import Foundation

/// How models are kept up to date (see `ModelUpdater`).
enum UpdatePolicy: Sendable, Hashable {
    /// Follow the channel or pin set in the portal.
    case automatic
    /// Always this CDN revision.
    case pinned(String)
    /// Never update on its own (`QuranLab.checkForUpdate()` does it on request).
    case manual
}

/// The SDK's entry point: configure once at launch, then load a model and make a recognizer.
enum QuranLab {
    struct Options: Sendable {
        /// Where models are looked for, in order.
        var modelSource: [ModelSource]
        var updates: UpdatePolicy
        /// An extra sink for every analytics event, besides the SDK's own daily aggregates.
        var analyticsSink: (any AnalyticsSink)?
        /// Refuse a model whose manifest is not signed by a trusted key. Off by default so a folder you staged yourself
        /// loads; a signed manifest is always verified, and CDN downloads are always signed.
        var requireSignedModels: Bool
        /// Where the SDK keeps models, the backend verdicts and its queues; nil means `Application Support/QuranLab`
        /// (on macOS `Application Support/<bundle id>/QuranLab`).
        var storageDirectory: URL?
        /// Quran Lab's servers. Nil: the SDK never contacts a server (tests: a model from a directory).
        var cloud: CloudOptions?
        /// Ignored since 2.0.1: every learner is asked to share (the SDK's own consent sheet, then every session in
        /// full for a learner who said "Share") under the same rules in every app, and the choice is theirs. The
        /// signed config's `flags.contributions` is Quran Lab's incident switch, never the app's.
        var contributions: Bool
        /// The language of the SDK's sharing copy; nil follows the device.
        var sharingLocale: Locale?
        /// Download the CoreML package (iOS 18 / macOS 15) as well as the CPU set. Off: CPU only, a smaller download.
        /// Which CoreML build is not an option here: a device gets the fp16 one, and the compact one for a Session
        /// whose `backend` names `coreml-compact`.
        var neuralEngine: Bool

        init(modelSource: [ModelSource] = [.cache, .cdn],
                    updates: UpdatePolicy = .automatic,
                    analyticsSink: (any AnalyticsSink)? = nil,
                    requireSignedModels: Bool = false,
                    storageDirectory: URL? = nil,
                    cloud: CloudOptions? = CloudOptions(),
                    contributions: Bool = false,
                    sharingLocale: Locale? = nil,
                    neuralEngine: Bool = true) {
            self.modelSource = modelSource
            self.updates = updates
            self.analyticsSink = analyticsSink
            self.requireSignedModels = requireSignedModels
            self.storageDirectory = storageDirectory
            self.cloud = cloud
            self.contributions = contributions
            self.sharingLocale = sharingLocale
            self.neuralEngine = neuralEngine
        }
    }

    struct Configuration: Sendable {
        var key: String?
        var options: Options

        var storageDirectory: URL {
            if let d = options.storageDirectory { return d }
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return Self.defaultStorage(applicationSupport: base, bundleID: Bundle.main.bundleIdentifier,
                                       processName: ProcessInfo.processInfo.processName)
        }

        /// `Application Support/QuranLab` on iOS. On macOS `Application Support/<bundle id>/QuranLab`: a Mac app
        /// outside the sandbox shares `~/Library/Application Support` with every other app, and two apps using the SDK
        /// must not share an outbox, tokens or a contributor code.
        static func defaultStorage(applicationSupport base: URL, bundleID: String?, processName: String) -> URL {
            #if os(macOS)
            let raw = (bundleID?.isEmpty == false ? bundleID! : processName)
            let name = String(raw.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" }.prefix(128))
            return base.appendingPathComponent(name.isEmpty ? "unknown" : name, isDirectory: true)
                .appendingPathComponent("QuranLab", isDirectory: true)
            #else
            return base.appendingPathComponent("QuranLab", isDirectory: true)
            #endif
        }
    }

    private static let state = Locked(Configuration(key: nil, options: Options(cloud: nil)))
    private static let cloudState = Locked<QuranLabCloud?>(nil)

    /// Configure once at launch with the app's developer key (sdk.quranlab.ai). The launch sequence runs in the
    /// background at utility priority: token, registration, the signed config (then every 60 s while a recognizer is
    /// in use and at each foreground), the telemetry and issues that are due, the sharing outbox, and the update check
    /// of a build this Client installed (never a first download: that waits for `model()` or `prefetch()`). Nothing in
    /// the recognition path waits on it.
    static func configure(key: String? = nil, options: Options = Options()) {
        state.withLock { $0 = Configuration(key: key, options: options) }
        Contributions.reload()
        let storage = configuration.storageDirectory
        let cloud = options.cloud.map { _ in QuranLabCloud(key: key, options: options, storage: storage) }
        cloudState.withLock { $0 = cloud }
        // a shared recording still open from the configuration that ended here ends now: kept where sharing is still
        // on under this one, dropped otherwise (as a session that ran across a configure did before 2.0.3)
        Contributions.recorder.reset()
        if let cloud, key != nil {
            Task.detached(priority: .utility) { await cloud.launch() }
        }
    }

