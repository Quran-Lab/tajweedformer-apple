import CryptoKit
import Foundation
import QuranLabCore

/// How a request of the protected model reaches the server: the SDK's HTTP client, or a fake in the tests.
protocol LeaseTransport: Sendable {
    func send(_ request: URLRequest) async throws(CloudError) -> HTTPClient.Response
    /// SDK 4.0.1: `accept` says whether a 2xx is the answer the route asks for (28.3: a lease the Core accepts); one
    /// that is not is unreachable on that host, and the next `api` host is asked.
    func send(_ request: URLRequest, accepting accept: @escaping @Sendable (HTTPClient.Response) -> Bool) async throws(CloudError)
        -> HTTPClient.Response
    /// SDK 4.0.2 (18.4.7.3 item 4): the answer a request of `url` gets now without asking, when its route is held by
    /// a `Retry-After`; nil when it may go.
    func held(_ url: URL) -> HTTPClient.Response?
}

extension LeaseTransport {
    /// A transport that keeps no holds (the tests' fakes).
    func held(_ url: URL) -> HTTPClient.Response? { nil }

    /// A transport with one host (the tests' fakes): the answer is the answer.
    func send(_ request: URLRequest, accepting accept: @escaping @Sendable (HTTPClient.Response) -> Bool) async throws(CloudError)
        -> HTTPClient.Response {
        try await send(request)
    }
}

extension HTTPClient: LeaseTransport {}

/// What the protected model needs of the Client's server side.
struct LeaseServer: Sendable {
    let transport: any LeaseTransport
    let apiURL: URL
    /// The developer key (`x-qlab-key` of the challenge).
    let key: String
    /// `ios` or `macos`: the app's platform as the API knows it.
    let platform: String
    /// The install's app token; with `renew` a new one.
    let token: @Sendable (_ renew: Bool) async throws(CloudError) -> String
    /// A new install certificate for `key` (`POST /v1/attest` with the install's keys and App Attest where the
    /// device has it, 18.4.3). The answer's token replaces the one in hand.
    let certify: @Sendable (_ key: any InstallKey) async throws(CloudError) -> String
    /// Quran Lab's signing keys: certificates verify against them.
    let trustedKeys: [Data]
}

/// Where the install keys come from: the Keychain and Secure Enclave (`InstallKeyring`), or a fixed key in tests.
protocol InstallKeySource: Sendable {
    func current() -> (any InstallKey)?
    var generation: Int { get }
    func makeNext() -> (key: any InstallKey, generation: Int)?
    func promote(_ key: any InstallKey, generation: Int)
    func discard(generation: Int)
}

extension InstallKeyring: InstallKeySource {}

/// The lease the SDK holds besides the Core's own copy: which build it is for and where that build's files are.
struct LeaseRecord: Codable, Sendable, Equatable {
    var build: String
    var base: String?
    var expiresAt: Int64
    var refreshAfter: Int64
    /// SDK 4.0.2: the lease's server issue time (`iat`), so an older lease never replaces it (`storeLease`). Nil in a
    /// record an earlier SDK wrote.
    var issuedAt: Int64? = nil
}

/// SDK 4.0.2: one Core per storage folder and install key in the process. A Client that is closed may still hold its
/// Core (a lease attempt on its way, a Model the app keeps open); a new Client on the same folder takes that Core
/// instead of making a second one, so every save of the Core's state comes from one Core, in order, and its counter is
/// raised by that Core alone. Tried before (to 4.0.1): a Core per Client. Two Cores then saved `core/state.bin` in turn,
/// and the one that saved last rolled the other's lease back (a renewal answered to a closed Client was lost).
enum LiveCores {
    private final class Entry: @unchecked Sendable { weak var host: CoreHost? }
    private static let table = Locked<[String: Entry]>([:])
    private static let making = NSLock()

    static func key(storage: URL, installHash: String) -> String { storage.standardizedFileURL.path + "|" + installHash }

    /// The live Core of `key`, else the one `make` builds, kept (weakly) for the next.
    static func take(_ key: String, make: () throws(CoreFailure) -> CoreHost) throws(CoreFailure) -> CoreHost {
        making.lock()
        defer { making.unlock() }
        if let h = live(key) { return h }
        let h = try make()
        let e = Entry()
        e.host = h
        table.withLock { t in
            t = t.filter { $0.value.host != nil }
            t[key] = e
        }
        return h
    }

    /// The Core of `key` while something holds it.
    static func live(_ key: String) -> CoreHost? { table.withLock { $0[key]?.host } }
}

/// SDK 4.0.2: the stops of a storage folder in the process: a verified stop of the lease route and a refusal that stops
/// the model (`ModelGate.note`) each count one. A lease request records the count when it goes out, and its answer is
/// handed to the Core only while the count is the same (the Core takes a verified lease even after a stop, quranlab-core
/// core.c:357, so an answer to a request sent before the stop would switch the model back on). Android: Lease.kt:832.
enum LeaseStops {
    private static let counts = Locked<[String: Int]>([:])
    static func current(_ storage: URL) -> Int { counts.withLock { $0[storage.standardizedFileURL.path] ?? 0 } }
    static func bump(_ storage: URL) { counts.withLock { $0[storage.standardizedFileURL.path, default: 0] += 1 } }
}

/// SDK 4.0.2: the lock of a storage folder's lease files in the process (`ProtectedRuntime.storeLease`).
enum FolderLocks {
    private static let locks = Locked<[String: NSLock]>([:])
    static func lock(_ storage: URL) -> NSLock {
        locks.withLock { l in
            let k = storage.standardizedFileURL.path
            if let x = l[k] { return x }
            let x = NSLock()
            l[k] = x
            return x
        }
    }
}

/// 18.4.7.1: the answer the last request of one lease attempt got. An attempt is the
/// token (when it must be renewed), the challenge, attest (when the certificate must be made again) and `model-key`,
/// with 18.4.10's repeats inside it. Bound to the attempt's task (`current`), so the requests record into it.
final class LeaseAttemptTrace: @unchecked Sendable {
    @TaskLocal static var current: LeaseAttemptTrace?

    private let lock = NSLock()
    private var _asked = false, _status = 0, _apiRefusal = false, _retryAfter = 0, _stopped = false
    /// SDK 4.0.2 (18.4.7.3 item 4): the last answer was the SDK's own for a route a `Retry-After` holds; nothing went out.
    private var _held = false
    /// SDK 4.0.1 (28.5): the largest `Retry-After` any host gave the request that went out.
    private var _hostRetryAfter = 0

    /// A request went out (its answer, if any, follows).
    func asking() { lock.withLock { _asked = true; _status = 0; _apiRefusal = false; _retryAfter = 0; _hostRetryAfter = 0; _held = false } }

    /// One host's answer to the request that went out (`HTTPClient.routed` tells each): its `Retry-After`, kept when
    /// it is the largest so far (28.5: an attempt that ended unreachable on every host waits the largest any host gave).
    func hostAnswered(retryAfter: String?) {
        let s = LeaseRetry.retryAfter(retryAfter)
        lock.withLock { _hostRetryAfter = max(_hostRetryAfter, s) }
    }

