import CryptoKit
import Foundation

/// A model or SDK version `x.y.z`: three decimal integers without leading zeros and without a suffix, at most 4, 4
/// and 6 digits, compared part by part as integers. Anything else is not a version and is never ordered.
struct ModelVersion: Sendable, Hashable, Comparable {
    let parts: [Int]

    init?(_ s: String) {
        guard s.range(of: #"^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,5})$"#, options: .regularExpression) != nil else { return nil }
        parts = s.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
    }

    static func < (a: ModelVersion, b: ModelVersion) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }

    static func isVersion(_ s: String) -> Bool { ModelVersion(s) != nil }
}

/// One accelerator build's tolerance in the promotion golden test on raw outputs (`golden_raw_tolerance` of the
/// signed manifest): per CTC head the token edits and the log-prob distances it may have against the CPU engine,
/// and for the attribute heads the mean probability difference. A head without an entry is judged on tokens only.
struct GoldenRawTolerance: Sendable, Hashable {
    struct Head: Sendable, Hashable {
        let tokenEdits: Int
        let lpMean: Double
        let lpP99: Double
    }

    var heads: [String: Head] = [:]
    /// `attr.p_mean`, when the build has one.
    var pMean: Double?

    /// A count as its signed line writes it: a number with an integer value 0 to 1,000,000.
    static func count(_ v: JSONValue?) -> String? {
        guard let x = v?.number, x.isFinite, x == x.rounded(), x >= 0, x <= 1_000_000 else { return nil }
        return String(Int(x))
    }

    /// A tolerance value as its signed line writes it, or nil when it is not acceptable: a number from `lo` to `hi`
    /// with at most 6 digits after the dot, written with 6 decimals, the trailing zeros removed but one digit kept
    /// after the dot (`0.05`, `1.5`, `2.0`, `0.0`).
    static func number(_ v: JSONValue?, _ lo: Double, _ hi: Double) -> String? {
        guard let x = v?.number, x.isFinite, x >= lo, x <= hi else { return nil }
        if x == 0 { return "0.0" }
        var s = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), x)
        guard Double(s) == x else { return nil }
        while s.hasSuffix("0") { s.removeLast() }
        return s.hasSuffix(".") ? s + "0" : s
    }

    /// A build key: 1 to 64 printable ASCII characters without a space.
    static func isBuildKey(_ k: String) -> Bool {
        let u = Array(k.utf8)
        return (1...64).contains(u.count) && u.allSatisfy { (0x21...0x7E).contains($0) }
    }

    static func isHeadKey(_ k: String) -> Bool { k.range(of: "^[a-z][a-z0-9_]{0,31}$", options: .regularExpression) != nil }

    static func sorted(_ keys: some Sequence<String>) -> [String] {
        keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// One build's entry: the tolerance and its signed lines when it is well formed, else nil (the build is then
    /// judged on tokens only). One bad head makes the whole build malformed.
    static func build(_ key: String, _ value: JSONValue) -> (tolerance: GoldenRawTolerance, lines: [String])? {
        guard isBuildKey(key), let o = value.object else { return nil }
        var t = GoldenRawTolerance()
        var lines: [String] = []
        for head in sorted(o.keys) {
            guard isHeadKey(head), let e = o[head]?.object else { return nil }
            if head == "attr" {
                guard Set(e.keys) == ["p_mean"], let p = number(e["p_mean"], 0, 1), let v = e["p_mean"]?.number else { return nil }
                t.pMean = v
                lines.append("golden_raw \(key) attr p_mean=\(p)")
            } else {
                guard Set(e.keys) == ["token_edits", "lp_mean", "lp_p99"], let n = count(e["token_edits"]),
                      let a = number(e["lp_mean"], 0, 30), let b = number(e["lp_p99"], 0, 30),
                      let edits = e["token_edits"]?.number, let mean = e["lp_mean"]?.number, let p99 = e["lp_p99"]?.number else { return nil }
                t.heads[head] = Head(tokenEdits: Int(edits), lpMean: mean, lpP99: p99)
                lines.append("golden_raw \(key) \(head) token_edits=\(n) lp_mean=\(a) lp_p99=\(b)")
            }
        }
        return (t, lines)
    }

    /// The whole field: the well-formed builds, the malformed build keys (sorted), and the signed lines.
    static func parse(_ field: JSONValue?) -> (good: [String: GoldenRawTolerance], bad: [String], lines: [String]) {
        guard let o = field?.object else { return ([:], [], []) }
        var good: [String: GoldenRawTolerance] = [:]
        var bad: [String] = [], lines: [String] = []
        for key in sorted(o.keys) {
            if let r = build(key, o[key]!) {
                good[key] = r.tolerance
                lines += r.lines
            } else {
                bad.append(key)
            }
        }
        return (good, bad, lines)
    }

    /// The signed lines of a 2.x `golden_tolerance` field: one per well-formed build entry, sorted by the build key.
    /// SDK 3.0.0 reads nothing else of that field.
    static func legacyLines(_ field: JSONValue?) -> [String] {
        guard let o = field?.object else { return [] }
        var out: [String] = []
        for key in sorted(o.keys) {
            guard isBuildKey(key), let e = o[key]?.object, let t = count(e["token_diffs"]), let s = count(e["site_flag_diffs"]),
                  let w = count(e["word_flag_diffs"]) else { continue }
            out.append("golden_tolerance \(key) \(t) \(s) \(w)")
        }
        return out
    }
}

