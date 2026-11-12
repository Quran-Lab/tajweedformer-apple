import Foundation

/// A verified TajweedFormer V4 model folder (`sdk/v4.0`, manifest format 3, folder layout v2): the tj3 tokens, the CPU
/// engine's files, calibration.json when the build ships it (data only), and, on iOS 18 / macOS 15, the CoreML
/// package. Every file on disk was checked against the signed manifest (size and SHA-256 of the decoded file) when the
/// folder was opened; a file the manifest does not list is never opened. A folder is one build of a model version.
struct ModelFolder: Sendable {
    /// One CoreML build of a context: the package (multifunction: functions `front_<ctx>` / `back_<ctx>`; a
    /// single-context package: `front` / `back`) and the context's keep table when the manifest lists one. A
    /// package that carries its keep table inside (it takes `keep_sel`) has none; which kind a package is, its own
    /// inputs say when it is loaded (`TajweedNeuralEngine`), never the manifest.
    struct CoreMLBuild: Sendable, Hashable {
        let package: URL
        let keeps: URL?
        let context: String
        let frontFunction: String
        let backFunction: String
        /// The compact (int8) build.
        let compact: Bool
    }

    let id: ModelID
    let directory: URL
    let manifest: ModelManifest
    let vocabulary: Vocabulary
    /// Local paths whose size and SHA-256 matched the manifest at open.
    let verifiedFiles: Set<String>
    /// Why the folder's CoreML files are not usable, when it has some that are not.
    let coreMLProblem: String?

    var revision: String { manifest.revision }
    /// The model's version, `4.0.0`.
    var version: String { manifest.version }
    /// The contexts the manifest lists, the default first.
    var contexts: [String] { [manifest.defaultContext] + manifest.contexts.filter { $0 != manifest.defaultContext } }