    /// The answer of the request that went out: its status, whether it is the API's own refusal (a 4xx other than 429
    /// whose body is JSON with an `error` string), and its `Retry-After`.
    func answered(status: Int, body: Data, retryAfter: String?) {
        let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let api = (400...499).contains(status) && status != 429 && (o?["error"] as? String).map { !$0.isEmpty } == true
        lock.withLock { _asked = true; _status = status; _apiRefusal = api; _retryAfter = LeaseRetry.retryAfter(retryAfter) }
    }

    /// The request met a route a `Retry-After` holds (28.11 item 2): the SDK answered it, nothing went out, and the
    /// attempt ends with that answer (`HTTPClient.routed` tells it).
    func metHold() { lock.withLock { _held = true } }
    var wasHeld: Bool { lock.withLock { _held } }

    /// A request of another part of the SDK (the token, attest) that failed: what its error says of the answer.
    func failed(_ e: CloudError) {
        switch e {
        case .rejected(let s, let code, _, _):
            // the HTTP client names a 4xx without the API's JSON error "http_<status>"
            let api = (400...499).contains(s) && s != 429 && !code.hasPrefix("http_") && code != "invalid_response"
            lock.withLock { _asked = true; _status = s; _apiRefusal = api; _retryAfter = 0 }
        case .offline(let why):
            let s = ErrorCause.status(after: "HTTP ", in: why) ?? 0
            lock.withLock { _asked = true; _status = s; _apiRefusal = false; _retryAfter = 0 }
        case .invalid, .badAnswer:
            lock.withLock { _asked = true; _status = 200; _apiRefusal = false; _retryAfter = 0 }
        case .noKey, .storage:
            // nothing was answered (no key; a model file the device could not keep, never a lease request)
            break
        }
    }

    /// A stop the Core verified: the lease is gone, nothing to tell.
    func stop() { lock.withLock { _stopped = true } }

    var asked: Bool { lock.withLock { _asked } }
    var status: Int { lock.withLock { _status } }
    var apiRefusal: Bool { lock.withLock { _apiRefusal } }
    /// 18.4.7 and 28.5: a 429's own `Retry-After` (no other host was asked); for an answer that was unreachable on
    /// every host, the largest any host gave (a `503 lease_unavailable` carries 30).
    var retryAfter: Int { lock.withLock { _status == 429 ? _retryAfter : max(_retryAfter, _hostRetryAfter) } }
    var stopped: Bool { lock.withLock { _stopped } }
}

/// The last lease attempt of this process that brought no lease (18.4.7.1): when it ended, how, and what a report of
/// an open in grace names.
struct LeaseAttemptEnd: Sendable {
    var running = 0
    var endedAtMs: Int64 = 0
    var unreachable = false
    var error: RecognizerError?
    var status = 0
    var reason = "network"
    /// 4.0.1 (28.7): the role of the attempt's last request and whether it was asked of more than one host, for the
    /// report of an open in grace (`host_role`, `fallback`). After a wait that ended before the attempt did: `api`,
    /// and `fallback` not known yet.
    var hostRole: String?
    var fallback: Bool?
}

/// The install's certificate, for the key generation it was issued to.
struct StoredCertificate: Codable, Sendable, Equatable {
    var generation: Int
    var certificate: String
}

/// The protected model of one Client: the Core over the install's key, the install
/// certificate, the lease, the install of each downloaded file to its device form, and the one open model.
///
/// Network: `ensureLease` asks the server only when the Core holds no valid lease for the build. A valid lease never
/// waits for a refresh: one that is due is renewed in the background (`refreshIfDue`), with the retry steps of
/// 18.4.7. Offline with a valid lease the model opens; after `exp` it fails with `needs_connection` and nothing is
/// decrypted.
final class ProtectedRuntime: @unchecked Sendable {
    /// The runtime of the Client in force (set by `QuranLabCloud`).
    static let current = Locked<ProtectedRuntime?>(nil)

    let storage: URL
    let server: LeaseServer?
    let keys: any InstallKeySource
    private let state: any CoreStateKeeping
    private let clocks: any CoreClocks
    private let hostBox = Locked<CoreHost?>(nil)
    private let certFile: JSONFile<StoredCertificate>
    private let leaseFile: JSONFile<LeaseRecord>
    /// The row of failed lease attempts and its next attempt (18.4.7.3), kept across restarts in `cloud/lease-retry.json`.
    private let retry: Locked<LeaseRetry>
    private let retryFile: JSONFile<LeaseRetry>
    private let refreshing = Locked<Task<Void, Never>?>(nil)
    private let flight = LeaseFlight()
    /// The one open model (the Core has one at a time) and the build folder it came from.
    private let open = Locked<(model: CoreModel, folder: URL)?>(nil)
    /// The build folder used last (the timer's refresh uses its manifest).
    private let lastFolder = Locked<ModelFolder?>(nil)
    /// Told every verified stop (the Client's model gate), every lease outcome (analytics) and every issue to report.
    var onStop: @Sendable (RecognizerError) -> Void = { _ in }
    var onLease: @Sendable (LeaseOutcome) -> Void = { _ in }
    var onIssue: @Sendable (_ kind: String, _ code: String) -> Void = { _, _ in }
    /// Told the cause of a background renewal that failed.
    var onSilent: @Sendable (ErrorCause) -> Void = { _ in }
    /// The last failure of the lease route with its cause: what the error alone does not
    /// say (a stop the Core verified, a stop it did not act on, a lease the Core refused or found past its end). Nil
    /// once a lease is accepted.
    let lastFailure = Locked<CausedFailure?>(nil)
    /// Told each take the recited journal finishes at a start (17.6): a take a killed process left open, or one the
    /// SDK's analytics had not counted yet (`pendingTakes`).
    var onRecovered: @Sendable (_ take: UInt64, _ range: CoreRecited?) -> Void = { _, _ in }
    var pendingTakes: @Sendable () -> [UInt64] = { [] }
    /// The Cores whose recited index is loaded.
    private let recitedHosts = Locked<[ObjectIdentifier]>([])
    /// 18.4.7.1: the attempts of this process (how many run, how the last one without a lease ended).
    private let attempts = Locked(LeaseAttemptEnd())
    /// How long a model open past `exp` waits for its attempt (10 s), and how long an unreachable outcome serves the
    /// next open with no request (60 s). Tests shorten them.
    var graceWait: TimeInterval = 10
    var graceReuse: TimeInterval = 60
    /// 18.4.7.1, ERRORS_40 24.3: the reasons a report of an open in grace names.
    static let graceReasons: Set<String> = ["network", "timeout", "http", "rate_limited", "redirect", "invalid_answer", "invalid", "lease_unavailable"]

    init(storage: URL, server: LeaseServer?, keys: any InstallKeySource, state: (any CoreStateKeeping)? = nil,
         clocks: any CoreClocks = SystemClocks()) {
        self.storage = storage
        self.server = server
        self.keys = keys
        self.state = state ?? KeychainCoreState(storage: storage)
        self.clocks = clocks
        certFile = JSONFile(url: storage.appendingPathComponent("cloud/install-cert.json"))
        // 28.11 item 3 (SDK 4.0.2): the lease's row of failures, as the last process left it; unreadable is taken as none
        // here, because an attempt may then come sooner, as before 4.0.2
        let rf = JSONFile<LeaseRetry>(url: storage.appendingPathComponent("cloud/lease-retry.json"))
        retryFile = rf
        retry = Locked((rf.read().takingUnreadableAsMissing ?? LeaseRetry()).readBack(now: clocks.wallMs() / 1000))
        leaseFile = JSONFile(url: storage.appendingPathComponent("cloud/lease.json"))
        // a compiled accelerator program that a process left in the dispatch folder when it ended during a prepare
        // (the Core deletes it before the call returns, the SDK after it; a process that ends first leaves it): it
        // goes at the start, before anything else (Stage B, the iPhone: a launch that ended 1 s after it began loading
        // the promoted build left the program there)
        AcceleratorGate.clearDispatch(storage: storage)
    }