/// The signed list of a model folder's files (`manifest.json`, format 3): every file with its stored size and
/// SHA-256, the platforms, SoC, context, role and need that decide which device downloads it, and for files
/// stored gzip the decoded file's path, size and SHA-256. The SDK keeps only decoded files on disk.
///
///     {"format": 3, "model_id": "v4.0", "family": "tajweedformer", "revision": "...", "version": "4.0.0",
///      "min_sdk_version": "3.0.0", "engine_format": 3, "coreml_format": 9, "tokens": "tokens.txt",
///      "tokens_sha256": "...", "default_context": "c16_l64", "contexts": ["c16_l64", "c24_l72", "c24_l256"],
///      "golden_raw_tolerance": {"coreml": {"log_probs": {"token_edits": 0, "lp_mean": 0.05, "lp_p99": 1.5}}},
///      "files": [{"path": "layers.zfw.gz", "size": 53737608, "sha256": "...", "platforms": "*", "soc": "*",
///                 "context": "*", "role": "weights", "need": "required", "encoding": "gzip",
///                 "decoded": {"path": "layers.zfw", "size": 65715584, "sha256": "..."}}, ...],
///      "signature": "<base64 Ed25519 over the signed text>"}
///
/// SDK 3.0.0: a model has a version (`4.0.0`), and a folder is a build of it, named by the first 40 hex digits of the
/// SHA-256 of its manifest.json. A manifest without `version` is a 2.x build and is refused. The signature covers
/// `signedText`, a plain text built from the fields (not the JSON bytes), so any language reproduces it.
struct ModelManifest: Sendable, Hashable {
    enum Need: String, Sendable, Hashable {
        /// Part of the CPU profile every SDK downloads before its first session.
        case required
        /// Fetched only by the backend that uses it.
        case optional
    }

    /// The decoded form of a file stored compressed.
    struct Decoded: Sendable, Hashable {
        let path: String
        let size: Int64
        let sha256: String
    }

    struct File: Sendable, Hashable {
        /// The stored file's path in the folder on the server (`layers.zfw.gz`).
        let path: String
        let size: Int64
        let sha256: String
        /// `["*"]`, or some of android, apple, web, native.
        let platforms: [String]
        /// A SoC id or `*`.
        let soc: String
        /// A context or `*`.
        let context: String
        /// tokens, calibration, reference, weights, frontend, graph, graph-data, frames, ort-graph, npu-model, selftest,
        /// coreml, coreml-keeps (and any role a later writer adds).
        let role: String
        let need: Need
        /// `identity` or `gzip`.
        let encoding: String
        let decoded: Decoded?

        /// The file as the SDK keeps it on disk.
        var localPath: String { decoded?.path ?? path }
        var localSize: Int64 { decoded?.size ?? size }
        var localSHA256: String { (decoded?.sha256 ?? sha256).lowercased() }
        var isGzip: Bool { encoding == "gzip" }

        func isFor(platform: String) -> Bool { platforms.contains("*") || platforms.contains(platform) }

        init(path: String, size: Int64, sha256: String, platforms: [String] = ["*"], soc: String = "*",
             context: String = "*", role: String, need: Need = .required, encoding: String = "identity",
             decoded: Decoded? = nil) {
            self.path = path; self.size = size; self.sha256 = sha256.lowercased(); self.platforms = platforms
            self.soc = soc; self.context = context; self.role = role; self.need = need; self.encoding = encoding
            self.decoded = decoded
        }
    }

