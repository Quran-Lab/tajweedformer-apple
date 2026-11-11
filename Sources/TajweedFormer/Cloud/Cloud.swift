import Foundation

/// Everything the SDK does with Quran Lab's servers, for one configuration: the token, the launch
/// registration, the signed config, the telemetry and issue queues, model installs and updates, and recording
/// sharing. Made by `QuranLab.configure`. Nothing here sits in the recognition path: the recognizer only records
/// counters (a lock and an addition) and reads the cached config.
public final class QuranLabCloud: Sendable {
    public let options: CloudOptions
    let key: String?
    let app: AppIdentity
    let storage: URL
    let analyticsOn: Bool
    let updates: UpdatePolicy
    let http: HTTPClient
    let tokens: TokenProvider?
    let config: ConfigStore
    let analytics: AnalyticsStore
    let issues: IssueQueue
    /// Accelerator incidents: the first of each kind per revision, kept until accepted, and the daily dedupe.
    let incidents: IncidentLedger
    let store: ModelStore
    public let updater: ModelUpdater
    /// Shared sessions waiting to upload, and the receipts of those that went.
    public let outbox: ContributionOutbox
    let clock: @Sendable () -> Date
    /// When the last telemetry delta was sealed (every send point resets the 15 minutes).
    private let lastSeal: Locked<Date>
    private let deltaTimer = Locked<Task<Void, Never>?>(nil)
    private struct Lifecycle {
        var background = false
        var observing = false
    }
    private let lifecycle = Locked(Lifecycle())
    private let stopped = Locked(false)
    private let signatureReported = Locked<String?>(nil)

    init(key: String?, options: QuranLab.Options, storage: URL,
         attester: any AppAttesting = DeviceCheckAttester(),
         attestKeys: any AttestKeyStoring = KeychainAttestKeyStore(),
         networkAllowed: (@Sendable (Bool) async -> Bool)? = nil,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        let cloud = options.cloud ?? CloudOptions()
        self.options = cloud
        self.key = key
        self.storage = storage
        self.analyticsOn = options.analytics != .off
        self.updates = options.updates
        self.clock = clock
        lastSeal = Locked(clock())
        let app = cloud.app ?? .main
        self.app = app
        let http = HTTPClient(session: cloud.urlSession ?? HTTPClient.makeSession())
        self.http = http
        tokens = key.map {
            TokenProvider(http: http, apiURL: cloud.apiURL, key: $0, app: app, teamID: cloud.appleTeamID,
                          attester: attester, attestKeys: attestKeys, storage: storage)
        }
        let config = ConfigStore(storage: storage, trustedKeys: cloud.signingKeys)
        self.config = config
        outbox = ContributionOutbox(storage: storage, http: http, apiURL: cloud.apiURL, tokens: tokens, config: config,
                                    options: cloud, app: app, clock: clock)
        analytics = AnalyticsStore(storage: storage, enabled: options.analytics != .off,
                                   context: .init(platform: app.platform, sdkVersion: SDKInfo.version, appVersion: app.version,
                                                  deviceClass: DeviceContext.deviceClass, soc: DeviceContext.soc,
                                                  osMajor: DeviceContext.osMajor, ramTier: DeviceContext.ramTier),
                                   clock: clock)
        issues = IssueQueue(storage: storage)
        incidents = IncidentLedger(storage: storage)
        let store = ModelStore(root: storage.appendingPathComponent("models"),
                               verifier: ManifestVerifier(trustedKeys: cloud.signingKeys, requireSignature: options.requireSignedModels),
                               updates: options.updates)
        self.store = store
        let wifiOnly = cloud.updatesOnWiFiOnly
        let analytics = self.analytics, issues = self.issues
        let issueContext = (app: app, enabled: cloud.issueReports)
        let explicitBase = cloud.cdnURL
        let cdnKey = key
        let cdnVerifier = ManifestVerifier(trustedKeys: cloud.signingKeys, requireSignature: true)
        let telemetryOn = options.analytics != .off
        updater = ModelUpdater(store: store, client: {
            guard let cdnKey else { return nil }
            return CDNClient(http: http, base: ModelHost.base(explicit: explicitBase, config: config.current), key: cdnKey, verifier: cdnVerifier)
        },
                               coreML: DownloadProfile.osRunsCoreML && options.neuralEngine, compact: options.compactCoreML,
                               rangeSize: cloud.rangeSize,
                               networkAllowed: networkAllowed ?? { first in
                                   // the first install (no model yet) goes on any network: the app cannot work without it
                                   if first || !wifiOnly { return true }
                                   return await ModelUpdater.onUnmeteredNetwork()
                               },
                               record: { e in if telemetryOn { analytics.record(e) } },
                               report: { e, rev in
                                   guard issueContext.enabled else { return }
                                   issues.add(QuranLabCloud.issue(kind: "update_failed", code: "update:" + (IssueQueue.classify(e)?.code ?? "other"),
                                                                  app: issueContext.app, backend: nil, revision: rev))
                               })
    }

