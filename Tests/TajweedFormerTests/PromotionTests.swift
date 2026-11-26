import Foundation
import XCTest
@testable import TajweedFormer

/// The promotion pipeline's state machine with fakes for the network, the files, the compiler, the engines and the
/// clock: no model, no CoreML, no Neural Engine. Every stage succeeding; every failure at every stage with its reason;
/// a restart in the middle of each stage (a new controller on the same record, the crash sentinel); OS build and
/// revision changes; backoff and its cap; deterministic failures never retried; conditions that wait without
/// counting; a session during the golden test; a build slower than the CPU kept off (4.0); failover demotion; telemetry.
final class PromotionTests: XCTestCase {
    /// The telemetry cohort of these tests (it was the retired 3.x AcceleratorTests' own).
    static let cohort = TelemetryCohort(revision: "4.0.0", build: "", context: "c16_l64", backend: "cpu")

    final class Harness: @unchecked Sendable {
        let storage = Fixtures.storage()
        let now = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let conditions = Locked(PromotionConditions())
        let events = Locked<[AnalyticsEvent]>([])
        let incidents = Locked<[AcceleratorIncident]>([])
        let calls = Locked<[String]>([])
        let failures = Locked<[PromotionStage: PromotionFailure]>([:])
        /// Outcomes of the golden test, in order (then `.passed`).
        let goldens = Locked<[AcceleratorController.GoldenOutcome]>([])
        let session = Locked(false)
        let denied = Locked<String?>(nil)
        let slowCompile = Locked<Double>(0)
        let goldenTimes = Locked<(acc: [Double], cpu: [Double])>(([0.002, 0.003, 0.002], [0.008, 0.009, 0.008]))
        /// The signed config's `flags.accel_min_speedup`, and this SDK's version.
        let minSpeedup = Locked<Double?>(nil)
        let sdk = Locked("4.0.0")
        /// SDK 4.0.2 (21.6): what `qlc_accel_allowed` answers for the lease in force (nil: no lease, the Core cannot say).
        let leaseAllows = Locked<Bool?>(nil)

        func env(revision: String = "r1", os: String = "23A100", device: String = "iPhone17,1", launch: String = "L1",
                 timeouts: AcceleratorController.Timeouts = .init()) -> AcceleratorController.Environment {
            let now = self.now, cond = self.conditions, ev = self.events, inc = self.incidents, den = self.denied
            var e = AcceleratorController.Environment(
                revision: revision, osBuild: os, deviceModel: device, context: "c16_l64", build: "coreml", storage: storage, launch: launch,
                clock: { now.withLock { $0 } }, sleep: { _ in await Task.yield() },
                conditions: { cond.withLock { $0 } }, maxConditionWaits: 2,
                thermal: { .nominal }, denied: { den.withLock { $0 } },
                record: { e in ev.withLock { $0.append(e) } }, incident: { i in inc.withLock { $0.append(i) } },
                cohort: { PromotionTests.cohort })
            e.timeouts = timeouts
            // no MetricKit in tests: the evidence is what the sentinel says, at once
            e.crashEvidence = { s in CrashDiagnostics.evidence(s, nil, app: nil) }
            let ms = self.minSpeedup
            e.minSpeedup = { ms.withLock { $0 } }
            e.sdkVersion = sdk.withLock { $0 }
            let la = self.leaseAllows
            e.acceleratorAllowed = { la.withLock { $0 } }
            return e
        }

