import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif
#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif

// CPU first, then a verified, seamless promotion to the Neural Engine.
//
// 1. The first install of a model downloads the CPU set only; the first session runs on the exact CPU engine and
//    nothing is queued in front of it. The promotion pipeline of a key never seen before starts after the first
//    session ends, or after `PromotionPolicy.idleStartDelay` without one; a later launch starts it at launch, at low
//    priority. Sessions never wait for it.
// 2. One persisted state machine per key (model revision, context, build, OS build, device model; `PromotionRecord`):
//    download (unmetered network), compile (the first load with the Neural Engine allowed, 10 min timeout), warmup
//    (silence and the first self-test clip, no NaN or inf), golden (every self-test clip through the accelerator and
//    the CPU engine: the same decisions, the CPU's equal to the shipped expected file), measure (speedup, telemetry
//    only: a slower build is promoted too), promote. The record is written after each stage; a restart resumes at the
//    stage after the last one recorded; a crash sentinel around every compile, load and first inference turns a
//    process death there into reason `crash` at the next launch.
// 3. The golden and measure stages run only while no session runs (a session starting aborts them without a
//    failure), and the whole pipeline only in good conditions (not Low Power Mode, battery at least 20 % or charging,
//    thermal nominal or fair).
// 4. The swap happens at a session boundary only, to a build that is loaded and warm; a session that started before
//    stays on the CPU engine.
// 5. Failures keep the CPU engine: retried for the same key after 1 h, 6 h, 24 h, then never; deterministic ones
//    (golden_mismatch, cpu_mismatch, non_finite, crash) never. A failover in a session (Failover.swift) demotes the
//    build and retests it no sooner than 24 h later, within the same budget.

/// Where the Neural Engine stands for a recognizer.
public enum AcceleratorState: Sendable, Hashable, CustomStringConvertible {
    /// The exact CPU engine serves; no accelerator work runs now (none applies, it has not started, or it waits).
    case cpu
    /// The promotion pipeline is running in the background; the CPU engine serves meanwhile.
    case preparing
    /// Promoted, loaded and warm: sessions from the next one on run on the Neural Engine.
    case ready
    /// Not used, and why (an older OS, a failed stage, a crash, the deny-list, a failover).
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
    /// The error behind the last failed call, when the runtime gave one.
    var lastError: NSError? { get }
}

extension AcceleratorBackend {
    var lastError: NSError? { nil }
}

@available(iOS 18.0, macOS 15.0, *)
extension TajweedNeuralEngine: AcceleratorBackend {}

/// What the golden test found (the last attempt of this key that got that far).
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

    /// CPU median over the accelerator's median (telemetry only: a build below 1 is promoted too).
    public var speedup: Double { medianMs > 0 ? cpuMedianMs / medianMs : 0 }
}

/// An accelerator incident for the issue reports (`accelerator_failover`, `promotion_failed`; PLATFORM_CLIENT 7.1).
struct AcceleratorIncident: Sendable, Equatable {
    enum Kind: String, Sendable { case failover = "accelerator_failover", promotionFailed = "promotion_failed" }
    var kind: Kind
    /// download, compile, warmup, golden, or session (a failover).
    var stage: String
    var cause: String
    var message: String?
    var errorDomain: String?
    var errorCode: String?
    var chunk: Int?
    var elapsedMs: Double?
    var deadlineMs: Double?
    var clip: String?
    var divergence: Divergence?
    var stallMs: Double?
    var attempt: Int?
    var revision: String
    var context: String
    var thermal: String?
    var lowPower: Bool?
    var code: String { "\(stage):\(cause)" }
}

/// The promotion pipeline of one key, and the build it promoted. Free of CoreML: the stages are closures, so the
/// state machine is tested with fakes (AcceleratorTests, PromotionTests).
final class AcceleratorController: @unchecked Sendable {
    struct Timeouts: Sendable {
        var compile = PromotionPolicy.compileTimeout
        var load = PromotionPolicy.loadTimeout
        var warmup = PromotionPolicy.warmupTimeout
        var golden = PromotionPolicy.goldenTimeout
    }

