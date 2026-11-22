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
    /// SDK 4.0.2: the context the Model's engine runs (else the default one), which the model opens with again when
    /// the table's install closed it.
    private let context: @Sendable () -> String

    init(folder: ModelFolder, file: ModelManifest.File, download: (@Sendable (ModelFolder, ModelManifest.File) async throws -> Void)?,
         context: (@Sendable () -> String)? = nil) {
        self.folder = folder
        self.file = file
        self.download = download
        let fallback = folder.manifest.defaultContext
        self.context = context ?? { fallback }
        fetched = ModelInstaller.present(file, in: folder.directory)
    }

    /// The error of a table that cannot be read, with the place it failed in `errorCode` (24.3): `not_fetched` (no
    /// fetch() yet), `not_open` (the model could not be opened to read it), `core_file` (the Core refused the file),
    /// `core_read` (another failure of the Core's read), `download` (fetch() brought no file).
    static func missing(_ errorCode: String, _ detail: String? = nil) -> TajweedError {
        TajweedError(.referenceMissing, detail.map { ["detail": $0] } ?? [:],
                     cause: ErrorCause(stage: "verify", reason: "missing", errorCode: errorCode))
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
        guard let download else { throw Self.missing("download", "there is no Client to fetch it through") }
        do {
            try await download(folder, file)
        } catch let e as RecognizerError {
            // SDK 4.0.2: the download's or the lease's own failure, by contract 24.4 (`needs_connection` when no
            // request got an answer, else `download_failed`), with its cause; 4.0.1 said reference_missing with none
            throw TajweedClient.modelCallError(ErrorCause.of(e, stage: "download"), onDevice: .nothing, error: e)
        } catch let e as TajweedError {
            throw e
        } catch {
            throw TajweedError(.downloadFailed, ["detail": "\(error)"],
                               cause: ErrorCause(stage: "download", reason: "other"))
        }
        guard ModelInstaller.present(file, in: folder.directory) else {
            throw Self.missing("download", "the file is not on the device")
        }
        setFetched(true)
        // SDK 4.0.2: the table's install closes the open model when the model reads that file (the Core refuses the
        // install while it is open), and nothing opened it again, so units() after fetch() found no model on a first
        // launch. When nothing is open now, this folder's model opens again (off the caller's thread), with the
        // context its engine runs. The app holds the Model, so a model it holds stays open (4.0.1). A failure here is
        // not the fetch's: units() opens it then, or says why.
        if let runtime = ProtectedRuntime.current.withLock({ $0 }), runtime.openFolder == nil {
            let f = folder, ctx = context()
            // SDK 4.0.3: a wait for another Client's take on the Core's model suspends here; the open never blocks
            await runtime.awaitOpenable(f, context: ctx)
            await Task.detached(priority: .userInitiated) {
                ProtectedRuntime.$asyncWaited.withValue(true) { _ = try? runtime.openModel(f, context: ctx) }
            }.value
        }
    }

    func units(surah: Int, ayah: Int) throws(TajweedError) -> (units: [Int], wordStarts: [Int]) {
        guard isDownloaded else { throw Self.missing("not_fetched") }
        guard (1...114).contains(surah) else { throw .argument("surah \(surah) is not 1 to 114") }
        let count = QuranIndex.ayahs[surah - 1]
        guard (1...count).contains(ayah) else { throw .argument("ayah \(ayah) is not 1 to \(count) of surah \(surah)") }
        guard let runtime = ProtectedRuntime.current.withLock({ $0 }) else {
            throw Self.missing("not_open", "the model is not open")
        }
        var open = runtime.openModel(of: folder)
        if open == nil, runtime.openFolder == nil {
            // SDK 4.0.2: nothing is open (an install closed this model, and fetch() could not open it again): it opens
            // here. Never while another folder or context is open: closing that one would fail a take running on it
            do throws(RecognizerError) {
                open = try runtime.openModel(folder, context: context())
            } catch {
                if case .offline(let why) = error, why.hasPrefix("needs_connection") {
                    // the model is on the device: what it needs is the lease (24.13)
                    throw TajweedError(.needsConnection, ["detail": "the model opens with the lease (\(why))"],
                                       cause: ErrorCause.of(error, stage: "model_open"), onDevice: .complete)
                }
                throw Self.missing("not_open", "the model could not be opened (\(error))")
            }
        }
        // SDK 4.0.3: this folder's model opened between the two reads above (fetch()'s reopen or a take's open, a moment
        // after an install closed it): the table reads through it. Without this, units() said not_open while the model
        // was open
        if open == nil { open = runtime.openModel(of: folder) }
        guard let model = open else { throw Self.missing("not_open", "the model is not open") }
        switch model.reference(surah: surah, ayah: ayah) {
        case .success(let r):
            return r
        case .failure(let e):
            switch e.status {
            case QLC_E_ARG:
                throw .argument("ayah \(ayah) of surah \(surah) is not in the reference data")
            case QLC_E_NEEDS_CONNECTION, QLC_E_LEASE:
                // the first read needs the lease, as an open does; the next call tries again
                // the model is on the device: what it needs is the lease (24.13)
                throw TajweedError(.needsConnection, ["detail": "the reference data is read with the lease (\(e.detail))"],
                                   cause: ErrorCause(stage: "lease", reason: "network", errorCode: CoreFailure.statusName(Int(e.status))),
                                   onDevice: .complete)
            case QLC_E_FILE:
                // not installed, or refused by its tags or its signed SHA-256: fetched again from the start
                if e.detail != 0 { try? FileManager.default.removeItem(at: folder.directory.appendingPathComponent(file.localPath + ".qld")) }
                setFetched(false)
                throw Self.missing("core_file", "the Core could not read the reference data (\(e.detail))")
            default:
                throw Self.missing("core_read", "the Core could not read the reference data (\(e.status), \(e.detail))")
            }
        }
    }
}
