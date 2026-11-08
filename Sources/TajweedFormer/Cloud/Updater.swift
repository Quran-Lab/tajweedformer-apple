import Foundation
import Network

/// Installs and updates the model from the CDN: the revision the remote config names (or the pinned one), this
/// device's download profile only (`DownloadProfile`), resumable, every file verified, the CPU engine's weights
/// rebuilt from the CoreML package right after the download (so the CPU fallback is ready before the first session).
/// A first install activates at once; an update of a model in use becomes current at the next load.
public actor ModelUpdater {
    public enum Outcome: Sendable {
        /// The revision is current and the context's files are on disk.
        case upToDate(revision: String)
        /// Installed (and current, when asked to activate).
        case installed(TajweedModel, InstallReport)
        /// Downloaded and verified; it becomes current at the next load.
        case pending(revision: String)
        /// Not attempted now (policy: no Wi-Fi; no revision known yet). Tried again at the next check.
        case deferred(String)
        case failed(RecognizerError)
    }

    let store: ModelStore
    private let client: @Sendable () -> CDNClient?
    private let networkAllowed: @Sendable (_ firstInstall: Bool) async -> Bool
    private let coreML: Bool
    private let compact: Bool
    private let record: @Sendable (AnalyticsEvent) -> Void
    private let report: @Sendable (RecognizerError, String) -> Void
    private let rangeSize: Int64
    private var running: [String: Task<Outcome, Never>] = [:]

    init(store: ModelStore, client: @escaping @Sendable () -> CDNClient?, coreML: Bool = DownloadProfile.osRunsCoreML,
         compact: Bool = false, rangeSize: Int64 = 8 << 20,
         networkAllowed: @escaping @Sendable (_ firstInstall: Bool) async -> Bool,
         record: @escaping @Sendable (AnalyticsEvent) -> Void = { _ in },
         report: @escaping @Sendable (RecognizerError, String) -> Void = { _, _ in }) {
        self.store = store
        self.client = client
        self.coreML = coreML
        self.compact = compact
        self.rangeSize = rangeSize
        self.networkAllowed = networkAllowed
        self.record = record
        self.report = report
    }

    /// Brings `id` to CDN revision `cdnRevision` with `context`'s files (nil: the manifest's default context).
    /// Concurrent calls for the same model share one run.
    public func update(_ id: ModelID, to cdnRevision: String, context: String? = nil, activate: Bool) async -> Outcome {
        let key = id.name + "@" + cdnRevision + "#" + (context ?? "")
        if let t = running[key] { return await t.value }
        let t = Task { await self.run(id, cdnRevision, context, activate) }
        running[key] = t
        let out = await t.value
        running[key] = nil
        return out
    }

    private func run(_ id: ModelID, _ cdnRevision: String, _ context: String?, _ activate: Bool) async -> Outcome {
        let current = store.currentRevision(id)
        let currentDir = current.map { store.base(id).appendingPathComponent($0) }
        let isCurrent = current.map { store.sourceRevision(id, revision: $0) == cdnRevision || $0 == cdnRevision } ?? false
        if isCurrent, let dir = currentDir, let m = try? TajweedModel.open(directory: dir, verifier: store.verifier, expecting: id),
           m.isUsable(context: context ?? m.calibration.defaultContext),
           !wantsOtherBuild(m, context: context ?? m.calibration.defaultContext) {
            return activate ? .installed(m, InstallReport()) : .upToDate(revision: m.revision)
        }
        if !activate, let p = store.pendingRevision(id), store.sourceRevision(id, revision: p) == cdnRevision {
            return .pending(revision: p)
        }
        guard await networkAllowed(current == nil) else { return .deferred("waiting for an unmetered network") }
        guard let client = client() else { return .deferred("no developer key configured") }
        var report = InstallReport()
        var profileName = "apple-cpu"
        do throws(RecognizerError) {
            let (manifest, _) = try await client.manifest(id, revision: cdnRevision)
            let ctx = context ?? manifest.defaultContext
            guard manifest.contexts.contains(ctx) else { throw RecognizerError.invalidArgument("context \(ctx) is not in \(id) \(cdnRevision)") }
            let profile = DownloadProfile(context: ctx, coreML: coreML, compact: compact)
            if !profile.appleFiles(manifest).isEmpty { profileName = compact ? "apple-compact" : "apple-coreml" }
            let installer = ModelInstaller(source: client.source(id, revision: cdnRevision), rangeSize: rangeSize)
            let model: TajweedModel
            if isCurrent, let dir = currentDir {
                // another context of the model in use: its files go into the same folder
                report = try await installer.install(manifest, profile: profile, into: dir)
                model = try TajweedModel.open(directory: dir, verifier: store.verifier, expecting: id)
            } else {
                let folder = store.downloadFolder(id, cdnRevision: cdnRevision)
                report = try await installer.install(manifest, profile: profile, into: folder)
                model = try store.place(folder, id: id, cdnRevision: cdnRevision)
                if activate || current == nil { try store.activate(id, revision: model.revision) } else { try store.markPending(id, revision: model.revision) }
            }
            record(.download(revision: cdnRevision, profile: profileName, bytes: report.downloadedBytes, success: true, resumed: report.resumed))
            if let why = report.correctionFallback { record(.correctionFallback(reason: why)) }
            if activate || current == nil || isCurrent { return .installed(model, report) }
            return .pending(revision: model.revision)
        } catch {
            if case .offline = error { return .deferred("offline: \(error)") }
            if case .insufficientStorage = error { return .deferred(error.description) }
            record(.download(revision: cdnRevision, profile: profileName, bytes: report.downloadedBytes, success: false, resumed: report.resumed))
            self.report(error, cdnRevision)
            return .failed(error)
        }
    }

    /// The model on disk has the other CoreML build (or none) while this install wants one the folder ships: the profile
    /// changed (`QuranLab.Options.compactCoreML`), so the install runs again (and deletes the other build).
    private func wantsOtherBuild(_ m: TajweedModel, context: String) -> Bool {
        guard coreML else { return false }
        let p = DownloadProfile(context: context, coreML: true, compact: compact)
        guard !p.appleFiles(m.manifest).isEmpty else { return false }
        return m.coreML(context: context)?.compact != compact
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
