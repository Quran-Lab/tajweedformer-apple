import Foundation

/// What a Client may be told besides its key. Every field has a default.
///
/// SDK 4.0: there is no analytics option. Anonymous analytics (daily counts and durations only, never audio, text,
/// names or device identifiers) are always on; Quran Lab's signed config (`flags.analytics`) is the only off switch.
///
/// SDK 4.0: there is no audience option. Every app shows the same sharing sheet, every learner is asked under the
/// same rules, and the choice is the learner's.
public struct TajweedClientOptions: Sendable {
    /// The app's id; nil reads the bundle identifier.
    public var appId: String?
    /// The app's version; nil reads the bundle's short version.
    public var appVersion: String?
    /// Where the SDK keeps models and its queues; nil means `Application Support/QuranLab` (on macOS
    /// `Application Support/<bundle id>/QuranLab`). The folder is the SDK's to fill: a model found there that this
    /// Client did not download itself on this device is not opened; it is deleted and downloaded.
    public var storage: URL?

    public init(appId: String? = nil, appVersion: String? = nil, storage: URL? = nil) {
        self.appId = appId
        self.appVersion = appVersion
        self.storage = storage
    }

    /// The same choices as the SDK's internal configuration.
    var configuration: QuranLab.Options {
        var o = QuranLab.Options()
        o.storageDirectory = storage
        if appId != nil || appVersion != nil {
            var app = AppIdentity.main
            if let appId { app.bundleID = appId }
            if let appVersion { app.version = appVersion }
            var cloud = o.cloud ?? CloudOptions()
            cloud.app = app
            o.cloud = cloud
        }
        return o
    }
}

/// The app's link to Quran Lab: the key, the signed config, registration, telemetry, issues, sharing and the model
/// files on disk. Make one at launch with the app's key from sdk.quranlab.ai and keep it:
///
///     let client = try TajweedClient(key: "qlk_v1_...")
///     let model = try await client.model()
///
/// One per process: a second one while the first is not closed throws `client_exists`. Nothing in the recognition
/// path waits on the network once the model is on the device. Making the Client downloads no model: the model
/// downloads only when the app calls `model()` or `prefetch()` (a later start checks only for an update of a build
/// this Client installed on this device).
///
/// A model comes only from Quran Lab's server, through the Client (3.1.0): the key, the signed config, the SDK's own
/// download and its verification. No call takes a model folder, and a Client opens only a build it downloaded
/// itself on this device.
public final class TajweedClient: Sendable {
    private static let live = Locked<UUID?>(nil)

    private let token: UUID
    private let closed = Locked(false)
    private let held = Locked<TajweedModel?>(nil)
    /// The model version the app pinned with `model(version:)`, when it did.
    private let pinned = Locked<String?>(nil)
    /// Sharing recitations with Quran Lab: whether Quran Lab's switch has it on, the learner's choice, the outbox.
    public let sharing: TajweedSharing
    /// Counters the app reports itself.
    public let analytics: TajweedAnalytics

