import CryptoKit
import Foundation

/// The per-app configuration from qlab-api (`GET /v1/config`): which model revision to use (the
/// portal's pin, or the channel's release with a staged rollout), the deny-list and flags. Signed
/// with Ed25519 over the exact body bytes; the SDK refuses one that does not verify or has expired.
public struct RemoteConfig: Codable, Sendable, Equatable {
    public struct Model: Codable, Sendable, Equatable {
        public let revision: String
        /// "pin", "stable" or "beta".
        public let source: String
        /// The model id (the folder name under sdk/ in the repository), when the server knows it.
        public let model_id: String?
        /// The SDK folder inside the repository ("sdk/v3.2"), when the server knows it.
        public let folder: String?
    }

    /// The model the server recommends for this app and SDK version: the newest recommended model
    /// whose minimum SDK version this SDK meets, unless the app is pinned.
    public struct Recommended: Codable, Sendable, Equatable {
        /// The model repository ("Quran-Lab/zipformer_p-arabic-v3").
        public let model: String
        public let model_id: String
        public let folder: String
        /// The CDN revision (commit).
        public let revision: String
        /// "pin", "stable" or "beta".
        public let source: String

        public var modelID: ModelID { ModelID(model_id, repository: model, folder: folder) }

        /// A config without a folder means `sdk/<model_id>`.
        public init(from d: any Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            model = try c.decode(String.self, forKey: .model)
            model_id = try c.decode(String.self, forKey: .model_id)
            revision = try c.decode(String.self, forKey: .revision)
            source = try c.decode(String.self, forKey: .source)
            let f = (try? c.decodeIfPresent(String.self, forKey: .folder)) ?? nil
            folder = f.flatMap { $0.isEmpty ? nil : $0 } ?? "sdk/\(model_id)"
        }
    }

    public struct DenyRule: Codable, Sendable, Equatable {
        public let platform: String
        public let os_version: String
        public let device_class: String
        public let sdk_version: String
        public let model_revision: String
        /// "exact" or "neuralEngine".
        public let backend_forced: String
        public let reason: String?
    }

    public struct Flags: Codable, Sendable, Equatable {
        public var analytics: Bool
        public var issues: Bool
        public var contributions: Bool
        /// Per platform: `off`, `capped` or `attested` (who may upload shared sessions).
        public var upload_trust: [String: String]?
        /// 2.0.3: how long a shared recording stays open for the next take, in ms. A whole number 0 to 10000; absent
        /// or anything else 3000; 0 never joins takes.
        public var share_join_ms: Int

        public init(analytics: Bool = true, issues: Bool = true, contributions: Bool = true, upload_trust: [String: String]? = nil,
                    share_join_ms: Int = 3000) {
            self.analytics = analytics
            self.issues = issues
            self.contributions = contributions
            self.upload_trust = upload_trust
            self.share_join_ms = share_join_ms
        }

        public init(from d: any Decoder) throws {
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

    public let v: Int
    public let app: String
    public let channel: String
    public let issued_at: Int
    public let expires_at: Int
    /// Keyed by model repository ("Quran-Lab/zipformer_p-arabic-v3").
    public let models: [String: Model]
    public let denylist: [DenyRule]
    public let flags: Flags
    /// Absent in configs from servers before recommendations, and null when no model fits.
    public let recommended: Recommended?
    /// 2.0.0: the portal's tajweed settings for V4, raw; absent on older servers. Read it with
    /// `RemoteTajweedBlock.parse` (TajweedRecognizer does): an invalid field is dropped, never the config.
    public let tajweed: JSONValue?
    /// Where model files are served, signed with the rest of the config. Read it with `modelBase`: any other JSON type
    /// is ignored there rather than failing the whole config.
    public let base: JSONValue?
    /// 2.0.1: rules that keep one accelerator off on matching devices (read with `accelDenyRules`; a malformed rule is
    /// skipped on its own, never the config).
    public let accel_deny: JSONValue?

    /// One `accel_deny` rule: patterns (`*`, `prefix*` or exact) by field; an optional field absent matches anything.
    public struct AccelDenyRule: Sendable, Equatable {
        public let patterns: [String: String]
        /// Unix seconds after which the rule is ignored.
        public let until: Double?
        public let reason: String?

        static let required = ["platform", "os_version", "device_class", "accelerator", "model_revision", "sdk_version"]
        static let optional = ["os_build", "device_model", "chip", "delegate"]

        /// Whether the rule matches `values` (the incident-report values) for an accelerator of `kind` (`ane`, `gpu`,
        /// `npu`) at `now`. A device without a value for a field the rule names (Apple has no delegate) matches only `*`.
        public func matches(_ values: [String: String], kind: String, now: Date = Date()) -> Bool {
            if let until, now.timeIntervalSince1970 >= until { return false }
            for (field, pattern) in patterns {
                let v = field == "accelerator" ? kind : (values[field] ?? "")
                if !RemoteConfig.match(pattern, v) { return false }
            }
            return true
        }
    }

    /// The well-formed `accel_deny` rules, in order.
    public var accelDenyRules: [AccelDenyRule] {
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
    public func accelDenyRule(values: [String: String], kind: String, now: Date = Date()) -> AccelDenyRule? {
        accelDenyRules.first { $0.matches(values, kind: kind, now: now) }
    }

    /// `base` when it is an https URL, the same rule qlab-api applies when it signs it.
    public var modelBase: URL? {
        guard let s = base?.string,
              s.range(of: #"^https://[A-Za-z0-9.-]+(:\d+)?(/[A-Za-z0-9._~/-]*)?$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: s)
    }

    public var expiresAt: Date { Date(timeIntervalSince1970: TimeInterval(expires_at)) }

    /// `flags.upload_trust` by platform.
    public var uploadTrust: [String: String] { flags.upload_trust ?? [:] }

    /// The deny-list rule matching this install, if any. Patterns are "*", a prefix ending in "*",
    /// or an exact value, as on the server.
    public func denyRule(platform: String, osVersion: String, deviceClass: String, sdkVersion: String,
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
    }

    private let file: JSONFile<Saved>
    private let bucketFile: URL
    private let verifier: ConfigVerifier
    private let state = Locked<RemoteConfig?>(nil)
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
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        let saved = file.read()
        let stored = current
        if let etag = saved?.etag, let stored, stored.expiresAt.timeIntervalSince(now) > 3600 {
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
            throw .rejected(status: resp.status, code: o?["error"] as? String ?? "http_\(resp.status)", message: o?["message"] as? String ?? "")
        }
        let sig = resp.header("x-qlab-signature"), kid = resp.header("x-qlab-key-id")
        let cfg = try verifier.verify(body: resp.body, signature: sig, keyID: kid, now: now)
        SDKLatest.note(body: resp.body)
        file.write(Saved(body: resp.body, signature: sig ?? "", keyID: kid, etag: resp.header("etag")))
        state.withLock { $0 = cfg }
        lastFetch.withLock { $0 = now }
        return cfg
    }
}
