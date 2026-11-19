import Foundation
import QuranLabCore

/// The reference table of one model build (manifest role `reference`, encrypted like every model file in SDK 4.0):
/// downloaded only when the app asks, installed by the Core to this device's form, and read by the Core
/// (`qlc_reference_expected`, R3), never by the SDK. It is data: nothing in the SDK reads it for a take.
///
/// The Core reads it at the first call after the model opened (as SDK 3.x read its table on first use) and holds it
/// with the model. That first call needs the lease, as an open does: without one it is `needs_connection`, and the
/// next call tries again. A table the Core refused (a changed byte) is `reference_missing` until it is fetched again.
final class ModelReference: ReferenceTable, @unchecked Sendable {
    private let lock = NSLock()
    private let folder: ModelFolder
    private let file: ModelManifest.File
    private var fetched: Bool
    /// Brings the file onto the device (downloaded, verified, installed by the Core); nil where there is no Client.
    // (untyped throws: an optional of a typed-throws function type needs iOS 18 / macOS 15 at run time)
    private let download: (@Sendable (ModelFolder, ModelManifest.File) async throws -> Void)?

    init(folder: ModelFolder, file: ModelManifest.File, download: (@Sendable (ModelFolder, ModelManifest.File) async throws -> Void)?) {
        self.folder = folder
        self.file = file
        self.download = download
        fetched = ModelInstaller.present(file, in: folder.directory)
    }

    var isDownloaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fetched
    }

    private func setFetched(_ v: Bool) {
        lock.lock()
        fetched = v
        lock.unlock()
    }

    func fetch() async throws(TajweedError) {
        if isDownloaded { return }
        if ModelInstaller.present(file, in: folder.directory) {
            setFetched(true)
            return
        }
        guard let download else { throw TajweedError(.referenceMissing) }
        do {
            try await download(folder, file)
        } catch {
            throw TajweedError(.referenceMissing)
        }
        guard ModelInstaller.present(file, in: folder.directory) else { throw TajweedError(.referenceMissing) }
        setFetched(true)
    }

    func units(surah: Int, ayah: Int) throws(TajweedError) -> (units: [Int], wordStarts: [Int]) {
        guard isDownloaded else { throw TajweedError(.referenceMissing) }
        guard (1...114).contains(surah) else { throw .argument("surah \(surah) is not 1 to 114") }
        let count = QuranIndex.ayahs[surah - 1]
        guard (1...count).contains(ayah) else { throw .argument("ayah \(ayah) is not 1 to \(count) of surah \(surah)") }
        guard let runtime = ProtectedRuntime.current.withLock({ $0 }), let model = runtime.openModel(of: folder) else {
            throw TajweedError(.referenceMissing, ["detail": "the model is not open"])
        }
        switch model.reference(surah: surah, ayah: ayah) {
        case .success(let r):
            return r
        case .failure(let e):
            switch e.status {
            case QLC_E_ARG:
                throw .argument("ayah \(ayah) of surah \(surah) is not in the reference data")
            case QLC_E_NEEDS_CONNECTION, QLC_E_LEASE:
                // the first read needs the lease, as an open does; the next call tries again
                throw TajweedError(.needsConnection, ["detail": "the reference data is read with the lease (\(e.detail))"])
            case QLC_E_FILE:
                // not installed, or refused by its tags or its signed SHA-256: fetched again from the start
                if e.detail != 0 { try? FileManager.default.removeItem(at: folder.directory.appendingPathComponent(file.localPath + ".qld")) }
                setFetched(false)
                throw TajweedError(.referenceMissing, ["detail": "the Core could not read the reference data (\(e.detail))"])
            default:
                throw TajweedError(.referenceMissing, ["detail": "the Core could not read the reference data (\(e.status), \(e.detail))"])
            }
        }
    }
}