    /// - Parameter key: the app's key from sdk.quranlab.ai (`qlk_v1_...`), for this app's bundle id.
    public convenience init(key: String, options: TajweedClientOptions = TajweedClientOptions()) throws(TajweedError) {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .argument("the key is empty") }
        try self.init(key: key, configuration: options.configuration, cloud: nil)
    }

    /// The Client over a configuration; tests pass the server client themselves (a stub network).
    init(key: String?, configuration: QuranLab.Options, cloud: (@Sendable (URL) -> QuranLabCloud?)?) throws(TajweedError) {
        try RuntimeSupport.check()
        let token = UUID()
        let taken = Self.live.withLock { (current: inout UUID?) -> Bool in
            if current != nil { return true }
            current = token
            return false
        }
        if taken { throw TajweedError(.clientExists) }
        self.token = token
        TakeBounds.droppedChunks.withLock { $0 = 0 }
        sharing = TajweedSharing()
        analytics = TajweedAnalytics()
        if let cloud {
            let storage = QuranLab.Configuration(key: key, options: configuration).storageDirectory
            QuranLab.configure(key: key, options: configuration, cloud: cloud(storage))
        } else {
            QuranLab.configure(key: key, options: configuration)
        }
    }

    deinit { close() }

    /// Ends the Client: its network calls and upload queue stop, and another Client can be made. Models made by it
    /// stay usable for takes that are open.
    public func close() {
        let first = closed.withLock { (c: inout Bool) -> Bool in
            defer { c = true }
            return !c
        }
        guard first else { return }
        held.withLock { $0 = nil }
        QuranLab.cloud?.analytics.closeSession()
        QuranLab.shutdown()
        Self.live.withLock { (current: inout UUID?) in
            if current == token { current = nil }
        }
    }

    private func check() throws(TajweedError) {
        if closed.withLock({ $0 }) { throw .argument("this TajweedClient was closed") }
    }

    // MARK: the model

    /// The Model for this app: downloaded on first use (the CPU files of the default context, verified), opened, and
    /// warmed so the first take starts at once. Later calls return the same Model. Call it early for a warm start.
    /// `version` pins a model version (`"4.0.0"`): the config request names it, and Quran Lab answers that version's
    /// build for this SDK, or its normal choice when it has none. Nil takes the version Quran Lab's config names.
    /// A first run without a network throws `needs_connection`; `model_unavailable` when Quran Lab has no build for
    /// this SDK version yet. When Quran Lab has refused the key or the app (`invalid_key`, or `server_rejected`
    /// with its reason), no model is opened and the downloaded model is removed from the device; once the server
    /// accepts the key again the model is downloaded again. A Model that was open before the refusal keeps
    /// running until the app closes it.
    public func model(version: String? = nil) async throws(TajweedError) -> TajweedModel {
        try check()
        if let version, !ModelVersion.isVersion(version) { throw .argument("version \(version) is not x.y.z") }
        if let m = held.withLock({ $0 }), version == nil || m.version == version { return m }
        if let cloud = QuranLab.cloud, version != nil || pinned.withLock({ $0 }) != nil {
            pinned.withLock { $0 = version }
            await cloud.pin(version: version)
        }
        let folder = try await install(progress: nil)
        try await Self.lease(folder)
        let model = TajweedModel(folder, client: self)
        // from here the Client holds an open Model: a refusal that arrives now leaves its files until it is closed
        let gate = QuranLab.cloud?.gate
        gate?.modelOpen(true)
        do throws(TajweedError) {
            try await model.warm()
        } catch {
            gate?.modelOpen(false)
            throw error
        }
        held.withLock { $0 = model }
        return model
    }

    /// SDK 4.0: the Core holds a valid lease for the build before the model opens: the one it has
    /// (no network then, and a lease past `refresh_after` is renewed in the background), else a new one. Offline
    /// after `exp`: `needs_connection`, and nothing is decrypted.
    private static func lease(_ folder: ModelFolder) async throws(TajweedError) {
        guard let runtime = ProtectedRuntime.current.withLock({ $0 }) else { throw TajweedError(.needsConnection) }
        do throws(RecognizerError) {
            _ = try await runtime.ensureLease(folder.manifest)
            runtime.refreshIfDue(folder)
        } catch {
            let cause = ErrorCause.lease(error, runtime: runtime)
            // contract 24.4: `needs_connection` only when the lease route got no answer and no valid lease is held (rule
            // 1); a 5xx or 429 is `download_failed` naming it; only a stop the Core verified is a stop, and an unsigned
            // or unverified refusal is `server_rejected` (rule 3). Before, every failure worded as `offline` was
            // `needs_connection`, a server failure and an unsigned stop among them
            switch error {
            case .offline, .serverRejected: throw Self.modelCallError(cause, onDevice: .nothing, error: error)
            default: throw TajweedError(from: error, cause: cause)
            }
        }
    }

    /// The error of a model call that failed for `cause`: `needs_connection`
    /// only when no request got an answer and nothing of what the call needs is on the device; a server's answer is
    /// `download_failed` with what answered as its detail.
    /// A refusal is `invalid_key` or `server_rejected` with the refusal's own words (15.3), and `sdk_too_old` keeps the
    /// version the answer names (`error`, the failure itself).
    static func modelCallError(_ cause: ErrorCause, onDevice: ErrorRules.OnDevice, error: RecognizerError? = nil) -> TajweedError {
        let code = ErrorRules.modelCallCode(cause, onDevice: onDevice)
        switch code {
        case ErrorCode.needsConnection.rawValue:
            return TajweedError(.needsConnection, cause: cause)
        case ErrorCode.invalidKey.rawValue:
            return TajweedError(.invalidKey, cause: cause)
        case ErrorCode.serverRejected.rawValue:
            let named = cause.errorCode ?? cause.reason
            let app = QuranLab.cloud?.app.bundleID ?? Bundle.main.bundleIdentifier ?? "this app"
            return TajweedError(.serverRejected, ["detail": named, "origin": app], reason: TajweedError.knownReason(named), cause: cause)
        case ErrorCode.sdkTooOld.rawValue:
            if let error { return TajweedError(from: error, cause: cause) }
            return TajweedError(.sdkTooOld, ["version": "a newer version"], cause: cause)
        default:
            return TajweedError(ErrorCode(rawValue: code) ?? .downloadFailed, ["detail": cause.detail], cause: cause)
        }
    }

    /// Downloads and verifies the model ahead of use. Resumable: a download that stopped goes on where it stopped.
    /// With `unmeteredOnly` it follows the connection `diagnose()` reports: it downloads on `unmetered` (Wi-Fi,
    /// Ethernet) and on `unknown`, and does nothing on `metered` (cellular, a personal hotspot, Low Data Mode) and
    /// on `none`; call it again later. A no-op when the model is on the device. `onProgress` gets the bytes done and
    /// the total of the files to download, as they arrive.
    public func prefetch(unmeteredOnly: Bool = false,
                         onProgress: (@Sendable (_ done: Int64, _ total: Int64) -> Void)? = nil) async throws(TajweedError) {
        try check()
        if unmeteredOnly, QuranLab.cloud != nil, onDevice() == nil {
            let connection = await ConnectionKind.current()
            if !connection.downloadsWhenUnmeteredOnly { return }
        }
        // a download ahead of use goes on to its end also when its caller stops waiting; with `unmeteredOnly` its
        // requests carry the system's marks for an unmetered network, for as long as it runs
        _ = try await install(progress: onProgress, ahead: true, unmeteredOnly: unmeteredOnly)
    }

    /// The model folder in the SDK's store, when one is there, is this Client's own download (its install record)
    /// and verifies. Nothing is deleted here.
    private func onDevice() -> ModelFolder? {
        let config = QuranLab.configuration
        let id = RecommendedModel.resolve(config: QuranLab.cloud?.currentConfig, storage: config.storageDirectory)
        let store = ModelStore.standard
        guard let dir = try? store.ownedDirectory(id, discard: false) else { return nil }
        return try? ModelFolder.open(directory: dir, verifier: store.verifier, expecting: id)
    }

    /// The model folder: the one this Client downloaded to the device, else a download. Nothing else is a source:
    /// not the app bundle (to 3.0.1 `QuranLabModels/<model id>/` was opened before any network), not a folder the
    /// app names, not a store filled in advance (a folder without this device's install record is deleted and the
    /// build downloaded).
    private func install(progress: (@Sendable (Int64, Int64) -> Void)?, ahead: Bool = false,
                         unmeteredOnly: Bool = false) async throws(TajweedError) -> ModelFolder {
        let config = QuranLab.configuration
        let cloud = QuranLab.cloud
        // a Client the server has refused does not run the model, also not one a real download left (SPEC 15.3)
        if let cloud, let stop = await cloud.modelStop() { throw TajweedError(from: stop) }
        let id = RecommendedModel.resolve(config: cloud?.currentConfig, storage: config.storageDirectory)
        let store = ModelStore.standard
        var local: RecognizerError?
        do throws(RecognizerError) {
            let folder = try await store.resolve(id, sources: [.cache], context: nil)
            // a pinned version is served from the device only when the device has that version
            if let want = pinned.withLock({ $0 }), folder.version != want, cloud != nil {
                local = .modelMissing("version \(want) is not on this device")
            } else {
                return folder
            }
        } catch {
            // the device's key store failed: nothing was opened or deleted, and nothing is downloaded now
            if case .storageFailed = error { throw TajweedError(from: error) }
            local = error
        }
        guard let cloud else {
            throw TajweedError(from: local ?? .modelMissing("no model on this device"))
        }
        await cloud.updater.setProgress(progress)
        let outcome = await cloud.install(id, context: nil, activate: true, keep: ahead, unmeteredOnly: unmeteredOnly)
        await cloud.updater.setProgress(nil)
        // the install's own failure, with the stage it was at, when the outcome is that failure
        let ran = cloud.updater.lastFailure.withLock { $0 }
        switch outcome {
        case .installed(let folder, _): return folder
        case .failed(let e):
            let cause = ran.flatMap { $0.error == e ? $0.cause : nil }
            // a refusal on the lease route: a stop only when the Core verified it
            if let cause, cause.stage == "lease", case .serverRejected = e { throw Self.modelCallError(cause, onDevice: .nothing, error: e) }
            throw TajweedError(from: e, cause: cause)
        case .upToDate, .pending:
            do throws(RecognizerError) {
                return try await store.resolve(id, sources: [.cache], context: nil)
            } catch {
                throw TajweedError(from: error)
            }
        case .deferred(let why):
            // the server said no to this key or app: that, not the missing connection, is what to fix
            if let refused = cloud.rejectionError { throw TajweedError(from: refused, stage: "config") }
            // Quran Lab answered and names no model build for this SDK version
            if cloud.currentConfig != nil, cloud.targetRevision(id) == nil {
                // a model this Client downloaded keeps serving
                if let folder = try? await store.resolve(id, sources: [.cache], context: nil) { return folder }
                throw TajweedError(.modelUnavailable)
            }
            // the install that was put off for its failure (no answer, a server's answer, no room): its cause
            let failed = ran.flatMap { why == "offline: \($0.error)" || why == $0.error.description ? $0.cause : nil }
            if why.contains("space") { throw TajweedError(.storageFull, ["needed": "more", "available": "too few"], cause: failed) }
            // a damaged copy on the device is reported as it is; a missing one: contract 24.4, `needs_connection` only
            // when no request got any answer (the config's, the token's, the manifest's, a file's), else
            // `download_failed` naming what answered. To 3.1.4 a server failure here was `needs_connection`
            if let local, case .modelMissing = local {
                if let failed { throw Self.modelCallError(failed, onDevice: failed.partial ? .partial : .nothing) }
                if cloud.currentConfig == nil, let cause = cloud.configFailure.withLock({ $0 }) {
                    throw Self.modelCallError(cause, onDevice: .nothing)
                }
                throw TajweedError(.needsConnection)
            }
            if let local { throw TajweedError(from: local) }
            throw TajweedError(.needsConnection)
        }
    }

    /// What the SDK holds on disk: the bytes of each model build, ordered by version then build, and the bytes of the
    /// sharing queue. The same object as `diagnose().storage`.
    public var storage: TajweedDiagnosis.Storage {
        let root = QuranLab.configuration.storageDirectory
        let models = root.appendingPathComponent("models")
        let fm = FileManager.default
        var out: [TajweedDiagnosis.StoredModel] = []
        for model in (try? fm.contentsOfDirectory(atPath: models.path)) ?? [] {
            let base = models.appendingPathComponent(model)
            for revision in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where ModelStore.safeName(revision) {
                let dir = base.appendingPathComponent(revision)
                guard let m = try? ModelManifest.read(dir), !m.version.isEmpty, m.build.count == 40 else { continue }
                out.append(TajweedDiagnosis.StoredModel(version: m.version, build: m.build, bytes: Self.bytes(dir)))
            }
        }
        out.sort { (a, b) in
            if a.version != b.version, let x = ModelVersion(a.version), let y = ModelVersion(b.version) { return x < y }
            return a.build < b.build
        }
        return TajweedDiagnosis.Storage(models: out, sharingQueueBytes: Self.bytes(root.appendingPathComponent("outbox")))
    }

    /// The bytes of every regular file under a folder.
    static func bytes(_ dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var n: Int64 = 0
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            n += Int64(v.fileSize ?? 0)
        }
        return n
    }

    /// Removes the model files (the next `model()` downloads them again). The learner's sharing choice and the
    /// upload queue stay.
    public func removeModels() throws(TajweedError) {
        try check()
        held.withLock { $0 = nil }
        QuranLab.cloud?.gate.modelOpen(false)
        let models = QuranLab.configuration.storageDirectory.appendingPathComponent("models")
        guard FileManager.default.fileExists(atPath: models.path) else { return }
        do {
            try FileManager.default.removeItem(at: models)
        } catch {
            throw TajweedError(.storageFailed, ["detail": error.localizedDescription])
        }
    }

    /// The Model this Client made is closed: the next `model()` opens it again.
    func forget(_ model: TajweedModel) {
        let was = held.withLock { (m: inout TajweedModel?) -> Bool in
            guard m === model else { return false }
            m = nil
            return true
        }
        // when the server has refused the Client while the Model was open, its files go now (SPEC 15.3)
        if was { QuranLab.cloud?.gate.modelOpen(false) }
    }

    /// What a Session with the default options (`backend: .auto`) would run on now in `context`, read from the stored
    /// promotion state (the verdict the pipeline keeps per model build, context, CoreML build, OS build and device):
    /// a promoted build is `accelerator`, by its name, `promoted`; a build the pipeline gave up on is `cpu`, `demoted`
    /// with its reason; `cpu` when nothing is promoted. It needs no open Model.
    /// Tried before (3.0.0): `diagnose()` reported the Backend of the Model's engine in hand, which is the engine of
    /// the LAST Session (its context, its backend choice), next to the model's default context; after a Session on
    /// the CPU engine or in another context a promoted default build read as `cpu`. Without an open Model it said
    /// `cpu` whatever was promoted.
    static func storedBackend(_ folder: ModelFolder, context: String) -> TajweedBackend {
        guard DownloadProfile.osRunsCoreML, TajweedRecognizer.mayUseAccelerator(requested: .automatic, context: context) else { return .cpu }
        let compact = TajweedRecognizer.unnamedBuildIsCompact(model: folder, context: context)
        let build = compact ? "coreml-compact" : "coreml"
        let store = PromotionStore(dir: QuranLab.configuration.storageDirectory.appendingPathComponent("accelerator"))
        let program = AcceleratorController.programKey(folder.manifest, context: context, compact: compact)
        guard let r = store.record(AcceleratorController.key(revision: folder.identity, context: context, build: build, program: program)) else {
            return .cpu
        }
        switch r.status {
        case .ready:
            // the build's package is on the device. The disk is asked, not the folder in hand: a Model's folder was
            // opened before the pipeline fetched the build, so it does not list the build's files.
            let files = folder.manifest.files.filter { $0.role == build && ($0.context == "*" || $0.context == context) }
            let onDisk = ModelFolder.packages(files).contains { (pkg: String) -> Bool in
                FileManager.default.fileExists(atPath: folder.directory.appendingPathComponent(pkg).path)
            }
            return onDisk ? TajweedBackend(kind: .accelerator, name: build, stage: .promoted, reason: nil) : .cpu
        case .failed:
            return TajweedBackend(kind: .cpu, name: "cpu", stage: .demoted, reason: r.lastReason?.rawValue ?? "other")
        default:
            return .cpu
        }
    }

    // MARK: background transfers

    /// Whether a background URLSession identifier is one of the SDK's (they start with `ai.quranlab.`). For the
    /// app delegate, and for SwiftUI's `.backgroundTask(.urlSession(matching:))`.
    public static func isBackgroundSession(_ identifier: String) -> Bool { BackgroundEvents.owns(identifier) }

    /// Forward the app delegate's `application(_:handleEventsForBackgroundURLSession:completionHandler:)` here.
    /// The SDK's transfers go on while the app is suspended; when they are done the system starts the app in the
    /// background and hands it this completion handler, which the SDK calls once its session has delivered
    /// everything. It may be called before the app has made its Client: the handler then waits for the Client,
    /// and is called in any case after a short while, so the system is always answered. Returns false, and does
    /// not call `completionHandler`, when the session is not the SDK's (pass it to its owner then).
    /// An app that does not forward loses nothing: the transfers finish all the same, and the SDK collects their
    /// results when the Client is next made.
    /// The handler is taken as the system declares it (not marked `@Sendable`), so an app delegate passes it on as
    /// it is in any language mode; the SDK calls it once, on the main queue.
    @discardableResult
    public static func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        let handler = BackgroundEvents.SystemHandler(call: completionHandler)
        return BackgroundEvents.handle(identifier: identifier, completionHandler: { handler.call() })
    }

    /// The same for SwiftUI (iOS 16): returns when the SDK's background session `identifier` has delivered its
    /// events, at once when the session is not the SDK's. On the app's scene:
    ///
    ///     .backgroundTask(.urlSession(matching: { TajweedClient.isBackgroundSession($0) })) { identifier in
    ///         await TajweedClient.backgroundEvents(identifier: identifier)
    ///     }
    public static func backgroundEvents(identifier: String) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if !BackgroundEvents.handle(identifier: identifier, completionHandler: { c.resume() }) { c.resume() }
        }
    }

    // MARK: lifecycle and diagnosis

    /// The app left the foreground. iOS and macOS apps need not call it: the SDK follows the system's notifications.
    /// For hosts without them (an extension, a command-line tool).
    public func background() { QuranLab.cloud?.wentToBackground() }

    /// The app returned to the foreground (see `background()`).
    public func foreground() { QuranLab.cloud?.cameToForeground() }

    /// One structured report of where the SDK stands, safe to paste into an issue: no audio, no text, no identifiers.
    public func diagnose() async -> TajweedDiagnosis {
        let cloud = QuranLab.cloud
        // The config's state is read first and once. The key's answer is read after it, so a config that arrives while
        // this report is made can show as an answered key with the config not yet fresh, never as a fresh config with
        // the key still unanswered.
        let configStatus = cloud?.config.status ?? "none"
        let latest = cloud?.config.latest
        var key = TajweedDiagnosis.Key(accepted: nil, reason: nil)
        if let cloud, cloud.key != nil {
            if let r = cloud.rejection {
                // the code `model()` raises for it: the answer's `reason` first, then its `error`
                key = .init(accepted: false, reason: TajweedError.refusalCode(code: r.code, reason: r.reason).rawValue)
            } else if cloud.config.answered {
                key = .init(accepted: true, reason: nil)
            }
        }
        var model: TajweedDiagnosis.Model?
        var context: String?
        var backend: TajweedBackend?
        if let m = held.withLock({ $0 }) {
            if ModelVersion.isVersion(m.version), m.build.count == 40 { model = .init(version: m.version, build: m.build, verified: true) }
            context = m.defaultContext
            // what a Session with the default options would run on now, not what the Model's last Session ran on
            backend = await m.defaultBackend()
        } else if let f = onDevice() {
            // on the device and verified, not opened yet: the stored promotion state says what a Session would get
            if ModelVersion.isVersion(f.version), f.build.count == 40 { model = .init(version: f.version, build: f.build, verified: true) }
            let ctx = TajweedModel.defaultContext(f)
            context = ctx
            backend = Self.storedBackend(f, context: ctx)
        }
        let permission: String
        switch Microphone.permission {
        case .granted: permission = "granted"
        case .denied: permission = "denied"
        case .undetermined: permission = "notAsked"
        }
        let connection = await ConnectionKind.current()
        var d = TajweedDiagnosis(sdkVersion: SDKInfo.version, sdkLatest: latest, key: key, config: configStatus,
                                 model: model, context: context, backend: backend, microphone: permission, storage: storage,
                                 lastError: ErrorCatalogue.lastRaised.withLock { $0 },
                                 droppedChunks: TakeBounds.droppedChunks.withLock { $0 }, connection: connection.rawValue,
                                 downloadProtocol: ModelDownloadRecord.networkProtocol)
        d.protected = ProtectedRuntime.current.withLock { $0 }?.diagnosis()
        return d
    }
}

