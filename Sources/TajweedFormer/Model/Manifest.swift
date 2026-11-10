import CryptoKit
import Foundation

/// The signed list of a model folder's files (`manifest.json`, format 3): every file with its stored size and
/// SHA-256, the platforms, SoC, context, role and need that decide which device downloads it, and for files
/// stored gzip the decoded file's path, size and SHA-256. The SDK keeps only decoded files on disk.
///
///     {"format": 3, "model_id": "v4.0", "family": "tajweedformer", "revision": "...", "min_sdk_version": "2.0.0",
///      "engine_format": 3, "coreml_format": 9, "tokens": "tokens.txt", "tokens_sha256": "...",
///      "default_context": "c16_l64", "contexts": ["c16_l64", "c24_l72", "c24_l256"],
///      "files": [{"path": "layers.zfw.gz", "size": 53737608, "sha256": "...", "platforms": "*", "soc": "*",
///                 "context": "*", "role": "weights", "need": "required", "encoding": "gzip",
///                 "decoded": {"path": "layers.zfw", "size": 65715584, "sha256": "..."}}, ...],
///      "signature": "<base64 Ed25519 over signedMessage>"}
///
/// The signature covers `signedMessage`, a plain text built from the fields (not the JSON bytes), so any language
/// reproduces it.
public struct ModelManifest: Sendable, Hashable {
    public enum Need: String, Sendable, Hashable {
        /// Part of the CPU profile every SDK downloads before its first session.
        case required
        /// Fetched only by the backend that uses it.
        case optional
    }

    /// The decoded form of a file stored compressed.
    public struct Decoded: Sendable, Hashable {
        public let path: String
        public let size: Int64
        public let sha256: String
    }

    public struct File: Sendable, Hashable {
        /// The stored file's path in the folder on the server (`layers.zfw.gz`).
        public let path: String
        public let size: Int64
        public let sha256: String
        /// `["*"]`, or some of android, apple, web, native.
        public let platforms: [String]
        /// A SoC id or `*`.
        public let soc: String
        /// A context or `*`.
        public let context: String
        /// tokens, calibration, expected, weights, frontend, graph, graph-data, frames, ort-graph, npu-model,
        /// npu-io, npu-masks, coreml, coreml-keeps, correction (and any role a later writer adds).
        public let role: String
        public let need: Need
        /// `identity` or `gzip`.
        public let encoding: String
        public let decoded: Decoded?

        /// The file as the SDK keeps it on disk.
        public var localPath: String { decoded?.path ?? path }
        public var localSize: Int64 { decoded?.size ?? size }
        public var localSHA256: String { (decoded?.sha256 ?? sha256).lowercased() }
        public var isGzip: Bool { encoding == "gzip" }

        public func isFor(platform: String) -> Bool { platforms.contains("*") || platforms.contains(platform) }

        public init(path: String, size: Int64, sha256: String, platforms: [String] = ["*"], soc: String = "*",
                    context: String = "*", role: String, need: Need = .required, encoding: String = "identity",
                    decoded: Decoded? = nil) {
            self.path = path; self.size = size; self.sha256 = sha256.lowercased(); self.platforms = platforms
            self.soc = soc; self.context = context; self.role = role; self.need = need; self.encoding = encoding
            self.decoded = decoded
        }
    }

    public static let fileName = "manifest.json"
    /// The only manifest format SDK 2.0.0 reads.
    public static let format = 3
    /// The engine file format SDK 2.0.0 reads (folder layout v2).
    public static let engineFormat = 3
    /// CoreML specification versions this SDK can load (9: iOS 18, macOS 15).
    public static let supportedCoreMLFormats = 1...9
    static let platformOrder = ["android", "apple", "web", "native"]

