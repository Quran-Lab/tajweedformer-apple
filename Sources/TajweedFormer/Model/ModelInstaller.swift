import Foundation

/// Where stored files come from: a byte range of a stored file (`layers.zfw.gz`).
protocol ModelFileSource: Sendable {
    /// Bytes `lower...upper` of the stored file `path` (inclusive). May return the whole file when the server
    /// ignores ranges; the installer slices it.
    func bytes(_ path: String, lower: Int64, upper: Int64, size: Int64) async throws(RecognizerError) -> Data
}

/// What an install did, for analytics (`downloads`) and the host.
struct InstallReport: Sendable, Hashable {
    /// Bytes fetched in this call (a resumed file counts only what was fetched now).
    var downloadedBytes: Int64 = 0
    /// Bytes the profile stores on the server, all files (what a fresh install downloads).
    var profileBytes: Int64 = 0
    /// Decoded bytes the profile keeps on disk.
    var diskBytes: Int64 = 0
    /// At least one file continued a partial download from an earlier launch.
    var resumed = false
    /// Why the accelerator files (CoreML package, keeps, self-test set) are not usable, when they are not; the CPU set
    /// is complete on its own.
    var appleUnavailable: String?
    /// The program was rebuilt on the device from its delta and the CPU weights (QLPD1), not downloaded.
    var programFromDelta = false
    /// Why the delta was not used (the full program was downloaded instead), when it was not.
    var programDeltaFallback: String?
    /// What `installAccelerator` deleted before it began (3.1.5, `ModelInstaller.repairAccelerator`): files that did
    /// not verify and what the manifest does not list in a CoreML package, as paths in the folder.
    var repaired: [String] = []
}

/// Counts the bytes of an install for `client.prefetch`'s progress: the stored bytes done (files already on disk, the
/// part of a file kept from an earlier run, every piece as it arrives) and the total of the CPU set.
final class ProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Int64 = 0
    private var total: Int64 = 0
    private let report: @Sendable (Int64, Int64) -> Void

    init(_ report: @escaping @Sendable (Int64, Int64) -> Void) { self.report = report }

    func start(total t: Int64) {
        lock.lock()
        total = t
        done = 0
        lock.unlock()
    }

    func add(_ n: Int64) {
        lock.lock()
        done = max(0, min(total, done + n))
        let d = done, t = total
        lock.unlock()
        report(d, t)
    }
}

/// Hands an install's progress to whoever listens now. An install reports to it from its start; a listener that comes
/// later (`client.prefetch` called while the launch's own update check is already downloading) is told at once where
/// the install stands, and then every step. One listener at a time; the last report is forgotten when the install ends.
final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: (@Sendable (Int64, Int64) -> Void)?
    private var last: (done: Int64, total: Int64)?

    /// Sets (or, with nil, removes) the listener. A running install's last report goes to a new listener at once.
    func listen(_ l: (@Sendable (Int64, Int64) -> Void)?) {
        lock.lock()
        listener = l
        let now = last
        lock.unlock()
        if let l, let now { l(now.done, now.total) }
    }

    func report(_ done: Int64, _ total: Int64) {
        lock.lock()
        last = (done, total)
        let l = listener
        lock.unlock()
        l?(done, total)
    }

    /// The install is over (finished or failed).
    func ended() {
        lock.lock()
        last = nil
        lock.unlock()
    }
}

/// Brings a profile of a model folder onto disk: every file by HTTP Range into `.work/<stored path>.part` (resumable
/// across launches), checked against the stored size and SHA-256, inflated when stored gzip into
/// `.work/<path>.inflating` and checked against the decoded size and SHA-256; only the decoded, checked file is moved
/// into place. Any mismatch deletes both and retries once.
///
/// Working files live in `<folder>/.work/` since 3.1.5, never next to the file they become. Tried before (to 3.1.4):
/// the `.part` sat next to its file and a gzip file was inflated straight into place, so a download the network or
/// the system stopped left, inside the CoreML package, a file the manifest does not list (or a short decoded file);
/// the folder's check then turned CoreML off at the next launch, and the promotion's download stage, which carried
/// that verdict past the download that had just removed the file, refused the build (`verify`, "... is in the CoreML
/// package but not in the manifest").
///
/// CPU first: `install` brings the CPU set (the exact engine runs from it alone), then, only when the profile asks for
/// them, the accelerator files. The SDK's own first install asks for the CPU set only; the promotion pipeline fetches
/// the accelerator files later with `installAccelerator`, on an unmetered network, after the first session.
struct ModelInstaller: Sendable {
    let source: any ModelFileSource
    let rangeSize: Int64
    let freeSpace: @Sendable (URL) -> Int64
    /// Told the bytes of the CPU set as they are done, when a caller wants progress.
    var meter: ProgressMeter?

