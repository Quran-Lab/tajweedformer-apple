import Foundation
import QuranLabCore

/// What a failure was, as an error report names it: the
/// stage where the CAUSE is (not the call that failed), a reason token, the HTTP status of the answer that failed, and
/// the platform error's class and code. Never a message, a path, a URL or an identifier: every field is a token, a
/// small number or absent.
struct ErrorCause: Sendable, Equatable {
    var stage: String
    var reason: String
    var httpStatus: Int? = nil
    /// An `NSError` domain or a Swift error type.
    var errorName: String? = nil
    /// An `NSError` code, the server's `error` of a 4xx, a Core status.
    var errorCode: String? = nil
    /// The attempts the SDK made inside the failing call beyond the first.
    var retries: Int? = nil
    /// Part of the build was on the device when it failed (24.4's `partial`). Never sent.
    var partial = false
    /// SDK 4.0.1 (24.2, 28.7): the role of the request the cause is (`api`, `models`), on the stages of a request to a
    /// host of 28.1; never a host name.
    var hostRole: String? = nil
    /// SDK 4.0.1: that request was asked of more than one host (a failover happened in it).
    var fallback: Bool? = nil

    /// What `HTTPClient.send` throws for a request that got no answer: the system's message, then the error's
    /// domain and code in brackets (` [NSURLErrorDomain -1009]`), which the report reads back. The message is never
    /// sent.
    static func noAnswer(_ error: any Error) -> String {
        let e = error as NSError
        return "\(e.localizedDescription) [\(e.domain) \(e.code)]"
    }

