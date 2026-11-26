import Foundation

/// SDK 4.0.5:
/// the attestation before the lease, retried through a flaky network. A failure of a request, of App Attest or of the
/// server's judgement is one of these classes; the class decides what comes next.
enum AttestClass: String, Sendable, Codable, CaseIterable {
    /// No answer, a stall, a 5xx, a 2xx that is not what was asked on every host, `challenge_invalid`: the same key, again.
    case transient
    /// App Attest's `DCError.serverUnavailable` ("typically due to network connectivity issues", Apple): the same key and,
    /// while the challenge is fresh, the same client data hash; never before `AttestPolicy.appleFloor`.
    case transientApple = "transient_apple"
    /// A 429 of the attest routes: its `Retry-After` is the floor of the next wait; no more tries inside the call.
    case slowDown = "slow_down"
    /// `DCError.invalidKey` or `invalidInput`, `attest_key_unknown`, `assertion_failed`: a new key at once, once per attempt.
    case newKey = "new_key"
    /// The server refused the attestation, or App Attest failed with another error: the key goes, 4.0.2's hold applies.
    case judged
    /// The platform cannot attest here (40.3).
    case unsupported
    /// A refusal that is not about the attestation (a stop, `key_revoked`): the route's own rules.
    case refusal
}

/// One failure of the attestation, as `AttestPolicy.classify` reads it.
enum AttestFailure: Sendable, Equatable {
    case noAnswer
    case timeout
    case invalidAnswer
    case http(status: Int, error: String?)
    /// An App Attest error by its `DCError.Code` name (`serverUnavailable`, `invalidKey`, `featureUnsupported`, ...).
    case apple(String)
}

enum AttestPolicy {
    /// 40.2 item 3: tries inside one call, the waits before the 2nd and 3rd (each times a draw), and the wall after which
    /// no try starts.
    static let inCallTries = 3
    static let inCallWaits: [Double] = [1, 3]
    static let inCallWall: Double = 20
    /// Every wait is multiplied by a draw uniform in this range.
    static let draw: ClosedRange<Double> = 0.5...1.5
    /// 40.2 item 4: the background's first wait after a transient failure and its largest base wait, seconds.
    static let backgroundBase = 30
    static let backgroundCap = 3600
    /// `DCError.serverUnavailable` never comes back sooner.
    static let appleFloor = 60
    /// After the network comes back: a try within this many seconds, at most one per `pathMinGap`.
    static let pathDelay: ClosedRange<Double> = 0...3
    static let pathMinGap: Double = 60
    /// 4.0.2's hold (`AttestBackoff`), kept for the judged failures only.
    static let holdBase = 3600
    static let holdCap = 86_400
    /// 40.3: App Attest unavailable this long, with this many tries, while Quran Lab answered: `apple_unavailable`.
    static let namedAfter: Int64 = 86_400
    static let namedMinTries = 6

    /// Tests only: a factor on the waits inside a call (the policy's numbers stay those of the contract).
    static let timeScale = Locked<Double>(1)

    /// A `DCError.Code` by its name, from its raw value (DeviceCheck's `DCError.Code`: 0 to 4).
    static func appleCodeName(_ code: Int) -> String {
        let names = ["unknownSystemFailure", "featureUnsupported", "invalidInput", "invalidKey", "serverUnavailable"]
        return names.indices.contains(code) ? names[code] : "unknownSystemFailure"
    }

    static let judgedErrors: Set<String> = ["attestation_failed", "team_mismatch", "attest_key_revoked", "lease_integrity_failed"]
    static let newKeyErrors: Set<String> = ["attest_key_unknown", "assertion_failed"]

    /// 40.2 item 2 (`classify` in the vectors).
    static func classify(_ f: AttestFailure) -> AttestClass {
        switch f {
        case .noAnswer, .timeout, .invalidAnswer: return .transient
        case .apple(let code):
            switch code {
            case "serverUnavailable": return .transientApple
            case "invalidKey", "invalidInput": return .newKey
            case "featureUnsupported": return .unsupported
            default: return .judged
            }
        case .http(let status, let error):
            if status == 429 { return .slowDown }
            if status >= 500 || (200..<300).contains(status) { return .transient }
            if error == "challenge_invalid" { return .transient }
            if let e = error, newKeyErrors.contains(e) { return .newKey }
            if let e = error, judgedErrors.contains(e) { return .judged }
            return .refusal
        }
    }

