import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif
#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif

// CPU first, the Neural Engine as a verified upgrade.
//
// 1. The exact CPU engine serves from the first take, always: it is built (and its weights rebuilt from the
//    correction) before any CoreML work starts.
// 2. The CoreML package is prepared in the background: the first load of the context's functions with the Neural
//    Engine allowed (which runs the on-device ANE compiler), at low priority, with a timeout. On macOS right after the
//    CPU engine is ready (utility QoS); on iOS after the first finished take (background QoS), or earlier from the
//    app's BGProcessingTask (`QuranLab.registerAcceleratorPreparation`).
// 3. A self-test before promotion: the model folder's self-test set (selftest/) through the package; greedy tokens,
//    flagged sites and flagged words identical to the expected outputs; no NaN or inf; per-chunk p90 at most half the
//    chunk's audio and the median below the CPU engine's in the same run. A failure is kept for that model revision,
//    OS build, device model and context, and never retried for them.
// 4. Promotion only when a take starts, never during one.
// 5. Runtime guards: a chunk over budget, a NaN or inf, all-blank chunks with audio in them, or an exception send the
//    recognizer back to the CPU engine (the take re-runs there); a crash sentinel written before every load and first
//    prediction disables the package for that key when found at the next launch; thermal state serious or critical
//    and memory warnings prefer the CPU engine.
// 6. The signed config's deny-list forces the CPU engine; every fallback and the time to ready go to telemetry.

/// Where the Neural Engine stands for a recognizer.
public enum AcceleratorState: Sendable, Hashable, CustomStringConvertible {
    /// The exact CPU engine serves; no accelerator work is pending (none applies, or it has not started yet).
    case cpu
    /// The CoreML package is being loaded and self-tested in the background; the CPU engine serves meanwhile.
    case preparing
    /// Passed: takes from the next one on run on the Neural Engine.
    case ready
    /// Not used, and why (an older OS, a failed self-test, a crash during a load, the deny-list, a runtime fault).
    case disabled(String)

    public var description: String {
        switch self {
        case .cpu: return "cpu"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .disabled(let why): return "disabled: \(why)"
        }
    }
}

/// What a loaded accelerator does (TajweedNeuralEngine; a fake in tests).
protocol AcceleratorBackend: AnyObject {
    func reset()
    func push(_ s: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [TajweedHeads]
    func finish() throws(RecognizerError) -> [TajweedHeads]
    /// Seconds per chunk run since the last reset.
    var chunkSeconds: [Double] { get }
}

@available(iOS 18.0, macOS 15.0, *)
extension TajweedNeuralEngine: AcceleratorBackend {}

/// What the self-test found.
public struct AcceleratorSelfTest: Sendable, Hashable {
    public let passed: Bool
    /// Why it failed, when it did.
    public let reason: String?
    /// Per-chunk compute, milliseconds: the accelerator's p90 and median, and the CPU engine's median.
    public let p90Ms: Double
    public let medianMs: Double
    public let cpuMedianMs: Double

    public init(passed: Bool, reason: String?, p90Ms: Double = 0, medianMs: Double = 0, cpuMedianMs: Double = 0) {
        self.passed = passed; self.reason = reason; self.p90Ms = p90Ms; self.medianMs = medianMs; self.cpuMedianMs = cpuMedianMs
    }
}

/// The verdicts and the crash sentinel on disk, keyed by model revision, OS build, device model, context and build.
struct AcceleratorStore: Sendable {
    struct Verdict: Codable, Sendable, Equatable {
        var passed: Bool
        var reason: String
        var date: Date
    }

    let dir: URL
    var verdictsURL: URL { dir.appendingPathComponent("accelerator-verdicts.json") }
    var tripsURL: URL { dir.appendingPathComponent("accelerator-trips.json") }

    /// Runtime watchdog trips per key, kept across launches.
    func trips(_ key: String) -> Int {
        ((try? Data(contentsOf: tripsURL)).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:])[key] ?? 0
    }