/// Counters the app reports about its own judge. Nothing is sent unless the app calls it.
public final class TajweedAnalytics: Sendable {
    init() {}

    /// How many times the app's own judge checked a rule and how many of those it flagged, for the app's analytics
    /// on sdk.quranlab.ai. `rule` is lower-case letters, digits and underscores (use the calibration's class ids
    /// where they apply: `vowel_sub`, `madd`, `qalqalah`, `word`), 0 <= flagged <= checked <= 100000. Counts only:
    /// never text, audio, ids or times. At most 32 different rules a day are counted.
    public func reportChecks(rule: String, checked: Int, flagged: Int) throws(TajweedError) {
        try Self.check(rule: rule, checked: checked, flagged: flagged)
        QuranLab.reportChecks(rule: rule, checked: checked, flagged: flagged)
    }

    /// A report the SDK takes; anything else is `invalid_argument` and counts nothing.
    static func check(rule: String, checked: Int, flagged: Int) throws(TajweedError) {
        guard AnalyticsStore.ruleKey(rule) else {
            throw .argument("rule \(rule.prefix(40)) is not lower-case letters, digits and underscores (1 to 24, a letter first)")
        }
        guard flagged >= 0, flagged <= checked, checked <= 100_000 else {
            throw .argument("checked \(checked) and flagged \(flagged) must satisfy 0 <= flagged <= checked <= 100000")
        }
    }
}

