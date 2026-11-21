import CryptoKit
import Foundation

/// The install certificate: base64url of its text, a dot, base64url of the Ed25519 signature by
/// Quran Lab's signing key over the text. Issued by `POST /v1/attest`, carried again (renewed) by every lease answer.
/// The SDK keeps it, sends it back in every lease request, and reads `exp` (attest again when it is over) and `key`
/// (the API key id a signed refusal names).
struct InstallCertificate: Sendable, Equatable, Codable {
    let encoded: String
    let fields: [String: String]

    var app: String { fields["app"] ?? "" }
    var platform: String { fields["platform"] ?? "" }
    var key: String { fields["key"] ?? "" }
    var install: String { fields["install"] ?? "" }
    var sign: String { fields["sign"] ?? "" }
    var att: String { fields["att"] ?? "" }
    var hardware: Bool { fields["hw"] == "1" }
    var issuedAt: Int64 { Int64(fields["iat"] ?? "") ?? 0 }
    var expiresAt: Int64 { Int64(fields["exp"] ?? "") ?? 0 }
    var recheck: Bool { fields["recheck"] == "1" }

    /// The lines of the text, in order (18.4.3).
    static let lines = ["app", "platform", "key", "install", "sign", "att", "hw", "iat", "exp", "recheck", "batch", "digest"]

    /// A certificate whose text has the form of 18.4.3 and whose signature verifies with one of `trustedKeys`; nil
    /// otherwise.
    static func parse(_ encoded: String, trustedKeys: [Data]) -> InstallCertificate? {
        let parts = encoded.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let text = Data(base64URL: String(parts[0])), let sig = Data(base64URL: String(parts[1])), sig.count == 64,
              let s = String(data: text, encoding: .utf8), s.hasPrefix("quranlab-install-cert 1\n"), s.hasSuffix("\n") else { return nil }
        let keys = trustedKeys.compactMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        guard keys.contains(where: { $0.isValidSignature(sig, for: text) }) else { return nil }
        var fields: [String: String] = [:]
        let body = s.dropFirst("quranlab-install-cert 1\n".count).dropLast().split(separator: "\n", omittingEmptySubsequences: false)
        guard body.count == lines.count else { return nil }
        for (name, line) in zip(lines, body) {
            guard line.hasPrefix(name + " ") else { return nil }
            fields[name] = String(line.dropFirst(name.count + 1))
        }
        return InstallCertificate(encoded: encoded, fields: fields)
    }

    /// Whether the certificate is this install key's: its `install` is the key's hash.
    func isFor(installHash: String) -> Bool { install == installHash }
}

/// A lease answer (18.4.5).
struct LeaseAnswer: Sendable, Equatable {
    let lease: Data
    let issuedAt: Int64
    let expiresAt: Int64
    let refreshAfter: Int64
    /// The model folder the build's files are under (`<base>manifest.json`, `<base>layers.zfw.qle`).
    let base: URL?
    let certificate: String?
    /// An optional data piece for the Core (spec fix 12): data, never code.
    let piece: Data?

    static func parse(_ body: Data) -> LeaseAnswer? {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], (o["v"] as? Int) == 1,
              let l = o["lease"] as? String, let lease = Data(base64URL: l), !lease.isEmpty, lease.count <= 4096,
              let iat = (o["iat"] as? NSNumber)?.int64Value, let exp = (o["exp"] as? NSNumber)?.int64Value,
              let ra = (o["refresh_after"] as? NSNumber)?.int64Value else { return nil }
        var base: URL?
        // 28.4 (4.0.1): the base as the answer wrote it is held to printable ASCII without a backslash before it is
        // made a URL (Foundation's URL(string:) percent-encodes a space or a backslash it would otherwise refuse, and
        // the encoded form would pass `ProtectedRuntime.acceptedBase`)
        if let b = o["base"] as? String, b.utf8.allSatisfy({ (0x21...0x7e).contains($0) && $0 != 0x5c }),
           let u = URL(string: b), u.scheme == "https", u.host != nil, b.hasSuffix("/") { base = u }
        let piece = (o["piece"] as? String).flatMap { Data(base64URL: $0) }
        return LeaseAnswer(lease: lease, issuedAt: iat, expiresAt: exp, refreshAfter: ra, base: base,
                           certificate: o["install_cert"] as? String, piece: piece)
    }
}