    /// Network calls are off for this launch (a revoked key, a blocked app, an SDK too old for the key).
    var isStopped: Bool { stopped.withLock { $0 } }

    private func stopIfFatal(_ e: CloudError) {
        guard case .rejected(let status, let code, _) = e else { return }
        let fatal = ["invalid_key", "unauthorized", "developer_not_approved", "not_a_member", "key_type_mismatch",
                     "origin_not_allowed", "app_not_allowed", "app_blocked", "environment_mismatch", "sdk_too_old"]
        if (status == 401 || status == 403) && fatal.contains(code) { stopped.withLock { $0 = true } }
    }

    // MARK: launch

    /// The launch sequence, at utility priority: registration (once a UTC day), the config, the uploads due (this
    /// launch's telemetry delta and any left from earlier runs, issues, the sharing outbox), then the model update
    /// check. Each step is independent; whatever was not sent stays queued. From here a telemetry delta goes every 15
    /// minutes while the app is in use and when it goes to the background.
    public func launch() async {
        analytics.count(.launch)
        _ = await register()
        let cfg = await refreshConfig() ?? config.current
        await flush()
        outbox.resume()
        observeLifecycle()
        startDeltaTimer()
        guard updates != .manual else { return }
        if let r = cfg?.recommended { RecommendedModel.remember(r, storage: storage) }
        _ = await checkForUpdate(.recommended)
    }

    private var installedMarker: URL { storage.appendingPathComponent("cloud/installed") }
    /// The UTC day of the last registration the server answered 200.
    private var registeredDay: URL { storage.appendingPathComponent("cloud/registered-day") }
    private var pendingRegistration: JSONFile<[String: Bool]> { JSONFile(url: storage.appendingPathComponent("cloud/register-pending.json")) }

    /// `POST /v1/register`, once per UTC day per install (2.0.1: the first launch or return to the foreground of the
    /// day, a day stamp written only after a 200; launches are counted in telemetry). The new-install flag comes from
    /// a first-launch marker on disk (a flag, not an id); a registration that cannot be sent now is sent at the next
    /// launch or foreground with the flag kept. Returns whether it was sent now (false when this install already
    /// registered today).
    @discardableResult
    public func register() async -> Bool {
        let today = Day.string(clock())
        if (try? String(contentsOf: registeredDay, encoding: .utf8)) == today { return false }
        let fm = FileManager.default
        let isNew = !fm.fileExists(atPath: installedMarker.path)
        if isNew {
            try? fm.createDirectory(at: installedMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: installedMarker.path, contents: Data())
        }
        let newInstall = isNew || (pendingRegistration.read()?["new_install"] ?? false)
        pendingRegistration.write(["new_install": newInstall])
        guard key != nil, !isStopped else { return false }
        var body: [String: Any] = ["platform": app.platform, "bundle_id": app.bundleID, "app_version": app.version,
                                   "sdk_version": SDKInfo.version, "new_install": newInstall]
        if let n = app.name, !n.isEmpty { body["app_name"] = n }
        if let rev = store.currentRevision(.v4_0) { body["model_revision"] = String(rev.prefix(64)) }
        do throws(CloudError) {
            _ = try await authed { (token: String) throws(CloudError) -> URLRequest in
                try HTTPClient.jsonRequest(self.options.apiURL.appendingPathComponent("v1/register"), body: body, auth: token)
            }
            pendingRegistration.delete()
            try? Data(today.utf8).write(to: registeredDay, options: .atomic)
            return true
        } catch {
            stopIfFatal(error)
            if !error.retryable { pendingRegistration.delete() }
            return false
        }
    }

