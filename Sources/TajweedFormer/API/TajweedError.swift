import Foundation

/// Everything the SDK throws. One type on every platform, with the same four fields: `code` is a stable string (the
/// same on Android, Apple, the web and C), `message` says what happened, `fix` is one sentence to act on, and `docs`
/// links the code's entry on sdk.quranlab.ai. Compare `code`, never `message`.
///
///     do { session = try await model.listen() } catch {
///         if error.code == "microphone_denied" { showSettingsHint(error.fix) }
///     }
///
/// SDK 4.0.2: `cause` says what failed, in the same tokens as the error report Quran Lab gets for it, so an app can log
/// it, word its message, and send it in a support request.
public struct TajweedError: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError {
    /// One of the 26 codes of the catalogue (`invalid_key`, `needs_connection`, `session_open`, ...).
    public let code: String
    public let message: String
    /// One sentence a developer can act on.
    public let fix: String
    /// `https://sdk.quranlab.ai/docs/errors#<code>`.
    public let docs: String
    /// What failed (SDK 4.0.2): where, why, and what answered, as tokens. Nil for the codes that only say the app used
    /// the API wrongly (`invalid_argument`, `client_exists`, `session_open`, `session_closed`, `cancelled`). It is set
    /// whether or not error reports are on, and it takes part in the error's equality.
    public let cause: Cause?

    public var description: String { "\(code): \(message) \(fix)" }
    public var errorDescription: String? { message }
    public var recoverySuggestion: String? { fix }

    /// What failed, as tokens: never a message, a path, an address, a host, a key or an identifier. A value the SDK
    /// cannot give as a token is left out.
    public struct Cause: Sendable, Hashable {
        /// Where the cause is: `config`, `register`, `attest`, `lease`, `manifest`, `download`, `verify`, `storage`,
        /// `runtime`, `model_open`, `accelerator`, `audio`, `session`, `sharing` or `events`.
        public let stage: String
        /// Why, at that stage (`network`, `timeout`, `http`, `rate_limited`, `refused`, `quota`, `memory`, ...;
        /// `other` when none fits).
        public let reason: String
        /// The HTTP status of the answer that failed, when there was one.
        public let httpStatus: Int?
        /// The system error's domain or class (`NSURLErrorDomain`, `NSCocoaErrorDomain`), when there was one.
        public let errorName: String?
        /// Its code (`-1009`), the server's error (`model_limit`, `app_blocked`) or a Core status (`nomem`).
        public let errorCode: String?
        /// On `needs_connection` only, what the SDK needs Quran Lab for: `model` (the model files the call needs are
        /// not on the device yet: connect to download them) or `lease` (the model is on the device and needs Quran
        /// Lab's answer to open).
        public let needs: String?
    }
}

/// The 26 codes of the catalogue (errors.json, shared by the four SDKs), in its order.
enum ErrorCode: String, CaseIterable, Sendable {
    case invalidArgument = "invalid_argument"
    case invalidKey = "invalid_key"
    case sdkTooOld = "sdk_too_old"
    case serverRejected = "server_rejected"
    case clientExists = "client_exists"
    case modelUnavailable = "model_unavailable"
    case needsConnection = "needs_connection"
    case networkNotPermitted = "network_not_permitted"
    case downloadFailed = "download_failed"
    case storageFull = "storage_full"
    case storageFailed = "storage_failed"
    case modelMissing = "model_missing"
    case modelInvalid = "model_invalid"
    case signatureInvalid = "signature_invalid"
    case checksumMismatch = "checksum_mismatch"
    case modelIncompatible = "model_incompatible"
    case runtimeUnsupported = "runtime_unsupported"
    case referenceMissing = "reference_missing"
    case sessionOpen = "session_open"
    case sessionClosed = "session_closed"
    case cancelled
    case engineFailed = "engine_failed"
    case microphoneDenied = "microphone_denied"
    case microphoneUnavailable = "microphone_unavailable"
    case interrupted
    case sharingUnavailable = "sharing_unavailable"
}

