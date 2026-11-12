import CryptoKit
import Foundation

/// The per-app configuration from qlab-api (`GET /v1/config`): which model revision to use (the
/// portal's pin, or the channel's release with a staged rollout), the deny-list and flags. Signed
/// with Ed25519 over the exact body bytes; the SDK refuses one that does not verify or has expired.
struct RemoteConfig: Codable, Sendable, Equatable {
    struct Model: Codable, Sendable, Equatable {
        /// The build: the first 40 hex digits of the SHA-256 of its signed manifest.
        let revision: String
        /// The model version of that build, `4.0.0` (SDK 3.0.0).
        let version: String?
        /// Where the build comes from: "pin", or the name of a channel ("stable", "beta", "alpha"). A free string: the
        /// SDK does not compare it with a list, send it back or act on it, as it does not with the config's `channel`.
        let source: String
        /// The model id (the folder name under sdk/ in the repository), when the server knows it.
        let model_id: String?
        /// The SDK folder inside the repository ("sdk/v3.2"), when the server knows it.
        let folder: String?
    }

    /// The model the server recommends for this app and SDK version: the newest recommended model
    /// whose minimum SDK version this SDK meets, unless the app is pinned.
    struct Recommended: Codable, Sendable, Equatable {
        /// The model repository ("Quran-Lab/zipformer_p-arabic-v3").
        let model: String
        let model_id: String
        let folder: String
        /// The build: the first 40 hex digits of the SHA-256 of its signed manifest.
        let revision: String
        /// The model version of that build, `4.0.0` (SDK 3.0.0).
        let version: String?
        /// "pin", "stable" or "beta".
        let source: String

        var modelID: ModelID { ModelID(model_id, repository: model, folder: folder) }

        /// A config without a folder means `sdk/<model_id>`.
        init(from d: any Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            model = try c.decode(String.self, forKey: .model)
            model_id = try c.decode(String.self, forKey: .model_id)
            revision = try c.decode(String.self, forKey: .revision)
            source = try c.decode(String.self, forKey: .source)
            version = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? nil
            let f = (try? c.decodeIfPresent(String.self, forKey: .folder)) ?? nil
            folder = f.flatMap { $0.isEmpty ? nil : $0 } ?? "sdk/\(model_id)"
        }
    }

    struct DenyRule: Codable, Sendable, Equatable {
        let platform: String
        let os_version: String
        let device_class: String
        let sdk_version: String
        let model_revision: String
        /// "exact" or "neuralEngine".
        let backend_forced: String
        let reason: String?
    }

    struct Flags: Codable, Sendable, Equatable {
        var analytics: Bool
        var issues: Bool
        var contributions: Bool
        /// Per platform: `off`, `capped` or `attested` (who may upload shared sessions).
        var upload_trust: [String: String]?
        /// 2.0.3: how long a shared recording stays open for the next take, in ms. A whole number 0 to 10000; absent
        /// or anything else 3000; 0 never joins takes.
        var share_join_ms: Int

        init(analytics: Bool = true, issues: Bool = true, contributions: Bool = true, upload_trust: [String: String]? = nil,
                    share_join_ms: Int = 3000) {
            self.analytics = analytics
            self.issues = issues
            self.contributions = contributions
            self.upload_trust = upload_trust
            self.share_join_ms = share_join_ms
        }

        init(from d: any Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            analytics = try c.decodeIfPresent(Bool.self, forKey: .analytics) ?? true
            issues = try c.decodeIfPresent(Bool.self, forKey: .issues) ?? true
            // absent: not offered (only Quran Lab's literal true offers sharing, 2.0.1)
            contributions = try c.decodeIfPresent(Bool.self, forKey: .contributions) ?? false
            upload_trust = try? c.decodeIfPresent([String: String].self, forKey: .upload_trust)
            // any JSON type is read (a string, a boolean or a fraction is the default), never failing the config
            let window: JSONValue? = try? c.decodeIfPresent(JSONValue.self, forKey: .share_join_ms)
            share_join_ms = TakeJoin.window(window)
        }
    }

