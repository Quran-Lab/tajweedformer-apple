import Foundation
#if canImport(MetricKit)
import MetricKit
#endif
#if canImport(MachO)
import MachO
#endif
#if os(iOS)
import os
#endif

// What ended the process that left a promotion sentinel (SDK 4.0). Through 3.1.x a sentinel found at launch was
// reported as `crash_on_last_run` with nothing else: a crash, a quit, a kill in the background, a jetsam and Xcode's
// stop button all looked the same (the incidents of 11-13 to 11-15: Simulators, Macs, iPhones at compile, warmup and
// golden, no frame anywhere). Now:
//
// - The sentinel carries the process id, when it was written, whether the app was in the foreground (updated on every
//   background and foreground notification), the memory footprint and, on iOS, the headroom left (a heartbeat every
//   2 s while it exists), and `quit` when the app was terminated normally during the stage (willTerminate).
// - At the next launch the report waits (at most 60 s) for the system's crash diagnostic of that process (MetricKit
//   delivers it at the next launch on iOS 15 and macOS 12 and later) and carries what it says: the Mach exception
//   type and code, the signal, the termination reason, the Objective-C exception's name (iOS 17, macOS 14), the OS
//   build it crashed on, and the crashing thread's top 12 frames: `<binary>!<symbol>+<offset>` when this process can
//   resolve the address (the same binary is loaded, same UUID: a system framework on the same OS build, or this SDK)
//   and `<binary>+0x<offset into __TEXT>` otherwise, with each binary's UUID so the rest is symbolicated off the device.
// - Never sent: the app's own frames' symbols (named `app`), memory region details, the exception's composed message,
//   the region format, any path. MetricKit delivers only when the user shares analytics with developers; without a
//   diagnostic the report says `exit: unknown` (or `background`, `quit`) and nothing else.
// - A quit during a stage (willTerminate seen) is `interrupted`: retried with the normal backoff, not a crash.

/// The report's `detail.crash` (bounded; the server's schema in qlab-api src/accel.js `CRASH`).
struct CrashEvidence: Codable, Sendable, Equatable {
    /// `crash` (a crash diagnostic of that process), `quit` (terminated normally during the stage), `background` (no
    /// diagnostic, and the app was in the background at the last heartbeat: a suspension kill or jetsam is likely),
    /// `unknown` (no diagnostic: analytics sharing off, a debugger, a kill in the foreground).
    var exit: String
    /// How the diagnostic was matched to the sentinel: `pid` (iOS 17, macOS 14) or `window` (time and OS build).
    var match: String?
    var exceptionType: Int?
    var exceptionCode: Int?
    var signal: Int?
    /// The termination reason, e.g. "Namespace SIGNAL, Code 11 Segmentation fault: 11" (paths and long numbers cut).
    var termination: String?
    var objcException: String?
    /// The OS build the crash happened on (from the diagnostic; the sentinel's when there is none).
    var osBuild: String?
    var footprintMB: Int?
    var headroomMB: Int?
    /// Seconds from the sentinel to the last heartbeat (how long the stage had run).
    var stageSeconds: Double?
    /// `<binary>:<UUID, 32 hex>` of the binaries the frames name, at most 8.
    var images: [String]?
    /// The crashing thread's frames, innermost first, at most 12, each at most 120 characters.
    var frames: [String]?

    enum CodingKeys: String, CodingKey {
        case exit, match, signal, termination, images, frames
        case exceptionType = "exception_type", exceptionCode = "exception_code", objcException = "objc_exception"
        case osBuild = "os_build", footprintMB = "footprint_mb", headroomMB = "headroom_mb", stageSeconds = "stage_s"
    }

    static let maxFrames = 12
    static let maxImages = 8

    /// Every value inside what the server takes.
    var bounded: CrashEvidence {
        var e = self
        e.exceptionType = exceptionType.map { max(0, min(64, $0)) }
        e.signal = signal.map { max(0, min(64, $0)) }
        e.termination = IncidentText.strip(termination).map { String($0.prefix(120)) }
        e.objcException = IncidentText.token(objcException, extra: "_.", max: 64)
        e.osBuild = IncidentText.token(osBuild, extra: "_.:/-", max: 64)
        e.footprintMB = footprintMB.map { max(0, min(1_000_000, $0)) }
        e.headroomMB = headroomMB.map { max(0, min(1_000_000, $0)) }
        e.stageSeconds = stageSeconds.map { (max(0, min(86_400, $0)) * 10).rounded() / 10 }
        e.images = images.map { Array($0.prefix(Self.maxImages)) }
        e.frames = frames.map { Array($0.prefix(Self.maxFrames).map { String($0.prefix(120)) }) }
        return e
    }
}