    public let modelID: String
    public let family: String
    public let revision: String
    public let minSDKVersion: String
    public let engineFormat: Int
    public let coremlFormat: Int
    public let tokens: String
    public let tokensSHA256: String
    public let defaultContext: String
    public let contexts: [String]
    public let files: [File]
    public var signature: String?
    /// The golden test's tolerance per accelerator build (`coreml`, `coreml-compact`, `npu:<soc>:<context>`), from the
    /// signed manifest's optional `golden_tolerance`; a build not listed (or listed with a malformed value) is exact.
    /// Empty when the field is absent, or present but not covered by the signature.
    public var goldenTolerance: [String: GoldenTolerance] = [:]

    /// How far an accelerator may be from the CPU engine over the whole self-test set and still pass: token edits on
    /// the clean clips, and the symmetric differences of the flagged sites and flagged words on every clip.
    public struct GoldenTolerance: Sendable, Hashable {
        public let tokenDiffs: Int
        public let siteFlagDiffs: Int
        public let wordFlagDiffs: Int
        public static let exact = GoldenTolerance(tokenDiffs: 0, siteFlagDiffs: 0, wordFlagDiffs: 0)
        public init(tokenDiffs: Int, siteFlagDiffs: Int, wordFlagDiffs: Int) {
            self.tokenDiffs = tokenDiffs; self.siteFlagDiffs = siteFlagDiffs; self.wordFlagDiffs = wordFlagDiffs
        }
    }

    /// The tolerance of `build`: exact unless the signed manifest gives one.
    public func tolerance(build: String) -> GoldenTolerance { goldenTolerance[build] ?? .exact }

