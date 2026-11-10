import Foundation

/// A verified TajweedFormer V4 model folder (`sdk/v4.0`, manifest format 3, folder layout v2): calibration.json, the
/// tj3 tokens, the expected table, the CPU engine's files and, on iOS 18 / macOS 15, the CoreML package. Every file
/// on disk was checked against the manifest (size and SHA-256 of the decoded file) when the folder was opened; a file
/// the manifest does not list is never opened.
public struct TajweedModel: Sendable {
    /// One CoreML build of a context: the package (multifunction: functions `front_<ctx>` / `back_<ctx>`; a
    /// single-context package: `front` / `back`) and the context's keep table.
    public struct CoreMLBuild: Sendable, Hashable {
        public let package: URL
        public let keeps: URL
        public let context: String
        public let frontFunction: String
        public let backFunction: String
        /// The compact (int8) build.
        public let compact: Bool
    }

    public let id: ModelID
    public let directory: URL
    public let manifest: ModelManifest
    public let calibration: TajweedCalibration
    public let vocabulary: Vocabulary
    /// Local paths whose size and SHA-256 matched the manifest at open.
    public let verifiedFiles: Set<String>
    /// Why the folder's CoreML files are not usable, when it has some that are not.
    public let coreMLProblem: String?

    public var revision: String { manifest.revision }
    /// The contexts calibration.json describes, the default first.
    public var contexts: [String] { calibration.contexts }

