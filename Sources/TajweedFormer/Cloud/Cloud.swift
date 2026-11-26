import Foundation

/// Everything the SDK does with Quran Lab's servers, for one configuration: the token, the launch
/// registration, the signed config, the telemetry and issue queues, model installs and updates, and recording
/// sharing. Made by `QuranLab.configure`. Nothing here sits in the recognition path: the recognizer only records
/// counters (a lock and an addition) and reads the cached config.
final class QuranLabCloud: Sendable {
    let options: CloudOptions
    let key: String?
    let app: AppIdentity
    let storage: URL
    let updates: UpdatePolicy
    let http: HTTPClient
    /// SDK 4.0.1 (section 28): the roles' hosts and the sticky host of each.
    let endpoints: EndpointSet
    let tokens: TokenProvider?
    /// SDK 4.0.5 (API_40 37.5 item 3): this is the install's first launch (no marker of an earlier start was found).
    let firstLaunch: Bool
    let config: ConfigStore
    let analytics: AnalyticsStore
    let issues: IssueQueue
    /// Accelerator incidents: the first of each kind per revision, kept until accepted, and the daily dedupe.
    let incidents: IncidentLedger
    let store: ModelStore
    let updater: ModelUpdater
    /// Shared sessions waiting to upload, and the receipts of those that went.
    let outbox: ContributionOutbox
    let clock: @Sendable () -> Date
    /// When the last telemetry delta was sealed (every send point resets the 15 minutes).
    private let lastSeal: Locked<Date>
    private let deltaTimer = Locked<Task<Void, Never>?>(nil)
    private struct Lifecycle {
        var background = false
        var observing = false
        /// When the app went to the background (its clock), until it comes back: the ask's app session (20.2).
        var backgroundAt: Date?
    }
    private let lifecycle = Locked(Lifecycle())
    private let stopped = Locked(false)
    private let signatureReported = Locked<String?>(nil)
    private let refusal = Locked<(status: Int, code: String, message: String, reason: String?)?>(nil)
    /// 4.0.1 (28.7): the request that brought `refusal` (its role, and whether more than one host was asked).
    private let refusalTrace = Locked<RequestTrace.Entry?>(nil)
    /// Whether this start has asked the server again for a deletion that a process ended in (once per start).
    private let deletionAsked = Locked(false)
    /// Error reports: every failure that reaches the app and every silent one of 24.1.
    let errorReports: ErrorReporter
    /// SDK 4.0.2 (28.11 item 4): the rows of 429s of the routes that can wait (`events`, `issues`, `uploads`).
    let slowDown: SlowDownRows
    /// Why the last config request failed (nil once one succeeds): the cause a model call without a config names.
    let configFailure = Locked<ErrorCause?>(nil)
    /// The 30-second send point of error reports is set (24.6: one timer for the SDK).
    private let errorTimer = Locked(false)
    /// SDK 4.0.5 (STEERING_40 34.9.2): the last download that failed to its caller, and the send that followed it: a
    /// failed download's error report goes at once, after that send, not after 24.6's 30 seconds.
    private let downloadFailedAt = Locked<Date?>(nil)
    private let afterDownloadSend = Locked<Task<Void, Never>?>(nil)
    /// Whether the install's first process is this one (no marker of an earlier start), per storage folder, as the
    /// first Client of the process found it.
    private static let firstStarts = Locked<[String: Bool]>([:])

    /// The one turn of a start to ask again for a deletion: true for the caller that takes it.
    func takeDeletionTurn() -> Bool {
        deletionAsked.withLock { (asked: inout Bool) -> Bool in
            if asked { return false }
            asked = true
            return true
        }
    }
    /// The refusal that stops the model on the device, remembered across launches (SPEC 15.3).
    let gate: ModelGate
    /// SDK 4.0: the protected model of this Client: the Core over the install's key, the certificate, the lease.
    let protected: ProtectedRuntime

    /// The server's refusal that stopped this launch's network calls (a revoked key, a blocked app, an SDK too old for
    /// the key), when there was one. `code` is the answer's `error` and `reason` its `reason`, the check that refused,
    /// when the answer names one. Without one of this launch: the refusal an earlier launch remembered, when it
    /// stops the model and no answer has accepted the key since.
    var rejection: (status: Int, code: String, message: String, reason: String?)? {
        if let now = refusal.withLock({ $0 }) { return now }
        return gate.stop.map { (status: $0.status, code: $0.code, message: $0.message, reason: $0.reason) }
    }

    /// The refusal that stops the model, when one is remembered: `client.model()` and `prefetch` then open no
    /// model. When this launch's calls are not stopped the server is asked once more first (the config): an
    /// accepting answer clears a refusal of the API, and the call goes on. A refusal of a model request is not
    /// cleared by it. But once an answer of the API has accepted the key since that refusal (this config, or a
    /// registration or a token of this launch), the remembered refusal is dropped here and nil is returned: the
    /// call goes on to its model requests, and the CDN's answer decides and is reported as itself (SPEC 15.3,
    /// `ModelGate.askAgain`). Without a network, and in a launch whose calls a refusal of the API stopped, nothing
    /// is asked and the refusal holds. It also holds while the files it left owed are still on the device (the
    /// removal failed, or a Model is open): the call must not open them in place of asking the CDN.
    /// A remembered refusal that is there and cannot be read (3.1.4) is not "no refusal": the call fails with
    /// `storage_failed`, nothing is asked of the server, and the next call reads again.
    func modelStop() async -> RecognizerError? {
        if let why = gate.unreadable { return ModelGate.unreadableError(why) }
        guard gate.stop != nil else {
            // no refusal now, but the removal one left owed (an accepting answer came before the Model was closed,
            // or the removal failed): the files go before this call uses them. While they cannot go (the removal
            // fails, or a Model is open), the call does not go on to open them
            guard gate.removeOwedModels() else {
                return .storageFailed("model files that a refusal left on this device are still there and could not be removed; "
                    + "close the open Model, or call again")
            }
            return nil
        }
        if !isStopped { _ = await refreshConfig() }
        // a removal of the model files that failed before is tried again, refused or accepted
        let gone = gate.removeOwedModels()
        if !isStopped, gone { gate.askAgain() }
        return gate.stop?.error
    }

    /// 4.0.1 (28.7): the cause of a call that fails on a remembered refusal (`modelStop`, `rejectionError`): its stage
    /// and reason as before, with `host_role` and `fallback` of the request that brought the refusal. The call raises
    /// it outside that request's operation, where `ErrorCause.traced` finds no request. `gateFirst`: the refusal the
    /// call raises is the model gate's (`modelStop`), else this launch's first (`rejection`).
    func refusalCause(_ e: RecognizerError, stage: String? = nil, gateFirst: Bool) -> ErrorCause {
        var c = ErrorCause.of(e, stage: stage)
        guard c.hostRole == nil, ErrorCause.hostStages.contains(c.stage), !ErrorCause.localReasons.contains(c.reason) else { return c }
        let launch: RequestTrace.Entry? = refusal.withLock { $0 != nil } ? refusalTrace.withLock { $0 } : nil
        let kept: RequestTrace.Entry? = gate.stop.flatMap { s in
            s.hostRole.flatMap { EndpointRole(rawValue: $0) }.map { RequestTrace.Entry(role: $0, fallback: s.fallback ?? false) }
        }
        if let t = gateFirst ? (kept ?? launch) : (launch ?? kept) {
            c.hostRole = t.role.rawValue
            c.fallback = t.fallback
        }
        return c
    }

