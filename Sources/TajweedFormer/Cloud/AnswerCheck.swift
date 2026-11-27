import Foundation

/// SDK 4.0.5: every
/// 2xx the SDK does not take names the first check it failed, a token of a closed set. The report says reason
/// `invalid_answer` with the check as its `error_code`, the app's error carries it as `cause.errorCode`, and the hop of
/// the cause chain names it (40.6). A check the SDK adds is added to the contract's set first.
enum AnswerCheck {
    // any JSON route
    static let notJSON = "not_json"
    // POST /v1/model-key, before the Core
    static let leaseV = "schema:v", leaseBytes = "schema:lease", leaseIat = "schema:iat", leaseExp = "schema:exp"
    static let leaseRefresh = "schema:refresh_after", leaseBase = "schema:base", baseHost = "base_host"
    // GET /v1/attest/challenge
    static let challengeForm = "schema:challenge"
    // POST /v1/attest, /v1/attest/assert
    static let token = "schema:token", installCert = "schema:install_cert"
    static let certFormat = "cert_format", certSignature = "cert_signature", certInstall = "cert_install"
    // a model file
    static let fileStatus = "status", noBytes = "no_bytes", contentRange = "content_range", rangeMismatch = "range_mismatch"
    static let shortRange = "short_range", size = "size"

    /// qlcore.h's statuses, by value (this file holds no Core, so it builds on Linux; `AnswerCheckCoreTests` holds them to
    /// the pinned header's constants on the Mac).
    enum Core {
        static let arg = -1, nomem = -2, storage = -3, manifest = -4, needsConnection = -5, lease = -6, file = -7
        static let engine = -8, stopped = -9, keystore = -10, busy = -11
    }

    /// qlcore.h's `QLC_D_LEASE_*` to their checks (40.5, `core_accept`).
    static let leaseDetails: [Int: String] = [
        1: "format_version", 2: "signature", 3: "install_mismatch", 4: "release_mismatch", 5: "build_mismatch", 6: "key_id",
        7: "model_mismatch", 8: "expired_on_arrival", 10: "outer_tag", 11: "inner_tag", 12: "site_mismatch",
        13: "node_cert_format", 14: "node_cert_signature", 15: "node_cert_kid", 16: "node_cert_tier", 17: "node_cert_window",
        18: "node_life", 32: "unwrap",
    ]
    static let statusNames: [Int: String] = [Core.arg: "arg", Core.nomem: "nomem", Core.storage: "storage", Core.keystore: "keystore",
                                             Core.busy: "busy", Core.file: "file", Core.engine: "engine"]

    /// The check a failed `qlc_lease_accept` names, from its status and `qlc_detail`. The Core (core.c `build_key_for`,
    /// c3 to c6) answers a lease whose anchor is at or past its `exp` `QLC_E_NEEDS_CONNECTION` with `QLC_D_LEASE_EXPIRED`,
    /// a node certificate past its window `QLC_E_NEEDS_CONNECTION` with 17, a lease the key store cannot unwrap
    /// `QLC_E_KEYSTORE` with 32, every other refusal of the lease `QLC_E_LEASE` with its detail. 4.0.2 named only the
    /// status (the reports "lease, expired, -5").
    static func coreAccept(status: Int, detail: Int) -> String {
        if [Core.lease, Core.needsConnection, Core.keystore].contains(status), let c = leaseDetails[detail] { return c }
        if status == Core.lease || status == Core.needsConnection { return "lease_detail:\(detail)" }
        if status == Core.manifest { return "manifest" }
        return "core:" + (statusNames[status] ?? String(abs(status)))
    }

    /// The closed set (40.5); `lease_detail:<n>` and `core:<name>` are its two forms with a value.
    static let all: [String] = [
        notJSON, leaseV, leaseBytes, leaseIat, leaseExp, leaseRefresh, leaseBase, baseHost, "format_version", "signature",
        "install_mismatch", "release_mismatch", "build_mismatch", "key_id", "model_mismatch", "expired_on_arrival", "outer_tag",
        "inner_tag", "site_mismatch", "node_cert_format", "node_cert_signature", "node_cert_kid", "node_cert_tier",
        "node_cert_window", "node_life", "unwrap", "lease_detail", "manifest", "core", challengeForm, token, installCert,
        certFormat, certSignature, certInstall, size, rangeMismatch, contentRange, shortRange, noBytes, fileStatus,
    ]