    /// One more trip for `key`; returns the new count.
    func addTrip(_ key: String) -> Int {
        var all = (try? Data(contentsOf: tripsURL)).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        all[key, default: 0] += 1
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: tripsURL, options: .atomic) }
        return all[key]!
    }
    var sentinelURL: URL { dir.appendingPathComponent("accelerator-sentinel") }

    func verdicts() -> [String: Verdict] {
        (try? Data(contentsOf: verdictsURL)).flatMap { try? JSONDecoder().decode([String: Verdict].self, from: $0) } ?? [:]
    }

    func verdict(_ key: String) -> Verdict? { verdicts()[key] }

    func set(_ key: String, _ v: Verdict) {
        var all = verdicts()
        all[key] = v
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: verdictsURL, options: .atomic) }
    }

    /// Written before a load or first prediction, removed after a clean run: found at launch, it means the app died
    /// during one.
    func writeSentinel(_ key: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(key.utf8).write(to: sentinelURL, options: .atomic)
    }

    func clearSentinel() { try? FileManager.default.removeItem(at: sentinelURL) }

    func sentinel() -> String? { (try? Data(contentsOf: sentinelURL)).flatMap { String(data: $0, encoding: .utf8) } }
}

/// The state machine of one recognizer's accelerator, free of CoreML so it can be tested with a fake.
final class AcceleratorController: @unchecked Sendable {
    struct Environment: Sendable {
        var revision: String
        var osBuild: String = DeviceInfo.osBuild
        var deviceModel: String = DeviceInfo.model
        var context: String
        var compact: Bool = false
        var storage: URL
        /// Seconds the background load may take before the CPU engine is kept for this launch.
        var timeout: TimeInterval = 180
        var thermal: @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }
        /// The deny-list rule forcing the CPU engine, with its reason; nil when none matches.
        var denied: @Sendable () -> String? = { nil }
        var record: @Sendable (AnalyticsEvent) -> Void = { _ in }
        var cohort: @Sendable () -> TelemetryCohort
    }

    typealias Load = @Sendable () async throws -> UncheckedBox<any AcceleratorBackend>
    typealias SelfTest = @Sendable (UncheckedBox<any AcceleratorBackend>) async -> AcceleratorSelfTest

    let env: Environment
    let store: AcceleratorStore
    private let lock = NSLock()
    private var _state: AcceleratorState = .cpu
    private var backend: (any AcceleratorBackend)?
    private var memoryPressure = false
    private var watchers: [UUID: AsyncStream<AcceleratorState>.Continuation] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var started = false
    private(set) var lastSelfTest: AcceleratorSelfTest?

    var key: String { [env.revision, env.osBuild, env.deviceModel, env.context, env.compact ? "compact" : "default"].joined(separator: "|") }

    init(_ env: Environment) {
        self.env = env
        store = AcceleratorStore(dir: env.storage)
        // the app died during a load or first prediction of this key: never again for it
        if let s = store.sentinel() {
            store.set(s, .init(passed: false, reason: "the app stopped during an accelerator load", date: Date()))
            store.clearSentinel()
            if s == key { env.record(.fallback(.modelLoad, cohort: env.cohort())) }
        }
        if let v = store.verdict(key), !v.passed { _state = .disabled(v.reason) }
        if let why = env.denied() { _state = .disabled(why) }
    }

    var state: AcceleratorState { lock.lock(); defer { lock.unlock() }; return _state }

    private func set(_ s: AcceleratorState) {
        lock.lock()
        _state = s
        let ws = Array(watchers.values)
        let wake: [CheckedContinuation<Void, Never>]
        if s != .preparing { wake = waiters; waiters = [] } else { wake = [] }
        lock.unlock()
        for w in ws { w.yield(s) }
        for c in wake { c.resume() }
    }

    /// Every change of state, starting with the current one.
    func states() -> AsyncStream<AcceleratorState> {
        let (stream, c) = AsyncStream<AcceleratorState>.makeStream()
        let id = UUID()
        lock.lock()
        watchers[id] = c
        let now = _state
        lock.unlock()
        c.yield(now)
        c.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.watchers[id] = nil; self.lock.unlock()
        }
        return stream
    }

    /// Waits until the state is no longer `.preparing` (or the timeout passes); true when it is `.ready`.
    func awaitReady(timeout: TimeInterval) async -> Bool {
        if state != .preparing { return state == .ready }
        await withTaskGroup(of: Void.self) { g in
            g.addTask {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    self.lock.lock()
                    if self._state != .preparing { self.lock.unlock(); c.resume(); return }
                    self.waiters.append(c)
                    self.lock.unlock()
                }
            }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1e9)) }
            _ = await g.next()
            g.cancelAll()
            // a timeout leaves the waiter registered: wake it so its task ends
            self.lock.lock()
            let w = self.waiters
            self.waiters = []
            self.lock.unlock()
            for c in w { c.resume() }
        }
        return state == .ready
    }

    /// Loads the package and self-tests it (once per controller). `load` runs with the timeout; `selfTest` runs after.
    func prepare(load: @escaping Load, selfTest: @escaping SelfTest) async {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        if case .disabled = state { return }
        if let why = env.denied() { return disable(why, reason: .other, persist: false) }
        let t0 = Date()
        set(.preparing)
        store.writeSentinel(key)
        let loaded: UncheckedBox<any AcceleratorBackend>
        do {
            loaded = try await Self.withTimeout(env.timeout, load)
        } catch is TimeoutError {
            store.clearSentinel()
            // a slow first compile: kept on the CPU engine this launch, tried again at the next
            return disable("the accelerator was not ready within \(Int(env.timeout)) s", reason: .modelLoad, persist: false)
        } catch {
            store.clearSentinel()
            return disable("the package did not load: \(error)", reason: .modelLoad, persist: true)
        }
        if let v = store.verdict(key), v.passed {
            store.clearSentinel()
            return promote(loaded.value, t0)
        }
        let r = await selfTest(loaded)
        store.clearSentinel()
        lastSelfTest = r
        env.record(.selfTest(passed: r.passed, cohort: env.cohort()))
        guard r.passed else { return disable("self-test: " + (r.reason ?? "failed"), reason: .modelLoad, persist: true) }
        store.set(key, .init(passed: true, reason: "self-test passed", date: Date()))
        promote(loaded.value, t0)
    }

    private func promote(_ b: any AcceleratorBackend, _ t0: Date) {
        lock.lock()
        backend = b
        lock.unlock()
        set(.ready)
        var c = env.cohort()
        c.backend = "ane"
        env.record(.modelLoaded(revision: env.revision, milliseconds: Date().timeIntervalSince(t0) * 1000, cohort: c))
    }

    private func disable(_ why: String, reason: FallbackReason, persist: Bool) {
        if persist { store.set(key, .init(passed: false, reason: why, date: Date())) }
        lock.lock()
        backend = nil
        lock.unlock()
        set(.disabled(why))
        env.record(.fallback(reason, cohort: env.cohort()))
    }

    /// At a take boundary: the accelerator when it is ready and nothing prefers the CPU engine now; else nil.
    func backendForTake() -> (any AcceleratorBackend)? {
        guard state == .ready else { return nil }
        let t = env.thermal()
        if t == .serious || t == .critical {
            env.record(.fallback(.thermal, cohort: env.cohort()))
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return memoryPressure ? nil : backend
    }

    /// Watchdog trips on one key (model revision, OS build, device model, context, build) that disable the accelerator
    /// for that key for good; a new revision or OS build is a new key and starts again from zero.
    static let tripsToDisable = 2

    /// A watchdog trip during a take (non-finite head, deadline, all-blank chunks, an exception): the CPU engine from
    /// now on in this launch. The trip is counted on disk for the key; at `tripsToDisable` the accelerator is disabled
    /// for that key across launches, like a crash during a load.
    func runtimeFault(_ reason: FallbackReason, _ detail: String) {
        let n = store.addTrip(key)
        if n >= Self.tripsToDisable {
            disable("the runtime watchdog tripped \(n) times on this model revision and OS build (last: \(detail))",
                    reason: reason, persist: true)
        } else {
            disable(detail, reason: reason, persist: false)
        }
    }

    /// A memory warning: the CPU engine for the rest of this launch, and the package released.
    func memoryWarning() {
        lock.lock()
        memoryPressure = true
        lock.unlock()
        if state == .ready { disable("a memory warning", reason: .memory, persist: false) }
    }

    struct TimeoutError: Error {}

    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { g in
            g.addTask { try await body() }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9))
                return nil
            }
            defer { g.cancelAll() }
            guard let first = try await g.next(), let v = first else { throw TimeoutError() }
            return v
        }
    }
}

