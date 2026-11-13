import Foundation

/// Resolves a model in the configured order and keeps the SDK's own copies.
///
/// The store lives in `<storage>/models/<model>/`: one folder per revision (only this device's download profile in
/// it), a `current` pointer file naming the one in use and `previous` the one before. A download goes to
/// `.download-<cdn revision>` (kept across launches, so it resumes), is verified, then renamed into place and the
/// pointer switched with an atomic write: a crash at any point leaves the old revision in use.
///
/// Since 3.1.0 the store opens only a build this Client downloaded itself (the install record, `InstallRecord`):
/// a revision folder without a valid record of this device is not opened, it is deleted, and the build is
/// downloaded. The app bundle is no longer a source of a model (`QuranLabModels/<model id>/` was, to 3.0.1).
struct ModelStore: Sendable {
    let root: URL
    let verifier: ManifestVerifier
    let updates: UpdatePolicy
    /// Where the device key of the install record lives.
    let installKeys: any InstallKeyStoring

    init(config: QuranLab.Configuration) {
        root = config.storageDirectory.appendingPathComponent("models")
        verifier = .standard
        updates = config.options.updates
        installKeys = KeychainInstallKeyStore()
    }

    init(root: URL, verifier: ManifestVerifier, updates: UpdatePolicy = .automatic,
         installKeys: any InstallKeyStoring = KeychainInstallKeyStore()) {
        self.root = root
        self.verifier = verifier
        self.updates = updates
        self.installKeys = installKeys
    }

    /// The store of the Client in force: its server client's (with that client's key store), else one over the
    /// configuration.
    static var standard: ModelStore { QuranLab.cloud?.store ?? ModelStore(config: QuranLab.configuration) }

