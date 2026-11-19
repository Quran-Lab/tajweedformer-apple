import Foundation
import XCTest
@testable import TajweedFormer
#if canImport(Darwin)
import Darwin
#endif

/// The 2.0.2 rules in the take runner, with fakes: a blank is a suspicion verified on the CPU engine off the audio
/// path (a held vowel or madd the CPU also hears as blank stays on the accelerator; a stretch the CPU hears switches,
/// from the first suspicious chunk, nothing lost); cold chunks have their own limit; the later limit comes from warm
/// chunks only; the warm-up runs off the audio path.
final class FailoverRulesTests: XCTestCase {
    func runner(held: Range<Int>? = nil) -> TakeRunner {
        let r = TakeRunner(chunkMs: 320, openCPU: { () throws(RecognizerError) -> any CPUStreamEngine in FakeCPUEngine(held: held) })
        r.policy.cpuChunkMs = 1
        r.policy.cpuOpenMs = 1
        return r
    }

    /// A long madd or held vowel (chunks 6 to 13 blank over sound in both engines): one verification, the CPU agrees,
    /// no failover, the CPU engine closed again, the take is the accelerator's.
    func testABlankTheCPUAlsoHearsAsBlankStaysOnTheAccelerator() throws {
        let held = 6..<14
        let audio = fakeRecitation(seconds: 8)
        let cpuOnly = try runTake(runner(held: held), audio, accelerator: nil)
        XCTAssertFalse(cpuOnly.heads.greedy.isEmpty)
        let r = runner(held: held)
        let acc = AcceleratorExecutor(FakeAccelerator(held: held))
        let opened = FakeCPUEngine.opened.withLock { $0 }
        let alive = FakeCPUEngine.alive.withLock { $0 }
        let got = try runTake(r, audio, accelerator: acc)
        XCTAssertNil(r.failover, "a blank the CPU engine confirms is no failover")
        XCTAssertTrue(r.onAccelerator)
        XCTAssertEqual(r.verifications, 1, "once per 10 s of audio")
        XCTAssertEqual(r.blankConfirmedOK, 1)
        XCTAssertEqual(r.lastVerification?.agreed, true)
        XCTAssertNil(r.cpu, "the CPU engine is closed again")
        XCTAssertNil(r.verification)
        XCTAssertEqual(FakeCPUEngine.opened.withLock { $0 }, opened + 1, "one CPU engine, for the verification")
        XCTAssertEqual(FakeCPUEngine.alive.withLock { $0 }, alive, "and none left open")
        XCTAssertEqual(got.heads.greedy, cpuOnly.heads.greedy)
        XCTAssertTrue(got.redeliveredFrom.isEmpty)
        let v = try XCTUnwrap(r.lastVerification)
        print(String(format: "v4-blank fake: verification open %.2f ms, replay %.2f ms (%d chunks), ring copy on the audio path %.2f ms (fake engine; not a device number)",
                     v.openMs, v.replayMs, v.chunks, r.lastSuspicionMs ?? -1))
    }