    static func isCheck(_ t: String) -> Bool {
        if all.contains(t) { return true }
        guard let colon = t.firstIndex(of: ":") else { return false }
        return ["lease_detail", "core"].contains(String(t[..<colon]))
    }

    /// The body as JSON, nil when it is not (`not_json`).
    static func json(_ body: Data) -> Any? { try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) }

    /// `GET /v1/attest/challenge`: the challenge in the strict form, or the check it failed.
    static func challenge(_ body: Data) -> (challenge: String?, check: String?) {
        guard let o = json(body) else { return (nil, notJSON) }
        guard let d = o as? [String: Any], let c = d["challenge"] as? String,
              c.range(of: #"^c1\.[0-9]{10}\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{22}$"#, options: .regularExpression) != nil
        else { return (nil, challengeForm) }
        return (c, nil)
    }

    /// The unix time a challenge in the strict form expires (`c1.<exp>.`), nil for another form.
    static func challengeExpiry(_ c: String) -> Int64? {
        let parts = c.split(separator: ".")
        guard parts.count == 4, parts[0] == "c1", parts[1].count == 10 else { return nil }
        return Int64(parts[1])
    }

    /// `POST /v1/attest` (`installKeys`: sent with the install's keys, so the certificate is needed too) and
    /// `POST /v1/attest/assert`: the check the answer failed, nil when it has what the route asks for.
    static func tokenAnswer(_ body: Data, installKeys: Bool) -> String? {
        guard let o = json(body) else { return notJSON }
        guard let d = o as? [String: Any], let t = d["token"] as? String, t.hasPrefix("qlt_") else { return token }
        if installKeys, !(d["install_cert"] is String) { return installCert }
        return nil
    }

    /// A model file's answer that said success and was not the file (16.1), from the words the download code throws it
    /// with (`CloudError.badAnswer`, `RecognizerError.updateDeferred`, the installer's), or nil for words of no check.
    static func file(fromWords why: String) -> String? {
        if why.contains(HTTPWords.notItsRange) || why.contains("for another range or another file size") { return rangeMismatch }
        if why.contains("without a Content-Range") { return contentRange }
        if why.contains("short range") { return shortRange }
        if why.contains("without a byte") || why.contains("brought no new byte") { return noBytes }
        if why.contains("is not a file") { return fileStatus }
        if why.contains("runs past") || why.contains("bytes for a file of") || why.contains("unexpected body") { return size }
        return nil
    }

    /// The check named at the end of a failure's words (`... (schema:token)`), when it is one of the set.
    static func named(in why: String) -> String? {
        guard why.hasSuffix(")"), let open = why.lastIndex(of: "(") else { return nil }
        let t = String(why[why.index(after: open)..<why.index(before: why.endIndex)])
        return isCheck(t) ? t : nil
    }

    /// What the request's accept found (`judging`): the check the answer failed, set by the accept that refused it.
    @TaskLocal static var slot: Locked<String?>?

    /// Called by an accept that refuses an answer: the check it failed, for the request's hop (`HTTPClient.routed`).
    static func failed(_ check: String) { slot?.withLock { $0 = $0 ?? check } }

    /// Runs one accept and returns whether it took the answer and, when it did not, the check it named (nil: none named).
    static func judging(_ accept: () -> Bool) -> (taken: Bool, check: String?) {
        let box = Locked<String?>(nil)
        let taken = $slot.withValue(box) { accept() }
        return (taken, taken ? nil : box.withLock { $0 })
    }
}

/// Words the download code throws an answer that was not the file with, named once so `AnswerCheck.file` reads them.
enum HTTPWords {
    static let notItsRange = "the answer is not the range asked for"
}