/// The model folder's self-test set (role `selftest`): `selftest/selftest.json`, the clips as 16 kHz int16
/// (`selftest/<clip>.s16`, samples q / 32768), and per context the exact CPU engine's expected outputs at the default
/// settings (`selftest/expected_<ctx>.json`).
struct SelfTestSet: Sendable {
    struct Clip: Sendable {
        let id: String
        let surah: Int
        let ayah: Int
        let samples: [Float]
        let mustDecode: Bool
        /// A planted-mistake clip (`"kind": "planted"` or `"planted": true`): only its flags must agree, not its tokens
        /// (the int8 CPU engine may decode a mistaken reading differently from fp16 / fp32 while flagging the same
        /// sites). Absent means clean: every token must agree.
        let planted: Bool
    }
    struct Expected: Sendable {
        let tokens: [Int]
        let flaggedSites: Set<String>   // "pos|class"
        let flaggedWords: Set<Int>
    }

    let clips: [Clip]
    let expected: [String: Expected]

    static func load(_ dir: URL, context: String) -> SelfTestSet? {
        let st = dir.appendingPathComponent("selftest")
        guard let meta = (try? Data(contentsOf: st.appendingPathComponent("selftest.json"))).flatMap({ JSONValue(data: $0) }),
              meta["format"]?.string == "quranlab.selftest/1",
              let exp = (try? Data(contentsOf: st.appendingPathComponent("expected_\(context).json"))).flatMap({ JSONValue(data: $0) }),
              exp["format"]?.string == "quranlab.selftest-expected/1" else { return nil }
        var clips: [Clip] = []
        for c in meta["clips"]?.array ?? [] {
            guard let id = c["id"]?.string, let file = c["file"]?.string,
                  let raw = try? Data(contentsOf: st.appendingPathComponent((file as NSString).lastPathComponent)) else { return nil }
            let samples = raw.withUnsafeBytes { r in
                (0..<(r.count / 2)).map { Float(Int16(littleEndian: r.loadUnaligned(fromByteOffset: 2 * $0, as: Int16.self))) / 32768 }
            }
            clips.append(Clip(id: id, surah: Int(c["surah"]?.number ?? 0), ayah: Int(c["ayah"]?.number ?? 0), samples: samples,
                              mustDecode: c["must_decode"]?.bool ?? false,
                              planted: Self.isPlanted(c)))
        }
        var expected: [String: Expected] = [:]
        for (id, e) in exp["clips"]?.object ?? [:] {
            let sites = (e["flagged_sites"]?.array ?? []).compactMap { p -> String? in
                guard let a = p.array, a.count == 2, let pos = a[0].number, let cls = a[1].string else { return nil }
                return "\(Int(pos))|\(cls)"
            }
            expected[id] = Expected(tokens: (e["tokens"]?.array ?? []).compactMap { $0.number.map(Int.init) },
                                    flaggedSites: Set(sites), flaggedWords: Set((e["flagged_words"]?.array ?? []).compactMap { $0.number.map(Int.init) }))
        }
        guard !clips.isEmpty, clips.allSatisfy({ expected[$0.id] != nil }) else { return nil }
        return SelfTestSet(clips: clips, expected: expected)
    }

