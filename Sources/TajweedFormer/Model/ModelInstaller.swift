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
    /// Files the correction rebuilt from the CoreML weights instead of downloading.
    public var rebuilt: [String] = []
    /// Why the Apple files (CoreML package, keeps, correction) are not usable, when they are not; the CPU set is
    /// then complete on its own.
    public var appleUnavailable: String?
    /// Why the correction did not rebuild the weights (they were downloaded instead), when it did not.
    public var correctionFallback: String?
}

/// Brings a profile of a model folder onto disk: every file by HTTP Range into `<stored path>.part` (resumable across
/// launches), checked against the stored size and SHA-256, inflated when stored gzip and checked against the decoded
/// size and SHA-256; only the decoded file is kept. Any mismatch deletes both and retries once.
///
/// Apple files first (iOS 18 / macOS 15): the CoreML package, the context's keep table and the correction; then the
/// CPU engine's weight files are rebuilt from the package's weights (`Correction`) and checked against the manifest,
/// and only what the correction did not cover is downloaded. If anything of that fails, the CPU set is downloaded
/// whole: the CPU path always works.
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

    /// Installs `profile` of `manifest` into `folder` (which may hold files of an earlier, interrupted install), and
    /// writes the manifest there last.
    public func install(_ manifest: ModelManifest, profile: DownloadProfile, into folder: URL) async throws(RecognizerError) -> InstallReport {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var report = InstallReport()
        var apple = profile.appleFiles(manifest)
        let cpu = profile.cpuFiles(manifest)
        let needed = (apple + cpu).filter { !Self.present($0, in: folder) }
        let want = needed.reduce(Int64(0)) { $0 + $1.size + $1.localSize }
        let free = freeSpace(folder)
        guard free >= want + (64 << 20) else { throw .insufficientStorage(needed: want + (64 << 20), available: free) }

        // the Apple files; any failure leaves the CPU set to do the work
        if !apple.isEmpty {
            do throws(RecognizerError) {
                for f in apple { try await ensure(f, in: folder, report: &report) }
            } catch {
                if case .offline = error { throw error }
                report.appleUnavailable = "\(error)"
                for f in apple { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f.localPath)) }
                apple = []
            }
        }
        // the correction: rebuild what it covers, each file checked against the manifest
        var covered = Set<String>()
        if let zfs = apple.first(where: { $0.role == profile.correctionRole }) {
            covered = rebuild(manifest, profile: profile, correction: zfs, apple: apple, in: folder, report: &report)
        }
        for f in cpu where !covered.contains(f.path) { try await ensure(f, in: folder, report: &report) }
        let kept = apple + cpu
        // one CoreML build on the device: the other build's files go (a profile change), once this one is in place
        if !apple.isEmpty {
            for f in profile.otherBuildFiles(manifest) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f.localPath)) }
            for f in profile.otherBuildFiles(manifest) {
                var dir = folder.appendingPathComponent(f.localPath).deletingLastPathComponent()
                while dir.path.count > folder.path.count, (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                    try? FileManager.default.removeItem(at: dir)
                    dir.deleteLastPathComponent()
                }
            }
        }
        report.profileBytes = DownloadProfile.bytes(kept.filter { !covered.contains($0.path) })
        report.diskBytes = kept.reduce(0) { $0 + $1.localSize }
        try manifest.write(to: folder)
        return report
    }

    /// The correction's rebuild. Returns the stored paths it covered (verified on disk).
    func rebuild(_ m: ModelManifest, profile: DownloadProfile, correction: ModelManifest.File, apple: [ModelManifest.File],
                 in folder: URL, report: inout InstallReport) -> Set<String> {
        let zfs = folder.appendingPathComponent(correction.localPath)
        guard let entries = Correction.entries(zfs) else {
            report.correctionFallback = "the correction file is not a sidecar this engine reads"
            return []
        }
        let targets = profile.rebuilt(m, correctionNames: entries.map(\.name))
        guard !targets.isEmpty else {
            report.correctionFallback = "the correction rebuilds none of this profile's files"
            return []
        }
        // the sidecar's own record must name the manifest's file, before any byte is written
        let bySidecar = Dictionary(entries.map { ($0.name, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        for t in targets where bySidecar[t.localPath] != t.localSHA256 {
            report.correctionFallback = "the correction rebuilds a different \(t.localPath) than the manifest lists"
            return []
        }
        if targets.allSatisfy({ Self.present($0, in: folder) }) { return Set(targets.map(\.path)) }
        guard let weights = apple.first(where: { $0.role == profile.packageRole && $0.localPath.hasSuffix(".mlmodelc/weights/weight.bin") }) else {
            report.correctionFallback = "the CoreML package has no weights/weight.bin"
            return []
        }
        // the rebuild writes into a scratch folder: only listed, checked files move into the model
        let scratch = folder.appendingPathComponent(".rebuild", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do throws(RecognizerError) {
            _ = try Correction.rebuild(weightBin: folder.appendingPathComponent(weights.localPath), zfs: zfs, into: scratch)
            for t in targets {
                let built = scratch.appendingPathComponent(t.localPath)
                let (size, sha) = try ModelManifest.digest(built)
                guard size == t.localSize, sha == t.localSHA256 else { throw RecognizerError.checksumMismatch(file: t.localPath + " (rebuilt)") }
                let dst = folder.appendingPathComponent(t.localPath)
                try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dst)
                do { try FileManager.default.moveItem(at: built, to: dst) } catch {
                    throw RecognizerError.storageFailed("cannot place \(t.localPath): \(error.localizedDescription)")
                }
            }
        } catch {
            report.correctionFallback = "\(error)"
            for t in targets { try? FileManager.default.removeItem(at: folder.appendingPathComponent(t.localPath)) }
            return []
        }
        report.rebuilt = targets.map(\.localPath)
        return Set(targets.map(\.path))
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