    /// 40.2 item 4 (`background` in the vectors): seconds from a failure of `cls` to the next background try; nil for none.
    /// `failures` counts the transient failures in a row, this one included; `judged` the judged ones (4.0.2's hold).
    static func background(_ cls: AttestClass, failures: Int, draw: Double, retryAfter: Int = 0, judged: Int = 0) -> Int? {
        switch cls {
        case .newKey: return 0
        case .unsupported, .refusal: return nil
        case .judged: return min(holdCap, holdBase << min(16, max(0, judged - 1)))
        case .transient, .transientApple, .slowDown:
            let base = min(backgroundBase << min(16, max(0, failures - 1)), backgroundCap)
            var w = Int((Double(base) * draw).rounded())
            if cls == .transientApple { w = max(w, appleFloor) }
            if (1...21_600).contains(retryAfter) { w = max(w, retryAfter) }
            return w
        }
    }

    /// 40.2 item 3: what comes after a try inside one call.
    enum Next: Equatable, Sendable {
        /// Try again after this many seconds (or as soon as the network is back, when it is down, within `maxWait`).
        case again(after: Double, maxWait: Double)
        /// Try again at once (a new key).
        case now
        /// The call's tries end: the background takes over (`pending`), or the class ended the attestation.
        case stop(String)
    }

    /// The tries of one call (`in_call` in the vectors).
    struct InCall: Sendable {
        private(set) var tries = 0
        private var newKeys = 0

        init() {}

        /// After a try that took the call to `elapsed` seconds since its first and ended in `cls`; `draw` for the wait.
        mutating func after(_ cls: AttestClass, elapsed: Double, draw: Double) -> Next {
            tries += 1
            switch cls {
            case .newKey:
                newKeys += 1
                return newKeys > 1 ? .stop("judged") : .now
            case .judged, .unsupported, .refusal: return .stop(cls.rawValue)
            case .slowDown: return .stop("pending")
            case .transient, .transientApple:
                guard tries < AttestPolicy.inCallTries else { return .stop("pending") }
                let wait = AttestPolicy.inCallWaits[min(tries, AttestPolicy.inCallWaits.count) - 1] * draw
                let left = AttestPolicy.inCallWall - elapsed
                guard left > 0 else { return .stop("pending") }
                return .again(after: wait, maxWait: left)
            }
        }
    }

    /// The vectors' `in_call`: the start of each try and how the call ends, with the network back at `pathBackAt` when
    /// it was down (that wait takes the timer's place, bounded by the wall).
    static func inCall(_ failures: [AttestClass?], draws: [Double], pathBackAt: Double? = nil, elapsed: [Double]? = nil)
        -> (starts: [Double], outcome: String) {
        var plan = InCall()
        var t = 0.0, starts: [Double] = [], d = 0
        for (i, cls) in failures.enumerated() {
            starts.append((t * 1000).rounded() / 1000)
            t += elapsed?[i] ?? 0
            guard let cls else { return (starts, "attested") }
            let draw = cls == .transient || cls == .transientApple ? (d < draws.count ? draws[d] : 1) : 1
            switch plan.after(cls, elapsed: t, draw: draw) {
            case .now: continue
            case .stop(let outcome): return (starts, outcome)
            case .again(let after, let maxWait):
                d += 1
                var wait = after
                if let back = pathBackAt, back > t { wait = back - t }
                guard wait <= maxWait else { return (starts, "pending") }
                t += wait
            }
        }
        return (starts, "pending")
    }

    /// 40.3 (`named` in the vectors): the unattested path an App Attest service that keeps failing gives, or nil.
    /// `history`: the failures since the last success (seconds, class, Quran Lab answered, App Attest's own failure).
    static func named(_ history: [AttestState.Failure]) -> String? {
        let svc = history.filter { $0.service && $0.cls == .transientApple }
        guard svc.count >= namedMinTries, let first = svc.first, let last = svc.last, last.at - first.at >= namedAfter else { return nil }
        // nothing answered at all: the device is offline, not the service down
        return history.contains { $0.answered } ? "apple_unavailable" : nil
    }

    /// 40.2 item 1 (`plans` in the vectors): what one lease attempt does, by the config's `attest: "required"` and how
    /// the certificate's attestation ended inside the call (`attested`, `pending`, `judged`, `unsupported`): the
    /// certificate the lease is asked with (`attested`, `none`, or nil: no lease asked) and whether the attestation stays
    /// owed. `TokenProvider.certify` and `ProtectedRuntime.certificate` follow it.
    static func plan(required: Bool, inCall: String) -> (certificate: String?, owed: Bool) {
        switch inCall {
        case "attested": return ("attested", false)
        case "pending": return required ? (nil, true) : ("none", true)
        default: return ("none", false)
        }
    }