    /// That refusal as the failure a call raises for it.
    var rejectionError: RecognizerError? {
        guard let r = rejection else { return nil }
        return RecognizerError.serverRejected(status: r.status, code: r.code, message: r.message, reason: r.reason)
    }

    /// The end of the Client that made it: no network call, upload pass or timer of it runs from here on.
    func shutdown() {
        stopped.withLock { $0 = true }
        ProtectedRuntime.current.withLock { (r: inout ProtectedRuntime?) in if r === protected { r = nil } }
        deltaTimer.withLock { (t: inout Task<Void, Never>?) in
            t?.cancel()
            t = nil
        }
        outbox.shutdown()
    }

    init(key: String?, options: QuranLab.Options, storage: URL,
         attester: any AppAttesting = DeviceCheckAttester(),
         attestKeys: any AttestKeyStoring = KeychainAttestKeyStore(),
         installKeys: (any InstallKeyStoring)? = nil,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        let cloud = options.cloud ?? CloudOptions()
        self.options = cloud
        self.key = key
        self.storage = storage
        self.updates = options.updates
        self.clock = clock
        lastSeal = Locked(clock())
        let app = cloud.app ?? .main
        self.app = app
        // section 27: the app's version and build go on every config request, read once for this Client
        let config = ConfigStore(storage: storage, trustedKeys: cloud.signingKeys, app: app)
        self.config = config
        // SDK 4.0.1 (section 28): the roles' hosts, the config in force's `endpoints` (its hosts only while it is in
        // force), and the sticky host of each role for this process
        // SDK 4.0.2 (28.11 item 3): each route's Retry-After hold as the last process left it
        // SDK 4.0.5 (SPLIT_40 35.8): the models P per connection type, stored with the config in force. The path monitor
        // is started here and never waited for: the type is `other` until it answers
        NetworkType.begin()
        let endpoints = EndpointSet(api: cloud.apiHosts, models: cloud.modelHosts,
                                    config: { config.current.map { $0.endpoints } }, clock: clock,
                                    holdsFile: storage.appendingPathComponent("cloud/retry-after.json"),
                                    pFile: storage.appendingPathComponent("cloud/models-p.json"),
                                    configIdentity: { config.identity })
        self.endpoints = endpoints
        let http = HTTPClient(session: cloud.urlSession ?? HTTPClient.makeSession(), endpoints: endpoints)
        self.http = http
        let gate = ModelGate(storage: storage)
        self.gate = gate
        // SDK 4.0.5 (plan A2): the API's connection is opened now, while the Client reads its state, so the launch's
        // first call (the token, the registration or the config) finds it open. Not for a Client without a key, one the
        // server stopped, or one made with a session of its own (tests)
        if key != nil, cloud.urlSession == nil || Self.preconnectsWithOwnSession.withLock({ $0 }), gate.stop == nil {
            http.preconnect(endpoints.order(.api, at: clock()).hosts.first ?? cloud.apiURL)
        }
        let tokens = key.map {
            // a token the server issues is an answer that accepts the key
            TokenProvider(http: http, apiURL: cloud.apiURL, key: $0, app: app, teamID: cloud.appleTeamID,
                          attester: attester, attestKeys: attestKeys, storage: storage, clock: clock, trustedKeys: cloud.signingKeys,
                          // SDK 4.0.5 (ATTEST_40.md 40.2 item 1): the config in force says whether the lease needs it
                          attestRequired: { config.current?.attestRequired ?? false },
                          issued: { gate.accepted(.api) })
        }
        self.tokens = tokens
        // the protocol of the last model request is this Client's own
        ModelDownloadRecord.reset()
        let issueQueue = IssueQueue(storage: storage)
        let reportsIssues = cloud.issueReports
        let slowDown = SlowDownRows(file: storage.appendingPathComponent("cloud/slow-down.json"), now: clock())
        self.slowDown = slowDown
        outbox = ContributionOutbox(storage: storage, http: http, apiURL: cloud.apiURL, tokens: tokens, config: config,
                                    options: cloud, app: app, clock: clock, slowDown: slowDown, redirected: { host in
                                        // SPEC 15.4: a background upload that the system redirected is reported with
                                        // the host it ended on, and nothing else of the address
                                        guard reportsIssues, config.current?.flags.issues ?? true else { return }
                                        issueQueue.add(QuranLabCloud.issue(kind: "other", code: "upload_redirected:" + host, app: app,
                                                                           backend: nil, revision: nil))
                                    })
        analytics = AnalyticsStore(storage: storage, enabled: true,
                                   context: .init(platform: app.platform, sdkVersion: SDKInfo.version, appVersion: app.version,
                                                  deviceClass: DeviceContext.deviceClass, soc: DeviceContext.soc,
                                                  osMajor: DeviceContext.osMajor, ramTier: DeviceContext.ramTier),
                                   clock: clock)
        // SDK 4.0.2 (STEERING_40 34.6): each model request's host counts, kept with the telemetry day; nothing is counted
        // while the signed config has telemetry off
        let hostCounts = analytics
        http.modelHosts.withLock {
            $0 = { [config] sample in
                guard config.current?.flags.analytics ?? true else { return }
                hostCounts.record(.modelHost(sample))
            }
        }
        // SDK 4.0.5 (STEERING_40 34.9.7): every move of a model request and every end of a file or a download, with the
        // host counts; nothing with telemetry off
        http.modelSink.withLock {
            $0 = { [config] e in
                guard config.current?.flags.analytics ?? true else { return }
                hostCounts.record(e)
            }
        }
        // SDK 4.0.5 (API_40 37.3): every API request and every move of one, kept with the telemetry day; nothing with
        // telemetry off; sent only behind `AnalyticsStore.sendsApiCounts`
        http.apiSink.withLock {
            $0 = { [config] e in
                guard config.current?.flags.analytics ?? true else { return }
                hostCounts.record(e)
            }
        }
        issues = issueQueue
        incidents = IncidentLedger(storage: storage)
        // contract section 24: the error reports. The install's first process is the one that found no marker of an
        // earlier start (the marker the first registration writes)
        let marker = storage.appendingPathComponent("cloud/installed").path
        let firstStart = QuranLabCloud.firstStarts.withLock { (m: inout [String: Bool]) -> Bool in
            if let known = m[storage.path] { return known }
            let first = !FileManager.default.fileExists(atPath: marker)
            m[storage.path] = first
            return first
        }
        firstLaunch = firstStart
        let reports = ErrorReporter(storage: storage, app: app, firstLaunch: firstStart, clock: clock,
                                     context: { () -> (revision: String?, build: String?) in
                                         // the model version and build in use or being fetched: the config's
                                         guard let c = config.current else { return (nil, nil) }
                                         let id = RecommendedModel.resolve(config: c, storage: storage)
                                         if let r = c.recommended, r.model == id.repository { return (r.version, r.revision) }
                                         return (c.models[id.repository]?.version, c.models[id.repository]?.revision)
                                     })
        errorReports = reports
        // 4.0.1 (24.1 item 2, 28.7): a request of a reporting stage that was taken, refused or slowed down on another
        // host after its first host was unreachable is one silent report, `<stage>`, `failover`, with the first host's
        // reason and status (never a host name)
        endpoints.onFailover.withLock {
            $0 = { (f: EndpointSet.Failover, stage: String?) in
                guard let stage, f.to != nil else { return }
                // 4.0.5 (ATTEST_40.md 40.6): with the operation's chain so far (told inside the request, on its task)
                reports.occur(ErrorCause(stage: stage, reason: "failover", httpStatus: f.status, errorCode: f.reason,
                                         hostRole: f.role.rawValue, fallback: true, chain: CauseChain.current),
                              code: "none", enabled: config.current?.flags.issues ?? true)
            }
        }
        // SDK 4.0: the protected model. The lease route uses the same token as every call; a new
        // certificate comes from a full attest with a new install key.
        let leaseServer: LeaseServer? = tokens.flatMap { (t: TokenProvider) -> LeaseServer? in
            guard let key else { return nil }
            return LeaseServer(transport: http, apiURL: cloud.apiURL, key: key, platform: app.platform,
                               token: { (renew: Bool) async throws(CloudError) -> String in
                                   if renew { await t.invalidate() }
                                   return try await t.token().token
                               },
                               certify: { (k: any InstallKey) async throws(CloudError) -> String in try await t.certify(k) },
                               trustedKeys: cloud.signingKeys,
                               // SDK 4.0.5 (ERRORS_40 24.14 items 4 and 5): the app's release a refusal or a certificate
                               // is kept with, and the App Attest retry hold an attest again clears
                               appRelease: app.version + " (" + (app.build ?? "") + ")",
                               clearAttestHold: { t.clearAttestHold() },
                               // SDK 4.0.5 (ATTEST_40.md 40.2, 40.3, 40.6): the attestation owed, its named path, diagnose's view
                               attestationOwedAndDue: { (networkBack: Bool) in t.attestationOwedAndDue(networkBack: networkBack) },
                               oweAttestation: { t.oweAttestation() },
                               oweAttestationAfter: { (s: Int) in t.oweAttestation(after: s) },
                               attestationOwed: { t.attestState.withLock { $0.owed } },
                               unattestedWhy: { t.whyUnattested.withLock { $0 } },
                               attestation: { (att: String?) in t.diagnosis(certificateAtt: att) },
                               attestRequired: { config.current?.attestRequired ?? false },
                               upgrade: { (k: any InstallKey) async throws(CloudError) -> String in try await t.certify(k, attestedOnly: true) })
        }
        #if DEBUG
        // debug builds only (StagingHooks): the clocks a staging test moves
        let runtime = ProtectedRuntime(storage: storage, server: leaseServer, keys: InstallKeyring(storage: storage),
                                       clocks: StagingHooks.clocks.withLock { $0 })
        #else
        let runtime = ProtectedRuntime(storage: storage, server: leaseServer, keys: InstallKeyring(storage: storage))
        #endif
        let leaseAnalytics = self.analytics
        runtime.onStop = { (e: RecognizerError) in
            // a stop the Core verified (signed by a pinned key, for this request): remembered like every stop of 15.3
            if case .serverRejected(let s, let c, let m, let r) = e { gate.note(.rejected(status: s, code: c, message: m, reason: r), from: .api) }
        }
        runtime.onLease = { (o: LeaseOutcome) in
            leaseAnalytics.recordLease(o)
            // 21.6 item 2: a lease the Core accepted is asked again whether it allows accelerator programs
            if o == .ok { AcceleratorRegistry.leaseAccepted() }
        }
        runtime.onSilent = { (c: ErrorCause) in
            // contract 24.1 item 2: a background lease renewal that failed; the model is on the device and keeps its
            // lease until it ends, and a plain network failure is not reported
            guard c.reason != "network" else { return }
            reports.occur(c, code: "none", enabled: config.current?.flags.issues ?? true)
        }
        runtime.onRecovered = { (take: UInt64, range: CoreRecited?) in leaseAnalytics.countRecovered(take: take, measured: range) }
        runtime.pendingTakes = { leaseAnalytics.pendingTakeIDs }
        // R10: the learner's days in the Core's recited journal (`qlc_days_*`)
        leaseAnalytics.learnerDays.withLock { $0 = CoreLearnerDays(host: { [weak runtime] in try? runtime?.host() }) }
        let issueApp = app, issueOn = cloud.issueReports
        runtime.onIssue = { (kind: String, code: String) in
            guard issueOn else { return }
            issueQueue.add(QuranLabCloud.issue(kind: kind, code: code, app: issueApp, backend: nil, revision: nil))
        }
        protected = runtime
        ProtectedRuntime.current.withLock { $0 = runtime }
        let store = ModelStore(root: storage.appendingPathComponent("models"),
                               verifier: ManifestVerifier(trustedKeys: cloud.signingKeys, requireSignature: true),
                               // 4.0.2: a Mac process the Keychain refuses keeps the key in this storage's file
                               updates: options.updates,
                               installKeys: installKeys ?? KeychainInstallKeyStore(file: KeychainInstallKeyStore.fileURL(storage: storage)))
        self.store = store
        // what the storage folder already holds gets the protection class of the SDK's files (3.1.4)
        StorageProtection.adopt(storage)
        // SDK 4.0.5 (38.3 item 3): the models folder is not backed up (a folder made by 4.0.4 or before was)
        ModelStore.excludeFromBackup(store.root)
        let analytics = self.analytics, issues = self.issues
        let issueContext = (app: app, enabled: cloud.issueReports)
        let explicitBase = cloud.cdnURL
        let cdnKey = key
        let cdnVerifier = ManifestVerifier(trustedKeys: cloud.signingKeys, requireSignature: true)
        // The background transport of model downloads (iOS): the session's finished ranges are placed in this
        // storage, a refusal that stops the model is told to the gate, and a redirect the system followed is
        // refused and reported with its host only (SPEC 15.4).
        var background: (transport: any BackgroundRangeTransport, policy: BackgroundDownloadPolicy, handOver: DownloadHandOver)?
        if cloud.backgroundDownloads != .off, key != nil {
            if let standIn = cloud.backgroundTransport {
                background = (standIn, cloud.backgroundDownloads, cloud.handOver)
            } else if cloud.urlSession == nil {
                let downloader = BackgroundDownloader.shared(identifier: BackgroundDownloader.identifier(for: app), parallel: cloud.parallelBackgroundRanges)
                downloader.attach(Self.rangeSink(storage: storage, gate: gate, issues: issues, app: app, enabled: cloud.issueReports))
                cloud.handOver.observeSystem()
                background = (downloader, cloud.backgroundDownloads, cloud.handOver)
            }
        }
        updater = ModelUpdater(store: store, client: {
            guard let cdnKey, let tokens else { return nil }
            // A model request carries the install's token: the one the SDK uses for everything else, attested where
            // the system supports App Attest, asked for before the first model request. A 401 `invalid_token` drops
            // it and asks for a new one, once.
            let auth = ModelRequestAuthorization(key: cdnKey, token: { (renew: Bool) async throws(CloudError) -> String in
                if renew { await tokens.invalidate() }
                do throws(CloudError) {
                    return try await tokens.token().token
                } catch {
                    // the API refused the key when it was asked for the token: remembered as any refusal of the API
                    gate.note(error, from: .api)
                    throw error
                }
            })
            // SDK 4.0: the build's files from the lease answer's model folder (ModelUpdater). 4.0.1 (28.4): the manifest
            // from the same folder through the `models` hosts when this install holds a lease of the build (a lease from
            // a backup host names that backup's model host), else from the build's folder under Quran Lab's model base (the
            // path qlab-api names in every lease; the 4.0 config names no base, and a base an older config names is not
            // used)
            var cdn = CDNClient(http: http, base: ModelHost.manifestBase(explicit: explicitBase), auth: auth, verifier: cdnVerifier,
                                refused: { gate.note($0, from: .model) }, accepted: { gate.accepted(.model) },
                                protocolSeen: { ModelDownloadRecord.note($0) })
            cdn.leaseFolder = { [weak runtime] (build: String) -> URL? in runtime?.leaseFolder(build) }
            return cdn
        },
                               inferenceContext: { config.current?.inferenceContext },
                               coreML: DownloadProfile.osRunsCoreML && options.neuralEngine,
                               record: { e in analytics.record(e) },
                               report: { e, rev in
                                   guard issueContext.enabled else { return }
                                   issues.add(QuranLabCloud.issue(kind: "update_failed", code: "update:" + (IssueQueue.classify(e)?.code ?? "other"),
                                                                  app: issueContext.app, backend: nil, revision: rev))
                               },
                               stopped: { gate.stop },
                               retryPauses: cloud.retryPauses,
                               background: background,
                               keyInBackground: { config.current?.flags.model_requests_key_in_background ?? true },
                               splitPlan: Self.splitPlan(storage: storage, config: config, endpoints: endpoints, analytics: analytics, clock: clock),
                               arm: { (acted: Bool, failed: Bool) in
                                   // 35.9 `arms`: on the host that was P when the download ended; nothing with telemetry off
                                   guard config.current?.flags.analytics ?? true, let p = endpoints.preferred(.models) else { return }
                                   analytics.record(.modelArm(host: p, acted: acted, failed: failed))
                               },
                               badBody: { (host: String) in
                                   // 34.9.1: nothing with telemetry off
                                   guard config.current?.flags.analytics ?? true else { return }
                                   analytics.record(.modelSplit(host: host, field: "bad_body", n: 1))
                               })
        errorReports.onNew.withLock { $0 = { [weak self] in self?.errorReportMade() } }
        updater.downloadEnded.withLock { $0 = { [weak self] failed in self?.downloadEnded(failed: failed) } }
        // SDK 4.0.5 (38.8): `resume_ms` runs from here, the Client's creation
        updater.createdMs.withLock { $0 = ModelUpdater.nowMs() }
        // SDK 4.0.5 (ATTEST_40.md 40.2 item 4): the background's attestation and lease before any model is on the device
        protected.leaseManifest = { [weak self] in await self?.leaseManifest() }
    }

