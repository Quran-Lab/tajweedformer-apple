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
    private var running: [String: Task<Outcome, Never>] = [:]
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
         stopped: @escaping @Sendable () -> ModelGate.Refusal? = { nil }) {
        self.stopped = stopped
        self.store = store
        self.client = client
        self.inferenceContext = inferenceContext
        self.coreML = coreML
        self.rangeSize = rangeSize
        self.networkAllowed = networkAllowed
        self.record = record
        self.report = report
    }

    /// Brings `id` to the build `cdnRevision` (the first 40 hex digits of the SHA-256 of its manifest; `version` is
    /// the model version the config names for it) with `context`'s files (nil: the config's `inference.context` when
    /// the build has it, else the manifest's default context). Concurrent calls for the same model share one run.
    func update(_ id: ModelID, to cdnRevision: String, version: String? = nil, context: String? = nil, activate: Bool) async -> Outcome {
        let key = id.name + "@" + cdnRevision + "#" + (context ?? "")
        if let t = running[key] { return await t.value }
        let t = Task { await self.run(id, cdnRevision, version, context, activate) }
        running[key] = t
        let out = await t.value
        running[key] = nil
        return out
    }

    /// Asks the CDN for the manifest of a build and reads nothing from the answer: the request itself is the
    /// question whether the CDN serves this key (SPEC 15.3). The CDN client tells the model gate what it answered.
    nonisolated func ask(_ id: ModelID, revision: String) async {
        guard let client = client() else { return }
        _ = try? await client.send(client.fileURL(id, revision: revision, path: ModelManifest.fileName))
    }

    /// The context to install: the caller's, else the config's when the manifest has it, else the manifest's default.
    private func resolve(_ context: String?, _ m: ModelManifest) -> String {
        if let context { return context }
        if let c = inferenceContext(), m.contexts.contains(c) { return c }
        return m.defaultContext
    }

    private func run(_ id: ModelID, _ cdnRevision: String, _ version: String?, _ context: String?, _ activate: Bool) async -> Outcome {
        // The device's key store first (SPEC 15.2): when it fails, nothing is opened, nothing is deleted and nothing
        // is downloaded; the next call tries again.
        if case .failed(let why) = store.installKeys.load() { return .failed(.storageFailed(InstallRecord.keyStoreMessage(why))) }
        // A Client the API has refused downloads nothing: the refusal is the answer. (A refusal of a model request
        // does not stop the request here: the CDN is asked, and its answer decides.)
        if let stop = stopped(), stop.from == .api { return .failed(stop.error) }
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
        guard let client = client() else { return .deferred("no developer key configured") }
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
            var installer = ModelInstaller(source: client.source(id, revision: cdnRevision), rangeSize: rangeSize)
            installer.meter = ProgressMeter { (done: Int64, total: Int64) in relay.report(done, total) }
            let model: ModelFolder
            if isCurrent, let dir = currentDir {
                // another context of the model in use: its files go into the same folder
                report = try await installer.install(manifest, profile: profile, into: dir)
                model = try ModelFolder.open(directory: dir, verifier: store.verifier, expecting: id)
            } else {
                let folder = store.downloadFolder(id, cdnRevision: cdnRevision)
                // the install record, state `downloading`, before the first file is asked for; a download folder
                // without this device's record of this build is deleted first, none of its files reused
                try store.beginDownload(folder, build: manifest.build)
                report = try await installer.install(manifest, profile: profile, into: folder)
                // a refusal that arrived while the files were on their way: nothing is put in place, and what was
                // downloaded goes
                if let stop = stopped() {
                    try? FileManager.default.removeItem(at: folder)
                    throw stop.error
                }
                // every file of the profile is verified: the record says `installed`, and travels with the folder
                model = try store.putInPlace(folder, id: id, cdnRevision: cdnRevision, build: manifest.build, current: activate || current == nil)
            }
            record(.download(revision: manifest.version.isEmpty ? cdnRevision : manifest.version, build: cdnRevision, profile: profileName,
                             bytes: report.downloadedBytes, success: true, resumed: report.resumed))
            if activate || current == nil || isCurrent { return .installed(model, report) }
            return .pending(revision: model.revision)
        } catch {
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
        guard let client = client() else { throw .offline("no developer key configured") }
        let profile = DownloadProfile(context: context, coreML: true, compact: compact)
        let name = compact ? "apple-compact" : "apple-coreml"
        let installer = ModelInstaller(source: client.source(model.id, revision: model.identity), rangeSize: rangeSize)
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
        let installer = ModelInstaller(source: client.source(model.id, revision: model.identity), rangeSize: rangeSize)
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