    /// Fetches and verifies the config; nil (keeping the last verified one) when that fails. A body that does not
    /// verify is reported once a day (`signature_invalid`).
    @discardableResult
    public func refreshConfig() async -> RemoteConfig? {
        guard let tokens, !isStopped else { return nil }
        do throws(CloudError) {
            let t = try await tokens.token()
            do throws(CloudError) {
                return try await config.fetch(http: http, apiURL: options.apiURL, token: t.token)
            } catch {
                guard case .rejected(401, _, _) = error else { throw error }
                await tokens.invalidate()
                return try await config.fetch(http: http, apiURL: options.apiURL, token: try await tokens.token().token)
            }
        } catch {
            stopIfFatal(error)
            if case .invalid(let why) = error, why.contains("sign") {
                let today = Day.string()
                let first = signatureReported.withLock { d -> Bool in defer { d = today }; return d != today }
                if first { report(.signatureInvalid, backend: nil, revision: nil) }
            }
            return nil
        }
    }

    public var currentConfig: RemoteConfig? { config.current }

    /// While the app is in use: the config again when the last fetch is a minute old (portal changes apply within a
    /// minute; settings take effect at the next take). Called at every take start and foreground.
    func noteActivity() {
        let last = config.lastFetch.withLock { $0 }
        guard last.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        config.lastFetch.withLock { $0 = Date() }
        Task.detached(priority: .utility) { _ = await self.refreshConfig() }
    }

    /// The app's return to the foreground and its going to the background (iOS: enter foreground and background; macOS:
    /// becoming and resigning active).
    private func observeLifecycle() {
        let first = lifecycle.withLock { (l: inout Lifecycle) -> Bool in
            defer { l.observing = true }
            return !l.observing
        }
        guard first else { return }
        #if canImport(UIKit) && !os(watchOS)
        let foreground = Notification.Name("UIApplicationWillEnterForegroundNotification")
        let background = Notification.Name("UIApplicationDidEnterBackgroundNotification")
        #else
        let foreground = Notification.Name("NSApplicationDidBecomeActiveNotification")
        let background = Notification.Name("NSApplicationDidResignActiveNotification")
        #endif
        NotificationCenter.default.addObserver(forName: foreground, object: nil, queue: nil) { [weak self] _ in self?.cameToForeground() }
        NotificationCenter.default.addObserver(forName: background, object: nil, queue: nil) { [weak self] _ in self?.wentToBackground() }
    }

    /// A return to the foreground: a launch for telemetry, the day's registration if not done yet, the config, the
    /// telemetry delta and the queues, and the 15-minute timer again. Takes in a row join one shared recording again.
    func cameToForeground() {
        Contributions.recorder.foreground()
        let returning = lifecycle.withLock { (l: inout Lifecycle) -> Bool in
            defer { l.background = false }
            return l.background
        }
        if returning { analytics.count(.launch) }
        startDeltaTimer()
        noteActivity()
        Task.detached(priority: .utility) {
            _ = await self.register()
            await self.flush()
        }
    }

    /// The app went to the background: a telemetry delta now (saved before it is sent, so one the system cuts short
    /// goes at the next send point), and no timer while in the background. On the Mac, where the app resigns active at
    /// every switch to another app, at most one a minute. A shared recording that waits for the next take closes
    /// (2.0.3; a take that is running keeps its recording until it ends).
    func wentToBackground() {
        Contributions.recorder.background()
        lifecycle.withLock { $0.background = true }
        deltaTimer.withLock { t in
            t?.cancel()
            t = nil
        }
        #if os(macOS)
        let recent = clock().timeIntervalSince(lastSeal.withLock { $0 }) < 60
        if recent { return }
        #endif
        Task.detached(priority: .utility) { await self.flush() }
    }