    /// A clip's kind: `kind` is authoritative ("planted" or "clean"); without it, `planted` marks a planted clip when it
    /// is `true` or an object (revision e describes the planted mistake there). Any other value, or none, is clean.
    /// Unknown keys and unexpected types never fail the set.
    static func isPlanted(_ c: JSONValue) -> Bool {
        if let k = c["kind"]?.string { return k == "planted" }
        if c["planted"]?.bool == true || c["planted"]?.object != nil { return true }
        return false
    }

    /// One clip's decisions against its expected ones: on a clean clip the token sequence; on every clip, planted ones
    /// included, the flagged sites and flagged words as sets compared in both directions (a missed flag and an extra
    /// flag both fail; an expected set may be empty or not). Sites are numbered by the engine's expected-token
    /// position, as the engine wrote the expected files. Nil when they agree, else why not.
    static func compare(clip: String, planted: Bool = false, expected e: Expected, tokens: [Int], flaggedSites: Set<String>,
                        flaggedWords: Set<Int>) -> String? {
        if !planted && tokens != e.tokens { return "\(clip): tokens differ (\(tokens.count) against \(e.tokens.count) expected)" }
        let missedSites = e.flaggedSites.subtracting(flaggedSites).sorted(), extraSites = flaggedSites.subtracting(e.flaggedSites).sorted()
        if !missedSites.isEmpty || !extraSites.isEmpty {
            return "\(clip): flagged sites differ (missed \(missedSites), extra \(extraSites))"
        }
        let missedWords = e.flaggedWords.subtracting(flaggedWords).sorted(), extraWords = flaggedWords.subtracting(e.flaggedWords).sorted()
        if !missedWords.isEmpty || !extraWords.isEmpty {
            return "\(clip): flagged words differ (missed \(missedWords), extra \(extraWords))"
        }
        return nil
    }

