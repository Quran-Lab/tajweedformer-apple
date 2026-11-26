import Foundation
import XCTest
@testable import TajweedFormer

/// Live promotion (SDK 4.0.5, contract section 30, `sdk_4.0.0/LIVE_PROMOTION_41.md`), the parts that need the SDK: the
/// contexts as the recognizer reads them, the pipeline's conditions as the rule reads them, the window's judgement with
/// the golden test's rule, the config's flag through the signed config's decoder, the record each outcome writes (the
/// failover's rule for the same trouble), the `live` object of the promotions entry (counted, kept out of what is sent
/// until the server takes it), and diagnose's `backend.live`. Every rule case of the vectors and the 29 takes through
/// the decide are in LiveVectorTests; the take runner with the fake engines in LiveTakeTests.
final class LivePromotionTests: XCTestCase {
    override func tearDown() {
        LiveDiagnosis.reset()
        AnalyticsStore.livePromotionsSent.withLock { $0 = true }
    }

    // MARK: 30.1, 30.2

    func testTheContextsAsTheRecognizerReadsThem() throws {
        for ctx in ["c8_l64", "c16_l64", "c24_l72", "c24_l256"] {
            XCTAssertEqual(LiveRules.chunkMs(context: ctx), TajweedRecognizer.chunkMs(context: ctx), ctx)
        }
        // c8_l64 has no accelerator build: live promotion never applies there
        XCTAssertTrue(ModelContexts.isCPUOnly("c8_l64"))
        XCTAssertFalse(TajweedRecognizer.mayUseAccelerator(requested: .automatic, context: "c8_l64"))
        XCTAssertEqual(LiveRules.ceilDiv(LiveRules.swapCapMs, 320), 25, "8 s at c16")
        XCTAssertEqual(LiveRules.ceilDiv(LiveRules.stallWaitMs, 480), 42, "20 s at c24")
    }

    /// The pipeline's conditions as the start rule reads them: a battery level the device does not give (below 0, or
    /// none) never blocks, the thermal state by its name.
    func testTheConditionsAsTheRuleReadsThem() {
        var p = PromotionConditions()
        p.battery = -1
        XCTAssertNil(LivePromotion.device(p, finishing: false, sourceLeftSeconds: nil).battery)
        XCTAssertNil(LiveRules.start(LiveRules.Conditions(device: LivePromotion.device(p, finishing: false, sourceLeftSeconds: nil))))
        p.battery = 0.1
        XCTAssertEqual(LiveRules.start(LiveRules.Conditions(device: LivePromotion.device(p, finishing: false, sourceLeftSeconds: nil))), "battery")
        p.charging = true
        XCTAssertNil(LiveRules.start(LiveRules.Conditions(device: LivePromotion.device(p, finishing: false, sourceLeftSeconds: nil))))
        for (t, name) in [(ProcessInfo.ThermalState.nominal, "nominal"), (.fair, "fair"), (.serious, "serious"), (.critical, "critical")] {
            XCTAssertEqual(LivePromotion.thermal(t), name)
        }
        p.thermal = .serious
        XCTAssertEqual(LiveRules.pipelineBlocker(LivePromotion.device(p, finishing: true, sourceLeftSeconds: 3)), "thermal")
        let d = LivePromotion.device(PromotionConditions(), finishing: true, sourceLeftSeconds: 9)
        XCTAssertNil(LiveRules.pipelineBlocker(d), "only items 6 to 8 end an attempt that runs (and the app's finish, in the decide)")
        XCTAssertEqual(LiveRules.start(LiveRules.Conditions(device: d)), "near_source_end")
    }

    // MARK: 30.4

