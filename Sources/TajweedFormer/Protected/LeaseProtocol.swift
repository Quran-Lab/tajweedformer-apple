import CryptoKit
import Foundation

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

/// When the SDK asks for a lease by itself (18.4.7, 18.4.7.3 as dd76474): at the first app start or model open after
/// `refresh_after`, and after a failed attempt (a 5xx, a 429, no answer) not before a wait drawn afresh, uniformly, from
/// 600 to 1800 s, so installs that failed together do not come back together. An answer's `Retry-After` is the floor:
/// the wait is the larger of it and the drawn time. The row is kept with the SDK's state across restarts (28.11 item 3)
/// and ends at a lease the Core accepts and at a verified stop. A valid lease never waits for a refresh, and an app's
/// call that cannot go on without a lease asks at once unless its route is held by a `Retry-After` (18.4.7.3 item 4).
/// Tried before (to 4.0.1): 60, 300, 1800, 7200, 14400, 21600 s, a `Retry-After` replaced the step, and a restart forgot
/// the row, so 503 `lease_unavailable` with its `Retry-After: 30` had every install past `refresh_after` ask every 30 s
/// in an outage.
struct LeaseRetry: Sendable, Equatable, Codable {
    var failures = 0
    var notBefore: Int64 = 0

    /// The wait after any failed attempt, seconds (18.4.7.3 item 1).
    static let wait: ClosedRange<Int64> = 600...1800

    /// A failed attempt: the next waits a time drawn from `wait` (`draw` picks it: the platform's random source, a
    /// test's own), or the answer's `Retry-After` when that is longer (read as 1 to 21600 s).
    mutating func failed(now: Int64, retryAfter: Int = 0, draw: (ClosedRange<Int64>) -> Int64 = { Int64.random(in: $0) }) {
        failures += 1
        let drawn = draw(Self.wait)
        let floor: Int64 = (1...21_600).contains(retryAfter) ? Int64(retryAfter) : 0
        notBefore = now + max(drawn, floor)
    }

    /// The row as a start reads it back: a next attempt more than 21600 s ahead (a clock that moved back) is now
    /// (28.11 item 3).
    func readBack(now: Int64) -> LeaseRetry {
        var r = self
        if r.notBefore > now + 21_600 { r.notBefore = now }
        return r
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
