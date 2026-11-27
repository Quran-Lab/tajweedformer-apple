import CryptoKit
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
//    download (on any network, SDK 4.0.2), compile (the first load with the Neural Engine allowed, 10 min timeout), warmup
//    (silence and the first self-test clip, no NaN or inf), golden (every self-test clip through the accelerator and
//    the CPU engine: the same decisions, the CPU's equal to the shipped expected file), measure (SDK 4.0: not promoted
//    when the accelerator's median chunk is slower than the CPU engine's, `slower_than_cpu`), promote. The record is written after each stage; a restart resumes at the
//    stage after the last one recorded; a crash sentinel around every compile, load and first inference turns a
//    process death there into reason `crash` at the next launch.
// 3. The golden and measure stages run only while no session runs (a session starting aborts them without a
//    failure), and the whole pipeline only in good conditions (not Low Power Mode, battery at least 20 % or charging,
//    thermal nominal or fair).
// 4. The swap is to a build that is loaded and warm: at a session boundary, and since SDK 4.0.5 also during a take
//   : a take that runs on the CPU engine when the build becomes ready
//    rebuilds the accelerator's state from its audio, checks it beside the CPU engine, and moves to it at a pause.
//    (SDK 4.0.4 and before kept the sdk_2.0.1 rule "only at a session boundary, never mid-session".)
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
    /// Promoted, loaded and warm: sessions from the next one on run on the Neural Engine, and a take on the CPU engine
    /// may move to it (a live promotion, contract section 30).
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

/// What a loaded accelerator does (an accelerator the Core prepared; a fake in tests).
protocol AcceleratorBackend: AnyObject {
    var coreModel: CoreModel? { get }
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
    /// False once the program it runs is gone (the Core's model was closed: another context, an install): the build is
    /// loaded again, not failed over.
    var isUsable: Bool { get }
    /// The program let go now (a build that is not promoted): the Core wipes it and its memory goes back.
    func release()
}

