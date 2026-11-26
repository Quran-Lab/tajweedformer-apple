import CryptoKit
import Darwin
import Foundation

/// The vocabularies the SDK knows, by the SHA-256 of their tokens.txt (the signed manifest's `tokens_sha256`). In a
/// protected build tokens.txt is encrypted like every model file; the SDK carries the public token list of each model
/// it runs (`Resources/Vocabulary/<sha256>.txt`), the same bytes, checked by their hash, because a folder is read
/// before any model opens. Once the Core opens the model its own list (`qlc_model_token_name`, R4) is compared with
/// this one, and a build whose lists differ is not run. A build whose vocabulary the SDK does not know is
/// `model_incompatible`.
enum Vocabularies {
    static func vocabulary(sha256: String) throws(RecognizerError) -> Vocabulary {
        let name = sha256.lowercased()
        guard name.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let url = SDKResources.bundle.url(forResource: name, withExtension: "txt", subdirectory: "Vocabulary"),
              let data = try? Data(contentsOf: url), Data(SHA256.hash(data: data)).hex == name,
              let text = String(data: data, encoding: .utf8) else {
            throw .modelIncompatible("the build's vocabulary (tokens \(sha256.prefix(12))) is not one this SDK carries")
        }
        let v = try Vocabulary(text: text)
        guard v.count == 38, v.blank == 0 else { throw .manifestInvalid("tokens \(sha256.prefix(12)) has \(v.count) tokens; tj3 has 38") }
        return v
    }
}

/// The accelerator calls of the Core (R2, quranlab-core 9300013; qlcore.h API 1, additions only), found by name at
/// run time (`dlsym`) as hardening.md section 10 asks of the Apple wrapper: a Core without them runs the CPU engine
/// only, and nothing else changes. Each signature is qlcore.h's.
enum CoreOptional {
    /// `int qlc_accel_prepare(qlc_model *m, const char *kind, const char *dispatch_dir, char *backend, size_t cap)`:
    /// the Core decrypts the accelerator program into its memory and hands it to the runtime itself (18.5.6): Core ML
    /// from memory (`MLModelAsset`) when the build ships the specification, else through a short-lived compiled package
    /// in `dispatch_dir` that the Core deletes before it returns. 0 and the backend's name, or a negative status.
    typealias AccelPrepare = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
                                             UnsafeMutablePointer<CChar>?, Int) -> Int32
    /// `int qlc_accel_release(qlc_model *m)`: the program wiped and released; `QLC_E_BUSY` while a stream runs on it.
    typealias AccelRelease = @convention(c) (OpaquePointer?) -> Int32
    /// `int qlc_accel_allowed(qlc_core *c)`: 1 when the lease in force allows accelerator programs (flags bit 3), 0 when
    /// it does not, else a status (no lease, a verified stop).
    typealias AccelAllowed = @convention(c) (OpaquePointer?) -> Int32
    /// `qlc_stream *qlc_stream_create_on(qlc_model *m, int backend, int *status)`: a stream on the CPU engine or on the
    /// prepared program (one such stream at a time).
    typealias StreamCreateOn = @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<Int32>?) -> OpaquePointer?
    /// `int qlc_stream_backend(const qlc_stream *s)`: `QLC_BACKEND_CPU`, `QLC_BACKEND_ANE` or `QLC_BACKEND_NPU`.
    typealias StreamBackend = @convention(c) (OpaquePointer?) -> Int32

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)   // RTLD_DEFAULT
    }

    nonisolated(unsafe) static let accelPrepare: AccelPrepare? = symbol("qlc_accel_prepare").map { unsafeBitCast($0, to: AccelPrepare.self) }
    nonisolated(unsafe) static let accelRelease: AccelRelease? = symbol("qlc_accel_release").map { unsafeBitCast($0, to: AccelRelease.self) }
    nonisolated(unsafe) static let accelAllowed: AccelAllowed? = symbol("qlc_accel_allowed").map { unsafeBitCast($0, to: AccelAllowed.self) }
    nonisolated(unsafe) static let streamCreateOn: StreamCreateOn? = symbol("qlc_stream_create_on").map { unsafeBitCast($0, to: StreamCreateOn.self) }
    nonisolated(unsafe) static let streamBackend: StreamBackend? = symbol("qlc_stream_backend").map { unsafeBitCast($0, to: StreamBackend.self) }

    /// `int qlc_lease_time(qlc_core *c, const char *time, size_t n)` (spec fix 17, a Core of `QLC_CLOCK_ANCHOR`; Core c3
    /// has none): the lease answer's signed server time, before the accept of the same answer. The Core sets its clock
    /// to it when it answers the Core's own ask, else moves it forward only; one that does not verify changes nothing.
    typealias LeaseTime = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32
    nonisolated(unsafe) static let leaseTime: LeaseTime? = symbol("qlc_lease_time").map { unsafeBitCast($0, to: LeaseTime.self) }

    /// All five: the accelerator path needs every one of them.
    static var hasAccelerator: Bool {
        accelPrepare != nil && accelRelease != nil && accelAllowed != nil && streamCreateOn != nil && streamBackend != nil
    }
}