    /// The Core over the current install key, made at first use. Nil key: the install has never attested, and the
    /// Core cannot hold a lease yet (a first key is made by `ensureLease`).
    func host() throws(RecognizerError) -> CoreHost? {
        if let h = hostBox.withLock({ $0 }) { return h }
        guard let key = keys.current() else { return nil }
        let platform = CorePlatform(storage: CoreStorage(root: storage), key: key, state: state, clocks: clocks)
        do throws(CoreFailure) {
            // SDK 4.0.2: the Core a closed Client of this folder still holds, when there is one (`LiveCores`)
            let h = try LiveCores.take(LiveCores.key(storage: storage, installHash: key.installHash)) { () throws(CoreFailure) -> CoreHost in
                try CoreHost(platform: platform)
            }
            hostBox.withLock { $0 = h }
            return h
        } catch {
            throw error.recognizerError
        }
    }

    var leaseRecord: LeaseRecord? { leaseFile.read().takingUnreadableAsMissing }

    /// SDK 4.0.1 (28.4): the model folder of the lease this install holds for `build` (its accepted `base`, valid or
    /// not: the folder is where the build's files are, and every answer from it is held to the signed manifest), else
    /// nil. `CDNClient.manifest` reads the build's manifest from there through the `models` hosts.
    func leaseFolder(_ build: String) -> URL? {
        guard let rec = leaseRecord, rec.build.lowercased() == build.lowercased() else { return nil }
        return Self.acceptedBase(rec.base.flatMap { URL(string: $0) })
    }

    /// `diagnose()`'s protected state (the C SDK's `protected` object): the key store, the lease and its grace, the
    /// install's class, the Core.
    func diagnosis() -> TajweedDiagnosis.Protected {
        let store = keys.current().map { $0.hardware ? "secureEnclave" : ($0 is SoftwareInstallKey ? "file" : "keychain") }
        let host = try? self.host()
        let s = host?.tick() ?? CoreLeaseStatus()
        let g = host?.leaseGrace() ?? (inGrace: false, until: 0)
        let lease = host == nil || !s.hasLease ? (s.stopped ? "stopped" : "none")
            : s.stopped ? "stopped" : s.valid ? "valid" : g.inGrace ? "grace" : "expired"
        let live = lease != "none" && lease != "stopped"
        // the lease's flags, bit 3 (18.4.6), as the Core reads them (qlc_accel_allowed)
        let cls: String? = live ? host?.accelAllowed().flatMap { $0 == 1 ? "attested" : $0 == 0 ? "standard" : nil } : nil
        return TajweedDiagnosis.Protected(keyStore: store, lease: lease,
                                          leaseExpires: lease != "none" && s.expiresAt > 0 ? s.expiresAt : nil,
                                          leaseClass: cls, refreshAfter: live && s.refreshAfter > 0 ? s.refreshAfter : nil,
                                          graceUntil: lease == "grace" ? g.until : nil, core: host == nil ? nil : CoreHost.version)
    }

    /// The background refresh's backoff as it stands (18.4.7).
    var retryState: LeaseRetry { retry.withLock { $0 } }

    /// The Core's view of its lease now (the background timer; never the audio thread).
    func status() -> CoreLeaseStatus { (try? self.host())?.tick() ?? CoreLeaseStatus() }

    /// Whether the Core holds a valid lease for `build`.
    func hasValidLease(build: String) -> Bool {
        let s = status()
        return s.valid && leaseRecord?.build == build
    }

    // MARK: the lease

    /// A valid lease for the build of `manifest`: the one the Core holds, else a new one from the server. The
    /// answer's `base` names where the build's ciphertext is.
    func ensureLease(_ m: ModelManifest) async throws(RecognizerError) -> LeaseRecord {
        #if DEBUG
        // tests only (StagingHooks.core): the lease answer of a stand-in for the Core
        if let standIn = StagingHooks.core.withLock({ $0 }) {
            do { return try await standIn.lease(m) } catch { throw (error as? RecognizerError) ?? .offline("needs_connection: \(error)") }
        }
        #endif
        guard m.encryption != nil else { throw .modelIncompatible("\(m.modelID) \(m.version) is not a protected build; SDK 4.0 runs protected builds only") }
        if let h = try self.host() {
            let s = h.tick()
            if s.valid, let r = leaseRecord, r.build == m.build {
                if s.refreshDue { refreshInBackground(m, now: s.now) }
                return r
            }
            // 18.4.7.1: this build's lease has expired: an attempt first, then the Core's grace decides
            if s.hasLease, !s.stopped, let r = leaseRecord, r.build == m.build {
                return try await pastExp(m, host: h, record: r)
            }
        }
        return try await flight.run(m.build) { () async throws(RecognizerError) -> LeaseRecord in
            try await self.fetchLease(m)
        }
    }

    /// A model open past the lease's `exp` (18.4.7.1): an unreachable outcome of this process less than a minute old
    /// serves it with no request; else one attempt (joining one that runs), waited for at most 10 s. With no outcome by
    /// then the Core is told unreachable and the attempt goes on: its answer is used when it comes (a lease accepted, a
    /// refusal told). The Core decides the open (`qlc_lease_grace`, then `qlc_model_open`); each open in grace is a
    /// silent report (lease, grace, the status and reason that ended the attempt).
    private func pastExp(_ m: ModelManifest, host: CoreHost, record: LeaseRecord) async throws(RecognizerError) -> LeaseRecord {
        // 18.4.7.3 item 3 (SDK 4.0.2): an open in the grace is an attempt of the SDK's own, and waits for the row of
        // failures; without a grace the open cannot go on, and asks at once (item 4)
        if !retry.withLock({ $0.due(now: clocks.wallMs() / 1000) }), let r = inGrace(host, record) { return r }
        let now = clocks.wallMs()
        let recent = attempts.withLock { a -> RecognizerError? in
            a.running == 0 && a.unreachable && a.endedAtMs > 0 && now - a.endedAtMs < Int64(graceReuse * 1000) ? a.error : nil
        }
        if let e = recent {
            if let r = inGrace(host, record) { return r }
            throw e
        }
        let attempt = Task { () -> Result<LeaseRecord, RecognizerError> in
            do throws(RecognizerError) {
                return .success(try await self.flight.run(m.build) { () async throws(RecognizerError) -> LeaseRecord in
                    try await self.fetchLease(m)
                })
            } catch {
                return .failure(error)
            }
        }
        switch await Self.wait(attempt, seconds: graceWait) {
        case .some(.success(let r)):
            return r
        case .some(.failure(let e)):
            if let r = inGrace(host, record) { return r }
            throw e
        case .none:
            host.leaseAttempt(refused: false)
            attempts.withLock { $0.status = 0; $0.reason = "timeout"; $0.hostRole = EndpointRole.api.rawValue; $0.fallback = nil }
            if let r = inGrace(host, record) { return r }
            throw .offline("needs_connection: the lease has expired and Quran Lab did not answer within \(Int(graceWait)) s")
        }
    }

