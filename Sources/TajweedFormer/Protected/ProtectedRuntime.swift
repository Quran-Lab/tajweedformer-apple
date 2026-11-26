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
    /// SDK 4.0.5 (ERRORS_40 24.14): the app's version and build (`AppIdentity`), as one string; empty when not known.
    var appRelease: String = ""
    /// SDK 4.0.5 (24.14 item 5): clears the App Attest retry hold (`AttestBackoff`) before an attest again.
    var clearAttestHold: @Sendable () -> Void = {}
    /// SDK 4.0.5 (ATTEST_40.md 40.2): an attestation is owed and its next try has come (`TokenProvider.attestationOwedAndDue`);
    /// with `networkBack` whatever the row's wait (the network came back, 40.2 item 4).
    var attestationOwedAndDue: @Sendable (_ networkBack: Bool) -> Bool = { _ in false }
    /// 40.2 item 8: a lease refused for attestation makes the attestation owed now.
    var oweAttestation: @Sendable () -> Void = {}
    /// 40.2 item 10: an upgrade whose full lease did not come owes the attestation again, its next try after `seconds`
    /// (so a restart makes it anew).
    var oweAttestationAfter: @Sendable (_ seconds: Int) -> Void = { _ in }
    /// 40.2: an attestation is owed (whether or not its next try has come).
    var attestationOwed: @Sendable () -> Bool = { false }
    /// 40.3: why the certificate in force was made without App Attest, the lease request's `unattested`; nil for none.
    var unattestedWhy: @Sendable () -> String? = { nil }
    /// 40.6 item 2: `diagnose()`'s attestation, from the certificate in force's `att`.
    var attestation: @Sendable (_ certificateAtt: String?) -> TajweedDiagnosis.Attestation? = { _ in nil }
    /// 40.2 item 1: the config in force says the lease needs attestation (`attest: "required"`). Tests' default: required.
    var attestRequired: @Sendable () -> Bool = { true }
    /// 40.2 item 1: an attested certificate for `key`, or a failure, never one without attestation (the upgrade of a
    /// capped install); nil: no upgrade (tests).
    var upgrade: (@Sendable (_ key: any InstallKey) async throws(CloudError) -> String)? = nil
}

/// SDK 4.0.5 (ERRORS_40 24.14 item 4): a lease refused for attestation (`lease_attestation_required`), remembered with the
/// app's release it was refused to (`cloud/lease-attestation-refusal.json`).
struct AttestationRefusal: Codable, Sendable, Equatable {
    /// The device's wall clock, seconds.
    var at: Int64
    var appRelease: String
    var status: Int
    var code: String
    var message: String

    /// An app call within this many seconds of the refusal gets the same error without a request.
    static let window: Int64 = 600

    /// Whether an app call at `now` of `release` gets the remembered error (the same app release, within the window).
    func holds(now: Int64, release: String) -> Bool { release == appRelease && now >= at && now - at < Self.window }

    var error: RecognizerError { .serverRejected(status: status, code: code, message: message) }
    var cause: ErrorCause { ErrorCause(stage: "lease", reason: "refused", httpStatus: status, errorCode: code) }
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

/// SDK 4.0.5 (ATTEST_40.md 40.2 item 10): an upgrade's target: the next install key (not the install's yet) and its
/// attested certificate, kept for the next try. `host` is the Core over that key made for one try's request, never ticked
/// and its saves held back (`CoreStateGate`) until it accepts the lease; a try that does not switch drops it unsaved.
final class UpgradeTarget: @unchecked Sendable {
    let key: any InstallKey
    let generation: Int
    let certificate: InstallCertificate
    let text: String
    /// The Core of the try in progress (nil between tries): made anew at each try, so it takes the platform's counter
    /// and the state as they are then (Core c3: a Core made earlier would save below the counter).
    var host: CoreHost?
    /// The full lease's failed tries and the next one (unix seconds of the wall clock), by 40.2 item 4's schedule.
    var failures = 0
    var nextTry: Int64 = 0

    init(key: any InstallKey, generation: Int, certificate: InstallCertificate, text: String) {
        self.key = key
        self.generation = generation
        self.certificate = certificate
        self.text = text
    }
}

/// The install's certificate, for the key generation it was issued to.
struct StoredCertificate: Codable, Sendable, Equatable {
    var generation: Int
    var certificate: String
    /// SDK 4.0.5 (ERRORS_40 24.14 item 5): the app's release it was attested with (nil: a certificate an earlier SDK kept).
    var appRelease: String? = nil
    /// SDK 4.0.5 (ATTEST_40.md 40.3): why it was made without App Attest, a named path (the lease request's
    /// `unattested`); nil when attested or not named.
    var unattested: String? = nil