/// `client.diagnose()`: where the SDK stands. The same report, with the same fields, on the four SDKs.
public struct TajweedDiagnosis: Sendable, Hashable {
    public struct Key: Sendable, Hashable {
        /// True, false, or nil while no answer from Quran Lab was seen.
        public let accepted: Bool?
        /// Only when `accepted` is false: `invalid_key`, `sdk_too_old` or `server_rejected`.
        public let reason: String?
    }

    public struct Model: Sendable, Hashable {
        public let version: String
        public let build: String
        public let verified: Bool
    }

    /// One model build on disk.
    public struct StoredModel: Sendable, Hashable {
        public let version: String
        public let build: String
        public let bytes: Int64
    }

    public struct Storage: Sendable, Hashable {
        /// One entry per model build on disk, ordered by version then build.
        public let models: [StoredModel]
        public let sharingQueueBytes: Int64
    }

    /// This SDK's version, and the version of the newest release the signed config names (nil when it names none).
    public let sdkVersion: String
    public let sdkLatest: String?
    public let key: Key
    /// The signed config: `fresh` (a verified one that has not expired is in force), `stale` or `none`.
    public let config: String
    /// Nil without a model on the device.
    public let model: Model?
    /// The context the next Session uses when the app names none; nil without a model.
    public let context: String?
    /// What runs now and where the promotion stands; nil without a model.
    public let backend: TajweedBackend?
    /// The microphone permission: `granted`, `denied` or `notAsked`.
    public let microphone: String
    public let storage: Storage
    /// The catalogue code of the last error the SDK raised in this process.
    public let lastError: String?
    /// Chunks that waited unread on a Session's `chunks` and were dropped to make room (at most 256 wait), since the
    /// Client was made. Above 0, the app reads `chunks` late; the takes' Heads are whole all the same.
    public let droppedChunks: Int
    /// The device's connection: `unmetered` (Wi-Fi, Ethernet), `metered` (cellular, a personal hotspot, Low Data
    /// Mode), `none`, or `unknown` when the system does not say. `prefetch(unmeteredOnly:)` downloads on `unmetered`
    /// and `unknown`.
    public let connection: String
    /// The protocol of the last model request that was answered for this Client in this process: `h3`, `h2` or
    /// `http/1.1`; nil when none was made yet or the system named none. Held in memory and sent in no telemetry.
    /// In `json` it is the optional key `downloadProtocol`, written after the eleven fields when it is known.
    public var downloadProtocol: String?