    struct Environment: Sendable {
        var revision: String
        var osBuild: String = DeviceInfo.osBuild
        var deviceModel: String = DeviceInfo.model
        var context: String
        /// `coreml` or `coreml-compact`.
        var build: String = "coreml"
        var storage: URL
        /// This process; at most one new attempt per launch for a key.
        var launch: String = AcceleratorController.thisLaunch
        var clock: @Sendable () -> Date = { Date() }
        var sleep: @Sendable (TimeInterval) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1e9)) }
        var conditions: @Sendable (_ network: Bool) async -> PromotionConditions = { n in await PromotionConditions.current(network: n) }
        /// Waits on bad conditions in one run before it gives up for now (no failure; the next trigger resumes).
        var maxConditionWaits = 30
        var thermal: @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }
        /// The deny-list rule forcing the CPU engine, with its reason; nil when none matches.
        var denied: @Sendable () -> String? = { nil }
        var record: @Sendable (AnalyticsEvent) -> Void = { _ in }
        var incident: @Sendable (AcceleratorIncident) -> Void = { _ in }
        var cohort: @Sendable () -> TelemetryCohort
        var timeouts = Timeouts()
    }

    enum GoldenOutcome: Sendable {
        /// Every clip agreed; per-chunk compute seconds of the accelerator and of the CPU engine.
        case passed(accelerator: [Double], cpu: [Double])
        case failed(PromotionFailure)
        /// A session started: run again later, not a failure.
        case aborted
    }

    /// The work of the stages (the recognizer's; fakes in tests).
    struct Stages: Sendable {
        var download: @Sendable () async throws(PromotionFailure) -> Void
        /// Loads the build with the Neural Engine allowed (the device-specific compile on a first load).
        var compile: @Sendable () async throws(PromotionFailure) -> UncheckedBox<any AcceleratorBackend>
        var warmup: @Sendable (UncheckedBox<any AcceleratorBackend>) async throws(PromotionFailure) -> Void
        var golden: @Sendable (UncheckedBox<any AcceleratorBackend>) async -> GoldenOutcome
        var sessionActive: @Sendable () async -> Bool
        var waitIdle: @Sendable () async -> Void
        /// The SHA-256 of the build's program on disk ("gone" when it is not there; nil when unknown).
        var fingerprint: @Sendable () -> String? = { nil }
    }

    static let thisLaunch = UUID().uuidString

    let env: Environment
    let store: PromotionStore
    private let lock = NSLock()
    private var _state: AcceleratorState = .cpu
    private var executor: AcceleratorExecutor?
    private var leased = false
    private var running = false
    private var memoryPressure = false
    private var watchers: [UUID: AsyncStream<AcceleratorState>.Continuation] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var key: String { Self.key(revision: env.revision, context: env.context, build: env.build, osBuild: env.osBuild, deviceModel: env.deviceModel) }

    static func key(revision: String, context: String, build: String, osBuild: String = DeviceInfo.osBuild,
                    deviceModel: String = DeviceInfo.model) -> String {
        [revision, context, build, osBuild, deviceModel].joined(separator: "|")
    }

    init(_ env: Environment) {
        self.env = env
        store = PromotionStore(dir: env.storage)
        // the process died during a compile, load or first inference: that key's attempt ends with reason crash
        if let s = store.sentinel() {
            store.clearSentinel()
            var r = store.record(s.key) ?? PromotionRecord(key: s.key)
            let wasReady = r.status == .ready
            recordFailure(&r, s.stage, PromotionFailure(.crash, "the app stopped during the \(s.stage.rawValue) stage"), reload: wasReady,
                          sameKey: s.key == key)
        }
        let r = store.record(key)
        if let why = env.denied() {
            _state = .disabled(why)
        } else if let r, r.status == .failed {
            _state = .disabled(r.lastDetail ?? "failed")
        }
    }

    /// The persisted record of this key.
    var record: PromotionRecord? { store.record(key) }

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
                    if !self.addWaiter(c) { c.resume() }
                }
            }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1e9)) }
            _ = await g.next()
            g.cancelAll()
            // a timeout leaves the waiter registered: wake it so its task ends
            for c in self.takeWaiters() { c.resume() }
        }
        return state == .ready
    }

    // NSLock.lock() and unlock() are unavailable from async code: the critical sections live in synchronous methods.
    private func addWaiter(_ c: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard _state == .preparing else { return false }
        waiters.append(c)
        return true
    }

    private func takeWaiters() -> [CheckedContinuation<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        let w = waiters
        waiters = []
        return w
    }

    private func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if running { return false }
        running = true
        return true
    }

    private func finishRun() {
        lock.lock()
        running = false
        lock.unlock()
    }

    /// Whether a run is in progress now.
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func hold(_ b: UncheckedBox<any AcceleratorBackend>?) {
        lock.lock()
        executor = b.map { AcceleratorExecutor($0.value) }
        lock.unlock()
    }

    private var hasExecutor: Bool { lock.lock(); defer { lock.unlock() }; return executor.map { !$0.abandoned } ?? false }

    // MARK: the pipeline

    /// Runs the pipeline for this key as far as it can go now (at most one run in flight; at most one new attempt per
    /// launch). A promoted key is loaded and warmed (no golden test again). Returns when the build is ready, has
    /// failed, or has to wait (backoff, conditions, nothing to do).
    func run(_ stages: Stages) async {
        guard begin() else { return }
        defer { finishRun() }
        var rec = store.record(key) ?? PromotionRecord(key: key)
        if let why = env.denied() { return noteDenied(&rec, why) }
        if rec.denied {
            rec.denied = false
            store.save(rec)
        }
        if hasExecutor, state == .ready { return }
        // a promoted key whose program changed or is gone: tested again from the start, not counted as a failure
        if rec.status == .ready, let had = rec.programSHA256, let now = stages.fingerprint(), now != had {
            rec.status = .pending
            rec.completed = nil
            rec.attemptStarted = nil
            rec.launch = nil
            rec.failures = 0
            rec.programSHA256 = nil
            store.save(rec)
        }
        switch rec.status {
        case .failed:
            return set(.disabled(rec.lastDetail ?? "failed"))
        case .retry:
            if let nb = rec.notBefore, env.clock() < nb {
                return set(.disabled("\(rec.lastDetail ?? "failed"); tried again after \(Self.iso(nb))"))
            }
        case .ready:
            return await reload(&rec, stages)
        case .pending:
            break
        }
        if rec.attemptStarted == nil {
            // a new attempt: at most one per launch
            guard rec.launch != env.launch else { return set(.cpu) }
            rec.attempts += 1
            rec.attemptStarted = env.clock()
            rec.completed = nil
            rec.status = .pending
        }
        rec.launch = env.launch
        store.save(rec)
        set(.preparing)
        var backend: UncheckedBox<any AcceleratorBackend>?
        var stage = rec.resumeStage
        // resumed after a restart past the warm-up: the build is loaded and warmed again, then the attempt goes on
        // where it stopped
        var afterRewarm: PromotionStage?
        if stage > .warmup {
            afterRewarm = stage
            stage = .warmup
        }
        while true {
            guard await waitConditions(stage) else { return set(.cpu) }
            switch stage {
            case .download:
                do throws(PromotionFailure) { try await stages.download() } catch { return fail(&rec, .download, error) }
            case .compile:
                store.writeSentinel(key, .compile)
                let t0 = env.clock()
                let r = await Self.race(env.timeouts.compile,
                                        onTimeout: PromotionFailure(.compileTimeout, "the compile took over \(Int(env.timeouts.compile)) s"),
                                        stages.compile)
                store.clearSentinel()
                switch r {
                case .failure(let f): return fail(&rec, .compile, f)
                case .success(let b): backend = b
                }
                rec.compileMs = env.clock().timeIntervalSince(t0) * 1000
            case .warmup:
                if backend == nil {
                    switch await load(stages) {
                    case .failure(let f): return fail(&rec, .warmup, f)
                    case .success(let b): backend = b
                    }
                }
                if let f = await warm(backend!, stages) { return fail(&rec, .warmup, f) }
            case .golden:
                switch await golden(backend!, stages) {
                case .failure(let f): return fail(&rec, .golden, f)
                case .success(let t):
                    rec.acceleratorMedianMs = Self.percentile(t.accelerator, 0.5) * 1000
                    rec.acceleratorP90Ms = Self.percentile(t.accelerator, 0.9) * 1000
                    rec.cpuMedianMs = Self.percentile(t.cpu, 0.5) * 1000
                    env.record(.selfTest(passed: true, cohort: env.cohort()))
                }
            case .measure:
                // telemetry only: the speedup never keeps a build that passed off the accelerator
                break
            case .promote:
                rec.status = .ready
                rec.completed = .promote
                rec.programSHA256 = stages.fingerprint()
                rec.attemptStarted = nil
                rec.failures = 0
                store.save(rec)
                hold(backend)
                promotion(.attempt(promoted: true, stage: nil, reason: nil, compileMs: rec.compileMs, speedup: rec.speedup))
                var c = env.cohort()
                c.backend = "ane"
                env.record(.modelLoaded(revision: env.revision, milliseconds: rec.compileMs ?? 0, cohort: c))
                return set(.ready)
            }
            if stage == .warmup, let resume = afterRewarm {
                afterRewarm = nil
                stage = resume
                continue
            }
            rec.completed = stage
            store.save(rec)
            guard let n = stage.next else { return }
            stage = n
        }
    }

    /// A key promoted in an earlier launch: load the compiled build again and warm it (the CPU engine serves meanwhile).
    private func reload(_ rec: inout PromotionRecord, _ stages: Stages) async {
        set(.preparing)
        guard await waitConditions(.warmup) else { return set(.cpu) }
        let backend: UncheckedBox<any AcceleratorBackend>
        switch await load(stages) {
        case .failure(let f): return fail(&rec, .warmup, f, reload: true)
        case .success(let b): backend = b
        }
        if let f = await warm(backend, stages) { return fail(&rec, .warmup, f, reload: true) }
        hold(backend)
        set(.ready)
    }

    /// The load of a build compiled before (a sentinel around it; a load error, or a hang past the timeout).
    private func load(_ stages: Stages) async -> Result<UncheckedBox<any AcceleratorBackend>, PromotionFailure> {
        store.writeSentinel(key, .warmup)
        let r = await Self.race(env.timeouts.load, onTimeout: PromotionFailure(.hang, "the load took over \(Int(env.timeouts.load)) s"),
                                stages.compile)
        store.clearSentinel()
        if case .failure(var f) = r, f.reason == .compileError || f.reason == .compileTimeout {
            f.reason = f.reason == .compileError ? .loadError : .hang
            return .failure(f)
        }
        return r
    }

    private func warm(_ b: UncheckedBox<any AcceleratorBackend>, _ stages: Stages) async -> PromotionFailure? {
        store.writeSentinel(key, .warmup)
        defer { store.clearSentinel() }
        let r = await Self.race(env.timeouts.warmup, onTimeout: PromotionFailure(.hang, "the warm-up took over \(Int(env.timeouts.warmup)) s")) {
            () async throws(PromotionFailure) -> Bool in
            try await stages.warmup(b)
            return true
        }
        if case .failure(let f) = r { return f }
        return nil
    }

    /// The golden test, only while no session runs: a session that starts during it aborts it without a failure, and
    /// it runs again once the recognizer is idle.
    private func golden(_ b: UncheckedBox<any AcceleratorBackend>, _ stages: Stages) async -> Result<(accelerator: [Double], cpu: [Double]), PromotionFailure> {
        while true {
            if await stages.sessionActive() {
                await stages.waitIdle()
                continue
            }
            store.writeSentinel(key, .golden)
            let r = await Self.race(env.timeouts.golden, onTimeout: PromotionFailure(.hang, "the golden test took over \(Int(env.timeouts.golden)) s")) {
                () async throws(PromotionFailure) -> GoldenOutcome in await stages.golden(b)
            }
            store.clearSentinel()
            switch r {
            case .failure(let f): return .failure(f)
            case .success(.failed(let f)): return .failure(f)
            case .success(.aborted): await stages.waitIdle()
            case .success(.passed(let a, let c)): return .success((a, c))
            }
        }
    }

    /// Waits while conditions are bad (no failure counted); false when it gave up for now.
    private func waitConditions(_ stage: PromotionStage) async -> Bool {
        var waits = 0
        while true {
            if Task.isCancelled { return false }
            let c = await env.conditions(stage == .download)
            guard c.blocker(for: stage) != nil else { return true }
            waits += 1
            if waits > env.maxConditionWaits { return false }
            await env.sleep(PromotionPolicy.conditionsRecheck)
        }
    }

    private func fail(_ rec: inout PromotionRecord, _ stage: PromotionStage, _ f: PromotionFailure, reload: Bool = false) {
        hold(nil)
        recordFailure(&rec, stage, f, reload: reload, sameKey: true)
    }

    /// Ends the attempt with a failure (or demotes a promoted key that failed to load again): the record, the retry
    /// time, the telemetry and the incident report.
    private func recordFailure(_ rec: inout PromotionRecord, _ stage: PromotionStage, _ f: PromotionFailure, reload: Bool, sameKey: Bool) {
        rec.failures += 1
        rec.lastStage = stage
        rec.lastReason = f.reason
        rec.lastDetail = "\(stage.rawValue): \(f.detail)"
        rec.completed = nil
        rec.attemptStarted = nil
        if f.reason.deterministic || rec.failures > PromotionPolicy.backoff.count {
            rec.status = .failed
            rec.notBefore = nil
        } else {
            rec.status = .retry
            rec.notBefore = env.clock().addingTimeInterval(PromotionPolicy.backoff[rec.failures - 1])
        }
        store.save(rec)
        let parts = rec.key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let revision = parts.first ?? env.revision, context = parts.count > 1 ? parts[1] : env.context
        if reload {
            promotion(.demoted(f.reason), revision: revision, context: context)
        } else {
            promotion(.attempt(promoted: false, stage: stage, reason: f.reason, compileMs: stage > .compile ? rec.compileMs : nil, speedup: nil),
                      revision: revision, context: context)
        }
        if stage == .golden { env.record(.selfTest(passed: false, cohort: env.cohort())) }
        env.record(.fallback(f.reason == .nonFinite ? .nonFinite : .modelLoad, cohort: env.cohort()))
        let c = AcceleratorController.conditionsNow()
        env.incident(AcceleratorIncident(kind: .promotionFailed, stage: stage.rawValue, cause: f.reason.incidentCause, message: f.detail,
                                         errorDomain: f.errorDomain, errorCode: f.errorCode, clip: f.clip, divergence: f.divergence,
                                         attempt: max(1, min(100, rec.attempts)), revision: revision, context: context,
                                         thermal: c.thermal, lowPower: c.lowPower))
        if sameKey { set(.disabled(rec.lastDetail ?? f.detail)) }
    }

    private func noteDenied(_ rec: inout PromotionRecord, _ why: String) {
        hold(nil)
        if !rec.denied {
            rec.denied = true
            rec.lastReason = .denylist
            rec.lastDetail = why
            store.save(rec)
            promotion(.demoted(.denylist))
            env.record(.fallback(.other, cohort: env.cohort()))
        }
        set(.disabled(why))
    }

    private func promotion(_ k: PromotionTelemetry.Kind, revision: String? = nil, context: String? = nil) {
        env.record(.promotion(PromotionTelemetry(backend: "ane", revision: revision ?? env.revision, context: context ?? env.context, kind: k)))
    }

    static func conditionsNow() -> (thermal: String, lowPower: Bool) {
        let c = PromotionConditions(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
        return (c.thermalName, c.lowPower)
    }

    // MARK: sessions

    /// At a session boundary: the promoted build's executor when it is ready and nothing prefers the CPU engine now
    /// (thermal state serious or critical, a memory warning, the deny-list), and no other session holds it; else nil.
    /// The caller gives it back with `endLease()` at the end of the session.
    func leaseForSession() -> AcceleratorExecutor? {
        guard state == .ready else { return nil }
        if let why = env.denied() {
            var rec = store.record(key) ?? PromotionRecord(key: key)
            noteDenied(&rec, why)
            return nil
        }
        let t = env.thermal()
        if t == .serious || t == .critical {
            env.record(.fallback(.thermal, cohort: env.cohort()))
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        guard !memoryPressure, !leased, let e = executor, !e.abandoned else { return nil }
        leased = true
        return e
    }

    func endLease() {
        lock.lock()
        leased = false
        lock.unlock()
    }

    /// A session left the accelerator (Failover.swift): the build is demoted for this key (later sessions start on the
    /// CPU engine) and retested by the pipeline no sooner than 24 h later, within the key's retry budget.
    func failedOver(_ f: TakeRunner.Failover) {
        hold(nil)
        var rec = store.record(key) ?? PromotionRecord(key: key)
        rec.failures += 1
        rec.lastStage = nil
        rec.lastReason = .failover
        rec.lastDetail = "failover: \(f.detail)"
        rec.completed = nil
        rec.attemptStarted = nil
        if rec.failures > PromotionPolicy.backoff.count {
            rec.status = .failed
            rec.notBefore = nil
        } else {
            rec.status = .retry
            rec.notBefore = env.clock().addingTimeInterval(max(PromotionPolicy.backoff[rec.failures - 1], PromotionPolicy.failoverRetest))
        }
        store.save(rec)
        promotion(.failover(cause: f.cause, stallMs: f.stallMs))
        promotion(.demoted(.failover))
        let reason: FallbackReason = f.cause == .nonFinite ? .nonFinite : f.cause == .deadline ? .deadline : .other
        env.record(.fallback(reason, cohort: env.cohort()))
        let c = AcceleratorController.conditionsNow()
        env.incident(AcceleratorIncident(kind: .failover, stage: "session", cause: f.cause.incidentCause, message: f.detail,
                                         errorDomain: f.errorDomain, errorCode: f.errorCode, chunk: f.chunk, elapsedMs: f.elapsedMs,
                                         deadlineMs: f.deadlineMs, stallMs: f.stallMs, revision: env.revision, context: env.context,
                                         thermal: c.thermal, lowPower: c.lowPower))
        set(.disabled(rec.lastDetail!))
    }

    /// A memory warning: the CPU engine for the rest of this launch, and the package released.
    func memoryWarning() {
        lock.lock()
        memoryPressure = true
        let busy = leased
        lock.unlock()
        if state == .ready && !busy {
            hold(nil)
            set(.disabled("a memory warning"))
            env.record(.fallback(.memory, cohort: env.cohort()))
        }
    }

    /// The failover deadline from the measure stage (300 ms before a measurement).
    var deadlineMs: Double {
        let r = record
        return PromotionPolicy.deadlineMs(p90Ms: r?.acceleratorP90Ms, medianMs: r?.acceleratorMedianMs)
    }

    /// The golden test's numbers, for `TajweedRecognizer.acceleratorSelfTest`.
    var lastSelfTest: AcceleratorSelfTest? {
        guard let r = record else { return nil }
        if r.lastReason == .goldenMismatch || r.lastReason == .cpuMismatch || (r.lastStage == .golden && r.status != .ready) {
            return AcceleratorSelfTest(passed: false, reason: r.lastDetail)
        }
        guard let m = r.acceleratorMedianMs else { return nil }
        return AcceleratorSelfTest(passed: true, reason: nil, p90Ms: r.acceleratorP90Ms ?? 0, medianMs: m, cpuMedianMs: r.cpuMedianMs ?? 0)
    }

    // MARK: helpers

    /// Runs `body` and gives up waiting for it after `seconds`: a body that never returns is abandoned (it may go on in
    /// the background; its result is dropped), unlike a task group, which would wait for it.
    static func race<T: Sendable>(_ seconds: TimeInterval, onTimeout: PromotionFailure,
                                  _ body: @escaping @Sendable () async throws(PromotionFailure) -> T) async -> Result<T, PromotionFailure> {
        let gate = Locked(false)
        return await withCheckedContinuation { (c: CheckedContinuation<Result<T, PromotionFailure>, Never>) in
            let first: @Sendable (Result<T, PromotionFailure>) -> Void = { r in
                let win = gate.withLock { (done: inout Bool) -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if win { c.resume(returning: r) }
            }
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9))
                if !Task.isCancelled { first(.failure(onTimeout)) }
            }
            Task {
                do throws(PromotionFailure) {
                    let v = try await body()
                    first(.success(v))
                } catch {
                    first(.failure(error))
                }
                timer.cancel()
            }
        }
    }

    static func percentile(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: d)
    }

    // MARK: one controller per key in the process

    private struct Weak: @unchecked Sendable { weak var value: AcceleratorController? }
    private static let registry = Locked<[String: Weak]>([:])

    /// The controller of `env`'s key: the same one for every recognizer of the process (one run in flight per key, one
    /// loaded build).
    static func shared(_ env: Environment) -> AcceleratorController {
        let probe = key(revision: env.revision, context: env.context, build: env.build, osBuild: env.osBuild, deviceModel: env.deviceModel)
        return registry.withLock { (r: inout [String: Weak]) -> AcceleratorController in
            if let c = r[probe]?.value, c.env.storage == env.storage { return c }
            let c = AcceleratorController(env)
            r[probe] = Weak(value: c)
            return c
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
        /// The planted mistake's site as "pos|class" (its tj3 position and class), when the set describes it: the
        /// accelerator must flag it, whatever the tolerance.
        var plantedSite: String? = nil
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
            let planted = Self.isPlanted(c)
            var site: String?
            if planted, let p = c["planted"], let pos = p["pos"]?.number ?? p["tj3_pos"]?.number, let cls = p["class"]?.string {
                site = "\(Int(pos))|\(cls)"
            }
            clips.append(Clip(id: id, surah: Int(c["surah"]?.number ?? 0), ayah: Int(c["ayah"]?.number ?? 0), samples: samples,
                              mustDecode: c["must_decode"]?.bool ?? false, planted: planted, plantedSite: site))
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

    /// The pass rule's verdict from the clips' comparison, with the per-chunk times (seconds) for the measure stage.
    /// Speed is never part of it (Quran Lab, 11-10): a build that agrees is promoted, slower or not.
    static func judge(mismatch: String?, accelerator: [Double], cpu: [Double]) -> AcceleratorSelfTest {
        let p90 = AcceleratorController.percentile(accelerator, 0.9) * 1000
        let med = AcceleratorController.percentile(accelerator, 0.5) * 1000
        let cpuMed = AcceleratorController.percentile(cpu, 0.5) * 1000
        return .init(passed: mismatch == nil, reason: mismatch, p90Ms: p90, medianMs: med, cpuMedianMs: cpuMed)
    }
}

/// The golden test's verdict over the whole self-test set, in both directions: the accelerator against the shipped
/// expected outputs and against the on-device CPU run (which must itself equal the expected file), the totals within
/// the build's tolerance from the signed manifest (exact when it gives none), and the planted mistake flagged always.
enum GoldenJudge {
    struct Clip: Sendable {
        var id: String
        var planted: Bool
        var plantedSite: String?
        /// The shipped expected outputs; nil for the SDK's bundled clips (tokens against the CPU only).
        var expected: SelfTestSet.Expected?
        var cpuTokens: [Int]
        var accTokens: [Int]
        var cpuSites: Set<String> = []
        var accSites: Set<String> = []
        var cpuWords: Set<Int> = []
        var accWords: Set<Int> = []
    }

    /// Nil when the build passes, else why not; `totals` are the counts against the CPU run (token edits on clean clips,
    /// symmetric differences of flagged sites and words on every clip).
    static func evaluate(_ clips: [Clip], tolerance t: ModelManifest.GoldenTolerance) -> (failure: PromotionFailure?, totals: Divergence) {
        var totals = Divergence()
        var firstDiff: String?
        for c in clips {
            if let e = c.expected {
                // the CPU engine first: it must be the shipped expected outputs exactly
                if let why = SelfTestSet.compare(clip: c.id, planted: false, expected: e, tokens: c.cpuTokens, flaggedSites: c.cpuSites,
                                                 flaggedWords: c.cpuWords) {
                    let d = Divergence(expected: e.tokens, tokens: c.cpuTokens, expectedSites: e.flaggedSites, sites: c.cpuSites,
                                       expectedWords: e.flaggedWords, words: c.cpuWords)
                    return (PromotionFailure(.cpuMismatch, "CPU engine: " + why, clip: c.id, divergence: d), d)
                }
            }
            if c.planted, let site = c.plantedSite, !c.accSites.contains(site) {
                let d = Divergence(expected: c.cpuTokens, tokens: c.accTokens, expectedSites: c.cpuSites, sites: c.accSites,
                                   expectedWords: c.cpuWords, words: c.accWords)
                return (PromotionFailure(.goldenMismatch, "\(c.id): the planted mistake at \(site) is not flagged", clip: c.id, divergence: d), d)
            }
            if !c.planted {
                totals.tokensExpected += c.cpuTokens.count
                totals.tokensDiffer += Divergence.edits(c.cpuTokens, c.accTokens)
            }
            totals.sitesDiffer += c.cpuSites.symmetricDifference(c.accSites).count
            totals.wordsDiffer += c.cpuWords.symmetricDifference(c.accWords).count
            if firstDiff == nil, (!c.planted && c.cpuTokens != c.accTokens) || c.cpuSites != c.accSites || c.cpuWords != c.accWords {
                firstDiff = c.id
            }
        }
        if totals.tokensDiffer > t.tokenDiffs || totals.sitesDiffer > t.siteFlagDiffs || totals.wordsDiffer > t.wordFlagDiffs {
            let why = "\(totals.tokensDiffer) token edits, \(totals.sitesDiffer) site flags and \(totals.wordsDiffer) word flags differ "
                + "from the CPU engine (tolerance \(t.tokenDiffs), \(t.siteFlagDiffs), \(t.wordFlagDiffs))"
            return (PromotionFailure(.goldenMismatch, why, clip: firstDiff, divergence: totals), totals)
        }
        return (nil, totals)
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
    /// Lets the app run the Neural Engine's promotion (download, compile, golden test) while the device is idle and
    /// charging: call once at launch, before the app finishes launching, with an identifier listed in the app's
    /// `BGTaskSchedulerPermittedIdentifiers`. Without it, the SDK runs it after the first finished session (or after a
    /// short idle delay), at background priority.
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