    /// The model's identity in analytics and issue reports: the CDN revision it came from when downloaded, else the
    /// manifest's revision.
    public var identity: String {
        let s = (try? String(contentsOf: directory.appendingPathComponent(".source"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let s, !s.isEmpty, s.count <= 64 { return s }
        return revision
    }

    /// Whether the CPU engine can run `context` from what is on disk (every required file of the context's CPU set).
    public func isUsable(context: String) -> Bool {
        guard contexts.contains(context) else { return false }
        let need = DownloadProfile(context: context, coreML: false).cpuFiles(manifest)
        return !need.isEmpty && need.allSatisfy { verifiedFiles.contains($0.localPath) }
    }

    /// The contexts the CPU engine can run now.
    public var usableContexts: [String] { contexts.filter { isUsable(context: $0) } }

    /// The CPU engine's folder of a context (`<context>/`, holding model_engine2.onnx.zfg and its data), when the
    /// context is usable.
    public func engineDirectory(context: String) -> URL? {
        isUsable(context: context) ? directory.appendingPathComponent(context, isDirectory: true) : nil
    }

    /// The CoreML build for `context`, when the folder has a verified one on disk: the default (fp16) build preferred
    /// over the compact (int8) one, the multifunction package (context `*`) over a context's own package. Always nil for
    /// a CPU-only context (`ModelContexts`).
    public func coreML(context: String) -> CoreMLBuild? {
        guard !ModelContexts.isCPUOnly(context), coreMLProblem == nil, contexts.contains(context) else { return nil }
        guard let keeps = manifest.files.first(where: { $0.role == "coreml-keeps" && $0.context == context }),
              verifiedFiles.contains(keeps.localPath) else { return nil }
        for (role, scope) in [("coreml", "*"), ("coreml", context), ("coreml-compact", "*"), ("coreml-compact", context)] {
            let files = manifest.files.filter { $0.role == role && $0.context == scope }
            guard let pkg = Self.packages(files).first else { continue }
            let inPkg = files.filter { $0.localPath.hasPrefix(pkg + "/") }
            guard !inPkg.isEmpty, inPkg.allSatisfy({ verifiedFiles.contains($0.localPath) }) else { continue }
            let multi = scope == "*"
            return CoreMLBuild(package: directory.appendingPathComponent(pkg), keeps: directory.appendingPathComponent(keeps.localPath),
                               context: context, frontFunction: multi ? "front_\(context)" : "front",
                               backFunction: multi ? "back_\(context)" : "back", compact: role == "coreml-compact")
        }
        return nil
    }

    /// The same model with `paths` counted as verified: files an install has just downloaded and checked against the
    /// manifest (the promotion pipeline's download stage), without hashing the folder again.
    /// `removing`: files the install deleted (the other CoreML build).
    func adding(verified paths: [String], removing gone: [String] = []) -> TajweedModel {
        TajweedModel(id: id, directory: directory, manifest: manifest, calibration: calibration, vocabulary: vocabulary,
                     verifiedFiles: verifiedFiles.subtracting(gone).union(paths), coreMLProblem: coreMLProblem)
    }

    static func packages(_ files: [ModelManifest.File]) -> [String] {
        Array(Set(files.compactMap { f -> String? in
            guard let r = f.localPath.range(of: ".mlmodelc/") else { return nil }
            return String(f.localPath[..<r.lowerBound]) + ".mlmodelc"
        })).sorted()
    }

    // MARK: loading

    /// Loads `id` from the configured sources (`QuranLab.Options.modelSource`, or `sources`): a folder, the app
    /// bundle, the SDK's store, or the CDN (this device's download profile, installed into the store). Verified.
    /// `context`: the context the app will run first (its CPU files must be there); nil for the portal's or the
    /// calibration's default.
    public static func load(_ id: ModelID = .recommended, sources: [ModelSource]? = nil,
                            context: String? = nil) async throws(RecognizerError) -> TajweedModel {
        let config = QuranLab.configuration
        let model = id.isRecommended ? RecommendedModel.resolve(config: QuranLab.cloud?.currentConfig, storage: config.storageDirectory) : id
        return try await ModelStore(config: config).resolve(model, sources: sources ?? config.options.modelSource, context: context)
    }

    /// The model in one folder (manifest.json and the decoded files), verified.
    public static func load(directory: URL) async throws(RecognizerError) -> TajweedModel {
        let verifier = ManifestVerifier.standard
        return try await detached { () throws(RecognizerError) in try open(directory: directory, verifier: verifier) }
    }

    /// Opens and verifies a folder: the manifest (signature when present or required, format 3, SDK version, engine
    /// format, tokens hash), then every listed file that is on disk. A CPU file that does not match refuses the folder;
    /// a CoreML file that does not match, or a file in the package the manifest does not list, only turns CoreML off.
    static func open(directory: URL, verifier: ManifestVerifier, expecting id: ModelID? = nil) throws(RecognizerError) -> TajweedModel {
        let read = try ModelManifest.read(directory)
        if let id, read.modelID != id.name { throw .modelMissing("\(directory.lastPathComponent) holds \(read.modelID), not \(id.name)") }
        let m = try verifier.verifySignature(read)
        try m.checkCompatible()
        guard let tok = m.file(local: m.tokens), tok.localSHA256 == m.tokensSHA256 else {
            throw .manifestInvalid("tokens_sha256 does not match \(m.tokens)")
        }
        var verified = Set<String>()
        var appleProblem: String?
        let fm = FileManager.default
        for f in m.files {
            let url = directory.appendingPathComponent(f.localPath)
            guard fm.fileExists(atPath: url.path) else { continue }
            let (size, sha) = try ModelManifest.digest(url)
            if size == f.localSize && sha == f.localSHA256 {
                verified.insert(f.localPath)
            } else if DownloadProfile.appleRoles.contains(f.role) {
                appleProblem = appleProblem ?? "\(f.localPath) does not match the manifest"
            } else {
                throw .checksumMismatch(file: f.localPath)
            }
        }
        for name in [m.tokens, "calibration.json", "expected_tj3.zfx"] where !verified.contains(name) {
            throw .modelMissing("\(name) is not in \(directory.lastPathComponent)")
        }
        // nothing unlisted may sit in a CoreML package, where CoreML would read it
        let listed = Set(m.files.map(\.localPath))
        for pkg in packages(m.files.filter { DownloadProfile.packageRoles.contains($0.role) }) where fm.fileExists(atPath: directory.appendingPathComponent(pkg).path) {
            for p in try filesUnder(directory, pkg) where !listed.contains(p) {
                appleProblem = appleProblem ?? "\(p) is in the CoreML package but not in the manifest"
            }
        }
        let vocab = try Vocabulary(tokensFile: directory.appendingPathComponent(m.tokens))
        guard vocab.count == 38, vocab.blank == 0 else {
            throw .manifestInvalid("tokens.txt has \(vocab.count) tokens, blank \(vocab.blank); V4 is tj3, 38, blank 0")
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("calibration.json")) else {
            throw .modelMissing("calibration.json")
        }
        let cal = try TajweedCalibration(data: data)
        if let mid = cal.modelID, mid != m.modelID { throw .manifestInvalid("calibration.json is for \(mid), the folder is \(m.modelID)") }
        if let t = cal.tokensSHA256, t.count == 64, t.lowercased() != m.tokensSHA256 {
            throw .manifestInvalid("calibration.json was made for another tokens.txt")
        }
        guard Set(cal.contexts) == Set(m.contexts) else {
            throw .manifestInvalid("calibration.json's contexts \(cal.contexts) are not the manifest's \(m.contexts)")
        }
        let model = TajweedModel(id: id ?? ModelID(m.modelID, repository: ModelID.v4_0.repository), directory: directory,
                                 manifest: m, calibration: cal, vocabulary: vocab, verifiedFiles: verified,
                                 coreMLProblem: appleProblem)
        guard !model.usableContexts.isEmpty else {
            throw .modelMissing("no context of \(m.modelID) has all its CPU files in \(directory.lastPathComponent)")
        }
        return model
    }

    /// Every regular file under `directory/sub`, as paths relative to `directory`, sorted.
    static func filesUnder(_ directory: URL, _ sub: String) throws(RecognizerError) -> [String] {
        let root = directory.appendingPathComponent(sub).resolvingSymlinksInPath()
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw .modelMissing("\(sub) is not a directory")
        }
        func plain(_ p: String) -> String { p.hasPrefix("/private/") ? String(p.dropFirst(8)) : p }
        let rootPath = plain(root.path)
        let base = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var out: [String] = []
        for case let url as URL in e {
            let resolved = url.resolvingSymlinksInPath()
            guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let full = plain(url.path)
            guard full.hasPrefix(base) else { continue }
            out.append(sub + "/" + String(full.dropFirst(base.count)))
        }
        return out.sorted()
    }
}