    /// The record of a lease in its grace, the open reported; nil when
    /// the Core gives none.
    private func inGrace(_ host: CoreHost, _ record: LeaseRecord) -> LeaseRecord? {
        // the Core in force now (an attempt that made a new install certificate made a new Core)
        let host = (try? self.host()) ?? host
        guard host.leaseGrace().inGrace else { return nil }
        let (status, reason, role, fallback) = attempts.withLock { ($0.status, $0.reason, $0.hostRole, $0.fallback) }
        // 4.0.1 (28.7): the report names the role of the attempt's request and whether it went to another host. It is
        // made here, outside the attempt's operation, so `ErrorCause.traced` would find no request
        onSilent(ErrorCause(stage: "lease", reason: "grace", httpStatus: status > 0 ? status : nil, errorCode: reason,
                            hostRole: role, fallback: role == nil ? nil : fallback))
        return record
    }

    /// A task's result within `seconds`, or nil; the task goes on either way.
    static func wait<T: Sendable>(_ task: Task<T, Never>, seconds: TimeInterval) async -> T? {
        let once = Locked(false)
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            Task {
                let v = await task.value
                if once.withLock({ (d: inout Bool) -> Bool in defer { d = true }; return !d }) { c.resume(returning: v) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if once.withLock({ (d: inout Bool) -> Bool in defer { d = true }; return !d }) { c.resume(returning: nil) }
            }
        }
    }

    /// A new lease for the build now, whatever the Core holds (the background refresh; tests).
    func renew(_ m: ModelManifest) async throws(RecognizerError) -> LeaseRecord {
        try await flight.run(m.build) { () async throws(RecognizerError) -> LeaseRecord in try await self.fetchLease(m) }
    }

    /// At an app start or model open: a refresh in the background when the lease is past `refresh_after` and the
    /// retry steps allow it. Returns at once.
    func refreshIfDue(_ folder: ModelFolder) {
        lastFolder.withLock { $0 = folder }
        guard let h = try? self.host() else { return }
        let s = h.tick()
        guard s.hasLease, s.refreshDue, leaseRecord?.build == folder.manifest.build else { return }
        refreshInBackground(folder.manifest, now: s.now)
    }

    /// The background timer (every minute while the app is in use): the Core folds its usage and journal and saves
    /// its state, and a refresh that is due starts.
    func tick() {
        guard let h = try? self.host() else { return }
        let s = h.tick()
        if s.hasLease, s.refreshDue, let f = lastFolder.withLock({ $0 }), leaseRecord?.build == f.manifest.build {
            refreshInBackground(f.manifest, now: s.now)
        }
    }

