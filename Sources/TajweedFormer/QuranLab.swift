import Foundation

/// How models are kept up to date (see `ModelUpdater`).
public enum UpdatePolicy: Sendable, Hashable {
    /// Follow the channel or pin set in the portal.
    case automatic
    /// Always this CDN revision.
    case pinned(String)
    /// Never update on its own (`QuranLab.checkForUpdate()` does it on request).
    case manual
}

/// Anonymous telemetry (daily aggregates and histograms, never audio, text or identifiers). On by default; the
/// signed config's `flags.analytics` can turn it off for every install of the app.
public enum AnalyticsLevel: Sendable, Hashable {
    case on
    case off
}

/// The SDK's entry point: configure once at launch, then load a model and make a recognizer.
public enum QuranLab {
    public struct Options: Sendable {
        /// Where models are looked for, in order.
        public var modelSource: [ModelSource]
        public var updates: UpdatePolicy
        /// Telemetry: on by default, anonymous by construction.
        public var analytics: AnalyticsLevel
        /// An extra sink for every analytics event, besides the SDK's own daily aggregates.
        public var analyticsSink: (any AnalyticsSink)?
        /// Refuse a model whose manifest is not signed by a trusted key. Off by default so a folder you staged yourself
        /// loads; a signed manifest is always verified, and CDN downloads are always signed.
        public var requireSignedModels: Bool
        /// Where the SDK keeps models, the backend verdicts and its queues; nil means `Application Support/QuranLab`
        /// (on macOS `Application Support/<bundle id>/QuranLab`).
        public var storageDirectory: URL?
        /// Quran Lab's servers. Nil: the SDK never contacts a server (models from the bundle, a directory or the store).
        public var cloud: CloudOptions?
        /// Ignored since 2.0.1: whether the SDK offers recording sharing (its own consent sheet, then every session in
        /// full for a learner who said "Share") is Quran Lab's decision per app, in the signed config.
        public var contributions: Bool
        /// The app's audience: `.children` shows the parent or guardian variant of the consent sheet.
        public var audience: Audience
        /// The language of the SDK's sharing copy; nil follows the device.
        public var sharingLocale: Locale?
        /// Download the CoreML package (iOS 18 / macOS 15) as well as the CPU set. Off: CPU only, a smaller download.
        public var neuralEngine: Bool
        /// The compact CoreML build (int8 weights, about half the download) instead of the default fp16 one: for
        /// low-storage devices; slightly less accurate. Changing it replaces the build on disk at the next install.
        public var compactCoreML: Bool

        public init(modelSource: [ModelSource] = [.bundle, .cache, .cdn],
                    updates: UpdatePolicy = .automatic,
                    analytics: AnalyticsLevel = .on,
                    analyticsSink: (any AnalyticsSink)? = nil,
                    requireSignedModels: Bool = false,
                    storageDirectory: URL? = nil,
                    cloud: CloudOptions? = CloudOptions(),
                    contributions: Bool = false,
                    audience: Audience = .general,
                    sharingLocale: Locale? = nil,
                    neuralEngine: Bool = true,
                    compactCoreML: Bool = false) {
            self.modelSource = modelSource
            self.updates = updates
            self.analytics = analytics
            self.analyticsSink = analyticsSink
            self.requireSignedModels = requireSignedModels
            self.storageDirectory = storageDirectory
            self.cloud = cloud
            self.contributions = contributions
            self.audience = audience
            self.sharingLocale = sharingLocale
            self.neuralEngine = neuralEngine
            self.compactCoreML = compactCoreML
        }
    }

    public struct Configuration: Sendable {
        public var key: String?
        public var options: Options

        public var storageDirectory: URL {
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

    /// Configure once at launch with the app's developer key (portal.quranlab.ai). The launch sequence runs in the
    /// background at utility priority: token, registration, the signed config (then every 60 s while a recognizer is
    /// in use and at each foreground), the telemetry and issues that are due, the sharing outbox, and the model
    /// update check. Nothing in the recognition path waits on it.
    public static func configure(key: String? = nil, options: Options = Options()) {
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

    public static var configuration: Configuration { state.withLock { $0 } }

    /// The server clients for the current configuration; nil when `options.cloud` is nil.
    public static var cloud: QuranLabCloud? { cloudState.withLock { $0 } }

    /// The sharing outbox: each shared session's status. Nil when `options.cloud` is nil.
    public static var contributions: ContributionOutbox? { cloud?.outbox }

    /// This install's contribution code (32 hex), sent with every shared session and shown to the learner in the
    /// sharing settings for deletion requests.
    public static var contributorID: String { Contributor.id(storage: configuration.storageDirectory) }

    /// Starts a new contribution code; later shares are not linked to the earlier ones.
    public static func resetContributor() { Contributor.reset(storage: configuration.storageDirectory) }

    /// Forward the app delegate's `application(_:handleEventsForBackgroundURLSession:completionHandler:)` here.
    /// Returns false (and does not call `completionHandler`) when the session is not the SDK's.
    @discardableResult
    public static func handleBackgroundEvents(identifier: String, completionHandler: @escaping @Sendable () -> Void) -> Bool {
        guard identifier.hasPrefix("ai.quranlab.contributions.") else { return false }
        let uploader = BackgroundUploader.existing(identifier) ?? {
            _ = cloud?.outbox
            return BackgroundUploader.existing(identifier)
        }()
        guard let uploader else { return false }
        uploader.setFinishedHandler(completionHandler)
        return true
    }

    /// For tests: a configuration whose cloud was made by the caller (stub network, fake App Attest).
    static func configure(key: String?, options: Options, cloud: QuranLabCloud?) {
        state.withLock { $0 = Configuration(key: key, options: options) }
        Contributions.reload()
        cloudState.withLock { $0 = cloud }
        Contributions.recorder.reset()
    }

    static func record(_ event: AnalyticsEvent) {
        let c = configuration
        guard c.options.analytics != .off else { return }
        c.options.analyticsSink?.record(event)
        cloud?.record(event)
    }

    /// Counts a 2.0.1 telemetry counter (launches, the sharing sheet's asks and answers).
    static func count(_ c: AnalyticsStore.Counter) {
        guard configuration.options.analytics != .off else { return }
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
    public static func checkForUpdate(_ id: ModelID = .recommended) async -> ModelUpdater.Outcome {
        guard let cloud else { return .deferred("no cloud configured") }
        if cloud.currentConfig == nil { _ = await cloud.refreshConfig() }
        return await cloud.checkForUpdate(id)
    }
}