    /// Telemetry deltas while the app is in use: one every 15 minutes (also at the SDK's next recorded event when the
    /// timer was late), and retries of unsent ones after their backoff.
    static let deltaInterval: TimeInterval = 15 * 60

    /// Claims the 15-minute send point when it is due (the app in use, the last delta 15 minutes old, or an unsent one
    /// due for a retry).
    func claimDelta() -> Bool {
        guard !lifecycle.withLock({ $0.background }) else { return false }
        let now = clock()
        let retry = analytics.retryDue(now)
        return lastSeal.withLock { (last: inout Date) -> Bool in
            guard now.timeIntervalSince(last) >= Self.deltaInterval || retry else { return false }
            last = now
            return true
        }
    }

    /// The 15-minute send point now if it is due; true when a delta went out (or was tried).
    @discardableResult
    func tick() async -> Bool {
        guard claimDelta() else { return false }
        await flush()
        return true
    }

    private func startDeltaTimer() {
        let t = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
        deltaTimer.withLock { old in
            old?.cancel()
            old = t
        }
    }

    /// Sends a request with the token, getting a new token once after a 401.
    func authed(_ make: (String) throws(CloudError) -> URLRequest) async throws(CloudError) -> HTTPClient.Response {
        guard let tokens else { throw .noKey }
        guard !isStopped else { throw .offline("stopped for this launch") }
        let t = try await tokens.token()
        do throws(CloudError) {
            return try await http.checked(try make(t.token))
        } catch {
            guard case .rejected(401, _, _) = error else { throw error }
            await tokens.invalidate()
            return try await http.checked(try make(try await tokens.token().token))
        }
    }

    // MARK: telemetry and issues

    func record(_ event: AnalyticsEvent) {
        analytics.record(event)
        // the SDK's next call is a send point too, when the timer was late (a suspended app)
        if claimDelta() { Task.detached(priority: .utility) { await self.flush() } }
    }

    /// A telemetry send point: seals what was counted since the last delta (per UTC day, a fresh report id each) and
    /// sends every unsent delta, oldest first; then the queued issues. The config's kill switches drop the queues.
    /// `includingToday` is kept for source compatibility: since 2.0.1 every flush includes today.
    @discardableResult
    public func flush(includingToday: Bool = false) async -> (events: Int, issues: Int) {
        lastSeal.withLock { $0 = clock() }
        let flags = config.current?.flags ?? RemoteConfig.Flags()
        if !flags.analytics { analytics.dropAll() }
        if !flags.issues { issues.dropAll() }
        guard key != nil, !isStopped else { return (0, 0) }
        var events = 0, sentIssues = 0
        if analyticsOn && flags.analytics {
            events = await analytics.flush(send: { (d: Data) async throws(CloudError) -> Void in
                do throws(CloudError) {
                    _ = try await self.authed { (token: String) throws(CloudError) -> URLRequest in
                        var r = try HTTPClient.jsonRequest(self.options.apiURL.appendingPathComponent("v1/events"), body: nil, auth: token)
                        r.httpBody = d
                        r.setValue("application/json", forHTTPHeaderField: "content-type")
                        return r
                    }
                } catch {
                    // a body the server refuses is the SDK's bug: dropped, and reported (kind and code only)
                    if case .rejected(400, _, _) = error {
                        self.report(.serverRejected(status: 400, code: "bad_request", message: ""), kind: "other", code: "bad_request:events",
                                    backend: nil, revision: nil)
                    }
                    throw error
                }
            })
        }
        if options.issueReports {
            // the first accelerator incident of each kind per revision goes whatever flags.issues says
            sentIssues = await sendIssues(regular: flags.issues)
        }
        return (events, sentIssues)
    }