    private func refreshInBackground(_ m: ModelManifest, now: Int64) {
        // the row's next attempt is on the device's wall clock, as it was written and as a restart reads it back (the
        // Core's `now` is its own clock, anchored at the lease)
        guard retry.withLock({ $0.due(now: clocks.wallMs() / 1000) }) else { return }
        let started = refreshing.withLock { (t: inout Task<Void, Never>?) -> Bool in
            if t != nil { return false }
            t = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                do throws(RecognizerError) {
                    _ = try await self.renew(m)
                } catch {
                    self.onSilent(ErrorCause.lease(error, runtime: self))
                }
                self.refreshing.withLock { $0 = nil }
            }
            return true
        }
        _ = started
    }

    /// The install's certificate for its current key; a new key and a new certificate when it has none, when it is
    /// over, or when `renew` (the server answered `install_cert_invalid`). A new key the server refuses is deleted
    /// and the old one kept.
    func certificate(renew: Bool = false) async throws(RecognizerError) -> InstallCertificate {
        guard let server else { throw .offline("no developer key configured") }
        let now = clocks.wallMs() / 1000
        if !renew, let key = keys.current(), let stored = certFile.read().takingUnreadableAsMissing, stored.generation == keys.generation,
           let c = InstallCertificate.parse(stored.certificate, trustedKeys: server.trustedKeys), c.isFor(installHash: key.installHash),
           c.expiresAt > now + 60 {
            return c
        }
        guard let next = keys.makeNext() else { throw .storageFailed("the install key store made no key") }
        let text: String
        do throws(CloudError) {
            text = try await server.certify(next.key)
        } catch {
            LeaseAttemptTrace.current?.failed(error)
            keys.discard(generation: next.generation)
            if case .rejected(_, let code, _, _) = error, code == "install_sig_invalid" { onIssue("other", "install_sig_invalid") }
            throw error.recognizerError
        }
        guard let c = InstallCertificate.parse(text, trustedKeys: server.trustedKeys), c.isFor(installHash: next.key.installHash) else {
            keys.discard(generation: next.generation)
            onIssue("other", "install_cert_unreadable")
            throw .serverRejected(status: 0, code: "invalid_response", message: "the install certificate does not verify")
        }
        keys.promote(next.key, generation: next.generation)
        certFile.write(StoredCertificate(generation: next.generation, certificate: text))
        // the Core over the new key: its lease part starts over, the clock's floor and the usage carry over. A model
        // open on the old Core keeps that Core until it closes.
        hostBox.withLock { $0 = nil }
        return c
    }

    /// One lease attempt (18.4.7.1): `request`, and when it brings no lease, its outcome told to the Core by the answer
    /// that ended it: refused for the API's own refusal (after 18.4.10's repeats inside it), unreachable for anything
    /// else (no answer, a stall, a 5xx, a 429, a redirect, a page that is not the API's, a 2xx that is not a lease the
    /// Core accepts). An attempt that asked nothing of the server is not told, nor a verified stop (the Core cleared
    /// the lease). The Core keeps it with the lease in its saved state.
    private func fetchLease(_ m: ModelManifest) async throws(RecognizerError) -> LeaseRecord {
        let trace = LeaseAttemptTrace()
        attempts.withLock { $0.running += 1 }
        defer { attempts.withLock { $0.running -= 1 } }
        // one operation for the causes it makes (4.0.1, RequestTrace)
        let (result, last) = await RequestTrace.scope { () async -> (Result<LeaseRecord, RecognizerError>, RequestTrace.Entry?) in
            let r = await LeaseAttemptTrace.$current.withValue(trace) { () async -> Result<LeaseRecord, RecognizerError> in
                do throws(RecognizerError) {
                    return .success(try await self.request(m))
                } catch {
                    return .failure(error)
                }
            }
            // the attempt's last request through a role (28.7), for the report of an open in grace
            return (r, RequestTrace.last)
        }
        switch result {
        case .success(let r):
            attempts.withLock { $0.endedAtMs = 0; $0.unreachable = false; $0.error = nil; $0.hostRole = nil; $0.fallback = nil }
            return r
        case .failure(let e):
            told(e, trace, last)
            throw e
        }
    }

    private func told(_ e: RecognizerError, _ trace: LeaseAttemptTrace, _ last: RequestTrace.Entry? = nil) {
        guard trace.asked, !trace.stopped else { return }
        (try? host())?.leaseAttempt(refused: trace.apiRefusal)
        let cause = lastFailure.withLock { $0?.cause }
        let reason = Self.graceReason(cause, status: trace.status)
        let now = clocks.wallMs()
        attempts.withLock { a in
            a.endedAtMs = now
            a.unreachable = !trace.apiRefusal
            a.error = e
            a.status = trace.status
            a.reason = reason
            a.hostRole = last?.role.rawValue
            a.fallback = last?.fallback
        }
    }

    /// The 24.3 reason of the failure that ended an attempt, as the report of an open in grace names it.
    static func graceReason(_ cause: ErrorCause?, status: Int) -> String {
        if let r = cause?.reason, graceReasons.contains(r) { return r }
        switch status {
        case 0: return "network"
        case 429: return "rate_limited"
        case 300...399: return "redirect"
        case 200...299: return "invalid"
        default: return "http"
        }
    }

    /// `POST /v1/model-key` until a lease is accepted or a refusal decides (18.4.10). Each repeat the table allows
    /// happens at most once.
    private func request(_ m: ModelManifest) async throws(RecognizerError) -> LeaseRecord {
        guard let server else { throw .offline("no developer key configured") }
        guard let enc = m.encryption, let raw = m.raw else { throw .modelIncompatible("not a protected build") }
        // 18.4.7.3 item 4 (SDK 4.0.2): the lease route held by a Retry-After: the attempt fails as that answer did and
        // asks nothing, no certificate, token or challenge first
        if let held = server.transport.held(server.apiURL.appendingPathComponent("v1/model-key")) {
            let trace = LeaseAttemptTrace.current
            trace?.asking()
            trace?.answered(status: held.status, body: held.body, retryAfter: held.header("Retry-After"))
            trace?.metHold()
            let o = (try? JSONSerialization.jsonObject(with: held.body)) as? [String: Any]
            let cause: ErrorCause? = held.status == 503 && (o?["error"] as? String) == "lease_unavailable"
                ? ErrorCause(stage: "lease", reason: "lease_unavailable", httpStatus: 503, errorCode: "lease_unavailable") : nil
            return try fail(LeaseRefusal.classify(status: held.status, body: held.body).error(status: held.status, body: held.body),
                            .offline, now: clocks.wallMs() / 1000, cause: cause)
        }
        var renewToken = false, reattested = false, rechallenged = false, pieceFallback = false
        // 18.4.10 (4.0.1, endpoints_40.json's attempts): after invalid_token the request is repeated once with the
        // renewed token and the SAME challenge (a challenge is a stateless HMAC good on every api host, 28.5); 4.0.0
        // asked a new one
        var keptChallenge: String?
        var cert = try await certificate()
        let now = { self.clocks.wallMs() / 1000 }
        let trace = LeaseAttemptTrace.current
        while true {
            guard let host = try self.host() else { throw .storageFailed("no install key") }
            let token: String
            let challenge: String
            do throws(CloudError) {
                token = try await server.token(renewToken)
            } catch {
                trace?.failed(error)
                return try fail(error.recognizerError, .offline, now: now())
            }
            do throws(CloudError) {
                if let kept = keptChallenge {
                    challenge = kept
                    keptChallenge = nil
                } else {
                    challenge = try await self.challenge(server, token: token)
                }
            } catch {
                return try fail(error.recognizerError, .offline, now: now())
            }
            let ask: (core: [String: Any], installSig: String)
            do throws(CoreFailure) { ask = try host.leaseAsk(challenge: challenge, build: m.build) } catch {
                return try fail(error.recognizerError, .other, now: now())
            }
            let body: [String: Any] = [
                "v": 1, "platform": server.platform, "install_cert": cert.encoded,
                "install_key": host.platform.key.spki.base64URL, "install_sign_key": host.platform.key.spki.base64URL,
                "challenge": challenge, "install_sig": ask.installSig, "model": m.modelID, "version": m.version, "build": m.build,
                "key_id": enc.keyID, "core": ask.core,
            ]
            let resp: HTTPClient.Response
            // 28.3, 18.4.7.1 (4.0.1): the answer this route asks for is a lease answer of 18.4.5 (its `base` on an
            // allowed host, 28.4) whose lease the Core accepts; another 2xx is unreachable on that host, and the next
            // `api` host is asked. The Core's verdict on the answer that ended the request is kept, so it is asked once.
            let verdict = Locked<(body: Data, result: Result<(expiresAt: Int64, refreshAfter: Int64), CoreFailure>)?>(nil)
            let build = m.build
            let leases = leaseFile, folderLock = FolderLocks.lock(storage), folder = storage
            // SDK 4.0.2: the folder's stops as this request goes out (`LeaseStops`)
            let sentStops = LeaseStops.current(storage)
            let accept: @Sendable (HTTPClient.Response) -> Bool = { (a: HTTPClient.Response) -> Bool in
                guard a.status == 200, let answer = LeaseAnswer.parse(a.body), Self.acceptedBase(answer.base) != nil else { return false }
                let result: Result<(expiresAt: Int64, refreshAfter: Int64), CoreFailure>
                // SDK 4.0.2: a lease older than the one this folder holds (an attempt of a closed Client, answered after
                // a newer one) is taken as answered and never handed to the Core; nor is one answered after a stop
                folderLock.lock()
                if LeaseStops.current(folder) != sentStops {
                    result = .failure(Self.stoppedSinceSent)
                } else if let saved = Self.newer(than: answer, build: build, in: leases) {
                    result = .success((saved.expiresAt, saved.refreshAfter))
                } else {
                    do throws(CoreFailure) { result = .success(try host.leaseAccept(answer.lease, manifest: raw, build: build)) } catch {
                        result = .failure(error)
                    }
                }
                folderLock.unlock()
                verdict.withLock { $0 = (a.body, result) }
                if case .success = result { return true }
                // an answer after a stop ends the request on this host (no other host is asked for it)
                if case .failure(let f) = result, f == Self.stoppedSinceSent { return true }
                return false
            }
            do throws(CloudError) {
                var r = try HTTPClient.jsonRequest(server.apiURL.appendingPathComponent("v1/model-key"), body: body, auth: token)
                r.timeoutInterval = 30
                trace?.asking()
                resp = try await server.transport.send(r, accepting: accept)
            } catch {
                return try fail(error.recognizerError, .offline, now: now())
            }
            trace?.answered(status: resp.status, body: resp.body, retryAfter: resp.header("Retry-After"))
            if resp.status == 200 {
                guard let answer = LeaseAnswer.parse(resp.body) else {
                    onIssue("other", "lease_answer_unreadable")
                    return try fail(.serverRejected(status: 200, code: "invalid_response", message: "the lease answer is not one"), .other, now: now())
                }
                // 28.4 (4.0.1): a `base` off the allow-list makes no lease answer of 18.4.5 (4.0.0 accepted the lease and
                // then had no folder to fetch from)
                guard let base = Self.acceptedBase(answer.base) else {
                    return try fail(.serverRejected(status: 200, code: "invalid_response", message: "the lease answer names no model folder of Quran Lab's"),
                                    .other, now: now())
                }
                // SDK 4.0.2: an older lease than the folder's own changes nothing (see `accept`)
                let kept = folderLock.withLock { Self.newer(than: answer, build: m.build, in: leases) }
                if let kept {
                    lastFailure.withLock { $0 = nil }
                    return kept
                }
                let accepted: (expiresAt: Int64, refreshAfter: Int64)
                do throws(CoreFailure) {
                    if let kept = verdict.withLock({ $0 }), kept.body == resp.body {
                        accepted = try kept.result.get()
                    } else {
                        let build = m.build
                        let r = folderLock.withLock { () -> Result<(expiresAt: Int64, refreshAfter: Int64), CoreFailure> in
                            if LeaseStops.current(folder) != sentStops { return .failure(Self.stoppedSinceSent) }
                            do throws(CoreFailure) { return .success(try host.leaseAccept(answer.lease, manifest: raw, build: build)) } catch {
                                return .failure(error)
                            }
                        }
                        accepted = try r.get()
                    }
                } catch {
                    // SDK 4.0.2: a stop came while this request was on its way: its lease is not taken, nothing is stored
                    if error == Self.stoppedSinceSent {
                        throw .serverRejected(status: 0, code: "stopped", message: "a stop arrived while this lease request was on its way")
                    }
                    // the Core refused the lease (another install's, another release's, expired by its clock)
                    let outcome: LeaseOutcome = error.detail == Self.leaseExpiredDetail ? .expired : .refused
                    let cause = ErrorCause(stage: "lease", reason: outcome == .expired ? "expired" : "invalid", errorCode: String(error.status))
                    return try fail(error.recognizerError, outcome, now: now(), cause: cause)
                }
                // 18.4.5, 18.6.7 (spec fix 16, quranlab-core d128af8): the answer's piece right after the accept of
                // the same answer, always. The Core keeps it pending (in its saved state too) and puts it in force at
                // the next model open; a piece is the last good one only once a lease asked under it was accepted and a
                // model opened after that. A piece that does not verify changes nothing.
                if let p = answer.piece { host.piece(p) }
                if let c = answer.certificate, let parsed = InstallCertificate.parse(c, trustedKeys: server.trustedKeys),
                   parsed.isFor(installHash: host.installHash) {
                    certFile.write(StoredCertificate(generation: keys.generation, certificate: c))
                }
                let rec = LeaseRecord(build: m.build, base: base.absoluteString,
                                      expiresAt: accepted.expiresAt, refreshAfter: accepted.refreshAfter, issuedAt: answer.issuedAt)
                #if DEBUG
                StagingHooks.beforeLeaseStore.withLock { $0 }?()
                #endif
                storeLease(rec)
                lastFailure.withLock { $0 = nil }
                onLease(.ok)
                return rec
            }
            // every refusal of this route (a 4xx with a body, 429 aside: 18.4.10) goes to the Core: a stop is acted on
            // only when the Core verifies its signature, and any refusal while a new data piece is in force sends the
            // Core back to its last good piece (18.6.7). 429, 5xx and anything else are never refusals.
            let refusable = (400...499).contains(resp.status) && resp.status != 429 && !resp.body.isEmpty
            // SDK 4.0.2: a verified stop, its count (`LeaseStops`) and its clear of the lease files under the folder's lock,
            // so a store or an accept of another request comes wholly before it or not at all
            let stopped = refusable && folderLock.withLock { () -> Bool in
                guard host.refusal(resp.body, apiKeyID: cert.key.isEmpty ? TokenProvider.keyID(server.key) : cert.key) else { return false }
                LeaseStops.bump(folder)
                // 18.4.7.3 item 5: a verified stop ends the row of failures; the lease files go, never through the
                // monotonic check (`storeLease`)
                endRetryRow()
                leaseFile.delete()
                return true
            }
            let refusal = LeaseRefusal.classify(status: resp.status, body: resp.body)
            if stopped {
                // a model that is open keeps running until it is closed (15.3); the Core removes the files then
                let e = refusal.error(status: resp.status, body: resp.body)
                // contract 24.4 rule 3: a stop the Core verified, reported with reason `stopped`
                var cause = ErrorCause.of(e, stage: "lease")
                cause.reason = "stopped"
                let failure = CausedFailure(error: e, cause: cause)
                lastFailure.withLock { $0 = failure }
                trace?.stop()
                onStop(e)
                onLease(.refused)
                throw e
            }
            switch refusal {
            case .renewToken where !renewToken:
                renewToken = true
                keptChallenge = challenge
            case .newChallenge where !rechallenged:
                rechallenged = true
            case .reattest where !reattested:
                reattested = true
                cert = try await certificate(renew: true)
            case .stop(let error, let reason):
                // a stop that is not signed by a pinned key for this request is not acted on (18.4.10); the app's call
                // gets `server_rejected` with its error, and nothing is removed
                let cause = ErrorCause(stage: "lease", reason: "refused", httpStatus: resp.status, errorCode: reason ?? error)
                return try fail(.offline("an unsigned stop on the lease route was not acted on"), .refused, now: now(), cause: cause)
            case .sdkBug:
                onIssue("other", "bad_request:model-key")
                return try fail(refusal.error(status: resp.status, body: resp.body), .other, now: now())
            case .refused(code: "lease_integrity_failed", why: .some("core"))
                where !pieceFallback && ((ask.core["piece"] as? Int) ?? 0) != 0:
                // 18.6.7: a proof refused while a new data piece was in force. The refusal above sent the Core back to
                // its last good piece; the request is asked once more under it (the lease in force covers a bad piece)
                pieceFallback = true
            case .refused(let code, _):
                // an attestation or integrity the server did not accept (24.3 `lease`): `server_rejected`, never a stop
                let reason = code == "lease_integrity_failed" ? "integrity_failed" : code.hasPrefix("lease_attestation") ? "attestation_failed" : "refused"
                // 24.3 (69326fb): an integrity refusal's error_code is the check it names (`verdict:boot`, `core`)
                let body = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]
                let errorCode = code == "lease_integrity_failed" ? (HTTPClient.reason(body) ?? code) : code
                let cause = ErrorCause(stage: "lease", reason: reason, httpStatus: resp.status, errorCode: errorCode)
                return try fail(refusal.error(status: resp.status, body: resp.body), code.hasPrefix("lease_attestation") ? .attestation : .refused,
                                now: now(), cause: cause)
            case .sdkTooOld, .buildUnknown, .routeOff:
                return try fail(refusal.error(status: resp.status, body: resp.body), .refused, now: now())
            default:
                // 503 `lease_unavailable`: a dependency of the route is down; never a refusal, the next
                // attempt after its Retry-After; reported as its own reason (24.3)
                let o = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]
                let cause: ErrorCause? = resp.status == 503 && (o?["error"] as? String) == "lease_unavailable"
                    ? ErrorCause(stage: "lease", reason: "lease_unavailable", httpStatus: 503, errorCode: "lease_unavailable") : nil
                return try fail(refusal.error(status: resp.status, body: resp.body), .offline, now: now(), cause: cause)
            }
        }
    }

    /// A failed lease request: counted, the retry steps advanced, its cause kept (`cause`, else the error's own), and
    /// the error thrown.
    private func fail(_ e: RecognizerError, _ outcome: LeaseOutcome, now: Int64, cause: ErrorCause? = nil) throws(RecognizerError) -> LeaseRecord {
        // 4.0.1: with the role of the request that failed and whether it was asked of more than one host (24.2)
        let failure = CausedFailure(error: e, cause: (cause ?? ErrorCause.of(e, stage: "lease")).traced())
        lastFailure.withLock { $0 = failure }
        let retryAfter = LeaseAttemptTrace.current?.retryAfter ?? 0
        // 18.4.7.3 item 4: an attempt that met a held route sent nothing; it is no failed attempt and moves no wait
        if LeaseAttemptTrace.current?.wasHeld != true {
            let row = retry.withLock { (r: inout LeaseRetry) -> LeaseRetry in
                r.failed(now: now, retryAfter: retryAfter)
                return r
            }
            retryFile.write(row)
        }
        onLease(outcome)
        throw e
    }

    /// A lease answered after a stop of this folder that came while its request was on its way (`LeaseStops`).
    static let stoppedSinceSent = CoreFailure(status: Int(QLC_E_STOPPED), detail: 0, call: "a stop since the lease request was sent")

    /// The lease the folder holds when it is newer than `answer` (the same build, a later server issue time): an older
    /// lease is never put in its place. Called with the folder's lock held.
    static func newer(than answer: LeaseAnswer, build: String, in file: JSONFile<LeaseRecord>) -> LeaseRecord? {
        guard let saved = file.read().takingUnreadableAsMissing, saved.build == build, let s = saved.issuedAt, answer.issuedAt < s else { return nil }
        return saved
    }

    /// SDK 4.0.2: `cloud/lease.json` and the row of failures, under the folder's lock as one read, compare and write: a
    /// lease whose server issue time is older than the saved one of its build never replaces it (nor ends the row), and
    /// none is stored once the Core is stopped (a verified stop that came while this store waited: the stop's clear,
    /// under the same lock, is the last word). True when `rec` was stored.
    @discardableResult
    func storeLease(_ rec: LeaseRecord) -> Bool {
        let lock = FolderLocks.lock(storage)
        lock.lock()
        defer { lock.unlock() }
        if let h = hostBox.withLock({ $0 }), h.tick().stopped { return false }
        if let saved = leaseFile.read().takingUnreadableAsMissing, saved.build == rec.build, let s = saved.issuedAt,
           let n = rec.issuedAt, n < s {
            return false
        }
        leaseFile.write(rec)
        endRetryRow()
        return true
    }

    /// The row of failures ends (a lease the Core accepted, a verified stop), here and on disk.
    private func endRetryRow() {
        retry.withLock { $0.succeeded() }
        retryFile.delete()
    }

    /// `GET /v1/attest/challenge` with the key and the app token (18.4.1 step 3: the challenge is bound to the token's
    /// key while the protected model is on).
    private func challenge(_ server: LeaseServer, token: String) async throws(CloudError) -> String {
        var r = URLRequest(url: server.apiURL.appendingPathComponent("v1/attest/challenge"))
        r.setValue(server.key, forHTTPHeaderField: "x-qlab-key")
        r.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        LeaseAttemptTrace.current?.asking()
        // 28.3: the answer asked for is a challenge in the strict form; another 2xx is unreachable on that host
        let resp = try await server.transport.send(r, accepting: { (a: HTTPClient.Response) -> Bool in
            (200..<300).contains(a.status) && Self.strictChallenge(a.body) != nil
        })
        LeaseAttemptTrace.current?.answered(status: resp.status, body: resp.body, retryAfter: resp.header("Retry-After"))
        guard (200..<300).contains(resp.status) else {
            if resp.status >= 500 { throw .offline("HTTP \(resp.status)") }
            let o = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]
            throw .rejected(status: resp.status, code: o?["error"] as? String ?? "http_\(resp.status)", message: HTTPClient.message(o),
                            reason: HTTPClient.reason(o))
        }
        guard let c = Self.strictChallenge(resp.body) else { throw .invalid("no challenge in the strict form") }
        return c
    }

    /// The challenge of an answer, when it is one in the strict form (`c1.<10 digits>.<22>.<22>`).
    static func strictChallenge(_ body: Data) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let c = o["challenge"] as? String,
              c.range(of: #"^c1\.[0-9]{10}\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{22}$"#, options: .regularExpression) != nil else { return nil }
        return c
    }

    /// The Core's lease refusal `expired` (qlcore.h `QLC_D_LEASE_EXPIRED`).
    static let leaseExpiredDetail = Int(QLC_D_LEASE_EXPIRED)

    /// A model folder URL from a lease answer is used only on Quran Lab's own hosts, over https (28.4, SDK 4.0.1): a
    /// host of the allow-list (`quranlab.ai`, `tajweedformer.com`, `quran-lab.com` or a name under one; 4.0.0 took
    /// `*.quranlab.ai` only), a path that starts and ends in '/', printable ASCII, at most 511 characters, and no port,
    /// user, query, fragment, backslash, space or "..". It is the only place a build's files come from (never a config),
    /// asked through the `models` hosts (`CDNFileSource`).
    static func acceptedBase(_ base: URL?) -> URL? {
        guard let base else { return nil }
        if Endpoints.baseParts(base.absoluteString) != nil { return base }
        #if DEBUG
        // debug builds only (StagingHooks): a host a staging test named, over https and in the same form as any other
        if let host = base.host?.lowercased(), StagingHooks.baseHosts.withLock({ $0.contains(host) }),
           var c = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            c.host = "staging.quranlab.ai"
            if let named = c.url, Endpoints.baseParts(named.absoluteString) != nil { return base }
        }
        #endif
        return nil
    }

    // MARK: install and open

    /// One downloaded CDN form to its device form (18.2.1), then the CDN form goes: the device keeps one copy, and it
    /// is ciphertext under a key of this install's lease.
    func install(_ m: ModelManifest, decodedPath: String, in folder: URL) throws(RecognizerError) {
        #if DEBUG
        // tests only (StagingHooks.core): the install of a stand-in for the Core
        if let standIn = StagingHooks.core.withLock({ $0 }) {
            do { return try standIn.install(m, decodedPath, folder) } catch { throw (error as? RecognizerError) ?? .storageFailed("\(error)") }
        }
        #endif
        guard let raw = m.raw, let host = try self.host() else { throw .offline("needs_connection: no install key or lease yet") }
        var closed = false
        while true {
            do throws(CoreFailure) {
                try host.install(manifest: raw, path: decodedPath, in: folder)
                return
            } catch {
                if error.isBusy, !closed {
                    // Every install goes beside the open model first: another build (its own folder) or another context
                    // installs while it is open (quranlab-core d128af8). The Core refuses only a file that model reads:
                    // a file of its own build with context "*" or its context (the accelerator build's files, the
                    // reference table of the build in use). Then, as qlcore.h says, the model is closed between takes,
                    // the file installed, and the model opens again at the next take (the take runner's CPU engine, the
                    // accelerator's reload).
                    try closeModelForInstall()
                    closed = true
                    continue
                }
                if error.isPlaintextMismatch { onIssue("update_failed", "model_decrypt_failed") }
                throw error.recognizerError
            }
        }
    }

    /// Waits for the open model to have no take on it (at most `timeout`, checked every quarter second), then closes
    /// it. A model in use all that time leaves the install for later (`offline`: the update and
    /// the promotion's download are tried again).
    private func closeModelForInstall(timeout: TimeInterval = 30) throws(RecognizerError) {
        let until = Date().addingTimeInterval(timeout)
        while true {
            guard let o = open.withLock({ $0 }) else { return }
            if o.model.closeIfIdle() {
                open.withLock { if $0?.model === o.model { $0 = nil } }
                return
            }
            if Date() >= until { throw .offline("the model is in a take; its files are installed later") }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// The CPU engine of `context` from the folder's device forms: the open model of another context or build is
    /// closed first (one at a time).
    func openEngine(_ folder: ModelFolder, context: String) throws(RecognizerError) -> CoreStreamEngine {
        try CoreStreamEngine(model: openModel(folder, context: context))
    }

    /// The open model of `folder` and `context`, opened now when it is not (the open model of another context or build
    /// is closed first). Its vocabulary is the folder's (R4), or it is not run.
    func openModel(_ folder: ModelFolder, context: String) throws(RecognizerError) -> CoreModel {
        guard let raw = folder.manifest.raw, let host = try self.host() else { throw .offline("needs_connection: no lease on this device yet") }
        lastFolder.withLock { $0 = folder }
        if let o = open.withLock({ $0 }), o.folder == folder.directory, o.model.context == context, o.model.isOpen, o.model.host === host {
            return o.model
        }
        closeModel()
        let model: CoreModel
        do throws(CoreFailure) {
            model = try host.open(manifest: raw, in: folder.directory, context: context, threads: 0)
        } catch {
            if error.status == QLC_E_FILE {
                // a device form that fails its tag: the folder's device forms go, and the next model() installs again
                removeDeviceForms(folder.directory)
            }
            throw error.recognizerError
        }
        if let names = model.tokens, names != folder.vocabulary.symbols {
            model.close()
            throw .modelIncompatible("the Core's vocabulary of this build is not the one the SDK carries for its tokens hash")
        }
        open.withLock { $0 = (model, folder.directory) }
        prepareRecited(host, folder)
        return model
    }

    // MARK: R2, the accelerator

    /// Whether the lease in force allows accelerator programs (flags bit 3), before the accelerator build is
    /// downloaded: true, false, or nil when the Core cannot say now (no lease, a Core without the call).
    func acceleratorAllowed() -> Bool? {
        guard let h = try? self.host(), let v = h.accelAllowed() else { return nil }
        return v == 1 ? true : v == 0 ? false : nil
    }

    /// The promotion's compile stage: the open model of `folder` and `context` (opened now when it is not), its Core ML
    /// program prepared by the Core in memory (or through a short-lived file in the dispatch folder), and a stream on
    /// it. Seconds long: never on the audio thread or the main thread.
    func prepareAccelerator(_ folder: ModelFolder, context: String, compact: Bool) throws(RecognizerError) -> CoreAcceleratorStream {
        let model = try openModel(folder, context: context)
        let dispatch = AcceleratorGate.dispatchFolder(storage: storage)
        defer { AcceleratorGate.clear(dispatch) }
        switch model.accelPrepare(kind: compact ? "coreml-compact" : "coreml", dispatchDir: dispatch) {
        case .failure(let e):
            onIssue("other", "accel_prepare:\(e.status):\(e.detail)")
            throw e.recognizerError
        case .success(let name):
            return try CoreAcceleratorStream(model: model, name: name)
        }
    }

    /// Whether the recited detector can run on this Core (its build's index loaded).
    func recitedReady(_ host: CoreHost) -> Bool { recitedHosts.withLock { $0.contains(ObjectIdentifier(host)) } }

    /// The build's prebuilt recited index (role `recited`, its SHA-256 pinned in the signed manifest) into the Core,
    /// once per Core; then the takes a killed process left are finished and counted (17.6). A build without the
    /// index leaves the detector off: the app's `reportRecited` counts.
    private func prepareRecited(_ host: CoreHost, _ folder: ModelFolder) {
        guard !recitedReady(host), RecitedSwitch.detectorOn, let raw = folder.manifest.raw,
              let f = folder.manifest.files(role: "recited").first,
              f.isEncrypted ? ModelInstaller.present(f, in: folder.directory) : ModelInstaller.verified(f, in: folder.directory) else { return }
        do throws(CoreFailure) {
            try host.recitedIndex(manifest: raw, in: folder.directory)
        } catch {
            onIssue("other", "recited_index:\(error.status)")
            return
        }
        recitedHosts.withLock { $0.append(ObjectIdentifier(host)) }
        var ids = pendingTakes()
        if let open = host.recitedOpen(), !ids.contains(open) { ids.append(open) }
        // a take the journal finished already keeps its result there (qlc_recited_done, R5); the others are finished now
        var done: [UInt64: CoreRecited?] = [:]
        for d in host.recitedDone() { done[d.take] = d.range }
        for id in ids {
            if let r = done[id] { onRecovered(id, r) } else { onRecovered(id, host.recitedFinish(id, flags: RecitedSwitch.flags)) }
        }
    }

    /// The model open now when it is `folder`'s (the reference reader reads through it).
    func openModel(of folder: ModelFolder) -> CoreModel? {
        guard let o = open.withLock({ $0 }), o.folder == folder.directory, o.model.isOpen else { return nil }
        return o.model
    }

    /// 4.0.1 (Gate C, 2026-11-20): the open model of `folder` closed when nothing runs on it (no call, no take), its
    /// plaintext wiped: a model `client.model()` opened and did not hand out is never left open with no owner. Another
    /// folder's open model, or one in use, is left as it is.
    func closeIdleModel(of folder: ModelFolder) {
        guard let o = open.withLock({ $0 }), o.folder == folder.directory else { return }
        if o.model.closeIfIdle() { open.withLock { if $0?.model === o.model { $0 = nil } } }
    }

    /// The folder of the Core's open model, when one is open.
    var openFolder: URL? { open.withLock { $0?.folder } }

    /// Closes the open model: its plaintext is wiped and released. A take running on it fails.
    func closeModel() {
        let o = open.withLock { (o: inout (model: CoreModel, folder: URL)?) -> CoreModel? in
            defer { o = nil }
            return o?.model
        }
        o?.close()
    }

    private func removeDeviceForms(_ folder: URL) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        var gone: [URL] = []
        for case let u as URL in e where u.path.hasSuffix(".qld") || u.path.hasSuffix(".qld.part") { gone.append(u) }
        for u in gone { try? fm.removeItem(at: u) }
    }
}

