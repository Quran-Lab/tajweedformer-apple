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
//    (golden_mismatch, cpu_mismatch, non_finite, crash) never.
// 6. A failure in a session (Failover.swift) is handled by its cause (2.0.2, `failedOver`): a deadline miss switches
//    that session to the CPU and demotes only after misses in 3 sessions within 24 h; a confirmed blank disagreement
//    demotes; both are transient (6 h, the build stays verified, no golden test again, never off for good). NaN, inf,
//    a head out of range, or a second confirmed disagreement turn the build off for good for the key. An exception
//    demotes as in 2.0.1 (golden-tested again no sooner than 24 h later, within the retry budget).
// 7. The first launch of 2.0.2 clears 2.0.1's blank and deadline demotions (`PromotionStore.migrate`).

/// Where the Neural Engine stands for a recognizer.
enum AcceleratorState: Sendable, Hashable, CustomStringConvertible {
    /// The exact CPU engine serves; no accelerator work runs now (none applies, it has not started, or it waits).
    case cpu
    /// The promotion pipeline is running in the background; the CPU engine serves meanwhile.
    case preparing
    /// Promoted, loaded and warm: sessions from the next one on run on the Neural Engine.
    case ready
    /// Not used, and why (an older OS, a failed stage, a crash, the deny-list, a failover).
    case disabled(String)