    /// SDK 4.0, contract section 25 (`sdk_4.0.0/DIAGNOSIS_40.md`): the protected model as the Core holds it. Its fields
    /// in the section's order; no key, path or identifier.
    public struct Protected: Sendable, Hashable {
        /// Where the install's agreement key lives: `secureEnclave`, `keychain` (a software key in the Keychain), or
        /// `file` where the Keychain refuses the process (a 0600 file in the storage folder; the Core then seals its
        /// state under a key of its release, 18.4.7, as C's `file`). Nil before the install has a key.
        public let keyStore: String?
        /// `valid`, `grace` (expired, opened because Quran Lab could not be reached, 18.4.7.1), `expired`, `stopped` or
        /// `none`.
        public let lease: String
        /// The `exp` of the lease the Core holds, also when it has expired or was stopped; nil only when `lease` is
        /// `none`.
        public let leaseExpires: Int64?
        /// `attested` or `standard`, from the lease's flags (bit 3, 18.4.6: `attested` may use the Neural Engine), never
        /// from `exp - iat` (18.4.7.2: how long a lease lasts is Quran Lab's); nil when `lease` is `none` or `stopped`.
        public let leaseClass: String?
        /// The lease's `refresh_after`; nil when `lease` is `none` or `stopped`.
        public let refreshAfter: Int64?
        /// `exp` + 86400 while `lease` is `grace`; nil otherwise.
        public let graceUntil: Int64?
        /// The Core's release and target (`qlc_version`); nil when the Core is not loaded.
        public let core: String?
    }