    /// The window check: the golden test's rule on the heads both engines returned; a head only one side has is left
    /// out (the CPU engine computes the selected and kept heads, the accelerator all of them).
    func testTheWindowComparesTheHeadsBothEnginesReturned() {
        func chunk(_ tokens: [Int], gem: Bool = false) -> HeadsBuffer {
            var lp = [Float](repeating: -20, count: tokens.count * 38)
            for (f, t) in tokens.enumerated() { lp[f * 38 + t] = 0 }
            var h: [String: [Float]] = ["log_probs": lp]
            if gem { h["gem"] = [Float](repeating: 0.5, count: tokens.count * 2 * 2) }
            return HeadsBuffer(chunk: h)
        }
        let cpu = chunk([0, 5, 5, 0, 7, 7, 0, 0])
        XCTAssertEqual(LivePromotion.judge(cpu: cpu, accelerator: chunk([0, 5, 5, 0, 7, 7, 0, 0], gem: true), tolerance: nil), .within,
                       "gem from the accelerator alone is not a shape failure")
        XCTAssertEqual(LivePromotion.judge(cpu: cpu, accelerator: chunk([0, 5, 5, 0, 9, 9, 0, 0]), tolerance: nil), .outside,
                       "no tolerance in the manifest: no token edit")
        XCTAssertEqual(LivePromotion.judge(cpu: cpu, accelerator: chunk([0, 5, 5, 0, 7, 7, 0]), tolerance: nil), .outside, "a shape that differs")
        XCTAssertEqual(LivePromotion.judge(cpu: HeadsBuffer(), accelerator: cpu, tolerance: nil), .outside, "log_probs is always compared")
    }

    // MARK: 30.6 and 30.8

    func testRecordAndConfig() throws {
        let records = try LiveVectorTests.cases("record", 6)
        for c in records {
            let o = try XCTUnwrap(LivePromotion.Outcome(rawValue: try XCTUnwrap(c["outcome"] as? String)))
            XCTAssertEqual(LivePromotion.recordRule(o)?.rawValue, c["record"] as? String, o.rawValue)
        }
        XCTAssertEqual(LivePromotion.Outcome.allCases.map(\.rawValue), LiveRules.outcomes)
        for c in try LiveVectorTests.cases("config", 5) {
            let value = c["value"] ?? NSNull()
            let on = try XCTUnwrap(c["on"] as? Bool)
            XCTAssertEqual(LivePromotion.configOn(JSONValue(any: value)), on, "\(value)")
            // through the signed config's own decoder: any value is kept, never failing the config
            let data = try JSONSerialization.data(withJSONObject: ["live_promotion": value, "analytics": true])
            let flags = try JSONDecoder().decode(RemoteConfig.Flags.self, from: data)
            XCTAssertEqual(flags.livePromotion, on, "\(value)")
        }
        let absent = try JSONDecoder().decode(RemoteConfig.Flags.self, from: Data("{}".utf8))
        XCTAssertNil(absent.live_promotion)
        XCTAssertTrue(absent.livePromotion, "on by default from 4.0.5")
    }

    // MARK: 30.9

    func store() -> AnalyticsStore {
        AnalyticsStore(storage: Fixtures.storage(), enabled: true,
                       context: .init(platform: "ios", sdkVersion: "4.0.5", appVersion: "1", deviceClass: "phone", soc: nil, osMajor: 26, ramTier: "8gb"))
    }