/// One frame of a MetricKit call stack.
struct CrashFrame: Equatable, Sendable {
    var binary: String
    var uuid: String?
    var offset: UInt64
}

enum CrashStacks {
    /// The crashing thread's frames from `MXCallStackTree.jsonRepresentation()`, innermost first: the thread with
    /// `threadAttributed`, its root frame and the chain of `subFrames` under it.
    static func crashingThread(_ json: Data) -> [CrashFrame] {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let stacks = o["callStacks"] as? [[String: Any]], !stacks.isEmpty else { return [] }
        let s = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks[0]
        var out: [CrashFrame] = []
        var level = s["callStackRootFrames"] as? [[String: Any]]
        while let f = level?.first, out.count < 128 {
            out.append(CrashFrame(binary: (f["binaryName"] as? String) ?? "?", uuid: f["binaryUUID"] as? String,
                                  offset: (f["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0))
            level = f["subFrames"] as? [[String: Any]]
        }
        // a chain that starts at the process's entry (dyld's start) is outermost first: turn it innermost first
        if let first = out.first, ["dyld", "libdyld.dylib"].contains(first.binary) { out.reverse() }
        return out
    }

    /// The report's frames and images. `app`: the main executable's name (its frames are `app+0x...`, never a
    /// symbol, unless the symbol is this SDK's). `resolve`: an address to a symbol and the distance from it, when
    /// this process has that binary loaded (nil in tests).
    static func describe(_ frames: [CrashFrame], app: String?,
                         resolve: (CrashFrame) -> (String, Int)? = CrashSymbols.resolve) -> (frames: [String], images: [String]) {
        var lines: [String] = []
        var images: [String] = []
        for f in frames.prefix(CrashEvidence.maxFrames) {
            let isApp = f.binary == app
            let name = isApp ? "app" : (IncidentText.token(f.binary, extra: "_.+-", max: 48) ?? "?")
            if let (sym, off) = resolve(f), !isApp || sym.contains("13TajweedFormer") || sym.hasPrefix("TajweedFormer.") {
                lines.append("\(name)!\(sym)+\(off)")
            } else {
                lines.append("\(name)+0x\(String(f.offset, radix: 16))")
            }
            if !isApp, let u = f.uuid?.replacingOccurrences(of: "-", with: "").uppercased(), u.count == 32,
               !images.contains("\(name):\(u)"), images.count < CrashEvidence.maxImages {
                images.append("\(name):\(u)")
            }
        }
        return (lines, images)
    }
}

enum CrashSymbols {
    /// The nearest exported symbol of a frame's address in this process, and the distance from it, when the binary
    /// with that UUID is loaded here (a system framework on the same OS build, the SDK). Redacted names are not used.
    static func resolve(_ f: CrashFrame) -> (String, Int)? {
        #if canImport(MachO)
        guard let u = f.uuid.flatMap(UUID.init(uuidString:)), let base = loadAddress(of: u) else { return nil }
        let addr = base.advanced(by: Int(f.offset))
        var info = Dl_info()
        guard dladdr(addr, &info) != 0, let s = info.dli_sname, let sa = info.dli_saddr else { return nil }
        let name = String(cString: s)
        guard name != "<redacted>", !name.isEmpty else { return nil }
        return (String(name.prefix(96)), UnsafeRawPointer(sa).distance(to: addr))
        #else
        return nil
        #endif
    }

    #if canImport(MachO)
    static func loadAddress(of uuid: UUID) -> UnsafeRawPointer? {
        for i in 0..<_dyld_image_count() {
            guard let h = _dyld_get_image_header(i), h.pointee.magic == MH_MAGIC_64 else { continue }
            var p = UnsafeRawPointer(h).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<h.pointee.ncmds {
                let lc = p.loadUnaligned(as: load_command.self)
                if lc.cmd == UInt32(LC_UUID) {
                    if UUID(uuid: p.loadUnaligned(as: uuid_command.self).uuid) == uuid { return UnsafeRawPointer(h) }
                    break
                }
                p = p.advanced(by: Int(lc.cmdsize))
            }
        }
        return nil
    }
    #endif

    /// The process's memory footprint, MB (what jetsam counts).
    static func footprintMB() -> Int? {
        #if canImport(MachO)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        #if compiler(>=6.1)
        let task = mach_task_self_
        #else
        // Swift 6.0's SDKs declare mach_task_self_ as a mutable C global, which Swift 6 mode refuses to read: the
        // same port, read through the dynamic loader
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "mach_task_self_") else { return nil }
        let task = sym.load(as: mach_port_t.self)
        #endif
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(task, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil
        #else
        return nil
        #endif
    }

    /// iOS: the memory this process may still use before jetsam, MB.
    static func headroomMB() -> Int? {
        #if os(iOS)
        return Int(os_proc_available_memory() / 1_048_576)
        #else
        return nil
        #endif
    }
}

/// MetricKit's crash diagnostics, kept for the sentinel of the previous launch. One subscriber per process, added at
/// the SDK's first AcceleratorController (MetricKit delivers to every subscriber: the app's own stays untouched).
final class CrashDiagnostics: NSObject, @unchecked Sendable {
    static let shared = CrashDiagnostics()

    struct Crash: Sendable {
        var pid: Int32?
        var begin: Date
        var end: Date
        var osBuild: String?
        var exceptionType: Int?
        var exceptionCode: Int?
        var signal: Int?
        var termination: String?
        var objcException: String?
        var frames: [CrashFrame]
    }

    private let lock = NSLock()
    private var crashes: [Crash] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var started = false

    /// Adds the subscriber once, and takes the payloads the system already delivered to this app.
    func start() {
        lock.lock()
        let first = !started
        started = true
        lock.unlock()
        guard first else { return }
        #if canImport(MetricKit) && !os(tvOS) && !os(watchOS)
        if #available(iOS 14.0, macOS 12.0, *) {
            MXMetricManager.shared.add(self)
            take(MXMetricManager.shared.pastDiagnosticPayloads)
        }
        #endif
    }

    func add(_ c: [Crash]) {
        lock.lock()
        crashes += c
        if crashes.count > 32 { crashes.removeFirst(crashes.count - 32) }
        let w = waiters
        waiters = []
        lock.unlock()
        for x in w { x.resume() }
    }

    /// The crash of the process that wrote `s`: by its pid when the diagnostic has one, else the one whose time range
    /// covers the sentinel on the same OS build.
    func match(_ s: PromotionStore.Sentinel) -> (Crash, String)? {
        lock.lock()
        defer { lock.unlock() }
        if let pid = s.pid, let c = crashes.last(where: { $0.pid == pid }) { return (c, "pid") }
        guard let at = s.at else { return nil }
        let c = crashes.last { c in
            c.pid == nil && c.end >= at && c.begin <= (s.heartbeat ?? at).addingTimeInterval(3600)
                && (s.osBuild == nil || c.osBuild == nil || c.osBuild == s.osBuild)
        }
        return c.map { ($0, "window") }
    }

    /// The report's evidence for the sentinel of the previous launch, waiting at most `timeout` for MetricKit.
    func evidence(for s: PromotionStore.Sentinel, timeout: TimeInterval) async -> CrashEvidence {
        let deadline = Date().addingTimeInterval(timeout)
        while match(s) == nil, Date() < deadline {
            await withTaskGroup(of: Void.self) { g in
                g.addTask { await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in self.wait(c) } }
                g.addTask { try? await Task.sleep(nanoseconds: UInt64(max(0, min(5, deadline.timeIntervalSinceNow)) * 1e9)) }
                _ = await g.next()
                g.cancelAll()
                self.wakeAll()
            }
        }
        return Self.evidence(s, match(s))
    }

    static func evidence(_ s: PromotionStore.Sentinel, _ m: (Crash, String)?,
                         app: String? = Bundle.main.executableURL?.lastPathComponent) -> CrashEvidence {
        var e = CrashEvidence(exit: "unknown")
        e.osBuild = s.osBuild
        e.footprintMB = s.footprintMB
        e.headroomMB = s.headroomMB
        if let at = s.at { e.stageSeconds = (s.heartbeat ?? at).timeIntervalSince(at) }
        if let (c, how) = m {
            e.exit = "crash"
            e.match = how
            e.exceptionType = c.exceptionType
            e.exceptionCode = c.exceptionCode
            e.signal = c.signal
            e.termination = c.termination
            e.objcException = c.objcException
            e.osBuild = c.osBuild ?? s.osBuild
            let d = CrashStacks.describe(c.frames, app: app)
            e.frames = d.frames.isEmpty ? nil : d.frames
            e.images = d.images.isEmpty ? nil : d.images
        } else if s.quit == true {
            e.exit = "quit"
        } else if s.foreground == false {
            e.exit = "background"
        }
        return e.bounded
    }

    private func wait(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        waiters.append(c)
        lock.unlock()
    }

    private func wakeAll() {
        lock.lock()
        let w = waiters
        waiters = []
        lock.unlock()
        for x in w { x.resume() }
    }

    /// "macOS 27.3 (26C5035r)", "iPhone OS 27.0.1 (24A446)" -> the build in the parentheses.
    static func build(of osVersion: String) -> String? {
        guard let a = osVersion.lastIndex(of: "("), let b = osVersion.lastIndex(of: ")"), a < b else { return nil }
        return String(osVersion[osVersion.index(after: a)..<b])
    }
}

#if canImport(MetricKit) && !os(tvOS) && !os(watchOS)
@available(iOS 14.0, macOS 12.0, *)
extension CrashDiagnostics: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) { take(payloads) }

