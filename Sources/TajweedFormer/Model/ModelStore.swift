import Foundation

/// Resolves a model in the configured order and keeps the SDK's own copies.
///
/// The store lives in `<storage>/models/<model>/`: one folder per revision (only this device's download profile in
/// it), a `current` pointer file naming the one in use and `previous` the one before. A download goes to
/// `.download-<cdn revision>` (kept across launches, so it resumes), is verified, then renamed into place and the
/// pointer switched with an atomic write: a crash at any point leaves the old revision in use.
struct ModelStore: Sendable {
    let root: URL
    let verifier: ManifestVerifier
    let updates: UpdatePolicy

    init(config: QuranLab.Configuration) {
        root = config.storageDirectory.appendingPathComponent("models")
        verifier = .standard
        updates = config.options.updates
    }

    init(root: URL, verifier: ManifestVerifier, updates: UpdatePolicy = .automatic) {
        self.root = root
        self.verifier = verifier
        self.updates = updates
    }

    /// The store the SDK uses by default.
    static var standard: ModelStore { ModelStore(config: QuranLab.configuration) }

    func resolve(_ id: ModelID, sources: [ModelSource], context: String?) async throws(RecognizerError) -> ModelFolder {
        var firstFailure: RecognizerError?
        var order = sources
        // with updates on, the store's copy (the newest the updater installed) wins over the copy bundled at install
        if updates != .manual, let c = order.firstIndex(of: .cache), let b = order.firstIndex(of: .bundle), b < c {
            order.remove(at: c)
            order.insert(.cache, at: b)
        }
        if order.contains(.cache) { _ = try? activatePending(id) }
        for source in order {
            do throws(RecognizerError) {
                if let model = try await load(id, from: source, context: context) { return model }
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        throw firstFailure ?? .modelMissing("\(id) is in none of \(sources)")
    }

    /// The model from one source, or nil when that source does not have it (or not the context asked for).
    func load(_ id: ModelID, from source: ModelSource, context: String?) async throws(RecognizerError) -> ModelFolder? {
        let verifier = self.verifier
        func usable(_ m: ModelFolder?) -> ModelFolder? {
            guard let m else { return nil }
            if let context, !m.isUsable(context: context) { return nil }
            return m
        }
        switch source {
        case .directory(let url):
            return usable(try await Self.verified(url, id, verifier))
        case .bundle:
            guard let res = Bundle.main.resourceURL else { return nil }
            return usable(try await Self.verified(res.appendingPathComponent("QuranLabModels").appendingPathComponent(id.name), id, verifier))
        case .cache:
            guard let dir = cachedDirectory(id) else { return nil }
            return usable(try await Self.verified(dir, id, verifier))
        case .cdn:
            guard let cloud = QuranLab.cloud else { return nil }
            let outcome = await cloud.install(id, context: context, activate: true)
            guard case .installed(let m, _) = outcome else {
                if case .failed(let e) = outcome { throw e }
                return nil
            }
            return usable(m)
        }
    }

    private static func verified(_ dir: URL, _ id: ModelID, _ verifier: ManifestVerifier) async throws(RecognizerError) -> ModelFolder? {
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(ModelManifest.fileName).path) else { return nil }
        return try await detached { () throws(RecognizerError) in try ModelFolder.open(directory: dir, verifier: verifier, expecting: id) }
    }

    func base(_ id: ModelID) -> URL { root.appendingPathComponent(id.name) }

    /// The cached revision to use: the pinned one if pinned, else `current`.
    func cachedDirectory(_ id: ModelID) -> URL? {
        let revision: String?
        if case .pinned(let r) = updates { revision = r } else { revision = pointer(base(id), "current") }
        guard let revision, Self.safeName(revision) else { return nil }
        let dir = base(id).appendingPathComponent(revision)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    static func safeName(_ s: String) -> Bool {
        !s.isEmpty && !s.contains("/") && !s.hasPrefix(".") && !["current", "previous", "pending"].contains(s)
    }

    /// The download folder for a CDN revision (kept across launches so a download resumes).
    func downloadFolder(_ id: ModelID, cdnRevision: String) -> URL {
        base(id).appendingPathComponent(".download-" + cdnRevision.filter { $0.isLetter || $0.isNumber || "._-+".contains($0) })
    }

    /// Moves a completed download into the store as revision `manifest.revision`, verifies it there, and returns it.
    /// The CDN revision travels with it in `.source`.
    func place(_ folder: URL, id: ModelID, cdnRevision: String?) throws(RecognizerError) -> ModelFolder {
        let m = try ModelManifest.read(folder)
        guard Self.safeName(m.revision) else { throw .manifestInvalid("bad revision name") }
        let fm = FileManager.default
        let final = base(id).appendingPathComponent(m.revision)
        if let cdnRevision { try? Data(cdnRevision.utf8).write(to: folder.appendingPathComponent(".source")) }
        // download leftovers never travel with a model
        if let e = fm.enumerator(atPath: folder.path) {
            var parts: [String] = []
            while let p = e.nextObject() as? String { if p.hasSuffix(".part") || p.hasPrefix(".rebuild") { parts.append(p) } }
            for p in parts { try? fm.removeItem(at: folder.appendingPathComponent(p)) }
        }
        do {
            if fm.fileExists(atPath: final.path) {
                if pointer(base(id), "current") == m.revision {
                    // the same revision is in use: keep it, add any file it lacks (another context)
                    for f in m.files {
                        let src = folder.appendingPathComponent(f.localPath), dst = final.appendingPathComponent(f.localPath)
                        guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
                        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: src, to: dst)
                    }
                    try? fm.removeItem(at: folder)
                } else {
                    try fm.removeItem(at: final)
                    try fm.moveItem(at: folder, to: final)
                }
            } else {
                try fm.moveItem(at: folder, to: final)
            }
        } catch {
            throw .storageFailed("cannot place the model: \(error.localizedDescription)")
        }
        return try ModelFolder.open(directory: final, verifier: verifier, expecting: id)
    }

    func pointer(_ base: URL, _ name: String) -> String? {
        let v = (try? String(contentsOf: base.appendingPathComponent(name), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let v, Self.safeName(v) else { return nil }
        return v
    }

    /// Makes `revision` current (the old current becomes previous) and drops everything else but a pending revision
    /// and resumable downloads.
    func activate(_ id: ModelID, revision: String) throws(RecognizerError) {
        let b = base(id)
        do {
            if let old = pointer(b, "current"), old != revision {
                try Data(old.utf8).write(to: b.appendingPathComponent("previous"), options: .atomic)
            }
            try Data(revision.utf8).write(to: b.appendingPathComponent("current"), options: .atomic)
            if pointer(b, "pending") == revision { try? FileManager.default.removeItem(at: b.appendingPathComponent("pending")) }
        } catch {
            throw .storageFailed("cannot activate the model: \(error.localizedDescription)")
        }
        prune(id)
    }

    /// Keeps current, previous and pending; removes other revisions (downloads in progress stay).
    func prune(_ id: ModelID) {
        let fm = FileManager.default
        let b = base(id)
        var keep: Set<String> = ["current", "previous", "pending"]
        for p in ["current", "previous", "pending"] { if let r = pointer(b, p) { keep.insert(r) } }
        for name in (try? fm.contentsOfDirectory(atPath: b.path)) ?? [] where !keep.contains(name) && !name.hasPrefix(".download-") {
            try? fm.removeItem(at: b.appendingPathComponent(name))
        }
    }

    /// Removes the store folders of every model id but the one in use, and returns their names. `model` is the
    /// model in use: a verified folder (every `ModelFolder` is) that is the `current` revision of its id in this
    /// store. Until 3.0.2 nothing removed another id's folders, so after a move to another model id the old one's
    /// files (hundreds of megabytes) stayed for ever.
    /// The rules, each with its test (ModelStoreOtherIDsTests):
    /// - only folders of this store that are model folders as the store makes them (`isStoreFolder`); a file, or a
    ///   folder that holds anything else, is left alone, and so is `recommended.json`;
    /// - never before the model in use is verified and current: a model that is not the `current` revision of its
    ///   id here (a staged one, a bundled one, a folder the app opened itself) removes nothing, so a failed or
    ///   unverified install of a new id leaves the old id whole;
    /// - the id in use is not touched: its `current`, its `previous` and a pending revision stay;
    /// - an install that is pinned (`UpdatePolicy.pinned`; a version pin is the caller's to check) stays as it is.
    @discardableResult
    func removeOtherModels(inUse model: ModelFolder) -> [String] {
        if case .pinned = updates { return [] }
        let fm = FileManager.default
        let id = model.id
        guard let current = currentRevision(id),
              model.directory.resolvingSymlinksInPath().path == base(id).appendingPathComponent(current).resolvingSymlinksInPath().path else {
            return []
        }
        var removed: [String] = []
        for name in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted() where name != id.name && !name.hasPrefix(".") {
            let other = root.appendingPathComponent(name)
            guard Self.isStoreFolder(other) else { continue }
            if (try? fm.removeItem(at: other)) != nil { removed.append(name) }
        }
        return removed
    }

    /// Whether `dir` is a model id's folder as this store makes one: a folder that holds nothing but the pointer
    /// files (`current`, `previous`, `pending`), resumable downloads (`.download-<revision>`) and revision folders
    /// with a manifest.json, and at least one revision or download. Anything else in it (a file the store does not
    /// write, a folder without a manifest) makes it not the store's, and it is left alone.
    static func isStoreFolder(_ dir: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
              let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        var models = 0
        for name in names where name != ".DS_Store" {
            var sub: ObjCBool = false
            let item = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: item.path, isDirectory: &sub) else { return false }
            if ["current", "previous", "pending"].contains(name) {
                if sub.boolValue { return false }
                continue
            }
            guard sub.boolValue else { return false }
            if name.hasPrefix(".download-") {
                models += 1
                continue
            }
            guard fm.fileExists(atPath: item.appendingPathComponent(ModelManifest.fileName).path) else { return false }
            models += 1
        }
        return models > 0
    }

    func currentRevision(_ id: ModelID) -> String? { pointer(base(id), "current") }
    func previousRevision(_ id: ModelID) -> String? { pointer(base(id), "previous") }

    func pendingRevision(_ id: ModelID) -> String? {
        guard let r = pointer(base(id), "pending"), FileManager.default.fileExists(atPath: base(id).appendingPathComponent(r).path) else { return nil }
        return r
    }

    /// The CDN revision a stored revision was downloaded from.
    func sourceRevision(_ id: ModelID, revision: String) -> String? {
        (try? String(contentsOf: base(id).appendingPathComponent(revision).appendingPathComponent(".source"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Marks a staged, verified revision to become current at the next load.
    func markPending(_ id: ModelID, revision: String) throws(RecognizerError) {
        do { try Data(revision.utf8).write(to: base(id).appendingPathComponent("pending"), options: .atomic) } catch {
            throw .storageFailed("cannot mark \(revision) pending: \(error.localizedDescription)")
        }
    }

    /// Activates the pending revision, if any. Returns the new current revision.
    @discardableResult
    func activatePending(_ id: ModelID) throws(RecognizerError) -> String? {
        guard let r = pendingRevision(id) else { return nil }
        try activate(id, revision: r)
        return r
    }

    /// Goes back to the previous revision (after the new one failed where it is used). The failed one is removed.
    func rollback(_ id: ModelID) throws(RecognizerError) {
        let b = base(id)
        guard let prev = pointer(b, "previous"), FileManager.default.fileExists(atPath: b.appendingPathComponent(prev).path) else {
            throw .modelMissing("no previous revision of \(id) to go back to")
        }
        let failed = pointer(b, "current")
        do {
            try Data(prev.utf8).write(to: b.appendingPathComponent("current"), options: .atomic)
            try? FileManager.default.removeItem(at: b.appendingPathComponent("previous"))
        } catch {
            throw .storageFailed("cannot roll back: \(error.localizedDescription)")
        }
        if let failed, failed != prev { try? FileManager.default.removeItem(at: b.appendingPathComponent(failed)) }
        prune(id)
    }
}