/// What the SDK does with an answer of `POST /v1/model-key` that is not a lease (the table of 18.4.10).
enum LeaseRefusal: Equatable, Sendable {
    /// A stop of 15.3 (`invalid_key`, `invalid_token` with a reason, `app_blocked`, `developer_not_approved`): the body
    /// goes to the Core, which clears its lease and removes the model's files only when the stop is signed by a
    /// pinned key and names this request. The SDK's own model gate remembers it as for any other route.
    case stop(error: String, reason: String?)
    /// 401 `invalid_token` without a reason: a new token, then the request once more.
    case renewToken
    /// 401 `install_cert_invalid`: attest again (a new install key), then the request once more. Not a stop.
    case reattest(why: String?)
    /// 401 `challenge_invalid`: a new challenge, then the request once more.
    case newChallenge
    /// 400 `invalid_body`: an SDK bug. Reported, never repeated as it is.
    case sdkBug
    /// 403 `sdk_too_old`: the Core release is unknown, revoked or below the floor. Not a stop.
    case sdkTooOld(minSDK: String?)
    /// 403 `lease_attestation_required`, `lease_integrity_failed` and the web's Turnstile answers: no lease, not a stop.
    case refused(code: String, why: String?)
    /// 404 `build_unknown`: refresh the config. Not a stop.
    case buildUnknown
    /// 404 `not_found`: the route is off on this server (`flags.protected_model`).
    case routeOff
    /// 429, 5xx, 503 `not_configured`, anything else: try later with the lease's backoff. Never a refusal.
    case later

    /// The stops of 15.3 that arrive on this route.
    static let stopErrors: Set<String> = ["invalid_key", "invalid_token", "app_blocked", "developer_not_approved"]

    static func classify(status: Int, body: Data) -> LeaseRefusal {
        let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = o?["error"] as? String ?? ""
        let reason = (o?["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let why = o?["why"] as? String
        switch (status, error) {
        case (401, "invalid_token") where reason == nil: return .renewToken
        case (401, _), (403, _):
            if stopErrors.contains(error) { return .stop(error: error, reason: reason) }
            switch error {
            case "install_cert_invalid": return .reattest(why: why)
            case "challenge_invalid": return .newChallenge
            case "sdk_too_old": return .sdkTooOld(minSDK: o?["min_sdk"] as? String)
            case "": return .later
            default: return .refused(code: error, why: why)
            }
        case (400, _): return .sdkBug
        case (404, "build_unknown"): return .buildUnknown
        case (404, _): return .routeOff
        default: return .later
        }
    }

    /// The error a caller gets for it.
    func error(status: Int, body: Data) -> RecognizerError {
        let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = HTTPClient.message(o)
        switch self {
        case .stop(let error, let reason):
            return .serverRejected(status: status, code: error, message: message, reason: reason)
        case .sdkTooOld:
            return .serverRejected(status: 403, code: "sdk_too_old", message: message)
        case .refused(let code, let why):
            // a 403 lease_integrity_failed carries its check as the reason (24.3, 69326fb): the developer's message
            // names it (TajweedError), and the app's code stays server_rejected
            return .serverRejected(status: status, code: code, message: why.map { "\(message) (\($0))" } ?? message,
                                   reason: code == "lease_integrity_failed" ? HTTPClient.reason(o) : nil)
        case .buildUnknown, .routeOff:
            return .serverRejected(status: 404, code: self == .routeOff ? "model_key_off" : "build_unknown", message: message)
        case .renewToken, .reattest, .newChallenge, .later:
            return .offline("the lease could not be renewed now (HTTP \(status))")
        case .sdkBug:
            return .serverRejected(status: 400, code: "invalid_body", message: message)
        }
    }
}

/// When the SDK asks for a lease in the background (18.4.7): at the first app start or model open after
/// `refresh_after`; after a failure 1, 5 and 30 minutes later, then every 2 hours growing to at most 6 hours. A
/// valid lease never waits for a refresh.
struct LeaseRetry: Sendable, Equatable, Codable {
    var failures = 0
    var notBefore: Int64 = 0

    static let steps: [Int64] = [60, 300, 1800, 7200, 14_400, 21_600]

    /// A failed attempt: the next waits the backoff's step, or the answer's `Retry-After` when it named one (503
    /// `lease_unavailable`, contract 1c971ab 18.4.7: read as 1 to 21600 s); the backoff goes on after it.
    mutating func failed(now: Int64, retryAfter: Int = 0) {
        failures += 1
        notBefore = now + ((1...21_600).contains(retryAfter) ? Int64(retryAfter) : Self.steps[min(failures, Self.steps.count) - 1])
    }

    /// `Retry-After` as 18.4.7 reads it: whole seconds, 1 to 21600; anything else (a date, 0, more) is none.
    static func retryAfter(_ header: String?) -> Int {
        guard let h = header?.trimmingCharacters(in: .whitespaces), let n = Int(h), (1...21_600).contains(n) else { return 0 }
        return n
    }

    mutating func succeeded() { self = LeaseRetry() }

    func due(now: Int64) -> Bool { now >= notBefore }
}

/// The `lease` group of the 4.0 analytics (17.8): refreshes that worked, and the ones that failed by cause.
enum LeaseOutcome: String, Sendable, CaseIterable {
    case ok, offline, refused, expired, clock, attestation, other
}