    init(source: any ModelFileSource, rangeSize: Int64 = 8 << 20,
                freeSpace: @escaping @Sendable (URL) -> Int64 = { ModelInstaller.defaultFreeSpace($0) }) {
        self.source = source
        self.rangeSize = max(64 << 10, rangeSize)
        self.freeSpace = freeSpace
    }

    static func defaultFreeSpace(_ url: URL) -> Int64 {
        var dir = url
        while !FileManager.default.fileExists(atPath: dir.path), dir.pathComponents.count > 1 { dir.deleteLastPathComponent() }
        let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let n = v?.volumeAvailableCapacityForImportantUsage, n > 0 { return n }
        return Int64(v?.volumeAvailableCapacity ?? Int.max)
    }

    /// Installs `profile` of `manifest` into `folder` (which may hold files of an earlier, interrupted install): the
    /// CPU set, then the profile's accelerator files when it has any (a failure there leaves the CPU set working and
    /// is reported in `appleUnavailable`). Writes the manifest there last.
    func install(_ manifest: ModelManifest, profile: DownloadProfile, into folder: URL) async throws(RecognizerError) -> InstallReport {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var report = InstallReport()
        let cpu = profile.cpuFiles(manifest)
        meter?.start(total: DownloadProfile.bytes(cpu))
        try checkSpace(cpu, in: folder)
        for f in cpu { try await ensure(f, in: folder, report: &report, counted: true) }
        try manifest.write(to: folder)
        if !profile.appleFiles(manifest).isEmpty {
            do throws(RecognizerError) {
                let a = try await installAccelerator(manifest, profile: profile, into: folder)
                report.downloadedBytes += a.downloadedBytes
                report.resumed = report.resumed || a.resumed
            } catch {
                if case .offline = error { throw error }
                report.appleUnavailable = "\(error)"
            }
        }
        let kept = cpu + (report.appleUnavailable == nil ? profile.appleFiles(manifest) : [])
        report.profileBytes = DownloadProfile.bytes(kept)
        report.diskBytes = kept.reduce(0) { $0 + $1.localSize }
        Self.tidyWork(folder)
        return report
    }