/// Whether the recited detector runs, and with which switches (17.1): the config's `flags.analytics` (SDK 4.0: an app
/// has no analytics option), `flags.recited` not false; `flags.recited_twins` false keeps a copy in another surah a
/// rival also on a continuation (`QLC_RECITED_NO_CROSS_SURAH`).
enum RecitedSwitch {
    static var detectorOn: Bool {
        guard let c = QuranLab.cloud else { return false }
        let f = c.currentConfig?.flags ?? RemoteConfig.Flags()
        return f.analytics && f.recited
    }

    static var flags: UInt32 { (QuranLab.cloud?.currentConfig?.flags.recited_twins ?? true) ? 0 : 2 }
}

/// One lease request in flight per build: a second caller waits for the first one's answer.
actor LeaseFlight {
    private var running: [String: Task<Result<LeaseRecord, RecognizerError>, Never>] = [:]

    func run(_ build: String, _ body: @escaping @Sendable () async throws(RecognizerError) -> LeaseRecord) async throws(RecognizerError) -> LeaseRecord {
        if let t = running[build] { return try await t.value.get() }
        let t = Task { () -> Result<LeaseRecord, RecognizerError> in
            do throws(RecognizerError) {
                return .success(try await body())
            } catch {
                return .failure(error)
            }
        }
        running[build] = t
        let r = await t.value
        running[build] = nil
        return try r.get()
    }
}