    /// The build id: the first 40 hex digits of the SHA-256 of the folder's manifest.json. It names the folder on the
    /// CDN, in telemetry and incident reports (next to the version) and in the promotion's key. A manifest made in
    /// memory (tests) has none: the CDN revision the folder came from stands in, else the manifest's revision.
    var build: String {
        if !manifest.build.isEmpty { return manifest.build }
        let s = (try? String(contentsOf: directory.appendingPathComponent(".source"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let s, !s.isEmpty, s.count <= 64 { return s }
        return revision
    }

    /// The build, under the name the promotion and the sharing recorder know it by.
    var identity: String { build }

    /// Whether the CPU engine can run `context` from what is on disk (every required file of the context's CPU set).
    func isUsable(context: String) -> Bool {
        guard manifest.contexts.contains(context) else { return false }
        let need = DownloadProfile(context: context, coreML: false).cpuFiles(manifest)
        return !need.isEmpty && need.allSatisfy { verifiedFiles.contains($0.localPath) }
    }

    /// The contexts the CPU engine can run now.
    var usableContexts: [String] { contexts.filter { isUsable(context: $0) } }

    /// The CPU engine's folder of a context (`<context>/`, holding model_engine2.onnx.zfg and its data), when the
    /// context is usable.
    func engineDirectory(context: String) -> URL? {
        isUsable(context: context) ? directory.appendingPathComponent(context, isDirectory: true) : nil
    }

    /// The CoreML build for `context`, when the folder has a verified one on disk. `compact` names the build: true
    /// the compact (int8) one, false the fp16 one, and neither stands in for the other; nil takes whichever is there,
    /// the fp16 one first. The multifunction package (context `*`) comes before a context's own package. Nil for a
    /// context the build does not serve (`ModelManifest.serving`, SPEC 5.4): the manifest decides, for every
    /// context. A keep table the manifest lists for the context must be on disk and verified too; a build whose
    /// manifest lists none for the context has none (`keeps` is nil).
    func coreML(context: String, compact: Bool? = nil) -> CoreMLBuild? {
        guard coreMLProblem == nil, manifest.contexts.contains(context) else { return nil }
        let keeps = manifest.files.first { $0.role == "coreml-keeps" && $0.context == context }
        if let keeps, !verifiedFiles.contains(keeps.localPath) { return nil }
        var order: [(String, String)] = []
        for role in ["coreml", "coreml-compact"] where compact == nil || compact == (role == "coreml-compact") {
            guard manifest.serving(build: role, context: context) != nil else { continue }
            order += [(role, "*"), (role, context)]
        }
        for (role, scope) in order {
            let files = manifest.files.filter { $0.role == role && $0.context == scope }
            guard let pkg = Self.packages(files).first else { continue }
            let inPkg = files.filter { $0.localPath.hasPrefix(pkg + "/") }
            guard !inPkg.isEmpty, inPkg.allSatisfy({ verifiedFiles.contains($0.localPath) }) else { continue }
            let multi = scope == "*"
            return CoreMLBuild(package: directory.appendingPathComponent(pkg), keeps: keeps.map { directory.appendingPathComponent($0.localPath) },
                               context: context, frontFunction: multi ? "front_\(context)" : "front",
                               backFunction: multi ? "back_\(context)" : "back", compact: role == "coreml-compact")
        }
        return nil
    }

    /// The build key of the CoreML build in the folder for `context` (`coreml` or `coreml-compact`), as the manifest's
    /// tolerances name it.
    func coreMLBuildKey(context: String) -> String {
        (coreML(context: context)?.compact ?? false) ? "coreml-compact" : "coreml"
    }

    /// The reference table's entry in the manifest (role `reference`), when the build ships one.
    var referenceFile: ModelManifest.File? { manifest.files(role: "reference").first }

    /// The same model with `paths` counted as verified: files an install has just downloaded and checked against the
    /// manifest (the promotion pipeline's download stage, the reference data), without hashing the folder again.
    /// `removing`: files the install deleted (a correction left by an earlier SDK).
    func adding(verified paths: [String], removing gone: [String] = []) -> ModelFolder {
        ModelFolder(id: id, directory: directory, manifest: manifest, vocabulary: vocabulary,
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
    /// `context`: the context the app will run first (its CPU files must be there); nil for the config's or the
    /// manifest's default.
    static func load(_ id: ModelID = .recommended, sources: [ModelSource]? = nil,
                     context: String? = nil) async throws(RecognizerError) -> ModelFolder {
        let config = QuranLab.configuration
        let model = id.isRecommended ? RecommendedModel.resolve(config: QuranLab.cloud?.currentConfig, storage: config.storageDirectory) : id
        return try await ModelStore(config: config).resolve(model, sources: sources ?? config.options.modelSource, context: context)
    }

    /// The model in one folder (manifest.json and the decoded files), verified.
    static func load(directory: URL) async throws(RecognizerError) -> ModelFolder {
        let verifier = ManifestVerifier.standard
        return try await detached { () throws(RecognizerError) in try open(directory: directory, verifier: verifier) }
    }

    /// Opens and verifies a folder: the manifest (its signature, format 3, a version, the SDK version, the engine
    /// format, the tokens hash), then every listed file that is on disk. A CPU file that does not match refuses the
    /// folder; a CoreML file that does not match, or a file in the package the manifest does not list, only turns
    /// CoreML off. calibration.json and the reference table are data: the folder opens without them.
    /// `build` and `version`: what the signed config named, when the folder came from it.
    static func open(directory: URL, verifier: ManifestVerifier, expecting id: ModelID? = nil, build: String? = nil,
                     version: String? = nil) throws(RecognizerError) -> ModelFolder {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(ModelManifest.fileName)) else {
            throw .modelMissing("no \(ModelManifest.fileName) in \(directory.lastPathComponent)")
        }
        let m: ModelManifest
        if verifier.requireSignature {
            m = try ModelManifest.accept(data, verifier: verifier, build: build, version: version)
        } else {
            // tests only: a folder staged without a signature
            m = try verifier.verifySignature(try ModelManifest.parse(data))
            try m.checkCompatible()
        }
        if let id, m.modelID != id.name { throw .modelMissing("\(directory.lastPathComponent) holds \(m.modelID), not \(id.name)") }
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
        guard verified.contains(m.tokens) else { throw .modelMissing("\(m.tokens) is not in \(directory.lastPathComponent)") }
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
        let model = ModelFolder(id: id ?? ModelID(m.modelID, repository: ModelID.v4_0.repository), directory: directory,
                                manifest: m, vocabulary: vocab, verifiedFiles: verified, coreMLProblem: appleProblem)
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