    /// SDK 4.0.5 (ATTEST_40.md 40.2 item 4): the signed manifest of the build this install would lease, for the
    /// background's attestation and lease before any model is on the device (`ProtectedRuntime.attestWithoutModel`):
    /// the config in hand, else asked; the build it names; that build's manifest. No model file.
    func leaseManifest() async -> ModelManifest? {
        guard key != nil, !isStopped else { return nil }
        if config.current == nil { _ = await refreshConfig() }
        let id = RecommendedModel.resolve(config: config.current, storage: storage)
        guard let revision = targetRevision(id) else { return nil }
        return await updater.manifestForLease(id, revision: revision, version: targetVersion(id), keyID: targetKeyID(id))
    }

    /// SDK 4.0.5 (SPLIT_40 35.2): what a CPU-set download of this Client is told at its start: the config in force's
    /// `flags.download_split` (absent: share 0, counted only), the share's draw for today, the connection type, and
    /// where the decide's counts (nothing with telemetry off, 22.2; the switch still acts), the bytes a cut discarded and
    /// P go.
    static func splitPlan(storage: URL, config: ConfigStore, endpoints: EndpointSet, analytics: AnalyticsStore,
                          clock: @escaping @Sendable () -> Date) -> @Sendable () async -> SplitPlan? {
        return { () async -> SplitPlan? in
            let flag = config.current?.flags.download_split ?? DownloadSplit()
            var plan = SplitPlan(shareOn: flag.inShare(seed: SplitSeed.read(storage), day: SplitSeed.day(clock())))
            plan.noHelper = flag.no_helper
            plan.conn = await NetworkType.current()
            plan.count = { (field: String, host: String, n: Int) in
                guard config.current?.flags.analytics ?? true else { return }
                analytics.record(.modelSplit(host: SplitHosts.name(host), field: field, n: n))
            }
            plan.wasted = { (host: String, bytes: Int64) in
                guard config.current?.flags.analytics ?? true else { return }
                analytics.record(.modelWasted(host: SplitHosts.name(host), bytes: bytes))
            }
            plan.settle = { (origin: URL) in endpoints.settle(.models, origin, at: clock(), probe: false) }
            return plan
        }
    }