    /// The accelerator files of `profile` (package, keep table, self-test set) into a folder that holds the CPU set,
    /// each verified like any download; then any correction left by an earlier SDK is deleted. The other CoreML
    /// build, when the folder holds it, stays. The compiled package is kept out of backups (the device makes it again).
    /// On a failure the files fetched so far stay (the next attempt resumes); a file that does not verify is deleted.
    /// Before anything is fetched, what an earlier download left is set right (`repairAccelerator`, 3.1.5).
    func installAccelerator(_ manifest: ModelManifest, profile: DownloadProfile,
                                   into folder: URL) async throws(RecognizerError) -> InstallReport {
        var report = InstallReport()
        let apple = profile.appleFiles(manifest)
        guard !apple.isEmpty else { throw .neuralEngineUnavailable("the folder has no \(profile.packageRole) build for \(profile.context)") }
        report.repaired = Self.repairAccelerator(manifest, in: folder)
        let pd = profile.programDelta(manifest)
        try checkSpace(apple + (pd.map { [$0.delta, $0.delta] } ?? []), in: folder)
        for f in apple where f.localPath != pd?.program.localPath { try await ensure(f, in: folder, report: &report) }
        if let pd {
            // the delta first: the program rebuilt from the CPU weights already here, checked before CoreML sees it
            if !Self.verified(pd.program, in: folder) {
                do throws(RecognizerError) {
                    try await rebuildFromDelta(manifest, pd.delta, pd.program, profile: profile, in: folder, report: &report)
                    report.programFromDelta = true
                } catch {
                    if case .offline = error { throw error }
                    report.programDeltaFallback = "\(error)"
                }
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(pd.delta.localPath))
                Self.removeParts(pd.delta, in: folder)
            }
            // the full program: when there was no delta to use, or it did not rebuild the listed bytes
            try await ensure(pd.program, in: folder, report: &report)
        }
        let fm = FileManager.default
        for f in profile.otherBuildFiles(manifest) { try? fm.removeItem(at: folder.appendingPathComponent(f.localPath)) }
        for f in profile.otherBuildFiles(manifest) {
            var dir = folder.appendingPathComponent(f.localPath).deletingLastPathComponent()
            while dir.path.count > folder.path.count, (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                try? fm.removeItem(at: dir)
                dir.deleteLastPathComponent()
            }
        }
        for top in Set(apple.compactMap { $0.localPath.split(separator: "/").first.map(String.init) }) where top != "selftest" {
            var url = folder.appendingPathComponent(top, isDirectory: true)
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            try? url.setResourceValues(v)
        }
        var fetched = apple
        if report.programFromDelta, let pd { fetched = apple.filter { $0.localPath != pd.program.localPath } + [pd.delta] }
        report.profileBytes = DownloadProfile.bytes(fetched)
        report.diskBytes = apple.reduce(0) { $0 + $1.localSize }
        Self.tidyWork(folder)
        return report
    }

    // MARK: working files and repair (3.1.5)

    /// The folder of a download's working files, inside the model folder and outside every CoreML package and every
    /// file the folder's check reads. `ModelStore.place` deletes it before a download becomes a revision.
    static let workFolder = ".work"

    /// `path` under the working folder.
    static func workURL(_ folder: URL, _ path: String) -> URL {
        var u = folder.appendingPathComponent(workFolder, isDirectory: true)
        for part in path.split(separator: "/") { u.appendPathComponent(String(part)) }
        return u
    }

    /// The working file of a stored file's download. One that an SDK to 3.1.4 left next to the file (for a package
    /// file, inside the CoreML package) is moved here first, so the download it began resumes; when both are there,
    /// the longer one is kept (each is the start of the same stored file).
    static func partURL(_ f: ModelManifest.File, in folder: URL) -> URL {
        let part = workURL(folder, f.path + ".part")
        let legacy = folder.appendingPathComponent(f.path + ".part")
        let fm = FileManager.default
        if fm.fileExists(atPath: legacy.path) {
            // sizes from the file system, not a URL's resource values: those stay cached in the URL they were read with
            func size(_ u: URL) -> Int64 { ((try? fm.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? -1 }
            if size(legacy) > size(part) {
                try? fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: part)
                try? fm.moveItem(at: legacy, to: part)
            }
            try? fm.removeItem(at: legacy)
        }
        // a URL made after the move, so no size read before it is cached in it
        return workURL(folder, f.path + ".part")
    }

    /// Deletes a stored file's working file, here and where an SDK to 3.1.4 kept it.
    static func removeParts(_ f: ModelManifest.File, in folder: URL) {
        try? FileManager.default.removeItem(at: workURL(folder, f.path + ".part"))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(f.path + ".part"))
    }

    /// The empty folders under the working folder, deleted deepest first (a working file of a download that stopped
    /// stays, to resume; an install that finished leaves none).
    static func tidyWork(_ folder: URL) {
        let fm = FileManager.default
        let root = folder.appendingPathComponent(workFolder, isDirectory: true)
        guard let e = fm.enumerator(atPath: root.path) else { return }
        var dirs: [String] = []
        while let p = e.nextObject() as? String {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: root.appendingPathComponent(p).path, isDirectory: &isDir), isDir.boolValue { dirs.append(p) }
        }
        for d in dirs.sorted(by: { $0.count > $1.count }) {
            let u = root.appendingPathComponent(d)
            if (try? fm.contentsOfDirectory(atPath: u.path))?.isEmpty == true { try? fm.removeItem(at: u) }
        }
        if (try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty == true { try? fm.removeItem(at: root) }
    }

    /// A working file of this downloader by its name: a stored file's `.part` (any SDK) or a decoded file being
    /// written (`.inflating`, 3.1.5).
    static func isWorkingFile(_ path: String) -> Bool { path.hasSuffix(".part") || path.hasSuffix(".inflating") }

    /// Sets right what a download left in the accelerator's files before the build is installed (3.1.5), so a
    /// download that the network, the system or the app stopped never keeps the build off. For every Apple file of
    /// the manifest (both builds, the keep tables, the deltas, the corrections):
    /// - a working file an SDK to 3.1.4 kept next to it is moved to the working folder (the download resumes);
    /// - a file on disk without the manifest's size and SHA-256 is deleted, and downloaded again;
    /// - in a CoreML package, a working file of this downloader the manifest does not list is deleted; any other file
    ///   the manifest does not list deletes the whole package, which is then downloaded again from nothing.
    /// Nothing the manifest does not list is ever accepted: the folder's check (`ModelFolder.open`) is as strict as
    /// before, and runs again on the files after the download (`ModelFolder.rechecked`). Returns the paths deleted.
    @discardableResult
    static func repairAccelerator(_ m: ModelManifest, in folder: URL) -> [String] {
        let fm = FileManager.default
        var removed: [String] = []
        let apple = m.files.filter { DownloadProfile.appleRoles.contains($0.role) }
        for f in apple { _ = partURL(f, in: folder) }
        for f in apple {
            let url = folder.appendingPathComponent(f.localPath)
            guard fm.fileExists(atPath: url.path) else { continue }
            if present(f, in: folder), let (_, sha) = try? ModelManifest.digest(url), sha == f.localSHA256 { continue }
            try? fm.removeItem(at: url)
            removed.append(f.localPath)
        }
        let listed = Set(m.files.map(\.localPath))
        for pkg in ModelFolder.packages(m.files.filter { DownloadProfile.packageRoles.contains($0.role) }) {
            guard fm.fileExists(atPath: folder.appendingPathComponent(pkg).path),
                  let inside = try? ModelFolder.filesUnder(folder, pkg) else { continue }
            let strays = inside.filter { !listed.contains($0) }
            if strays.isEmpty { continue }
            if strays.allSatisfy(isWorkingFile) {
                for p in strays {
                    try? fm.removeItem(at: folder.appendingPathComponent(p))
                    removed.append(p)
                }
            } else {
                try? fm.removeItem(at: folder.appendingPathComponent(pkg))
                removed.append(pkg)
            }
        }
        return removed
    }

    /// Whether a decoded file is on disk with the manifest's size and SHA-256.
    static func verified(_ f: ModelManifest.File, in folder: URL) -> Bool {
        guard present(f, in: folder), let (_, sha) = try? ModelManifest.digest(folder.appendingPathComponent(f.localPath)) else { return false }
        return sha == f.localSHA256
    }

    /// Downloads the delta (verified like any file) and rebuilds the program from it and the context's CPU files,
    /// into a scratch file outside the package that moves into place only once its SHA-256 is the manifest's.
    func rebuildFromDelta(_ m: ModelManifest, _ delta: ModelManifest.File, _ program: ModelManifest.File, profile: DownloadProfile,
                          in folder: URL, report: inout InstallReport) async throws(RecognizerError) {
        try await ensure(delta, in: folder, report: &report)
        let cpu = ProgramDelta.CPUFiles(folder: folder, context: profile.context,
                                        layersSHA256: m.files(role: "weights").first?.localSHA256,
                                        frontendSHA256: m.files(role: "frontend").first?.localSHA256)
        let scratch = folder.appendingPathComponent(".rebuild", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let built = scratch.appendingPathComponent((program.localPath as NSString).lastPathComponent)
        try ProgramDelta.rebuild(delta: folder.appendingPathComponent(delta.localPath), cpu: cpu, to: built,
                                 expectedSHA256: program.localSHA256, expectedSize: program.localSize)
        let dst = folder.appendingPathComponent(program.localPath)
        try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.moveItem(at: built, to: dst) } catch {
            throw .storageFailed("cannot place \(program.localPath): \(error.localizedDescription)")
        }
    }

    /// Room for `files` not on disk yet (stored and decoded bytes), with 64 MB to spare.
    func checkSpace(_ files: [ModelManifest.File], in folder: URL) throws(RecognizerError) {
        let needed = files.filter { !Self.present($0, in: folder) }
        let want = needed.reduce(Int64(0)) { $0 + $1.size + $1.localSize }
        let free = freeSpace(folder)
        guard free >= want + (64 << 20) else { throw .insufficientStorage(needed: want + (64 << 20), available: free) }
    }

    /// Whether the decoded file is on disk with its size (the hash is checked when the model is opened).
    static func present(_ f: ModelManifest.File, in folder: URL) -> Bool {
        let v = try? folder.appendingPathComponent(f.localPath).resourceValues(forKeys: [.fileSizeKey])
        return v?.fileSize.map(Int64.init) == f.localSize
    }

    /// One file on disk, decoded and verified: kept if already there and matching, else downloaded (resuming a
    /// `.part`), checked, inflated, checked. One retry after a mismatch.
    func ensure(_ f: ModelManifest.File, in folder: URL, report: inout InstallReport, counted: Bool = false) async throws(RecognizerError) {
        let fm = FileManager.default
        let dst = folder.appendingPathComponent(f.localPath)
        let meter = counted ? self.meter : nil
        if Self.present(f, in: folder), let (_, sha) = try? ModelManifest.digest(dst), sha == f.localSHA256 {
            meter?.add(f.size)
            return
        }
        try? fm.removeItem(at: dst)
        var attempt = 0
        while true {
            attempt += 1
            let before = report.downloadedBytes
            var kept: Int64 = 0
            do throws(RecognizerError) {
                try await fetch(f, in: folder, report: &report, meter: meter, kept: &kept)
                return
            } catch {
                guard case .checksumMismatch = error, attempt < 2 else { throw error }
                // the file starts again: what was counted for it goes back
                meter?.add(-(kept + report.downloadedBytes - before))
            }
        }
    }

    private func fetch(_ f: ModelManifest.File, in folder: URL, report: inout InstallReport, meter: ProgressMeter?,
                       kept: inout Int64) async throws(RecognizerError) {
        let fm = FileManager.default
        let part = Self.partURL(f, in: folder)
        let dst = folder.appendingPathComponent(f.localPath)
        try? fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        var have = Int64((try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
        if have > f.size { try? fm.removeItem(at: part); have = -1 }
        if have < 0 {
            guard fm.createFile(atPath: part.path, contents: nil) else { throw .storageFailed("cannot create \(f.path).part") }
            have = 0
        } else if have > 0 {
            report.resumed = true
            kept = have
            meter?.add(have)
        }
        guard let h = try? FileHandle(forWritingTo: part) else { throw .storageFailed("cannot open \(f.path).part") }
        do {
            try h.seek(toOffset: UInt64(have))
            while have < f.size {
                let upper = min(f.size, have + rangeSize) - 1
                let piece = try await source.bytes(f.path, lower: have, upper: upper, size: f.size)
                guard Int64(piece.count) == upper - have + 1 else { throw RecognizerError.offline("short range for \(f.path)") }
                try h.write(contentsOf: piece)
                have += Int64(piece.count)
                report.downloadedBytes += Int64(piece.count)
                meter?.add(Int64(piece.count))
            }
            try h.synchronize()
            try h.close()
        } catch let e as RecognizerError {
            try? h.close()
            throw e
        } catch {
            try? h.close()
            throw .storageFailed("cannot write \(f.path).part: \(error.localizedDescription)")
        }
        let (size, sha) = try ModelManifest.digest(part)
        guard size == f.size, sha == f.sha256 else {
            try? fm.removeItem(at: part)
            throw .checksumMismatch(file: f.path)
        }
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if f.isGzip {
            // inflated beside the part, and moved into place only once it is the manifest's file
            let inflating = Self.workURL(folder, f.localPath + ".inflating")
            try? fm.removeItem(at: inflating)
            try? fm.createDirectory(at: inflating.deletingLastPathComponent(), withIntermediateDirectories: true)
            let out: Gzip.Output
            do throws(RecognizerError) { out = try Gzip.inflate(part, to: inflating) } catch {
                try? fm.removeItem(at: part)
                try? fm.removeItem(at: inflating)
                throw error
            }
            try? fm.removeItem(at: part)
            guard out.size == f.localSize, out.sha256 == f.localSHA256 else {
                try? fm.removeItem(at: inflating)
                throw .checksumMismatch(file: f.localPath)
            }
            try? fm.removeItem(at: dst)
            do { try fm.moveItem(at: inflating, to: dst) } catch {
                try? fm.removeItem(at: inflating)
                throw .storageFailed("cannot place \(f.localPath): \(error.localizedDescription)")
            }
        } else {
            try? fm.removeItem(at: dst)
            do { try fm.moveItem(at: part, to: dst) } catch {
                try? fm.removeItem(at: part)
                throw .storageFailed("cannot place \(f.localPath): \(error.localizedDescription)")
            }
        }
    }
}

/// Stored files from a local folder (a staged copy of the server folder): for tests and offline installs.
struct DirectoryFileSource: ModelFileSource {
    let root: URL
    init(root: URL) { self.root = root }
    func bytes(_ path: String, lower: Int64, upper: Int64, size: Int64) async throws(RecognizerError) -> Data {
        guard let h = try? FileHandle(forReadingFrom: root.appendingPathComponent(path)) else { throw .modelMissing(path) }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: UInt64(lower))
            return try h.read(upToCount: Int(upper - lower + 1)) ?? Data()
        } catch {
            throw .modelMissing(path)
        }
    }
}
