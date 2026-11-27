import Foundation

/// SDK 4.0.5: the owed record of a download of model files the app asked for, or the SDK started under
/// its own rules, that has not ended ready. Written atomically when the download starts, before its first request,
/// updated once its signed manifest verified and once a lease answer named its folder; removed only when the download
/// ends ready (`OwedDownloads.remove`), when the app removes the model files (`removeModels`: the records are in the
/// models folder and go with it), and when a refusal stops the model (the gate's removal of the models folder takes
/// them too). Everything else keeps it, and the next Client's start goes on with it (38.5): a failure, no network, the
/// app leaving, the process's end, the Client's close, a cancelled call.
///
/// What it holds: the model, the build, the context the call named, the kind and who asked, the build's folder as a
/// lease answer named it, and the signed manifest's bytes (verified again when read, never fetched again to resume).
/// No identifier, no URL with a key, no token. The files, their kept bytes and validators stay where 16.1 and 16.2 keep
/// them. The records live in `<models>/.owed/`, which is excluded from backups with the models folder (38.3 item 3).
struct OwedDownload: Codable, Sendable, Equatable {
    var v = 1
    var model: String
    var repository: String
    var folder: String
    var build: String
    var version: String?
    var keyID: String?
    /// The context the call named (nil: the config's, else the manifest's default).
    var context: String?
    /// `first_install`, `context`, `reference`, `update` or `accelerator` (38.2).
    var kind: String
    /// `app` or `sdk`.
    var by: String
    /// The download makes its build the one in use when it ends (a first install, the app's call).
    var activate: Bool
    /// The build's folder as a lease answer named it.
    var base: String?
    /// The signed manifest's bytes, base64.
    var manifest: String?
    /// SDK 4.0.5: which build of the kind, when it has more than one (`compact`: the Core ML build's compact one).
    var variant: String?

    init(id: ModelID, build: String, version: String?, keyID: String?, context: String?, kind: String, by: String, activate: Bool) {
        model = id.name
        repository = id.repository
        folder = id.folder
        self.build = build
        self.version = version
        self.keyID = keyID
        self.context = context
        self.kind = kind
        self.by = by
        self.activate = activate
    }

    var id: ModelID { ModelID(model, repository: repository, folder: folder) }

    /// The record's file name: one record per model, build, kind (and its variant) and context.
    var fileName: String {
        let raw = [model, build, kind + (variant.map { "-" + $0 } ?? ""), context ?? ""].joined(separator: "_")
        let safe = raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" ? Character($0) : "_" }
        return String(safe) + ".json"
    }

    /// The stored manifest, verified again (nil when there is none, or it does not verify: the resume fetches it).
    func manifest(verifier: ManifestVerifier) -> ModelManifest? {
        guard let s = manifest, let data = Data(base64Encoded: s) else { return nil }
        let isBuild = build.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil
        guard let m = try? ModelManifest.accept(data, verifier: verifier, build: isBuild ? build : nil, version: version),
              m.modelID == model else { return nil }
        return m
    }
}

enum OwedDownloads {
    /// Where the records are, under the store's models folder: a dot folder, which no listing of model ids takes for
    /// one (`ModelStore.removeOtherModels`, the gate's build folders).
    static func directory(_ root: URL) -> URL { root.appendingPathComponent(".owed", isDirectory: true) }

    /// Writes (or rewrites) a record, atomically.
    static func write(_ o: OwedDownload, root: URL) {
        let dir = directory(root)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(o) else { return }
        try? data.write(to: dir.appendingPathComponent(o.fileName), options: .atomic)
        ModelStore.excludeFromBackup(root)
    }

    /// The download ended ready (38.3: the one way besides a removal of the models and a stop).
    static func remove(_ o: OwedDownload, root: URL) {
        try? FileManager.default.removeItem(at: directory(root).appendingPathComponent(o.fileName))
    }

    /// The record stored under `o`'s name (the same model, build, kind and context), when there is one that reads.
    static func stored(_ o: OwedDownload, root: URL) -> OwedDownload? {
        guard let data = try? Data(contentsOf: directory(root).appendingPathComponent(o.fileName)) else { return nil }
        return try? JSONDecoder().decode(OwedDownload.self, from: data)
    }

    /// The records on the device; one that cannot be read is skipped (and left for a later SDK, never acted on).
    static func all(root: URL) -> [OwedDownload] {
        let dir = directory(root)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        return names.compactMap { name in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
            return try? JSONDecoder().decode(OwedDownload.self, from: data)
        }
    }

    /// The records of other builds of `id` for a first install or an update: their downloads were superseded (38.5
    /// item 6) when another build's download began.
    static func removeOther(_ id: ModelID, keeping build: String, root: URL) {
        for o in all(root: root) where o.model == id.name && o.build != build && (o.kind == "first_install" || o.kind == "update") {
            remove(o, root: root)
        }
    }

    /// 38.3 item 4: a download an earlier SDK left (a `.download-<build>` folder of `id` with this device's install
    /// record saying downloading) and no record of its own, read as the owed record of that build's CPU set, asked by
    /// the app.
    static func leftBy404(_ id: ModelID, store: ModelStore, known: [OwedDownload]) -> [OwedDownload] {
        let base = store.base(id)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).filter { $0.hasPrefix(".download-") }
        var out: [OwedDownload] = []
        for name in names.sorted() {
            let build = String(name.dropFirst(".download-".count))
            guard !build.isEmpty, !known.contains(where: { $0.model == id.name && $0.build == build }) else { continue }
            // the folder has no manifest while it downloads: its record is judged against the build its name gives
            guard case .own(.downloading) = InstallRecord.standing(of: base.appendingPathComponent(name), build: build, keys: store.installKeys) else { continue }
            let current = store.currentRevision(id)
            out.append(OwedDownload(id: id, build: build, version: nil, keyID: nil, context: nil,
                                    kind: current == nil ? "first_install" : "update", by: "app", activate: current == nil))
        }
        return out
    }

    /// 38.5 item 3: the app's downloads first (`first_install`, `context`, `reference`), then the SDK's (`update`,
    /// `accelerator`); records of one rank in the order they were read.
    static func ordered(_ owed: [OwedDownload]) -> [OwedDownload] {
        owed.enumerated().sorted {
            let a = ($0.element.by == "app" ? 0 : 1, ContinuityRules.kinds.firstIndex(of: $0.element.kind) ?? 9, $0.offset)
            let b = ($1.element.by == "app" ? 0 : 1, ContinuityRules.kinds.firstIndex(of: $1.element.kind) ?? 9, $1.offset)
            return a < b
        }.map { $0.element }
    }
}