    /// A stretch the accelerator hears nothing in but the CPU engine does: the disagreement is confirmed, the take goes
    /// on on the CPU from the first suspicious chunk (handed out again from there), every chunk there, exactly the
    /// CPU-only take (a short take is replayed whole). The first confirmed disagreement for the key is a transient
    /// demotion; a second one turns the build off for good.
    func testABlankTheCPUHearsSwitchesFromTheFirstSuspiciousChunk() async throws {
        let audio = fakeRecitation(seconds: 8)
        let ref = try runTake(runner(), audio, accelerator: nil)
        let r = runner()
        let got = try runTake(r, audio, accelerator: AcceleratorExecutor(FakeAccelerator(failAt: 6, failure: .blankSpan(8))))
        let f = try XCTUnwrap(r.failover)
        XCTAssertEqual(f.cause, .blank)
        XCTAssertEqual(f.chunk, 6, "from the first suspicious chunk")
        XCTAssertTrue(f.exact)
        XCTAssertEqual(got.redeliveredFrom, [6])
        XCTAssertEqual(got.frames.count, ref.frames.count, "nothing lost")
        XCTAssertEqual(got.heads.greedy, ref.heads.greedy)
        XCTAssertEqual(got.heads.logProbs, ref.heads.logProbs)
        let d = try XCTUnwrap(f.divergence)
        XCTAssertGreaterThan(d.tokensExpected ?? 0, 0)
        XCTAssertEqual(d.tokenEdits, d.tokensExpected, "the accelerator heard none of them")
        XCTAssertFalse(r.onAccelerator)

        // the build: the first confirmed disagreement is transient, the second turns it off for good
        let h = PromotionTests.Harness()
        let c = h.controller()
        await c.run(h.stages())
        XCTAssertNotNil(c.leaseForSession())
        c.failedOver(f, session: "s1")
        c.endLease()
        let inc = try XCTUnwrap(h.incidents.withLock { $0 }.last)
        XCTAssertEqual(inc.code, "session:blank")
        XCTAssertEqual(inc.divergence, d)
        IncidentTests.validate(try IncidentTests.json(QuranLabCloud.incidentReport(inc, app: IncidentTests.app, chip: "a18pro",
                                                                                   deviceModel: "iPhone18,1", osBuild: "23C71")))
        var rec = try XCTUnwrap(c.record)
        XCTAssertEqual(rec.status, .ready, "still verified")
        XCTAssertEqual(rec.disagreements, 1)
        XCTAssertEqual(rec.backoffUntil, h.now.withLock { $0 }.addingTimeInterval(6 * 3600))
        XCTAssertNil(c.leaseForSession())
        h.advance(6 * 3600 + 1)
        h.resetCalls()
        let next = h.controller(launch: "L2")
        await next.run(h.stages())
        XCTAssertEqual(h.calls.withLock { $0 }, ["compile", "warmup"], "used again after the backoff, no golden test")
        XCTAssertNotNil(next.leaseForSession())
        next.failedOver(f, session: "s2")
        next.endLease()
        rec = try XCTUnwrap(next.record)
        XCTAssertEqual(rec.status, .failed, "a repeated confirmed disagreement: off for good for the key")
        guard case .disabled = next.state else { return XCTFail("\(next.state)") }
        h.advance(30 * 86_400)
        h.resetCalls()
        await h.controller(launch: "L3").run(h.stages())
        XCTAssertEqual(h.calls.withLock { $0 }, [])
        print(String(format: "v4-blank fake confirmed: switch at chunk %d, catch-up %.2f ms, %d tokens the accelerator missed",
                     f.chunk, f.stallMs, d.tokensExpected ?? 0))
    }

    /// The first chunk after the Neural Engine sat idle, at 3 times the warm limit (150 ms against 50 ms) and within
    /// the first-chunk limit (1000 ms): served by the accelerator, no miss, and not a warm measurement.
    func testAColdFirstChunkWithinTheFirstChunkLimitIsNoMiss() throws {
        let r = runner()
        r.policy.deadlineMs = 50
        r.policy.warmMs = Array(repeating: 4, count: 16)
        XCTAssertEqual(r.laterLimitMs, 50)
        XCTAssertEqual(r.policy.firstChunkMs, 1000)
        let fa = FakeAccelerator()
        fa.costs = [0: 0.150]
        _ = try runTake(r, fakeRecitation(seconds: 3), accelerator: AcceleratorExecutor(fa))
        XCTAssertNil(r.failover, "\(String(describing: r.failover))")
        XCTAssertTrue(r.onAccelerator)
        XCTAssertGreaterThanOrEqual(r.chunkSeconds.first ?? 0, 0.150)
        XCTAssertEqual(r.takeWarmMs.count, r.chunks - 1, "the first chunk is not a warm chunk")
        XCTAssertLessThan(r.takeWarmMs.max() ?? 99, 50)
        XCTAssertEqual(r.laterLimitMs, 50, "the slow first chunk did not raise the later limit")
    }

    /// A first chunk past even the first-chunk limit: that chunk and the rest of the take on the CPU (the take exactly
    /// the CPU-only one); a single miss does not demote the build, and the accelerator is not abandoned (it answered).
    func testAFirstChunkPastTheFirstChunkLimitGoesToTheCPUWithoutDemotion() async throws {
        let audio = fakeRecitation(seconds: 3)
        let ref = try runTake(runner(), audio, accelerator: nil)
        let r = runner()
        r.policy.firstChunkMs = 200
        let fa = FakeAccelerator()
        fa.costs = [0: 0.350]
        let acc = AcceleratorExecutor(fa)
        let got = try runTake(r, audio, accelerator: acc)
        let f = try XCTUnwrap(r.failover)
        XCTAssertEqual(f.cause, .deadline)
        XCTAssertEqual(f.chunk, 0)
        XCTAssertEqual(f.deadlineMs, 200, "the first-chunk limit")
        XCTAssertEqual(got.heads.greedy, ref.heads.greedy)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(acc.abandoned, "a late answer within the grace is a miss, not a hang")
        let h = PromotionTests.Harness()
        let c = h.controller()
        await c.run(h.stages())
        XCTAssertNotNil(c.leaseForSession())
        c.failedOver(f, session: "s1")
        c.endLease()
        XCTAssertEqual(c.state, .ready, "one miss does not demote")
        XCTAssertEqual(c.record?.status, .ready)
        XCTAssertNil(c.record?.backoffUntil)
        XCTAssertEqual(c.record?.missSessions?.count, 1)
        XCTAssertNotNil(c.leaseForSession(), "the next session uses the build")
        c.endLease()
        XCTAssertEqual(h.incidents.withLock { $0 }.last?.code, "session:timeout")
        let store = AnalyticsStore(storage: Fixtures.storage(), enabled: true,
                                   context: .init(platform: "ios", sdkVersion: SDKInfo.version, appVersion: "1", deviceClass: "phone", soc: nil,
                                                  osMajor: 26, ramTier: "8gb"))
        for p in h.promotions { store.record(.promotion(p)) }
        let e = try XCTUnwrap(AnalyticsStore.promotions(try XCTUnwrap(store.pending.first).promotions).first)
        XCTAssertEqual(e["failovers"] as? Int, 1, "still a switch to the CPU for that session")
        XCTAssertEqual(e["failover_causes"] as? [String: Int], ["deadline": 1])
        XCTAssertNil(e["demoted"], "no demotion")
    }