    /// SDK 4.0.5 (API_40 37.5): the process's first ask for a model ended, ready or not. Nothing with telemetry off.
    func recordReady(_ r: ReadySample) {
        guard config.current?.flags.analytics ?? true else { return }
        analytics.record(.ready(r))
    }

    /// Tests only: a Client made with a session of its own preconnects too.
    static let preconnectsWithOwnSession = Locked(false)

    /// What a range that a background task finished is handed to: this storage, the model gate for a refusal, and
    /// the issue queue for a redirect the system followed (`update_failed`, `model_redirected:<host>`: the host
    /// only, never a path or a query).
    static func rangeSink(storage: URL, gate: ModelGate, issues: IssueQueue, app: AppIdentity, enabled: Bool) -> RangeDelivery.Sink {
        RangeDelivery.Sink(storage: storage,
                           refused: { gate.note($0, from: .model) },
                           redirected: { host in
                               guard enabled else { return }
                               issues.add(QuranLabCloud.issue(kind: "update_failed", code: "model_redirected:" + host, app: app, backend: nil,
                                                              revision: nil))
                           })
    }

    /// Network calls are off for this launch (a revoked key, a blocked app, an SDK too old for the key).
    var isStopped: Bool { stopped.withLock { $0 } }

    /// This is the configured Client's server client: the ask to share (SDK 4.0, section 20) follows its launches and
    /// its foreground, and the learner's state is in its storage.
    private var isConfigured: Bool { QuranLab.cloud === self }

    private func stopIfFatal(_ e: CloudError) {
        // a refusal of the key or the app that stops the model on the device is remembered (SPEC 15.3)
        gate.note(e, from: .api)
        guard case .rejected(let status, let code, let message, let reason) = e else { return }
        // the network follows the status and the answer's `error`, as before 3.1.0; an answer whose `reason` stops
        // the model stops this launch's calls too, whatever its `error` (a token whose key was revoked)
        let fatal = ["invalid_key", "unauthorized", "developer_not_approved", "not_a_member", "key_type_mismatch",
                     "origin_not_allowed", "app_not_allowed", "app_blocked", "environment_mismatch", "sdk_too_old"]
        if ((status == 401 || status == 403) && fatal.contains(code)) || ModelGate.stops(status: status, reason: reason) {
            stopped.withLock { $0 = true }
            refusal.withLock { $0 = (status, code, message, reason) }
            refusalTrace.withLock { $0 = RequestTrace.last }
        } else if status == 403, !code.hasPrefix("http_"), !isStopped {
            // a refusal with a code this SDK does not know: the calls go on, and the app's errors name the code
            refusal.withLock { $0 = (status, code, message, reason) }
            refusalTrace.withLock { $0 = RequestTrace.last }
        }
    }