/// The error catalogue as shipped in the package (Resources/Errors/errors.json, a byte copy of the contract's file;
/// a test fails when the copy differs).
struct ErrorCatalogue: Sendable {
    struct Entry: Sendable {
        let message: String
        let fix: String
        /// For a code whose cause the server names (`server_rejected`): the message and the fix of each of the
        /// server's codes the catalogue knows (`developer_not_approved`, `app_not_allowed`, ...).
        var reasons: [String: Texts] = [:]
    }

    /// What an error says: what happened, and one sentence to act on.
    struct Texts: Sendable, Hashable {
        let message: String
        let fix: String
    }

    let docsBase: String
    let entries: [String: Entry]
    /// The codes in the file's order.
    let codes: [String]

    static let shared = load()

    /// The code of the last error the SDK raised in this process (`diagnose().lastError`).
    static let lastRaised = Locked<String?>(nil)

    /// The embedded file.
    static var resource: URL? {
        Bundle.module.url(forResource: "Errors", withExtension: nil)?.appendingPathComponent("errors.json")
    }

    static func load() -> ErrorCatalogue {
        guard let url = resource, let data = try? Data(contentsOf: url), let c = parse(data) else {
            return ErrorCatalogue(docsBase: "https://sdk.quranlab.ai/docs/errors#", entries: [:], codes: [])
        }
        return c
    }

    /// A catalogue file (errors.json): per code its message and fix, and for a code with `reasons` those of each
    /// reason. Nil when the data is not a catalogue.
    static func parse(_ data: Data) -> ErrorCatalogue? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let list = o["errors"] as? [[String: Any]] else { return nil }
        var entries: [String: Entry] = [:]
        var codes: [String] = []
        for e in list {
            guard let code = e["code"] as? String, let message = e["message"] as? String, let fix = e["fix"] as? String else { continue }
            var entry = Entry(message: message, fix: fix)
            for (reason, r) in (e["reasons"] as? [String: [String: Any]]) ?? [:] {
                guard let m = r["message"] as? String, let f = r["fix"] as? String else { continue }
                entry.reasons[reason] = Texts(message: m, fix: f)
            }
            entries[code] = entry
            codes.append(code)
        }
        return ErrorCatalogue(docsBase: (o["docs_base"] as? String) ?? "https://sdk.quranlab.ai/docs/errors#", entries: entries, codes: codes)
    }

    /// The message and the fix of `code`: those of `reason` (the server's code of a refusal) when the catalogue's
    /// entry has that reason, else the entry's own. Nil for a code the catalogue does not have. The one place a
    /// reason is looked up.
    func texts(_ code: String, reason: String? = nil) -> Texts? {
        guard let e = entries[code] else { return nil }
        if let reason, let r = e.reasons[reason] { return r }
        return Texts(message: e.message, fix: e.fix)
    }

    /// The text with every `{name}` filled from `values`; a placeholder without a value is left out with the
    /// punctuation that led to it.
    static func fill(_ text: String, _ values: [String: String]) -> String {
        var out = text
        for (k, v) in values { out = out.replacingOccurrences(of: "{\(k)}", with: v) }
        while let open = out.range(of: "{"), let close = out.range(of: "}", range: open.upperBound..<out.endIndex) {
            out.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return out.replacingOccurrences(of: ": .", with: ".").replacingOccurrences(of: "  ", with: " ")
    }
}

extension TajweedError {
    /// The catalogue's entry for `code`, its placeholders filled (`detail`, `version`, `sdk`, `needed`, `available`,
    /// `file`). With `reason` (the server's code of a refusal) the message and the fix are that reason's, when the
    /// catalogue has it; the error's `code` stays the same.
    /// SDK 4.0: this and `init(from:)` are where every error the app gets is made, so every one is
    /// reported here, once, with the stage of its CAUSE (`cause`; without one, the code's own, `ErrorCause.of(code:)`).
    /// The codes of the app's own misuse make no report (`ErrorRules.notReported`).
    /// SDK 4.0.2 (24.13): the error carries the same cause as its report (`Cause.made`); `onDevice`: what of the files
    /// the call needs is on the device, which says what a `needs_connection` needs (nil: by the cause's stage).
    init(_ code: ErrorCode, _ values: [String: String] = [:], reason: String? = nil, catalogue c: ErrorCatalogue = .shared,
         cause: ErrorCause? = nil, onDevice: ErrorRules.OnDevice? = nil) {
        let made = cause ?? ErrorCause.of(code: code)
        self.init(made: code, values, reason: reason, catalogue: c, cause: Cause.made(made, code: code.rawValue, onDevice: onDevice))
        ErrorReporter.raised(code.rawValue, cause: made)
    }