    var description: String {
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
    func push(_ s: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [HeadsBuffer]
    func finish() throws(RecognizerError) -> [HeadsBuffer]
    /// Seconds per chunk run since the last reset.
    var chunkSeconds: [Double] { get }
    /// The error behind the last failed call, when the runtime gave one.
    var lastError: NSError? { get }
    /// One prediction on silence that leaves no state behind (the backend is reset after it): wakes the accelerator
    /// before a take's first real chunk.
    func warmUp() throws(RecognizerError)
}

extension AcceleratorBackend {
    var lastError: NSError? { nil }
    func warmUp() throws(RecognizerError) {}
}

@available(iOS 18.0, macOS 15.0, *)
extension TajweedNeuralEngine: AcceleratorBackend {}

/// What the golden test found (the last attempt of this key that got that far).
struct AcceleratorSelfTest: Sendable, Hashable {
    let passed: Bool
    /// Why it failed, when it did.
    let reason: String?
    /// Per-chunk compute, milliseconds: the accelerator's p90 and median, and the CPU engine's median.
    let p90Ms: Double
    let medianMs: Double
    let cpuMedianMs: Double

    init(passed: Bool, reason: String?, p90Ms: Double = 0, medianMs: Double = 0, cpuMedianMs: Double = 0) {
        self.passed = passed; self.reason = reason; self.p90Ms = p90Ms; self.medianMs = medianMs; self.cpuMedianMs = cpuMedianMs
    }

    /// CPU median over the accelerator's median (telemetry only: a build below 1 is promoted too).
    var speedup: Double { medianMs > 0 ? cpuMedianMs / medianMs : 0 }
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
    /// The model version (SDK 3.0.0), and the build next to it.
    var revision: String
    var build: String? = nil
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
        /// The model build the key is made of (a new build of the same version is a new key: it may carry new programs).
        var revision: String
        /// The model version, as telemetry and incident reports name the model (the build goes next to it). Empty: the
        /// build stands in for it.
        var version: String = ""
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
        /// Every clip agreed; per-chunk compute seconds of the accelerator and of the CPU engine, and what the test
        /// measured (per compared head, with the tolerance it was judged against when the build has one). The measures
        /// are kept with the key's record also for a build without a tolerance, which is judged on its tokens: they
        /// are what a later build's tolerance is set from.
        case passed(accelerator: [Double], cpu: [Double], measures: Divergence? = nil)
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
        // the first launch of 2.0.2: 2.0.1's blank and deadline demotions are cleared (once per store)
        store.migrate(now: env.clock())
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
        } else if let r, r.status == .ready, let until = r.backoffUntil, env.clock() < until {
            _state = .disabled(Self.backoffDetail(r, until))
        }
        let name = Self.activeNotification
        activation = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.becameActive() }
    }

    deinit {
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }

    private var activation: (any NSObjectProtocol)?

    /// The app became active (iOS: didBecomeActive; macOS: NSApplication didBecomeActive).
    #if canImport(UIKit) && !os(watchOS)
    static let activeNotification = Notification.Name("UIApplicationDidBecomeActiveNotification")
    #else
    static let activeNotification = Notification.Name("NSApplicationDidBecomeActiveNotification")
    #endif

    static func backoffDetail(_ r: PromotionRecord, _ until: Date) -> String {
        "\(r.lastDetail ?? "demoted"); used again after \(iso(until))"
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

    /// Every change of state, starting with the current one. At most 64 wait for a reader (the newest are kept).
    func states() -> AsyncStream<AcceleratorState> {
        let (stream, c) = AsyncStream<AcceleratorState>.makeStream(bufferingPolicy: .bufferingNewest(64))
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
            // a transient demotion: still verified, used again (loaded and warmed, no golden test) after the backoff
            if let until = rec.backoffUntil, env.clock() < until { return set(.disabled(Self.backoffDetail(rec, until))) }
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
                    // warm chunks only (the golden test leaves out each clip's first chunk): the session limits
                    rec.acceleratorMedianMs = Self.percentile(t.accelerator, 0.5) * 1000
                    rec.acceleratorP90Ms = Self.percentile(t.accelerator, 0.9) * 1000
                    rec.cpuMedianMs = Self.percentile(t.cpu, 0.5) * 1000
                    rec.warmChunkMs = Array(t.accelerator.map { $0 * 1000 }.suffix(PromotionPolicy.warmSamplesKept))
                    rec.golden = t.measures
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
                rec.backoffUntil = nil
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
    private func golden(_ b: UncheckedBox<any AcceleratorBackend>, _ stages: Stages) async
        -> Result<(accelerator: [Double], cpu: [Double], measures: Divergence?), PromotionFailure> {
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
            case .success(.passed(let a, let c, let m)): return .success((accelerator: a, cpu: c, measures: m))
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
        // a golden test that failed keeps what it measured, as one that passed does (`failed` then names the measures)
        if stage == .golden { rec.golden = f.divergence?.bounded }
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
        let named = named(revision)
        env.incident(AcceleratorIncident(kind: .promotionFailed, stage: stage.rawValue, cause: f.reason.incidentCause, message: f.detail,
                                         errorDomain: f.errorDomain, errorCode: f.errorCode, clip: f.clip, divergence: f.divergence,
                                         attempt: max(1, min(100, rec.attempts)), revision: named.revision, build: named.build,
                                         context: context, thermal: c.thermal, lowPower: c.lowPower))
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
        let named = named(revision ?? env.revision)
        env.record(.promotion(PromotionTelemetry(backend: "ane", revision: named.revision, build: named.build ?? "",
                                                 context: context ?? env.context, kind: k)))
    }

    /// How telemetry and incident reports name the model of a key's build: its version with the build next to it. A
    /// controller made without a version names the build alone.
    private func named(_ build: String) -> (revision: String, build: String?) {
        env.version.isEmpty ? (build, nil) : (env.version, build)
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
        if let r = store.record(key), let until = r.backoffUntil, env.clock() < until {
            hold(nil)
            set(.disabled(Self.backoffDetail(r, until)))
            return nil
        }
        if dropAbandoned() {
            // a call hung in an earlier session of this launch: the build is loaded again (no golden test) for later ones
            set(.cpu)
            return nil
        }
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

    /// A session left the accelerator (Failover.swift) for the CPU engine. Every switch is counted (`failovers`,
    /// `failover_causes`) and reported (`accelerator_failover`); what happens to the build depends on the cause:
    /// - deadline: the session goes on on the CPU; the build is demoted (transient) only once misses happened in 3
    ///   different sessions of the key within 24 h;
    /// - blank (a disagreement the CPU engine confirmed): the first demotes (transient), the second for the key turns
    ///   the build off for good;
    /// - NaN or inf, a head out of range: off for good for the key;
    /// - exception: demoted and golden-tested again by the pipeline no sooner than 24 h later, within the key's retry
    ///   budget (2.0.1's rule).
    /// `session` identifies the take (deadline misses are counted per session).
    func failedOver(_ f: TakeRunner.Failover, session: String = UUID().uuidString) {
        var rec = store.record(key) ?? PromotionRecord(key: key)
        let now = env.clock()
        promotion(.failover(cause: f.cause, stallMs: f.stallMs))
        let reason: FallbackReason = f.cause == .nonFinite ? .nonFinite : f.cause == .deadline ? .deadline : .other
        env.record(.fallback(reason, cohort: env.cohort()))
        let c = AcceleratorController.conditionsNow()
        env.incident(AcceleratorIncident(kind: .failover, stage: "session", cause: f.cause.incidentCause, message: f.detail,
                                         errorDomain: f.errorDomain, errorCode: f.errorCode, chunk: f.chunk, elapsedMs: f.elapsedMs,
                                         deadlineMs: f.deadlineMs, divergence: f.divergence, stallMs: f.stallMs,
                                         revision: named(env.revision).revision, build: named(env.revision).build,
                                         context: env.context, thermal: c.thermal, lowPower: c.lowPower))
        switch f.cause {
        case .deadline:
            var misses = (rec.missSessions ?? []).filter { now.timeIntervalSince($0.at) < PromotionPolicy.missWindow }
            if !misses.contains(where: { $0.session == session }) { misses.append(.init(session: session, at: now)) }
            if Set(misses.map(\.session)).count >= PromotionPolicy.missSessions {
                rec.missSessions = nil
                demoteTransient(&rec, f, now)
            } else {
                // one miss: this session is on the CPU, the build stays promoted for the next one
                rec.missSessions = misses
                store.save(rec)
            }
        case .blank:
            let n = (rec.disagreements ?? 0) + 1
            rec.disagreements = n
            if n >= PromotionPolicy.disagreementsOffForGood { offForGood(&rec, f, .failover) } else { demoteTransient(&rec, f, now) }
        case .nonFinite, .outOfRange:
            offForGood(&rec, f, .nonFinite)
        case .exception:
            hold(nil)
            rec.failures += 1
            rec.lastStage = nil
            rec.lastReason = .failover
            rec.lastCause = f.cause
            rec.lastDetail = "failover: \(f.detail)"
            rec.completed = nil
            rec.attemptStarted = nil
            if rec.failures > PromotionPolicy.backoff.count {
                rec.status = .failed
                rec.notBefore = nil
            } else {
                rec.status = .retry
                rec.notBefore = now.addingTimeInterval(max(PromotionPolicy.backoff[rec.failures - 1], PromotionPolicy.failoverRetest))
            }
            store.save(rec)
            promotion(.demoted(.failover))
            set(.disabled(rec.lastDetail!))
        }
    }

    /// A transient demotion: the build stays promoted and verified, unused for `PromotionPolicy.transientBackoff`
    /// (then loaded and warmed again, no golden test); never off for good.
    private func demoteTransient(_ rec: inout PromotionRecord, _ f: TakeRunner.Failover, _ now: Date) {
        hold(nil)
        let until = now.addingTimeInterval(PromotionPolicy.transientBackoff)
        rec.backoffUntil = until
        rec.lastCause = f.cause
        rec.lastReason = .failover
        rec.lastDetail = "failover: \(f.detail)"
        store.save(rec)
        promotion(.demoted(.failover))
        set(.disabled(Self.backoffDetail(rec, until)))
    }

    /// A confirmed numeric fault: never again for the key (a new model revision or OS build tries again).
    private func offForGood(_ rec: inout PromotionRecord, _ f: TakeRunner.Failover, _ reason: PromotionReason) {
        hold(nil)
        rec.status = .failed
        rec.notBefore = nil
        rec.backoffUntil = nil
        rec.completed = nil
        rec.attemptStarted = nil
        rec.lastStage = nil
        rec.lastReason = reason
        rec.lastCause = f.cause
        rec.lastDetail = "failover: \(f.detail)"
        store.save(rec)
        promotion(.demoted(.failover))
        set(.disabled(rec.lastDetail!))
    }

    /// The end of a session that ran on the accelerator: its warm chunk times join the key's (the limits of later
    /// sessions), and the blank suspicions the CPU engine confirmed as correct are counted (`blank_confirmed_ok`).
    func sessionEnded(warmMs: [Double], blankConfirmedOK: Int) {
        for _ in 0..<max(0, blankConfirmedOK) { promotion(.blankConfirmedOK) }
        guard !warmMs.isEmpty, var rec = store.record(key), rec.status == .ready else { return }
        rec.warmChunkMs = Array(((rec.warmChunkMs ?? []) + warmMs).suffix(PromotionPolicy.warmSamplesKept))
        store.save(rec)
    }

    /// The app became active: the next accelerator chunk is a cold one (its own limit), and with no session on the
    /// build, one prediction on silence wakes the Neural Engine now, off any audio path. (A session in progress is not
    /// interrupted: a warm-up would reset its stream.)
    func becameActive() {
        lock.lock()
        let e = executor
        let busy = leased
        lock.unlock()
        guard let e, !e.abandoned else { return }
        e.markCold()
        if !busy { e.warmUp() }
    }

    /// Drops the held executor when a call on it hung (true then).
    private func dropAbandoned() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let e = executor, e.abandoned, !leased else { return false }
        executor = nil
        return true
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

    /// The session limits from this key's warm chunk times (the measure stage's p90 and median for a record without
    /// them; 1000 ms and 300 ms before any measurement), and those times.
    var limits: (firstMs: Double, laterMs: Double, warmMs: [Double]) {
        let r = record
        let warm = r?.warmChunkMs ?? []
        let l = PromotionPolicy.limits(warmMs: warm, p90Ms: r?.acceleratorP90Ms, medianMs: r?.acceleratorMedianMs)
        return (l.firstMs, l.laterMs, warm)
    }

    /// What this key's last golden test measured, per compared head (kept with the record, so it is there in later
    /// launches too), whether it passed or failed; nil before a golden test ran, and for a record written before SDK
    /// 3.0.0 kept them.
    var lastGolden: Divergence? { record?.golden }

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
/// (`selftest/<clip>.s16`, samples q / 32768), and per context the exact CPU engine's expected tokens
/// (`selftest/expected_<ctx>.json`). SDK 3.0.0 reads only `tokens` of each clip there: a build for 3.0 holds nothing
/// else, and the site and word fields of a 2.x file are ignored.
struct SelfTestSet: Sendable {
    struct Clip: Sendable {
        let id: String
        let surah: Int
        let ayah: Int
        let samples: [Float]
        let mustDecode: Bool
        /// A clip with a planted mistake (`"kind": "planted"` or `"planted": true`): the int8 CPU engine may decode a
        /// mistaken reading differently from fp16, so its tokens do not count in the golden test's token edits (its
        /// frames count in the distances). Absent means clean.
        let planted: Bool
    }

    let clips: [Clip]
    /// By clip id: the CPU engine's greedy tokens of `log_probs`.
    let expected: [String: [Int]]

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
                              mustDecode: c["must_decode"]?.bool ?? false, planted: Self.isPlanted(c)))
        }
        var expected: [String: [Int]] = [:]
        for (id, e) in exp["clips"]?.object ?? [:] {
            guard let tokens = e["tokens"]?.array else { continue }
            expected[id] = tokens.compactMap { $0.number.map { Int($0) } }
        }
        guard !clips.isEmpty, clips.allSatisfy({ expected[$0.id] != nil }) else { return nil }
        return SelfTestSet(clips: clips, expected: expected)
    }

    /// A clip's kind: `kind` is authoritative ("planted" or "clean"); without it, `planted` marks a planted clip when it
    /// is `true` or an object. Any other value, or none, is clean. Unknown keys and unexpected types never fail the set.
    static func isPlanted(_ c: JSONValue) -> Bool {
        if let k = c["kind"]?.string { return k == "planted" }
        if c["planted"]?.bool == true || c["planted"]?.object != nil { return true }
        return false
    }

    /// The verdict from the golden test's outcome, with the per-chunk times (seconds) for the measure stage.
    /// Speed is never part of it: a build that agrees is promoted, slower or not.
    static func judge(mismatch: String?, accelerator: [Double], cpu: [Double]) -> AcceleratorSelfTest {
        let p90 = AcceleratorController.percentile(accelerator, 0.9) * 1000
        let med = AcceleratorController.percentile(accelerator, 0.5) * 1000
        let cpuMed = AcceleratorController.percentile(cpu, 0.5) * 1000
        return .init(passed: mismatch == nil, reason: mismatch, p90Ms: p90, medianMs: med, cpuMedianMs: cpuMed)
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
    static func registerAcceleratorPreparation(identifier: String) {
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