    /// The server answered this install: a refusal that did not stop the launch's calls is over, and so is a
    /// remembered refusal of the API that stopped the model (the answer accepts the key).
    private func answered() {
        configFailure.withLock { $0 = nil }
        if !isStopped { refusal.withLock { $0 = nil } }
        gate.accepted(.api)
    }

    // MARK: launch

    /// The launch sequence, at utility priority: registration (once a UTC day), the config, the uploads due (this
    /// launch's telemetry delta and any left from earlier runs, issues, the sharing outbox), then the update check of
    /// a build this Client installed on this device (never a first install: that waits for `client.model()` or
    /// `prefetch()`, contract 1.22.4). Each step is independent; whatever was not sent stays queued. From here a
    /// telemetry delta goes every 15 minutes while the app is in use and when it goes to the background.
    func launch() async {
        analytics.count(.launch)
        // SDK 4.0 (20.2, 20.5 `launch`): the Client's start is a new app session for the ask to share (never an ask)
        if isConfigured { Contributions.appSessionStarted() }
        _ = await register()
        let cfg = await refreshConfig() ?? config.current
        await flush()
        // a deletion that a process ended in: the saved answer is read here (which turns sharing off), and the
        // server is asked again
        await Contributions.finishDeletion()
        outbox.resume()
        observeLifecycle()
        startDeltaTimer()
        guard updates != .manual else { return }
        if let r = cfg?.recommended { RecommendedModel.remember(r, storage: storage) }
        // SDK 4.0: the first start after `refresh_after` renews the lease in the background (18.4.7)
        let id = RecommendedModel.resolve(config: cfg, storage: storage)
        if let dir = try? store.ownedDirectory(id, discard: false),
           let folder = try? ModelFolder.open(directory: dir, verifier: store.verifier, expecting: id) {
            protected.refreshIfDue(folder)
        }
        // Making the Client never downloads or installs a model: the first install waits
        // for the app's client.model() or prefetch(), which take the lease and download. The start checks only for an
        // update of a build this Client installed on this device; a model it did not install is left to those calls,
        // which delete it and download the build.
        // Tried before (to 3.1.4): the start's update check installed the model on a fresh store, so making the
        // Client downloaded the model before the app asked for it.
        guard let held = store.currentRevision(id),
              case .own(.installed) = store.standing(of: store.base(id).appendingPathComponent(held)) else { return }
        _ = await checkForUpdate(.recommended)
    }