    /// 24.14 item 5: an install whose certificate says `att none` with `recheck 0` attests again before its next lease
    /// ask when the app's release differs from the one it attested with (a certificate an earlier SDK kept says none),
    /// so a release that adds the App Attest capability reaches its installs at their first launch.
    static func attestsAgain(_ c: InstallCertificate, attestedWith: String?, release: String) -> Bool {
        guard c.att == "none", !c.recheck, !release.isEmpty else { return false }
        return attestedWith != release
    }
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
    /// SDK 4.0.5 (24.14 item 4): the last lease refused for attestation.
    private let attestRefusalFile: JSONFile<AttestationRefusal>
    /// The row of failed lease attempts and its next attempt (18.4.7.3), kept across restarts in `cloud/lease-retry.json`.
    private let retry: Locked<LeaseRetry>
    private let retryFile: JSONFile<LeaseRetry>
    private let refreshing = Locked<Task<Void, Never>?>(nil)
    /// SDK 4.0.5 (ATTEST_40.md 40.2 item 5): the next install key an owed attestation was made for in this process, kept
    /// so Apple's object (which binds its hash) can be sent again while its challenge is fresh.
    private let pendingNext = Locked<(key: any InstallKey, generation: Int)?>(nil)
    /// SDK 4.0.5 (ATTEST_40.md 40.2 item 10): the upgrade of a capped install whose attestation succeeded and whose full
    /// lease has not been accepted yet: the next key and its attested certificate (each try makes its own Core over the
    /// key). Kept for the next try (in this process); the capped lease, its certificate, its key and its Core stay in
    /// force meanwhile.
    private let pendingUpgrade = Locked<UpgradeTarget?>(nil)
    /// 40.2 item 10: set for the lease attempt of an upgrade (its certificate, key and Core in place of the install's).
    @TaskLocal static var upgrading: UpgradeTarget?
    /// 40.2 item 4: the background attestation (and the lease after it), one at a time.
    private let attesting = Locked<Task<Void, Never>?>(nil)
    /// 40.2 item 4: when the network last came back and was a try (at most one a minute).
    private let lastNetworkTry = Locked<Date?>(nil)
    private let flight = LeaseFlight()
    /// The model this runtime opened or shares, and the build folder it came from: its hold on it. SDK 4.0.3: which model
    /// the Core has open is the Core's (`CoreHost.openSlot`), the same for every runtime of the Core.
    private let open = Locked<(model: CoreModel, folder: URL)?>(nil)
    /// SDK 4.0.3: how long an open waits for another runtime's model to end its take (a Client closed while the app keeps
    /// its Model). One value for the SDK, as the other SDKs wait. Never a blocking wait on the main thread, and an async
    /// call waits by suspending (`asyncOpen`), never by holding a thread.
    static let openWaitSeconds: TimeInterval = 3
    /// `openWaitSeconds`; tests shorten it.
    var openWait: TimeInterval = ProtectedRuntime.openWaitSeconds
    /// SDK 4.0.5 (ATTEST_40.md 40.2 item 4): set for a renewal the SDK started by itself; an attestation that is owed and
    /// not due yet is not tried by it (the owed attestation's own schedule, the network coming back and the app's calls
    /// try it).
    @TaskLocal static var inBackground = false
    /// SDK 4.0.3: set by `asyncOpen` for the call it runs: the wait was done by suspending, and an open under it never
    /// blocks its thread (it fails at once when the model is still in another Client's take).
    @TaskLocal static var asyncWaited = false
    /// The build folder used last (the timer's refresh uses its manifest).
    private let lastFolder = Locked<ModelFolder?>(nil)
    /// SDK 4.0.5 (40.2 item 4): the manifest the last lease was asked for (a first install has no folder in use yet),
    /// for the background attestation and lease when the network comes back.
    private let lastManifest = Locked<ModelManifest?>(nil)
    /// Told every verified stop (the Client's model gate), every lease outcome (analytics) and every issue to report.
    var onStop: @Sendable (RecognizerError) -> Void = { _ in }
    var onLease: @Sendable (LeaseOutcome) -> Void = { _ in }
    var onIssue: @Sendable (_ kind: String, _ code: String) -> Void = { _, _ in }
    /// Told the cause of a background renewal that failed.
    var onSilent: @Sendable (ErrorCause) -> Void = { _ in }
    /// SDK 4.0.5: the signed manifest of the build this install would lease (the config's build, its manifest from the
    /// CDN; no model file), for an owed attestation's background try when no model is on the device yet. Set once by
    /// the server client.
    var leaseManifest: (@Sendable () async -> ModelManifest?)?
    /// SDK 4.0.5: the app asked this process for a model (`model()`, `prefetch()`): only then does an install with no
    /// model on the device attest and lease in the background.
    private let wanted = Locked(false)
    /// The background tries that found no manifest in a row, and when the next may come (40.2 item 4's row: 30 s,
    /// doubling, at most an hour).
    private let noManifest = Locked<(failures: Int, until: Date?)>((0, nil))

    /// The app asked for a model (`TajweedClient.model()`, `prefetch()`).
    func modelWanted() { wanted.withLock { $0 = true } }
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
         clocks: (any CoreClocks)? = nil) {
        self.storage = storage
        self.server = server
        self.keys = keys
        self.state = state ?? KeychainCoreState(storage: storage)
        // SDK 4.0.5 (spec fix 17): the boot id kept across launches (`StickyBootID`)
        let clocks = clocks ?? SystemClocks(bootIDFile: storage.appendingPathComponent("cloud/boot-id.json"))
        self.clocks = clocks
        certFile = JSONFile(url: storage.appendingPathComponent("cloud/install-cert.json"))
        attestRefusalFile = JSONFile(url: storage.appendingPathComponent("cloud/lease-attestation-refusal.json"))
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
        // SDK 4.0.5 (ATTEST_40.md 40.2 item 4, 40.4 item 1): the network coming back is a try of an owed attestation and
        // of a renewal that is due
        NetworkWatch.shared.observe(self) { [weak self] in self?.networkBack() }
    }