    /// The pass rule on the per-clip outcomes and the per-chunk times (seconds).
    static func judge(mismatch: String?, accelerator: [Double], cpu: [Double], chunkMs: Int) -> AcceleratorSelfTest {
        func pct(_ v: [Double], _ p: Double) -> Double {
            guard !v.isEmpty else { return 0 }
            let s = v.sorted()
            return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
        }
        let p90 = pct(accelerator, 0.9) * 1000, med = pct(accelerator, 0.5) * 1000, cpuMed = pct(cpu, 0.5) * 1000
        if let mismatch { return .init(passed: false, reason: mismatch, p90Ms: p90, medianMs: med, cpuMedianMs: cpuMed) }
        if p90 > 0.5 * Double(chunkMs) {
            return .init(passed: false, reason: String(format: "chunk p90 %.1f ms is over half of %d ms", p90, chunkMs),
                         p90Ms: p90, medianMs: med, cpuMedianMs: cpuMed)
        }
        if !(med < cpuMed) {
            return .init(passed: false, reason: String(format: "median %.2f ms is not below the CPU engine's %.2f ms", med, cpuMed),
                         p90Ms: p90, medianMs: med, cpuMedianMs: cpuMed)
        }
        return .init(passed: true, reason: nil, p90Ms: p90, medianMs: med, cpuMedianMs: cpuMed)
    }
}

/// Recognizers whose accelerator waits to be prepared, for the app's background task.
enum AcceleratorRegistry {
    static let pending = Locked<[UUID: @Sendable () async -> Void]>([:])

    static func add(_ id: UUID, _ run: @escaping @Sendable () async -> Void) { pending.withLock { $0[id] = run } }
    static func remove(_ id: UUID) { _ = pending.withLock { $0.removeValue(forKey: id) } }

    static func runAll() async {
        let all = pending.withLock { p -> [@Sendable () async -> Void] in
            defer { p = [:] }
            return Array(p.values)
        }
        for r in all { await r() }
    }
}

extension QuranLab {
    #if canImport(BackgroundTasks) && os(iOS)
    /// Lets the app prepare the Neural Engine while the device is idle and charging: call once at launch, before the
    /// app finishes launching, with an identifier listed in the app's `BGTaskSchedulerPermittedIdentifiers`. Without
    /// it, the SDK prepares after the first finished take, at background priority.
    public static func registerAcceleratorPreparation(identifier: String) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let box = UncheckedBox(task)
            let work = Task.detached(priority: .background) {
                await AcceleratorRegistry.runAll()
                box.value.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
        let r = BGProcessingTaskRequest(identifier: identifier)
        r.requiresExternalPower = true
        r.requiresNetworkConnectivity = false
        try? BGTaskScheduler.shared.submit(r)
    }
    #endif
}