    /// 40.2 item 10 (`upgrades` in the vectors): one upgrade try of a capped install, `ProtectedRuntime.upgradeLease`'s
    /// rule: a take in progress waits; an attestation that did not end attested changes nothing; the switch to the new key
    /// and the full lease only once the Core accepted it; any other end keeps the capped lease in force and the next key
    /// with its certificate for the next try.
    static func upgradeOutcome(modelOpen: Bool, attestation: String, lease: String?)
        -> (inForce: String, key: String, owed: Bool, nextKept: Bool) {
        if modelOpen || attestation != "attested" { return ("capped", "old", true, false) }
        if lease == "accepted" { return ("full", "new", false, false) }
        return ("capped", "old", true, true)
    }

    /// 40.4 (`renew` in the vectors): from when the SDK asks for a new lease by itself, on the Core's clock.
    static func renewDue(iat: Int64?, exp: Int64, refreshAfter: Int64) -> Int64 {
        guard let iat, exp > iat else { return refreshAfter }
        return min(refreshAfter, iat + (exp - iat) / 2)
    }
}

/// SDK 4.0.5 (40.2 item 5): the attestation owed by this install, kept across launches in `cloud/attest-state.json`.
/// 4.0.2's judged hold stays in `cloud/attest-backoff.json` (`AttestBackoff`).
struct AttestState: Codable, Sendable, Equatable {
    struct Failure: Codable, Sendable, Equatable {
        /// Unix seconds, the device's wall clock.
        var at: Int64
        var cls: AttestClass
        /// A Quran Lab host answered in this try (the challenge, at least).
        var answered: Bool
        /// The failure was App Attest's own (not a request's).
        var service: Bool
    }

    /// An attestation is owed: the lease waits for it (40.2 item 1).
    var owed = false
    /// Transient failures in a row (40.2 item 4's `n`).
    var failures = 0
    /// The next background try, unix seconds of the wall clock; nil: whenever asked.
    var nextTry: Int64?
    /// The App Attest key made for the owed attestation and not yet accepted (its id is not secret: a handle to a key that
    /// never leaves the Secure Enclave), with the attestation object Apple gave for it, its challenge and the install
    /// hash the object binds ("" for an app token's attestation without install keys).
    var keyID: String?
    var object: Data?
    var challenge: String?
    var boundHash: String?
    /// The install key generation the object binds (the next one, not yet current), so a restart finds it again.
    var generation: Int?
    /// The failures since the last success, for 40.3's `apple_unavailable` (at most 32 kept).
    var history: [Failure] = []
    /// The named path in force (40.3), nil when the install can attest.
    var unattested: String?

    /// The try is due at `now` (unix seconds).
    func due(_ now: Int64) -> Bool { nextTry.map { now >= $0 } ?? true }

    /// A next try more than 6 hours ahead (a clock that moved back) is now, as 18.4.7.3's row (40.2 item 5).
    func readBack(now: Int64) -> AttestState {
        var s = self
        if let n = s.nextTry, n > now + 21_600 { s.nextTry = now }
        return s
    }

    /// The object Apple gave can be sent again at `now`: its challenge has at least 30 s left and it binds `installHash`.
    func resendable(now: Int64, installHash: String) -> Bool {
        guard object != nil, let c = challenge, let exp = AnswerCheck.challengeExpiry(c), boundHash == installHash else { return false }
        return exp - now >= 30
    }

    /// A failure of class `cls` at `now`: the row and the next background try (`draw` from `AttestPolicy.draw`).
    mutating func failed(_ cls: AttestClass, at now: Int64, answered: Bool, service: Bool, draw: Double, retryAfter: Int = 0) {
        owed = true
        if [.transient, .transientApple, .slowDown].contains(cls) { failures += 1 }
        history.append(Failure(at: now, cls: cls, answered: answered, service: service))
        if history.count > 32 { history.removeFirst(history.count - 32) }
        let judged = history.reversed().prefix { $0.cls == .judged }.count
        if let w = AttestPolicy.background(cls, failures: max(1, failures), draw: draw, retryAfter: retryAfter, judged: judged) {
            nextTry = now + Int64(w)
        }
        if unattested == nil, let n = AttestPolicy.named(history) { unattested = n }
    }

    /// The server accepted an attestation: nothing is owed.
    mutating func attested() { self = AttestState() }

    /// The App Attest key is gone (`new_key`, judged): the next try makes a new one.
    mutating func forgetKey() {
        keyID = nil
        object = nil
        challenge = nil
        boundHash = nil
        generation = nil
    }
}