    func sendIssues(regular: Bool = true) async -> Int {
        let send = { (d: Data) async throws(CloudError) -> Void in
            _ = try await self.authed { (token: String) throws(CloudError) -> URLRequest in
                var r = try HTTPClient.jsonRequest(self.options.apiURL.appendingPathComponent("v1/issues"), body: nil, auth: token)
                r.httpBody = d
                r.setValue("application/json", forHTTPHeaderField: "content-type")
                return r
            }
        }
        var n = await incidents.flush(send: send)
        if regular { n += await issues.flush(send: send) }
        return n
    }

    static func issue(kind: String, code: String, app: AppIdentity, backend: ActiveBackend?, revision: String?) -> IssueReport {
        let rev = revision.map { String($0.filter { $0.isLetter || $0.isNumber || "._+@-".contains($0) }.prefix(64)) }
        return IssueReport(day: Day.string(), platform: app.platform, sdk_version: SDKInfo.version, app_version: app.version,
                           os_version: DeviceContext.osVersionString, device_class: DeviceContext.deviceClass,
                           backend: backend?.telemetryName, revision: rev?.isEmpty == false ? rev : nil,
                           kind: kind, code: String(code.filter { $0.isLetter || $0.isNumber || "_.:-".contains($0) }.prefix(64)))
    }

    /// Queues an issue report (kind, code, backend, revision, device class, OS and SDK version only; never a message)
    /// and sends the queue shortly after, off the caller's path.
    func report(_ error: RecognizerError, kind: String? = nil, code: String? = nil, backend: ActiveBackend?, revision: String?) {
        guard options.issueReports, config.current?.flags.issues ?? true else { return }
        guard let c = IssueQueue.classify(error) ?? (kind.map { ($0, code ?? "other") }) else { return }
        issues.add(Self.issue(kind: kind ?? c.kind, code: code ?? c.code, app: app, backend: backend, revision: revision))
        guard key != nil else { return }
        Task.detached(priority: .utility) { [self] in _ = await sendIssues() }
    }

    // MARK: config effects

    /// The backend the deny-list forces on this install for `revision`, with its reason.
    public func forcedBackend(revision: String) -> (backend: ActiveBackend, reason: String)? {
        guard let rule = config.current?.denyRule(platform: app.platform, osVersion: DeviceContext.osVersionString,
                                                  deviceClass: DeviceContext.deviceClass, sdkVersion: SDKInfo.version,
                                                  modelRevision: revision) else { return nil }
        let b: ActiveBackend = rule.backend_forced == "neuralEngine" ? .neuralEngine : .exact
        return (b, "deny-listed" + (rule.reason.map { ": \($0)" } ?? ""))
    }

    /// The values `accel_deny` rules match (the same as an incident report's).
    func deviceValues(revision: String) -> [String: String] {
        var v = ["platform": app.platform, "os_version": DeviceContext.osVersionString, "os_build": DeviceInfo.osBuild,
                 "device_class": DeviceContext.deviceClass, "device_model": DeviceInfo.model, "model_revision": revision,
                 "sdk_version": SDKInfo.version]
        if let soc = DeviceContext.soc { v["chip"] = soc }
        return v
    }

    /// Why the signed config keeps the Neural Engine off for `revision` on this device, if it does: `denylist` with
    /// `backend_forced: exact`, or an `accel_deny` rule for the `ane` kind. Read at every check (every verified config).
    public func acceleratorDenied(revision: String, kind: String = "ane") -> String? {
        if let f = forcedBackend(revision: revision), f.backend == .exact { return f.reason }
        guard let r = config.current?.accelDenyRule(values: deviceValues(revision: revision), kind: kind) else { return nil }
        if let reason = r.reason { SDKLatest.debugOnly("accel_deny: \(reason)") }
        return "accel_deny" + (r.reason.map { ": \($0)" } ?? "")
    }

    /// The CDN revision this install should run: the local pin, else the config's (portal pin, or the channel's
    /// release with the staged rollout applied by the server).
    public func targetRevision(_ id: ModelID) -> String? {
        if case .pinned(let r) = updates { return r }
        guard let c = config.current else { return nil }
        if let r = c.recommended, r.model == id.repository { return r.revision }
        return c.models[id.repository]?.revision
    }