    func take(_ payloads: [MXDiagnosticPayload]) {
        var out: [Crash] = []
        for p in payloads {
            for d in p.crashDiagnostics ?? [] {
                var c = Crash(begin: p.timeStampBegin, end: p.timeStampEnd, frames: CrashStacks.crashingThread(d.callStackTree.jsonRepresentation()))
                if #available(iOS 17.0, macOS 14.0, *) {
                    c.pid = d.metaData.pid
                    c.objcException = d.exceptionReason?.exceptionName
                }
                c.osBuild = CrashDiagnostics.build(of: d.metaData.osVersion)
                c.exceptionType = d.exceptionType?.intValue
                c.exceptionCode = d.exceptionCode?.intValue
                c.signal = d.signal?.intValue
                c.termination = d.terminationReason
                out.append(c)
            }
        }
        if !out.isEmpty { add(out) }
    }
}
#endif

/// Keeps the sentinel of this process current: the foreground state on every change, `quit` at willTerminate, and a
/// heartbeat every 2 s (footprint, headroom, time) while a stage runs. Notification names as strings, like
/// AcceleratorController's, so neither UIKit nor AppKit is needed here.
final class SentinelWatch: @unchecked Sendable {
    static let shared = SentinelWatch()

    private let lock = NSLock()
    private var stores: [String: PromotionStore] = [:]
    private var observers: [any NSObjectProtocol] = []
    private var heartbeat: Task<Void, Never>?
    private var _foreground = true
    var foreground: Bool { lock.lock(); defer { lock.unlock() }; return _foreground }