    let v: Int
    let app: String
    let channel: String
    let issued_at: Int
    let expires_at: Int
    /// Keyed by model repository ("Quran-Lab/zipformer_p-arabic-v3").
    let models: [String: Model]
    let denylist: [DenyRule]
    let flags: Flags
    /// Absent in configs from servers before recommendations, and null when no model fits.
    let recommended: Recommended?
    /// SDK 3.0.0: `{"context": "c16_l64"}`, the response time the app's developer chose on sdk.quranlab.ai. Read it
    /// with `inferenceContext`: anything but an object with a string is ignored, never failing the config.
    let inference: JSONValue?
    /// With a pinned model version the server could not serve: `{"version", "status": "unavailable"}`.
    let pin: JSONValue?

    /// The context the config names, when it names one.
    var inferenceContext: String? { inference?.object?["context"]?.string }

    /// The pinned version the server could not serve (its normal choice stands), when the config says so.
    var pinUnavailable: String? {
        guard let p = pin?.object, p["status"]?.string == "unavailable" else { return nil }
        return p["version"]?.string
    }

    /// Which context a Session runs: the app's choice (it must be one of the model's, else `invalidArgument`), else
    /// the config's `inference.context` when the model has it, else the manifest's default.
    static func context(app: String?, config: RemoteConfig?, contexts: [String], defaultContext: String) throws(RecognizerError) -> String {
        try context(app: app, inference: config?.inferenceContext, contexts: contexts, defaultContext: defaultContext).context
    }

    static func context(app: String?, inference: String?, contexts: [String],
                        defaultContext: String) throws(RecognizerError) -> (context: String, source: String) {
        if let app {
            guard contexts.contains(app) else {
                throw .invalidArgument("context \(app) is not one of \(contexts.joined(separator: ", "))")
            }
            return (app, "app")
        }
        if let inference, contexts.contains(inference) { return (inference, "config") }
        return (defaultContext, "manifest")
    }
    /// Where model files are served, signed with the rest of the config. Read it with `modelBase`: any other JSON type
    /// is ignored there rather than failing the whole config.
    let base: JSONValue?
    /// 2.0.1: rules that keep one accelerator off on matching devices (read with `accelDenyRules`; a malformed rule is
    /// skipped on its own, never the config).
    let accel_deny: JSONValue?

    /// One `accel_deny` rule: patterns (`*`, `prefix*` or exact) by field; an optional field absent matches anything.
    struct AccelDenyRule: Sendable, Equatable {
        let patterns: [String: String]
        /// Unix seconds after which the rule is ignored.
        let until: Double?
        let reason: String?

        static let required = ["platform", "os_version", "device_class", "accelerator", "model_revision", "sdk_version"]
        static let optional = ["os_build", "device_model", "chip", "delegate"]

        /// Whether the rule matches `values` (the incident-report values) for an accelerator of `kind` (`ane`, `gpu`,
        /// `npu`) at `now`. A device without a value for a field the rule names (Apple has no delegate) matches only `*`.
        func matches(_ values: [String: String], kind: String, now: Date = Date()) -> Bool {
            if let until, now.timeIntervalSince1970 >= until { return false }
            for (field, pattern) in patterns {
                let v = field == "accelerator" ? kind : (values[field] ?? "")
                if !RemoteConfig.match(pattern, v) { return false }
            }
            return true
        }
    }

    /// The well-formed `accel_deny` rules, in order.
    var accelDenyRules: [AccelDenyRule] {
        guard let list = accel_deny?.array else { return [] }
        var out: [AccelDenyRule] = []
        rules: for r in list {
            guard let o = r.object else { continue }
            var p: [String: String] = [:]
            for f in AccelDenyRule.required {
                guard let s = o[f]?.string, !s.isEmpty else { continue rules }
                p[f] = s
            }
            for f in AccelDenyRule.optional {
                guard let v = o[f] else { continue }
                guard let s = v.string, !s.isEmpty else { continue rules }
                p[f] = s
            }
            var until: Double?
            if let u = o["until"] {
                guard let n = u.number, n.isFinite else { continue rules }
                until = n
            }
            if let reason = o["reason"], reason.string == nil { continue rules }
            out.append(AccelDenyRule(patterns: p, until: until, reason: o["reason"]?.string))
        }
        return out
    }