    /// The later limit is computed from warm chunks only: neither the first chunk of the take (400 ms) nor the first
    /// chunk after the app became active (300 ms) is a warm chunk, and neither is a miss (each had the cold limit).
    func testTheLimitsComeFromWarmChunksOnly() throws {
        let r = runner()
        let fa = FakeAccelerator()
        fa.costs = [0: 0.4, 12: 0.3]
        let acc = AcceleratorExecutor(fa)
        try r.start(accelerator: acc)
        let audio = fakeRecitation(seconds: 6)
        var at = 0, marked = false
        while at < audio.count {
            if r.chunks == 12 && !marked {
                acc.markCold()
                marked = true
            }
            _ = try r.push(Array(audio[at..<min(audio.count, at + 5120)]))
            at += 5120
        }
        _ = try r.finish()
        XCTAssertTrue(marked)
        XCTAssertNil(r.failover, "\(String(describing: r.failover))")
        XCTAssertEqual(r.takeWarmMs.count, r.chunks - 2, "neither cold chunk is a warm measurement")
        XCTAssertLessThan(r.takeWarmMs.max() ?? 99, 50)
        XCTAssertEqual(r.laterLimitMs, 50)
        // the policy's numbers
        XCTAssertEqual(PromotionPolicy.limits(warmMs: [], p90Ms: nil, medianMs: nil).firstMs, 1000)
        XCTAssertEqual(PromotionPolicy.limits(warmMs: [], p90Ms: nil, medianMs: nil).laterMs, 300, "before any warm measurement")
        XCTAssertEqual(PromotionPolicy.limits(warmMs: Array(repeating: 3.7, count: 20), p90Ms: nil, medianMs: nil).laterMs, 50)
        XCTAssertEqual(PromotionPolicy.limits(warmMs: Array(repeating: 120, count: 20), p90Ms: nil, medianMs: nil).firstMs, 1200)
        XCTAssertEqual(PromotionPolicy.limits(warmMs: Array(repeating: 120, count: 20), p90Ms: nil, medianMs: nil).laterMs, 300)
        XCTAssertEqual(PromotionPolicy.limits(warmMs: [3], p90Ms: 60, medianMs: 30).laterMs, 240, "too few warm times: the measure stage's")
    }

    /// The warm-up: at take start it is queued on the accelerator's queue and the start does not wait for it; the first
    /// chunk, which needs a full chunk of audio, comes after it without a delay; when the app becomes active with no
    /// session on the build, the controller warms it up, and the next chunk is a cold one.
    func testTheWarmUpRunsAtTakeStartOffTheAudioPath() throws {
        let fa = FakeAccelerator()
        fa.warmUpCost = 0.2
        let acc = AcceleratorExecutor(fa)
        let r = runner()
        let t0 = CFAbsoluteTimeGetCurrent()
        try r.start(accelerator: acc)
        let startMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        XCTAssertLessThan(startMs, 50, "the take starts without waiting for the warm-up")
        // audio in real time: the first chunk needs 450 ms of it
        let audio = fakeRecitation(seconds: 1)
        Thread.sleep(forTimeInterval: 0.32)
        var t = CFAbsoluteTimeGetCurrent()
        let o1 = try r.push(Array(audio[0..<5120]))
        let push1 = (CFAbsoluteTimeGetCurrent() - t) * 1000
        XCTAssertTrue(o1.chunks.isEmpty)
        Thread.sleep(forTimeInterval: 0.32)
        t = CFAbsoluteTimeGetCurrent()
        let o2 = try r.push(Array(audio[5120..<10240]))
        let firstChunk = (CFAbsoluteTimeGetCurrent() - t) * 1000
        XCTAssertEqual(o2.chunks.count, 1)
        XCTAssertNil(r.failover)
        XCTAssertEqual(acc.warmUps, 1)
        XCTAssertEqual(fa.warmUpsRun.withLock { $0 }, 1)
        XCTAssertGreaterThanOrEqual(acc.lastWarmUpMs ?? 0, 200)
        XCTAssertLessThan(firstChunk, 100, "the warm-up was done before the first chunk's audio was")
        print(String(format: "v4-warmup fake: take start %.2f ms with a 200 ms warm-up queued, first push %.1f ms, first chunk %.1f ms (fake engine)",
                     startMs, push1, firstChunk))
    }

