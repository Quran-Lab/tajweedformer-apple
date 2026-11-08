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
    let store: ModelStore
    public let updater: ModelUpdater
    /// Shared sessions waiting to upload, and the receipts of those that went.
    public let outbox: ContributionOutbox
    private let lastFlushDay = Locked<String?>(nil)
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
        let store = ModelStore(root: storage.appendingPathComponent("models"),
                               verifier: ManifestVerifier(trustedKeys: cloud.signingKeys, requireSignature: options.requireSignedModels),
                               updates: options.updates)
        self.store = store
        let wifiOnly = cloud.updatesOnWiFiOnly
        let analytics = self.analytics, issues = self.issues
        let issueContext = (app: app, enabled: cloud.issueReports)
        let cdn = CDNClient(http: http, cdnURL: cloud.cdnURL, key: key ?? "",
                            verifier: ManifestVerifier(trustedKeys: cloud.signingKeys, requireSignature: true))
        let hasKey = key != nil
        let telemetryOn = options.analytics != .off
        updater = ModelUpdater(store: store, client: { hasKey ? cdn : nil },
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

    /// The launch sequence, at utility priority: registration, the config, the uploads due (telemetry, issues, the
    /// sharing outbox), then the model update check. Each step is independent; whatever was not sent stays queued.
    public func launch() async {
        _ = await register()
        let cfg = await refreshConfig() ?? config.current
        await flush()
        outbox.resume()
        observeForeground()
        guard updates != .manual else { return }
        if let r = cfg?.recommended { RecommendedModel.remember(r, storage: storage) }
        _ = await checkForUpdate(.recommended)
    }

    private var installedMarker: URL { storage.appendingPathComponent("cloud/installed") }
    private var pendingRegistration: JSONFile<[String: Bool]> { JSONFile(url: storage.appendingPathComponent("cloud/register-pending.json")) }

    /// `POST /v1/register`, at most once per launch. The new-install flag comes from a first-launch marker on disk
    /// (a flag, not an id); a registration that cannot be sent now is sent at the next launch with the flag kept.
    @discardableResult
    public func register() async -> Bool {
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

    private func observeForeground() {
        #if canImport(UIKit) && !os(watchOS)
        let name = Notification.Name("UIApplicationWillEnterForegroundNotification")
        #else
        let name = Notification.Name("NSApplicationDidBecomeActiveNotification")
        #endif
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.noteActivity()
            Task.detached(priority: .utility) { await self.flush() }
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
        if case .sessionFinished = event { flushIfNewDay() }
    }

    private func flushIfNewDay() {
        let today = Day.string()
        let due = lastFlushDay.withLock { d -> Bool in
            if d == today { return false }
            d = today
            return true
        }
        if due { Task.detached(priority: .utility) { await self.flush() } }
    }

    /// Sends the complete days of telemetry and the queued issues; the config's kill switches drop the queues.
    @discardableResult
    public func flush(includingToday: Bool = false) async -> (events: Int, issues: Int) {
        lastFlushDay.withLock { $0 = Day.string() }
        let flags = config.current?.flags ?? RemoteConfig.Flags()
        if !flags.analytics { analytics.dropAll() }
        if !flags.issues { issues.dropAll() }
        guard key != nil, !isStopped else { return (0, 0) }
        var events = 0, sentIssues = 0
        if analyticsOn && flags.analytics {
            events = await analytics.flush(send: { (d: Data) async throws(CloudError) -> Void in
                _ = try await self.authed { (token: String) throws(CloudError) -> URLRequest in
                    var r = try HTTPClient.jsonRequest(self.options.apiURL.appendingPathComponent("v1/events"), body: nil, auth: token)
                    r.httpBody = d
                    r.setValue("application/json", forHTTPHeaderField: "content-type")
                    return r
                }
            }, force: includingToday)
        }
        if options.issueReports && flags.issues {
            sentIssues = await sendIssues()
        }
        return (events, sentIssues)
    }

    private func sendIssues() async -> Int {
        await issues.flush(send: { (d: Data) async throws(CloudError) -> Void in
            _ = try await self.authed { (token: String) throws(CloudError) -> URLRequest in
                var r = try HTTPClient.jsonRequest(self.options.apiURL.appendingPathComponent("v1/issues"), body: nil, auth: token)
                r.httpBody = d
                r.setValue("application/json", forHTTPHeaderField: "content-type")
                return r
            }
        })
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