    /// The first `accel_deny` rule matching this device and accelerator kind now, if any.
    func accelDenyRule(values: [String: String], kind: String, now: Date = Date()) -> AccelDenyRule? {
        accelDenyRules.first { $0.matches(values, kind: kind, now: now) }
    }

    /// `base` when it is an https URL, the same rule qlab-api applies when it signs it.
    var modelBase: URL? {
        guard let s = base?.string,
              s.range(of: #"^https://[A-Za-z0-9.-]+(:\d+)?(/[A-Za-z0-9._~/-]*)?$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: s)
    }

    var expiresAt: Date { Date(timeIntervalSince1970: TimeInterval(expires_at)) }

    /// `flags.upload_trust` by platform.
    var uploadTrust: [String: String] { flags.upload_trust ?? [:] }

    /// The deny-list rule matching this install, if any. Patterns are "*", a prefix ending in "*",
    /// or an exact value, as on the server.
    func denyRule(platform: String, osVersion: String, deviceClass: String, sdkVersion: String,
                         modelRevision: String) -> DenyRule? {
        denylist.first { r in
            Self.match(r.platform, platform) && Self.match(r.os_version, osVersion)
                && Self.match(r.device_class, deviceClass) && Self.match(r.sdk_version, sdkVersion)
                && Self.match(r.model_revision, modelRevision)
        }
    }

    static func match(_ pattern: String, _ value: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasSuffix("*") { return value.hasPrefix(String(pattern.dropLast())) }
        return pattern == value
    }
}

/// Checks a config response's signature: the header `x-qlab-signature: ed25519=<base64url>` over
/// the body bytes exactly as received, with the key named by `x-qlab-key-id` (the first 8 bytes of
/// SHA-256 of the raw public key, hex) among the trusted ones.
struct ConfigVerifier: Sendable {
    let trustedKeys: [Data]

    static func keyID(_ raw: Data) -> String { Data(SHA256.hash(data: raw).prefix(8)).hex }

    func verify(body: Data, signature header: String?, keyID: String?, now: Date = Date()) throws(CloudError) -> RemoteConfig {
        guard let header, header.hasPrefix("ed25519="), let sig = Data(base64URL: String(header.dropFirst(8))) else {
            throw .invalid("config is not signed")
        }
        // the key id must name one of the keys compiled into the SDK: an unknown kid is refused
        let candidates = trustedKeys.filter { Self.keyID($0) == keyID }
        let ok = candidates.contains { raw in
            (try? Curve25519.Signing.PublicKey(rawRepresentation: raw))?.isValidSignature(sig, for: body) == true
        }
        guard ok else { throw .invalid("config signature does not verify") }
        let cfg: RemoteConfig
        do {
            cfg = try JSONDecoder().decode(RemoteConfig.self, from: body)
        } catch {
            throw .invalid("config does not parse: \(error)")
        }
        guard cfg.v == 1 else { throw .invalid("config version \(cfg.v)") }
        guard cfg.expiresAt > now else { throw .invalid("config expired") }
        return cfg
    }
}

/// Fetches, verifies and keeps the config. The last verified response is kept on disk (body and
/// signature, re-verified when read), so an offline launch still honours the deny-list until the
/// config expires.
final class ConfigStore: Sendable {
    struct Saved: Codable {
        let body: Data
        let signature: String
        let keyID: String?
        var etag: String?
        /// The pin the body was asked with (a body asked with another pin is not confirmed by its ETag).
        var pin: String?
    }

    private let file: JSONFile<Saved>
    private let bucketFile: URL
    private let verifier: ConfigVerifier
    private let state = Locked<RemoteConfig?>(nil)
    /// The model version the config request pins (`model_version`), when the app pinned one.
    private let pinned = Locked<String?>(nil)

    /// The model version the app pinned, when it pinned one.
    var pinnedVersion: String? { pinned.withLock { $0 } }