    /// Activation: the controller's build is warmed up when no session holds it, and the next chunk is a cold one; a
    /// session on the build is not interrupted (a warm-up would reset its stream), its next chunk is a cold one.
    func testTheWarmUpRunsWhenTheAppBecomesActive() async throws {
        let h = PromotionTests.Harness()
        let c = h.controller()
        await c.run(h.stages())
        let e = try XCTUnwrap(c.leaseForSession())
        c.endLease()
        let before = e.warmUps
        NotificationCenter.default.post(name: AcceleratorController.activeNotification, object: nil)
        for _ in 0..<100 where e.warmUps == before { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(e.warmUps, before + 1, "warmed up on activation")
        XCTAssertTrue(e.takeCold(), "the next chunk has the first-chunk limit")
        // a session on the build: no warm-up (it would reset the stream), only the cold limit
        _ = try XCTUnwrap(c.leaseForSession())
        NotificationCenter.default.post(name: AcceleratorController.activeNotification, object: nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(e.warmUps, before + 1)
        XCTAssertTrue(e.takeCold())
        c.endLease()
    }
}

/// A blank verification through the real exact engine (TAJWEED_V4_FOLDER with `selftest/`): the CPU engine opened on
/// a background queue and 30 s of audio (the self-test clips, repeated) replayed, as the ring is at its fullest. Measured
/// here: the open, the replay, the copy on the audio path, and the resident memory the verification adds at its peak.
final class BlankVerificationRealTests: XCTestCase {
    func testABlankVerificationOnTheRealEngine() throws {
        guard let p = ProcessInfo.processInfo.environment["TAJWEED_V4_FOLDER"] else {
            print("v4-blank real: skipped (no TAJWEED_V4_FOLDER: the model is not on this runner)")
            throw XCTSkip("set TAJWEED_V4_FOLDER")
        }
        let dir = URL(fileURLWithPath: p)
        guard let set = SelfTestSet.load(dir, context: "c16_l64") else {
            print("v4-blank real: skipped (the folder has no selftest/ set)")
            throw XCTSkip("no self-test set in TAJWEED_V4_FOLDER")
        }
        var audio: [Float] = []
        while audio.count < 30 * 16_000 { for c in set.clips { audio += c.samples } }
        audio = Array(audio.prefix(30 * 16_000))
        let open = { () throws(RecognizerError) -> any CPUStreamEngine in
            let e = try TajweedExactEngine(directory: dir, context: "c16_l64")
            e.setHeads(HeadSelection.default.engineMask)
            return e
        }
        var lines: [String] = []
        for run in 0..<3 {
            let before = residentMB()
            let peak = Locked(before)
            let sampling = Locked(true)
            let sampler = Thread {
                while sampling.withLock({ $0 }) {
                    let f = residentMB()
                    peak.withLock { $0 = max($0, f) }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            sampler.start()
            let t0 = CFAbsoluteTimeGetCurrent()
            let v = BlankVerification(first: 90, count: 3, from: 0, end: audio.count, accTokens: [], audio: audio, piece: 5120, openCPU: open)
            let startMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            XCTAssertTrue(v.wait(120))
            sampling.withLock { $0 = false }
            let r = v.take()
            XCTAssertNil(r.error)
            XCTAssertNotNil(r.engine)
            XCTAssertGreaterThan(r.chunks.count, 80)
            let after = residentMB()
            lines.append(String(format: "v4-blank real verification %d: 30 s replayed, start on the audio path %.2f ms, CPU open %.1f ms, replay %.1f ms (%d chunks, %.1f ms a chunk), footprint %.1f MB, peak +%.1f MB, after +%.1f MB (macOS runner)",
                                run, startMs, r.openMs, r.replayMs, r.chunks.count, r.replayMs / Double(max(1, r.chunks.count)),
                                before, peak.withLock { $0 } - before, after - before))
        }
        for l in lines { print(l) }
    }
}

/// Resident memory that counts against an app (phys_footprint), MB; -1 where it cannot be read.
func residentMB() -> Double {
    #if canImport(Darwin)
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { (p: UnsafeMutablePointer<rusage_info_v4>) -> Int32 in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return rc == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : -1
    #else
    return -1
    #endif
}