    /// The domain and code `noAnswer` put at the end of a failure's text.
    static func marker(_ why: String) -> (name: String, code: String)? {
        guard let r = why.range(of: #"\[[A-Za-z][A-Za-z0-9_.:$-]{0,47} -?[0-9]{1,20}\]$"#, options: .regularExpression) else { return nil }
        let parts = why[r].dropFirst().dropLast().split(separator: " ")
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// The status after `prefix` in a failure's text ("HTTP 503"), when it is one (100 to 599).
    static func status(after prefix: String, in why: String) -> Int? {
        guard let r = why.range(of: prefix) else { return nil }
        let digits = why[r.upperBound...].prefix { $0.isASCII && $0.isNumber }
        guard digits.count == 3, let n = Int(digits), (100...599).contains(n) else { return nil }
        return n
    }

    /// A failed request as the SDK's network code words it (`CloudError.offline`, `RecognizerError.offline`): a
    /// redirect, a 5xx (or a 429 a route words so), no answer at all (`noAnswer`'s marker; a timeout of the system is
    /// `timeout`), a lease the Core does not have yet, an answer that is not the file.
    static func answer(_ why: String, stage: String) -> ErrorCause {
        if let s = status(after: "redirect (HTTP ", in: why) { return ErrorCause(stage: stage, reason: "redirect", httpStatus: s) }
        if let s = status(after: "HTTP ", in: why) {
            return ErrorCause(stage: stage, reason: s == 429 ? "rate_limited" : "http", httpStatus: s)
        }
        if let m = marker(why) {
            // a host that sent no byte before an answer within its limit (28.3 item 6) gave no answer: `network` (24.3:
            // a timeout before any answer is `network`)
            let timeout = m.name == NSURLErrorDomain && m.code == String(NSURLErrorTimedOut) && !why.hasPrefix(HTTPClient.silentHost)
            return ErrorCause(stage: stage, reason: timeout ? "timeout" : "network", errorName: m.name, errorCode: m.code)
        }
        // no valid lease on the device (CoreFailure, ProtectedRuntime): its end passed, or none was ever held
        if why.hasPrefix("needs_connection") {
            return ErrorCause(stage: stage, reason: why.contains("lease has expired") ? "expired" : "network")
        }
        // the Core refused the lease it holds (CoreFailure, `QLC_E_LEASE`); a stop on the lease route that is not signed
        // (24.4 rule 3: a refusal, never a stop)
        if why.contains("refused by the Core") { return ErrorCause(stage: stage, reason: "invalid") }
        if why.contains("unsigned stop") { return ErrorCause(stage: stage, reason: "refused") }
        if why.contains("unexpected body") || why.contains("short range") { return ErrorCause(stage: stage, reason: "invalid_answer") }
        return ErrorCause(stage: stage, reason: "other")
    }

    /// An answer whose status is a failure (24.3): 429 `rate_limited`; a 401 or 403 that names why `refused`, the
    /// report's `error_code` its `reason` (the check that refused, 15.3) or else its `error`; a 2xx that is not what was
    /// asked `invalid_answer`; any other `http`.
    static func refusal(status: Int, code: String, reason: String?, stage: String) -> ErrorCause {
        let named: String? = code.hasPrefix("http_") ? nil : code
        let known: Int? = (100...599).contains(status) ? status : nil
        if status == 0 || (200..<300).contains(status) || code == "invalid_response" {
            return ErrorCause(stage: stage, reason: "invalid_answer", httpStatus: known)
        }
        if status == 429 { return ErrorCause(stage: stage, reason: "rate_limited", httpStatus: 429, errorCode: named) }
        // a 403 lease_integrity_failed (18.4.10, at the attest or the lease): integrity_failed, its error_code the
        // check the answer names (ERRORS_40 24.3, 69326fb; `reason` carries it, HTTPClient.reason)
        if status == 403, named == "lease_integrity_failed" {
            return ErrorCause(stage: stage, reason: "integrity_failed", httpStatus: 403, errorCode: reason ?? "lease_integrity_failed")
        }
        // a 401 `invalid_token` that names no stop reason is the token's own answer, renewed once and repeated once
        // (PLATFORM_CLIENT.md 8; the model-gate vector: "no error of its own"): an answer that failed, never a refusal
        if status == 401, named == "invalid_token", !(reason.map { ModelGate.stopReasons.contains($0) } ?? false) {
            return ErrorCause(stage: stage, reason: "http", httpStatus: 401, errorCode: named)
        }
        if status == 401 || status == 403, named != nil || reason != nil {
            return ErrorCause(stage: stage, reason: "refused", httpStatus: status, errorCode: reason ?? named)
        }
        return ErrorCause(stage: stage, reason: "http", httpStatus: known, errorCode: named)
    }

    /// The `error_code` of a `403 lease_integrity_failed` (ERRORS_40 24.3, contract 69326fb): the answer's `why`, then
    /// `:` and its `check` when it names one (`verdict:boot`, `verdict:digest`, `verdict:recorded`, `downgrade`,
    /// `core`), a token of 24.2; `why` alone when the two would pass 32 characters or `check` is not a token;
    /// `lease_integrity_failed` when the answer names no `why` (or one that is not a token).
    static func integrityCode(why: String?, check: String?) -> String {
        func token(_ s: String) -> Bool { s.range(of: #"^[A-Za-z0-9_.:-]{1,32}$"#, options: .regularExpression) != nil }
        guard let why, token(why) else { return "lease_integrity_failed" }
        if let check, token(check), token(why + ":" + check) { return why + ":" + check }
        return why
    }

    /// What answered, as the detail of a `download_failed` the cause makes (24.4 rule 2: "the server answered 503").
    var detail: String {
        if let s = httpStatus {
            return reason == "redirect" ? "the server answered with a redirect (HTTP \(s))" : "the server answered \(s)"
        }
        switch reason {
        case "timeout": return "the server did not answer in time"
        case "signature": return "Quran Lab's answer did not verify"
        case "expired": return "Quran Lab's config has expired"
        case "parse", "invalid_answer": return "Quran Lab's answer could not be read"
        case "invalid": return "the lease on this device was refused; a new one is needed"
        default: return "the request failed (\(stage), \(reason))"
        }
    }

    /// A failure of one of the SDK's requests to Quran Lab, at `stage`; with the role of the request and whether it was
    /// asked of more than one host, when this task made it (4.0.1, `traced`).
    static func of(_ e: CloudError, stage: String) -> ErrorCause { plain(e, stage: stage).traced() }

    private static func plain(_ e: CloudError, stage: String) -> ErrorCause {
        switch e {
        case .offline(let why): return answer(why, stage: stage)
        case .rejected(let s, let code, _, let reason): return refusal(status: s, code: code, reason: reason, stage: stage)
        case .invalid(let why):
            guard stage == "config" else { return ErrorCause(stage: stage, reason: "invalid_answer") }
            if why.contains("sign") { return ErrorCause(stage: stage, reason: "signature") }
            return ErrorCause(stage: stage, reason: why.contains("expired") ? "expired" : "parse")
        case .noKey: return ErrorCause(stage: stage, reason: "other")
        // a model file the device could not keep; an answer that said success and was not the file (SPEC 16.1)
        case .storage: return ErrorCause(stage: stage, reason: "storage")
        case .badAnswer: return ErrorCause(stage: stage, reason: "invalid_answer")
        }
    }
}

extension ErrorCause {
    /// A failure as the SDK's own error says it, at `stage` when the caller knows where the call was (`manifest`,
    /// `download` and `lease` while a build is fetched; `model_open`, `accelerator`, `session`, `audio`, `sharing`).
    static func of(_ e: RecognizerError, stage: String? = nil) -> ErrorCause { plain(e, stage: stage).traced() }

    private static func plain(_ e: RecognizerError, stage: String?) -> ErrorCause {
        let fetching = stage == "manifest" || stage == "download" || stage == "lease"
        switch e {
        case .modelMissing(let why):
            // the CDN's 404 to a manifest (CDNClient.manifest words it so)
            if fetching, why.hasSuffix("on the CDN") { return ErrorCause(stage: "manifest", reason: "http", httpStatus: 404) }
            return ErrorCause(stage: fetching ? (stage ?? "download") : "verify", reason: "missing")
        case .checksumMismatch: return ErrorCause(stage: fetching ? "download" : "verify", reason: "hash")
        case .signatureInvalid: return ErrorCause(stage: fetching ? "manifest" : "verify", reason: "signature")
        case .manifestInvalid: return fetching ? ErrorCause(stage: "manifest", reason: "parse") : ErrorCause(stage: "verify", reason: "invalid")
        case .modelIncompatible: return ErrorCause(stage: fetching ? "manifest" : (stage ?? "model_open"), reason: "incompatible")
        case .unsupportedAudioFormat: return ErrorCause(stage: "audio", reason: "sample_rate")
        case .microphoneUnavailable(let why):
            return ErrorCause(stage: "audio", reason: why.hasPrefix(TajweedError.deniedMark) ? "permission_denied" : "unavailable")
        case .neuralEngineUnavailable: return ErrorCause(stage: "accelerator", reason: "unavailable")
        case .engineFailed(let code, _):
            // the Core's status by its name (`busy`, `nomem`, `engine`, `arg`), so a report tells them apart (Gate C,
            // 2026-11-20); out of memory is `memory` where the stage has it (24.3: model_open, session)
            let at = stage ?? "session"
            let memory = code == QLC_E_NOMEM && (at == "model_open" || at == "session")
            return ErrorCause(stage: at, reason: at == "accelerator" ? "load" : (memory ? "memory" : "engine"),
                              errorCode: CoreFailure.statusName(code) ?? String(code))
        case .sessionActive, .sessionClosed, .cancelled, .invalidArgument: return ErrorCause(stage: stage ?? "session", reason: "other")
        case .serviceUnavailable, .contributionUnavailable: return ErrorCause(stage: stage ?? "sharing", reason: "other")
        // a lease the device does not hold is the lease's failure, wherever the call was (24.4 rule 1)
        case .offline(let why): return answer(why, stage: why.hasPrefix("needs_connection") ? "lease" : (stage ?? "download"))
        case .serverRejected(let s, let code, _, let reason): return refusal(status: s, code: code, reason: reason, stage: stage ?? "download")
        case .insufficientStorage: return ErrorCause(stage: fetching ? "download" : "storage", reason: "quota")
        case .updateDeferred(let why):
            // the download's answer said success and was not the file, or brought no byte (SPEC 16.1, the installer's
            // words): invalid_answer, as the CloudError it came from
            let answer = why.contains("was not the file") || why.contains("brought no new byte")
            return ErrorCause(stage: stage ?? "download", reason: answer ? "invalid_answer" : "other")
        case .storageFailed(let why):
            if stage == "download" { return ErrorCause(stage: "download", reason: "storage") }
            return ErrorCause(stage: "storage", reason: why.contains("read") ? "read" : "write")
        }
    }

    /// The cause of an error made from its code alone (no failure of the SDK's own in hand): the microphone, the
    /// runtime, a store, the model on the device.
    static func of(code: ErrorCode) -> ErrorCause {
        switch code {
        case .microphoneDenied: return ErrorCause(stage: "audio", reason: "permission_denied")
        case .microphoneUnavailable: return ErrorCause(stage: "audio", reason: "unavailable")
        case .interrupted: return ErrorCause(stage: "audio", reason: "interrupted")
        case .runtimeUnsupported: return ErrorCause(stage: "runtime", reason: "native_library")
        case .engineFailed: return ErrorCause(stage: "session", reason: "engine")
        case .storageFull: return ErrorCause(stage: "storage", reason: "quota")
        case .storageFailed: return ErrorCause(stage: "storage", reason: "write")
        case .checksumMismatch: return ErrorCause(stage: "verify", reason: "hash")
        case .signatureInvalid: return ErrorCause(stage: "manifest", reason: "signature")
        case .modelMissing, .referenceMissing: return ErrorCause(stage: "verify", reason: "missing")
        case .modelInvalid: return ErrorCause(stage: "verify", reason: "invalid")
        case .modelIncompatible: return ErrorCause(stage: "verify", reason: "incompatible")
        case .modelUnavailable: return ErrorCause(stage: "config", reason: "unavailable")
        case .invalidKey, .serverRejected, .sdkTooOld: return ErrorCause(stage: "config", reason: "refused")
        case .needsConnection: return ErrorCause(stage: "download", reason: "network")
        case .networkNotPermitted, .downloadFailed: return ErrorCause(stage: "download", reason: "other")
        case .sharingUnavailable: return ErrorCause(stage: "sharing", reason: "other")
        case .invalidArgument, .clientExists, .sessionOpen, .sessionClosed, .cancelled:
            return ErrorCause(stage: "session", reason: "other")
        }
    }
}

/// A failure and its cause, kept by the code that knew more than the error says (the lease route: a stop the Core
/// verified, a refusal of the Core, a lease past its end).
struct CausedFailure: Sendable {
    let error: RecognizerError
    let cause: ErrorCause
}

extension ErrorCause {
    /// The cause of a failure of the lease route: the one `ProtectedRuntime` kept for that very failure, else the
    /// failure's own at stage `lease`.
    static func lease(_ e: RecognizerError, runtime: ProtectedRuntime?) -> ErrorCause {
        if let kept = runtime?.lastFailure.withLock({ $0 }), kept.error == e { return kept.cause }
        return ErrorCause.of(e, stage: "lease")
    }
}
