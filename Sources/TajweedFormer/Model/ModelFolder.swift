import Foundation

/// A verified TajweedFormer model folder of SDK 4.0 (`sdk/v4.0`, manifest format 3 with `encryption`): the signed
/// manifest, the device forms the Core wrote at install (ciphertext under a key of this install's lease), and the few
/// plain files the manifest keeps plain (calibration.json, the self-test clips), each checked against the manifest
/// when the folder was opened. The SDK never reads a model file: only the Core opens the device forms, from a lease.
/// The vocabulary is the SDK's own copy of the build's tokens.txt, chosen by the signed `tokens_sha256`.
struct ModelFolder: Sendable {
    /// One CoreML build of a context: the package (multifunction: functions `front_<ctx>` / `back_<ctx>`; a
    /// single-context package: `front` / `back`) and the context's keep table.
    struct CoreMLBuild: Sendable, Hashable {
        let package: URL
        let keeps: URL
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
        // unreadable is taken as not there here: the manifest's revision stands in
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
    /// the fp16 one first. The multifunction package (context `*`) comes before a context's own package. Always nil
    /// for a CPU-only context (`ModelContexts`).
    func coreML(context: String, compact: Bool? = nil) -> CoreMLBuild? {
        guard !ModelContexts.isCPUOnly(context), coreMLProblem == nil, manifest.contexts.contains(context) else { return nil }
        guard let keeps = manifest.files.first(where: { $0.role == "coreml-keeps" && $0.context == context }),
              verifiedFiles.contains(keeps.localPath) else { return nil }
        var order: [(String, String)] = []
        for role in ["coreml", "coreml-compact"] where compact == nil || compact == (role == "coreml-compact") {
            order += [(role, "*"), (role, context)]
        }
        for (role, scope) in order {
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

    /// Loads `id` from the configured sources (`QuranLab.Options.modelSource`, or `sources`): the SDK's store, or
    /// the CDN (this device's download profile, installed into the store). Verified.
    /// `context`: the context the app will run first (its CPU files must be there); nil for the config's or the
    /// manifest's default.
    static func load(_ id: ModelID = .recommended, sources: [ModelSource]? = nil,
                     context: String? = nil) async throws(RecognizerError) -> ModelFolder {
        let config = QuranLab.configuration
        let model = id.isRecommended ? RecommendedModel.resolve(config: QuranLab.cloud?.currentConfig, storage: config.storageDirectory) : id
        return try await ModelStore.standard.resolve(model, sources: sources ?? config.options.modelSource, context: context)
    }

    /// Opens and verifies a folder: the manifest (its signature, format 3, a version, the SDK version, the engine
    /// format, the tokens hash), then every listed file that is on disk. A CPU file that does not match refuses the
    /// folder; a CoreML file that does not match, or a file in the package the manifest does not list, only turns
    /// CoreML off. calibration.json and the reference table are data: the folder opens without them.
    /// `build` and `version`: what the signed config named, when the folder came from it.
    static func open(directory: URL, verifier: ManifestVerifier, expecting id: ModelID? = nil, build: String? = nil,
                     version: String? = nil) throws(RecognizerError) -> ModelFolder {
        guard let data = try? StorageSeam.data(directory.appendingPathComponent(ModelManifest.fileName)) else {
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
            if f.isEncrypted {
                // the device form, by its size; its records' tags are checked by the Core at every open
                if ModelInstaller.present(f, in: directory) { verified.insert(f.localPath) }
                continue
            }
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
        // SDK 4.0: accelerator programs are opened by the Core only (18.5.6), from their device forms; Core ML never reads
        // the folder, so nothing in it is refused for not being listed. Tried before (a397d40 to 9d16fe0): every folder
        // was given the problem "accelerator programs are opened by the Core", which made `coreML` nil for every build,
        // so the promotion's download stage refused every build (`verify`) and no Apple device was ever promoted.
        let vocab = try Vocabularies.vocabulary(sha256: m.tokensSHA256)
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

    /// The same folder with its accelerator files checked again from disk, as `open` checks them (an encrypted file by
    /// its device form's size, any other by size and SHA-256); the CPU files keep the verdict of `open`. The
    /// promotion's download stage judges the build by this, never by the problem `open` found before the download
    /// (SDK 3.1.5: to 3.1.4 an interrupted download's problem refused the download that had just set it right).
    func rechecked() throws(RecognizerError) -> ModelFolder {
        let fm = FileManager.default
        var verified = verifiedFiles
        var problem: String?
        for f in manifest.files where DownloadProfile.appleRoles.contains(f.role) {
            verified.remove(f.localPath)
            if f.isEncrypted {
                if ModelInstaller.present(f, in: directory) { verified.insert(f.localPath) }
                continue
            }
            let url = directory.appendingPathComponent(f.localPath)
            guard fm.fileExists(atPath: url.path) else { continue }
            let (size, sha) = try ModelManifest.digest(url)
            if size == f.localSize && sha == f.localSHA256 {
                verified.insert(f.localPath)
            } else {
                problem = problem ?? "\(f.localPath) does not match the manifest"
            }
        }
        return ModelFolder(id: id, directory: directory, manifest: manifest, vocabulary: vocabulary, verifiedFiles: verified,
                           coreMLProblem: problem)
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