    #if canImport(UIKit) && !os(watchOS)
    static let background = ["UIApplicationDidEnterBackgroundNotification"]
    static let foregroundNames = ["UIApplicationWillEnterForegroundNotification", "UIApplicationDidBecomeActiveNotification"]
    static let terminate = "UIApplicationWillTerminateNotification"
    #else
    static let background = ["NSApplicationDidResignActiveNotification", "NSApplicationDidHideNotification"]
    static let foregroundNames = ["NSApplicationDidBecomeActiveNotification"]
    static let terminate = "NSApplicationWillTerminateNotification"
    #endif

    func attach(_ store: PromotionStore) {
        lock.lock()
        defer { lock.unlock() }
        stores[store.dir.path] = store
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        for n in Self.background {
            observers.append(nc.addObserver(forName: Notification.Name(n), object: nil, queue: nil) { [weak self] _ in self?.setForeground(false) })
        }
        for n in Self.foregroundNames {
            observers.append(nc.addObserver(forName: Notification.Name(n), object: nil, queue: nil) { [weak self] _ in self?.setForeground(true) })
        }
        observers.append(nc.addObserver(forName: Notification.Name(Self.terminate), object: nil, queue: nil) { [weak self] _ in
            // the app is quitting normally: a sentinel left now is not a crash
            for s in self?.all() ?? [] { s.updateSentinel { $0.quit = true } }
        })
        // a normal exit with no willTerminate (a command-line tool that returns from `main` or calls `exit`, an app with
        // no UIApplication or NSApplication): the same mark (the developer report on 3.1.4 of a tool that returned from
        // `main` during the warm-up, then had the build off for good with reason crash)
        atexit { SentinelWatch.shared.markQuit() }
        heartbeat = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                let fg = self.foreground
                for s in self.all() {
                    s.updateSentinel {
                        $0.heartbeat = Date()
                        $0.foreground = fg
                        $0.footprintMB = CrashSymbols.footprintMB()
                        $0.headroomMB = CrashSymbols.headroomMB()
                    }
                }
            }
        }
    }

    /// Marks this process's sentinels as quit (willTerminate, atexit).
    func markQuit() {
        for s in all() { s.updateSentinel { $0.quit = true } }
    }

    private func all() -> [PromotionStore] {
        lock.lock()
        defer { lock.unlock() }
        return Array(stores.values)
    }

    private func setForeground(_ v: Bool) {
        lock.lock()
        _foreground = v
        lock.unlock()
        for s in all() { s.updateSentinel { $0.foreground = v } }
    }
}
