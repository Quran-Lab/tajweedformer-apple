import CryptoKit
import Foundation

/// The rules of contract section 24 (`sdk_4.0.0/ERRORS_40.md`), ported from its reference `tools/errors40.py` and
/// replayed on `vectors/errors_40.json` (`ErrorReportVectorTests`): the code the app gets (24.4), whether a failure
/// makes a report (24.1), the signature (24.5) and the telemetry name of a failed download (24.8).
enum ErrorRules {
    /// What of the build a call needs is on the device (24.4): nothing, part of a download, a build that opens.
    enum OnDevice: String, Sendable {
        /// `none` in the vectors (named so it is never read as an Optional's `.none`).
        case nothing = "none"
        case partial, complete
    }

    /// The codes that only say the app used the API wrongly: never reported (24.1 item 1).
    static let notReported: Set<String> = ["invalid_argument", "client_exists", "session_open", "session_closed", "cancelled"]
    /// The `reason`s of a refusal that name the key itself (15.3): `invalid_key`.
    static let keyReasons: Set<String> = ["key_revoked", "key_unknown"]

    /// The code of the `TajweedError` the app gets for a failure at `stage` with `reason`, or `none` when the call
    /// goes on (a silent failure). `errorCode`: the server's `error` (or `reason`) of a refusal. errors40.py `code_for`.
    static func code(stage: String, reason: String, status: Int? = nil, onDevice: OnDevice = .nothing, errorCode: String? = nil) -> String {
        // 4.0.1 (28.7): `failover`, the request was answered on another host: silent, as errors40.py
        if ["sharing", "events"].contains(stage) || reason == "failover" { return "none" }
        // rule 3a: the token gates the config; with a build on the device, or an attestation the platform cannot give
        // (the SDK goes on unattested), the call goes on
        if stage == "attest", onDevice == .complete || attestationReasons.contains(reason) { return "none" }
        switch stage {
        case "storage":
            return ["quota": "storage_full", "read": "storage_failed", "write": "storage_failed", "corrupt": "storage_failed"][reason] ?? "none"
        case "verify":
            return ["hash": "checksum_mismatch", "signature": "signature_invalid", "missing": "model_missing", "invalid": "model_invalid",
                    "incompatible": "model_incompatible"][reason] ?? "none"
        case "runtime":
            if ["wasm_unsupported", "simd", "threads", "webcrypto", "ed25519", "native_library"].contains(reason) { return "runtime_unsupported" }
            return reason == "worker" ? "none" : "engine_failed"
        case "model_open":
            return ["incompatible": "model_incompatible", "invalid": "model_invalid", "decrypt": "model_invalid",
                    "missing": "model_missing"][reason] ?? "engine_failed"
        case "accelerator": return reason == "unavailable" ? "runtime_unsupported" : "engine_failed"
        case "audio": return ["permission_denied": "microphone_denied", "interrupted": "interrupted"][reason] ?? "microphone_unavailable"
        case "session": return "engine_failed"
        default: break
        }
        // the network stages: config, register, attest (rule 3a), lease, manifest, download
        if stage == "lease" {
            // rule 3: only a stop the Core verified is a stop; rule 1: no valid lease and no answer is needs_connection,
            // whatever is on the device (a protected build does not open without a lease)
            // 18.4.7.1: an open in the lease's grace goes on, a silent report
            if reason == "grace" { return "none" }
            if reason == "stopped" { return errorCode.map { keyReasons.contains($0) } == true ? "invalid_key" : "server_rejected" }
            if reason == "refused" { return errorCode == "sdk_too_old" ? "sdk_too_old" : "server_rejected" }
            if reason == "network" || reason == "expired" { return "needs_connection" }
            if attestationReasons.contains(reason) || reason == "invalid" { return "server_rejected" }
            return "download_failed"
        }
        if reason == "refused" {
            if let e = errorCode, keyReasons.contains(e) || e == "invalid_key" || e == "unauthorized" { return "invalid_key" }
            return errorCode == "sdk_too_old" ? "sdk_too_old" : "server_rejected"
        }
        if onDevice == .complete, ["config", "register", "attest", "manifest"].contains(stage) { return "none" }
        if stage == "register" { return "none" }
        if reason == "network" { return onDevice == .nothing ? "needs_connection" : "download_failed" }
        if stage == "config", reason == "unavailable" { return "model_unavailable" }
        if stage == "manifest", let c = ["signature": "signature_invalid", "parse": "model_invalid", "incompatible": "model_incompatible"][reason] {
            return c
        }
        if stage == "download" {
            if reason == "hash" { return "checksum_mismatch" }
            if reason == "signature" { return "signature_invalid" }
            if reason == "quota" { return "storage_full" }
            if reason == "storage" { return "storage_failed" }
        }
        return "download_failed"
    }

    /// The reasons of an attestation the platform cannot give (24.3 `attest`, `lease`).
    static let attestationReasons: Set<String> = ["unsupported", "attestation_failed", "integrity_failed", "turnstile"]

    /// The code of a model call (`client.model()`, `prefetch`, the lease) that failed for `cause`: `code` of the
    /// cause (a token that failed is the config's gate, rule 3a; a registration that failed never fails a call).
    static func modelCallCode(_ cause: ErrorCause, onDevice: OnDevice) -> String {
        code(stage: cause.stage, reason: cause.reason, status: cause.httpStatus, onDevice: onDevice, errorCode: cause.errorCode)
    }

    /// 24.1: whether a failure makes a report: never the app's own misuse, never a silent plain network failure.
    static func reported(stage: String, reason: String, code: String) -> Bool {
        if notReported.contains(code) { return false }
        return !(code == "none" && reason == "network")
    }

    /// 24.5: `error\n<stage>\n<reason>\n<code>\n<status or 0>`.
    static func signature(stage: String, reason: String, code: String, status: Int?) -> String {
        "error\n\(stage)\n\(reason)\n\(code)\n\(status ?? 0)"
    }

    /// The first 16 bytes of the signature's SHA-256 in hex, as the server groups.
    static func signatureHex(stage: String, reason: String, code: String, status: Int?) -> String {
        String(Data(SHA256.hash(data: Data(signature(stage: stage, reason: reason, code: code, status: status).utf8))).hex.prefix(32))
    }

    /// 24.8: the `failure_reasons` name of a download that failed with `reason`.
    static func telemetryReason(_ reason: String) -> String {
        switch reason {
        case "network", "timeout": return "network"
        case "http", "rate_limited", "refused", "redirect", "invalid_answer": return "http"
        case "hash": return "hash_mismatch"
        case "signature": return "signature"
        case "storage", "quota": return "storage"
        default: return "other"
        }
    }

    /// The days from UTC day `a` to UTC day `b` (`YYYY-MM-DD`), by the civil calendar; nil when one is not a day.
    static func days(from a: String, to b: String) -> Int? {
        guard let x = ordinal(a), let y = ordinal(b) else { return nil }
        return y - x
    }

    /// Days since 1970-01-01 (Howard Hinnant's days_from_civil).
    static func ordinal(_ day: String) -> Int? {
        let p = day.split(separator: "-")
        guard day.count == 10, p.count == 3, var y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        y -= m <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