    /// The Core over the current install key, made at first use. Nil key: the install has never attested, and the
    /// Core cannot hold a lease yet (a first key is made by `ensureLease`).
    func host() throws(RecognizerError) -> CoreHost? {
        if let h = hostBox.withLock({ $0 }) { return h }
        guard let key = keys.current() else { return nil }
        // SDK 4.0.5 (40.2 item 10): its saves through a gate of its own, which an upgrade holds back or ends
        let platform = CorePlatform(storage: CoreStorage(root: storage), key: key, state: CoreStateGate(state), clocks: clocks)
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

    /// The Core this runtime uses, else the live one of its folder and install key (`LiveCores`); never makes one.
    private var liveHost: CoreHost? {
        if let h = hostBox.withLock({ $0 }) { return h }
        guard let key = keys.current() else { return nil }
        return LiveCores.live(LiveCores.key(storage: storage, installHash: key.installHash))
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
        var p = TajweedDiagnosis.Protected(keyStore: store, lease: lease,
                                           leaseExpires: lease != "none" && s.expiresAt > 0 ? s.expiresAt : nil,
                                           leaseClass: cls, refreshAfter: live && s.refreshAfter > 0 ? s.refreshAfter : nil,
                                           graceUntil: lease == "grace" ? g.until : nil, core: host == nil ? nil : CoreHost.version)
        // SDK 4.0.5 (ATTEST_40.md 40.6 item 2, DIAGNOSIS_40 25.4)
        let att = certFile.read().takingUnreadableAsMissing.flatMap { stored in server.flatMap { InstallCertificate.parse(stored.certificate, trustedKeys: $0.trustedKeys) } }?.att
        p.attestation = server?.attestation(att)
        if let f = lastFailure.withLock({ $0 }) {
            let c = f.cause
            p.lastFailure = TajweedDiagnosis.LeaseFailure(stage: c.stage, reason: c.reason, httpStatus: c.httpStatus,
                                                          errorCode: c.errorCode.flatMap { ErrorRules.token($0, ErrorRules.errorCodePattern) },
                                                          hostRole: c.hostRole, fallback: c.fallback,
                                                          chain: (c.chain ?? []).suffix(CauseChain.max).map(\.diagnosisJSON))
        }
        return p
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

    /// SDK 4.0.5: the lease in force for the build of `m`, read with no request; nil when the
    /// Core holds none for it that is valid now (none, expired, another build). A resume with none asks it beside its
    /// first request.
    func leaseInForce(_ m: ModelManifest) -> LeaseRecord? {
        #if DEBUG
        // tests only (StagingHooks.core): the stand-in's lease in force
        if let standIn = StagingHooks.core.withLock({ $0 }) { return standIn.inForce(m) }
        #endif
        guard hasValidLease(build: m.build), let r = leaseRecord else { return nil }
        return r
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
        lastManifest.withLock { $0 = m }
        if let h = try self.host() {
            let s = h.tick()
            if s.valid, let r = leaseRecord, r.build == m.build {
                if s.refreshDue || renewDue(s) { refreshInBackground(m, now: s.now) }
                return r
            }
            // 18.4.7.1: this build's lease has expired: an attempt first, then the Core's grace decides
            if s.hasLease, !s.stopped, let r = leaseRecord, r.build == m.build {
                return try await pastExp(m, host: h, record: r)
            }
        }
        // SDK 4.0.5 (ERRORS_40 24.14 item 4): an app call within 10 minutes of a refusal for attestation gets the same
        // error, with the same cause, without a request; an app of another version or build asks at once. The
        // background attempts keep 18.4.7.3's times (they do not come here)
        if let r = attestRefusalFile.read().takingUnreadableAsMissing, r.holds(now: clocks.wallMs() / 1000, release: server?.appRelease ?? "") {
            lastFailure.withLock { $0 = CausedFailure(error: r.error, cause: r.cause) }
            throw r.error
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
        // SDK 4.0.5 (40.2 item 4): an owed attestation that is due, when no lease can open
        attestIfOwed(folder.manifest)
        guard s.hasLease, s.refreshDue || renewDue(s), leaseRecord?.build == folder.manifest.build else { return }
        refreshInBackground(folder.manifest, now: s.now)
    }

    /// The background timer (every minute while the app is in use): the Core folds its usage and journal and saves
    /// its state, and a refresh that is due starts.
    func tick() {
        guard let h = try? self.host() else { return }
        let s = h.tick()
        if s.hasLease, s.refreshDue || renewDue(s), let f = lastFolder.withLock({ $0 }), leaseRecord?.build == f.manifest.build {
            refreshInBackground(f.manifest, now: s.now)
        }
        attestIfOwed(lastFolder.withLock { $0 }?.manifest ?? lastManifest.withLock { $0 })
    }

    /// SDK 4.0.5 (ATTEST_40.md 40.4 item 1): the lease's half-life has passed on the Core's clock, before the server's
    /// `refresh_after` (which the Core's `refreshDue` says): a late `refresh_after` never leaves a lease to its last day.
    func renewDue(_ s: CoreLeaseStatus) -> Bool {
        guard s.hasLease, !s.stopped, let r = leaseRecord, r.expiresAt > 0 else { return false }
        return s.now >= AttestPolicy.renewDue(iat: r.issuedAt, exp: r.expiresAt, refreshAfter: r.refreshAfter)
    }

    /// 40.2 item 8: the lease the Core holds can still open the model (valid, or in its grace).
    func leaseCanOpen() -> Bool {
        guard let h = try? self.host() else { return false }
        let s = h.tick()
        return s.hasLease && !s.stopped && (s.valid || h.leaseGrace().inGrace)
    }

    /// The network came back (`NetworkWatch`): after a draw of 0 to 3 s, at most once a minute, an owed attestation that
    /// is due and a renewal that is due and whose row allows it (40.2 item 4, 40.4 items 1 and 2).
    func networkBack() {
        let now = Date()
        let go = lastNetworkTry.withLock { (t: inout Date?) -> Bool in
            if let t0 = t, now.timeIntervalSince(t0) < AttestPolicy.pathMinGap { return false }
            t = now
            return true
        }
        guard go else { return }
        let delay = Double.random(in: AttestPolicy.pathDelay) * AttestPolicy.timeScale.withLock { $0 }
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            self.attestIfOwed(self.lastFolder.withLock({ $0 })?.manifest ?? self.lastManifest.withLock({ $0 }), networkBack: true)
            guard let f = self.lastFolder.withLock({ $0 }), let h = try? self.host() else { return }
            let s = h.tick()
            if s.hasLease, s.refreshDue || self.renewDue(s), self.leaseRecord?.build == f.manifest.build {
                self.refreshInBackground(f.manifest, now: s.now)
            }
        }
    }

    /// 40.2 items 4 and 8: an owed attestation whose try has come, in the background, when no lease the Core holds can
    /// still open the model (a lease in use stays in use; a new install key would leave it behind); then the lease.
    func attestIfOwed(_ m: ModelManifest?, networkBack: Bool = false) {
        // a capped install whose lease needs no attestation upgrades while its lease can still open (40.2 item 1); one
        // whose lease needs it keeps a lease that can open until it cannot (item 8)
        guard let server else { return }
        guard let m else { return attestWithoutModel(server, networkBack: networkBack) }
        let upgradeDue = pendingUpgrade.withLock { $0.map { networkBack || clocks.wallMs() / 1000 >= $0.nextTry } } ?? false
        guard server.attestationOwedAndDue(networkBack) || upgradeDue, !leaseCanOpen() || !server.attestRequired() else { return }
        attesting.withLock { (t: inout Task<Void, Never>?) in
            guard t == nil else { return }
            t = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                do throws(RecognizerError) {
                    // a flight of its own after the one running (the attempt a refusal made it owed in is never joined)
                    _ = try await self.flight.runAfter(m.build) { () async throws(RecognizerError) -> LeaseRecord in
                        // 40.2 item 1: a capped install whose lease can open upgrades only on success (a try that does
                        // not end attested changes nothing); else a new certificate, as the lease needs
                        if !server.attestRequired(), self.leaseCanOpen() {
                            // 40.2 item 10: the full lease with the next key; the capped lease in force until it is accepted
                            return try await self.upgradeLease(m, server)
                        }
                        _ = try await self.certificate(renew: true)
                        return try await self.fetchLease(m)
                    }
                } catch {
                    self.onSilent(ErrorCause.lease(error, runtime: self))
                }
                self.attesting.withLock { $0 = nil }
            }
        }
    }

    /// SDK 4.0.5 (ATTEST_40.md 40.2 items 4 and 9): an install with no model on the device (so no manifest in hand) whose
    /// app asked for one that did not come (no network at its first `model()`), with an attestation owed: the background
    /// tries it as for a known build, when the network comes back and at the row's time. In 18.4.1's order: the build the
    /// config names and its signed manifest (`leaseManifest`; no model file, the download waits for the app's call),
    /// then in the build's flight the certificate (the attestation, 40.2 items 1 to 3) and the lease. The guards are read
    /// again once the manifest is in, since the app's own call may have leased meanwhile. A try that finds no manifest
    /// waits 30 s, doubling to an hour, before the next (the network coming back does not wait).
    private func attestWithoutModel(_ server: LeaseServer, networkBack: Bool) {
        guard wanted.withLock({ $0 }), let find = leaseManifest else { return }
        guard server.attestationOwedAndDue(networkBack), !leaseCanOpen() else { return }
        if !networkBack, let until = noManifest.withLock({ $0.until }), Date() < until { return }
        attesting.withLock { (t: inout Task<Void, Never>?) in
            guard t == nil else { return }
            t = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                if let m = await find() {
                    self.noManifest.withLock { $0 = (0, nil) }
                    self.lastManifest.withLock { $0 = $0 ?? m }
                    if server.attestationOwedAndDue(networkBack), !self.leaseCanOpen() {
                        do throws(RecognizerError) {
                            _ = try await self.flight.runAfter(m.build) { () async throws(RecognizerError) -> LeaseRecord in
                                _ = try await self.certificate(renew: true)
                                return try await self.fetchLease(m)
                            }
                        } catch {
                            self.onSilent(ErrorCause.lease(error, runtime: self))
                        }
                    }
                } else {
                    self.noManifest.withLock { (s: inout (failures: Int, until: Date?)) in
                        s.failures += 1
                        let wait = min(30 << min(16, s.failures - 1), 3600)
                        s.until = Date().addingTimeInterval(TimeInterval(wait))
                    }
                }
                self.attesting.withLock { $0 = nil }
            }
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
                // SDK 4.0.5 (40.2 item 4): a renewal of the SDK's own, which keeps an owed attestation's schedule
                await Self.$inBackground.withValue(true) {
                    do throws(RecognizerError) {
                        _ = try await self.renew(m)
                    } catch {
                        self.onSilent(ErrorCause.lease(error, runtime: self))
                    }
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
            // SDK 4.0.5 (24.14 item 5): an unattested certificate of another app release attests again, its App Attest
            // retry hold cleared first; (ATTEST_40.md 40.2 items 1 and 8) so does one whose attestation is owed and due.
            // Either waits while the lease the Core holds can still open the model (a new install key would leave it
            // behind; Android 159c790's rule); else it is the install's certificate until it ends
            let again = StoredCertificate.attestsAgain(c, attestedWith: stored.appRelease, release: server.appRelease)
            let owed = c.att == "none" && server.attestationOwedAndDue(false)
            // SDK 4.0.5 (40.2 items 1 and 10): where the lease needs no attestation, an owed attestation is the background's
            // upgrade (`upgradeLease`), which switches only once the full lease is accepted: here the capped certificate
            // stays the one the lease is asked with
            if owed, !server.attestRequired() { return c }
            guard again || owed, !leaseCanOpen() else { return c }
            if again { server.clearAttestHold() }
        }
        // 40.2 item 5: the next key an owed attestation was made for in this process, so Apple's object is sent again
        let kept = pendingNext.withLock { (p: inout (key: any InstallKey, generation: Int)?) -> (key: any InstallKey, generation: Int)? in
            defer { p = nil }
            return p?.generation == keys.generation + 1 ? p : nil
        }
        // 40.2 item 4: the SDK's own renewal does not try an owed attestation before its time
        if kept == nil, Self.inBackground, server.attestationOwed(), !server.attestationOwedAndDue(false) {
            let e = RecognizerError.offline("the install's attestation is owed and its next try comes later")
            lastFailure.withLock { $0 = CausedFailure(error: e, cause: ErrorCause(stage: "attest", reason: "other").traced()) }
            throw e
        }
        guard let next = kept ?? keys.makeNext() else { throw .storageFailed("the install key store made no key") }
        let text: String
        do throws(CloudError) {
            text = try await server.certify(next.key)
        } catch {
            LeaseAttemptTrace.current?.failed(error)
            // SDK 4.0.5 (40.6): the cause where it is (stage attest), with the attempt's chain, for the app's error,
            // the report and diagnose's lastFailure
            lastFailure.withLock { $0 = CausedFailure(error: error.recognizerError, cause: ErrorCause.of(error, stage: "attest")) }
            // 40.2 item 5: an attestation still owed keeps its next key for the next try in this process
            if server.attestationOwed() {
                pendingNext.withLock { $0 = next }
            } else {
                keys.discard(generation: next.generation)
            }
            if case .rejected(_, let code, _, _) = error, code == "install_sig_invalid" { onIssue("other", "install_sig_invalid") }
            throw error.recognizerError
        }
        guard let c = InstallCertificate.parse(text, trustedKeys: server.trustedKeys), c.isFor(installHash: next.key.installHash) else {
            keys.discard(generation: next.generation)
            // SDK 4.0.5 (40.5): the check it failed, for the attempt's chain
            let check = InstallCertificate.check(text, trustedKeys: server.trustedKeys, installHash: next.key.installHash) ?? AnswerCheck.certFormat
            CauseChain.add(CauseHop.made(stage: "lease", reason: "invalid_answer", hostRole: "api", httpStatus: 200, errorCode: check))
            onIssue("other", "install_cert_unreadable")
            throw .serverRejected(status: 0, code: "invalid_response", message: "the install certificate does not verify")
        }
        keys.promote(next.key, generation: next.generation)
        certFile.write(StoredCertificate(generation: next.generation, certificate: text, appRelease: server.appRelease,
                                         unattested: c.att == "none" ? server.unattestedWhy() : nil))
        // SDK 4.0.5 (40.2 item 8): an attested certificate is what the refusal asked for: the app's next call asks at once
        if c.att != "none" { attestRefusalFile.delete() }
        // the Core over the new key: its lease part starts over, the clock's floor and the usage carry over. A model
        // open on the old Core keeps that Core until it closes.
        hostBox.withLock { $0 = nil }
        return c
    }

    /// SDK 4.0.5 (ATTEST_40.md 40.2 item 10): an upgrade's target: the attestation with the NEXT install key (not the
    /// install's) and its certificate; nil when the attestation did not end attested (the next key kept while the
    /// attestation is owed). Nothing of the install changes here; each try makes its own Core (`upgradeLease`).
    private func upgradeTarget(_ server: LeaseServer) async -> UpgradeTarget? {
        guard let up = server.upgrade else { return nil }
        let kept = pendingNext.withLock { (p: inout (key: any InstallKey, generation: Int)?) -> (key: any InstallKey, generation: Int)? in
            defer { p = nil }
            return p?.generation == keys.generation + 1 ? p : nil
        }
        guard let next = kept ?? keys.makeNext() else { return nil }
        let text: String
        do throws(CloudError) {
            text = try await up(next.key)
        } catch {
            if server.attestationOwed() { pendingNext.withLock { $0 = next } } else { keys.discard(generation: next.generation) }
            return nil
        }
        guard let c = InstallCertificate.parse(text, trustedKeys: server.trustedKeys), c.isFor(installHash: next.key.installHash), c.att != "none" else {
            keys.discard(generation: next.generation)
            return nil
        }
        return UpgradeTarget(key: next.key, generation: next.generation, certificate: c, text: text)
    }

    /// SDK 4.0.5 (ATTEST_40.md 40.2 item 10): one upgrade try of a capped install: the full lease asked with the attested
    /// certificate and the next key's Core, and the switch (`switchTo`) only once that Core accepted it. Any other end
    /// leaves the capped lease, its certificate and its key in force (the new Core dropped unsaved), keeps the target for
    /// the next try by 40.2 item 4's schedule, and owes the attestation again (a restart makes it anew). A take in
    /// progress: the upgrade waits.
    func upgradeLease(_ m: ModelManifest, _ server: LeaseServer) async throws(RecognizerError) -> LeaseRecord {
        guard open.withLock({ $0 }) == nil else { throw .offline("a take is in progress: the upgrade waits") }
        let now = clocks.wallMs() / 1000
        var target = pendingUpgrade.withLock { (t: inout UpgradeTarget?) -> UpgradeTarget? in
            // a target whose certificate ends within the hour, or whose key is no longer the next one, is made anew
            if let x = t, x.certificate.expiresAt <= now + 3600 || x.generation != keys.generation + 1 { t = nil }
            return t
        }
        if target == nil { target = await upgradeTarget(server) }
        guard let t = target else { throw .offline("the install's attestation is still owed") }
        // the Core in force saves nothing while the try's Core lives (its saves held back, written when the try ends
        // without a switch), and the try's Core is made after that: it takes the counter and the state as they stay
        // until it accepts (Core c3: two saves of the old Core meanwhile would leave the new state older than the
        // counter, and a restart would lose the full lease)
        let oldGate = (try? host())?.platform.state as? CoreStateGate
        oldGate?.hold()
        let res: Result<LeaseRecord, RecognizerError>
        do throws(CoreFailure) {
            t.host = try CoreHost(platform: CorePlatform(storage: CoreStorage(root: storage), key: t.key,
                                                         state: CoreStateGate(state, held: true), clocks: clocks))
            res = await Self.$upgrading.withValue(t) { () async -> Result<LeaseRecord, RecognizerError> in
                do throws(RecognizerError) {
                    return .success(try await self.fetchLease(m))
                } catch {
                    return .failure(error)
                }
            }
        } catch {
            res = .failure(error.recognizerError)
        }
        // no switch: the try's Core goes unsaved, and the Core in force writes what it held back (nothing once silenced)
        t.host = nil
        oldGate?.commit()
        switch res {
        case .success(let r):
            pendingUpgrade.withLock { $0 = nil }
            return r
        case .failure(let e):
            // switched (the Core accepted, a later step failed): the upgrade is done
            if keys.generation == t.generation {
                pendingUpgrade.withLock { $0 = nil }
                throw e
            }
            t.failures += 1
            let wait = AttestPolicy.background(.transient, failures: t.failures, draw: Double.random(in: AttestPolicy.draw)) ?? AttestPolicy.backgroundCap
            t.nextTry = now + Int64(wait)
            pendingUpgrade.withLock { $0 = t }
            server.oweAttestationAfter(wait)
            throw e
        }
    }

    /// 40.2 item 10, step 4: the next key is the install's, its certificate and its Core the ones in force, the new
    /// Core's held saves written and the old Core silenced (a model or another Client holding it never saves again: its
    /// state would replace the new key's lease). Called with the folder's lock held, right after the upgrade's Core
    /// accepted the full lease. False, and nothing changes, when a model is open on the Core in force (it opened during
    /// the try): the upgrade waits, and the new Core is dropped unsaved.
    private func switchTo(_ up: UpgradeTarget) -> Bool {
        guard let next = up.host else { return false }
        let old = hostBox.withLock { $0 } ?? liveHost
        if open.withLock({ $0 }) != nil { return false }
        if let old, old.openSlot.withLock({ (s: CoreHost.OpenSlot) in s.model != nil }) { return false }
        keys.promote(up.key, generation: up.generation)
        certFile.write(StoredCertificate(generation: up.generation, certificate: up.text, appRelease: server?.appRelease))
        (next.platform.state as? CoreStateGate)?.commit()
        (old?.platform.state as? CoreStateGate)?.silence()
        _ = try? LiveCores.take(LiveCores.key(storage: storage, installHash: up.key.installHash)) { () throws(CoreFailure) -> CoreHost in next }
        hostBox.withLock { $0 = next }
        attestRefusalFile.delete()
        return true
    }

    /// 40.2 item 10: the upgrade's Core accepted the full lease while a model was open on the Core in force: no switch now.
    static let upgradeWaits = CoreFailure(status: Int(QLC_E_ARG), detail: 0, call: "a model opened during the upgrade")

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
            // 24.14 item 4: a lease ends what a refusal for attestation left remembered
            attestRefusalFile.delete()
            return r
        case .failure(let e):
            told(e, trace, last)
            throw e
        }
    }

    private func told(_ e: RecognizerError, _ trace: LeaseAttemptTrace, _ last: RequestTrace.Entry? = nil) {
        // 40.2 item 10: an upgrade's failure says nothing of the lease in force (the capped one keeps working)
        guard trace.asked, !trace.stopped, Self.upgrading == nil else { return }
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
        // SDK 4.0.5 (ATTEST_40.md 40.7): a server that does not take `unattested` yet (400) is asked once more without it
        var sendUnattested = true
        // 18.4.10 (4.0.1, endpoints_40.json's attempts): after invalid_token the request is repeated once with the
        // renewed token and the SAME challenge (a challenge is a stateless HMAC good on every api host, 28.5); 4.0.0
        // asked a new one
        var keptChallenge: String?
        // 40.2 item 10: an upgrade asks with its attested certificate and its Core over the next key
        let upgrading = Self.upgrading
        var cert: InstallCertificate
        if let up = upgrading { cert = up.certificate } else { cert = try await certificate() }
        let now = { self.clocks.wallMs() / 1000 }
        let trace = LeaseAttemptTrace.current
        while true {
            let host: CoreHost
            if let up = upgrading {
                guard let h = up.host else { throw .storageFailed("no Core for the upgrade") }
                host = h
            } else {
                guard let h = try self.host() else { throw .storageFailed("no install key") }
                host = h
            }
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
            var body: [String: Any] = [
                "v": 1, "platform": server.platform, "install_cert": cert.encoded,
                "install_key": host.platform.key.spki.base64URL, "install_sign_key": host.platform.key.spki.base64URL,
                "challenge": challenge, "install_sig": ask.installSig, "model": m.modelID, "version": m.version, "build": m.build,
                "key_id": enc.keyID, "core": ask.core,
            ]
            // SDK 4.0.5 (ATTEST_40.md 40.3 item 2): why a certificate without attestation is one, a named path only
            let unattested = cert.att == "none" && sendUnattested
                ? (certFile.read().takingUnreadableAsMissing.flatMap { $0.generation == keys.generation ? $0.unattested : nil } ?? server.unattestedWhy())
                : nil
            if let unattested { body["unattested"] = unattested }
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
                guard a.status == 200 else { return false }
                // SDK 4.0.5 (ATTEST_40.md 40.5): an answer this host gave that is not taken names the check it failed
                let read = LeaseAnswer.read(a.body)
                guard let answer = read.answer, read.check == nil else {
                    AnswerCheck.failed(read.check ?? AnswerCheck.leaseV)
                    return false
                }
                guard Self.acceptedBase(answer.base) != nil else {
                    AnswerCheck.failed(AnswerCheck.baseHost)
                    return false
                }
                let result: Result<(expiresAt: Int64, refreshAfter: Int64), CoreFailure>
                // SDK 4.0.2: a lease older than the one this folder holds (an attempt of a closed Client, answered after
                // a newer one) is taken as answered and never handed to the Core; nor is one answered after a stop
                folderLock.lock()
                if LeaseStops.current(folder) != sentStops {
                    result = .failure(Self.stoppedSinceSent)
                } else if upgrading == nil, let saved = Self.newer(than: answer, build: build, in: leases) {
                    result = .success((saved.expiresAt, saved.refreshAfter))
                } else {
                    var r: Result<(expiresAt: Int64, refreshAfter: Int64), CoreFailure>
                    // spec fix 17: the answer's signed time first, so the lease is judged at the server's time
                    if let t = answer.time { host.leaseTime(t) }
                    do throws(CoreFailure) { r = .success(try host.leaseAccept(answer.lease, manifest: raw, build: build)) } catch {
                        r = .failure(error)
                    }
                    // 40.2 item 10, step 4: the upgrade's Core accepted the full lease: only now the switch
                    if case .success = r, let up = upgrading, !self.switchTo(up) { r = .failure(Self.upgradeWaits) }
                    result = r
                }
                folderLock.unlock()
                verdict.withLock { $0 = (a.body, result) }
                if case .success = result { return true }
                // an answer after a stop ends the request on this host (no other host is asked for it); so does a
                // full lease taken while a model opened (40.2 item 10: the upgrade waits)
                if case .failure(let f) = result, f == Self.stoppedSinceSent || f == Self.upgradeWaits { return true }
                // 40.5: the Core's refusal by its status and detail (4.0.2 reported the status alone: "lease, expired, -5")
                if case .failure(let f) = result { AnswerCheck.failed(AnswerCheck.coreAccept(status: f.status, detail: f.detail)) }
                return false
            }
            do throws(CloudError) {
                var r = try HTTPClient.jsonRequest(Self.leaseURL(server.apiURL), body: body, auth: token)
                r.timeoutInterval = 30
                trace?.asking()
                resp = try await server.transport.send(r, accepting: accept)
            } catch {
                return try fail(error.recognizerError, .offline, now: now())
            }
            trace?.answered(status: resp.status, body: resp.body, retryAfter: resp.header("Retry-After"))
            if resp.status == 200 {
                // SDK 4.0.5 (ATTEST_40.md 40.5): an answer every host gave and none passed is invalid_answer with the check
                // the one that ended the request failed (`error_code`), and its hops are the cause's chain (40.6)
                let read = LeaseAnswer.read(resp.body)
                guard let answer = read.answer, read.check == nil || read.check == AnswerCheck.leaseBase else {
                    onIssue("other", "lease_answer_unreadable")
                    let check = read.check ?? AnswerCheck.leaseV
                    return try fail(.serverRejected(status: 200, code: "invalid_response", message: "the lease answer is not one (\(check))"), .other,
                                    now: now(), cause: ErrorCause(stage: "lease", reason: "invalid_answer", httpStatus: 200, errorCode: check))
                }
                // 28.4 (4.0.1): a `base` off the allow-list makes no lease answer of 18.4.5 (4.0.0 accepted the lease and
                // then had no folder to fetch from)
                guard let base = Self.acceptedBase(answer.base) else {
                    let check = read.check ?? AnswerCheck.baseHost
                    return try fail(.serverRejected(status: 200, code: "invalid_response", message: "the lease answer names no model folder of Quran Lab's"),
                                    .other, now: now(), cause: ErrorCause(stage: "lease", reason: "invalid_answer", httpStatus: 200, errorCode: check))
                }
                // SDK 4.0.2: an older lease than the folder's own changes nothing (see `accept`)
                let kept = upgrading != nil ? nil : folderLock.withLock { Self.newer(than: answer, build: m.build, in: leases) }
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
                            if let t = answer.time { host.leaseTime(t) } // spec fix 17, as above
                            do throws(CoreFailure) {
                                let ok = try host.leaseAccept(answer.lease, manifest: raw, build: build)
                                // 40.2 item 10, step 4 (the answer the request ended on, accepted here)
                                if let up = upgrading, keys.generation != up.generation, !self.switchTo(up) { return .failure(Self.upgradeWaits) }
                                return .success(ok)
                            } catch {
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
                    // 40.2 item 10: a model opened during the upgrade; the capped lease stays in force, the upgrade waits
                    if error == Self.upgradeWaits { throw .offline("a model opened during the upgrade: it waits") }
                    // the Core refused the lease (another install's, another release's, expired by its clock). SDK 4.0.5
                    // (ATTEST_40.md 40.5): an answer, so invalid_answer with its check (`expired_on_arrival`, `signature`,
                    // ...); 4.0.2 reported reason `expired` and the status (-5) alone, with no role, fallback or status, and
                    // the app got needs_connection for a request that was answered (24.4 rule 2)
                    let outcome: LeaseOutcome = error.detail == Self.leaseExpiredDetail ? .expired : .refused
                    let check = AnswerCheck.coreAccept(status: error.status, detail: error.detail)
                    let cause = ErrorCause(stage: "lease", reason: "invalid_answer", httpStatus: 200, errorCode: check)
                    return try fail(error.recognizerError, outcome, now: now(), cause: cause)
                }
                // 18.4.5, 18.6.7 (spec fix 16, quranlab-core d128af8): the answer's piece right after the accept of
                // the same answer, always. The Core keeps it pending (in its saved state too) and puts it in force at
                // the next model open; a piece is the last good one only once a lease asked under it was accepted and a
                // model opened after that. A piece that does not verify changes nothing.
                if let p = answer.piece { host.piece(p) }
                if let c = answer.certificate, let parsed = InstallCertificate.parse(c, trustedKeys: server.trustedKeys),
                   parsed.isFor(installHash: host.installHash) {
                    // SDK 4.0.5: the renewed certificate keeps the release and the named path it was made with (until 4.0.5
                    // the release was dropped here, so an unattested install attested again at its next certificate)
                    let kept = certFile.read().takingUnreadableAsMissing.flatMap { $0.generation == keys.generation ? $0 : nil }
                    certFile.write(StoredCertificate(generation: keys.generation, certificate: c, appRelease: kept?.appRelease,
                                                     unattested: kept?.unattested))
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
            case .reattest where upgrading != nil:
                // 40.2 item 10: the upgrade's own certificate refused: this try ends, the capped lease stays
                return try fail(.offline("the upgrade's certificate was not taken"), .offline, now: now())
            case .reattest where !reattested:
                reattested = true
                cert = try await certificate(renew: true)
            case .stop(let error, let reason):
                // a stop that is not signed by a pinned key for this request is not acted on (18.4.10); the app's call
                // gets `server_rejected` with its error, and nothing is removed
                let cause = ErrorCause(stage: "lease", reason: "refused", httpStatus: resp.status, errorCode: reason ?? error)
                return try fail(.offline("an unsigned stop on the lease route was not acted on"), .refused, now: now(), cause: cause)
            case .sdkBug where unattested != nil:
                // 40.7: a server that does not take `unattested` yet; the request once more without it
                sendUnattested = false
                keptChallenge = challenge
            case .sdkBug:
                onIssue("other", "bad_request:model-key")
                return try fail(refusal.error(status: resp.status, body: resp.body), .other, now: now())
            case .refused(code: "lease_integrity_failed", why: .some("core"))
                where !pieceFallback && ((ask.core["piece"] as? Int) ?? 0) != 0:
                // 18.6.7: a proof refused while a new data piece was in force. The refusal above sent the Core back to
                // its last good piece; the request is asked once more under it (the lease in force covers a bad piece)
                pieceFallback = true
            case .refused(let code, _):
                // an attestation or integrity the server did not accept (24.3 `lease`): `server_rejected`, never a stop.
                // SDK 4.0.5 (ERRORS_40 24.14 item 2): `lease_attestation_required` is reason `refused`, as on every SDK
                // (4.0.3 and 4.0.4 said `attestation_failed`)
                let reason = code == "lease_integrity_failed" ? "integrity_failed" : "refused"
                // 24.3 (69326fb): an integrity refusal's error_code is the check it names (`verdict:boot`, `core`)
                let body = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]
                let errorCode = code == "lease_integrity_failed" ? (HTTPClient.reason(body) ?? code) : code
                let cause = ErrorCause(stage: "lease", reason: reason, httpStatus: resp.status, errorCode: errorCode)
                let error = refusal.error(status: resp.status, body: resp.body)
                // 24.14 item 4: remembered with the app's release, so the app's next call within 10 minutes asks nothing
                if code == "lease_attestation_required", case .serverRejected(let st, let c, let msg, _) = error {
                    attestRefusalFile.write(AttestationRefusal(at: now(), appRelease: server.appRelease, status: st, code: c, message: msg))
                    // SDK 4.0.5 (ATTEST_40.md 40.2 item 8): never given up: the attestation is owed now, made in the
                    // background with 40.2's tries, and the lease asked again once it is accepted
                    // only a certificate without attestation is owed one (an attested one refused is the server's to
                    // explain: attesting again would make a new key and the same refusal)
                    if cert.att == "none" { server.oweAttestation() }
                    let build = m
                    Task.detached(priority: .utility) { [weak self] in self?.attestIfOwed(build) }
                }
                return try fail(error, code.hasPrefix("lease_attestation") ? .attestation : .refused, now: now(), cause: cause)
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
        if LeaseAttemptTrace.current?.wasHeld != true, Self.upgrading == nil {
            let row = retry.withLock { (r: inout LeaseRetry) -> LeaseRetry in
                r.failed(now: now, retryAfter: retryAfter)
                return r
            }
            retryFile.write(row)
        }
        onLease(outcome)
        throw e
    }

    /// SDK 4.0.5 (ATTEST_40.md 40.2 item 1): `POST /v1/model-key?sdk=<version>`: qlab-api reads the SDK's version from the
    /// request first for a strict app (its `leaseSdkVersion`), so a robust SDK is never taken for an older one.
    static func leaseURL(_ api: URL) -> URL {
        let base = api.appendingPathComponent("v1/model-key")
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        c.queryItems = [URLQueryItem(name: "sdk", value: SDKInfo.version)]
        return c.url ?? base
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
                    try closeModelForInstall(host)
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
    /// SDK 4.0.3: the Core's open model, whichever runtime opened it (`CoreHost.openSlot`): a model a closed Client's
    /// Model keeps open makes the Core refuse the install as this runtime's own does.
    private func closeModelForInstall(_ host: CoreHost, timeout: TimeInterval = 30) throws(RecognizerError) {
        let until = Date().addingTimeInterval(timeout)
        while true {
            let closed = host.openSlot.withLock { (s: CoreHost.OpenSlot) -> Bool in
                guard let m = s.model else { return true }
                guard m.closeIfIdle() else { return false }
                open.withLock { if $0?.model === m { $0 = nil } }
                return true
            }
            if closed { return }
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
    ///
    /// SDK 4.0.3: which model is open is the Core's, not this Client's. A Client closed while the app keeps its Model
    /// leaves that model open on the Core the next Client takes (`LiveCores`), and the Core opens one model at a time
    /// (`QLC_E_BUSY` for a second). Every runtime of the Core reads one slot (`CoreHost.openSlot`), and the check, the
    /// close and the open happen under its lock:
    /// - the open model of this folder and context is shared, whoever opened it (each take runs its own stream on it);
    /// - a model this runtime opened, of another folder or context, is closed first, as before (one at a time);
    /// - a model another runtime opened (also one this runtime shares) is closed once nothing runs on it, and while a
    ///   take runs on it the open waits (at most `openWait`, the lock let go): that take is never cut by this runtime.
    ///   Past the wait the open fails with `session_open`. On the main thread it never waits and fails at once:
    ///   `reference.units()` is synchronous and opens the model, and an app may call it there (the system ends an app
    ///   whose main thread stalls). Under an async call (`asyncOpen`) it never waits either: that call waited already,
    ///   by suspending.
    /// A close whose last call still runs, or a model let go a moment ago, keeps the Core busy for a moment: the open is
    /// tried again within the same wait. Tried before (to 4.0.2): a slot per runtime, without a lock. A second Client
    /// met the first one's model as `engine_failed` (`busy`) at `model_open`, and so did two opens of one Client at once.
    func openModel(_ folder: ModelFolder, context: String) throws(RecognizerError) -> CoreModel {
        guard let raw = folder.manifest.raw, let host = try self.host() else { throw .offline("needs_connection: no lease on this device yet") }
        lastFolder.withLock { $0 = folder }
        // this runtime's model on an earlier Core (a new install key made a new one) is closed first, as before
        if let o = open.withLock({ $0 }), o.model.host !== host { closeModel() }
        enum Step {
            case opened(CoreModel, fresh: Bool)
            /// another runtime's model is in use, or the Core is still busy with a model being closed
            case wait(CoreFailure?)
            case failed(CoreFailure)
            case incompatible
        }
        let until = Date().addingTimeInterval(Thread.isMainThread || Self.asyncWaited ? 0 : openWait)
        while true {
            let step = host.openSlot.withLock { (s: CoreHost.OpenSlot) -> Step in
                let mine = open.withLock { $0?.model }
                if let m = s.model, m.isOpen, m.folder == folder.directory, m.context == context {
                    open.withLock { $0 = (m, folder.directory) }
                    return .opened(m, fresh: m !== mine)
                }
                if let m = s.model {
                    if s.opener === self {
                        // this runtime opened it: closed at once, as before (a take on it fails)
                        m.close()
                        open.withLock { if $0?.model === m { $0 = nil } }
                    } else if !m.closeIfIdle() {
                        // another runtime opened it (a closed Client's Model the app keeps): its take is waited for
                        return .wait(nil)
                    }
                }
                let model: CoreModel
                do throws(CoreFailure) {
                    model = try host.open(manifest: raw, in: folder.directory, context: context, threads: 0)
                } catch {
                    return error.isBusy ? .wait(error) : .failed(error)
                }
                if let names = model.tokens, names != folder.vocabulary.symbols {
                    model.close()
                    return .incompatible
                }
                s.model = model
                s.opener = self
                open.withLock { $0 = (model, folder.directory) }
                return .opened(model, fresh: true)
            }
            switch step {
            case .opened(let model, let fresh):
                // the recited index once per runtime and Core, also for a model another runtime opened
                if fresh { prepareRecited(host, folder) }
                return model
            case .wait(let busy):
                guard Date() < until else {
                    // the Core stayed busy with no model it knows of in use: the Core's own answer
                    if let busy { throw busy.recognizerError }
                    // another Client's take holds the model (a Model of a closed Client the app keeps)
                    throw .sessionActive
                }
                Thread.sleep(forTimeInterval: 0.05)
            case .failed(let error):
                if error.status == QLC_E_FILE {
                    // a device form that fails its tag: the folder's device forms go, and the next model() installs again
                    removeDeviceForms(folder.directory)
                }
                throw error.recognizerError
            case .incompatible:
                throw .modelIncompatible("the Core's vocabulary of this build is not the one the SDK carries for its tokens hash")
            }
        }
    }

    /// SDK 4.0.3: an async call's wait for the Core's model, by suspending (never holding a thread): while a model
    /// another runtime opened, of another folder or context, has a call or a take on it, at most `openWait`. Returns at
    /// once when there is nothing to wait for.
    func awaitOpenable(_ folder: ModelFolder, context: String) async {
        guard let host = liveHost else { return }
        let until = Date().addingTimeInterval(openWait)
        while Date() < until {
            let inUse = host.openSlot.withLock { (s: CoreHost.OpenSlot) -> Bool in
                // none; one this runtime opened (closed at once, as before); this folder and context (shared)
                guard let m = s.model, s.opener !== self else { return false }
                if m.isOpen, m.folder == folder.directory, m.context == context { return false }
                return !m.isIdle
            }
            if !inUse { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// SDK 4.0.3: an async API's call that opens the Core's model (`model()`'s warm-up, `prepare`, a take's start): the
    /// wait for another Client's take is done here by suspending (`awaitOpenable`), and the open in `body` never blocks
    /// its thread (`asyncWaited`).
    static func asyncOpen<T: Sendable>(_ folder: ModelFolder, context: String,
                             _ body: () async throws(RecognizerError) -> T) async throws(RecognizerError) -> T {
        if let runtime = current.withLock({ $0 }) { await runtime.awaitOpenable(folder, context: context) }
        let r: Result<T, RecognizerError> = await $asyncWaited.withValue(true) { () async -> Result<T, RecognizerError> in
            do throws(RecognizerError) {
                return .success(try await body())
            } catch {
                return .failure(error)
            }
        }
        return try r.get()
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
        defer { AcceleratorGate.release(dispatch) }
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
    /// SDK 4.0.3: once per Core, whichever runtime loads it (`CoreHost.recitedIndexed`). A runtime that shares a Core
    /// another runtime loaded it on (a Client closed while the app keeps its Model) uses the index as it is and finishes
    /// nothing: the take open in the journal is that Client's, maybe running now, not one a killed process left.
    private func prepareRecited(_ host: CoreHost, _ folder: ModelFolder) {
        guard !recitedReady(host), RecitedSwitch.detectorOn, let raw = folder.manifest.raw,
              let f = folder.manifest.files(role: "recited").first,
              f.isEncrypted ? ModelInstaller.present(f, in: folder.directory) : ModelInstaller.verified(f, in: folder.directory) else { return }
        enum Load { case already, loaded, failed(CoreFailure) }
        let load = host.recitedIndexed.withLock { (indexed: inout Bool) -> Load in
            if indexed { return .already }
            do throws(CoreFailure) {
                try host.recitedIndex(manifest: raw, in: folder.directory)
            } catch {
                return .failed(error)
            }
            indexed = true
            return .loaded
        }
        switch load {
        case .failed(let error):
            onIssue("other", "recited_index:\(error.status)")
            return
        case .already:
            recitedHosts.withLock { $0.append(ObjectIdentifier(host)) }
            return
        case .loaded:
            break
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

    /// The model open now when it is `folder`'s (the reference reader reads through it). SDK 4.0.3: also one another
    /// runtime of this Core opened (a closed Client's Model the app keeps).
    func openModel(of folder: ModelFolder) -> CoreModel? {
        if let o = open.withLock({ $0 }), o.folder == folder.directory, o.model.isOpen { return o.model }
        guard let m = liveHost?.openSlot.withLock({ $0.model }), m.folder == folder.directory, m.isOpen else { return nil }
        return m
    }

    /// 4.0.1 (Gate C, 2026-11-20): the open model of `folder` closed when nothing runs on it (no call, no take), its
    /// plaintext wiped: a model `client.model()` opened and did not hand out is never left open with no owner. Another
    /// folder's open model, or one in use, is left as it is. SDK 4.0.3: the Core's open model, whichever runtime opened it.
    func closeIdleModel(of folder: ModelFolder) {
        var models: [CoreModel] = []
        if let m = open.withLock({ $0?.model }) { models.append(m) }
        if let m = liveHost?.openSlot.withLock({ $0.model }), !models.contains(where: { $0 === m }) { models.append(m) }
        for m in models where m.folder == folder.directory {
            // under the lock of its Core's slot, so no open of that Core shares it while it closes
            m.host.openSlot.withLock { (_: CoreHost.OpenSlot) in
                if m.closeIfIdle() { open.withLock { if $0?.model === m { $0 = nil } } }
            }
        }
    }

    /// The folder of the Core's open model, when one is open. SDK 4.0.3: whichever runtime of the Core opened it.
    var openFolder: URL? {
        if let m = open.withLock({ $0?.model }), m.isOpen { return m.folder }
        guard let m = liveHost?.openSlot.withLock({ $0.model }), m.isOpen else { return nil }
        return m.folder
    }

    /// Closes this runtime's open model (its own, or the one it shares): its plaintext is wiped and released. A take
    /// running on it fails.
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
        // SDK 4.0.5: only its own entry (a flight `runAfter` started meanwhile stays joinable)
        if running[build] == t { running[build] = nil }
        return try r.get()
    }

    /// SDK 4.0.5 (ATTEST_40.md 40.2 item 8): `body` as a flight of its own once the one running for `build` has ended:
    /// the background attestation after a refusal never joins the attempt that was refused.
    func runAfter(_ build: String, _ body: @escaping @Sendable () async throws(RecognizerError) -> LeaseRecord) async throws(RecognizerError)
        -> LeaseRecord {
        if let t = running[build] {
            _ = await t.value
            if running[build] == t { running[build] = nil }
        }
        return try await run(build, body)
    }
}
