import Foundation
import Network

/// Installs and updates the model from the CDN: the revision the remote config names (or the pinned one), the CPU set
/// of this device's download profile only (`DownloadProfile`), resumable, every file verified. A first install
/// activates at once; an update of a model in use becomes current at the next load. The Neural Engine's files are
/// never part of an install: the promotion pipeline fetches them later (`installAccelerator`), after the first
/// session, on an unmetered network.
actor ModelUpdater {
    enum Outcome: Sendable {
        /// The revision is current and the context's files are on disk.
        case upToDate(revision: String)
        /// Installed (and current, when asked to activate).
        case installed(ModelFolder, InstallReport)
        /// Downloaded and verified; it becomes current at the next load.
        case pending(revision: String)
        /// Not attempted now (policy: no Wi-Fi; no revision known yet). Tried again at the next check.
        case deferred(String)
        case failed(RecognizerError)
    }

    let store: ModelStore
    private let client: @Sendable () -> CDNClient?
    /// The signed config's `inference.context`, when it names one.
    private let inferenceContext: @Sendable () -> String?
    private let networkAllowed: @Sendable (_ firstInstall: Bool) async -> Bool
    /// Whether this install may fetch a CoreML build at all (the OS runs it and the app allows it).
    nonisolated let coreML: Bool
    private let record: @Sendable (AnalyticsEvent) -> Void
    private let report: @Sendable (RecognizerError, String) -> Void
    /// The refusal that stops the model now, when one is remembered (SPEC 15.3): nothing is put on the device
    /// while it holds.
    private let stopped: @Sendable () -> ModelGate.Refusal?
    private let rangeSize: Int64
    private let retryPauses: [TimeInterval]
    /// The background transport, its policy and the hand-over's state, when this install has one.
    private let background: (transport: any BackgroundRangeTransport, policy: BackgroundDownloadPolicy, handOver: DownloadHandOver)?
    /// Whether a background transfer sends the developer key beside the token, as the signed config says now.
    private let keyInBackground: @Sendable () -> Bool
    /// The background range tasks that were cancelled before they ended, since this updater was made.
    nonisolated let abandonedRanges = Locked(0)
    /// `whenResigning`: the tasks cancelled, and the bytes they had fetched that were dropped, when the app was
    /// active again without having been in the background; since this updater was made.
    nonisolated let droppedForNothing = Locked<(tasks: Int, bytes: Int64)>((0, 0))
    /// An update, and the accelerator's build, wait for an unmetered network (`CloudOptions.updatesOnWiFiOnly`):
    /// their requests say so, and the system holds to it for the whole transfer. A first install goes on any.
    private let unmeteredUpdates: Bool
    /// Who wants the bytes of an install as they are done (`client.prefetch`). Every install reports to the relay, so
    /// a listener that comes while one is running (the launch's own update check may have started it) gets its
    /// progress from where it stands.
    nonisolated let progress = ProgressRelay()

    func setProgress(_ p: (@Sendable (Int64, Int64) -> Void)?) { progress.listen(p) }

    init(store: ModelStore, client: @escaping @Sendable () -> CDNClient?, inferenceContext: @escaping @Sendable () -> String? = { nil },
         coreML: Bool = DownloadProfile.osRunsCoreML,
         rangeSize: Int64 = 8 << 20,
         networkAllowed: @escaping @Sendable (_ firstInstall: Bool) async -> Bool,
         record: @escaping @Sendable (AnalyticsEvent) -> Void = { _ in },
         report: @escaping @Sendable (RecognizerError, String) -> Void = { _, _ in },
         stopped: @escaping @Sendable () -> ModelGate.Refusal? = { nil },
         retryPauses: [TimeInterval] = ModelInstaller.standardRetryPauses,
         unmeteredUpdates: Bool = false,
         background: (transport: any BackgroundRangeTransport, policy: BackgroundDownloadPolicy, handOver: DownloadHandOver)? = nil,
         keyInBackground: @escaping @Sendable () -> Bool = { true }) {
        self.keyInBackground = keyInBackground
        self.stopped = stopped
        self.background = background
        self.retryPauses = retryPauses
        self.unmeteredUpdates = unmeteredUpdates
        self.store = store
        self.client = client
        self.inferenceContext = inferenceContext
        self.coreML = coreML
        self.rangeSize = rangeSize
        self.networkAllowed = networkAllowed
        self.record = record
        self.report = report
    }

    /// One install that is running, and who waits for it.
    private struct Run {
        let id: UUID
        let task: Task<Outcome, Never>
        var waiters: [UUID: CheckedContinuation<Outcome, Never>]
        /// A download ahead of use (`client.prefetch`) asked for this install: it goes on to its end whoever stops
        /// waiting.
        var kept: Bool
        /// The last waiter left and the install was told to stop: a caller that comes now starts it again, after it.
        var stopping = false
        /// Every caller so far asked for unmetered networks only (`prefetch(unmeteredOnly:)`): the install's
        /// requests then carry the system's marks for that. A caller that needs the model on any network lifts it.
        let unmetered: Locked<Bool>
    }
    private var runs: [String: Run] = [:]

    /// Brings `id` to the build `cdnRevision` (the first 40 hex digits of the SHA-256 of its manifest; `version` is
    /// the model version the config names for it) with `context`'s files (nil: the config's `inference.context` when
    /// the build has it, else the manifest's default context). Concurrent calls for the same model share one run.
    ///
    /// Cancelling a caller ends that caller's wait and nothing else (SPEC 16.3): it gets `cancelled` at once, and
    /// the install goes on while another caller waits for it, or when a `prefetch` asked for it (`keep`). When the
    /// last waiter is gone and no `prefetch` asked, the part that runs in the app stops (the request in flight ends
    /// and a pause before a retry ends at once); what is on disk stays, what was handed to the system's background
    /// session runs on, and the next call goes on from there.
    /// Tried before (the first candidate, never released): a cancelled caller cancelled the install it had
    /// started or joined, also under the callers that were still waiting for it.
    func update(_ id: ModelID, to cdnRevision: String, version: String? = nil, context: String? = nil, activate: Bool,
                keep: Bool = false, unmeteredOnly: Bool = false) async -> Outcome {
        let key = id.name + "@" + cdnRevision + "#" + (context ?? "")
        let me = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Outcome, Never>) in
                self.join(key, me, waiter, keep: keep, unmeteredOnly: unmeteredOnly) { unmetered in
                    await self.run(id, cdnRevision, version, context, activate, unmetered)
                }
            }
        } onCancel: {
            Task { await self.leave(key, me) }
        }
    }

    /// A caller comes to wait for the install `key`, which is started when it does not run.
    private func join(_ key: String, _ me: UUID, _ waiter: CheckedContinuation<Outcome, Never>, keep: Bool, unmeteredOnly: Bool,
                      _ work: @escaping @Sendable (Locked<Bool>) async -> Outcome) {
        // a caller that was cancelled before it came starts nothing and waits for nothing
        if Task.isCancelled {
            waiter.resume(returning: .failed(.cancelled))
            return
        }
        if var run = runs[key], !run.stopping {
            run.waiters[me] = waiter
            run.kept = run.kept || keep
            if !unmeteredOnly { run.unmetered.withLock { $0 = false } }
            runs[key] = run
            return
        }
        // an install that was told to stop ends first: two never write the same download folder
        let earlier = runs[key]?.task
        let id = UUID()
        let unmetered = Locked(unmeteredOnly)
        let task = Task { () -> Outcome in
            if let earlier { _ = await earlier.value }
            let out = await work(unmetered)
            await self.finished(key, id, out)
            return out
        }
        runs[key] = Run(id: id, task: task, waiters: [me: waiter], kept: keep, unmetered: unmetered)
    }

    /// The install `key` has ended: everyone who waits for it gets its outcome.
    private func finished(_ key: String, _ id: UUID, _ out: Outcome) {
        guard let run = runs[key], run.id == id else { return }
        runs[key] = nil
        for waiter in run.waiters.values { waiter.resume(returning: out) }
    }

    /// A caller was cancelled: its wait ends now. The install stops only when nobody waits for it any more and no
    /// `prefetch` asked for it.
    private func leave(_ key: String, _ me: UUID) {
        guard var run = runs[key], let waiter = run.waiters.removeValue(forKey: me) else { return }
        waiter.resume(returning: .failed(.cancelled))
        if run.waiters.isEmpty, !run.kept, !run.stopping {
            run.stopping = true
            run.task.cancel()
        }
        runs[key] = run
    }

    /// The working files of a download in `folder`, at any depth: partial files, their validators, ranges that a
    /// background task delivered, a whole file that was on its way (`<file>.part` and everything named after it).
    /// They are removed before the folder is put in place: a range that a background task delivered after its
    /// file was finished must not become a file of the installed build.
    static func pruneWorkingFiles(_ folder: URL) {
        let fm = FileManager.default
        let all = (fm.enumerator(atPath: folder.path)?.allObjects as? [String]) ?? []
        for name in all where name.hasSuffix(".part") || name.contains(".part.") {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// The download folders of other builds of the model, left by an earlier process (`.download-<build>` beside
    /// `folder`): they are removed, and the background tasks that still belong to them are cancelled, since what
    /// they bring has no place any more.
    private func pruneOtherDownloads(beside folder: URL) async {
        let fm = FileManager.default
        let parent = folder.deletingLastPathComponent()
        let root = store.root.path.hasSuffix("/") ? store.root.path : store.root.path + "/"
        let names = ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).filter { $0.hasPrefix(".download-") && $0 != folder.lastPathComponent }
        for name in names {
            let other = parent.appendingPathComponent(name)
            if let background, other.path.hasPrefix(root) {
                let relative = store.root.lastPathComponent + "/" + String(other.path.dropFirst(root.count))
                _ = await background.transport.cancel(prefix: BackgroundRange.prefix(folder: relative))
            }
            try? fm.removeItem(at: other)
        }
    }

    /// What an install into `folder` needs to hand its ranges to the background transport; nil without one, or
    /// for a folder outside the store.
    private func plan(_ client: CDNClient, _ id: ModelID, _ cdnRevision: String, into folder: URL) -> BackgroundPlan? {
        guard let background, background.policy != .off else { return nil }
        let root = store.root.path.hasSuffix("/") ? store.root.path : store.root.path + "/"
        guard folder.path.hasPrefix(root) else { return nil }
        let relative = store.root.lastPathComponent + "/" + String(folder.path.dropFirst(root.count))
        let counter = abandonedRanges
        let sendsKey = keyInBackground
        let stop = stopped
        let droppedCounter = droppedForNothing
        return BackgroundPlan(transport: background.transport, policy: background.policy, handOver: background.handOver, folder: relative,
                              request: { (path: String, lower: Int64, upper: Int64, validator: String?) async -> URLRequest? in
                                  await client.backgroundRequest(client.fileURL(id, revision: cdnRevision, path: path), lower: lower, upper: upper,
                                                                 validator: validator, sendsKey: sendsKey())
                              },
                              abandoned: { n in counter.withLock { $0 += n } },
                              stopped: { stop()?.error },
                              dropped: { tasks, bytes in droppedCounter.withLock { $0 = ($0.tasks + tasks, $0.bytes + bytes) } })
    }

    /// The context to install: the caller's, else the config's when the manifest has it, else the manifest's default.
    private func resolve(_ context: String?, _ m: ModelManifest) -> String {
        if let context { return context }
        if let c = inferenceContext(), m.contexts.contains(c) { return c }
        return m.defaultContext
    }

    private func run(_ id: ModelID, _ cdnRevision: String, _ version: String?, _ context: String?, _ activate: Bool,
                     _ unmetered: Locked<Bool>) async -> Outcome {
        // The device's key store first (SPEC 15.2): when it fails, nothing is opened, nothing is deleted and nothing
        // is downloaded; the next call tries again.
        if case .failed(let why) = store.installKeys.load() { return .failed(.storageFailed(InstallRecord.keyStoreMessage(why))) }
        // A Client the server has refused downloads nothing: the remembered refusal is the answer, whichever side
        // it came from. A refusal of a model request is dropped by `client.model()` and `prefetch` before they
        // come here, once the API has accepted the key since (`QuranLabCloud.modelStop`); the launch's own update
        // check does not drop one, so without such a call it asks nothing.
        // Tried before (3.1.0 to 3.1.2): a refusal of a model request did not stop the request here, so every
        // launch asked the CDN again, whether or not the API had accepted the key.
        if let stop = stopped() { return .failed(stop.error) }
        var current = store.currentRevision(id)
        var currentDir = current.map { store.base(id).appendingPathComponent($0) }
        // A model in the store that this Client did not download itself (no valid install record of this device) is
        // not opened and nothing is added to it: it is deleted, and the build is downloaded as on a first install.
        if let dir = currentDir {
            switch store.standing(of: dir) {
            case .own(.installed):
                break
            case .keyStoreFailed(let why):
                return .failed(.storageFailed(InstallRecord.keyStoreMessage(why)))
            case .unreadable(let why):
                // the build's install record or manifest cannot be read now: nothing is deleted or downloaded
                return .failed(.storageFailed(InstallRecord.unreadableMessage(why)))
            case .own(.downloading), .notOwn:
                store.discard(id, folder: dir)
                current = nil
                currentDir = nil
            }
        }
        let isCurrent = current.map { store.sourceRevision(id, revision: $0) == cdnRevision || $0 == cdnRevision } ?? false
        if isCurrent, let dir = currentDir, let m = try? ModelFolder.open(directory: dir, verifier: store.verifier, expecting: id),
           m.isUsable(context: resolve(context, m.manifest)) {
            return activate ? .installed(m, InstallReport()) : .upToDate(revision: m.revision)
        }
        if !activate, let p = store.pendingRevision(id), store.sourceRevision(id, revision: p) == cdnRevision {
            return .pending(revision: p)
        }
        guard await networkAllowed(current == nil) else { return .deferred("waiting for an unmetered network") }
        guard var client = client() else { return .deferred("no developer key configured") }
        // an update waits for an unmetered network, for as long as it runs; a first install goes on any network
        client.unmeteredOnly = unmeteredUpdates && current != nil
        // a `prefetch(unmeteredOnly:)` asked for this install: its requests wait for an unmetered network as well,
        // until a caller that needs the model on any network has joined
        client.alsoUnmetered = { unmetered.withLock { $0 } }
        // the learner may leave the app while this runs: the system is asked for the time it gives a task that is
        // under way, and gets it back however this ends
        let endGrace = await InstallGrace.begin()
        defer { endGrace() }
        var report = InstallReport()
        let profileName = "apple-cpu"
        let relay = progress
        defer { relay.ended() }
        do throws(RecognizerError) {
            let manifest = try await client.manifest(id, revision: cdnRevision, version: version)
            let ctx = resolve(context, manifest)
            guard manifest.contexts.contains(ctx) else { throw RecognizerError.invalidArgument("context \(ctx) is not in \(id) \(cdnRevision)") }
            // the CPU set only: the accelerator's files come later, from the promotion pipeline
            let profile = DownloadProfile(context: ctx, coreML: false)
            var installer = ModelInstaller(source: client.source(id, revision: cdnRevision), rangeSize: rangeSize, retryPauses: retryPauses)
            installer.meter = ProgressMeter { (done: Int64, total: Int64) in relay.report(done, total) }
            let model: ModelFolder
            if isCurrent, let dir = currentDir {
                // another context of the model in use: its files go into the same folder
                report = try await installer.install(manifest, profile: profile, into: dir)
                model = try ModelFolder.open(directory: dir, verifier: store.verifier, expecting: id)
            } else {
                let folder = store.downloadFolder(id, cdnRevision: cdnRevision)
                await pruneOtherDownloads(beside: folder)
                // the install record, state `downloading`, before the first file is asked for; a download folder
                // without this device's record of this build is deleted first, none of its files reused
                try store.beginDownload(folder, build: manifest.build)
                installer.background = plan(client, id, cdnRevision, into: folder)
                report = try await installer.install(manifest, profile: profile, into: folder)
                // a refusal that arrived while the files were on their way: nothing is put in place, and what was
                // downloaded goes
                if let stop = stopped() {
                    try? FileManager.default.removeItem(at: folder)
                    throw stop.error
                }
                // nothing of the download's working files goes into the build: the tasks still out for this
                // folder are cancelled, and what they or an earlier attempt left is removed
                if let plan = installer.background {
                    _ = await plan.transport.cancel(prefix: BackgroundRange.prefix(folder: plan.folder))
                }
                Self.pruneWorkingFiles(folder)
                // every file of the profile is verified: the record says `installed`, and travels with the folder
                model = try store.putInPlace(folder, id: id, cdnRevision: cdnRevision, build: manifest.build, current: activate || current == nil)
            }
            record(.download(revision: manifest.version.isEmpty ? cdnRevision : manifest.version, build: cdnRevision, profile: profileName,
                             bytes: report.downloadedBytes, success: true, resumed: report.resumed))
            SDKLatest.debugOnly("model download: finished, \(report.downloadedBytes) bytes in this call\(report.resumed ? ", resumed" : "")")
            if activate || current == nil || isCurrent { return .installed(model, report) }
            return .pending(revision: model.revision)
        } catch {
            // a refusal that stops the model arrived while this ran (met by a background task, or by the API on
            // another call): the refusal is the error, whatever the install failed on after its files went
            if let stop = stopped() { return .failed(stop.error) }
            if case .offline = error { return .deferred("offline: \(error)") }
            if case .insufficientStorage = error { return .deferred(error.description) }
            record(.download(revision: version ?? cdnRevision, build: cdnRevision, profile: profileName, bytes: report.downloadedBytes,
                             success: false, resumed: report.resumed))
            self.report(error, cdnRevision)
            return .failed(error)
        }
    }

    /// The promotion pipeline's `download` stage: the accelerator files of one CoreML build (package, the context's
    /// keep table, the self-test set) into `model`'s folder, from the CDN revision the folder came from. `compact`:
    /// the compact build, for a Session that names `coreml-compact`; else the fp16 build.
    func installAccelerator(_ model: ModelFolder, context: String, compact: Bool = false) async throws(RecognizerError) -> InstallReport {
        guard coreML else { throw .neuralEngineUnavailable("CoreML downloads are off for this install") }
        guard var client = client() else { throw .offline("no developer key configured") }
        // the accelerator's build is never needed at once: it waits for an unmetered network, like an update
        client.unmeteredOnly = unmeteredUpdates
        let endGrace = await InstallGrace.begin()
        defer { endGrace() }
        let profile = DownloadProfile(context: context, coreML: true, compact: compact)
        let name = compact ? "apple-compact" : "apple-coreml"
        let installer = ModelInstaller(source: client.source(model.id, revision: model.identity), rangeSize: rangeSize, retryPauses: retryPauses)
        do throws(RecognizerError) {
            let r = try await installer.installAccelerator(model.manifest, profile: profile, into: model.directory)
            record(.download(revision: model.version.isEmpty ? model.identity : model.version, build: model.identity, profile: name,
                             bytes: r.downloadedBytes, success: true, resumed: r.resumed))
            return r
        } catch {
            if case .offline = error { throw error }
            record(.download(revision: model.version.isEmpty ? model.identity : model.version, build: model.identity, profile: name,
                             bytes: 0, success: false, resumed: false))
            throw error
        }
    }

    /// One more file of a model already on the device (the reference table, which no profile downloads), into its
    /// folder: downloaded from the build the folder came from and verified against the manifest like any file.
    func install(_ file: ModelManifest.File, of model: ModelFolder) async throws(RecognizerError) {
        guard let client = client() else { throw .offline("no developer key configured") }
        let installer = ModelInstaller(source: client.source(model.id, revision: model.identity), rangeSize: rangeSize, retryPauses: retryPauses)
        var report = InstallReport()
        try await installer.ensure(file, in: model.directory, report: &report)
    }

    /// Whether the network is fine for a model download: not cellular, not Low Data Mode.
    static func onUnmeteredNetwork() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            let once = Locked(false)
            monitor.pathUpdateHandler = { path in
                let first = once.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard first else { return }
                monitor.cancel()
                c.resume(returning: path.status == .satisfied && !path.isExpensive && !path.isConstrained)
            }
            monitor.start(queue: DispatchQueue(label: "ai.quranlab.path", qos: .utility))
        }
    }
}