    /// `golden_tolerance` read leniently: each build whose three counts are integers 0 or more; any other build entry is
    /// left out (exact).
    static func parseTolerance(_ any: Any?) -> [String: GoldenTolerance] {
        guard let o = any as? [String: Any] else { return [:] }
        func count(_ v: Any?) -> Int? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            guard d.isFinite, d >= 0, d == d.rounded(), d <= 1_000_000 else { return nil }
            return Int(d)
        }
        var out: [String: GoldenTolerance] = [:]
        for (build, v) in o {
            guard !build.isEmpty, !build.contains(" "), !build.contains("\n"), let e = v as? [String: Any],
                  let t = count(e["token_diffs"]), let s = count(e["site_flag_diffs"]), let w = count(e["word_flag_diffs"]) else { continue }
            out[build] = GoldenTolerance(tokenDiffs: t, siteFlagDiffs: s, wordFlagDiffs: w)
        }
        return out
    }

    public init(modelID: String, family: String = "tajweedformer", revision: String, minSDKVersion: String = "2.0.0",
                engineFormat: Int = 3, coremlFormat: Int = 9, tokens: String = "tokens.txt", tokensSHA256: String,
                defaultContext: String, contexts: [String], files: [File], signature: String? = nil) {
        self.modelID = modelID; self.family = family; self.revision = revision; self.minSDKVersion = minSDKVersion
        self.engineFormat = engineFormat; self.coremlFormat = coremlFormat; self.tokens = tokens
        self.tokensSHA256 = tokensSHA256.lowercased(); self.defaultContext = defaultContext; self.contexts = contexts
        self.files = files; self.signature = signature
    }

    // MARK: JSON

    /// Parses manifest.json. Throws `manifestInvalid` for anything but a well-formed format 3 manifest.
    public static func parse(_ data: Data) throws(RecognizerError) -> ModelManifest {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw .manifestInvalid("manifest.json is not a JSON object")
        }
        guard let f = o["format"] as? Int else { throw .manifestInvalid("no format") }
        guard f == format else {
            throw .manifestInvalid("format \(f) is not supported by this SDK (2.0.0 reads format 3, the V4 folder)")
        }
        func str(_ k: String) throws(RecognizerError) -> String {
            guard let v = o[k] as? String else { throw .manifestInvalid("\(k) missing") }
            return v
        }
        func int(_ k: String) throws(RecognizerError) -> Int {
            guard let v = o[k] as? Int else { throw .manifestInvalid("\(k) missing") }
            return v
        }
        guard let ctxs = o["contexts"] as? [String], !ctxs.isEmpty else { throw .manifestInvalid("contexts missing") }
        guard let list = o["files"] as? [[String: Any]] else { throw .manifestInvalid("files missing") }
        var files: [File] = []
        for e in list {
            guard let path = e["path"] as? String, let size = (e["size"] as? NSNumber)?.int64Value,
                  let sha = e["sha256"] as? String, let role = e["role"] as? String,
                  let needRaw = e["need"] as? String, let need = Need(rawValue: needRaw) else {
                throw .manifestInvalid("a file entry lacks path, size, sha256, role or need")
            }
            let platforms: [String]
            if let s = e["platforms"] as? String { platforms = [s] } else if let a = e["platforms"] as? [String] { platforms = a } else {
                throw .manifestInvalid("\(path): platforms missing")
            }
            let encoding = (e["encoding"] as? String) ?? "identity"
            guard encoding == "identity" || encoding == "gzip" else { throw .manifestInvalid("\(path): encoding \(encoding)") }
            var decoded: Decoded?
            if encoding == "gzip" {
                guard let d = e["decoded"] as? [String: Any], let dp = d["path"] as? String,
                      let ds = (d["size"] as? NSNumber)?.int64Value, let dh = d["sha256"] as? String else {
                    throw .manifestInvalid("\(path): gzip without its decoded path, size and sha256")
                }
                decoded = Decoded(path: dp, size: ds, sha256: dh.lowercased())
            }
            files.append(File(path: path, size: size, sha256: sha, platforms: platforms, soc: (e["soc"] as? String) ?? "*",
                              context: (e["context"] as? String) ?? "*", role: role, need: need, encoding: encoding,
                              decoded: decoded))
        }
        let m = ModelManifest(modelID: try str("model_id"), family: try str("family"), revision: try str("revision"),
                              minSDKVersion: try str("min_sdk_version"), engineFormat: try int("engine_format"),
                              coremlFormat: try int("coreml_format"), tokens: try str("tokens"),
                              tokensSHA256: try str("tokens_sha256"), defaultContext: try str("default_context"),
                              contexts: ctxs, files: files, signature: o["signature"] as? String)
        var mm = m
        mm.goldenTolerance = parseTolerance(o["golden_tolerance"])
        try mm.checkPaths()
        return mm
    }

    /// manifest.json for this manifest (sorted keys; the signature is over `signedMessage`, so formatting is free).
    public func jsonData() -> Data {
        var list: [[String: Any]] = []
        for f in files {
            var e: [String: Any] = ["path": f.path, "size": f.size, "sha256": f.sha256,
                                    "platforms": f.platforms == ["*"] ? "*" as Any : f.platforms as Any,
                                    "soc": f.soc, "context": f.context, "role": f.role, "need": f.need.rawValue,
                                    "encoding": f.encoding]
            if let d = f.decoded { e["decoded"] = ["path": d.path, "size": d.size, "sha256": d.sha256] }
            list.append(e)
        }
        var o: [String: Any] = ["format": Self.format, "model_id": modelID, "family": family, "revision": revision,
                                "min_sdk_version": minSDKVersion, "engine_format": engineFormat,
                                "coreml_format": coremlFormat, "tokens": tokens, "tokens_sha256": tokensSHA256,
                                "default_context": defaultContext, "contexts": contexts, "files": list]
        if let signature { o["signature"] = signature }
        if !goldenTolerance.isEmpty {
            o["golden_tolerance"] = goldenTolerance.mapValues {
                ["token_diffs": $0.tokenDiffs, "site_flag_diffs": $0.siteFlagDiffs, "word_flag_diffs": $0.wordFlagDiffs]
            }
        }
        return (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    public func write(to directory: URL) throws(RecognizerError) {
        do { try jsonData().write(to: directory.appendingPathComponent(Self.fileName), options: .atomic) } catch {
            throw .storageFailed("cannot write \(Self.fileName): \(error.localizedDescription)")
        }
    }

    static func read(_ directory: URL) throws(RecognizerError) -> ModelManifest {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else {
            throw .modelMissing("no \(fileName) in \(directory.lastPathComponent)")
        }
        return try parse(data)
    }

    // MARK: signature

    /// The platforms field of the signed text: `*`, or the listed ones in the order android, apple, web, native.
    static func platformField(_ p: [String]) -> String {
        p.contains("*") ? "*" : platformOrder.filter { p.contains($0) }.joined(separator: ",")
    }

    /// The bytes the signature covers (UTF-8, LF line ends, files sorted by the stored path's bytes):
    ///
    ///     quranlab-model-manifest 3
    ///     model_id v4.0
    ///     family tajweedformer
    ///     revision <rev>
    ///     min_sdk_version 2.0.0
    ///     engine_format 3
    ///     coreml_format 9
    ///     tokens tokens.txt
    ///     tokens_sha256 <hex>
    ///     default_context c16_l64
    ///     contexts c16_l64,c24_l72,c24_l256
    ///     file <sha256> <size> <path> <platforms> <soc> <context> <role> <need> <encoding> <dsha256> <dsize> <dpath>
    ///
    /// For `identity` files the three decoded fields are `-`. With `golden_tolerance` (SDK 2.0.1), one line per build
    /// after the header lines, sorted by the build key's bytes: `golden_tolerance <build> <token_diffs>
    /// <site_flag_diffs> <word_flag_diffs>`; none when the field is absent.
    public var signedMessage: Data { signedMessage(tolerance: true) }

    func signedMessage(tolerance: Bool) -> Data {
        var s = "quranlab-model-manifest 3\n"
        s += "model_id \(modelID)\nfamily \(family)\nrevision \(revision)\nmin_sdk_version \(minSDKVersion)\n"
        s += "engine_format \(engineFormat)\ncoreml_format \(coremlFormat)\ntokens \(tokens)\ntokens_sha256 \(tokensSHA256)\n"
        s += "default_context \(defaultContext)\ncontexts \(contexts.joined(separator: ","))\n"
        if tolerance {
            for b in goldenTolerance.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
                let t = goldenTolerance[b]!
                s += "golden_tolerance \(b) \(t.tokenDiffs) \(t.siteFlagDiffs) \(t.wordFlagDiffs)\n"
            }
        }
        for f in files.sorted(by: { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }) {
            let d = f.decoded
            s += "file \(f.sha256) \(f.size) \(f.path) \(Self.platformField(f.platforms)) \(f.soc) \(f.context) "
            s += "\(f.role) \(f.need.rawValue) \(f.encoding) \(d?.sha256 ?? "-") \(d.map { String($0.size) } ?? "-") \(d?.path ?? "-")\n"
        }
        return Data(s.utf8)
    }

    // MARK: checks

    private static func safe(_ p: String) -> Bool {
        !p.isEmpty && !p.hasPrefix("/") && !p.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
            && !p.hasSuffix(".part")
    }

    func checkPaths() throws(RecognizerError) {
        var stored = Set<String>(), local = Set<String>()
        for f in files {
            guard Self.safe(f.path), Self.safe(f.localPath) else { throw .manifestInvalid("bad path \(f.path)") }
            guard f.sha256.count == 64, f.localSHA256.count == 64, f.size >= 0, f.localSize >= 0 else {
                throw .manifestInvalid("\(f.path): bad size or sha256")
            }
            guard stored.insert(f.path).inserted, local.insert(f.localPath).inserted else {
                throw .manifestInvalid("\(f.localPath) is listed twice")
            }
        }
        guard contexts.contains(defaultContext) else { throw .manifestInvalid("default_context is not one of contexts") }
        for f in files where f.context != "*" && !contexts.contains(f.context) {
            throw .manifestInvalid("\(f.path): context \(f.context) is not one of contexts")
        }
    }

    /// Whether `version` (x.y.z) is at or above `minimum` (x.y.z), compared numerically part by part.
    public static func version(_ version: String, isAtLeast minimum: String) -> Bool {
        func parts(_ v: String) -> [Int]? {
            let core = v.split(separator: "-", maxSplits: 1).first.map(String.init) ?? v
            let p = core.split(separator: ".").map { Int($0) }
            return p.contains(nil) || p.isEmpty ? nil : p.map { $0! }
        }
        guard let a = parts(version), let b = parts(minimum) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    /// The model can run in this SDK: its minimum SDK version and the engine format.
    func checkCompatible(sdkVersion: String = SDKInfo.version) throws(RecognizerError) {
        guard Self.version(sdkVersion, isAtLeast: minSDKVersion) else {
            throw .manifestInvalid("\(modelID) \(revision) needs SDK \(minSDKVersion) or newer (this is \(sdkVersion))")
        }
        guard engineFormat == Self.engineFormat else {
            throw .manifestInvalid("engine format \(engineFormat) is not supported by this SDK (it reads \(Self.engineFormat))")
        }
        guard family == "tajweedformer" else { throw .manifestInvalid("family \(family): SDK 2.0.0 hosts only TajweedFormer") }
    }

    // MARK: lookups

    public func file(local path: String) -> File? { files.first { $0.localPath == path } }
    public func files(role: String) -> [File] { files.filter { $0.role == role } }

    /// Size and lowercase hex SHA-256 of a file, read in 4 MB pieces.
    static func digest(_ url: URL) throws(RecognizerError) -> (Int64, String) {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw .modelMissing("cannot read \(url.lastPathComponent)") }
        defer { try? h.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            let piece: Data
            do { piece = try h.read(upToCount: 4 << 20) ?? Data() } catch { throw .modelMissing("cannot read \(url.lastPathComponent)") }
            if piece.isEmpty { break }
            size += Int64(piece.count)
            hasher.update(data: piece)
        }
        return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

/// Checks a manifest's Ed25519 signature against the SDK's trusted keys.
public struct ManifestVerifier: Sendable {
    /// Raw 32-byte Ed25519 public keys a signature may verify against.
    let trustedKeys: [Data]
    let requireSignature: Bool

    public init(trustedKeys: [Data], requireSignature: Bool) {
        self.trustedKeys = trustedKeys
        self.requireSignature = requireSignature
    }

    /// Quran Lab's manifest signing key (the public half of qlab-cdn's and qlab-api's MANIFEST_SIGNING_KEY, key id
    /// 660a07197c4808da). Signs the CDN file list, model manifests and the per-app config.
    public static let quranLabPublicKey = Data([
        0xfc, 0x02, 0xfb, 0xd9, 0x06, 0x60, 0x8e, 0xbc, 0x20, 0x6a, 0x37, 0x1d, 0x8e, 0x61, 0xc1, 0x06, 0x2e, 0xa5, 0x55, 0x77, 0x8b, 0x44, 0xb1, 0xac, 0x83, 0x40, 0x61, 0x04, 0x3a, 0xee, 0x4a, 0x33
    ])

    static var standard: ManifestVerifier {
        let o = QuranLab.configuration.options
        return ManifestVerifier(trustedKeys: (o.cloud ?? CloudOptions()).signingKeys, requireSignature: o.requireSignedModels)
    }

    /// The signature must verify when present, and be present when `required` (or the verifier requires it).
    /// Checks the signature and returns the manifest as trusted: with `golden_tolerance` when the signature covers it,
    /// without it (every build exact) when the field is there but only the rest is signed.
    @discardableResult
    func verifySignature(_ m: ModelManifest, required: Bool = false) throws(RecognizerError) -> ModelManifest {
        if let sig = m.signature {
            guard let raw = Data(base64Encoded: sig) else { throw .signatureInvalid }
            func ok(_ message: Data) -> Bool {
                trustedKeys.contains { key in
                    guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
                    return pk.isValidSignature(raw, for: message)
                }
            }
            if ok(m.signedMessage(tolerance: true)) { return m }
            guard !m.goldenTolerance.isEmpty, ok(m.signedMessage(tolerance: false)) else { throw .signatureInvalid }
            var unsigned = m
            unsigned.goldenTolerance = [:]
            return unsigned
        } else if required || requireSignature {
            throw .signatureInvalid
        }
        return m
    }
}