        func stages() -> AcceleratorController.Stages {
            let calls = self.calls, failures = self.failures, goldens = self.goldens, session = self.session, slow = self.slowCompile
            let times = self.goldenTimes
            return AcceleratorController.Stages(
                download: { () async throws(PromotionFailure) -> Void in
                    calls.withLock { $0.append("download") }
                    if let f = failures.withLock({ $0[.download] }) { throw f }
                },
                compile: { () async throws(PromotionFailure) -> UncheckedBox<any AcceleratorBackend> in
                    calls.withLock { $0.append("compile") }
                    let d = slow.withLock { $0 }
                    if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d * 1e9)) }
                    if let f = failures.withLock({ $0[.compile] }) { throw f }
                    return UncheckedBox(FakeAccelerator() as any AcceleratorBackend)
                },
                warmup: { (_: UncheckedBox<any AcceleratorBackend>) async throws(PromotionFailure) -> Void in
                    calls.withLock { $0.append("warmup") }
                    if let f = failures.withLock({ $0[.warmup] }) { throw f }
                },
                golden: { (_: UncheckedBox<any AcceleratorBackend>) async -> AcceleratorController.GoldenOutcome in
                    calls.withLock { $0.append("golden") }
                    if let f = failures.withLock({ $0[.golden] }) { return .failed(f) }
                    let next = goldens.withLock { g -> AcceleratorController.GoldenOutcome? in g.isEmpty ? nil : g.removeFirst() }
                    if let next { return next }
                    let t = times.withLock { $0 }
                    return .passed(accelerator: t.acc, cpu: t.cpu)
                },
                sessionActive: { () async -> Bool in session.withLock { $0 } },
                waitIdle: { () async -> Void in
                    calls.withLock { $0.append("waitIdle") }
                    session.withLock { $0 = false }
                })
        }

        func controller(revision: String = "r1", os: String = "23A100", launch: String = "L1",
                        timeouts: AcceleratorController.Timeouts = .init()) -> AcceleratorController {
            AcceleratorController(env(revision: revision, os: os, launch: launch, timeouts: timeouts))
        }

        func advance(_ s: TimeInterval) { now.withLock { $0 = $0.addingTimeInterval(s) } }
        func count(_ stage: String) -> Int { calls.withLock { $0 }.filter { $0 == stage }.count }
        func resetCalls() { calls.withLock { $0 = [] } }
        var promotions: [PromotionTelemetry] {
            events.withLock { $0 }.compactMap { if case .promotion(let p) = $0 { return p } else { return nil } }
        }
    }

    var h = Harness()

    override func setUp() {
        h = Harness()
    }

    // MARK: success

    func testEveryStageSucceedsAndThePromotedBuildIsLeasedAtTheNextSession() async {
        let c = h.controller()
        XCTAssertEqual(c.state, .cpu)
        XCTAssertNil(c.leaseForSession(), "nothing before the pipeline")
        await c.run(h.stages())
        XCTAssertEqual(c.state, .ready)
        XCTAssertEqual(h.calls.withLock { $0 }, ["download", "compile", "warmup", "golden"])
        let r = try? XCTUnwrap(c.record)
        XCTAssertEqual(r?.status, .ready)
        XCTAssertEqual(r?.completed, .promote)
        XCTAssertEqual(r?.attempts, 1)
        XCTAssertEqual(r?.acceleratorMedianMs ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(r?.cpuMedianMs ?? 0, 8, accuracy: 0.001)
        XCTAssertNotNil(r?.compileMs)
        XCTAssertNotNil(c.leaseForSession())
        XCTAssertNil(c.leaseForSession(), "one session at a time holds the build")
        c.endLease()
        XCTAssertNotNil(c.leaseForSession())
        guard case .attempt(let promoted, _, _, let compileMs, let speedup)? = h.promotions.last?.kind else { return XCTFail("\(h.promotions)") }
        XCTAssertTrue(promoted)
        XCTAssertNotNil(compileMs)
        XCTAssertEqual(speedup ?? 0, 4, accuracy: 0.01)
        XCTAssertNil(c.store.sentinel(), "no sentinel left after a clean run")
        print("v4-promotion success: stages \(h.calls.withLock { $0 }), speedup \(speedup ?? 0)")
    }

    /// SDK 4.0 (as Android, after a device lab's NPU path that matched exactly at a tenth of the CPU's speed): a build
    /// that passes the golden test but is slower than the CPU engine on this device stays off. The CPU engine runs, the
    /// attempt is `slower_than_cpu` with both medians in the telemetry, and the retry budget is not used.
    func testABuildSlowerThanTheCPUIsNotPromoted() async throws {
        h.goldenTimes.withLock { $0 = ([0.030, 0.040, 0.035], [0.008, 0.009, 0.008]) }
        let c = h.controller()
        await c.run(h.stages())
        guard case .disabled = c.state else { return XCTFail("\(c.state)") }
        XCTAssertNil(c.leaseForSession(), "the CPU engine runs")
        let r = try XCTUnwrap(c.record)
        XCTAssertEqual(r.status, .retry)
        XCTAssertEqual(r.lastReason, .slowerThanCPU)
        XCTAssertEqual(r.lastStage, .measure)
        XCTAssertEqual(r.failures, 0, "not a failure of the build")
        XCTAssertEqual(r.slowerSDK, "4.0.0")
        XCTAssertEqual(r.notBefore, h.now.withLock { $0 }.addingTimeInterval(PromotionPolicy.slowerRetry))
        XCTAssertEqual(r.acceleratorMedianMs ?? 0, 35, accuracy: 0.001)
        XCTAssertEqual(r.cpuMedianMs ?? 0, 8, accuracy: 0.001)
        guard case .slowerThanCPU(let acc, let cpu, _)? = h.promotions.last?.kind else { return XCTFail("\(h.promotions)") }
        XCTAssertEqual(acc, 35, accuracy: 0.001)
        XCTAssertEqual(cpu, 8, accuracy: 0.001)
        let store = AnalyticsStore(storage: h.storage, enabled: true, context: .init(platform: "ios", sdkVersion: "4.0.0", appVersion: "1",
                                                                                     deviceClass: "phone", soc: nil, osMajor: 18, ramTier: "6gb"))
        for p in h.promotions { store.record(.promotion(p)) }
        let entry = try XCTUnwrap(AnalyticsStore.promotions(try XCTUnwrap(store.pending.first).promotions).first)
        XCTAssertNil(entry["promoted"])
        XCTAssertEqual(entry["attempts"] as? Int, 1)
        XCTAssertEqual(entry["reasons"] as? [String: Int], ["slower_than_cpu": 1])
        XCTAssertEqual(entry["speedup"] as? [String: Int], ["lt_0_5": 1])
        XCTAssertEqual(entry["slower_than_cpu"] as? [[String: Double]], [["accelerator_ms": 35, "cpu_ms": 8]])
    }

    /// Not slower is enough: an accelerator as fast as the CPU engine is promoted.
    func testABuildAsFastAsTheCPUIsPromoted() async {
        h.goldenTimes.withLock { $0 = ([0.008, 0.008, 0.008], [0.008, 0.008, 0.008]) }
        let c = h.controller()
        await c.run(h.stages())
        XCTAssertEqual(c.state, .ready)
    }

    /// The signed config can ask for more than 1.0, never less.
    func testTheConfigsMinimumSpeedupHasAFloorOfOne() async {
        XCTAssertEqual(PromotionPolicy.minSpeedup(nil), 1)
        XCTAssertEqual(PromotionPolicy.minSpeedup(0.5), 1)
        XCTAssertEqual(PromotionPolicy.minSpeedup(.nan), 1)
        XCTAssertEqual(PromotionPolicy.minSpeedup(.infinity), 1)
        XCTAssertEqual(PromotionPolicy.minSpeedup(1.5), 1.5)
        // 1.33 times faster: promoted by default, kept off with 1.5
        h.goldenTimes.withLock { $0 = ([0.006, 0.006, 0.006], [0.008, 0.008, 0.008]) }
        h.minSpeedup.withLock { $0 = 1.5 }
        let c = h.controller()
        await c.run(h.stages())
        XCTAssertEqual(c.record?.lastReason, .slowerThanCPU)
        // a config below 1.0 cannot let a slower build through
        h = Harness()
        h.goldenTimes.withLock { $0 = ([0.010, 0.010, 0.010], [0.008, 0.008, 0.008]) }
        h.minSpeedup.withLock { $0 = 0.5 }
        let d = h.controller()
        await d.run(h.stages())
        XCTAssertEqual(d.record?.lastReason, .slowerThanCPU)
    }

    /// Transient: the same key is tried again after 30 days, or at once by another SDK version; an OS update or a new
    /// build is a new key with its own attempt.
    func testASlowerVerdictIsRetriedAfterAnUpdateOrThirtyDays() async {
        h.goldenTimes.withLock { $0 = ([0.030, 0.040, 0.035], [0.008, 0.009, 0.008]) }
        await h.controller().run(h.stages())
        h.resetCalls()
        // the next launch, the same SDK, a day later: nothing runs
        h.advance(86_400)
        await h.controller(launch: "L2").run(h.stages())
        XCTAssertEqual(h.calls.withLock { $0 }, [])
        // another SDK version: tried again at once (and, as fast as the CPU now, promoted)
        h.sdk.withLock { $0 = "4.0.1" }
        h.goldenTimes.withLock { $0 = ([0.008, 0.008, 0.008], [0.008, 0.008, 0.008]) }
        let c = h.controller(launch: "L3")
        await c.run(h.stages())
        XCTAssertEqual(h.calls.withLock { $0 }, ["download", "compile", "warmup", "golden"])
        XCTAssertEqual(c.state, .ready)
        // the same SDK after 30 days
        h = Harness()
        h.goldenTimes.withLock { $0 = ([0.030, 0.040, 0.035], [0.008, 0.009, 0.008]) }
        await h.controller().run(h.stages())
        h.resetCalls()
        h.advance(PromotionPolicy.slowerRetry + 60)
        await h.controller(launch: "L2").run(h.stages())
        XCTAssertEqual(h.calls.withLock { $0 }, ["download", "compile", "warmup", "golden"])
        // an OS update is a new key: its own attempt at once
        h.resetCalls()
        await h.controller(os: "23B200", launch: "L3").run(h.stages())
        XCTAssertEqual(h.calls.withLock { $0 }, ["download", "compile", "warmup", "golden"])
    }

    // MARK: failures at every stage

    func testEveryFailureAtEveryStageKeepsTheCPUWithItsReason() async {
        let cases: [(PromotionStage, PromotionReason)] = [
            (.download, .network), (.download, .storage), (.download, .verify), (.download, .other),
            (.compile, .compileError), (.warmup, .loadError), (.warmup, .nonFinite), (.warmup, .hang),
            (.golden, .goldenMismatch), (.golden, .cpuMismatch), (.golden, .nonFinite), (.golden, .hang),
        ]
        for (i, (stage, reason)) in cases.enumerated() {
            h = Harness()
            h.failures.withLock { $0[stage] = PromotionFailure(reason, "injected \(reason.rawValue)") }
            let c = h.controller(revision: "f\(i)")
            await c.run(h.stages())
            guard case .disabled(let why) = c.state else { XCTFail("\(stage) \(reason): \(c.state)"); continue }
            XCTAssertTrue(why.hasPrefix(stage.rawValue + ":"), why)
            XCTAssertNil(c.leaseForSession())
            let r = c.record!
            XCTAssertEqual(r.lastStage, stage)
            XCTAssertEqual(r.lastReason, reason)
            XCTAssertEqual(r.status, reason.deterministic ? .failed : .retry, "\(reason)")
            XCTAssertNil(r.attemptStarted)
            guard case .attempt(false, let s, let rr, _, _)? = h.promotions.last?.kind else { XCTFail("\(h.promotions)"); continue }
            XCTAssertEqual(s, stage)
            XCTAssertEqual(rr, reason)
            let inc = h.incidents.withLock { $0 }.last
            XCTAssertEqual(inc?.kind, .promotionFailed)
            XCTAssertEqual(inc?.code, "\(stage.rawValue):\(reason.incidentCause)")
            XCTAssertEqual(inc?.attempt, 1)
            XCTAssertNil(c.store.sentinel())
        }
    }

    func testACompileTimeoutIsItsOwnReasonAndAbandonsTheCompile() async {
        h.slowCompile.withLock { $0 = 5 }
        var t = AcceleratorController.Timeouts()
        t.compile = 0.2
        let c = h.controller(timeouts: t)
        let t0 = Date()
        await c.run(h.stages())
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3, "the timeout does not wait for the compile")
        XCTAssertEqual(c.record?.lastReason, .compileTimeout)
        XCTAssertEqual(c.record?.status, .retry)
    }

    /// SDK 4.0.5: a stage's limit counts the time the process ran (`AcceleratorController.RunClock`). A compile the
    /// system suspended with the app for an hour is no timeout; a compile that runs past the limit still is. Until 4.0.4
    /// the limit was wall time, and the 4.0.x timeouts of the 7 days to 2026-11-25 sat at the limit itself (600 s).
    /// Not compiled or run on 11-25 (no Mac).
    func testACompileTheSystemSuspendedIsNoTimeout() async {
        let offset = Locked<TimeInterval>(0)
        AcceleratorController.runClock.withLock {
            $0 = AcceleratorController.RunClock(now: { ProcessInfo.processInfo.systemUptime + offset.withLock { $0 } }, step: 0.05, stalled: 0.5)
        }
        defer { AcceleratorController.runClock.withLock { $0 = .live } }
        h.slowCompile.withLock { $0 = 0.6 }
        var t = AcceleratorController.Timeouts()
        t.compile = 1.0
        let c = h.controller(timeouts: t)
        // 0.2 s into the compile, an hour passes on the clock while the process does not run
        let jump = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            offset.withLock { $0 += 3600 }
        }
        await c.run(h.stages())
        await jump.value
        XCTAssertEqual(c.state, .ready, "the hour suspended is no part of the limit")
        XCTAssertNil(c.record?.lastReason)

        h = Harness()
        h.slowCompile.withLock { $0 = 3 }
        t.compile = 0.4
        let d = h.controller(timeouts: t)
        let t0 = Date()
        await d.run(h.stages())
        XCTAssertEqual(d.record?.lastReason, .compileTimeout, "running past the limit is still a timeout")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.5)
    }

    /// SDK 4.0.5: the compile and the load wait for the device unlocked and the app not in the background (the Core
    /// writes the program with complete file protection, and a lock during Core ML's compile was a SIGBUS in the field);
    /// the download does not. Waiting is no failure. Not compiled or run on 11-25 (no Mac).
    /// SDK 4.0.5: a compile the device's lock or the app's leaving cut (the program unreadable once the lock takes the key
    /// of its complete protection away, "not a valid .mlmodelc") is not a failure of the build: no failure recorded, no
    /// backoff, no incident, `not_now` in telemetry; the run waits for an unlocked device and the foreground and compiles
    /// again in the same attempt, which promotes. A compile error with no lock and no leaving counts as before.
    /// SDK 4.0.5 on the Core c3: the compile asks the system for no background time. c3 writes the package with
    /// complete file protection; with extra time an app that leaves runs on past the moment those files lock, and Core
    /// ML's mapped reads fault (SIGBUS, 4.0.2 crash reports). Without it the app is suspended first.
    func testTheCompileAsksForNoBackgroundTime() async {
        let asked = Locked<[String]>([])
        InstallGrace.override.withLock { $0 = { name in asked.withLock { $0.append(name) }; return {} } }
        defer { InstallGrace.override.withLock { $0 = nil } }
        h = Harness()
        let c = h.controller(revision: "no-grace")
        await c.run(h.stages())
        XCTAssertEqual(c.state, .ready)
        XCTAssertEqual(h.calls.withLock { $0 }.filter { $0 == "compile" }.count, 1)
        XCTAssertEqual(asked.withLock { $0 }, [], "no beginBackgroundTask around the compile, or anywhere in the run")
    }

    func testACompileTheLockOrTheAppsLeavingCutRunsAgainAndCountsNothing() async {
        for (cut, why) in [(PromotionConditions(protectedData: false), "locked"), (PromotionConditions(background: true), "background")] {
            h = Harness()
            let cond = h.conditions, fails = h.failures, calls = h.calls
            h.failures.withLock { $0[.compile] = PromotionFailure(.compileError, "Failed to open file: coremldata.bin. It is not a valid .mlmodelc file.") }
            var e = h.env(revision: "cut-\(why)")
            // the fake compile: the device locks (or the app leaves) while it runs, and the compile fails for it
            let compile = h.stages().compile
            var stages = h.stages()
            stages.compile = { () async throws(PromotionFailure) -> UncheckedBox<any AcceleratorBackend> in
                if fails.withLock({ $0[.compile] }) != nil { cond.withLock { $0 = cut } }
                return try await compile()
            }
            // the wait for conditions: the learner unlocks (or comes back), and the next compile goes through
            let waits = Locked(0)
            e.sleep = { _ in
                waits.withLock { $0 += 1 }
                cond.withLock { $0 = PromotionConditions() }
                fails.withLock { $0[.compile] = nil }
            }
            let c = AcceleratorController(e)
            await c.run(stages)
            XCTAssertEqual(c.state, .ready, "\(why): the same attempt compiles again and promotes")
            XCTAssertEqual(calls.withLock { $0 }.filter { $0 == "compile" }.count, 2, why)
            XCTAssertEqual(waits.withLock { $0 }, 1, "\(why): it waited for the device and the foreground once")
            XCTAssertEqual(c.record?.attempts, 1, why)
            XCTAssertEqual(c.record?.failures, 0, why)
            XCTAssertNil(c.record?.lastReason, why)
            XCTAssertNil(c.record?.backoffUntil, why)
            XCTAssertTrue(h.incidents.withLock { $0 }.isEmpty, "\(why): no incident")
            let kinds = h.events.withLock { $0 }.compactMap { (ev: AnalyticsEvent) -> PromotionTelemetry.Kind? in
                if case .promotion(let t) = ev { return t.kind }
                return nil
            }
            XCTAssertTrue(kinds.contains(.notNow(stage: .compile, why: why)), "\(why): \(kinds)")
            XCTAssertFalse(kinds.contains { if case .attempt(false, _, _, _, _) = $0 { return true }; return false }, "\(why): no failed attempt")
        }
        // the same error with no lock and no leaving: a failure of the build, as before
        h = Harness()
        h.failures.withLock { $0[.compile] = PromotionFailure(.compileError, "Failed to open file: coremldata.bin. It is not a valid .mlmodelc file.") }
        let d = h.controller(revision: "plain")
        await d.run(h.stages())
        XCTAssertEqual(d.record?.failures, 1)
        XCTAssertEqual(d.record?.lastReason, .compileError)
    }

    /// SDK 4.0.5: a run whose compile the lock keeps cutting gives up for now after `notNowRunsMax` and leaves the
    /// attempt as it stood; nothing is counted, and the next run goes on.
    func testACompileCutAgainAndAgainGoesOnAtTheNextRun() async {
        h = Harness()
        let cond = h.conditions, fails = h.failures
        h.failures.withLock { $0[.compile] = PromotionFailure(.compileError, "not a valid .mlmodelc") }
        var e = h.env(revision: "again")
        let compile = h.stages().compile
        var stages = h.stages()
        stages.compile = { () async throws(PromotionFailure) -> UncheckedBox<any AcceleratorBackend> in
            if fails.withLock({ $0[.compile] }) != nil { cond.withLock { $0 = PromotionConditions(protectedData: false) } }
            return try await compile()
        }
        e.sleep = { _ in cond.withLock { $0 = PromotionConditions() } }
        let c = AcceleratorController(e)
        await c.run(stages)
        XCTAssertEqual(h.count("compile"), AcceleratorController.notNowRunsMax + 1)
        XCTAssertEqual(c.state, .cpu)
        XCTAssertEqual(c.record?.failures, 0)
        XCTAssertNil(c.record?.lastReason)
        XCTAssertTrue(h.incidents.withLock { $0 }.isEmpty)
        fails.withLock { $0[.compile] = nil }
        await c.run(stages)
        XCTAssertEqual(c.state, .ready, "the next run goes on with the same attempt")
        XCTAssertEqual(c.record?.attempts, 1)
    }

    func testTheCompileWaitsForAnUnlockedDeviceAndTheForeground() async {
        XCTAssertEqual(PromotionConditions(protectedData: false).blocker(for: .compile, prepares: true), "the device is locked")
        XCTAssertEqual(PromotionConditions(background: true).blocker(for: .warmup, prepares: true), "the app is in the background")
        XCTAssertNil(PromotionConditions(protectedData: false, background: true).blocker(for: .download))
        XCTAssertNil(PromotionConditions(protectedData: false, background: true).blocker(for: .golden))
        XCTAssertNil(PromotionConditions(protectedData: false, background: true).blocker(for: .warmup), "a warm-up of the program in memory")
        for blocked in [PromotionConditions(protectedData: false), PromotionConditions(background: true)] {
            h = Harness()
            h.conditions.withLock { $0 = blocked }
            let c = h.controller(revision: "gate")
            await c.run(h.stages())
            XCTAssertEqual(h.calls.withLock { $0 }, ["download"], "the download only")
            XCTAssertEqual(c.state, .cpu)
            XCTAssertEqual(c.record?.failures, 0)
            XCTAssertNil(c.record?.lastReason)
            XCTAssertTrue(h.incidents.withLock { $0 }.isEmpty)
            h.conditions.withLock { $0 = PromotionConditions() }
            await c.run(h.stages())
            XCTAssertEqual(c.state, .ready, "unlocked and in the foreground, the same attempt goes on and promotes")
        }
        // the app leaves while the compile runs: the warm-up of the program just compiled does not wait (it prepares
        // nothing), and the attempt promotes
        h = Harness()
        h.slowCompile.withLock { $0 = 0.3 }
        let cond = h.conditions
        let leave = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            cond.withLock { $0 = PromotionConditions(protectedData: false, background: true) }
        }
        let d = h.controller(revision: "left")
        await d.run(h.stages())
        await leave.value
        XCTAssertEqual(d.state, .ready)
    }

    // MARK: restarts

    /// A record left in the middle of an attempt by an earlier launch (killed, rebooted): the next launch resumes at
    /// the stage after the last one recorded; past the compile, the build is loaded again at the warm-up.
    func testARestartResumesAfterTheLastRecordedStage() async {
        let expected: [(PromotionStage?, [String])] = [
            (nil, ["download", "compile", "warmup", "golden"]),
            (.download, ["compile", "warmup", "golden"]),
            (.compile, ["compile", "warmup", "golden"]),     // the load before the warm-up
            (.warmup, ["compile", "warmup", "golden"]),
            (.golden, ["compile", "warmup"]),
            (.measure, ["compile", "warmup"]),
        ]
        for (i, (done, calls)) in expected.enumerated() {
            h = Harness()
            let first = h.controller(revision: "k\(i)", launch: "L1")
            var r = PromotionRecord(key: first.key)
            r.attempts = 1
            r.attemptStarted = h.now.withLock { $0 }
            r.launch = "L1"
            r.completed = done
            r.acceleratorMedianMs = 2
            r.cpuMedianMs = 8
            first.store.save(r)
            let next = h.controller(revision: "k\(i)", launch: "L2")
            await next.run(h.stages())
            XCTAssertEqual(next.state, .ready, "resumed after \(done?.rawValue ?? "nothing")")
            XCTAssertEqual(h.calls.withLock { $0 }, calls, "after \(done?.rawValue ?? "nothing")")
            XCTAssertEqual(next.record?.attempts, 1, "a resumed attempt is the same attempt")
        }
    }

    /// A process death inside a stage: the sentinel is found at the next launch and that attempt ends with reason
    /// crash at that stage. At the golden test it is deterministic (never again for the key); at the compile and
    /// the warm-up, before the model ran on the accelerator, it takes the retry budget (3.1.5: the sentinel here
    /// says nothing of the foreground, as on a Mac, and a stop then takes the foreground rule;
    /// PreparationStopTests has the rest).
    func testTheCrashSentinelEndsTheAttemptAtItsStage() async {
        for (i, stage) in [PromotionStage.compile, .warmup, .golden].enumerated() {
            h = Harness()
            let c = h.controller(revision: "c\(i)")
            var r = PromotionRecord(key: c.key)
            r.attempts = 1
            r.attemptStarted = h.now.withLock { $0 }
            c.store.save(r)
            c.store.writeSentinel(c.key, stage)
            let next = h.controller(revision: "c\(i)", launch: "L2")
            await next.lastLaunchReport?.value
            XCTAssertNil(next.store.sentinel(), "read once")
            XCTAssertEqual(next.record?.lastReason, .crash)
            XCTAssertEqual(next.record?.lastStage, stage)
            XCTAssertEqual(next.record?.status, stage.isPreparation ? .retry : .failed, "\(stage)")
            guard case .disabled = next.state else { XCTFail("\(next.state)"); continue }
            await next.run(h.stages())
            XCTAssertEqual(h.calls.withLock { $0 }, [], "not now: never again at the golden test, not before the retry time at the compile and the warm-up")
            XCTAssertEqual(h.incidents.withLock { $0 }.last?.code, "\(stage.rawValue):crash_on_last_run")
            // another OS build may try again
            let updated = h.controller(revision: "c\(i)", os: "23B9", launch: "L3")
            await updated.run(h.stages())
            XCTAssertEqual(updated.state, .ready)
        }
    }

    /// SDK 4.0: a quit during a stage (willTerminate wrote `quit` into the sentinel) is `interrupted`, retried after
    /// the backoff, and its report says `exit: quit`; a stop without a diagnostic says what the heartbeat saw.
    func testAQuitDuringAStageIsInterruptedNotACrash() async {
        for (i, stage) in [PromotionStage.compile, .warmup, .golden].enumerated() {
            h = Harness()
            let c = h.controller(revision: "q\(i)")
            var r = PromotionRecord(key: c.key)
            r.attempts = 1
            r.attemptStarted = h.now.withLock { $0 }
            c.store.save(r)
            c.store.writeSentinel(c.key, stage)
            c.store.updateSentinel { $0.quit = true }
            let next = h.controller(revision: "q\(i)", launch: "L2")
            await next.lastLaunchReport?.value
            XCTAssertEqual(next.record?.lastReason, .interrupted)
            XCTAssertEqual(next.record?.status, .retry, "retried after the backoff")
            XCTAssertEqual(next.record?.failures, 0, "a quit never uses up the retry budget")
            let inc = h.incidents.withLock { $0 }.last
            XCTAssertEqual(inc?.code, "\(stage.rawValue):interrupted")
            XCTAssertEqual(inc?.crash?.exit, "quit")
        }
        // without quit and without a diagnostic, in the background, where the platform tells it (iOS): the system
        // ended the app there, not a failure of the build (Apple 3.1.5's rule, contract 1.22.2): nothing counted, no
        // wait, the attempt goes on; reported as crash_on_last_run with foreground false and `background` evidence
        AcceleratorController.tellsForeground.withLock { $0 = true }
        defer {
            #if canImport(UIKit) && os(iOS)
            AcceleratorController.tellsForeground.withLock { $0 = true }
            #else
            AcceleratorController.tellsForeground.withLock { $0 = false }
            #endif
        }
        h = Harness()
        let c = h.controller(revision: "b0")
        var b0 = PromotionRecord(key: c.key)
        b0.attempts = 1
        b0.attemptStarted = h.now.withLock { $0 }
        c.store.save(b0)
        c.store.writeSentinel(c.key, .compile)
        c.store.updateSentinel { $0.foreground = false }
        let next = h.controller(revision: "b0", launch: "L2")
        await next.lastLaunchReport?.value
        XCTAssertEqual(next.record?.failures, 0)
        XCTAssertNil(next.record?.notBefore, "no wait")
        XCTAssertNotEqual(next.record?.status, .failed)
        XCTAssertEqual(h.incidents.withLock { $0 }.last?.code, "compile:crash_on_last_run")
        XCTAssertEqual(h.incidents.withLock { $0 }.last?.crash?.exit, "background")
        XCTAssertEqual(h.incidents.withLock { $0 }.last?.foreground, false)
        await next.run(h.stages())
        XCTAssertEqual(next.state, .ready, "the attempt goes on and promotes")
        // in the foreground with no mark: a crash
        h = Harness()
        let f = h.controller(revision: "f0")
        f.store.writeSentinel(f.key, .compile)
        let after = h.controller(revision: "f0", launch: "L2")
        await after.lastLaunchReport?.value
        XCTAssertEqual(after.record?.lastReason, .crash)
    }

    /// Apple 3.1.5's rules in 4.0: a stage under way in another process is not judged; a download the network stopped
    /// never uses up the retry budget; `forget` prepares a failed build again.
    func testAnotherProcessesStageTheNetworkAndForget() async {
        h = Harness()
        let c = h.controller(revision: "o0")
        var s = PromotionStore.Sentinel(key: c.key, stage: .compile)
        s.pid = getppid()
        s.at = Date()
        s.heartbeat = Date()
        XCTAssertTrue(AcceleratorController.underWayElsewhere(s, now: Date()), "a live process with a fresh heartbeat")
        XCTAssertFalse(AcceleratorController.underWayElsewhere(s, now: Date().addingTimeInterval(60)), "a heartbeat that stopped")
        s.pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertFalse(AcceleratorController.underWayElsewhere(s, now: Date()), "this process's own")

        h = Harness()
        h.failures.withLock { $0[.download] = PromotionFailure(.network, "offline: the network connection was lost") }
        for n in 1...6 {
            let d = h.controller(revision: "n0", launch: "L\(n)")
            await d.run(h.stages())
            XCTAssertEqual(d.record?.status, .retry)
            XCTAssertEqual(d.record?.failures, 0)
            h.advance(25 * 3600)
        }

        h = Harness()
        h.failures.withLock { $0[.golden] = PromotionFailure(.goldenMismatch, "tokens differ") }
        let g = h.controller(revision: "g0")
        await g.run(h.stages())
        XCTAssertEqual(g.record?.status, .failed)
        h.failures.withLock { $0 = [:] }
        g.forget()
        XCTAssertNil(g.record)
    }

    // MARK: keys

    func testAnOSBuildOrRevisionChangeIsANewKeyWithAFreshBudget() async {
        h.failures.withLock { $0[.golden] = PromotionFailure(.goldenMismatch, "tokens differ") }
        let c = h.controller()
        await c.run(h.stages())
        XCTAssertEqual(c.record?.status, .failed)
        h.failures.withLock { $0 = [:] }
        let os = h.controller(os: "23B50", launch: "L2")
        XCTAssertEqual(os.state, .cpu)
        await os.run(h.stages())
        XCTAssertEqual(os.state, .ready)
        let rev = h.controller(revision: "r2", launch: "L3")
        XCTAssertEqual(rev.record, nil)
        await rev.run(h.stages())
        XCTAssertEqual(rev.state, .ready)
        XCTAssertEqual(rev.record?.failures, 0)
    }

    // MARK: retries

    func testBackoffIsOneSixAndTwentyFourHoursThenNoMore() async {
        // a stage's failure that counts (a download the network stopped never does, Apple 3.1.5)
        h.failures.withLock { $0[.compile] = PromotionFailure(.compileError, "E5RT: compile failed") }
        var launch = 0
        func run() async -> AcceleratorController {
            launch += 1
            let c = h.controller(launch: "L\(launch)")
            await c.run(h.stages())
            return c
        }
        var c = await run()
        XCTAssertEqual(c.record?.notBefore, h.now.withLock { $0 }.addingTimeInterval(3600))
        h.advance(1800)
        c = await run()
        XCTAssertEqual(c.record?.attempts, 1, "not before the hour")
        h.advance(1800)
        c = await run()
        XCTAssertEqual(c.record?.attempts, 2)
        XCTAssertEqual(c.record?.notBefore, h.now.withLock { $0 }.addingTimeInterval(6 * 3600))
        h.advance(6 * 3600)
        c = await run()
        XCTAssertEqual(c.record?.attempts, 3)
        XCTAssertEqual(c.record?.notBefore, h.now.withLock { $0 }.addingTimeInterval(24 * 3600))
        h.advance(24 * 3600)
        c = await run()
        XCTAssertEqual(c.record?.attempts, 4)
        XCTAssertEqual(c.record?.status, .failed, "3 retries after the first attempt, then none")
        h.advance(100 * 86_400)
        h.resetCalls()
        c = await run()
        XCTAssertEqual(h.count("download"), 0)
        XCTAssertEqual(c.record?.attempts, 4)
    }

    func testDeterministicFailuresAreNeverRetriedForTheKey() async {
        for (i, reason) in [PromotionReason.goldenMismatch, .cpuMismatch, .nonFinite].enumerated() {
            h = Harness()
            h.failures.withLock { $0[.golden] = PromotionFailure(reason, "x") }
            await h.controller(revision: "d\(i)").run(h.stages())
            h.failures.withLock { $0 = [:] }
            h.advance(30 * 86_400)
            h.resetCalls()
            let later = h.controller(revision: "d\(i)", launch: "L9")
            await later.run(h.stages())
            XCTAssertEqual(h.calls.withLock { $0 }, [], "\(reason)")
            XCTAssertEqual(later.record?.status, .failed)
        }
    }

    func testAtMostOneAttemptPerLaunchAndOneRunInFlight() async {
        h.failures.withLock { $0[.download] = PromotionFailure(.network, "offline") }
        let c = h.controller()
        await c.run(h.stages())
        h.advance(2 * 3600)
        h.failures.withLock { $0 = [:] }
        await c.run(h.stages())
        XCTAssertEqual(c.record?.attempts, 1, "the same launch never starts a second attempt")
        // two runs at once: one does the work
        let fresh = h.controller(revision: "r-par", launch: "L5")
        h.slowCompile.withLock { $0 = 0.3 }
        h.resetCalls()
        let stages = h.stages()
        async let a: Void = fresh.run(stages)
        async let b: Void = fresh.run(stages)
        _ = await (a, b)
        XCTAssertEqual(h.count("compile"), 1)
        XCTAssertEqual(fresh.state, .ready)
    }

    // MARK: conditions and sessions

    func testBadConditionsWaitWithoutCounting() async {
        let bad: [PromotionConditions] = [
            PromotionConditions(lowPower: true),
            PromotionConditions(battery: 0.1, charging: false),
            PromotionConditions(thermal: .serious),
        ]
        for (i, cond) in bad.enumerated() {
            h = Harness()
            h.conditions.withLock { $0 = cond }
            let c = h.controller(revision: "w\(i)")
            await c.run(h.stages())
            XCTAssertEqual(h.count("download"), 0, "\(cond)")
            XCTAssertEqual(c.state, .cpu)
            XCTAssertEqual(c.record?.failures, 0)
            XCTAssertNotNil(c.record?.attemptStarted, "the attempt waits, it did not fail")
            h.conditions.withLock { $0 = PromotionConditions() }
            await c.run(h.stages())
            XCTAssertEqual(c.state, .ready, "resumes in the same launch once conditions are good")
            XCTAssertEqual(c.record?.attempts, 1)
        }
        // low battery while charging is fine
        XCTAssertNil(PromotionConditions(battery: 0.1, charging: true).blocker(for: .compile))
        XCTAssertNil(PromotionConditions(thermal: .fair).blocker(for: .golden))
    }

    /// SDK 4.0.2, no_wait_40.json `accelerator_metered`: with the system reporting a metered network, the pipeline's
    /// download stage runs and the attempt goes on to the promotion; no condition of the pipeline is the network's
    /// (the one the device reports now holds no stage either).
    func testTheDownloadStageGoesOnOnAMeteredNetwork() async {
        ConnectionKind.override.withLock { $0 = { .metered } }
        defer { ConnectionKind.override.withLock { $0 = nil } }
        let c = h.controller(revision: "metered")
        await c.run(h.stages())
        XCTAssertEqual(h.count("download"), 1)
        XCTAssertEqual(c.state, .ready)
        XCTAssertEqual(c.record?.failures, 0)
    }

    func testASessionDuringTheGoldenTestAbortsItWithoutAFailure() async {
        h.goldens.withLock { $0 = [.aborted] }
        let c = h.controller()
        await c.run(h.stages())
        XCTAssertEqual(c.state, .ready)
        XCTAssertEqual(h.count("golden"), 2, "run again once idle")
        XCTAssertGreaterThanOrEqual(h.count("waitIdle"), 1)
        XCTAssertEqual(c.record?.failures, 0)
        // a session running when the golden test is due: it waits for the end
        h = Harness()
        h.session.withLock { $0 = true }
        let d = h.controller(revision: "r-s")
        await d.run(h.stages())
        XCTAssertEqual(h.calls.withLock { $0 }.filter { $0 == "golden" || $0 == "waitIdle" }, ["waitIdle", "golden"])
    }

    // MARK: later launches, failover, deny-list

    /// A key promoted in an earlier launch: loaded and warmed again, no golden test; sessions before that stay on the CPU.
    func testAPromotedKeyIsReloadedAtTheNextLaunchWithoutAGoldenTest() async {
        let c = h.controller()
        await c.run(h.stages())
        h.resetCalls()
        let next = h.controller(launch: "L2")
        XCTAssertEqual(next.state, .cpu)
        XCTAssertNil(next.leaseForSession(), "a session before the build is warm runs on the CPU, without waiting")
        await next.run(h.stages())
        XCTAssertEqual(h.calls.withLock { $0 }, ["compile", "warmup"])
        XCTAssertEqual(next.state, .ready)
        XCTAssertNotNil(next.leaseForSession())
    }

    /// An exception in a session keeps 2.0.1's rule: demoted, golden-tested again no sooner than a day later.
    func testAnExceptionInASessionDemotesTheBuildForAtLeastADay() async {
        let c = h.controller()
        await c.run(h.stages())
        XCTAssertNotNil(c.leaseForSession())
        let f = TakeRunner.Failover(cause: .exception, detail: "the accelerator threw: prediction failed", chunk: 7, replayFrom: 0, stallMs: 84,
                                    cold: true, elapsedMs: nil, deadlineMs: 300, errorDomain: "com.apple.CoreML", errorCode: "-1")
        c.failedOver(f)
        c.endLease()
        guard case .disabled(let why) = c.state else { return XCTFail("\(c.state)") }
        XCTAssertTrue(why.contains("failover"), why)
        XCTAssertNil(c.leaseForSession(), "later sessions start on the CPU")
        let r = c.record!
        XCTAssertEqual(r.status, .retry)
        XCTAssertEqual(r.lastReason, .failover)
        XCTAssertGreaterThanOrEqual(r.notBefore!.timeIntervalSince(h.now.withLock { $0 }), 24 * 3600)
        let inc = h.incidents.withLock { $0 }.last
        XCTAssertEqual(inc?.kind, .failover)
        XCTAssertEqual(inc?.code, "session:exception")
        XCTAssertEqual(inc?.chunk, 7)
        XCTAssertEqual(inc?.stallMs, 84)
        // the next launch within the day: CPU; after it: retested from the download stage
        h.resetCalls()
        await h.controller(launch: "L2").run(h.stages())
        XCTAssertEqual(h.calls.withLock { $0 }, [])
        h.advance(24 * 3600 + 1)
        let later = h.controller(launch: "L3")
        await later.run(h.stages())
        XCTAssertEqual(h.calls.withLock { $0 }, ["download", "compile", "warmup", "golden"])
        XCTAssertEqual(later.state, .ready)
    }

    // MARK: 2.0.2: demotion by cause

    func miss(_ chunk: Int = 0) -> TakeRunner.Failover {
        TakeRunner.Failover(cause: .deadline, detail: "the first chunk took 1180.0 ms (first-chunk limit 1000 ms)", chunk: chunk, replayFrom: 0,
                            stallMs: 30, cold: true, elapsedMs: 1180, deadlineMs: 1000, errorDomain: nil, errorCode: nil)
    }

    /// Deadline misses in 3 different sessions within 24 h: a transient demotion (6 h, the build stays promoted and
    /// verified, used again without a golden test), never off for good however often it happens.
    func testMissesInThreeSessionsWithinADayDemoteForSixHoursNeverForGood() async {
        var launch = 1
        var c = h.controller(launch: "L1")
        await c.run(h.stages())
        for round in 0..<4 {
            for s in 0..<3 {
                XCTAssertNotNil(c.leaseForSession(), "round \(round) session \(s)")
                c.failedOver(miss(), session: "r\(round)s\(s)")
                c.endLease()
                if s < 2 {
                    XCTAssertEqual(c.state, .ready, "round \(round): \(s + 1) sessions with a miss do not demote")
                    h.advance(3600)
                }
            }
            guard case .disabled(let why) = c.state else { return XCTFail("round \(round): \(c.state)") }
            XCTAssertTrue(why.contains("used again after"), why)
            let r = c.record!
            XCTAssertEqual(r.status, .ready, "still verified")
            XCTAssertEqual(r.backoffUntil, h.now.withLock { $0 }.addingTimeInterval(6 * 3600))
            XCTAssertNil(r.missSessions)
            XCTAssertEqual(r.lastCause, .deadline)
            XCTAssertNil(c.leaseForSession())
            // within the backoff a new launch stays on the CPU; after it the build is loaded again, no golden test
            launch += 1
            h.resetCalls()
            let during = h.controller(launch: "L\(launch)")
            await during.run(h.stages())
            XCTAssertEqual(h.calls.withLock { $0 }, [])
            h.advance(6 * 3600 + 1)
            launch += 1
            c = h.controller(launch: "L\(launch)")
            await c.run(h.stages())
            XCTAssertEqual(h.calls.withLock { $0 }, ["compile", "warmup"], "round \(round)")
            XCTAssertEqual(c.state, .ready)
        }
        XCTAssertNotEqual(c.record?.status, .failed, "deadline misses never turn the build off for good")
        XCTAssertEqual(h.promotions.filter { if case .demoted = $0.kind { return true }; return false }.count, 4)
        XCTAssertEqual(h.promotions.filter { if case .failover(.deadline, _) = $0.kind { return true }; return false }.count, 12)
    }

    /// Misses in 2 sessions, or in 3 sessions spread over more than 24 h, or twice in one session: no demotion.
    func testMissesInTwoSessionsOrOverMoreThanADayDoNotDemote() async {
        let c = h.controller()
        await c.run(h.stages())
        for s in ["a", "b", "b"] {
            XCTAssertNotNil(c.leaseForSession())
            c.failedOver(miss(), session: s)
            c.endLease()
        }
        XCTAssertEqual(c.state, .ready, "two sessions")
        XCTAssertEqual(c.record?.missSessions?.count, 2)
        h.advance(24 * 3600 + 60)
        XCTAssertNotNil(c.leaseForSession())
        c.failedOver(miss(), session: "c")
        c.endLease()
        XCTAssertEqual(c.state, .ready, "the first two are more than 24 h old")
        XCTAssertEqual(c.record?.missSessions?.map(\.session), ["c"])
        XCTAssertNil(c.record?.backoffUntil)
        XCTAssertNotNil(c.leaseForSession())
    }

    /// NaN or a head out of range in a session: off for good for the key at once.
    func testANumericFaultInASessionTurnsTheBuildOffForGood() async {
        for (i, cause) in [FailoverCause.nonFinite, .outOfRange].enumerated() {
            h = Harness()
            let c = h.controller(revision: "n\(i)")
            await c.run(h.stages())
            XCTAssertNotNil(c.leaseForSession())
            c.failedOver(TakeRunner.Failover(cause: cause, detail: "log_probs is NaN or infinite", chunk: 3, replayFrom: 0, stallMs: 20, cold: true,
                                             elapsedMs: 4, deadlineMs: 50, errorDomain: nil, errorCode: nil), session: "s")
            c.endLease()
            XCTAssertEqual(c.record?.status, .failed, "\(cause)")
            XCTAssertEqual(c.record?.lastReason, .nonFinite)
            h.advance(30 * 86_400)
            h.resetCalls()
            await h.controller(revision: "n\(i)", launch: "L2").run(h.stages())
            XCTAssertEqual(h.calls.withLock { $0 }, [], "never again for the key")
        }
    }

    /// The first launch of 2.0.2 over 2.0.1's records: a build demoted for blank and one off for good after 4 deadline
    /// failovers are cleared and go back to the golden stage (loaded, warmed, golden-tested again, promoted); one off
    /// for good for NaN and one demoted for an exception stay. The migration runs once.
    func testTheUpgradeFrom201ClearsBlankAndDeadlineDemotionsOnce() async throws {
        let now = h.now.withLock { $0 }
        func key(_ rev: String) -> String {
            AcceleratorController.key(revision: rev, context: "c16_l64", build: "coreml", osBuild: "23A100", deviceModel: "iPhone17,1")
        }
        func old(_ rev: String, _ status: PromotionRecord.Status, _ reason: PromotionReason, _ detail: String, failures: Int,
                 stage: PromotionStage? = nil) -> PromotionRecord {
            var r = PromotionRecord(key: key(rev))
            r.status = status
            r.attempts = failures + 1
            r.failures = failures
            r.lastReason = reason
            r.lastStage = stage
            r.lastDetail = detail
            r.notBefore = status == .retry ? now.addingTimeInterval(24 * 3600) : nil
            r.compileMs = 9000
            r.acceleratorMedianMs = 3.7
            r.acceleratorP90Ms = 4.4
            r.cpuMedianMs = 34
            r.programSHA256 = String(repeating: "a", count: 64)
            return r
        }
        // as 2.0.1 wrote them (2.0.1 had no lastCause: the cause is in the detail text)
        let store = PromotionStore(dir: h.storage)
        store.save(old("u-blank", .retry, .failover, "failover: 3 chunks in a row heard nothing in audio with energy", failures: 1))
        store.save(old("u-deadline", .failed, .failover, "failover: no answer within 55 ms", failures: 4))
        store.save(old("u-chunk", .retry, .failover, "failover: a chunk took 61.2 ms (deadline 50 ms)", failures: 2))
        store.save(old("u-nan", .failed, .nonFinite, "golden: Husary_001001: log_probs is NaN or infinite", failures: 1, stage: .golden))
        store.save(old("u-throw", .retry, .failover, "failover: the accelerator threw: prediction failed", failures: 1))
        for rev in ["u-blank", "u-deadline", "u-chunk"] {
            h.resetCalls()
            let c = h.controller(revision: rev, launch: "L2")
            XCTAssertEqual(c.state, .cpu, rev)
            let r = try XCTUnwrap(c.record)
            XCTAssertEqual(r.status, .pending, rev)
            XCTAssertEqual(r.completed, .warmup, "\(rev): back to the golden stage")
            XCTAssertEqual(r.failures, 0)
            XCTAssertNil(r.notBefore)
            XCTAssertNil(r.lastReason)
            XCTAssertEqual(r.acceleratorMedianMs, 3.7, "the measurements stay")
            await c.run(h.stages())
            XCTAssertEqual(h.calls.withLock { $0 }, ["compile", "warmup", "golden"], "\(rev): loaded, warmed, golden-tested again")
            XCTAssertEqual(c.state, .ready, rev)
            XCTAssertEqual(c.record?.status, .ready)
        }
        h.resetCalls()
        let nan = h.controller(revision: "u-nan", launch: "L2")
        XCTAssertEqual(nan.record?.status, .failed, "NaN stays off")
        guard case .disabled = nan.state else { return XCTFail("\(nan.state)") }
        await nan.run(h.stages())
        XCTAssertEqual(h.calls.withLock { $0 }, [])
        let thrown = h.controller(revision: "u-throw", launch: "L2")
        XCTAssertEqual(thrown.record?.status, .retry, "other causes stay")
        XCTAssertEqual(thrown.record?.lastReason, .failover)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.migratedURL.path))
        // once: a record of that shape written later (never by 2.0.2 itself) is left alone
        store.save(old("u-later", .retry, .failover, "failover: 3 chunks in a row heard nothing in audio with energy", failures: 1))
        XCTAssertEqual(store.migrate(now: now), [])
        XCTAssertEqual(h.controller(revision: "u-later", launch: "L3").record?.status, .retry)
    }

    /// `blank_confirmed_ok`: counted per session from the take, sent in the `promotions` entry, no failover or
    /// demotion; days saved by 2.0.1 (no such field) still decode.
    func testBlankConfirmedOKIsCountedWithoutAFailover() throws {
        let c = h.controller()
        c.sessionEnded(warmMs: [], blankConfirmedOK: 2)
        let store = AnalyticsStore(storage: Fixtures.storage(), enabled: true,
                                   context: .init(platform: "ios", sdkVersion: SDKInfo.version, appVersion: "1", deviceClass: "phone", soc: nil,
                                                  osMajor: 26, ramTier: "8gb"))
        for p in h.promotions { store.record(.promotion(p)) }
        let e = try XCTUnwrap(AnalyticsStore.promotions(try XCTUnwrap(store.pending.first).promotions).first)
        XCTAssertEqual(e["blank_confirmed_ok"] as? Int, 2)
        XCTAssertNil(e["failovers"])
        XCTAssertNil(e["demoted"])
        XCTAssertTrue(h.incidents.withLock { $0 }.isEmpty, "no incident report")
        var o = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AnalyticsStore.Promotion(backend: "ane", revision: "r", context: "c16_l64"))) as? [String: Any])
        o["blankConfirmedOK"] = nil
        let old = try JSONDecoder().decode(AnalyticsStore.Promotion.self, from: JSONSerialization.data(withJSONObject: o))
        XCTAssertNil(old.blankConfirmedOK)
    }

    /// A session's warm chunk times join the key's (the limits of later sessions), cold ones never do.
    func testSessionWarmTimesJoinTheKeysLimits() async {
        let c = h.controller()
        await c.run(h.stages())
        XCTAssertEqual(c.record?.warmChunkMs?.count, 3, "the golden test's warm chunks")
        c.sessionEnded(warmMs: Array(repeating: 20, count: 70), blankConfirmedOK: 0)
        XCTAssertEqual(c.record?.warmChunkMs?.count, PromotionPolicy.warmSamplesKept)
        XCTAssertEqual(c.limits.laterMs, 80, "4 x 20 ms")
        XCTAssertEqual(c.limits.firstMs, 1000)
    }

    func testTheDenyListKeepsTheCPUAndIsCountedOnce() async {
        h.denied.withLock { $0 = "deny-listed: fp16 trouble" }
        let c = h.controller()
        XCTAssertEqual(c.state, .disabled("deny-listed: fp16 trouble"))
        await c.run(h.stages())
        await c.run(h.stages())
        XCTAssertEqual(h.calls.withLock { $0 }, [])
        XCTAssertEqual(h.promotions.count, 1)
        guard case .demoted(.denylist)? = h.promotions.first?.kind else { return XCTFail("\(h.promotions)") }
        // a promoted build that becomes deny-listed is not leased
        h = Harness()
        let p = h.controller()
        await p.run(h.stages())
        h.denied.withLock { $0 = "deny-listed" }
        XCTAssertNil(p.leaseForSession())
    }

    // MARK: telemetry

    /// The `promotions` entries: a promoted attempt, a failure at each stage, a failover; zero counts and empty objects
    /// left out; at most 8 entries.
    func testThePromotionsTelemetry() throws {
        let store = AnalyticsStore(storage: Fixtures.storage(), enabled: true,
                                   context: .init(platform: "ios", sdkVersion: "2.0.1", appVersion: "1", deviceClass: "phone", soc: "a17pro",
                                                  osMajor: 18, ramTier: "8gb"))
        func rec(_ k: PromotionTelemetry.Kind, _ rev: String = "v4.0+abc") {
            store.record(.promotion(PromotionTelemetry(backend: "ane", revision: rev, context: "c16_l64", kind: k)))
        }
        rec(.attempt(promoted: true, stage: nil, reason: nil, compileMs: 12_000, speedup: 3.4))
        rec(.attempt(promoted: false, stage: .download, reason: .network, compileMs: nil, speedup: nil))
        rec(.attempt(promoted: false, stage: .compile, reason: .compileTimeout, compileMs: nil, speedup: nil))
        rec(.attempt(promoted: false, stage: .warmup, reason: .nonFinite, compileMs: 800, speedup: nil))
        rec(.attempt(promoted: false, stage: .golden, reason: .goldenMismatch, compileMs: 70_000, speedup: nil))
        rec(.failover(cause: .deadline, stallMs: 140))
        rec(.demoted(.failover))
        let day = try XCTUnwrap(store.pending.first)
        let body = store.payload(day, reportID: String(repeating: "a", count: 32))
        let list = try XCTUnwrap(body["promotions"] as? [[String: Any]])
        XCTAssertEqual(list.count, 1)
        let e = list[0]
        XCTAssertEqual(e["backend"] as? String, "ane")
        XCTAssertEqual(e["revision"] as? String, "v4.0+abc")
        XCTAssertEqual(e["context"] as? String, "c16_l64")
        XCTAssertEqual(e["attempts"] as? Int, 5)
        XCTAssertEqual(e["promoted"] as? Int, 1)
        XCTAssertEqual(e["failed_at"] as? [String: Int], ["download": 1, "compile": 1, "warmup": 1, "golden": 1])
        XCTAssertEqual(e["reasons"] as? [String: Int], ["network": 1, "compile_timeout": 1, "non_finite": 1, "golden_mismatch": 1, "failover": 1])
        XCTAssertEqual(e["compile_ms"] as? [String: Int], ["le_1000": 1, "le_15000": 1, "le_120000": 1])
        XCTAssertEqual(e["speedup"] as? [String: Int], ["le_5": 1])
        XCTAssertEqual(e["failovers"] as? Int, 1)
        XCTAssertEqual(e["demoted"] as? Int, 1, "the failover took a promoted build back")
        XCTAssertEqual(e["failover_causes"] as? [String: Int], ["deadline": 1])
        XCTAssertEqual(e["failover_stall_ms"] as? [String: Int], ["le_200": 1])
        // nothing counted: no promotions key at all
        let quiet = AnalyticsStore(storage: Fixtures.storage(), enabled: true,
                                   context: .init(platform: "ios", sdkVersion: "2.0.1", appVersion: "1", deviceClass: "phone", soc: nil,
                                                  osMajor: 18, ramTier: "8gb"))
        quiet.count(.launch)
        XCTAssertNil(quiet.payload(try XCTUnwrap(quiet.pending.first), reportID: String(repeating: "b", count: 32))["promotions"])
        // at most 8 entries
        for i in 0..<12 { rec(.attempt(promoted: true, stage: nil, reason: nil, compileMs: nil, speedup: nil), "rev\(i)") }
        XCTAssertEqual(AnalyticsStore.promotions(try XCTUnwrap(store.pending.first).promotions).count, 8)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
    }
}