    /// The error, made and not reported: `init(from:)` reports it once, with the cause of the failure.
    private init(made code: ErrorCode, _ values: [String: String] = [:], reason: String? = nil, catalogue c: ErrorCatalogue = .shared,
                 cause: Cause?) {
        let e = c.texts(code.rawValue, reason: reason)
        var v = values
        if v["sdk"] == nil { v["sdk"] = SDKInfo.version }
        // where the SDK runs, said the same wherever an error names it
        if v["minimum"] == nil { v["minimum"] = SDKInfo.minimum }
        // one line, no path beyond a file name, bounded
        if let d = v["detail"] { v["detail"] = String(d.replacingOccurrences(of: "\n", with: " ").prefix(300)) }
        self.init(code: code.rawValue, message: ErrorCatalogue.fill(e?.message ?? code.rawValue, v),
                  fix: ErrorCatalogue.fill(e?.fix ?? "", v), docs: c.docsBase + code.rawValue, cause: cause)
        ErrorCatalogue.lastRaised.withLock { $0 = code.rawValue }
    }

    /// `invalid_argument` with what was wrong.
    static func argument(_ detail: String) -> TajweedError { TajweedError(.invalidArgument, ["detail": detail]) }

    /// The catalogue code of an internal failure. Every failure the SDK raises maps to one of the 26 codes. Reported
    /// once (24.1) with `cause`, else the failure's own at `stage` (where the call was: `model_open`, `session`, ...).
    /// SDK 4.0.2 (24.13): the error carries that same cause; `onDevice` as for `init(_:)`.
    init(from e: RecognizerError, cause: ErrorCause? = nil, stage: String? = nil, onDevice: ErrorRules.OnDevice? = nil) {
        let (code, values, reason) = Self.mapped(e)
        let made = cause ?? ErrorCause.of(e, stage: stage)
        self.init(made: code, values, reason: reason, cause: Cause.made(made, code: code.rawValue, onDevice: onDevice))
        ErrorReporter.raised(code.rawValue, cause: made)
    }