    func resolve(_ id: ModelID, sources: [ModelSource], context: String?) async throws(RecognizerError) -> ModelFolder {
        var firstFailure: RecognizerError?
        let order = sources
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
        case .cache:
            // only a build this Client downloaded itself: anything else in the store is deleted here, and the caller
            // downloads the build
            guard let dir = try ownedDirectory(id, discard: true) else { return nil }
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

    // MARK: the install record

    /// How a revision folder of this store stands to this Client: its own when it holds a valid install record of
    /// this device for the build its manifest.json is. The key store is asked first.
    func standing(of dir: URL) -> InstallStanding {
        if case .failed(let why) = installKeys.load() { return .keyStoreFailed(why) }
        switch InstallRecord.storedBuild(dir) {
        case .missing: return .notOwn("the folder has no manifest")
        // a manifest that is there and cannot be read is not "no manifest" (3.1.4)
        case .unreadable(let why): return .unreadable(why.why)
        case .value(let build): return InstallRecord.standing(of: dir, build: build, keys: installKeys)
        }
    }

    /// The cached revision's folder when it is this Client's own finished download; nil when there is none. A
    /// folder that is not the Client's is deleted with `discard` (its pointer files with it), never opened. A key
    /// store that fails throws `storageFailed`: nothing is opened and nothing is deleted.
    func ownedDirectory(_ id: ModelID, discard: Bool) throws(RecognizerError) -> URL? {
        // one at a time with `putInPlace`: a folder is judged and deleted in one step, so the download that the
        // launch's update check has just put in place is never the one deleted
        Self.ownership.lock()
        defer { Self.ownership.unlock() }
        guard let dir = cachedDirectory(id) else { return nil }
        switch standing(of: dir) {
        case .own(.installed):
            return dir
        case .keyStoreFailed(let why):
            throw .storageFailed(InstallRecord.keyStoreMessage(why))
        case .unreadable(let why):
            // nothing is opened and nothing is deleted; the caller downloads nothing
            throw .storageFailed(InstallRecord.unreadableMessage(why))
        case .own(.downloading), .notOwn:
            if discard { self.discard(id, folder: dir) }
            return nil
        }
    }

    /// Deletes a revision folder that is not the Client's, and the pointer files that name it.
    func discard(_ id: ModelID, folder: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        let b = base(id)
        for p in ["current", "previous", "pending"] where pointer(b, p) == folder.lastPathComponent {
            try? fm.removeItem(at: b.appendingPathComponent(p))
        }
    }

    /// The start of a download into `folder` (the download folder of a build): a folder that holds this device's
    /// record of `build` goes on where it stopped; any other folder there is not the Client's and is deleted first,
    /// none of its files reused. Then the record is written with the state `downloading`, before the first file is
    /// asked for.
    func beginDownload(_ folder: URL, build: String) throws(RecognizerError) {
        if FileManager.default.fileExists(atPath: folder.path) {
            switch InstallRecord.standing(of: folder, build: build, keys: installKeys) {
            case .own:
                return
            case .keyStoreFailed(let why):
                throw .storageFailed(InstallRecord.keyStoreMessage(why))
            case .unreadable(let why):
                // a partial download whose record cannot be read is neither resumed nor deleted
                throw .storageFailed(InstallRecord.unreadableMessage(why))
            case .notOwn:
                try? FileManager.default.removeItem(at: folder)
            }
        }
        try InstallRecord.write(.downloading, build: build, in: folder, keys: installKeys)
    }

    /// Every file of the download profile is on disk and verified: the record says `installed`.
    func finishDownload(_ folder: URL, build: String) throws(RecognizerError) {
        try InstallRecord.write(.installed, build: build, in: folder, keys: installKeys)
    }

    /// Judging a folder of the store and putting a download in place, one at a time in the process.
    private static let ownership = NSLock()

    /// A finished download becomes a revision of the store: its record says `installed`, the folder is renamed
    /// into place, and it becomes the current revision (`current`) or the pending one.
    func putInPlace(_ folder: URL, id: ModelID, cdnRevision: String, build: String, current: Bool) throws(RecognizerError) -> ModelFolder {
        Self.ownership.lock()
        defer { Self.ownership.unlock() }
        try finishDownload(folder, build: build)
        let model = try place(folder, id: id, cdnRevision: cdnRevision)
        if current { try activate(id, revision: model.revision) } else { try markPending(id, revision: model.revision) }
        return model
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
        if let cdnRevision { try? Data(cdnRevision.utf8).write(to: folder.appendingPathComponent(".source"), options: StorageProtection.inPlace) }
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
        // unreadable is taken as not there here, because the worst it costs is that the model is downloaded again;
        // while the install record or the manifest of a build cannot be read, that build is neither deleted nor
        // replaced (`standing`)
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
                try Data(old.utf8).write(to: b.appendingPathComponent("previous"), options: StorageProtection.atomic)
            }
            try Data(revision.utf8).write(to: b.appendingPathComponent("current"), options: StorageProtection.atomic)
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

    func currentRevision(_ id: ModelID) -> String? { pointer(base(id), "current") }
    func previousRevision(_ id: ModelID) -> String? { pointer(base(id), "previous") }

    func pendingRevision(_ id: ModelID) -> String? {
        guard let r = pointer(base(id), "pending"), FileManager.default.fileExists(atPath: base(id).appendingPathComponent(r).path) else { return nil }
        return r
    }

    /// The CDN revision a stored revision was downloaded from.
    func sourceRevision(_ id: ModelID, revision: String) -> String? {
        // unreadable is taken as not there here, because the worst it costs is one more update check
        (try? String(contentsOf: base(id).appendingPathComponent(revision).appendingPathComponent(".source"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Marks a staged, verified revision to become current at the next load.
    func markPending(_ id: ModelID, revision: String) throws(RecognizerError) {
        do { try Data(revision.utf8).write(to: base(id).appendingPathComponent("pending"), options: StorageProtection.atomic) } catch {
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
            try Data(prev.utf8).write(to: b.appendingPathComponent("current"), options: StorageProtection.atomic)
            try? FileManager.default.removeItem(at: b.appendingPathComponent("previous"))
        } catch {
            throw .storageFailed("cannot roll back: \(error.localizedDescription)")
        }
        if let failed, failed != prev { try? FileManager.default.removeItem(at: b.appendingPathComponent(failed)) }
        prune(id)
    }
}