    /// Downloads, verifies and stages the target revision (see `ModelUpdater`); it becomes current at the next load.
    public func checkForUpdate(_ id: ModelID = .recommended) async -> ModelUpdater.Outcome {
        let id = id.isRecommended ? RecommendedModel.resolve(config: config.current, storage: storage) : id
        guard key != nil else { return .deferred("no developer key configured") }
        guard let target = targetRevision(id) else { return .deferred("no revision in the config yet") }
        return await updater.update(id, to: target, context: nil, activate: store.currentRevision(id) == nil)
    }

    /// Installs the model for `context` now (the first launch, or another context on demand), and activates it.
    func install(_ id: ModelID, context: String?, activate: Bool) async -> ModelUpdater.Outcome {
        guard key != nil else { return .deferred("no developer key configured") }
        if config.current == nil { _ = await refreshConfig() }
        guard let target = targetRevision(id) else { return .deferred("no revision in the config yet") }
        let ctx = context ?? RemoteTajweedBlock.parse(config.current?.tajweed).block?.context
        return await updater.update(id, to: target, context: ctx, activate: activate)
    }

    // MARK: sharing routes for the learner

    /// The app id the server knows this install's app by ("ios:<bundle id>").
    var appID: String { "\(app.platform):\(app.bundleID)" }

    /// "Delete what I shared": a single-use nonce from `POST /v1/contributions/challenge`,
    /// the deletion message signed with the device key, `POST /v1/contributions/delete`. No app credential is sent
    /// (the server refuses one). 202 is the server's answer whatever the signature (no enumeration); the purge runs
    /// within seconds. One retry with a new nonce on `nonce_invalid`.
    func deleteContributions(contributor: String) async throws(RecognizerError) {
        guard let key = ContributorKey.key(storage: storage) else { throw .contributionUnavailable("no device key on this install") }
        for attempt in 0..<2 {
            do throws(CloudError) {
                let ch = try await http.checked(try HTTPClient.jsonRequest(options.apiURL.appendingPathComponent("v1/contributions/challenge"),
                                                                           body: ["app": appID, "contributor": contributor], auth: nil))
                guard let o = (try? JSONSerialization.jsonObject(with: ch.body)) as? [String: Any], let nonce = o["nonce"] as? String else {
                    throw CloudError.invalid("no nonce")
                }
                let ts = Int(Date().timeIntervalSince1970)
                let message = ContributorKey.deletionMessage(app: appID, contributor: contributor, nonce: nonce, timestamp: ts)
                let sig: Data
                do { sig = try key.sign(message) } catch { throw CloudError.invalid("signing failed") }
                _ = try await http.checked(try HTTPClient.jsonRequest(options.apiURL.appendingPathComponent("v1/contributions/delete"),
                                                                      body: ["app": appID, "contributor": contributor, "nonce": nonce,
                                                                             "timestamp": ts, "action": "delete-all",
                                                                             "signature": sig.base64URL], auth: nil))
                return
            } catch {
                if attempt == 0, case .rejected(401, let code, _) = error, code == "nonce_invalid" { continue }
                throw error.recognizerError
            }
        }
    }

    /// `GET /v1/contributions/summary`; nil on any failure.
    func contributionSummary(contributor: String) async -> ContributionSummary? {
        guard let r = try? await authed({ (token: String) throws(CloudError) -> URLRequest in
            var r = try HTTPClient.jsonRequest(self.options.apiURL.appendingPathComponent("v1/contributions/summary"), method: "GET",
                                               body: nil, auth: token)
            r.setValue(contributor, forHTTPHeaderField: "x-qlab-contributor")
            return r
        }), let o = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any],
              let you = o["you"] as? [String: Any], let all = o["all"] as? [String: Any] else { return nil }
        let app = o["app"] as? [String: Any]
        return ContributionSummary(mySessions: (you["sessions"] as? Int) ?? 0, myMinutes: (you["minutes"] as? Double) ?? 0,
                                   appContributors: app?["contributors"] as? Int, appMinutes: app?["minutes"] as? Double,
                                   allContributors: (all["contributors"] as? Int) ?? 0, allMinutes: (all["minutes"] as? Double) ?? 0)
    }
}