    /// Nil before the protected model's runtime exists (no key configured).
    public var protected: Protected? = nil

    /// The report as JSON, its eleven fields in the order every SDK writes them, for pasting; then `downloadProtocol`
    /// when one is known, and (4.0) `protected`.
    public var json: String {
        func q(_ s: String?) -> String {
            guard let s else { return "null" }
            let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"" + escaped + "\""
        }
        func b(_ v: Bool?) -> String { v.map { $0 ? "true" : "false" } ?? "null" }
        var lines: [String] = []
        lines.append("  \"sdk\": {\"version\": \(q(sdkVersion)), \"latest\": \(q(sdkLatest))}")
        lines.append("  \"key\": {\"accepted\": \(b(key.accepted)), \"reason\": \(q(key.reason))}")
        lines.append("  \"config\": \(q(config))")
        lines.append("  \"model\": " + (model.map { "{\"version\": \(q($0.version)), \"build\": \(q($0.build)), \"verified\": \(b($0.verified))}" } ?? "null"))
        lines.append("  \"context\": \(q(context))")
        lines.append("  \"backend\": " + (backend.map {
            "{\"kind\": \(q($0.kind.rawValue)), \"name\": \(q($0.name)), \"stage\": \(q($0.stage.rawValue)), \"reason\": \(q($0.reason))}"
        } ?? "null"))
        lines.append("  \"microphone\": \(q(microphone))")
        let models = storage.models.map { "{\"version\": \(q($0.version)), \"build\": \(q($0.build)), \"bytes\": \($0.bytes)}" }
        lines.append("  \"storage\": {\"models\": [\(models.joined(separator: ", "))], \"sharingQueueBytes\": \(storage.sharingQueueBytes)}")
        lines.append("  \"lastError\": \(q(lastError))")
        lines.append("  \"droppedChunks\": \(max(0, droppedChunks))")
        lines.append("  \"connection\": \(q(connection))")
        // the optional key of contract 1.18.0, with one of the values the schema knows
        if let downloadProtocol, ["h3", "h2", "http/1.1"].contains(downloadProtocol) { lines.append("  \"downloadProtocol\": \(q(downloadProtocol))") }
        // 4.0, after the eleven shared fields and only with a runtime (as the C SDK's JSON adds it)
        if let p = protected {
            func n(_ v: Int64?) -> String { v.map(String.init) ?? "null" }
            lines.append("  \"protected\": {\"keyStore\": \(q(p.keyStore)), \"lease\": \(q(p.lease)), \"leaseExpires\": \(n(p.leaseExpires)), "
                + "\"leaseClass\": \(q(p.leaseClass)), \"refreshAfter\": \(n(p.refreshAfter)), \"graceUntil\": \(n(p.graceUntil)), "
                + "\"core\": \(q(p.core))}")
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n}"
    }
}