    static let fileName = "manifest.json"
    /// The only manifest format the SDK reads.
    static let format = 3
    /// The engine file format the SDK reads (folder layout v2).
    static let engineFormat = 3
    /// CoreML specification versions this SDK can load (9: iOS 18, macOS 15).
    static let supportedCoreMLFormats = 1...9
    static let platformOrder = ["android", "apple", "web", "native"]

    let modelID: String
    let family: String
    let revision: String
    let minSDKVersion: String
    let engineFormat: Int
    let coremlFormat: Int
    let tokens: String
    let tokensSHA256: String
    let defaultContext: String
    let contexts: [String]
    let files: [File]
    /// The model's version, `4.0.0`; empty when the manifest names none (a 2.x build, which SDK 3.0.0 refuses).
    var version = ""
    var signature: String?
    /// The bytes this manifest was parsed from: what is written to disk, so that a folder's manifest.json is the
    /// signed file byte for byte and its SHA-256 is the build id. Nil for a manifest made in memory.
    var raw: Data?
    /// `golden_tolerance` (2.x) and `golden_raw_tolerance` as the JSON has them: their signed lines are made from
    /// these values.
    var goldenToleranceField: JSONValue?
    var goldenRawField: JSONValue?
    /// The tolerance of each accelerator build in the raw golden test: the well-formed builds of a SIGNED
    /// `golden_raw_tolerance`. Empty when the field is absent or the signature does not cover its lines; a build
    /// without an entry is judged on tokens only.
    var goldenRaw: [String: GoldenRawTolerance] = [:]
    /// Whether the signature covered the `golden_tolerance` and the `golden_raw` lines (set by the verifier).
    var goldenToleranceSigned = false
    var goldenRawSigned = false
    /// The SHA-256 (hex) of the manifest.json bytes this was read from; empty for a manifest made in memory.
    var sha256 = ""

    /// The build id: the first 40 hex digits of the SHA-256 of manifest.json.
    var build: String { String(sha256.prefix(40)) }

    /// The builds whose `golden_raw_tolerance` entry is malformed: judged on tokens only.
    var tokensOnlyBuilds: [String] { goldenRawSigned ? GoldenRawTolerance.parse(goldenRawField).bad : [] }

    /// The raw golden tolerance of `build` (`coreml`, `coreml-compact`), when the signed manifest gives one.
    func rawTolerance(build: String) -> GoldenRawTolerance? { goldenRaw[build] }

    init(modelID: String, family: String = "tajweedformer", revision: String, version: String = "4.0.0", minSDKVersion: String = "3.0.0",
         engineFormat: Int = 3, coremlFormat: Int = 9, tokens: String = "tokens.txt", tokensSHA256: String,
         defaultContext: String, contexts: [String], files: [File], signature: String? = nil) {
        self.modelID = modelID; self.family = family; self.revision = revision; self.minSDKVersion = minSDKVersion
        self.engineFormat = engineFormat; self.coremlFormat = coremlFormat; self.tokens = tokens
        self.tokensSHA256 = tokensSHA256.lowercased(); self.defaultContext = defaultContext; self.contexts = contexts
        self.files = files; self.signature = signature
        self.version = version
    }

    // MARK: JSON

    private static func isHex64(_ s: String) -> Bool { s.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil }

    /// A JSON integer (not a boolean, not a fraction).
    private static func integer(_ v: Any?) -> Int64? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) < 9e15 else { return nil }
        return n.int64Value
    }

    /// Parses manifest.json. Throws `manifestInvalid` for anything but a well-formed format 3 manifest: the format 3
    /// shape, and `version` (when present) and `min_sdk_version` being versions.
    static func parse(_ data: Data) throws(RecognizerError) -> ModelManifest {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw .manifestInvalid("manifest.json is not a JSON object")
        }
        guard let f = integer(o["format"]) else { throw .manifestInvalid("no format") }
        guard f == Int64(format) else {
            throw .manifestInvalid("format \(f) is not supported by this SDK (it reads format 3, the V4 folder)")
        }
        func str(_ k: String) throws(RecognizerError) -> String {
            guard let v = o[k] as? String, !v.isEmpty else { throw .manifestInvalid("\(k) missing") }
            return v
        }
        func int(_ k: String) throws(RecognizerError) -> Int {
            guard let v = integer(o[k]) else { throw .manifestInvalid("\(k) missing") }
            return Int(v)
        }
        guard let ctxs = o["contexts"] as? [String], !ctxs.isEmpty else { throw .manifestInvalid("contexts missing") }
        guard let list = o["files"] as? [[String: Any]], !list.isEmpty else { throw .manifestInvalid("files missing") }
        var files: [File] = []
        for e in list {
            guard let path = e["path"] as? String, let size = integer(e["size"]),
                  let sha = e["sha256"] as? String, isHex64(sha), let role = e["role"] as? String, !role.isEmpty,
                  let needRaw = e["need"] as? String, let need = Need(rawValue: needRaw) else {
                throw .manifestInvalid("a file entry lacks path, size, sha256, role or need")
            }
            let platforms: [String]
            if let s = e["platforms"] as? String, s == "*" {
                platforms = [s]
            } else if let a = e["platforms"] as? [String], !a.isEmpty, a.allSatisfy({ platformOrder.contains($0) }) {
                platforms = a
            } else {
                throw .manifestInvalid("\(path): platforms missing")
            }
            guard let soc = e["soc"] as? String, !soc.isEmpty, let context = e["context"] as? String, !context.isEmpty else {
                throw .manifestInvalid("\(path): soc or context missing")
            }
            guard let encoding = e["encoding"] as? String, encoding == "identity" || encoding == "gzip" else {
                throw .manifestInvalid("\(path): encoding")
            }
            var decoded: Decoded?
            if encoding == "gzip" {
                guard let d = e["decoded"] as? [String: Any], let dp = d["path"] as? String,
                      let ds = integer(d["size"]), let dh = d["sha256"] as? String, isHex64(dh) else {
                    throw .manifestInvalid("\(path): gzip without its decoded path, size and sha256")
                }
                decoded = Decoded(path: dp, size: ds, sha256: dh.lowercased())
            }
            files.append(File(path: path, size: size, sha256: sha, platforms: platforms, soc: soc, context: context, role: role, need: need,
                              encoding: encoding, decoded: decoded))
        }
        var m = ModelManifest(modelID: try str("model_id"), family: try str("family"), revision: try str("revision"), version: "",
                              minSDKVersion: try str("min_sdk_version"), engineFormat: try int("engine_format"),
                              coremlFormat: try int("coreml_format"), tokens: try str("tokens"),
                              tokensSHA256: try str("tokens_sha256"), defaultContext: try str("default_context"),
                              contexts: ctxs, files: files, signature: o["signature"] as? String)
        guard ModelVersion.isVersion(m.minSDKVersion) else { throw .manifestInvalid("min_sdk_version \(m.minSDKVersion) is not a version") }
        guard isHex64(m.tokensSHA256) else { throw .manifestInvalid("tokens_sha256 is not a SHA-256") }
        if let v = o["version"] {
            guard let s = v as? String, ModelVersion.isVersion(s) else { throw .manifestInvalid("version is not x.y.z") }
            m.version = s
        }
        if let t = o["golden_tolerance"] { m.goldenToleranceField = JSONValue(any: t) }
        if let t = o["golden_raw_tolerance"] { m.goldenRawField = JSONValue(any: t) }
        m.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        m.raw = data
        try m.checkPaths()
        return m
    }

    /// manifest.json for this manifest (sorted keys; the signature is over `signedText`, so formatting is free).
    func jsonData() -> Data {
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
        if !version.isEmpty { o["version"] = version }
        if let signature { o["signature"] = signature }
        if let t = goldenToleranceField { o["golden_tolerance"] = t.any }
        if let t = goldenRawField { o["golden_raw_tolerance"] = t.any }
        return (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    func write(to directory: URL) throws(RecognizerError) {
        do { try (raw ?? jsonData()).write(to: directory.appendingPathComponent(Self.fileName), options: StorageProtection.atomic) } catch {
            throw .storageFailed("cannot write \(Self.fileName): \(error.localizedDescription)")
        }
    }

    static func read(_ directory: URL) throws(RecognizerError) -> ModelManifest {
        guard let data = try? StorageSeam.data(directory.appendingPathComponent(fileName)) else {
            throw .modelMissing("no \(fileName) in \(directory.lastPathComponent)")
        }
        return try parse(data)
    }

    // MARK: signature

    /// The platforms field of the signed text: `*`, or the listed ones in the order android, apple, web, native.
    static func platformField(_ p: [String]) -> String {
        p.contains("*") ? "*" : platformOrder.filter { p.contains($0) }.joined(separator: ",")
    }

    /// The text the signature covers (UTF-8, every line ends with one LF):
    ///
    ///     quranlab-model-manifest 3
    ///     model_id v4.0
    ///     family tajweedformer
    ///     revision <rev>
    ///     version 4.0.0                                  only when the manifest has the field
    ///     min_sdk_version 3.0.0
    ///     engine_format 3
    ///     coreml_format 9
    ///     tokens tokens.txt
    ///     tokens_sha256 <hex>
    ///     default_context c16_l64
    ///     contexts c16_l64,c24_l72,c24_l256
    ///     golden_tolerance <build> <token_diffs> <site_flag_diffs> <word_flag_diffs>      2.x; one per build
    ///     golden_raw <build> <head> token_edits=<int> lp_mean=<num> lp_p99=<num>          one per build and CTC head
    ///     golden_raw <build> attr p_mean=<num>
    ///     file <sha256> <size> <path> <platforms> <soc> <context> <role> <need> <encoding> <dsha256> <dsize> <dpath>
    ///
    /// The tolerance lines only for well-formed entries, sorted by the bytes of the build key (then the head); the
    /// file lines sorted by the stored path's bytes; `- - -` for the decoded fields of an identity file.
    func signedText(tolerance: Bool = true, raw: Bool = true) -> String {
        var s = "quranlab-model-manifest 3\n"
        s += "model_id \(modelID)\nfamily \(family)\nrevision \(revision)\n"
        if !version.isEmpty { s += "version \(version)\n" }
        s += "min_sdk_version \(minSDKVersion)\n"
        s += "engine_format \(engineFormat)\ncoreml_format \(coremlFormat)\ntokens \(tokens)\ntokens_sha256 \(tokensSHA256)\n"
        s += "default_context \(defaultContext)\ncontexts \(contexts.joined(separator: ","))\n"
        if tolerance { for line in GoldenRawTolerance.legacyLines(goldenToleranceField) { s += line + "\n" } }
        if raw { for line in GoldenRawTolerance.parse(goldenRawField).lines { s += line + "\n" } }
        for f in files.sorted(by: { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }) {
            let d = f.isGzip ? f.decoded : nil
            s += "file \(f.sha256) \(f.size) \(f.path) \(Self.platformField(f.platforms)) \(f.soc) \(f.context) "
            s += "\(f.role) \(f.need.rawValue) \(f.encoding) \(d?.sha256 ?? "-") \(d.map { String($0.size) } ?? "-") \(d?.path ?? "-")\n"
        }
        return s
    }

    var signedMessage: Data { Data(signedText().utf8) }

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

    /// Whether `version` is at or above `minimum`; false when either is not a version.
    static func version(_ version: String, isAtLeast minimum: String) -> Bool {
        guard let a = ModelVersion(version), let b = ModelVersion(minimum) else { return false }
        return a >= b
    }

    /// The model can run in this SDK: it is a build with a version (a 2.x build has none), its minimum SDK version is
    /// not above this SDK's, and the engine format and the family are the ones this SDK reads.
    func checkCompatible(sdkVersion: String = SDKInfo.version) throws(RecognizerError) {
        guard !version.isEmpty else {
            throw .modelIncompatible("\(modelID) \(revision) is a build for SDK 2.x (its manifest names no version)")
        }
        guard Self.version(sdkVersion, isAtLeast: minSDKVersion) else {
            throw .modelIncompatible("\(modelID) \(version) needs SDK \(minSDKVersion) or newer (this is \(sdkVersion))")
        }
        guard engineFormat == Self.engineFormat else {
            throw .modelIncompatible("engine format \(engineFormat) is not the one this SDK reads (\(Self.engineFormat))")
        }
        guard family == "tajweedformer" else { throw .modelIncompatible("family \(family) is not TajweedFormer") }
    }

    /// What SDK 3.0.0 does with a manifest.json, in this order (the first check that fails decides the error):
    /// 1. a config named the build: the SHA-256 of the bytes starts with it, else `checksumMismatch`;
    /// 2. the bytes are a format 3 manifest, else `manifestInvalid`;
    /// 3. the signature verifies with a trusted key, else `signatureInvalid`;
    /// 4. the manifest has a version, and 5. its `min_sdk_version` is not above the SDK's, else `modelIncompatible`;
    /// 6. a config named the version: the manifest's is that one, else `manifestInvalid`.
    /// A folder opened without a config skips 1 and 6.
    static func accept(_ data: Data, verifier: ManifestVerifier, build: String? = nil, version: String? = nil,
                       sdkVersion: String = SDKInfo.version) throws(RecognizerError) -> ModelManifest {
        if let build {
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard build.count == 40, sha.hasPrefix(build.lowercased()) else { throw .checksumMismatch(file: fileName) }
        }
        let m = try verifier.verifySignature(try parse(data), required: true)
        try m.checkCompatible(sdkVersion: sdkVersion)
        if let version, m.version != version {
            throw .manifestInvalid("the manifest is version \(m.version), the config names \(version)")
        }
        return m
    }

    // MARK: lookups

    func file(local path: String) -> File? { files.first { $0.localPath == path } }
    func files(role: String) -> [File] { files.filter { $0.role == role } }

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
struct ManifestVerifier: Sendable {
    /// Raw 32-byte Ed25519 public keys a signature may verify against.
    let trustedKeys: [Data]
    /// Refuse a manifest without a signature. Always on outside tests: SDK 3.0.0 opens only signed model folders.
    let requireSignature: Bool

    init(trustedKeys: [Data], requireSignature: Bool) {
        self.trustedKeys = trustedKeys
        self.requireSignature = requireSignature
    }

    /// Quran Lab's manifest signing key (the public half of qlab-cdn's and qlab-api's MANIFEST_SIGNING_KEY, key id
    /// 660a07197c4808da). Signs the CDN file list, model manifests and the per-app config.
    static let quranLabPublicKey = Data([
        0xfc, 0x02, 0xfb, 0xd9, 0x06, 0x60, 0x8e, 0xbc, 0x20, 0x6a, 0x37, 0x1d, 0x8e, 0x61, 0xc1, 0x06, 0x2e, 0xa5, 0x55, 0x77, 0x8b, 0x44, 0xb1, 0xac, 0x83, 0x40, 0x61, 0x04, 0x3a, 0xee, 0x4a, 0x33
    ])

    /// The verifier of the configuration in force: its trusted keys, a signature always required.
    static var standard: ManifestVerifier {
        let o = QuranLab.configuration.options
        return ManifestVerifier(trustedKeys: (o.cloud ?? CloudOptions()).signingKeys, requireSignature: true)
    }

    /// Checks the signature and returns the manifest as trusted. Up to four texts are tried, in this order, and the
    /// first on which the signature verifies decides which tolerance fields it covers: with the `golden_tolerance`
    /// and the `golden_raw` lines; without the `golden_raw` lines (`golden_raw_tolerance` then counts as absent);
    /// without the `golden_tolerance` lines; without both. So a tampered tolerance value is a refused manifest, and a
    /// manifest signed without the lines loads with tokens-only golden tests. A signature that is not base64 of 64
    /// bytes is refused; a manifest without one is refused when `required` (or the verifier requires it).
    @discardableResult
    func verifySignature(_ m: ModelManifest, required: Bool = false) throws(RecognizerError) -> ModelManifest {
        guard let sig = m.signature else {
            if required || requireSignature { throw .signatureInvalid }
            var unsigned = m
            unsigned.goldenRaw = [:]
            return unsigned
        }
        guard let raw = Data(base64Encoded: sig), raw.count == 64 else { throw .signatureInvalid }
        let keys = trustedKeys.compactMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        var tried = Set<String>()
        for (withTolerance, withRaw) in [(true, true), (true, false), (false, true), (false, false)] {
            let text = m.signedText(tolerance: withTolerance, raw: withRaw)
            guard tried.insert(text).inserted else { continue }
            let message = Data(text.utf8)
            guard keys.contains(where: { $0.isValidSignature(raw, for: message) }) else { continue }
            var trusted = m
            trusted.goldenToleranceSigned = withTolerance && m.goldenToleranceField?.object != nil
            trusted.goldenRawSigned = withRaw && m.goldenRawField?.object != nil
            trusted.goldenRaw = trusted.goldenRawSigned ? GoldenRawTolerance.parse(m.goldenRawField).good : [:]
            return trusted
        }
        throw .signatureInvalid
    }
}
