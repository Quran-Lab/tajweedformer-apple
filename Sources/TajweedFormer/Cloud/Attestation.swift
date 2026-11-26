import CryptoKit
import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// App Attest, behind a protocol so tests (and platforms without it) can stand in.
protocol AppAttesting: Sendable {
    var isSupported: Bool { get }
    /// A new key in the Secure Enclave; returns its id.
    func generateKey() async throws -> String
    /// Apple's attestation object for the key, over `clientDataHash`.
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    /// An assertion by an attested key over `clientDataHash`. Throws `DCError(.invalidKey)` when the
    /// key no longer exists (the app was reinstalled or restored, or App Attest was reset).
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

/// DCAppAttestService. Unsupported on the simulator, in Mac command-line tools and tests, and on
/// devices without a Secure Enclave: the SDK then runs unattested.
struct DeviceCheckAttester: AppAttesting {
    init() {}

    var isSupported: Bool {
        #if canImport(DeviceCheck) && !targetEnvironment(simulator)
        if #available(iOS 14.0, macOS 11.0, *) { return DCAppAttestService.shared.isSupported }
        #endif
        return false
    }

    func generateKey() async throws -> String {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, macOS 11.0, *) { return try await DCAppAttestService.shared.generateKey() }
        #endif
        throw RecognizerError.serviceUnavailable("App Attest")
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, macOS 11.0, *) {
            return try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
        }
        #endif
        throw RecognizerError.serviceUnavailable("App Attest")
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, macOS 11.0, *) {
            return try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
        }
        #endif
        throw RecognizerError.serviceUnavailable("App Attest")
    }

    /// `DCError.serverUnavailable`: Apple's attestation service did not take the request now (it throttles an app that
    /// asks too often, about 100 attestations a second per app).
    static func isThrottled(_ error: any Error) -> Bool {
        let e = error as NSError
        return e.domain == DCErrorDomain && e.code == DCError.Code.serverUnavailable.rawValue
    }

    /// DCError.invalidKey (or invalidInput, a key id App Attest does not take): the key is gone and
    /// only a new key and attestation help.
    static func isInvalidKey(_ error: any Error) -> Bool {
        #if canImport(DeviceCheck)
        let e = error as NSError
        return e.domain == DCErrorDomain
            && (e.code == DCError.Code.invalidKey.rawValue || e.code == DCError.Code.invalidInput.rawValue)
        #else
        return false
        #endif
    }
}

/// Where the attested key id is kept between launches.
protocol AttestKeyStoring: Sendable {
    func load() -> String?
    func save(_ keyID: String)
    func delete()
}

