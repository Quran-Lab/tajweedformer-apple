import Foundation
import TajweedFormerCore

/// The reference table of one model folder (manifest role `reference`, the file `expected_tj3.zfx`): downloaded only
/// when the app asks, verified against the signed manifest like every file, and read through the engine's
/// `zf_tajweed_reference_*`. It is data: nothing in the SDK reads it for a take.
final class ModelReference: ReferenceTable, @unchecked Sendable {
    private let lock = NSLock()
    private let folder: ModelFolder
    private let file: ModelManifest.File
    private var fetched: Bool
    private var handle: OpaquePointer?
    /// Brings the file into the folder (downloaded and verified); nil where there is no Client to download with.
    // (untyped throws: an optional of a typed-throws function type needs iOS 18 / macOS 15 at run time)
    private let download: (@Sendable (ModelFolder, ModelManifest.File) async throws -> Void)?

    init(folder: ModelFolder, file: ModelManifest.File,
         download: (@Sendable (ModelFolder, ModelManifest.File) async throws -> Void)?) {
        self.folder = folder
        self.file = file
        self.download = download
        fetched = folder.verifiedFiles.contains(file.localPath)
    }

    deinit {
        if let handle { zf_tajweed_reference_close(handle) }
    }

    private var url: URL { folder.directory.appendingPathComponent(file.localPath) }

    var isDownloaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fetched
    }

    private func markFetched() {
        lock.lock()
        fetched = true
        lock.unlock()
    }

    func fetch() async throws(TajweedError) {
        if isDownloaded { return }
        // a file already there (an earlier fetch, a folder the app staged) only has to verify
        if ModelInstaller.verified(file, in: folder.directory) {
            markFetched()
            return
        }
        guard let download else { throw TajweedError(.referenceMissing) }
        do {
            try await download(folder, file)
        } catch {
            throw TajweedError(.referenceMissing)
        }
        guard ModelInstaller.verified(file, in: folder.directory) else { throw TajweedError(.referenceMissing) }
        markFetched()
    }

    /// The table, opened on first use. Its ids must refer to the model's own tokens.txt.
    private func table() throws(TajweedError) -> OpaquePointer {
        lock.lock()
        defer { lock.unlock() }
        if let handle { return handle }
        guard fetched else { throw TajweedError(.referenceMissing) }
        var err: UnsafePointer<CChar>?
        guard let r = url.path.withCString({ zf_tajweed_reference_open($0, &err) }) else {
            throw TajweedError(.modelInvalid, ["detail": err.map { String(cString: $0) } ?? "the reference data does not open"])
        }
        if let sha = zf_tajweed_reference_tokens_sha256(r) {
            let hex = UnsafeBufferPointer(start: sha, count: 32).map { String(format: "%02x", $0) }.joined()
            guard hex == folder.manifest.tokensSHA256 else {
                zf_tajweed_reference_close(r)
                throw TajweedError(.modelInvalid, ["detail": "the reference data was made for another tokens.txt"])
            }
        }
        handle = r
        return r
    }

    func units(surah: Int, ayah: Int) throws(TajweedError) -> (units: [Int], wordStarts: [Int]) {
        let r = try table()
        var units: UnsafePointer<Int32>?
        var words: UnsafePointer<Int32>?
        var nWords: Int32 = 0
        let n = Int(zf_tajweed_reference_units(r, Int32(surah), Int32(ayah), &units, &words, &nWords))
        guard n >= 0, let units, let words else {
            let count = Int(zf_tajweed_reference_ayah_count(r, Int32(surah)))
            throw .argument(count == 0 ? "surah \(surah) is not in the reference data" : "ayah \(ayah) is not 1 to \(count) of surah \(surah)")
        }
        var ids: [Int] = [], starts: [Int] = []
        ids.reserveCapacity(n)
        for i in 0..<n {
            ids.append(Int(units[i]))
            if i == 0 || words[i] != words[i - 1] { starts.append(i) }
        }
        return (ids, starts)
    }
}
