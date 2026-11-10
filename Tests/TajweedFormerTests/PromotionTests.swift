import Foundation
import XCTest
@testable import TajweedFormer

/// The promotion pipeline's state machine with fakes for the network, the files, the compiler, the engines and the
/// clock: no model, no CoreML, no Neural Engine. Every stage succeeding; every failure at every stage with its reason;
/// a restart in the middle of each stage (a new controller on the same record, the crash sentinel); OS build and
/// revision changes; backoff and its cap; deterministic failures never retried; conditions that wait without
/// counting; a session during the golden test; a slower build promoted; failover demotion; telemetry.
final class PromotionTests: XCTestCase {
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

        func env(revision: String = "r1", os: String = "23A100", device: String = "iPhone17,1", launch: String = "L1",
                 timeouts: AcceleratorController.Timeouts = .init()) -> AcceleratorController.Environment {
            let now = self.now, cond = self.conditions, ev = self.events, inc = self.incidents, den = self.denied
            var e = AcceleratorController.Environment(
                revision: revision, osBuild: os, deviceModel: device, context: "c16_l64", build: "coreml", storage: storage, launch: launch,
                clock: { now.withLock { $0 } }, sleep: { _ in await Task.yield() },
                conditions: { _ in cond.withLock { $0 } }, maxConditionWaits: 2,
                thermal: { .nominal }, denied: { den.withLock { $0 } },
                record: { e in ev.withLock { $0.append(e) } }, incident: { i in inc.withLock { $0.append(i) } },
                cohort: { AcceleratorTests.cohort })
            e.timeouts = timeouts
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

    /// Quran Lab (11-10): a build that passes the golden test is promoted whatever its speed.
    func testASlowerBuildIsPromoted() async {
        h.goldenTimes.withLock { $0 = ([0.030, 0.040, 0.035], [0.008, 0.009, 0.008]) }
        let c = h.controller()
        await c.run(h.stages())
        XCTAssertEqual(c.state, .ready)
        XCTAssertLessThan(c.record?.speedup ?? 9, 1)
        let store = AnalyticsStore(storage: h.storage, enabled: true, context: .init(platform: "ios", sdkVersion: "2.0.1", appVersion: "1",
                                                                                     deviceClass: "phone", soc: nil, osMajor: 18, ramTier: "6gb"))
        for p in h.promotions { store.record(.promotion(p)) }
        let entry = AnalyticsStore.promotions(store.pending.first!.promotions).first!
        XCTAssertEqual(entry["promoted"] as? Int, 1)
        XCTAssertEqual(entry["speedup"] as? [String: Int], ["lt_0_5": 1])
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
    /// crash at that stage (deterministic: never again for the key).
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
            XCTAssertNil(next.store.sentinel(), "read once")
            XCTAssertEqual(next.record?.lastReason, .crash)
            XCTAssertEqual(next.record?.lastStage, stage)
            XCTAssertEqual(next.record?.status, .failed)
            guard case .disabled = next.state else { XCTFail("\(next.state)"); continue }
            await next.run(h.stages())
            XCTAssertEqual(h.calls.withLock { $0 }, [], "never again for the key")
            XCTAssertEqual(h.incidents.withLock { $0 }.last?.code, "\(stage.rawValue):crash_on_last_run")
            // another OS build may try again
            let updated = h.controller(revision: "c\(i)", os: "23B9", launch: "L3")
            await updated.run(h.stages())
            XCTAssertEqual(updated.state, .ready)
        }
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
        h.failures.withLock { $0[.download] = PromotionFailure(.network, "offline") }
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
            PromotionConditions(unmetered: false),
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
        // low battery while charging is fine; a metered network only holds the download
        XCTAssertNil(PromotionConditions(battery: 0.1, charging: true).blocker(for: .compile))
        XCTAssertNil(PromotionConditions(unmetered: false).blocker(for: .golden))
        XCTAssertNotNil(PromotionConditions(unmetered: false).blocker(for: .download))
        XCTAssertNil(PromotionConditions(thermal: .fair).blocker(for: .golden))
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

    func testAFailoverDemotesTheBuildForAtLeastADay() async {
        let c = h.controller()
        await c.run(h.stages())
        XCTAssertNotNil(c.leaseForSession())
        let f = TakeRunner.Failover(cause: .deadline, detail: "no answer within 300 ms", chunk: 7, replayFrom: 0, stallMs: 84, cold: true,
                                    elapsedMs: 300, deadlineMs: 300, errorDomain: nil, errorCode: nil)
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
        XCTAssertEqual(inc?.code, "session:timeout")
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