    /// The `live` object: each take's tally added when it ended (its attempt with its outcome and its swap's latency at
    /// once, so a delta never holds an outcome without its attempt; a take held from one under its reason); checked by
    /// the server's rule; sent (qlab-api takes it since 2026-11-23 15:27Z), and with the switch off (`livePromotionsSent`)
    /// kept out of what is sent, no entry made for it alone.
    func testTheLiveObjectIsCountedAndKeptOutOfWhatIsSent() throws {
        XCTAssertTrue(AnalyticsStore.livePromotionsSent.withLock { $0 }, "on: qlab-api takes live")
        AnalyticsStore.livePromotionsSent.withLock { $0 = false }
        let s = store()
        func rec(_ t: LiveTally, _ context: String = "c16_l64") {
            s.record(.promotion(PromotionTelemetry(backend: "ane", revision: "4.0.0", build: "", context: context, kind: .live(t))))
        }
        // the section's own example: 3 attempts, 2 swaps, 1 mismatch, 3 takes held
        rec(LiveTally(attempts: 1, outcome: "swapped", latency: "le_1000", secondsAfterSwap: 400.0))
        rec(LiveTally(attempts: 1, outcome: "swapped", latency: "le_2000", secondsAfterSwap: 12.5))
        rec(LiveTally(attempts: 1, outcome: "mismatch"))
        rec(LiveTally(held: "thermal"))
        rec(LiveTally(held: "thermal"))
        rec(LiveTally(held: "stall"))
        let day = try XCTUnwrap(s.pending.first)
        let live = try XCTUnwrap(day.promotions.values.first?.live)
        XCTAssertEqual(live.object as NSDictionary, ["attempts": 3, "swapped": 2, "mismatch": 1, "held": ["thermal": 2, "stall": 1],
                                                     "latency_ms": ["le_1000": 1, "le_2000": 1], "seconds_after_swap": 412.5] as NSDictionary)
        XCTAssertNil(LiveRules.liveProblem(live.object))
        // off: nothing of it goes, and an entry with nothing else counted is not made
        XCTAssertNil(s.payload(day, reportID: String(repeating: "a", count: 32))["promotions"])
        // an entry with other counts goes without it
        s.record(.promotion(PromotionTelemetry(backend: "ane", revision: "4.0.0", build: "", context: "c16_l64",
                                               kind: .failover(cause: .deadline, stallMs: 40))))
        let off = try XCTUnwrap(s.payload(try XCTUnwrap(s.pending.first), reportID: String(repeating: "b", count: 32))["promotions"] as? [[String: Any]])
        XCTAssertEqual(off.count, 1)
        XCTAssertNil(off[0]["live"])
        XCTAssertEqual(off[0]["failovers"] as? Int, 1)
        // on: as the server takes it
        AnalyticsStore.livePromotionsSent.withLock { $0 = true }
        let on = try XCTUnwrap(s.payload(try XCTUnwrap(s.pending.first), reportID: String(repeating: "c", count: 32))["promotions"] as? [[String: Any]])
        XCTAssertEqual(on[0]["live"] as? NSDictionary, live.object as NSDictionary)
        // every outcome, each counted once with its attempt; an entry of held takes alone is made once it is on
        for o in LiveRules.outcomes {
            rec(LiveTally(attempts: 1, outcome: o, latency: o == "swapped" ? "le_500" : nil, secondsAfterSwap: o == "swapped" ? 0.7 : nil), "c24_l72")
        }
        rec(LiveTally(held: "config_off"), "c24_l256")
        let all = try XCTUnwrap(s.pending.first?.promotions.values.first { $0.context == "c24_l72" }?.live)
        XCTAssertEqual(all.attempts, 6)
        XCTAssertEqual(all.outcomes.values.reduce(0, +), 6)
        XCTAssertEqual(all.object["seconds_after_swap"] as? Double, 0.7)
        XCTAssertNil(LiveRules.liveProblem(all.object))
        let three = try XCTUnwrap(s.payload(try XCTUnwrap(s.pending.first), reportID: String(repeating: "d", count: 32))["promotions"] as? [[String: Any]])
        XCTAssertEqual(three.count, 3)
        let heldOnly = try XCTUnwrap(three.first { $0["context"] as? String == "c24_l256" }?["live"] as? [String: Any])
        XCTAssertEqual(heldOnly as NSDictionary, ["attempts": 0, "held": ["config_off": 1]] as NSDictionary)
        XCTAssertNil(LiveRules.liveProblem(heldOnly))
        // a day saved by 4.0.4 (no `live`) still decodes
        var o = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AnalyticsStore.Promotion(backend: "ane", revision: "r", context: "c16_l64"))) as? [String: Any])
        o["live"] = nil
        XCTAssertNil(try JSONDecoder().decode(AnalyticsStore.Promotion.self, from: JSONSerialization.data(withJSONObject: o)).live)
    }

    // MARK: 30.6, the record

    func end(_ o: LivePromotion.Outcome, cause: FailoverCause? = nil, exact: Bool = true) -> TakeRunner.LiveEnd {
        TakeRunner.LiveEnd(outcome: o, exact: exact, detail: "a test", cause: cause)
    }

    func ready(_ h: PromotionTests.Harness, revision: String = "r1") async -> AcceleratorController {
        let c = h.controller(revision: revision)
        await c.run(h.stages())
        XCTAssertEqual(c.state, .ready)
        return c
    }

    /// What each outcome writes is the failover's rule for the same trouble; none counts a failover or reports an
    /// incident (no take left the accelerator). The take's tally is counted on its own (`liveTally`).
    func testEachOutcomeWritesTheFailoversRuleIntoTheRecord() async throws {
        // swapped, stalled, aborted: nothing
        for o in [LivePromotion.Outcome.swapped, .stalled, .aborted] {
            let h = PromotionTests.Harness()
            let c = await ready(h)
            XCTAssertNotNil(c.leaseForSession())
            c.liveEnded(end(o), session: "s")
            c.endLease()
            XCTAssertEqual(c.state, .ready, o.rawValue)
            let r = try XCTUnwrap(c.record)
            XCTAssertNil(r.backoffUntil, o.rawValue)
            XCTAssertNil(r.disagreements, o.rawValue)
            XCTAssertNil(r.missSessions, o.rawValue)
            XCTAssertNotNil(c.leaseForSession(), "\(o.rawValue): the next session runs on the build")
            c.endLease()
            XCTAssertTrue(h.incidents.withLock { $0 }.isEmpty, o.rawValue)
            XCTAssertFalse(h.promotions.contains { if case .live = $0.kind { return true }; return false }, "the tally is the take's, at its end")
            // the take's tally, at its end
            c.liveTally(LiveTally(attempts: 1, outcome: o.rawValue, latency: o == .swapped ? "le_500" : nil, secondsAfterSwap: o == .swapped ? 12.3 : nil))
            c.liveTally(LiveTally())
            let live = h.promotions.compactMap { p -> LiveTally? in if case .live(let t) = p.kind { return t }; return nil }
            XCTAssertEqual(live.count, 1, "an empty tally is not counted")
            XCTAssertEqual(live.compactMap(\.outcome), [o.rawValue])
        }
        // mismatch: as a confirmed blank disagreement, a transient demotion; a second one turns the build off for good
        do {
            let h = PromotionTests.Harness()
            var c = await ready(h)
            XCTAssertNotNil(c.leaseForSession())
            c.liveEnded(end(.mismatch), session: "s1")
            c.endLease()
            guard case .disabled(let why) = c.state else { return XCTFail("\(c.state)") }
            XCTAssertTrue(why.contains("used again after"), why)
            var r = try XCTUnwrap(c.record)
            XCTAssertEqual(r.status, .ready, "still verified")
            XCTAssertEqual(r.disagreements, 1)
            XCTAssertEqual(r.lastCause, .blank)
            XCTAssertEqual(r.backoffUntil, h.now.withLock { $0 }.addingTimeInterval(PromotionPolicy.transientBackoff))
            XCTAssertNil(c.leaseForSession())
            h.advance(PromotionPolicy.transientBackoff + 1)
            c = h.controller(launch: "L2")
            await c.run(h.stages())
            XCTAssertEqual(c.state, .ready, "loaded again after the backoff, no golden test")
            XCTAssertNotNil(c.leaseForSession())
            c.liveEnded(end(.mismatch), session: "s2")
            c.endLease()
            r = try XCTUnwrap(c.record)
            XCTAssertEqual(r.status, .failed, "a second disagreement: off for good for the key")
            XCTAssertTrue(h.incidents.withLock { $0 }.isEmpty)
            XCTAssertTrue(h.promotions.allSatisfy { if case .failover = $0.kind { return false }; return true }, "no failover counted")
            XCTAssertEqual(h.promotions.filter { if case .demoted(.failover) = $0.kind { return true }; return false }.count, 2)
        }
        // mismatch_inexact: as a deadline miss, demoted only after misses in 3 different sessions within 24 h
        do {
            let h = PromotionTests.Harness()
            let c = await ready(h)
            for (i, s) in ["a", "b", "b", "c"].enumerated() {
                XCTAssertNotNil(c.leaseForSession(), s)
                c.liveEnded(end(.mismatchInexact, exact: false), session: s)
                c.endLease()
                if i < 3 { XCTAssertEqual(c.state, .ready, "misses in fewer than 3 sessions (\(i + 1) attempts)") }
                h.advance(3600)
            }
            guard case .disabled = c.state else { return XCTFail("\(c.state)") }
            XCTAssertEqual(c.record?.status, .ready, "a transient demotion")
            XCTAssertEqual(c.record?.lastCause, .deadline)
        }
        // accel_failed: by its cause
        for (cause, status) in [(FailoverCause.nonFinite, PromotionRecord.Status.failed), (.outOfRange, .failed), (.exception, .retry)] {
            let h = PromotionTests.Harness()
            let c = await ready(h, revision: "x\(cause.rawValue)")
            XCTAssertNotNil(c.leaseForSession())
            c.liveEnded(end(.accelFailed, cause: cause), session: "s")
            c.endLease()
            XCTAssertEqual(c.record?.status, status, cause.rawValue)
            XCTAssertEqual(c.record?.lastCause, cause)
            XCTAssertNil(c.leaseForSession(), cause.rawValue)
        }
        do {
            let h = PromotionTests.Harness()
            let c = await ready(h)
            XCTAssertNotNil(c.leaseForSession())
            c.liveEnded(end(.accelFailed, cause: .deadline), session: "s")
            c.endLease()
            XCTAssertEqual(c.state, .ready, "one deadline miss keeps the build")
            XCTAssertEqual(c.record?.missSessions?.count, 1)
        }
    }

    // MARK: 30.10

    func testDiagnoseHasLiveLastInBackendOnceAnAttemptStarted() throws {
        var d = TajweedDiagnosis(sdkVersion: "4.0.5", sdkLatest: nil, key: .init(accepted: true, reason: nil), config: "fresh", model: nil,
                                 context: "c16_l64", backend: TajweedBackend(kind: .accelerator, name: "coreml", stage: .promoted, reason: nil),
                                 microphone: "granted", storage: .init(models: [], sharingQueueBytes: 0), lastError: nil, droppedChunks: 0,
                                 connection: "unmetered")
        let before = d.json
        XCTAssertFalse(before.contains("live"), "before an attempt: the report of 4.0.1")
        d.live = .init(attempts: 1, swaps: 1, last: "swapped", lastFromChunk: 41)
        XCTAssertTrue(d.json.contains("\"backend\": {\"kind\": \"accelerator\", \"name\": \"coreml\", \"stage\": \"promoted\", \"reason\": null, "
            + "\"live\": {\"attempts\": 1, \"swaps\": 1, \"last\": \"swapped\", \"lastFromChunk\": 41}},"), d.json)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(d.json.utf8)) as? [String: Any])
        XCTAssertEqual((o["backend"] as? [String: Any])?["live"] as? NSDictionary,
                       ["attempts": 1, "swaps": 1, "last": "swapped", "lastFromChunk": 41] as NSDictionary)
        // running, before any swap: no lastFromChunk
        d.live = .init(attempts: 1, swaps: 0, last: "running", lastFromChunk: nil)
        XCTAssertTrue(d.json.contains("\"live\": {\"attempts\": 1, \"swaps\": 0, \"last\": \"running\"}}"), d.json)
        // the process's counts
        XCTAssertNil(LiveDiagnosis.stats.withLock { $0 })
        LiveDiagnosis.started()
        XCTAssertEqual(LiveDiagnosis.stats.withLock { $0 }, .init(attempts: 1, swaps: 0, last: "running", lastFromChunk: nil))
        LiveDiagnosis.ended(.swapped, fromChunk: 41)
        LiveDiagnosis.started()
        LiveDiagnosis.ended(.stalled, fromChunk: nil)
        XCTAssertEqual(LiveDiagnosis.stats.withLock { $0 }, .init(attempts: 2, swaps: 1, last: "stalled", lastFromChunk: 41))
    }
}
