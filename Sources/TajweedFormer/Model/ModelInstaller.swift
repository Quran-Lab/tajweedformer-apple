import Foundation

/// Where stored files come from: a byte range of a stored file (`layers.zfw.gz`).
public protocol ModelFileSource: Sendable {
    /// Bytes `lower...upper` of the stored file `path` (inclusive). May return the whole file when the server
    /// ignores ranges; the installer slices it.
    func bytes(_ path: String, lower: Int64, upper: Int64, size: Int64) async throws(RecognizerError) -> Data
}

/// What an install did, for analytics (`downloads`) and the host.
public struct InstallReport: Sendable, Hashable {
    /// Bytes fetched in this call (a resumed file counts only what was fetched now).
    public var downloadedBytes: Int64 = 0
    /// Bytes the profile stores on the server, all files (what a fresh install downloads).
    public var profileBytes: Int64 = 0
    /// Decoded bytes the profile keeps on disk.
    public var diskBytes: Int64 = 0
    /// At least one file continued a partial download from an earlier launch.
    public var resumed = false
    /// Why the accelerator files (CoreML package, keeps, self-test set) are not usable, when they are not; the CPU set
    /// is complete on its own.
    public var appleUnavailable: String?
    /// The program was rebuilt on the device from its delta and the CPU weights (QLPD1), not downloaded.
    public var programFromDelta = false
    /// Why the delta was not used (the full program was downloaded instead), when it was not.
    public var programDeltaFallback: String?
}

/// Brings a profile of a model folder onto disk: every file by HTTP Range into `<stored path>.part` (resumable across
/// launches), checked against the stored size and SHA-256, inflated when stored gzip and checked against the decoded
/// size and SHA-256; only the decoded file is kept. Any mismatch deletes both and retries once.
///
/// CPU first: `install` brings the CPU set (the exact engine runs from it alone), then, only when the profile asks for
/// them, the accelerator files. The SDK's own first install asks for the CPU set only; the promotion pipeline fetches
/// the accelerator files later with `installAccelerator`, on an unmetered network, after the first session.
public struct ModelInstaller: Sendable {
    let source: any ModelFileSource
    let rangeSize: Int64
    let freeSpace: @Sendable (URL) -> Int64

    public init(source: any ModelFileSource, rangeSize: Int64 = 8 << 20,
                freeSpace: @escaping @Sendable (URL) -> Int64 = { ModelInstaller.defaultFreeSpace($0) }) {
        self.source = source
        self.rangeSize = max(64 << 10, rangeSize)
        self.freeSpace = freeSpace
    }

    public static func defaultFreeSpace(_ url: URL) -> Int64 {
        var dir = url
        while !FileManager.default.fileExists(atPath: dir.path), dir.pathComponents.count > 1 { dir.deleteLastPathComponent() }
        let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let n = v?.volumeAvailableCapacityForImportantUsage, n > 0 { return n }
        return Int64(v?.volumeAvailableCapacity ?? Int.max)
    }

    /// Installs `profile` of `manifest` into `folder` (which may hold files of an earlier, interrupted install): the
    /// CPU set, then the profile's accelerator files when it has any (a failure there leaves the CPU set working and
    /// is reported in `appleUnavailable`). Writes the manifest there last.
    public func install(_ manifest: ModelManifest, profile: DownloadProfile, into folder: URL) async throws(RecognizerError) -> InstallReport {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var report = InstallReport()
        let cpu = profile.cpuFiles(manifest)
        try checkSpace(cpu, in: folder)
        for f in cpu { try await ensure(f, in: folder, report: &report) }
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
        return report
    }

    /// The accelerator files of `profile` (package, keep table, self-test set) into a folder that holds the CPU set,
    /// each verified like any download; then the other build's files and any correction left by an earlier SDK are
    /// deleted (one build on the device). The compiled package is kept out of backups (the device makes it again).
    /// On a failure the files fetched so far stay (the next attempt resumes); a file that does not verify is deleted.
    public func installAccelerator(_ manifest: ModelManifest, profile: DownloadProfile,
                                   into folder: URL) async throws(RecognizerError) -> InstallReport {
        var report = InstallReport()
        let apple = profile.appleFiles(manifest)
        guard !apple.isEmpty else { throw .neuralEngineUnavailable("the folder has no \(profile.packageRole) build for \(profile.context)") }
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
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(pd.delta.path + ".part"))
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
        return report
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
    func ensure(_ f: ModelManifest.File, in folder: URL, report: inout InstallReport) async throws(RecognizerError) {
        let fm = FileManager.default
        let dst = folder.appendingPathComponent(f.localPath)
        if Self.present(f, in: folder), let (_, sha) = try? ModelManifest.digest(dst), sha == f.localSHA256 { return }
        try? fm.removeItem(at: dst)
        var attempt = 0
        while true {
            attempt += 1
            do throws(RecognizerError) {
                try await fetch(f, in: folder, report: &report)
                return
            } catch {
                guard case .checksumMismatch = error, attempt < 2 else { throw error }
            }
        }
    }

    private func fetch(_ f: ModelManifest.File, in folder: URL, report: inout InstallReport) async throws(RecognizerError) {
        let fm = FileManager.default
        let part = folder.appendingPathComponent(f.path + ".part")
        let dst = folder.appendingPathComponent(f.localPath)
        try? fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        var have = Int64((try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
        if have > f.size { try? fm.removeItem(at: part); have = -1 }
        if have < 0 {
            guard fm.createFile(atPath: part.path, contents: nil) else { throw .storageFailed("cannot create \(f.path).part") }
            have = 0
        } else if have > 0 {
            report.resumed = true
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
        if f.isGzip {
            let out: Gzip.Output
            do throws(RecognizerError) { out = try Gzip.inflate(part, to: dst) } catch {
                try? fm.removeItem(at: part)
                try? fm.removeItem(at: dst)
                throw error
            }
            try? fm.removeItem(at: part)
            guard out.size == f.localSize, out.sha256 == f.localSHA256 else {
                try? fm.removeItem(at: dst)
                throw .checksumMismatch(file: f.localPath)
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
public struct DirectoryFileSource: ModelFileSource {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func bytes(_ path: String, lower: Int64, upper: Int64, size: Int64) async throws(RecognizerError) -> Data {
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