    /// The code of an internal failure, the values of its message and the reason that picks a refusal's own texts.
    static func mapped(_ e: RecognizerError) -> (ErrorCode, [String: String], String?) {
        switch e {
        case .modelMissing(let why): return (.modelMissing, ["detail": why], nil)
        case .checksumMismatch(let file): return (.checksumMismatch, ["file": file], nil)
        case .signatureInvalid: return (.signatureInvalid, [:], nil)
        case .manifestInvalid(let why): return (.modelInvalid, ["detail": why], nil)
        case .modelIncompatible(let why): return (.modelIncompatible, ["detail": why], nil)
        case .unsupportedAudioFormat(let why): return (.invalidArgument, ["detail": "audio format: \(why)"], nil)
        case .microphoneUnavailable(let why):
            return (why.hasPrefix(Self.deniedMark) ? .microphoneDenied : .microphoneUnavailable, ["detail": why], nil)
        case .neuralEngineUnavailable(let why): return (.engineFailed, ["detail": "Neural Engine: \(why)"], nil)
        case .engineFailed(let code, let message): return (.engineFailed, ["detail": "\(message) (\(code))"], nil)
        case .sessionActive: return (.sessionOpen, [:], nil)
        case .sessionClosed: return (.sessionClosed, [:], nil)
        case .cancelled: return (.cancelled, [:], nil)
        case .serviceUnavailable: return (.sharingUnavailable, [:], nil)
        // no valid lease on the device and none could be asked for; any other: the download
        case .offline(let why): return (why.hasPrefix("needs_connection") ? .needsConnection : .downloadFailed, ["detail": why], nil)
        case .serverRejected(let status, let code, let message, let reason):
            // a reason that names the page's origin names the app id here (an app has no origin)
            let app = QuranLab.cloud?.app.bundleID ?? Bundle.main.bundleIdentifier ?? "this app"
            if let reason, ModelGate.keyReasons.contains(reason) {
                // a key Quran Lab revoked or never issued, whatever the answer's `error` (also a token whose key was
                // revoked after it was issued, and the CDN's 401 to a model request)
                return (.invalidKey, [:], nil)
            } else if let named = Self.knownReason(reason) {
                // the answer's `reason` is read first: the API answers an origin, key-type or allow-list refusal as a
                // bad key (401 `invalid_key`) and names the check that refused there
                return (.serverRejected, ["detail": named, "origin": app], named)
            } else if code == "invalid_key" || (status == 401 && code == Self.cdnBareRefusal) {
                // a key the server does not know; the CDN's bare 401 says the same of a model request
                return (.invalidKey, [:], nil)
            } else if HTTPClient.redirects.contains(status) {
                // a model file's request was answered with a redirect, which is never followed: the download failed
                return (.downloadFailed, ["detail": "the download server answered with a redirect, which is never followed"], nil)
            } else if status == 429 && code == "model_limit" {
                // a model request over Quran Lab's daily limit: the download stopped, try later; never a refusal
                return (.downloadFailed, ["detail": "Quran Lab's daily limit for model downloads is reached; try again later"], nil)
            } else if code == "lease_integrity_failed" {
                // ERRORS_40 24.3 (69326fb): the developer's message names the check the server named (the reason of
                // the refusal, `verdict:boot`); the app's code stays server_rejected
                return (.serverRejected, ["detail": reason.map { "\(code) (\($0))" } ?? code, "origin": app], code)
            } else if status == 401 && code == "invalid_token" {
                // the token was renewed once and the repeat was refused too: the download failed, as any download does
                return (.downloadFailed, ["detail": "Quran Lab did not accept this install's token"], nil)
            } else if code == "sdk_too_old" {
                return (.sdkTooOld, ["version": Self.version(in: message) ?? "a newer version"], nil)
            } else {
                // the answer's `error` picks its own message and fix when the catalogue has them; any other refusal
                // names that code
                return (.serverRejected, ["detail": code, "origin": app], code)
            }
        case .insufficientStorage(let needed, let available):
            return (.storageFull, ["needed": String(needed), "available": String(available)], nil)
        case .updateDeferred(let why): return (.downloadFailed, ["detail": why], nil)
        case .storageFailed(let why): return (.storageFailed, ["detail": why], nil)
        case .contributionUnavailable: return (.sharingUnavailable, [:], nil)
        case .invalidArgument(let why): return (.invalidArgument, ["detail": why], nil)
        }
    }

    /// The `error` of the CDN's 401 to a model request without a key it knows.
    static let cdnBareRefusal = "missing or invalid x-qlab-key"

    /// The entry of `server_rejected`'s reasons that an answer's `reason` names; nil when the answer has none, or
    /// one the catalogue does not know.
    static func knownReason(_ reason: String?, catalogue c: ErrorCatalogue = .shared) -> String? {
        guard let reason, c.entries[ErrorCode.serverRejected.rawValue]?.reasons[reason] != nil else { return nil }
        return reason
    }

    /// The code a refusal is raised with: `server_rejected` when the answer's `reason` names an entry of the
    /// catalogue, else by the answer's `error` (`invalid_key` and `sdk_too_old` keep their own codes).
    static func refusalCode(code: String, reason: String?) -> ErrorCode {
        if let reason, ModelGate.keyReasons.contains(reason) { return .invalidKey }
        if knownReason(reason) != nil { return .serverRejected }
        if code == "invalid_key" || code == cdnBareRefusal { return .invalidKey }
        if code == "sdk_too_old" { return .sdkTooOld }
        return .serverRejected
    }

    /// How `microphoneUnavailable` says that the permission was refused (the rest is `microphone_unavailable`).
    static let deniedMark = "access to the microphone was denied"

    /// The version a refusal names: the `min_sdk` of the server's answer (kept in the message as `min_sdk x.y.z`),
    /// else the first `x.y.z` in the message.
    static func version(in text: String) -> String? {
        let pattern = #"[0-9]+\.[0-9]+\.[0-9]+"#
        if let m = text.range(of: "min_sdk " + pattern, options: .regularExpression) { return String(text[m].dropFirst(8)) }
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[r])
    }
}