/// The Keychain, this device only (a key id restored onto another device would be useless: App
/// Attest keys never leave the Secure Enclave they were made in).
struct KeychainAttestKeyStore: AttestKeyStoring {
    /// The data protection keychain on macOS too (the iOS-style keychain: per app, the
    /// accessibility class honoured), not the Mac's file-based login keychain.
    var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "quranlab.sdk",
         kSecAttrAccount as String: "quranlab.attest.key",
         kSecUseDataProtectionKeychain as String: true]
    }

    func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let d = result as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func save(_ keyID: String) {
        delete()
        var add = query
        add[kSecValueData as String] = Data(keyID.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    func delete() { SecItemDelete(query as CFDictionary) }
}

/// SDK 4.0.2 (App Attest under load, the Ramadan capacity model): after an attestation that did not end in an attested
/// token or certificate (App Attest refused it on the device, `DCError.serverUnavailable` when Apple throttles the app
/// among them, or the API did not take it), no new App Attest key is attested before a wait of 1 hour, doubling to 24
/// hours. Meanwhile the token and the install certificate are unattested, as for a device without App Attest (ERRORS_40
/// 24.4 rule 3a: silent; the 24-hour class of the lease). An attestation the API accepts ends the row. Kept on disk, so a
/// restart does not ask Apple again. Tried before (to 4.0.1): an attestation that failed was asked again at the next
/// token or certificate, and one the API failed to take after Apple gave it (no answer, a 5xx) at the next call that
/// needed a token: a new App Attest key and an attestation each time.
/// SDK 4.0.5 (ATTEST_40.md 40.2 item 2): the hold is for the judged failures only (the server refused the attestation,
/// App Attest failed with an error other than `serverUnavailable` or `invalidKey`). A network moment and Apple's
/// `serverUnavailable` ("typically due to network connectivity issues") are retried by `AttestState`'s row instead: 4.0.2
/// held them too, and a strict app's install then made a certificate without attestation that its lease refused.
struct AttestBackoff: Codable, Sendable, Equatable {
    var failures = 0
    var notBefore: Date?
    /// The last failure was Apple's throttling (`DCError.serverUnavailable`): the install can attest later.
    var throttled = false

    static func wait(_ failures: Int) -> TimeInterval { min(86_400, 3600 * pow(2, Double(max(0, failures - 1)))) }

    func due(_ now: Date) -> Bool { notBefore.map { now >= $0 } ?? true }

    /// `retryAfter`: the `Retry-After` of a 429 the attest route answered (1 to 21600 s, else 0), the floor of the wait
    /// (SDK 4.0.2: a shed attestation is not made again sooner; a new one costs an App Attest attestation and a write
    /// of the database that is short then).
    mutating func failed(_ now: Date, throttled: Bool, retryAfter: Int = 0) {
        failures += 1
        notBefore = now.addingTimeInterval(max(Self.wait(failures), TimeInterval(retryAfter)))
        self.throttled = throttled
    }
}

/// An API token and whether App Attest backs it.
struct APIToken: Codable, Sendable, Equatable {
    let token: String
    let attested: Bool
    let expiresAt: Date
    /// The public key id part of the developer key it was issued under (not a secret).
    let keyID: String
    let app: String
}

/// Gets and caches the 24 h app token from qlab-api.
///
/// With App Attest (where supported) each install attests one key, once: challenge, new key,
/// attestation, `/v1/attest`, and the key id goes into the Keychain. Every later token comes from an
/// assertion by that key (challenge, `generateAssertion`, `/v1/attest/assert`), as Apple intends; Apple
/// may throttle apps that attest too often. A new key is attested only when the old one is gone or
/// invalid: `DCError.invalidKey`, the server answering `attest_key_unknown` or `attest_key_revoked`
/// (or refusing the key's assertions), or a reinstall (the Keychain outlives the app's files, App
/// Attest keys do not). Unsupported devices get an unattested token, as before.
///
/// Refreshes are serialized: one fetch in flight per provider, so two assertions never race for
/// the key's counter here. Another provider in the process using the same key can still lose the
/// race on the server (`counter_not_increasing`); a lost race is retried once with a new assertion.
actor TokenProvider {
    private let http: HTTPClient
    private let apiURL: URL
    private let key: String
    private let app: AppIdentity
    private let teamID: String?
    private let attester: any AppAttesting
    private let keys: any AttestKeyStoring
    private let file: JSONFile<APIToken>
    /// A fingerprint of the stored key id, among the app's files: missing after a reinstall.
    private let keyMarker: JSONFile<String>
    private var cached: APIToken?
    private var inFlight: Task<APIToken, any Error>?
    /// Told when the server issued a token: an answer that accepts the key (it clears a remembered refusal).
    private let issued: @Sendable () -> Void
    /// SDK 4.0.2: the wait before the next attestation (`AttestBackoff`), and the file that keeps it. SDK 4.0.5: for the
    /// judged failures only (ATTEST_40.md 40.2 item 2).
    private let backoffFile: JSONFile<AttestBackoff>
    nonisolated let attestBackoff: Locked<AttestBackoff>
    /// SDK 4.0.5 (40.2 item 5): the attestation owed, its row, its key and Apple's object, kept across launches.
    nonisolated let attestState: Locked<AttestState>
    private let stateFile: JSONFile<AttestState>
    /// Quran Lab's signing keys: an attest answer's certificate is held to them before it is taken (40.4 item 3).
    private let trustedKeys: [Data]
    /// SDK 4.0.5 (ATTEST_40.md 40.2 item 1): the config in force says the lease needs attestation (`attest: "required"`).
    private let attestRequired: @Sendable () -> Bool
    private let clock: @Sendable () -> Date

    init(http: HTTPClient, apiURL: URL, key: String, app: AppIdentity, teamID: String?,
         attester: any AppAttesting, attestKeys: any AttestKeyStoring = KeychainAttestKeyStore(), storage: URL,
         clock: @escaping @Sendable () -> Date = { Date() }, trustedKeys: [Data] = [],
         attestRequired: @escaping @Sendable () -> Bool = { true }, issued: @escaping @Sendable () -> Void = {}) {
        self.issued = issued
        self.clock = clock
        self.trustedKeys = trustedKeys
        self.attestRequired = attestRequired
        let sf = JSONFile<AttestState>(url: storage.appendingPathComponent("cloud/attest-state.json"))
        stateFile = sf
        // unreadable is taken as nothing owed here: the next certificate attests from the start, as before 4.0.5
        attestState = Locked((sf.read().takingUnreadableAsMissing ?? AttestState()).readBack(now: Int64(clock().timeIntervalSince1970)))
        let f = JSONFile<AttestBackoff>(url: storage.appendingPathComponent("cloud/attest-backoff.json"))
        backoffFile = f
        // unreadable is taken as not there here: an attestation may then be asked for at once, as before 4.0.2
        attestBackoff = Locked(f.read().takingUnreadableAsMissing ?? AttestBackoff())
        self.http = http
        self.apiURL = apiURL
        self.key = key
        self.app = app
        self.teamID = teamID
        self.attester = attester
        self.keys = attestKeys
        self.file = JSONFile(url: storage.appendingPathComponent("cloud/token.json"))
        self.keyMarker = JSONFile(url: storage.appendingPathComponent("cloud/attest-key.json"))
    }

    static func keyID(_ key: String) -> String {
        // qlk_v1_{key_id}_{sig}: the id is public, the signature is not stored anywhere
        let parts = key.split(separator: "_")
        return parts.count >= 4 ? parts[2..<(parts.count - 1)].joined(separator: "_") : ""
    }

    private var appID: String { "\(app.platform):\(app.bundleID)" }

    /// Whether a new attestation may be asked of App Attest now (`AttestBackoff`).
    private func attestDue() -> Bool { attestBackoff.withLock { $0.due(clock()) } }

    /// An attestation that did not end in an attested answer: the next waits.
    private func attestFailed(throttled: Bool = false, retryAfter: Int = 0) {
        let b = attestBackoff.withLock { (b: inout AttestBackoff) -> AttestBackoff in
            b.failed(clock(), throttled: throttled, retryAfter: retryAfter)
            return b
        }
        backoffFile.write(b)
    }

    /// The `Retry-After` of the 429 an attest route answered with `error` (0 for any other failure). `route` is the
    /// route's hold key (`RetryAfterHolds.route`): `attest`, or `attest/challenge` for the challenge, which is a route of
    /// its own (Mac, 11-26: read under `attest`, a challenge's 429 gave no floor, the owed attestation's next try came
    /// before the hold's end and failed on the hold, and the wait that failure added went past the server's Retry-After).
    private func retryAfter(of error: CloudError, route: String) -> Int {
        guard case .rejected(429, _, _, _) = error else { return 0 }
        return http.endpoints?.holds.lastRetryAfter(route) ?? 0
    }

    /// An attestation the API accepted: the row ends.
    private func attestAccepted() {
        attestBackoff.withLock { $0 = AttestBackoff() }
        backoffFile.delete()
    }

    /// SDK 4.0.5 (ERRORS_40 24.14 item 5): an unattested install of a new app release attests again at once: the row of
    /// App Attest failures ends (a release that adds the App Attest capability is not held by the old one's failures).
    nonisolated func clearAttestHold() {
        attestBackoff.withLock { $0 = AttestBackoff() }
        backoffFile.delete()
        // SDK 4.0.5 (ATTEST_40.md 40.2): and the owed attestation's wait
        let s = attestState.withLock { (s: inout AttestState) -> AttestState in
            s.nextTry = nil
            return s
        }
        if s.owed { stateFile.write(s) }
    }

    /// Apple throttles this app's attestations now, and the install will attest when the wait is over: an upload that
    /// needs an attested token waits for it (`ContributionOutbox`) instead of failing for good.
    /// SDK 4.0.5: Apple's service was unavailable at the owed attestation's last try (`DCError.serverUnavailable`).
    nonisolated var attestationThrottled: Bool {
        attestBackoff.withLock { $0.throttled && $0.failures > 0 } || attestState.withLock { $0.owed && $0.history.last?.cls == .transientApple }
    }

    private func usable(_ t: APIToken?) -> APIToken? {
        guard let t, t.keyID == Self.keyID(key), t.app == appID,
              t.expiresAt.timeIntervalSinceNow > 3600 else { return nil }
        return t
    }

    /// Why the last call of `token()` failed, nil when it gave a token: a call made with the token tells by it whether
    /// it was the token that failed (an error report's stage `attest`, contract 24.3).
    nonisolated let lastFailure = Locked<CloudError?>(nil)

    /// A token valid for at least another hour.
    func token() async throws(CloudError) -> APIToken {
        do throws(CloudError) {
            let t = try await obtain()
            lastFailure.withLock { $0 = nil }
            return t
        } catch {
            lastFailure.withLock { $0 = error }
            throw error
        }
    }

    private func obtain() async throws(CloudError) -> APIToken {
        if let t = usable(cached) { return t }
        // unreadable is taken as not there here, because a token is asked for again
        if let t = usable(file.read().takingUnreadableAsMissing) { cached = t; return t }
        let task: Task<APIToken, any Error>
        if let running = inFlight {
            task = running
        } else {
            task = Task { try await self.fetch() }
            inFlight = task
        }
        do {
            let t = try await task.value
            finish(task, with: t)
            return t
        } catch {
            finish(task, with: nil)
            throw (error as? CloudError) ?? .offline("\(error)")
        }
    }

    /// Clears the fetch once, whichever waiter resumes first, and never a newer fetch.
    private func finish(_ task: Task<APIToken, any Error>, with t: APIToken?) {
        guard inFlight == task else { return }
        inFlight = nil
        if let t {
            cached = t
            file.write(t)
            issued()
        }
    }

    /// Drops the cached token (after a 401). The attested key stays: the next token is an assertion.
    func invalidate() {
        cached = nil
        file.delete()
    }

    // MARK: fetching

    private func fetch() async throws(CloudError) -> APIToken {
        guard app.platform != "android", attester.isSupported, let team = teamID ?? Self.teamIDFromKeychain() else {
            return try await unattested()
        }
        if let keyID = storedKey() {
            switch try await renew(keyID: keyID) {
            case .token(let t): return t
            case .unattested: return try await unattested()
            case .newKey: forgetKey()
            }
        }
        // 4.0.2: a new attestation waits for its judged hold; 4.0.5 (ATTEST_40.md 40.2 item 4): and for the owed
        // attestation's next try. Meanwhile the token is unattested (24.4 rule 3a)
        guard attestDue(), stateDue() else { return try await unattested() }
        // SDK 4.0.5 (40.2): the token's attestation with the certificate's tries; one that ends owed (a network moment)
        // gives the unattested token this call needs (the token gates the config, 24.4 rule 3a) and stays owed: the
        // certificate a strict app's lease needs attests before any lease (`certify`)
        switch await attested(team: team, key: nil, patient: false) {
        case .done(let t, _): return t
        case .answeredUnattested(let t, _): return t
        case .notAttested(_, let failure, let refusal):
            if refusal, let failure { throw failure }
            return try await unattested()
        }
    }

    private enum Renewal { case token(APIToken), newKey, unattested }

    /// A token from an assertion by the attested key.
    private func renew(keyID: String) async throws(CloudError) -> Renewal {
        // 28.11 item 2 (SDK 4.0.2): the assert route held by a Retry-After fails as it did, with no challenge first
        try http.failIfHeld(apiURL.appendingPathComponent("v1/attest/assert"))
        for attempt in 0..<2 {
            let challenge = try await challenge()
            let assertion: Data
            do {
                assertion = try await attester.generateAssertion(keyID, clientDataHash: Self.clientDataHash(challenge))
            } catch {
                // the key is gone; anything else is App Attest failing on the device this time: the
                // key is kept and the token is unattested until it expires
                CauseChain.add(Self.appleHop(error))
                return DeviceCheckAttester.isInvalidKey(error) ? .newKey : .unattested
            }
            let body: [String: Any] = ["platform": app.platform, "bundle_id": app.bundleID, "key_id": keyID,
                                       "challenge": challenge, "assertion": assertion.base64EncodedString()]
            do throws(CloudError) {
                // SDK 4.0.5 (40.4 item 3): a 2xx without a token is unreachable on that host, and the next api host is asked
                let resp = try await post(try request("v1/attest/assert", body: body), accept: Self.tokenAccept(installKeys: false))
                return .token(try tokenFrom(resp))
            } catch {
                guard case .rejected(_, let code, let message, _) = error else { throw error }
                switch code {
                case "attest_key_unknown", "attest_key_revoked":
                    return .newKey
                case "assertion_failed" where message == "counter_not_increasing" && attempt == 0:
                    continue // another refresh with this key won the race; a new assertion counts higher
                case "assertion_failed":
                    return .newKey // the server cannot verify this key's assertions
                case "challenge_invalid", "team_mismatch":
                    return .unattested
                default:
                    throw error // rate limits, the developer key, a blocked app: the same for any token
                }
            }
        }
        return .newKey
    }

    // MARK: SDK 4.0.5: the attestation before the lease

    /// How an attestation with App Attest ended inside one call.
    private enum Attested {
        /// The server accepted it: an attested token, and with install keys the certificate.
        case done(APIToken, String?)
        /// The server answered with an unattested token (and certificate): it did not take App Attest's object.
        case answeredUnattested(APIToken, String?)
        /// No attested answer in this call. `failure`: the last failure; `refusal`: it is a refusal that is not about the
        /// attestation (the route's own rules: thrown). Otherwise the attestation is owed (`AttestState`), judged (4.0.2's
        /// hold) or unsupported: the caller decides whether an unattested answer may stand in.
        case notAttested(owed: Bool, failure: CloudError?, refusal: Bool)
    }

    /// One try's failure.
    private struct TryFailure {
        let cls: AttestClass
        let error: CloudError?
        /// A Quran Lab host answered in this try (the challenge, at least).
        let answered: Bool
        /// App Attest's own failure.
        let service: Bool
        var retryAfter = 0
    }

    private enum TryResult { case success(APIToken, String?), unattestedAnswer(APIToken, String?), failure(TryFailure) }

    /// The last failure of an attestation in this process (the error a call within Apple's floor gets).
    private var lastAttestError: CloudError?

    /// 40.2 items 3, 5 and 6: an attestation with App Attest, its tries inside this call (`AttestPolicy.InCall`), the owed
    /// key and Apple's object kept across tries and launches (`AttestState`). `key`: the install key a certificate is
    /// asked for (nil: the app token alone).
    /// `patient`: the tries of 40.2 item 3; false for the app token's attestation, which the config waits on and which an
    /// unattested token stands in for: one try (and a new key at once when the old one is gone).
    private func attested(team: String, key: (any InstallKey)?, patient: Bool = true) async -> Attested {
        // Apple's `serverUnavailable` is not asked again within its floor (40.2 item 4), whoever calls: the failure stands
        let now = Int64(clock().timeIntervalSince1970)
        if let last = attestState.withLock({ $0.history.last }), last.cls == .transientApple, now - last.at < Int64(AttestPolicy.appleFloor) {
            return .notAttested(owed: true, failure: lastAttestError ?? .offline("App Attest failed (serverUnavailable) [\(Self.appleErrorDomain) 4]"),
                                refusal: false)
        }
        var plan = AttestPolicy.InCall()
        let started = Date()
        while true {
            switch await attestOnce(team: team, key: key) {
            case .success(let t, let cert): return .done(t, cert)
            case .unattestedAnswer(let t, let cert):
                noteFailure(TryFailure(cls: .judged, error: nil, answered: true, service: false))
                return .answeredUnattested(t, cert)
            case .failure(let f):
                noteFailure(f)
                switch plan.after(f.cls, elapsed: Date().timeIntervalSince(started), draw: Double.random(in: AttestPolicy.draw)) {
                case .now:
                    continue
                case .again where !patient:
                    return .notAttested(owed: true, failure: f.error, refusal: false)
                case .again(let after, let maxWait):
                    // 40.2 item 3: the network down, the wait is until it is back (within the wall); else the timer
                    await NetworkWatch.shared.pause(after * AttestPolicy.timeScale.withLock { $0 }, upTo: maxWait * AttestPolicy.timeScale.withLock { $0 })
                    continue
                case .stop(let outcome):
                    return .notAttested(owed: outcome == "pending", failure: f.error, refusal: outcome == "refusal")
                }
            }
        }
    }

    /// One try: Apple's object sent again while its challenge is fresh (40.2 item 5), else a challenge, the owed key (made
    /// once and kept before `attestKey` is asked, 40.2 item 6) and its attestation; then `/v1/attest`.
    private func attestOnce(team: String, key: (any InstallKey)?) async -> TryResult {
        let bound = key?.installHash ?? ""
        let now = Int64(clock().timeIntervalSince1970)
        var s = attestState.withLock { $0 }
        let keyID: String, challenge: String, object: Data
        let answered: Bool
        if s.resendable(now: now, installHash: bound), let k = s.keyID, let o = s.object, let c = s.challenge {
            keyID = k
            challenge = c
            object = o
            answered = false
        } else {
            var route = "attest"
            do throws(CloudError) {
                // 28.11 item 2 (SDK 4.0.2): the attest route held by a Retry-After fails as it did, with no challenge and
                // no App Attest attestation first
                try http.failIfHeld(apiURL.appendingPathComponent("v1/attest"))
                route = "attest/challenge"
                challenge = try await self.challenge()
            } catch {
                return .failure(Self.requestFailure(error, answered: false, retryAfter: retryAfter(of: error, route: route)))
            }
            answered = true
            // 40.2 item 6: the same key is attested again only where Apple says so (after `serverUnavailable`, when it
            // gave no object); a key whose object Apple gave and which can no longer be sent (its challenge ended, or it
            // binds another install key) is replaced: Apple does not say a key can be attested twice
            if s.object != nil {
                s.forgetKey()
                saveState(s)
            }
            let id: String
            if let k = s.keyID {
                id = k
            } else {
                do {
                    id = try await attester.generateKey()
                } catch {
                    return .failure(Self.appleFailure(error))
                }
                s.keyID = id
                s.object = nil
                saveState(s)
            }
            do {
                object = try await attester.attestKey(id, clientDataHash: Self.clientDataHash(key == nil ? challenge : challenge + "\n" + bound))
            } catch {
                return .failure(Self.appleFailure(error))
            }
            keyID = id
            s.object = object
            s.challenge = challenge
            s.boundHash = bound
            saveState(s)
        }
        var body: [String: Any] = ["platform": app.platform, "bundle_id": app.bundleID, "team_id": team, "key_id": keyID,
                                   "attestation": object.base64EncodedString(), "challenge": challenge]
        if let key {
            guard let sig = key.attestProof(challenge: challenge) else {
                return .failure(TryFailure(cls: .judged, error: .invalid("the install key did not sign"), answered: answered, service: false))
            }
            body.merge(["install_key": key.spki.base64URL, "install_sign_key": key.spki.base64URL, "install_sig": sig,
                        "install_hw": key.hardware ? 1 : 0]) { mine, _ in mine }
        }
        do throws(CloudError) {
            let resp = try await post(try request("v1/attest", body: body),
                                      accept: Self.tokenAccept(installKeys: key != nil, trustedKeys: trustedKeys, installHash: key?.installHash))
            let t = try tokenFrom(resp)
            let cert = key == nil ? nil : ((try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any])?["install_cert"] as? String
            guard t.attested else { return .unattestedAnswer(t, cert) }
            rememberKey(keyID)
            attestAccepted()
            attestState.withLock { $0.attested() }
            stateFile.delete()
            return .success(t, cert)
        } catch {
            return .failure(Self.requestFailure(error, answered: true, retryAfter: retryAfter(of: error, route: "attest")))
        }
    }

    /// A failure of one try, told to the owed attestation's row (and 4.0.2's hold when judged); the key goes when App
    /// Attest or the server says it is gone or refused (40.2 item 6).
    private func noteFailure(_ f: TryFailure) {
        if let e = f.error { lastAttestError = e }
        let now = Int64(clock().timeIntervalSince1970)
        let s = attestState.withLock { (s: inout AttestState) -> AttestState in
            s.failed(f.cls, at: now, answered: f.answered, service: f.service, draw: Double.random(in: AttestPolicy.draw),
                     retryAfter: f.retryAfter)
            if [.newKey, .judged, .unsupported].contains(f.cls) { s.forgetKey() }
            return s
        }
        saveState(s)
        if f.cls == .judged { attestFailed(retryAfter: f.retryAfter) }
    }

    private func saveState(_ s: AttestState) {
        attestState.withLock { $0 = s }
        stateFile.write(s)
    }

    /// The owed attestation's next try has come (or none is owed).
    private func stateDue() -> Bool { attestState.withLock { $0.due(Int64(clock().timeIntervalSince1970)) } }

    /// A failed request of the attestation, classed (40.2 item 2).
    private static func requestFailure(_ e: CloudError, answered: Bool, retryAfter: Int) -> TryFailure {
        let f: AttestFailure
        switch e {
        case .rejected(let s, let code, _, _): f = .http(status: s, error: code.hasPrefix("http_") ? nil : code)
        case .offline(let why):
            if let s = ErrorCause.status(after: "redirect (HTTP ", in: why) { f = .http(status: s >= 300 && s < 400 ? 503 : s, error: nil) }
            else if let s = ErrorCause.status(after: "HTTP ", in: why) { f = .http(status: s, error: nil) }
            else { f = ErrorCause.answer(why, stage: "attest").reason == "timeout" ? .timeout : .noAnswer }
        case .invalid, .badAnswer: f = .invalidAnswer
        case .noKey, .storage: f = .http(status: 400, error: "local")
        }
        return TryFailure(cls: AttestPolicy.classify(f), error: e, answered: answered, service: false, retryAfter: retryAfter)
    }

    /// App Attest's failure, classed by its `DCError.Code` (40.2 item 2), with its hop (40.6).
    private static func appleFailure(_ error: any Error) -> TryFailure {
        CauseChain.add(appleHop(error))
        let e = error as NSError
        let name = e.domain == appleErrorDomain ? AttestPolicy.appleCodeName(e.code) : "unknownSystemFailure"
        var unsupported = false
        if let r = error as? RecognizerError, case .serviceUnavailable = r { unsupported = true }
        let cls = unsupported ? AttestClass.unsupported : AttestPolicy.classify(.apple(name))
        return TryFailure(cls: cls, error: .offline("App Attest failed (\(name)) [\(e.domain) \(e.code)]"), answered: true, service: true)
    }

    /// `DCErrorDomain`, by its value so the classification reads it on every platform.
    static let appleErrorDomain = "com.apple.devicecheck.error"

    /// The hop of an App Attest failure (40.6): stage `attest`, reason `attestation_failed`, the error's domain and code.
    private static func appleHop(_ error: any Error) -> CauseHop? {
        let e = error as NSError
        return CauseHop.made(stage: "attest", reason: "attestation_failed", errorName: e.domain, errorCode: String(e.code))
    }

    /// 40.4 item 3: the answer `/v1/attest` and `/v1/attest/assert` ask for. A 2xx that fails is unreachable on that host,
    /// and the next api host is asked; its check names it (40.5).
    static func tokenAccept(installKeys: Bool, trustedKeys: [Data] = [], installHash: String? = nil) -> @Sendable (HTTPClient.Response) -> Bool {
        { (r: HTTPClient.Response) -> Bool in
            guard (200..<300).contains(r.status) else { return false }
            if let c = AnswerCheck.tokenAnswer(r.body, installKeys: installKeys) {
                AnswerCheck.failed(c)
                return false
            }
            if installKeys, !trustedKeys.isEmpty, let hash = installHash,
               let o = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any], let cert = o["install_cert"] as? String,
               let c = InstallCertificate.check(cert, trustedKeys: trustedKeys, installHash: hash) {
                AnswerCheck.failed(c)
                return false
            }
            return true
        }
    }

    // MARK: SDK 4.0: the install certificate

    /// A full attest with the install's NEW key, once per certificate (30 days, or 24 hours unattested): the key's
    /// SPKI as both install keys (one Secure Enclave key agrees and signs), `install_sig` by it over the challenge (or
    /// "-" without one) and its install hash, `install_hw`, and App Attest where the device has it, its client data hash
    /// covering `challenge "\n" <install hash>`. Returns the answer's certificate; the answer's token replaces the one in
    /// hand, and later tokens come from that App Attest key's assertions as before.
    /// SDK 4.0.5 (ATTEST_40.md 40.2): App Attest first, with its tries; an attestation that ends owed (a network moment,
    /// Apple's service unavailable) throws its last failure and makes NO certificate without attestation (4.0.2 made one
    /// inside its hold, which a strict app refuses); the install goes on unattested only where the platform cannot attest
    /// (40.3: `unattestedWhy`) or the attestation was judged (refused: 4.0.2's hold, as before).
    /// SDK 4.0.5 (40.2 item 1): where the config does not say the lease needs attestation, the attestation is tried once
    /// in the call and a certificate without attestation stands in when it does not end attested for a transient cause
    /// (the lease at once; the attestation stays owed). `attestedOnly` (the upgrade of a capped install, 40.2 item 1):
    /// an attested certificate or a failure, never a certificate without attestation.
    func certify(_ key: any InstallKey, attestedOnly: Bool = false) async throws(CloudError) -> String {
        // 28.11 item 2 (SDK 4.0.2): the attest route held by a Retry-After fails as it did, with no challenge and no
        // App Attest attestation first
        try http.failIfHeld(apiURL.appendingPathComponent("v1/attest"))
        // an Android stand-in of the tests: never App Attest, as before
        if attestedOnly, app.platform == "android" || cannotAttest() != nil { throw .offline("this install cannot attest now") }
        if app.platform == "android" {
            whyUnattested.withLock { $0 = nil }
            return try await sendUnattested(key)
        }
        if let why = cannotAttest() {
            whyUnattested.withLock { $0 = why }
            return try await sendUnattested(key)
        }
        // inside 4.0.2's judged hold: unattested, as before (24.4 rule 3a)
        guard attestDue(), let team = teamID ?? Self.teamIDFromKeychain() else {
            if attestedOnly { throw .offline("the attestation is held") }
            whyUnattested.withLock { $0 = nil }
            return try await sendUnattested(key)
        }
        let required = attestRequired()
        switch await attested(team: team, key: key, patient: required) {
        case .answeredUnattested where attestedOnly:
            throw .offline("Quran Lab did not take the attestation")
        case .done(let t, let cert), .answeredUnattested(let t, let cert):
            guard let cert else { throw .invalid("the attest answer has no install certificate: the protected model is off on that server (schema:install_cert)") }
            cached = t
            file.write(t)
            issued()
            whyUnattested.withLock { $0 = nil }
            return cert
        case .notAttested(let owed, let failure, let refusal):
            if refusal, let failure { throw failure }
            if attestedOnly { throw failure ?? .offline("the attestation is owed") }
            if owed {
                // 40.3: App Attest unavailable for a day while Quran Lab answered is a named path; else, where the lease
                // needs attestation, the lease waits (40.2 item 1), and elsewhere a certificate without attestation
                // stands in, the attestation owed and tried in the background
                let named = attestState.withLock({ $0.unattested })
                guard named != nil || !required else { throw failure ?? .offline("the attestation is owed") }
                whyUnattested.withLock { $0 = named }
                return try await sendUnattested(key)
            }
            // judged: 4.0.2's hold runs, and the install goes on unattested as before; unsupported: 40.3
            let unsupported = attestState.withLock { $0.history.last?.cls == .unsupported }
            whyUnattested.withLock { $0 = unsupported ? "unsupported" : nil }
            return try await sendUnattested(key)
        }
    }

    /// 40.3: why this process cannot attest with App Attest, nil when it can try.
    nonisolated func cannotAttest() -> String? {
        if !attester.isSupported { return "unsupported" }
        if Self.inUnservedExtension { return "extension" }
        if (teamID ?? Self.teamIDFromKeychain()) == nil { return "no_team" }
        return nil
    }

    /// An app extension of a kind App Attest does not serve (Apple: only action, extensible SSO and watchOS extensions are).
    static let inUnservedExtension: Bool = {
        guard Bundle.main.bundleURL.pathExtension == "appex" else { return false }
        let point = (Bundle.main.infoDictionary?["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String ?? ""
        return !["com.apple.ui-services", "com.apple.services", "com.apple.AppSSO.idp-extension"].contains(point)
    }()

    /// The certificate without App Attest: the install keys and `install_sig` alone (att none).
    private func sendUnattested(_ key: any InstallKey) async throws(CloudError) -> String {
        guard let sig = key.attestProof(challenge: nil) else { throw .invalid("the install key did not sign") }
        let body: [String: Any] = ["platform": app.platform, "bundle_id": app.bundleID, "install_key": key.spki.base64URL,
                                   "install_sign_key": key.spki.base64URL, "install_sig": sig, "install_hw": key.hardware ? 1 : 0]
        let resp = try await post(try request("v1/attest", body: body),
                                  accept: Self.tokenAccept(installKeys: true, trustedKeys: trustedKeys, installHash: key.installHash))
        let t = try tokenFrom(resp)
        guard let o = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any], let cert = o["install_cert"] as? String else {
            throw .invalid("the attest answer has no install certificate: the protected model is off on that server (schema:install_cert)")
        }
        cached = t
        file.write(t)
        issued()
        return cert
    }

    /// 40.3: why the certificate in force was made without App Attest (`unattested` of the lease request), nil when it
    /// was attested or the reason is not a named path.
    nonisolated let whyUnattested = Locked<String?>(nil)

    /// 40.2: an attestation is owed (the lease waits for it) and its next background try has come; with `networkBack`
    /// (40.2 item 4: the network came back) whatever the row's wait, never inside 4.0.2's hold of a judged failure.
    nonisolated func attestationOwedAndDue(networkBack: Bool = false) -> Bool {
        attestState.withLock { $0.owed && (networkBack || $0.due(Int64(clock().timeIntervalSince1970))) } && attestBackoff.withLock { $0.due(clock()) }
    }

    /// 40.2 item 8: a lease refused for attestation makes it owed now: the row's wait ends, unless the last failure was
    /// judged (the server refused the attestation: 4.0.2's hold runs, so a refusal is never asked for again at once).
    nonisolated func oweAttestation(after seconds: Int? = nil) {
        // nothing to owe where the platform cannot attest (40.3): a refusal there is the named path's, and attesting
        // again would only make a new install key and the same refusal
        guard app.platform != "android", cannotAttest() == nil else { return }
        let s = attestState.withLock { (s: inout AttestState) -> AttestState in
            s.owed = true
            // the row's wait ends, except after a judged failure (4.0.2's hold) and on a named path (40.3: App Attest
            // unavailable for a day; its tries keep the row's schedule, or a strict app's refusal would loop every minute);
            // an upgrade whose full lease did not come (40.2 item 10) owes it again after its own wait
            if let seconds { s.nextTry = Int64(clock().timeIntervalSince1970) + Int64(seconds) }
            else if s.history.last?.cls != .judged, s.unattested == nil { s.nextTry = nil }
            return s
        }
        stateFile.write(s)
    }

    /// `diagnose()`'s `protected.attestation` (40.6 item 2), from the certificate in force (`att`, nil when none).
    nonisolated func diagnosis(certificateAtt: String?) -> TajweedDiagnosis.Attestation {
        let s = attestState.withLock { $0 }
        let state: String
        var why: String?
        switch certificateAtt {
        case .some("none"):
            state = s.owed ? "pending" : "unattested"
            why = s.owed ? nil : (whyUnattested.withLock { $0 } ?? "judged")
        case .some: state = "attested"
        case .none: state = s.owed ? "pending" : "none"
        }
        return TajweedDiagnosis.Attestation(state: state, why: why, failures: s.owed ? s.failures : 0, nextTry: s.owed ? s.nextTry : nil)
    }

    private func unattested() async throws(CloudError) -> APIToken {
        try tokenFrom(try await post(try request("v1/attest", body: ["platform": app.platform, "bundle_id": app.bundleID]),
                                     accept: Self.tokenAccept(installKeys: false)))
    }

    /// SDK 4.0.5 (ATTEST_40.md 40.4 item 3): a request of the attest routes through the role its URL names (as every
    /// request of the token was, and as the lease route's are), `accept` saying what a 2xx must be to be the answer;
    /// an answer that is not a 2xx fails as `HTTPClient.checked` fails it.
    private func post(_ r: URLRequest, accept: @escaping @Sendable (HTTPClient.Response) -> Bool) async throws(CloudError) -> HTTPClient.Response {
        let resp = try await http.send(r, accepting: accept)
        guard (200..<300).contains(resp.status) else { throw HTTPClient.failure(status: resp.status, body: resp.body) }
        return resp
    }

    private func request(_ path: String, body: [String: Any]) throws(CloudError) -> URLRequest {
        var r = try HTTPClient.jsonRequest(apiURL.appendingPathComponent(path), body: body, auth: nil)
        r.setValue(key, forHTTPHeaderField: "x-qlab-key")
        return r
    }

    private func tokenFrom(_ resp: HTTPClient.Response) throws(CloudError) -> APIToken {
        guard let o = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any],
              let tok = o["token"] as? String, tok.hasPrefix("qlt_") else {
            // SDK 4.0.5 (ATTEST_40.md 40.5): the check it failed, for the cause's error_code
            throw .invalid("attest response has no token (\(AnswerCheck.tokenAnswer(resp.body, installKeys: false) ?? AnswerCheck.token))")
        }
        let ttl = (o["expires_in"] as? Double) ?? 86_400
        return APIToken(token: tok, attested: (o["attested"] as? Bool) ?? false,
                        expiresAt: Date().addingTimeInterval(ttl), keyID: Self.keyID(key), app: appID)
    }

    /// `GET /v1/attest/challenge`. SDK 4.0.5 (40.4 item 3): only a challenge in the strict form is the answer; another 2xx
    /// is unreachable on that host, and the next api host is asked (`schema:challenge`, 40.5).
    private func challenge() async throws(CloudError) -> String {
        var r = URLRequest(url: apiURL.appendingPathComponent("v1/attest/challenge"))
        r.setValue(key, forHTTPHeaderField: "x-qlab-key")
        let resp = try await post(r, accept: { (a: HTTPClient.Response) -> Bool in
            guard (200..<300).contains(a.status) else { return false }
            if let c = AnswerCheck.challenge(a.body).check {
                AnswerCheck.failed(c)
                return false
            }
            return true
        })
        let read = AnswerCheck.challenge(resp.body)
        guard let challenge = read.challenge else { throw .invalid("no challenge (\(read.check ?? AnswerCheck.challengeForm))") }
        return challenge
    }

    static func clientDataHash(_ challenge: String) -> Data { Data(SHA256.hash(data: Data(challenge.utf8))) }

    // MARK: the attested key

    private static func fingerprint(_ keyID: String) -> String { Data(SHA256.hash(data: Data(keyID.utf8))).hex }

    /// The attested key id, unless the app's files were reset under it (a reinstall).
    private func storedKey() -> String? {
        guard let k = keys.load() else { return nil }
        // unreadable is taken as not there here, because the App Attest key is then made and attested again
        guard keyMarker.read().takingUnreadableAsMissing == Self.fingerprint(k) else {
            forgetKey()
            return nil
        }
        return k
    }

    private func rememberKey(_ keyID: String) {
        keys.save(keyID)
        keyMarker.write(Self.fingerprint(keyID))
    }

    private func forgetKey() {
        keys.delete()
        keyMarker.delete()
    }

    /// The team id from the app's default keychain access group ("TEAMID.bundle.id"): a keychain
    /// item is added once and read back for its access group. Nil in a binary without a team
    /// (unsigned, or ad hoc signed: `swift test`), where App Attest does not work either.
    static func teamIDFromKeychain() -> String? {
        var result: CFTypeRef?
        var status = SecItemCopyMatching(teamIDProbeQuery as CFDictionary, &result)
        if status == errSecItemNotFound {
            var add = teamIDProbeQuery
            add[kSecValueData as String] = Data()
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, &result)
        }
        guard status == errSecSuccess, let attrs = result as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String else { return nil }
        let team = group.split(separator: ".").first.map(String.init)
        return team.flatMap { $0.count == 10 && $0.allSatisfy { $0.isUppercase || $0.isNumber } ? $0 : nil }
    }

    /// In the data protection keychain: on macOS only its items carry the app's access group
    /// ("TEAMID.bundle.id"); the file-based keychain's do not.
    static var teamIDProbeQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrAccount as String: "quranlab.teamid.probe",
         kSecAttrService as String: "quranlab.sdk",
         kSecReturnAttributes as String: true,
         kSecUseDataProtectionKeychain as String: true]
    }
}