    /// The revision of the model this install holds, whatever its id: of the model Quran Lab's config names for
    /// this app (the one `client.model()` opens), else of any model in the store.
    /// Tried before (to 3.1.2): the registration sent the revision of the model id `v4.0` only, so an install on
    /// another model id sent none.
    func heldModelRevision() -> String? {
        let id = RecommendedModel.resolve(config: config.current, storage: storage)
        return store.currentRevision(id) ?? store.anyCurrentRevision()
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
    func register() async -> Bool {
        // one operation for the causes it makes (4.0.1, RequestTrace)
        await RequestTrace.scope { await self.registerOnce() }
    }

    private func registerOnce() async -> Bool {
        let today = Day.string(clock())
        // unreadable is taken as not there here, because the day's registration is then sent once more
        if (try? String(contentsOf: registeredDay, encoding: .utf8)) == today { return false }
        let fm = FileManager.default
        let isNew = !fm.fileExists(atPath: installedMarker.path)
        if isNew {
            try? fm.createDirectory(at: installedMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: installedMarker.path, contents: Data())
        }
        // unreadable is taken as not there here, because it only carries the new-install flag of a registration
        // that could not be sent
        let newInstall = isNew || (pendingRegistration.read().takingUnreadableAsMissing?["new_install"] ?? false)
        pendingRegistration.write(["new_install": newInstall])
        guard key != nil, !isStopped else { return false }
        var body: [String: Any] = ["platform": app.platform, "bundle_id": app.bundleID, "app_version": app.version,
                                   "sdk_version": SDKInfo.version, "new_install": newInstall]
        if let n = app.name, !n.isEmpty { body["app_name"] = n }
        if let rev = heldModelRevision() { body["model_revision"] = String(rev.prefix(64)) }
        do throws(CloudError) {
            _ = try await authed { (token: String) throws(CloudError) -> URLRequest in
                try HTTPClient.jsonRequest(self.options.apiURL.appendingPathComponent("v1/register"), body: body, auth: token)
            }
            pendingRegistration.delete()
            try? Data(today.utf8).write(to: registeredDay, options: StorageProtection.atomic)
            gate.accepted(.api)
            return true
        } catch {
            stopIfFatal(error)
            if !error.retryable { pendingRegistration.delete() }
            // 24.1 item 2: the launch goes on without it
            noteSilent(ErrorCause.of(error, stage: stage(of: error, route: "register")))
            return false
        }
    }

    /// Fetches and verifies the config; nil (keeping the last verified one) when that fails. A body that does not
    /// verify is reported once a day (`signature_invalid`).
    @discardableResult
    func refreshConfig() async -> RemoteConfig? {
        // one operation for the causes it makes (4.0.1, RequestTrace)
        await RequestTrace.scope { await self.refreshConfigOnce() }
    }

    private func refreshConfigOnce() async -> RemoteConfig? {
        guard let tokens, !isStopped else { return nil }
        do throws(CloudError) {
            let t = try await tokens.token()
            do throws(CloudError) {
                let fetched = try await config.fetch(http: http, apiURL: options.apiURL, token: t.token)
                answered()
                return fetched
            } catch {
                // a 401 that names why the key is refused is not answered with a new token
                guard case .rejected(401, _, _, let reason) = error, !ModelGate.stops(reason: reason) else { throw error }
                await tokens.invalidate()
                let fetched = try await config.fetch(http: http, apiURL: options.apiURL, token: try await tokens.token().token)
                answered()
                return fetched
            }
        } catch {
            stopIfFatal(error)
            if case .invalid(let why) = error, why.contains("sign") {
                let today = Day.string()
                let first = signatureReported.withLock { d -> Bool in defer { d = today }; return d != today }
                if first { report(.signatureInvalid, backend: nil, revision: nil) }
            }
            // 24.1 item 2: the SDK goes on with the config it has, or none; a model call that fails for want of it
            // names this cause (24.4)
            let cause = ErrorCause.of(error, stage: stage(of: error, route: "config"))
            configFailure.withLock { $0 = cause }
            noteSilent(cause)
            return nil
        }
    }

    var currentConfig: RemoteConfig? { config.current }

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
    /// SDK 4.0 (20.2): back after 30 minutes or more in the background, a new app session for the ask to share.
    func cameToForeground() {
        Contributions.recorder.foreground()
        let now = clock()
        let (returning, away) = lifecycle.withLock { (l: inout Lifecycle) -> (Bool, TimeInterval?) in
            defer {
                l.background = false
                l.backgroundAt = nil
            }
            return (l.background, l.backgroundAt.map { now.timeIntervalSince($0) })
        }
        if returning { analytics.count(.launch) }
        if let away, away >= ShareAsk.appSessionGap, isConfigured { Contributions.appSessionStarted() }
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
        // SDK 4.0 (20.6): an ask that waits for its moment, or a card on screen, is withdrawn (the card as a "Not now")
        if isConfigured { Contributions.leftForeground() }
        // the analytics session ends with the foreground (17.8 `session_s`)
        analytics.closeSession()
        let now = clock()
        lifecycle.withLock { (l: inout Lifecycle) in
            l.background = true
            if l.backgroundAt == nil { l.backgroundAt = now }
        }
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
        // the Core's own timer (lease expiry, a refresh that is due, the day's audio, the recited journal), off the
        // audio thread
        protected.tick()
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

    /// Sends a request with the token, getting a new token once after a 401 (not after one that names why the key
    /// is refused: the key was revoked after the token was issued).
    func authed(_ make: (String) throws(CloudError) -> URLRequest) async throws(CloudError) -> HTTPClient.Response {
        guard let tokens else { throw .noKey }
        guard !isStopped else { throw .offline("stopped for this launch") }
        let t = try await tokens.token()
        do throws(CloudError) {
            return try await http.checked(try make(t.token))
        } catch {
            guard case .rejected(401, _, _, let reason) = error, !ModelGate.stops(reason: reason) else { throw error }
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
    func flush(includingToday: Bool = false) async -> (events: Int, issues: Int) {
        lastSeal.withLock { $0 = clock() }
        let flags = config.current?.flags ?? RemoteConfig.Flags()
        if !flags.analytics { analytics.dropAll() }
        analytics.metricsOff.withLock { $0 = Set((flags.metrics ?? [:]).filter { !$0.value }.keys) }
        if !flags.issues {
            issues.dropAll()
            errorReports.dropQueue()
        }
        guard key != nil, !isStopped else { return (0, 0) }
        var events = 0, sentIssues = 0
        // 28.11 item 4 (SDK 4.0.2): a route a 429 asked to wait sends at the first send point after its row's wait
        if flags.analytics, slowDown.allows("events", now: clock()) {
            // one operation for the causes it makes (4.0.1, RequestTrace: `events` names its request's role and fallback)
            events = await RequestTrace.scope { await self.flushEvents() }
        }
        if options.issueReports {
            // the first accelerator incident of each kind per revision goes whatever flags.issues says
            sentIssues = await sendIssues(regular: flags.issues)
        }
        // contract 24.6: every telemetry send point (the launch's comes after its config) sends the error reports, after
        // the telemetry. SDK 4.0: no app option turns them off, only `flags.issues`
        if flags.issues { await sendErrorReports() }
        return (events, sentIssues)
    }

    /// SDK 4.0.5 (STEERING_40 34.9.2): a download of model files ended (its files in place, or its failure told to its
    /// caller). Today's host counts are sealed alone and sent at once with any bodies already waiting (at most 4 such sends
    /// a UTC day, nothing when no host was counted since the last seal, nothing with telemetry off); for a failed
    /// download, the queued error reports go right after (24.6's answers and caps, `flags.issues`).
    func downloadEnded(failed: Bool) {
        if failed { downloadFailedAt.withLock { $0 = clock() } }
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.sendAfterDownload(failed: failed)
        }
        afterDownloadSend.withLock { $0 = task }
    }

    private func sendAfterDownload(failed: Bool) async {
        guard key != nil, !isStopped else { return }
        let flags = config.current?.flags ?? RemoteConfig.Flags()
        if flags.analytics, analytics.sealAfterDownload(), slowDown.allows("events", now: clock()) {
            _ = await RequestTrace.scope { await self.flushEvents(sealing: false) }
        }
        if failed, flags.issues { await sendErrorReports() }
    }

    /// The telemetry deltas of a send point, each one `POST /v1/events`. `sealing` false: only what is sealed already
    /// (the send after a download).
    private func flushEvents(sealing: Bool = true) async -> Int {
        await analytics.flush(sealing: sealing, send: { (d: Data) async throws(CloudError) -> Void in
            do throws(CloudError) {
                _ = try await self.authed { (token: String) throws(CloudError) -> URLRequest in
                    var r = try HTTPClient.jsonRequest(self.options.apiURL.appendingPathComponent("v1/events"), body: nil, auth: token)
                    r.httpBody = d
                    r.setValue("application/json", forHTTPHeaderField: "content-type")
                    return r
                }
                self.slowDown.accepted("events")
            } catch {
                if case .rejected(429, _, _, _) = error { self.slowedDown("events") }
                // contract 24.1 item 2: a telemetry report the server refused (400, 413) is dropped
                if case .rejected(let s, _, _, _) = error, s == 400 || s == 413 {
                    self.noteSilent(ErrorCause(stage: "events", reason: "http", httpStatus: s).traced())
                }
                // a body the server refuses is the SDK's bug: dropped, and reported (kind and code only)
                if case .rejected(400, _, _, _) = error {
                    self.report(.serverRejected(status: 400, code: "bad_request", message: ""), kind: "other", code: "bad_request:events",
                                backend: nil, revision: nil)
                }
                throw error
            }
        })
    }

    // MARK: error reports

    /// An occurrence of a failure: recorded off the caller's path; `flags.issues: false` records nothing.
    func errorOccurred(_ cause: ErrorCause, code: String) {
        errorReports.occur(cause, code: code, enabled: config.current?.flags.issues ?? true)
    }

    /// A failure of a background call the app is not told of (24.1 item 2: the config, registration, the token, a
    /// telemetry report): code `none`, never a plain network failure. A model call it makes fail is its own report,
    /// with the code the app got (24.1, f209443: the two have their own signatures).
    func noteSilent(_ cause: ErrorCause) {
        guard cause.reason != "network" else { return }
        errorOccurred(cause, code: "none")
    }

    /// The stage of a failed call made with the token: `attest` when it was the token that failed.
    func stage(of e: CloudError, route: String) -> String {
        tokens?.lastFailure.withLock({ $0 }) == e ? "attest" : route
    }

    /// 24.6: 30 seconds after an occurrence that made a new report, while the app is in the foreground (one timer).
    private func errorReportMade() {
        // SDK 4.0.5 (34.9.2 item 5): a failed download's report goes at once, after the send of its host counts
        if let at = downloadFailedAt.withLock({ $0 }), abs(clock().timeIntervalSince(at)) < 60 {
            let before = afterDownloadSend.withLock { $0 }
            Task.detached(priority: .utility) { [weak self] in
                _ = await before?.value
                await self?.sendErrorReports()
            }
            return
        }
        guard !lifecycle.withLock({ $0.background }) else { return }
        let start = errorTimer.withLock { (on: inout Bool) -> Bool in
            defer { on = true }
            return !on
        }
        guard start else { return }
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            guard let self else { return }
            self.errorTimer.withLock { $0 = false }
            await self.sendErrorReports()
        }
    }

    /// Sends the queued error reports, oldest first, one request each (24.6): 202 sent, 400 or 413 dropped, anything
    /// else keeps the rest for the next send point. A failure to send one is never reported.
    @discardableResult
    func sendErrorReports() async -> Int {
        guard key != nil, !isStopped, config.current?.flags.issues ?? true else { return 0 }
        // 28.11 item 4: after a 429 of the issues route, its row's wait first
        guard slowDown.allows("issues", now: clock()) else { return 0 }
        return await errorReports.send { (d: Data) async -> Int? in
            do throws(CloudError) {
                let status = try await self.authed { (token: String) throws(CloudError) -> URLRequest in
                    var r = try HTTPClient.jsonRequest(self.options.apiURL.appendingPathComponent("v1/issues"), body: nil, auth: token)
                    r.httpBody = d
                    r.setValue("application/json", forHTTPHeaderField: "content-type")
                    return r
                }.status
                self.slowDown.accepted("issues")
                return status
            } catch {
                if case .rejected(429, _, _, _) = error { self.slowedDown("issues") }
                if case .rejected(let s, _, _, _) = error { return s }
                return nil
            }
        }
    }

    /// 28.11 item 4: a 429 on a route that can wait: one more in its row, with the answer's `Retry-After` when it named one.
    func slowedDown(_ route: String) {
        slowDown.slowed(route, retryAfter: http.endpoints?.holds.lastRetryAfter(route), now: clock())
    }

    func sendIssues(regular: Bool = true) async -> Int {
        // 28.11 item 4: after a 429 of the issues route, its row's wait first
        guard slowDown.allows("issues", now: clock()) else { return 0 }
        let send = { (d: Data) async throws(CloudError) -> Void in
            do throws(CloudError) {
                _ = try await self.authed { (token: String) throws(CloudError) -> URLRequest in
                    var r = try HTTPClient.jsonRequest(self.options.apiURL.appendingPathComponent("v1/issues"), body: nil, auth: token)
                    r.httpBody = d
                    r.setValue("application/json", forHTTPHeaderField: "content-type")
                    return r
                }
                self.slowDown.accepted("issues")
            } catch {
                if case .rejected(429, _, _, _) = error { self.slowedDown("issues") }
                throw error
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
    func forcedBackend(revision: String) -> (backend: ActiveBackend, reason: String)? {
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
    func acceleratorDenied(revision: String, kind: String = "ane") -> String? {
        if let f = forcedBackend(revision: revision), f.backend == .exact { return f.reason }
        guard let r = config.current?.accelDenyRule(values: deviceValues(revision: revision), kind: kind) else { return nil }
        if let reason = r.reason { SDKLatest.debugOnly("accel_deny: \(reason)") }
        return "accel_deny" + (r.reason.map { ": \($0)" } ?? "")
    }

    /// The CDN revision this install should run: the local pin, else the config's (portal pin, or the channel's
    /// release with the staged rollout applied by the server).
    func targetRevision(_ id: ModelID) -> String? {
        if case .pinned(let r) = updates { return r }
        guard let c = config.current else { return nil }
        if let r = c.recommended, r.model == id.repository { return r.revision }
        return c.models[id.repository]?.revision
    }

    /// The model version of the build the config names for `id` (SDK 3.0.0); nil for a local pin by revision.
    func targetVersion(_ id: ModelID) -> String? {
        if case .pinned = updates { return nil }
        guard let c = config.current else { return nil }
        if let r = c.recommended, r.model == id.repository { return r.version }
        return c.models[id.repository]?.version
    }

    /// The key id the config names for the build of `id` (SDK 4.0, 18.4.5); nil for a local pin by revision.
    func targetKeyID(_ id: ModelID) -> String? {
        if case .pinned = updates { return nil }
        guard let c = config.current else { return nil }
        if let r = c.recommended, r.model == id.repository { return r.key_id }
        return c.models[id.repository]?.key_id
    }

    /// Pins the model version the config request asks for (`model_version=x.y.z`); nil follows Quran Lab's choice. A
    /// change takes effect with the next config, fetched here.
    func pin(version: String?) async {
        guard config.pin(version) else { return }
        _ = await refreshConfig()
        if let v = config.current?.pinUnavailable { SDKLatest.debugOnly("model version \(v) is not available for this SDK: Quran Lab's choice stands") }
    }

    /// Downloads, verifies and stages the target revision (see `ModelUpdater`); it becomes current at the next load.
    func checkForUpdate(_ id: ModelID = .recommended) async -> ModelUpdater.Outcome {
        let id = id.isRecommended ? RecommendedModel.resolve(config: config.current, storage: storage) : id
        guard key != nil else { return .deferred("no developer key configured") }
        // a remembered refusal that cannot be read: nothing is downloaded until it reads
        if let why = gate.unreadable { return .failed(ModelGate.unreadableError(why)) }
        guard let target = targetRevision(id) else { return .deferred("no revision in the config yet") }
        return await updater.update(id, to: target, version: targetVersion(id), keyID: targetKeyID(id), context: nil,
                                    activate: store.currentRevision(id) == nil, by: "sdk")
    }

    // MARK: downloads that survive the app (SDK 4.0.5, contract section 38)

    /// Tests: whether `QuranLab.configure` starts the resume of owed downloads beside the launch (on by default).
    static let resumesAtStart = Locked(true)

    /// SDK 4.0.5: making the Client resumes every owed download at once, without waiting for `model()`
    /// or `prefetch()`, on its own task beside the launch (never before it, never blocking the constructor). It never
    /// starts a download that has no owed record: a first install still waits for the app's call (SPEC 13.4, which
    /// 38.5 amends). In order:
    /// - a removal owed or a refusal held (15.3) removes the model files and the owed records, and nothing resumes;
    /// - the records (and a download 4.0.4 left, 38.3 item 4), the app's first, then the SDK's (38.5 item 3);
    /// - a record whose build the config in force no longer names for its context ends; the app's download moves to the
    ///   new build (38.5 item 6), the SDK's update is left to the update rules;
    /// - each goes on through the same entry point as the app's call (`ModelUpdater.update`), with the manifest the
    ///   record kept, so a `model()` or `prefetch()` meanwhile joins it (38.5 item 7) and no byte is asked twice. The
    ///   hosts' order and P are the config in force's; the token is the stored one while valid (the client's own).
    /// - with no lease in force for the build, the lease is asked beside the first request, which goes to the folder
    ///   the record's earlier answer named (`ModelUpdater.leaseBeside`, 18.4.1 step 4 as 38.6 amends it).
    /// Not yet on Apple: a wait for a network when there is none (today the resume ends deferred, and the app's call
    /// goes on with it).
    func resumeOwed() async {
        guard key != nil, !isStopped else { return }
        if gate.unreadable != nil { return }
        if gate.stop != nil || gate.removalOwed {
            _ = gate.removeOwedModels()
            return
        }
        var owed = OwedDownloads.all(root: store.root)
        let id = RecommendedModel.resolve(config: config.current, storage: storage)
        owed += OwedDownloads.leftBy404(id, store: store, known: owed)
        guard !owed.isEmpty else { return }
        for o in OwedDownloads.ordered(owed) {
            if isStopped || gate.stop != nil { return }
            let oid = o.id
            // 38.5 item 6: the build moved on for this context
            if o.kind != "accelerator", o.kind != "reference", let target = targetRevision(oid), target != o.build {
                OwedDownloads.remove(o, root: store.root)
                SDKLatest.debugOnly("owed download: \(o.kind) of \(o.build) superseded by \(target)")
                if o.by == "app" {
                    updater.startResumed.withLock { _ = $0.insert(target) }
                    _ = await updater.update(oid, to: target, version: targetVersion(oid), keyID: targetKeyID(oid), context: o.context,
                                             activate: o.activate, by: o.by)
                }
                continue
            }
            // the Core ML build, the reference table: into the build in use they belong to
            if o.kind == "accelerator" || o.kind == "reference" {
                await resumeInBuild(o)
                continue
            }
            guard o.kind == "first_install" || o.kind == "update" || o.kind == "context" else { continue }
            updater.startResumed.withLock { _ = $0.insert(o.build) }
            SDKLatest.debugOnly("owed download: resuming \(o.kind) of \(o.build) at the Client's start")
            _ = await updater.update(oid, to: o.build, version: o.version, keyID: o.keyID, context: o.context, activate: o.activate,
                                     by: o.by, manifest: o.manifest(verifier: store.verifier))
        }
    }

    /// SDK 4.0.5 (38.5 items 2 and 3): an owed download of the Core ML build or of the reference table goes on into the
    /// build in use it belongs to, with no backoff of the promotion's stages (a cut download is no failure of the
    /// pipeline). A record of a build that is no longer the one in use ends (the build moved on), and so does one of a
    /// Core ML build on an install that downloads none or that this device has failed for good. The Core ML build
    /// waits while the config's deny list holds it or the lease in force does not allow accelerator programs (R2), as
    /// the promotion's download does.
    private func resumeInBuild(_ o: OwedDownload) async {
        let oid = o.id
        guard let rev = store.currentRevision(oid),
              let folder = try? ModelFolder.open(directory: store.base(oid).appendingPathComponent(rev), verifier: store.verifier, expecting: oid),
              folder.identity == o.build else {
            OwedDownloads.remove(o, root: store.root)
            return
        }
        SDKLatest.debugOnly("owed download: resuming \(o.kind) of \(o.build) at the Client's start")
        if o.kind == "accelerator" {
            let ctx = o.context ?? folder.manifest.defaultContext, compact = o.variant == "compact"
            // the promotion's own verdicts first, as its download stage would meet them: no Core ML downloads in this
            // process, or a build this device has failed for good: the record ends; the config's deny list or a lease
            // in force without accelerator programs (R2): it waits
            guard updater.coreML else { return OwedDownloads.remove(o, root: store.root) }
            let key = AcceleratorController.key(revision: folder.identity, context: ctx, build: compact ? "coreml-compact" : "coreml",
                                                program: AcceleratorController.programKey(folder.manifest, context: ctx, compact: compact))
            let verdicts = PromotionStore(dir: QuranLab.configuration.storageDirectory.appendingPathComponent("accelerator"))
            if verdicts.record(key)?.status == .failed { return OwedDownloads.remove(o, root: store.root) }
            if acceleratorDenied(revision: folder.version.isEmpty ? folder.identity : folder.version) != nil { return }
            if protected.acceleratorAllowed() == false { return }
            do throws(RecognizerError) {
                _ = try await updater.installAccelerator(folder, context: ctx, compact: compact)
            } catch {
                if case .neuralEngineUnavailable = error { OwedDownloads.remove(o, root: store.root) }
            }
            return
        }
        guard let file = folder.referenceFile else {
            OwedDownloads.remove(o, root: store.root)
            return
        }
        do throws(RecognizerError) { try await updater.install(file, of: folder) } catch {}
    }

    /// Installs the model for `context` now (the first launch, or another context on demand), and activates it.
    func install(_ id: ModelID, context: String?, activate: Bool, keep: Bool = false) async -> ModelUpdater.Outcome {
        guard key != nil else { return .deferred("no developer key configured") }
        // a remembered refusal that cannot be read: nothing is downloaded until it reads
        if let why = gate.unreadable { return .failed(ModelGate.unreadableError(why)) }
        if config.current == nil { _ = await refreshConfig() }
        guard let target = targetRevision(id) else { return .deferred("no revision in the config yet") }
        var outcome = await updater.update(id, to: target, version: targetVersion(id), keyID: targetKeyID(id), context: context, activate: activate,
                                           keep: keep)
        // SDK 4.0.5: a build this SDK does not run, named by a config that an SDK before 4.0 stored in the same folder.
        // At the first launch after an app's update from SDK 3.x, that config is still in force (it is signed and valid
        // for a day), so this call asked for none and installed its build: a plain build for SDK 3, which SDK 4 refuses
        // (model_incompatible). The config is asked for now, and when it names another build, that build is installed
        // in this same call.
        // Tried before (4.0.0 to 4.0.4): the call failed with model_incompatible, and the next call, after the launch's
        // own config request, installed the right build (Apple 4.0.2, 2026-11-24: one failed `model()` for about a
        // quarter of the installs that came from 3.1.4).
        if case .failed(.modelIncompatible(_)) = outcome {
            _ = await refreshConfig()
            if let fresh = targetRevision(id), fresh != target {
                outcome = await updater.update(id, to: fresh, version: targetVersion(id), keyID: targetKeyID(id), context: context, activate: activate,
                                               keep: keep)
            }
        }
        // 4.0.1 (3.0.2's rule): the model of this id is installed and the one in use, so the store folders of every
        // other model id go. An install pinned to a model version stays as it is.
        if activate, case .installed(let model, _) = outcome, config.pinnedVersion == nil { await removeOtherModels(inUse: model) }
        return outcome
    }

    /// Removes the model files other model ids left in this Client's store (`ModelStore.removeOtherModels`), keeping
    /// every id that is in use: the folder of an open Model, the Core's open model, the model a Client is opening,
    /// and a download under way (an install running here, or ranges the background session still carries). Only
    /// the model store: the sharing outbox, the learner's choices, the lease and the Core's state are never touched.
    @discardableResult
    func removeOtherModels(inUse model: ModelFolder) async -> [String] {
        var keeping = await updater.runningModelNames()
        let others = ((try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []).filter { $0 != model.id.name }
        keeping.formUnion(await updater.backgroundModelNames(among: others))
        var open = ModelsInUse.all
        if let core = protected.openFolder { open.append(core) }
        for dir in open { if let name = store.modelName(of: dir) { keeping.insert(name) } }
        return store.removeOtherModels(inUse: model, keeping: keeping)
    }

    // MARK: sharing routes for the learner

    /// The app id the server knows this install's app by ("ios:<bundle id>").
    var appID: String { "\(app.platform):\(app.bundleID)" }

    /// "Delete what I shared": a single-use nonce from `POST /v1/contributions/challenge`,
    /// the deletion message signed with the device key, `POST /v1/contributions/delete`. No app credential is sent
    /// (the server refuses one). 202 is the server's answer whatever the signature (no enumeration); the purge runs
    /// within seconds. One retry with a new nonce on `nonce_invalid` or `timestamp_invalid`.
    /// `key` is the device key the caller read, or made because the device had none (3.1.4): none is made here,
    /// and the caller makes none while a key is there and cannot be read.
    func deleteContributions(contributor: String, key: ContributorKey.Key) async throws(RecognizerError) {
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
                if attempt == 0, case .rejected(401, let code, _, _) = error, code == "nonce_invalid" || code == "timestamp_invalid" { continue }
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