    static var configuration: Configuration { state.withLock { $0 } }

    /// The end of a Client (`TajweedClient.close()`): its server client stops (no network call, no upload pass, no
    /// timer of it runs on), an open shared recording ends, and the configuration goes back to none, so the next
    /// Client starts clean on the same storage.
    static func shutdown() {
        let old = cloudState.withLock { (c: inout QuranLabCloud?) -> QuranLabCloud? in
            defer { c = nil }
            return c
        }
        old?.shutdown()
        state.withLock { $0 = Configuration(key: nil, options: Options(cloud: nil)) }
        Contributions.reload()
        Contributions.recorder.reset()
    }

    /// Where the learner recited in a finished take (`session.reportRecited`), counted into the day's telemetry.
    static func reportRecited(surah: Int, ayahFrom: Int, ayahTo: Int) {
        cloud?.analytics.reportRecited(surah: surah, ayahFrom: ayahFrom, ayahTo: ayahTo)
    }

    /// One take's recited count (17.1, 17.9): the detector's range, else the app's report.
    static func countRecited(take: UInt64?, measured: CoreRecited?, report: SessionShared.Recited?, late: Bool) {
        guard let c = cloud else { return }
        c.analytics.count(take: take, measured: measured, report: report, late: late)
    }

    /// The app's own judge results (`client.analytics.reportChecks`), counted into the day's telemetry.
    static func reportChecks(rule: String, checked: Int, flagged: Int) {
        cloud?.analytics.reportChecks(rule: rule, checked: checked, flagged: flagged)
    }

    /// The server clients for the current configuration; nil when `options.cloud` is nil.
    static var cloud: QuranLabCloud? { cloudState.withLock { $0 } }

    /// The sharing outbox: each shared session's status. Nil when `options.cloud` is nil.
    static var contributions: ContributionOutbox? { cloud?.outbox }

    /// This install's contribution code (32 hex), sent with every shared session and shown to the learner in the
    /// sharing settings for deletion requests.
    /// Empty while the id on the device cannot be read (3.1.4): no new one is made in its place, and nothing is
    /// recorded or sent meanwhile.
    static var contributorID: String { Contributor.id(storage: configuration.storageDirectory) ?? "" }

    /// Starts a new contribution code; later shares are not linked to the earlier ones.
    static func resetContributor() { Contributor.reset(storage: configuration.storageDirectory) }

    /// The app delegate's `application(_:handleEventsForBackgroundURLSession:completionHandler:)`, forwarded: the
    /// public call is `TajweedClient.handleBackgroundEvents` (3.1.5; to 3.1.1 this was internal and no app could
    /// reach it). Returns false (and does not call `completionHandler`) when the session is not the SDK's.
    @discardableResult
    static func handleBackgroundEvents(identifier: String, completionHandler: @escaping @Sendable () -> Void) -> Bool {
        BackgroundEvents.handle(identifier: identifier, completionHandler: completionHandler)
    }

    /// For tests: a configuration whose cloud was made by the caller (stub network, fake App Attest).
    static func configure(key: String?, options: Options, cloud: QuranLabCloud?) {
        state.withLock { $0 = Configuration(key: key, options: options) }
        Contributions.reload()
        cloudState.withLock { $0 = cloud }
        Contributions.recorder.reset()
    }

    static func record(_ event: AnalyticsEvent) {
        // SDK 4.0: always on (anonymous by construction); the signed config's flags.analytics is the only off switch
        let c = configuration
        c.options.analyticsSink?.record(event)
        cloud?.record(event)
    }

    /// Counts a 2.0.1 telemetry counter (launches, the sharing sheet's asks and answers).
    static func count(_ c: AnalyticsStore.Counter) {
        cloud?.analytics.count(c)
    }

    /// Queues an accelerator incident report: through the Quran Lab client when the app configured one, else on the
    /// device (bounded, 7 days), sent once a client is configured with a key and the network is there. An app that
    /// never configures Quran Lab with a key never sends them (there is no key or token to send with).
    static func reportIncident(_ i: AcceleratorIncident) {
        if let cloud {
            cloud.reportIncident(i)
        } else {
            OfflineIncidents.queue(i, storage: configuration.storageDirectory)
        }
    }

    /// Queues an issue report for a fault (never for cancellation or misuse).
    static func report(_ error: RecognizerError, backend: ActiveBackend?, revision: String?, kind: String? = nil, code: String? = nil) {
        cloud?.report(error, kind: kind, code: code, backend: backend, revision: revision)
    }

    /// Checks for a model update now (for `UpdatePolicy.manual`, or a host's own schedule).
    static func checkForUpdate(_ id: ModelID = .recommended) async -> ModelUpdater.Outcome {
        guard let cloud else { return .deferred("no cloud configured") }
        if cloud.currentConfig == nil { _ = await cloud.refreshConfig() }
        return await cloud.checkForUpdate(id)
    }
}