extension AcceleratorBackend {
    var lastError: NSError? { nil }
    func warmUp() throws(RecognizerError) {}
    var isUsable: Bool { true }
    func release() {}
    /// The Core model it runs on, which a take holds from its start (`TakeRunner.holdModel`); nil for a stand-in.
    var coreModel: CoreModel? { nil }
}

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
    /// A promotion stage the previous process did not finish (SDK 4.0): what ended it (CrashDiagnostics), and (a stop,
    /// `crash_on_last_run`, contract 1.22.0) whether the app was in the foreground at the sentinel's last heartbeat; nil
    /// where the platform cannot tell (macOS).
    var crash: CrashEvidence? = nil
    var foreground: Bool? = nil
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
        /// The program's digest (`programDigest`, its first 16 hex), part of the key: a build whose program changes in
        /// any file (only model.mil, say) is a new key, tested from the start. Empty: none known.
        var program: String = ""
        var storage: URL
        /// This process; at most one new attempt per launch for a key.
        var launch: String = AcceleratorController.thisLaunch
        var clock: @Sendable () -> Date = { Date() }
        /// The wait between two looks at the conditions; SDK 4.0.5: it ends early when the device is unlocked or the app
        /// becomes active again (`InterruptionWatch`).
        var sleep: @Sendable (TimeInterval) async -> Void = { s in await InterruptionWatch.shared.wait(upTo: s) }
        var conditions: @Sendable () async -> PromotionConditions = { await PromotionConditions.current() }
        /// SDK 4.0.5: the locks and the app's leaving the foreground so far in this process (`InterruptionWatch`).
        var interruptions: @Sendable () -> InterruptionWatch.Count = { InterruptionWatch.shared.now }
        /// Waits on bad conditions in one run before it gives up for now (no failure; the next trigger resumes).
        var maxConditionWaits = 30
        var thermal: @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }
        /// The deny-list rule forcing the CPU engine, with its reason; nil when none matches.
        var denied: @Sendable () -> String? = { nil }
        /// SDK 4.0.2 (21.6): whether the lease in force allows accelerator programs (`qlc_accel_allowed`); nil when the
        /// Core cannot say now (no lease). False holds the pipeline as the deny list does (`leaseDenied`).
        var acceleratorAllowed: @Sendable () -> Bool? = { nil }
        /// The signed config's `flags.accel_min_speedup` (nil: none); `PromotionPolicy.minSpeedup` bounds it.
        var minSpeedup: @Sendable () -> Double? = { nil }
        var record: @Sendable (AnalyticsEvent) -> Void = { _ in }
        var incident: @Sendable (AcceleratorIncident) -> Void = { _ in }
        /// What ended the process that left a sentinel: MetricKit's crash diagnostic of it, waited for at most 60 s
        /// (none for a quit), else what the sentinel's heartbeat saw.
        var crashEvidence: @Sendable (PromotionStore.Sentinel) async -> CrashEvidence = { s in
            await CrashDiagnostics.shared.evidence(for: s, timeout: s.quit == true ? 0 : 60)
        }
        var cohort: @Sendable () -> TelemetryCohort
        var timeouts = Timeouts()
        /// This SDK's version: a `slower_than_cpu` verdict of another SDK version is tried again at once.
        var sdkVersion: String = SDKInfo.version
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

    var key: String {
        Self.key(revision: env.revision, context: env.context, build: env.build, osBuild: env.osBuild, deviceModel: env.deviceModel,
                 program: env.program)
    }

    static func key(revision: String, context: String, build: String, osBuild: String = DeviceInfo.osBuild,
                    deviceModel: String = DeviceInfo.model, program: String = "") -> String {
        ([revision, context, build, osBuild, deviceModel] + (program.isEmpty ? [] : [program])).joined(separator: "|")
    }

    /// The whole accelerator program of a build as the Core's `qlc_accel_prepare` loads it: every file of the package
    /// role (`coreml` or `coreml-compact`) of context `*` or `context` (the compiled package's model.mil, its weights,
    /// its metadata, the specification `model.mlmodel` where the build ships one) and the context's keep table, each by
    /// its signed SHA-256 from the manifest, hashed in path order. Through 4.0's first drafts only weight.bin was
    /// hashed, so a build that changed only model.mil (the A20 stride fix: a strided slice_by_index replaced by
    /// reshape, mul and reduce_sum) kept its promotion without a golden test. Nil when the manifest lists no program.
    static func programDigest(files: [ModelManifest.File], context: String, compact: Bool) -> String? {
        let role = compact ? "coreml-compact" : "coreml"
        let program = files.filter {
            $0.isFor(platform: DownloadProfile.platform)
                && (($0.role == role && ($0.context == "*" || $0.context == context)) || ($0.role == "coreml-keeps" && $0.context == context))
        }
        guard program.contains(where: { $0.role == role }) else { return nil }
        let lines = program.map { "\($0.localPath) \($0.localSHA256)\n" }.sorted().joined()
        return Data(SHA256.hash(data: Data(lines.utf8))).hex
    }

    /// The key's program part: the digest's first 16 hex, or empty.
    static func programKey(_ m: ModelManifest, context: String, compact: Bool) -> String {
        programDigest(files: m.files, context: context, compact: compact).map { String($0.prefix(16)) } ?? ""
    }

    init(_ env: Environment) {
        self.env = env
        store = PromotionStore(dir: env.storage)
        // the first launch of 2.0.2: 2.0.1's blank and deadline demotions are cleared (once per store)
        store.migrate(now: env.clock())
        CrashDiagnostics.shared.start()
        SentinelWatch.shared.attach(store)
        // the first launch of 3.1.5 or later: a key ended by one stop at download, compile or warm-up gets its retry back
        let back = store.migrate315(now: env.clock())
        if !back.isEmpty { SDKLatest.debugOnly("promotion: \(back.count) build(s) ended by one stop during preparation may be tried again") }
        // the first launch of 4.0.2 or later (21.6 item 4): a key 4.0.1 counted a lease without accelerator programs
        // against goes back to pending
        let leased = store.migrate402()
        if !leased.isEmpty { SDKLatest.debugOnly("promotion: \(leased.count) build(s) held by a lease without accelerator programs may be tried again") }
        // the process stopped during a compile, load or first inference: a quit, a stop in the background, or a crash
        // (stopFound); the report goes out once the system's crash diagnostic of that process is in (or after 60 s
        // without one), with what it says. A stage under way in another process of the app (its sentinel's heartbeat is
        // fresh and its process is there) is not judged: two processes of one app never poison each other's record
        if let s = store.sentinel(), !Self.underWayElsewhere(s, now: Date()) {
            store.clearSentinel()
            if Self.writtenBefore40(s) {
                // SDK 4.0.5: the stop of a process of an SDK before 4.0 (the app's version before its update): nothing
                // tells a crash from a quit or the update itself, and its key is not one this SDK runs
                SDKLatest.debugOnly("promotion: a stage of an SDK before 4.0 was under way when its process ended; not judged")
            } else {
                stopFound(s)
            }
        }
        let r = store.record(key)
        if let why = leaseDenied() {
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

    /// Whether this platform can tell a stop in the background from one in the foreground. iOS: yes (the app is
    /// suspended in the background, SentinelWatch follows it). macOS: no: a Mac app is not suspended, so a stop there
    /// takes the rule of a stop in the foreground and the report leaves `foreground` out.
    /// (Tests set it to run either rule on the Mac.)
    static let tellsForeground: Locked<Bool> = {
        #if canImport(UIKit) && os(iOS)
        return Locked(true)
        #else
        return Locked(false)
        #endif
    }()

    /// What the last launch left: the process stopped at `s.stage` of the attempt of `s.key` (3.1.5 with 4.0's
    /// evidence).
    /// - A quit (willTerminate, or a normal exit: atexit): `interrupted`, never a crash (ACCEL_40): retried after the
    ///   backoff, never using up the key's retry budget.
    /// - In the background (`foreground` false; iOS only): counts nothing and the attempt goes on where it was, until
    ///   the `backgroundStopsCountedFrom`th in a row at the same stage, which counts as a stop in the foreground
    ///  . Reported as `crash_on_last_run` with `foreground` false.
    /// - In the foreground, or where it is not known (macOS): reason crash. (A sentinel of an SDK before 4.0 never gets
    ///   here since 4.0.5: `writtenBefore40`.) At download, compile
    ///   or warm-up within the retry budget, and a second at the same stage ends the key; at the golden test or the
    ///   measurement it ends the key.
    /// A quit or a stop in the background while a promoted build was being loaded again holds nothing against it.
    private func stopFound(_ s: PromotionStore.Sentinel) {
        var r = store.record(s.key) ?? PromotionRecord(key: s.key)
        let wasReady = r.status == .ready
        let quit = s.quit == true
        let fg: Bool? = Self.tellsForeground.withLock { $0 } ? s.foreground : nil
        let background = !quit && fg == false
        if (quit || background) && wasReady { return }
        let detail = "the app stopped during the \(s.stage.rawValue) stage"
        let env = self.env
        func send(_ incident: AcceleratorIncident) {
            lastLaunchReport = Task.detached(priority: .utility) {
                var i = incident
                i.crash = await env.crashEvidence(s)
                env.incident(i)
            }
        }
        if quit {
            let incident = recordFailure(&r, s.stage, PromotionFailure(.interrupted, "the app was quit during the \(s.stage.rawValue) stage"),
                                         reload: wasReady, sameKey: s.key == key, report: false)
            send(incident)
            return
        }
        // a row of background stops that reached the bound: kept past the counted failure, so that the next stop in
        // the same row is the second counted one at the stage
        var countedRow: [String: Int]?
        if background, PromotionPolicy.backgroundStopCountsNothingAtEveryStage || s.stage.isPreparation {
            var row = r.backgroundStops ?? [:]
            let n = (row[s.stage.rawValue] ?? 0) + 1
            row[s.stage.rawValue] = n
            r.backgroundStops = row
            if n < PromotionPolicy.backgroundStopsCountedFrom {
                // not a failure of the build: nothing counted, no wait; the attempt goes on where it was
                store.save(r)
                SDKLatest.debugOnly("promotion: the app stopped in the background during the \(s.stage.rawValue) stage; "
                                    + "nothing counted (\(n) in a row), the attempt goes on")
                let parts = s.key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                let revision = parts.first ?? env.revision, context = parts.count > 1 ? parts[1] : env.context
                let c = AcceleratorController.conditionsNow()
                let named = named(revision)
                send(AcceleratorIncident(kind: .promotionFailed, stage: s.stage.rawValue, cause: PromotionReason.crash.incidentCause,
                                         message: detail, attempt: max(1, min(100, r.attempts)), revision: named.revision, build: named.build,
                                         context: context, thermal: c.thermal, lowPower: c.lowPower, foreground: false))
                return
            }
            SDKLatest.debugOnly("promotion: the app stopped in the background during the \(s.stage.rawValue) stage, "
                                + "\(n) in a row: counted as a stop in the foreground")
            countedRow = row
        }
        let incident = recordFailure(&r, s.stage, PromotionFailure(.crash, detail), reload: wasReady, sameKey: s.key == key,
                                     report: false, foreground: fg)
        if let countedRow {
            r.backgroundStops = countedRow
            store.save(r)
        }
        send(incident)
        if r.status == .failed {
            SDKLatest.debugOnly("promotion: the app stopped during the \(s.stage.rawValue) stage; the build is off for this device")
        } else if let nb = r.notBefore {
            SDKLatest.debugOnly("promotion: the app stopped during the \(s.stage.rawValue) stage; tried again after \(Self.iso(nb))")
        }
    }

    private(set) var lastLaunchReport: Task<Void, Never>?

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
        // the config's deny list, and (21.6) a lease in force that does not allow accelerator programs: no attempt starts
        // or goes on, nothing is counted
        if let why = leaseDenied() { return noteDenied(&rec, why) }
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
            // a build slower than the CPU engine is tried again at once by another SDK version (an OS update or a new
            // build is another key)
            let newSDK = rec.lastReason == .slowerThanCPU && rec.slowerSDK != env.sdkVersion
            if let nb = rec.notBefore, env.clock() < nb, !newSDK {
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
        // SDK 4.0.5: the stages a lock or the app's leaving cut in this run, each run again once unlocked and in front
        var notNowRuns = 0
        if stage > .warmup {
            afterRewarm = stage
            stage = .warmup
        }
        while true {
            // 4.0.5: the warm-up of a build compiled in this run prepares nothing (the program is in memory already)
            guard await waitConditions(stage, prepares: stage == .compile || (stage == .warmup && backend == nil)) else { return set(.cpu) }
            switch stage {
            case .download:
                do throws(PromotionFailure) { try await stages.download() } catch { return fail(&rec, .download, error) }
            case .compile:
                store.writeSentinel(key, .compile)
                SDKLatest.debugOnly("promotion: compile begins (the first load of the build on this device)")
                let t0 = env.clock()
                let seen = env.interruptions()
                // No background time is asked for around the compile (beginBackgroundTask). The Core c3 writes the
                // package Core ML reads with complete file protection: about 10 s after a lock its files can no longer
                // be read, and a mapped read then ends the process (SIGBUS). Without the system's extra time an app
                // that leaves is suspended within seconds, before that, and the compile goes on once it is back. The
                // time comes back with a Core that writes the package readable while locked (complete until the
                // first unlock).
                let r = await Self.race(env.timeouts.compile,
                                        onTimeout: PromotionFailure(.compileTimeout, "the compile took over \(Int(env.timeouts.compile)) s"),
                                        stages.compile)
                store.clearSentinel()
                switch r {
                case .failure(let f):
                    if let why = await interrupted(since: seen, f) {
                        guard notNow(&notNowRuns, .compile, why, f) else { return set(.cpu) }
                        continue
                    }
                    return fail(&rec, .compile, f)
                case .success(let b): backend = b
                }
                rec.compileMs = env.clock().timeIntervalSince(t0) * 1000
            case .warmup:
                if backend == nil {
                    let seen = env.interruptions()
                    switch await load(stages) {
                    case .failure(let f):
                        if let why = await interrupted(since: seen, f) {
                            guard notNow(&notNowRuns, .warmup, why, f) else { return set(.cpu) }
                            continue
                        }
                        return fail(&rec, .warmup, f)
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
                // SDK 4.0 (as Android): promoted only when it is not slower than the CPU engine on this device, by the
                // golden test's medians (warm chunks); the speedup is also telemetry
                let acc = rec.acceleratorMedianMs ?? 0, cpu = rec.cpuMedianMs ?? 0
                if acc > 0, cpu > 0, cpu / acc < PromotionPolicy.minSpeedup(env.minSpeedup()) {
                    backend?.value.release()
                    return slowerThanCPU(&rec, acceleratorMs: acc, cpuMs: cpu)
                }
            case .promote:
                rec.status = .ready
                rec.completed = .promote
                rec.backgroundStops = nil
                rec.preparationStops = nil
                SDKLatest.debugOnly("promotion: promoted; the next session uses the accelerator")
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
                // the warm-up again completed: its row has ended (the stage the attempt resumes keeps its own)
                endRow(&rec, .warmup)
                continue
            }
            rec.completed = stage
            // a stage that finished ends a row of download stops
            rec.downloadStops = nil
            // the stage completed: a row of background stops at it has ended
            rec.backgroundStops?[stage.rawValue] = nil
            store.save(rec)
            guard let n = stage.next else { return }
            stage = n
        }
    }

    /// A key promoted in an earlier launch: load the compiled build again and warm it (the CPU engine serves meanwhile).
    private func reload(_ rec: inout PromotionRecord, _ stages: Stages) async {
        set(.preparing)
        guard await waitConditions(.warmup, prepares: true) else { return set(.cpu) }
        let backend: UncheckedBox<any AcceleratorBackend>
        let seen = env.interruptions()
        switch await load(stages) {
        case .failure(let f):
            // SDK 4.0.5: a load the lock or the app's leaving cut leaves the promoted key as it is; the next run loads it
            if let why = await interrupted(since: seen, f) {
                var runs = Self.notNowRunsMax
                _ = notNow(&runs, .warmup, why, f)
                return set(.cpu)
            }
            return fail(&rec, .warmup, f, reload: true)
        case .success(let b): backend = b
        }
        if let f = await warm(backend, stages) { return fail(&rec, .warmup, f, reload: true) }
        hold(backend)
        set(.ready)
    }

    /// A stage completed outside the attempt's own steps (the warm-up again before a resumed stage): the row of
    /// background stops at it has ended. Saved only when there was one. (The reload of a promoted build needs none:
    /// a stop in the background while it runs holds nothing against the build and starts no row, `stopFound`.)
    private func endRow(_ rec: inout PromotionRecord, _ stage: PromotionStage) {
        guard rec.backgroundStops?[stage.rawValue] != nil else { return }
        rec.backgroundStops?[stage.rawValue] = nil
        store.save(rec)
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

    /// Waits while conditions are bad (no failure counted); false when it gave up for now. `prepares`: the stage makes
    /// the Core prepare the program (the compile, a load), which waits for an unlocked device and the foreground.
    private func waitConditions(_ stage: PromotionStage, prepares: Bool = false) async -> Bool {
        var waits = 0
        while true {
            if Task.isCancelled { return false }
            let c = await env.conditions()
            guard c.blocker(for: stage, prepares: prepares) != nil else { return true }
            waits += 1
            if waits > env.maxConditionWaits { return false }
            await env.sleep(PromotionPolicy.conditionsRecheck)
        }
    }

    /// A stage cut this many times in one run by a lock or the app's leaving goes on at the next run instead.
    static let notNowRunsMax = 3

    /// SDK 4.0.5: why a stage that prepares the program ended, when it was not the build: the device locked while it ran
    /// (`locked`: Core ML could no longer read the program the Core wrote with complete protection, "not a valid
    /// .mlmodelc", or the process was suspended) or the app left the foreground (`background`); nil for any other end,
    /// which counts as before. The Core busy (`notNow` already) is its own case.
    private func interrupted(since seen: InterruptionWatch.Count, _ f: PromotionFailure) async -> String? {
        guard !f.notNow, !f.leaseNoAccel else { return nil }
        guard [PromotionReason.compileError, .compileTimeout, .loadError, .hang].contains(f.reason) else { return nil }
        let now = env.interruptions()
        let c = await env.conditions()
        if now.locked != seen.locked || !c.protectedData { return "locked" }
        if now.background != seen.background || c.background { return "background" }
        return nil
    }

    /// A stage cut by a lock or the app's leaving: nothing counted against the build, no failure recorded, no backoff,
    /// no incident; told apart in telemetry (`not_now`). True when the run goes on with the stage again (it waits for
    /// an unlocked device and the foreground first), false when the run ends here and the next one goes on.
    private func notNow(_ runs: inout Int, _ stage: PromotionStage, _ why: String, _ f: PromotionFailure) -> Bool {
        runs += 1
        promotion(.notNow(stage: stage, why: why))
        let again = runs <= Self.notNowRunsMax
        SDKLatest.debugOnly("promotion: \(stage.rawValue) not now (\(why)): \(f.reason.rawValue), nothing counted; "
            + (again ? "it runs again once the device is unlocked and the app in the foreground" : "the next run goes on from here"))
        return again
    }

    private func fail(_ rec: inout PromotionRecord, _ stage: PromotionStage, _ f: PromotionFailure, reload: Bool = false) {
        // 21.6: the Core refused a stage for the lease in force (a prepare or a load, also of a promoted key): the deny
        // list's path, not a failure. The attempt stays where it stood, a promoted key stays promoted, and the next lease
        // that allows programs takes it up again (`leaseAccepted`)
        if f.leaseNoAccel { return noteDenied(&rec, Self.leaseNoAccel + ": " + f.detail) }
        hold(nil)
        // SDK 4.0.5: the Core busy with something else (`PromotionFailure.notNow`): nothing counted, reported or
        // changed in the record; the attempt (or the reload of a promoted key) goes on at the next run
        if f.notNow {
            SDKLatest.debugOnly("promotion: \(stage.rawValue) not now (\(f.detail)); the next run goes on from here")
            return set(.cpu)
        }
        recordFailure(&rec, stage, f, reload: reload, sameKey: true)
    }

    /// The text of a lease without accelerator programs, as a record's `lastDetail` names it (4.0.1 and 4.0.2).
    static let leaseNoAccel = "lease_no_accel"

    /// Why the pipeline is held now without a failure: the config's deny list, else (21.6) a lease in force that does
    /// not allow accelerator programs; nil when neither holds it.
    private func leaseDenied() -> String? {
        if let why = env.denied() { return why }
        if env.acceleratorAllowed() == false { return Self.leaseNoAccel + ": the lease in force does not allow accelerator programs" }
        return nil
    }

    /// Ends the attempt with a failure (or demotes a promoted key that failed to load again): the record, the retry
    /// time, the telemetry and the incident report.
    /// `report`: false when the caller sends the incident itself (the previous launch's sentinel, after its evidence).
    /// `foreground`: of a stop of the process (`crash`), as the report carries it.
    @discardableResult
    private func recordFailure(_ rec: inout PromotionRecord, _ stage: PromotionStage, _ f: PromotionFailure, reload: Bool, sameKey: Bool,
                               report: Bool = true, foreground: Bool? = nil) -> AcceleratorIncident {
        // a quit during a stage is the user's: retried after the backoff, never using up the key's retry budget; so is
        // a download the network stopped or that had no room (3.1.5): it says nothing about the build
        let downloadStop = stage == .download && (f.reason == .network || f.reason == .storage)
        let notCounted = f.reason == .interrupted || downloadStop
        if !notCounted { rec.failures += 1 }
        if downloadStop { rec.downloadStops = (rec.downloadStops ?? 0) + 1 }
        rec.lastStage = stage
        rec.lastReason = f.reason
        rec.lastDetail = "\(stage.rawValue): \(f.detail)"
        rec.completed = nil
        rec.attemptStarted = nil
        // a golden test that failed keeps what it measured, as one that passed does (`failed` then names the measures)
        if stage == .golden { rec.golden = f.divergence?.bounded }
        // a stop of the process before the model ran on the accelerator (3.1.5): the retry budget, and a second stop
        // at the same stage ends the key
        var ends = f.reason.deterministic
        if f.reason == .crash, stage.isPreparation {
            var stops = rec.preparationStops ?? [:]
            let n = (stops[stage.rawValue] ?? 0) + 1
            stops[stage.rawValue] = n
            rec.preparationStops = stops
            ends = n >= 2
        }
        // the attempt ended: a row of background stops has ended with it
        rec.backgroundStops = nil
        if ends || rec.failures > PromotionPolicy.backoff.count {
            rec.status = .failed
            rec.notBefore = nil
        } else {
            rec.status = .retry
            let n = downloadStop ? (rec.downloadStops ?? 1) : rec.failures
            rec.notBefore = env.clock().addingTimeInterval(PromotionPolicy.backoff[min(PromotionPolicy.backoff.count - 1, max(0, n - 1))])
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
        let incident = AcceleratorIncident(kind: .promotionFailed, stage: stage.rawValue, cause: f.reason.incidentCause, message: f.detail,
                                           errorDomain: f.errorDomain, errorCode: f.errorCode, clip: f.clip, divergence: f.divergence,
                                           attempt: max(1, min(100, rec.attempts)), revision: named.revision, build: named.build,
                                           context: context, thermal: c.thermal, lowPower: c.lowPower,
                                           foreground: f.reason == .crash ? foreground : nil)
        if report { env.incident(incident) }
        if sameKey { set(.disabled(rec.lastDetail ?? f.detail)) }
        return incident
    }

    /// The golden test passed but the accelerator is slower than the CPU engine here: the CPU engine stays, the attempt
    /// ends as `slower_than_cpu` with both medians in the telemetry, and the key is tried again after
    /// `PromotionPolicy.slowerRetry` or an SDK update. Not a failure of the build: the retry budget is not used.
    private func slowerThanCPU(_ rec: inout PromotionRecord, acceleratorMs: Double, cpuMs: Double) {
        rec.status = .retry
        rec.notBefore = env.clock().addingTimeInterval(PromotionPolicy.slowerRetry)
        rec.lastStage = .measure
        rec.lastReason = .slowerThanCPU
        rec.lastDetail = String(format: "measure: the accelerator's median chunk takes %.1f ms, the CPU engine's %.1f ms", acceleratorMs, cpuMs)
        rec.slowerSDK = env.sdkVersion
        rec.completed = nil
        rec.attemptStarted = nil
        store.save(rec)
        promotion(.slowerThanCPU(acceleratorMs: acceleratorMs, cpuMs: cpuMs, compileMs: rec.compileMs))
        set(.disabled(rec.lastDetail ?? "slower_than_cpu"))
    }

    /// SDK 4.0.5: a sentinel an SDK before 4.0 wrote (3.1.4: `{key, stage}` only, in the same file), found at the first
    /// launch after the app's update to 4.0. Every 4.0 sentinel has the process id, the time, the OS build, a heartbeat
    /// and the foreground (`PromotionStore.writeSentinel`). Its process ran the old SDK, often until the update ended
    /// it; its key (no program digest) is never this SDK's, and MetricKit's diagnostic cannot be matched to it (no pid,
    /// no time), so 4.0.0 to 4.0.4 counted it as a crash of the old key and reported `crash_on_last_run` with the bare
    /// evidence `{"exit":"unknown"}` after waiting 60 s for a diagnostic: 5 of the 8 incidents of 11-24 and 11-25 (one
    /// app's update from 3.1.4 to 4.0.2). Now it is removed with nothing counted and nothing reported.
    static func writtenBefore40(_ s: PromotionStore.Sentinel) -> Bool {
        s.pid == nil && s.at == nil && s.osBuild == nil && s.heartbeat == nil && s.foreground == nil && s.quit == nil
    }

    /// Whether a sentinel belongs to a stage under way in another process of the app now: not this process, a heartbeat
    /// (every 2 s, SentinelWatch) in the last 10 s, and its process there (a process that died stops its heartbeat; a
    /// pid used again later is ruled out by the heartbeat's age). Such a sentinel is judged at a later launch.
    static func underWayElsewhere(_ s: PromotionStore.Sentinel, now: Date) -> Bool {
        guard let pid = s.pid, pid != ProcessInfo.processInfo.processIdentifier, let beat = s.heartbeat ?? s.at,
              now.timeIntervalSince(beat) < 10 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Forgets this device's verdict on the key and the build loaded for it in this process
    /// (`TajweedModel.prepareAccelerator(again: true)`): the next run prepares the build from the start.
    func forget() {
        hold(nil)
        store.remove(key)
        set(.cpu)
    }

    /// The reason `model.backend` names for this key's demoted or held build (the record's, the codes of the incident
    /// reports). SDK 4.0.5 (ACCEL_40 21.2, 21.6): a lease without accelerator programs (an install that is not attested,
    /// a command-line tool, an app without the App Attest capability, or a development key's) is `not_attested`, not
    /// `denylist`: `denylist` means the config's deny list only.
    var backendReason: String? {
        guard let rec = record else { return nil }
        if Self.isLeaseNoAccel(rec) { return Self.notAttested }
        return rec.lastReason?.rawValue
    }

    static let notAttested = PromotionReason.notAttested.rawValue

    /// A record held for a lease without accelerator programs (21.6).
    static func isLeaseNoAccel(_ rec: PromotionRecord) -> Bool {
        rec.lastReason == .notAttested || (rec.denied && rec.lastDetail?.hasPrefix(leaseNoAccel) == true)
    }

    /// SDK 4.0.5 (ACCEL_40 21.2): whether the telemetry names a lease without accelerator programs `not_attested`. ON:
    /// qlab-api takes the 19th reason since 2026-11-23 13:55Z (4757fd5, version ac01594d; a reason outside the server's
    /// list refuses the whole delta). Off, it is counted `denylist`, as 4.0.2 to 4.0.4 counted it.
    static let sendsNotAttested = Locked(true)

    private func noteDenied(_ rec: inout PromotionRecord, _ why: String) {
        hold(nil)
        if !rec.denied {
            // SDK 4.0.5 (21.2): a lease without accelerator programs is `not_attested` while the switch is on (it is)
            let reason: PromotionReason = why.hasPrefix(Self.leaseNoAccel) && Self.sendsNotAttested.withLock({ $0 }) ? .notAttested : .denylist
            rec.denied = true
            rec.lastReason = reason
            rec.lastDetail = why
            store.save(rec)
            promotion(.demoted(reason))
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
        if let why = leaseDenied() {
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
        promotion(.failover(cause: f.cause, stallMs: f.stallMs))
        let reason: FallbackReason = f.cause == .nonFinite ? .nonFinite : f.cause == .deadline ? .deadline : .other
        env.record(.fallback(reason, cohort: env.cohort()))
        let c = AcceleratorController.conditionsNow()
        env.incident(AcceleratorIncident(kind: .failover, stage: "session", cause: f.cause.incidentCause, message: f.detail,
                                         errorDomain: f.errorDomain, errorCode: f.errorCode, chunk: f.chunk, elapsedMs: f.elapsedMs,
                                         deadlineMs: f.deadlineMs, divergence: f.divergence, stallMs: f.stallMs,
                                         revision: named(env.revision).revision, build: named(env.revision).build,
                                         context: env.context, thermal: c.thermal, lowPower: c.lowPower))
        trouble(f.cause, detail: f.detail, session: session)
    }

    /// The record of the key after trouble on the accelerator in a session, by its cause (2.0.2): the failover's rule,
    /// and a live promotion's for the same kind of trouble.
    private func trouble(_ cause: FailoverCause, detail: String, session: String) {
        var rec = store.record(key) ?? PromotionRecord(key: key)
        let now = env.clock()
        switch cause {
        case .deadline:
            var misses = (rec.missSessions ?? []).filter { now.timeIntervalSince($0.at) < PromotionPolicy.missWindow }
            if !misses.contains(where: { $0.session == session }) { misses.append(.init(session: session, at: now)) }
            if Set(misses.map(\.session)).count >= PromotionPolicy.missSessions {
                rec.missSessions = nil
                demoteTransient(&rec, cause, detail, now)
            } else {
                // one miss: this session is on the CPU, the build stays promoted for the next one
                rec.missSessions = misses
                store.save(rec)
            }
        case .blank:
            let n = (rec.disagreements ?? 0) + 1
            rec.disagreements = n
            if n >= PromotionPolicy.disagreementsOffForGood { offForGood(&rec, cause, detail, .failover) } else { demoteTransient(&rec, cause, detail, now) }
        case .nonFinite, .outOfRange:
            offForGood(&rec, cause, detail, .nonFinite)
        case .exception:
            hold(nil)
            rec.failures += 1
            rec.lastStage = nil
            rec.lastReason = .failover
            rec.lastCause = cause
            rec.lastDetail = "failover: \(detail)"
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

    /// A live promotion ended without a swap. What it writes into the record is the failover's
    /// rule for the same kind of trouble (30.6): `mismatch` as a confirmed blank disagreement, `mismatch_inexact` as a
    /// deadline miss of this session, `accel_failed` by its cause; `stalled` and `aborted` nothing. No failover is
    /// counted and no incident is reported: no take left the accelerator (until the swap the accelerator's chunks are
    /// never the take's). When the record takes the build back, its program is released. It is counted with the take's
    /// tally (`liveTally`).
    func liveEnded(_ e: TakeRunner.LiveEnd, session: String) {
        let cause: FailoverCause
        switch LivePromotion.recordRule(e.outcome) {
        case nil: return
        case .disagreement?: cause = .blank
        case .deadlineMiss?: cause = .deadline
        case .byCause?: cause = e.cause ?? .exception
        }
        lock.lock()
        let held = executor
        lock.unlock()
        trouble(cause, detail: "live promotion (\(e.outcome.rawValue)): \(e.detail)", session: session)
        lock.lock()
        let kept = held != nil && executor === held
        lock.unlock()
        if let held, !kept { held.enqueue { $0.release() } }
    }

    /// A take's part of the day's `live` object (30.9), at its end.
    func liveTally(_ t: LiveTally) {
        guard !t.isEmpty else { return }
        promotion(.live(t))
    }

    /// A transient demotion: the build stays promoted and verified, unused for `PromotionPolicy.transientBackoff`
    /// (then loaded and warmed again, no golden test); never off for good.
    private func demoteTransient(_ rec: inout PromotionRecord, _ cause: FailoverCause, _ detail: String, _ now: Date) {
        hold(nil)
        let until = now.addingTimeInterval(PromotionPolicy.transientBackoff)
        rec.backoffUntil = until
        rec.lastCause = cause
        rec.lastReason = .failover
        rec.lastDetail = "failover: \(detail)"
        store.save(rec)
        promotion(.demoted(.failover))
        set(.disabled(Self.backoffDetail(rec, until)))
    }

    /// A confirmed numeric fault: never again for the key (a new model revision or OS build tries again).
    private func offForGood(_ rec: inout PromotionRecord, _ cause: FailoverCause, _ detail: String, _ reason: PromotionReason) {
        hold(nil)
        rec.status = .failed
        rec.notBefore = nil
        rec.backoffUntil = nil
        rec.completed = nil
        rec.attemptStarted = nil
        rec.lastStage = nil
        rec.lastReason = reason
        rec.lastCause = cause
        rec.lastDetail = "failover: \(detail)"
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

    /// Drops the held executor when a call on it hung, or its program is gone with the model the Core closed (true
    /// then).
    private func dropAbandoned() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let e = executor, e.abandoned || !e.backend.isUsable, !leased else { return false }
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

    /// The clock of a stage's time limit (`race`): it counts the time this process ran, in steps of `step` seconds, and
    /// a step whose wait took more than `step + stalled` counts only `step`: the process did not run for the rest
    /// (the app suspended in the background, the device asleep), and neither did the stage's work.
    struct RunClock: Sendable {
        var now: @Sendable () -> TimeInterval
        var step: TimeInterval = 1
        var stalled: TimeInterval = 5
        static let live = RunClock(now: { ProcessInfo.processInfo.systemUptime })
    }

    /// The clock `race` uses (tests set a fake one).
    static let runClock = Locked(RunClock.live)

    /// Runs `body` and gives up waiting for it after `seconds` of the process's running time (`RunClock`): a body that
    /// never returns is abandoned (it may go on in the background; its result is dropped), unlike a task group, which
    /// would wait for it. SDK 4.0.5: until 4.0.4 the limit was wall time, so a compile the system suspended with the
    /// app (the learner left the app for a few minutes) ended as `compile_timeout` or a 600 s load at the first moment
    /// back. How many of the 4.0.x timeouts that explains is not known (a timeout report carries no foreground): of the
    /// 14 compile timeouts of the 7 days to 2026-11-25, 7 were on A14 and A20, chips whose program never promotes
    /// (A14) or fails the golden test (A20), so most look like a compile that does not end; 225 of the 235 compiles
    /// that completed took 120 s or less. This makes the limit mean what it says; it is not the fix for those.
    static func race<T: Sendable>(_ seconds: TimeInterval, onTimeout: PromotionFailure,
                                  _ body: @escaping @Sendable () async throws(PromotionFailure) -> T) async -> Result<T, PromotionFailure> {
        let gate = Locked(false)
        let clock = runClock.withLock { $0 }
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
                var counted: TimeInterval = 0
                var last = clock.now()
                while counted < seconds {
                    let step = min(max(0.001, clock.step), seconds - counted)
                    try? await Task.sleep(nanoseconds: UInt64(max(0, step) * 1e9))
                    if Task.isCancelled { return }
                    let now = clock.now()
                    let waited = max(0, now - last)
                    last = now
                    counted += waited > step + clock.stalled ? step : waited
                }
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
    /// SDK 4.0.2 (21.6 item 2): the recognizers to tell at every lease the Core accepts (a new install's, a renewal, a
    /// lease after a refusal ended); each asks the lease again and goes on where a lease without accelerator programs
    /// held it.
    static let leaseWatchers = Locked<[UUID: @Sendable () async -> Void]>([:])

    static func watchLease(_ id: UUID, _ run: @escaping @Sendable () async -> Void) { leaseWatchers.withLock { $0[id] = run } }

    /// A lease was accepted: every watcher is told, in the background.
    static func leaseAccepted() {
        let all = leaseWatchers.withLock { Array($0.values) }
        guard !all.isEmpty else { return }
        Task.detached(priority: .utility) { for r in all { await r() } }
    }

    static func add(_ id: UUID, _ run: @escaping @Sendable () async -> Void) { pending.withLock { $0[id] = run } }
    static func remove(_ id: UUID) {
        _ = pending.withLock { $0.removeValue(forKey: id) }
        _ = leaseWatchers.withLock { $0.removeValue(forKey: id) }
    }

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
    /// Lets the app run the Neural Engine's promotion while the device is idle and charging: call once at launch, before
    /// the app finishes launching, with an identifier listed in the app's `BGTaskSchedulerPermittedIdentifiers`. Without
    /// it, the SDK runs it after the first finished session (or after a short idle delay), at background priority.
    /// SDK 4.0.5: in such a task only the download runs; the compile and the load wait for the app in the foreground
    /// with the device unlocked (`PromotionConditions.blocker`), which a task while charging seldom has. Until 4.0.4 the
    /// task compiled too, and on a locked device that always failed.
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
