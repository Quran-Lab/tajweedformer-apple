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
    /// SDK 4.0.2: the wait before the next attestation (`AttestBackoff`), and the file that keeps it.
    private let backoffFile: JSONFile<AttestBackoff>
    nonisolated let attestBackoff: Locked<AttestBackoff>
    private let clock: @Sendable () -> Date

    init(http: HTTPClient, apiURL: URL, key: String, app: AppIdentity, teamID: String?,
         attester: any AppAttesting, attestKeys: any AttestKeyStoring = KeychainAttestKeyStore(), storage: URL,
         clock: @escaping @Sendable () -> Date = { Date() }, issued: @escaping @Sendable () -> Void = {}) {
        self.issued = issued
        self.clock = clock
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

    /// The `Retry-After` of the 429 the attest route answered with `error` (0 for any other failure).
    private func retryAfter(of error: CloudError) -> Int {
        guard case .rejected(429, _, _, _) = error else { return 0 }
        return http.endpoints?.holds.lastRetryAfter("attest") ?? 0
    }

    /// An attestation the API accepted: the row ends.
    private func attestAccepted() {
        attestBackoff.withLock { $0 = AttestBackoff() }
        backoffFile.delete()
    }

    /// Apple throttles this app's attestations now, and the install will attest when the wait is over: an upload that
    /// needs an attested token waits for it (`ContributionOutbox`) instead of failing for good.
    nonisolated var attestationThrottled: Bool { attestBackoff.withLock { $0.throttled && $0.failures > 0 } }

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
        // 4.0.2: a new attestation waits for its backoff; meanwhile the token is unattested (24.4 rule 3a)
        guard attestDue() else { return try await unattested() }
        return try await attestNewKey(team: team)
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
                return DeviceCheckAttester.isInvalidKey(error) ? .newKey : .unattested
            }
            let body: [String: Any] = ["platform": app.platform, "bundle_id": app.bundleID, "key_id": keyID,
                                       "challenge": challenge, "assertion": assertion.base64EncodedString()]
            do throws(CloudError) {
                return .token(try tokenFrom(try await http.checked(try request("v1/attest/assert", body: body))))
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

    /// Challenge, a new key, its attestation and `/v1/attest`. The key id is kept once the server
    /// accepted the attestation.
    private func attestNewKey(team: String) async throws(CloudError) -> APIToken {
        let keyID: String, fields: [String: Any]
        // 28.11 item 2 (SDK 4.0.2): the attest route held by a Retry-After fails as it did, with no challenge and no
        // App Attest attestation first
        try http.failIfHeld(apiURL.appendingPathComponent("v1/attest"))
        let challenge = try await challenge()
        do {
            (keyID, fields) = try await attest(team: team, challenge: challenge)
        } catch {
            // App Attest failed on the device (Apple's throttling, Apple unreachable, another failure): run unattested,
            // and the next attestation waits (4.0.2)
            attestFailed(throttled: DeviceCheckAttester.isThrottled(error))
            return try await unattested()
        }
        let body = fields.merging(["platform": app.platform, "bundle_id": app.bundleID]) { a, _ in a }
        do throws(CloudError) {
            let t = try tokenFrom(try await http.checked(try request("v1/attest", body: body)))
            if t.attested {
                rememberKey(keyID)
                attestAccepted()
            } else {
                attestFailed()
            }
            return t
        } catch {
            // the attestation was spent: the next one waits, whatever the API answered (4.0.1 attested a new key at the
            // next call that needed a token after a 5xx or no answer); a 429's Retry-After is the wait's floor
            attestFailed(retryAfter: retryAfter(of: error))
            // an attestation the server refuses still leaves the unattested path
            guard case .rejected(_, let code, _, _) = error,
                  ["attestation_failed", "challenge_invalid", "team_mismatch", "attest_key_revoked"].contains(code) else { throw error }
            return try await unattested()
        }
    }

    // MARK: SDK 4.0: the install certificate

    /// A full attest with the install's NEW key, once per certificate (30 days, or 24 hours unattested): the key's
    /// SPKI as both install keys (one Secure Enclave key agrees and signs), `install_sig` by it over the challenge (or
    /// "-" without one) and its install hash, `install_hw`, and App Attest where the device has it, with a new App
    /// Attest key whose client data hash covers `challenge "\n" <install hash>`. Returns the answer's certificate; the
    /// answer's token replaces the one in hand, and later tokens come from that App Attest key's assertions as before.
    /// An attestation the server refuses is sent once more without it (`att none`), as `attestNewKey` does.
    func certify(_ key: any InstallKey) async throws(CloudError) -> String {
        // 28.11 item 2 (SDK 4.0.2): the attest route held by a Retry-After fails as it did, with no challenge and no
        // App Attest attestation first
        try http.failIfHeld(apiURL.appendingPathComponent("v1/attest"))
        let installHash = key.installHash
        var attested: (keyID: String, fields: [String: String], challenge: String)?
        // 4.0.2: an attestation waits for its backoff (`AttestBackoff`); meanwhile the certificate is unattested
        if app.platform != "android", attester.isSupported, attestDue(), let team = teamID ?? Self.teamIDFromKeychain() {
            let challenge = try await challenge()
            do {
                let keyID = try await attester.generateKey()
                let object = try await attester.attestKey(keyID, clientDataHash: Self.clientDataHash(challenge + "\n" + installHash))
                attested = (keyID, ["team_id": team, "key_id": keyID, "attestation": object.base64EncodedString(), "challenge": challenge], challenge)
            } catch {
                // App Attest failed on the device this time: the certificate is unattested, and the next attestation waits
                attested = nil
                attestFailed(throttled: DeviceCheckAttester.isThrottled(error))
            }
        }
        func send(_ a: (keyID: String, fields: [String: String], challenge: String)?) async throws(CloudError) -> (APIToken, String) {
            guard let sig = key.attestProof(challenge: a?.challenge) else { throw .invalid("the install key did not sign") }
            var body: [String: Any] = ["platform": app.platform, "bundle_id": app.bundleID, "install_key": key.spki.base64URL,
                                       "install_sign_key": key.spki.base64URL, "install_sig": sig, "install_hw": key.hardware ? 1 : 0]
            if let a { body.merge(a.fields.mapValues { $0 as Any }) { mine, _ in mine } }
            let resp = try await http.checked(try request("v1/attest", body: body))
            let t = try tokenFrom(resp)
            guard let o = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any], let cert = o["install_cert"] as? String else {
                throw .invalid("the attest answer has no install certificate (the server's protected model is off)")
            }
            return (t, cert)
        }
        let answer: (APIToken, String)
        do throws(CloudError) {
            answer = try await send(attested)
            if let a = attested {
                if answer.0.attested {
                    rememberKey(a.keyID)
                    attestAccepted()
                } else {
                    attestFailed()
                }
            }
        } catch {
            // an attestation that was sent and not taken: the next one waits
            if attested != nil { attestFailed(retryAfter: retryAfter(of: error)) }
            guard attested != nil, case .rejected(_, let code, _, _) = error,
                  ["attestation_failed", "challenge_invalid", "team_mismatch", "attest_key_revoked"].contains(code) else { throw error }
            answer = try await send(nil)
        }
        cached = answer.0
        file.write(answer.0)
        issued()
        return answer.1
    }

    private func unattested() async throws(CloudError) -> APIToken {
        try tokenFrom(try await http.checked(try request("v1/attest", body: ["platform": app.platform, "bundle_id": app.bundleID])))
    }

    private func request(_ path: String, body: [String: Any]) throws(CloudError) -> URLRequest {
        var r = try HTTPClient.jsonRequest(apiURL.appendingPathComponent(path), body: body, auth: nil)
        r.setValue(key, forHTTPHeaderField: "x-qlab-key")
        return r
    }

    private func tokenFrom(_ resp: HTTPClient.Response) throws(CloudError) -> APIToken {
        guard let o = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any],
              let tok = o["token"] as? String, tok.hasPrefix("qlt_") else {
            throw .invalid("attest response has no token")
        }
        let ttl = (o["expires_in"] as? Double) ?? 86_400
        return APIToken(token: tok, attested: (o["attested"] as? Bool) ?? false,
                        expiresAt: Date().addingTimeInterval(ttl), keyID: Self.keyID(key), app: appID)
    }

    private func challenge() async throws(CloudError) -> String {
        var r = URLRequest(url: apiURL.appendingPathComponent("v1/attest/challenge"))
        r.setValue(key, forHTTPHeaderField: "x-qlab-key")
        let resp = try await http.checked(r)
        guard let o = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any],
              let challenge = o["challenge"] as? String else { throw .invalid("no challenge") }
        return challenge
    }

    static func clientDataHash(_ challenge: String) -> Data { Data(SHA256.hash(data: Data(challenge.utf8))) }

    /// Key generation and attestation over `challenge`; returns the key id and the fields /v1/attest adds. Throws App
    /// Attest's own error.
    private func attest(team: String, challenge: String) async throws -> (String, [String: Any]) {
        let keyID = try await attester.generateKey()
        let object = try await attester.attestKey(keyID, clientDataHash: Self.clientDataHash(challenge))
        return (keyID, ["team_id": team, "key_id": keyID, "attestation": object.base64EncodedString(), "challenge": challenge])
    }

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