/// Whether this process tries an accelerator at all. Never on the Simulator (the server saw many promotion failures
/// from simulators; a simulator has no Neural Engine to prove, and the Core refuses there too); only with a Core that
/// exports the accelerator calls; and on iOS 18 / macOS 15, the floor of the Core's Core ML path (the multifunction
/// package's `functionName`). Elsewhere the CPU engine runs, with no promotion attempted and no promotion incident
/// reported.
enum AcceleratorGate {
    static var available: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        guard CoreOptional.hasAccelerator else { return false }
        if #available(iOS 18.0, macOS 15.0, *) { return true }
        return false
        #endif
    }

    /// The `dispatch_dir` of `qlc_accel_prepare`: where the Core writes the compiled package for the load when the build
    /// ships no specification (a fresh `<random>.mlmodelc` it deletes before the call returns). A folder of its own for
    /// each prepare (SDK 4.0.5), `core/dispatch/<uuid>`, in the app's container with complete file protection, excluded
    /// from backup; what earlier prepares or processes left in `core/dispatch` goes first, except the folders of
    /// prepares in flight in this process. The caller gives it back with `release(_:)` when the prepare returns. Core ML
    /// keeps its own device-specialised cache in Caches (`com.apple.e5rt.e5bundlecache`), which neither the Core nor the
    /// SDK controls.
    ///
    /// Until 4.0.4 every prepare used `core/dispatch` itself and emptied it first and after, and every start of a
    /// protected runtime (every Client made) emptied it too: a second Client made, or a second prepare begun, while a
    /// prepare loaded its package deleted that package under Core ML, and the prepare failed (`accel_program`, counted
    /// against the build). Apple 4.0.2 shows the pattern without proving it (the Core keeps no reason): 60 of the 63
    /// accel_program failures of 4.0.x in the 7 days to 2026-11-25 came from one app on 11-24 and 11-25, the same app
    /// and days as 22 of the 23 failures that met a second model open on the Core (a second Client).
    static func dispatchFolder(storage: URL) -> URL {
        let root = storage.appendingPathComponent("core/dispatch", isDirectory: true)
        clear(root)
        let fm = FileManager.default
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        try? fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: protection)
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        var w = root
        try? w.setResourceValues(v)
        let u = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true, attributes: protection)
        inFlight.withLock { _ = $0.insert(u.standardizedFileURL.path) }
        return u
    }

    /// The end of the prepare that `dispatchFolder` gave `folder` to: the folder and anything left in it go.
    static func release(_ folder: URL) {
        inFlight.withLock { _ = $0.remove(folder.standardizedFileURL.path) }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The dispatch folders of the prepares running in this process: emptied only by their own prepare's end (or the
    /// process's normal exit).
    static let inFlight = Locked<Set<String>>([])

    /// Empties the dispatch folder of `storage` (at every start, and when the process exits normally), without making
    /// it, except the folders of prepares in flight in this process. A program a prepare wrote there is only ever there
    /// while that prepare runs.
    static func clearDispatch(storage: URL) {
        clear(storage.appendingPathComponent("core/dispatch", isDirectory: true))
        exitRoots.withLock { $0.insert(storage.path) }
        _ = installExitHandler
    }

    /// The storages whose dispatch folder a normal exit empties (`atexit`: a process that returns from `main` or
    /// calls `exit`, as a test runner and a command-line tool do). At exit every folder goes, a prepare's in flight too.
    static let exitRoots = Locked<Set<String>>([])
    private static let installExitHandler: Void = {
        atexit {
            for root in AcceleratorGate.exitRoots.withLock({ $0 }) {
                AcceleratorGate.clear(URL(fileURLWithPath: root).appendingPathComponent("core/dispatch", isDirectory: true), keepInFlight: false)
            }
        }
    }()

    static func clear(_ folder: URL, keepInFlight: Bool = true) {
        let fm = FileManager.default
        let keep: Set<String> = keepInFlight ? inFlight.withLock({ $0 }) : []
        for n in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let u = folder.appendingPathComponent(n)
            if keep.contains(u.standardizedFileURL.path) { continue }
            try? fm.removeItem(at: u)
        }
    }
}