    /// Sets the pin; true when it changed.
    func pin(_ version: String?) -> Bool {
        pinned.withLock { (p: inout String?) -> Bool in
            defer { p = version }
            return p != version
        }
    }
    /// When the config was last fetched (or confirmed by a 304) in this process.
    let lastFetch = Locked<Date?>(nil)

    init(storage: URL, trustedKeys: [Data]) {
        file = JSONFile(url: storage.appendingPathComponent("cloud/config.json"))
        bucketFile = storage.appendingPathComponent("cloud/rollout-bucket")
        verifier = ConfigVerifier(trustedKeys: trustedKeys)
        if let s = file.read(), let c = try? verifier.verify(body: s.body, signature: s.signature, keyID: s.keyID) {
            state.withLock { $0 = c }
            SDKLatest.note(body: s.body)
        }
    }

    /// The current verified config, nil when there is none or it expired.
    var current: RemoteConfig? {
        state.withLock { c in
            if let x = c, x.expiresAt <= Date() { c = nil }
            return c
        }
    }

    /// For `diagnose()`: `fresh` when a verified config that has not expired is in force, `stale` when the stored one is
    /// past its `expires_at`, `none` when there is none.
    var status: String {
        if current != nil { return "fresh" }
        return file.read() != nil ? "stale" : "none"
    }

    /// Whether Quran Lab answered this install's key: a config was fetched or confirmed in this process, or a verified
    /// one is in force.
    var answered: Bool { lastFetch.withLock { $0 } != nil || current != nil }

    /// The version of the newest SDK release the config in force names (`sdk_latest`), when it names one.
    var latest: String? {
        guard current != nil, let n = file.read().flatMap({ SDKLatest.parse($0.body) }), ModelVersion.isVersion(n.version) else { return nil }
        return n.version
    }

    /// The staged-rollout bucket: one number 0 to 99, drawn once and kept on the device. One of
    /// 100 values identifies no one.
    var bucket: Int {
        if let s = try? String(contentsOf: bucketFile, encoding: .utf8),
           let b = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)), (0..<100).contains(b) {
            return b
        }
        let b = Int.random(in: 0..<100)
        try? FileManager.default.createDirectory(at: bucketFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(String(b).utf8).write(to: bucketFile, options: .atomic)
        return b
    }

    /// GET /v1/config with `If-None-Match` (a 304 keeps the stored signed body), except within an hour of the stored
    /// body's expiry, when a freshly signed body is asked for.
    func fetch(http: HTTPClient, apiURL: URL, token: String, now: Date = Date()) async throws(CloudError) -> RemoteConfig {
        var c = URLComponents(url: apiURL.appendingPathComponent("v1/config"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "bucket", value: String(bucket)), URLQueryItem(name: "sdk", value: SDKInfo.version)]
        let pin = pinned.withLock { $0 }
        if let pin { c.queryItems?.append(URLQueryItem(name: "model_version", value: pin)) }
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        let saved = file.read()
        let stored = current
        if let etag = saved?.etag, saved?.pin == pin, let stored, stored.expiresAt.timeIntervalSince(now) > 3600 {
            r.setValue(etag, forHTTPHeaderField: "if-none-match")
        }
        let resp = try await http.send(r)
        if resp.status == 304, let stored {
            lastFetch.withLock { $0 = now }
            return stored
        }
        guard (200..<300).contains(resp.status) else {
            if resp.status >= 500 { throw .offline("HTTP \(resp.status)") }
            let o = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]
            throw .rejected(status: resp.status, code: o?["error"] as? String ?? "http_\(resp.status)", message: HTTPClient.message(o),
                            reason: HTTPClient.reason(o))
        }
        let sig = resp.header("x-qlab-signature"), kid = resp.header("x-qlab-key-id")
        let cfg = try verifier.verify(body: resp.body, signature: sig, keyID: kid, now: now)
        SDKLatest.note(body: resp.body)
        file.write(Saved(body: resp.body, signature: sig ?? "", keyID: kid, etag: resp.header("etag"), pin: pin))
        state.withLock { $0 = cfg }
        lastFetch.withLock { $0 = now }
        return cfg
    }
}
