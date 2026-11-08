import Foundation
import XCTest
@testable import TajweedFormer

/// The CPU-first state machine of the Neural Engine, with a fake accelerator: no Mac, no CoreML, no Neural Engine
/// needed. Every rule: the self-test gates promotion, verdicts are kept per revision, OS build, device model and
/// context, a crash during a load disables that key at the next launch, runtime faults and memory warnings go back
/// to the CPU engine for the launch, a slow preparation times out, the deny-list and thermal state prefer the CPU.
final class AcceleratorTests: XCTestCase {
    final class FakeBackend: AcceleratorBackend {
        var chunkSeconds: [Double] = []
        func reset() { chunkSeconds = [] }
        func push(_ s: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [TajweedHeads] { [] }
        func finish() throws(RecognizerError) -> [TajweedHeads] { [] }
    }

    static let cohort = TelemetryCohort(revision: "r1", context: "c16_l64", backend: "cpu", preset: "balanced", wordLevel: "off",
                                        wordBucket: "", siteOverrides: 0)

    let events = Locked<[AnalyticsEvent]>([])
    let loads = Locked(0)
    let tests = Locked(0)
    lazy var storage: URL = Fixtures.storage()

    func controller(revision: String = "r1", os: String = "23A100", device: String = "iPhone17,1", timeout: TimeInterval = 5,
                    thermal: ProcessInfo.ThermalState = .nominal, denied: String? = nil) -> AcceleratorController {
        let ev = events
        let t = Locked(thermal)
        return AcceleratorController(.init(revision: revision, osBuild: os, deviceModel: device, context: "c16_l64", compact: false,
                                           storage: storage, timeout: timeout, thermal: { t.withLock { $0 } }, denied: { denied },
                                           record: { e in ev.withLock { $0.append(e) } }, cohort: { Self.cohort }))
    }

    func load(delay: TimeInterval = 0) -> AcceleratorController.Load {
        let n = loads
        return {
            n.withLock { $0 += 1 }
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            return UncheckedBox(FakeBackend() as any AcceleratorBackend)
        }
    }

    func selfTest(_ r: AcceleratorSelfTest) -> AcceleratorController.SelfTest {
        let n = tests
        return { _ in
            n.withLock { $0 += 1 }
            return r
        }
    }

    static let pass = AcceleratorSelfTest(passed: true, reason: nil, p90Ms: 3, medianMs: 2, cpuMedianMs: 6)
    static let tokensDiffer = AcceleratorSelfTest(passed: false, reason: "Husary_001001: tokens differ")
    static let flagsDiffer = AcceleratorSelfTest(passed: false, reason: "Husary_112001: flagged sites differ")

    func fallbacks() -> [FallbackReason] {
        events.withLock { $0 }.compactMap { if case .fallback(let r, _) = $0 { return r } else { return nil } }
    }

    // MARK: promotion

    func testCPUFirstThenReadyAfterTheSelfTestPromotedAtTheNextTake() async {
        let c = controller()
        XCTAssertEqual(c.state, .cpu)
        let takeInProgress = c.backendForTake()
        XCTAssertNil(takeInProgress, "the first take runs on the CPU engine")
        await c.prepare(load: load(), selfTest: selfTest(Self.pass))
        XCTAssertEqual(c.state, .ready)
        XCTAssertNil(takeInProgress, "a take that started on the CPU stays there")
        XCTAssertNotNil(c.backendForTake(), "the next take runs on the accelerator")
        XCTAssertTrue(events.withLock { $0 }.contains { if case .modelLoaded(_, _, let co) = $0 { return co.backend == "ane" } else { return false } },
                      "time to ready recorded")
        // the next launch: the kept verdict, no new self-test
        let again = controller()
        await again.prepare(load: load(), selfTest: selfTest(Self.tokensDiffer))
        XCTAssertEqual(again.state, .ready)
        XCTAssertEqual(tests.withLock { $0 }, 1, "a passed key is not self-tested again")
    }

    // MARK: self-test failures

    func testTokenOrFlagMismatchIsNeverRetriedForTheSameKey() async {
        for (i, r) in [Self.tokensDiffer, Self.flagsDiffer].enumerated() {
            let c = controller(revision: "rev-\(i)")
            await c.prepare(load: load(), selfTest: selfTest(r))
            XCTAssertEqual(c.state, .disabled("self-test: " + r.reason!))
            XCTAssertNil(c.backendForTake())
            let before = loads.withLock { $0 }
            let next = controller(revision: "rev-\(i)")
            XCTAssertEqual(next.state, .disabled("self-test: " + r.reason!), "kept on disk")
            await next.prepare(load: load(), selfTest: selfTest(Self.pass))
            XCTAssertEqual(loads.withLock { $0 }, before, "never retried for the same revision and OS build")
        }
        XCTAssertTrue(fallbacks().contains(.modelLoad))
    }

    func testAnOSBuildChangePreparesAgain() async {
        let c = controller(os: "23A100")
        await c.prepare(load: load(), selfTest: selfTest(Self.tokensDiffer))
        guard case .disabled = c.state else { return XCTFail("\(c.state)") }
        let updated = controller(os: "23B50")
        XCTAssertEqual(updated.state, .cpu, "a new OS build is a new key")
        await updated.prepare(load: load(), selfTest: selfTest(Self.pass))
        XCTAssertEqual(updated.state, .ready)
    }

    func testARevisionChangePreparesAgain() async {
        let c = controller(revision: "r1")
        await c.prepare(load: load(), selfTest: selfTest(Self.flagsDiffer))
        let newer = controller(revision: "r2")
        XCTAssertEqual(newer.state, .cpu)
        await newer.prepare(load: load(), selfTest: selfTest(Self.pass))
        XCTAssertEqual(newer.state, .ready)
    }

    // MARK: crash sentinel

    func testACrashDuringALoadDisablesThatKeyAtTheNextLaunch() async {
        let c = controller()
        // the app dies between the sentinel and its clearing: what a crash in the ANE compiler leaves behind
        c.store.writeSentinel(c.key)
        let next = controller()
        guard case .disabled(let why) = next.state else { return XCTFail("\(next.state)") }
        XCTAssertTrue(why.contains("stopped during an accelerator load"), why)
        XCTAssertNil(next.store.sentinel(), "the sentinel is cleared once read")
        await next.prepare(load: load(), selfTest: selfTest(Self.pass))
        XCTAssertEqual(loads.withLock { $0 }, 0, "no load for a key that crashed")
        XCTAssertEqual(controller(os: "23C1").state, .cpu, "another OS build may try again")
        XCTAssertTrue(fallbacks().contains(.modelLoad))
    }

    func testACleanRunLeavesNoSentinel() async {
        let c = controller()
        await c.prepare(load: load(), selfTest: selfTest(Self.pass))
        XCTAssertNil(c.store.sentinel())
    }

    // MARK: timeouts and runtime guards

    func testAPrepareTimeoutKeepsTheCPUForThisLaunchOnly() async {
        let c = controller(timeout: 0.2)
        await c.prepare(load: load(delay: 3), selfTest: selfTest(Self.pass))
        guard case .disabled(let why) = c.state else { return XCTFail("\(c.state)") }
        XCTAssertTrue(why.contains("not ready within"), why)
        XCTAssertNil(c.store.sentinel())
        XCTAssertEqual(controller().state, .cpu, "a timeout is not kept: the next launch tries again")
    }

    func testANaNAtChunkKFallsBackFromTheNextTake() async {
        let c = controller()
        await c.prepare(load: load(), selfTest: selfTest(Self.pass))
        XCTAssertNotNil(c.backendForTake())
        c.runtimeFault(.nonFinite, "a head was NaN or infinite at chunk 7")
        XCTAssertEqual(c.state, .disabled("a head was NaN or infinite at chunk 7"))
        XCTAssertNil(c.backendForTake(), "the CPU engine from the next take")
        XCTAssertTrue(fallbacks().contains(.nonFinite))
        let nextLaunch = controller()
        await nextLaunch.prepare(load: load(), selfTest: selfTest(Self.tokensDiffer))
        XCTAssertEqual(nextLaunch.state, .ready, "a runtime fault is for this launch; the passed verdict stands")
    }

    func testThermalPrefersTheCPU() async {
        let hot = controller(thermal: .serious)
        await hot.prepare(load: load(), selfTest: selfTest(Self.pass))
        XCTAssertEqual(hot.state, .ready)
        XCTAssertNil(hot.backendForTake(), "serious thermal state: this take on the CPU engine")
        XCTAssertTrue(fallbacks().contains(.thermal))
        let cool = controller(revision: "r-fair", thermal: .fair)
        await cool.prepare(load: load(), selfTest: selfTest(Self.pass))
        XCTAssertNotNil(cool.backendForTake(), "fair is fine")
    }

    func testAMemoryWarningPrefersTheCPU() async {
        let c = controller()
        await c.prepare(load: load(), selfTest: selfTest(Self.pass))
        c.memoryWarning()
        XCTAssertNil(c.backendForTake())
        XCTAssertTrue(fallbacks().contains(.memory))
    }

    func testTheDenyListForcesTheCPU() async {
        let c = controller(denied: "deny-listed: fp16 trouble on this build")
        XCTAssertEqual(c.state, .disabled("deny-listed: fp16 trouble on this build"))
        await c.prepare(load: load(), selfTest: selfTest(Self.pass))
        XCTAssertEqual(loads.withLock { $0 }, 0)
        XCTAssertNil(c.backendForTake())
    }

    func testAwaitReady() async {
        let c = controller()
        let l = load(delay: 0.5), t = selfTest(Self.pass)
        let task = Task { await c.prepare(load: l, selfTest: t) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(c.state, .preparing)
        let early = await c.awaitReady(timeout: 0.05)
        XCTAssertFalse(early)
        let ready = await c.awaitReady(timeout: 10)
        XCTAssertTrue(ready)
        await task.value
        var seen: [AcceleratorState] = []
        for await s in c.states() { seen.append(s); break }
        XCTAssertEqual(seen, [.ready])
    }

    // MARK: the self-test set and its rule

    func testTheSelfTestSetParsesTheLayoutSchema() throws {
        let set = try XCTUnwrap(SelfTestSet.load(Fixtures.v4mini().appendingPathComponent("decoded"), context: "c16_l64"))
        XCTAssertEqual(set.clips.map(\.id), ["Husary_001001", "Husary_112001", "Husary_112001_planted"])
        XCTAssertEqual(set.clips[0].samples.count, 1600)
        XCTAssertTrue(set.clips[0].mustDecode)
        XCTAssertEqual(set.expected["Husary_001001"]?.tokens, [3, 4, 5])
        XCTAssertEqual(set.expected["Husary_001001"]?.flaggedSites, [])
        XCTAssertEqual(set.expected["Husary_112001_planted"]?.flaggedSites, ["2|vowel_sub"], "the planted mistake is expected flagged")
        XCTAssertEqual(set.expected["Husary_112001_planted"]?.flaggedWords, [0])
        XCTAssertNil(try SelfTestSet.load(Fixtures.v4mini().appendingPathComponent("decoded"), context: "c24_l256"))
    }

    /// Flags are compared as sets in both directions: the planted mistake missed fails, an extra flag fails, exact passes.
    func testFlagSetsAreComparedBothWays() throws {
        let set = try XCTUnwrap(SelfTestSet.load(Fixtures.v4mini().appendingPathComponent("decoded"), context: "c16_l64"))
        let planted = try XCTUnwrap(set.expected["Husary_112001_planted"])
        XCTAssertNil(SelfTestSet.compare(clip: "p", expected: planted, tokens: [3, 4, 6], flaggedSites: ["2|vowel_sub"], flaggedWords: [0]))
        let missed = SelfTestSet.compare(clip: "Husary_112001_planted", expected: planted, tokens: [3, 4, 6], flaggedSites: [], flaggedWords: [0])
        XCTAssertEqual(missed, "Husary_112001_planted: flagged sites differ (missed [\"2|vowel_sub\"], extra [])")
        let extra = SelfTestSet.compare(clip: "c", expected: try XCTUnwrap(set.expected["Husary_001001"]), tokens: [3, 4, 5],
                                        flaggedSites: ["1|cons_sub"], flaggedWords: [])
        XCTAssertNotNil(extra, "an extra flag fails too")
        XCTAssertNotNil(SelfTestSet.compare(clip: "p", expected: planted, tokens: [3, 4, 6], flaggedSites: ["2|vowel_sub"], flaggedWords: []),
                        "a missed word flag fails")
    }

    /// The accelerator misses the planted flag: not promoted, the reason says so, and the verdict is kept for the key.
    func testAMissedPlantedFlagIsNotPromoted() async throws {
        let set = try XCTUnwrap(SelfTestSet.load(Fixtures.v4mini().appendingPathComponent("decoded"), context: "c16_l64"))
        let planted = try XCTUnwrap(set.expected["Husary_112001_planted"])
        let why = SelfTestSet.compare(clip: "Husary_112001_planted", expected: planted, tokens: planted.tokens, flaggedSites: [], flaggedWords: [])
        let r = SelfTestSet.judge(mismatch: why, accelerator: [0.002], cpu: [0.008], chunkMs: 320)
        let c = controller(revision: "planted")
        await c.prepare(load: load(), selfTest: selfTest(r))
        guard case .disabled(let reason) = c.state else { return XCTFail("\(c.state)") }
        XCTAssertTrue(reason.contains("Husary_112001_planted") && reason.contains("missed"), reason)
        XCTAssertNil(c.backendForTake())
        XCTAssertEqual(controller(revision: "planted").state, .disabled(reason), "kept for the key")
    }

    // MARK: the planted-clip rule: tokens on clean clips, flags on every clip

    func testClipKindsComeFromTheSet() throws {
        let set = try XCTUnwrap(SelfTestSet.load(Fixtures.v4mini().appendingPathComponent("decoded"), context: "c16_l64"))
        XCTAssertEqual(set.clips.map(\.planted), [false, false, true], "kind clean, kind absent (clean), kind planted")
    }

    func testPlantedClipWithOtherTokensButTheSameFlagsIsPromoted() async throws {
        let set = try XCTUnwrap(SelfTestSet.load(Fixtures.v4mini().appendingPathComponent("decoded"), context: "c16_l64"))
        let planted = try XCTUnwrap(set.expected["Husary_112001_planted"])
        let extraToken = planted.tokens + [9]
        let why = SelfTestSet.compare(clip: "Husary_112001_planted", planted: true, expected: planted, tokens: extraToken,
                                      flaggedSites: planted.flaggedSites, flaggedWords: planted.flaggedWords)
        XCTAssertNil(why, "a planted clip's tokens may differ when its flags agree")
        let c = controller(revision: "planted-tokens")
        await c.prepare(load: load(), selfTest: selfTest(SelfTestSet.judge(mismatch: why, accelerator: [0.002], cpu: [0.008], chunkMs: 320)))
        XCTAssertEqual(c.state, .ready)
    }

    func testPlantedClipWithAMissedFlagIsRefused() throws {
        let set = try XCTUnwrap(SelfTestSet.load(Fixtures.v4mini().appendingPathComponent("decoded"), context: "c16_l64"))
        let planted = try XCTUnwrap(set.expected["Husary_112001_planted"])
        let why = SelfTestSet.compare(clip: "Husary_112001_planted", planted: true, expected: planted, tokens: planted.tokens + [9],
                                      flaggedSites: [], flaggedWords: planted.flaggedWords)
        XCTAssertEqual(why, "Husary_112001_planted: flagged sites differ (missed [\"2|vowel_sub\"], extra [])")
    }

    func testCleanClipWithOtherTokensIsRefused() throws {
        let set = try XCTUnwrap(SelfTestSet.load(Fixtures.v4mini().appendingPathComponent("decoded"), context: "c16_l64"))
        let clean = try XCTUnwrap(set.expected["Husary_112001"])
        let why = SelfTestSet.compare(clip: "Husary_112001", planted: false, expected: clean, tokens: clean.tokens + [9],
                                      flaggedSites: clean.flaggedSites, flaggedWords: clean.flaggedWords)
        XCTAssertEqual(why, "Husary_112001: tokens differ (4 against 3 expected)")
    }

    /// An older set without kind fields: every clip is clean, tokens compared on all of them.
    func testASetWithoutKindsComparesTokensEverywhere() throws {
        let dir = Fixtures.storage().appendingPathComponent("selftest")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pcm = Data(repeating: 0, count: 3200)
        try pcm.write(to: dir.appendingPathComponent("a.s16"))
        try pcm.write(to: dir.appendingPathComponent("b.s16"))
        let meta: [String: Any] = ["format": "quranlab.selftest/1", "clips": [
            ["id": "a", "surah": 1, "ayah": 1, "file": "selftest/a.s16", "samples": 1600, "sample_rate": 16000, "must_decode": true],
            ["id": "b", "surah": 112, "ayah": 1, "file": "selftest/b.s16", "samples": 1600, "sample_rate": 16000, "must_decode": false]]]
        let exp: [String: Any] = ["format": "quranlab.selftest-expected/1", "context": "c16_l64", "clips": [
            "a": ["chunks": 1, "tokens": [3], "flagged_sites": [], "flagged_words": []],
            "b": ["chunks": 1, "tokens": [4], "flagged_sites": [[0, "vowel_sub"]], "flagged_words": [0]]]]
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("selftest.json"))
        try JSONSerialization.data(withJSONObject: exp).write(to: dir.appendingPathComponent("expected_c16_l64.json"))
        let set = try XCTUnwrap(SelfTestSet.load(dir.deletingLastPathComponent(), context: "c16_l64"))
        XCTAssertEqual(set.clips.map(\.planted), [false, false])
        for clip in set.clips {
            let e = try XCTUnwrap(set.expected[clip.id])
            XCTAssertNotNil(SelfTestSet.compare(clip: clip.id, planted: clip.planted, expected: e, tokens: e.tokens + [5],
                                                flaggedSites: e.flaggedSites, flaggedWords: e.flaggedWords),
                            "\(clip.id): tokens are compared when no kind is given")
        }
        // "planted": true is read too
        var m2 = meta
        var clips = m2["clips"] as! [[String: Any]]
        clips[1]["planted"] = true
        m2["clips"] = clips
        try JSONSerialization.data(withJSONObject: m2).write(to: dir.appendingPathComponent("selftest.json"))
        XCTAssertEqual(try XCTUnwrap(SelfTestSet.load(dir.deletingLastPathComponent(), context: "c16_l64")).clips.map(\.planted), [false, true])
    }

    /// the self-test set (revision 07f): `kind` on every clip, `planted` an object on the planted clip (the
    /// planted mistake, its splice and seam checks), unknown keys; and its expected file (flagged_sites
    /// [[pos, "class"]], pos counting the '|' tokens, the engine's numbering). Placeholders stand in for the audio.
    func testShippedSetShapeParses() throws {
        let src = try XCTUnwrap(Bundle.module.url(forResource: "selftest_07f", withExtension: nil, subdirectory: "Fixtures"))
        let root = Fixtures.storage()
        let dir = root.appendingPathComponent("selftest")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in ["selftest.json", "expected_c16_l64.json"] {
            try FileManager.default.copyItem(at: src.appendingPathComponent(f), to: dir.appendingPathComponent(f))
        }
        let meta = try XCTUnwrap(JSONValue(data: Data(contentsOf: dir.appendingPathComponent("selftest.json"))))
        for c in meta["clips"]?.array ?? [] { try Data(count: 3200).write(to: dir.appendingPathComponent(c["file"]!.string!)) }
        let set = try XCTUnwrap(SelfTestSet.load(root, context: "c16_l64"))
        XCTAssertEqual(set.clips.map(\.id), ["Husary_001001", "Abdul_001001", "Saood_001001", "Husary_112001", "Husary_112001_vsub2"])
        XCTAssertEqual(set.clips.map(\.planted), [false, false, false, false, true])
        XCTAssertEqual(set.clips.filter(\.mustDecode).count, 3)
        let vsub = try XCTUnwrap(set.expected["Husary_112001_vsub2"])
        XCTAssertEqual(vsub.flaggedSites, ["5|vowel_sub", "6|cons_sub"])
        XCTAssertEqual(vsub.flaggedWords, [1])
        XCTAssertEqual(set.expected["Husary_001001"]?.tokens.count, 21)
        XCTAssertEqual(set.expected["Husary_112001"]?.flaggedSites, [])
        // the rule on it: a planted clip's tokens are not compared, its flags are
        XCTAssertNil(SelfTestSet.compare(clip: "Husary_112001_vsub2", planted: true, expected: vsub, tokens: vsub.tokens + [32],
                                         flaggedSites: vsub.flaggedSites, flaggedWords: vsub.flaggedWords))
        XCTAssertNotNil(SelfTestSet.compare(clip: "Husary_112001_vsub2", planted: true, expected: vsub, tokens: vsub.tokens,
                                            flaggedSites: ["5|vowel_sub"], flaggedWords: vsub.flaggedWords))
    }

    func testKindIsAuthoritativeAndPlantedIsTolerant() {
        func kind(_ o: [String: JSONValue]) -> Bool { SelfTestSet.isPlanted(.object(o)) }
        XCTAssertFalse(kind(["kind": .string("clean"), "planted": .object(["pos": .number(5)])]), "kind wins")
        XCTAssertTrue(kind(["kind": .string("planted")]))
        XCTAssertTrue(kind(["planted": .object(["pos": .number(5)])]), "no kind: a planted object")
        XCTAssertTrue(kind(["planted": .bool(true)]))
        XCTAssertFalse(kind(["planted": .bool(false)]))
        XCTAssertFalse(kind(["planted": .string("yes")]), "another type is not planted, and does not fail")
        XCTAssertFalse(kind([:]), "absent is clean")
    }

    // MARK: watchdog persistence

    func testOneTripThenRelaunchIsStillEligible() async {
        let c = controller(revision: "w1")
        await c.prepare(load: load(), selfTest: selfTest(Self.pass))
        c.runtimeFault(.deadline, "a chunk took over three times its audio")
        XCTAssertNil(c.backendForTake(), "this process: the CPU engine")
        let next = controller(revision: "w1")
        XCTAssertEqual(next.state, .cpu, "one trip is for the process only")
        await next.prepare(load: load(), selfTest: selfTest(Self.pass))
        XCTAssertEqual(next.state, .ready)
    }

    func testTwoTripsAcrossLaunchesDisableTheKey() async {
        let first = controller(revision: "w2")
        await first.prepare(load: load(), selfTest: selfTest(Self.pass))
        first.runtimeFault(.nonFinite, "a head was NaN or infinite")
        let second = controller(revision: "w2")
        await second.prepare(load: load(), selfTest: selfTest(Self.pass))
        XCTAssertEqual(second.state, .ready)
        second.runtimeFault(.other, "3 chunks in a row heard nothing in audio with energy")
        guard case .disabled(let why) = second.state else { return XCTFail("\(second.state)") }
        XCTAssertTrue(why.contains("tripped 2 times"), why)
        let loadsBefore = loads.withLock { $0 }
        let third = controller(revision: "w2")
        XCTAssertEqual(third.state, .disabled(why), "kept across launches")
        await third.prepare(load: load(), selfTest: selfTest(Self.pass))
        XCTAssertEqual(loads.withLock { $0 }, loadsBefore, "no further prepare for that key")
        // an OS build change is a new key: eligible again, from zero trips
        let updated = controller(revision: "w2", os: "23D7")
        XCTAssertEqual(updated.state, .cpu)
        await updated.prepare(load: load(), selfTest: selfTest(Self.pass))
        XCTAssertEqual(updated.state, .ready)
        updated.runtimeFault(.deadline, "a chunk took over three times its audio")
        XCTAssertEqual(controller(revision: "w2", os: "23D7").state, .cpu, "one trip on the new key: still eligible")
    }

    func testTheSelfTestRule() {
        let fast = [0.003, 0.004, 0.003, 0.005], cpu = [0.008, 0.009, 0.010]
        XCTAssertTrue(SelfTestSet.judge(mismatch: nil, accelerator: fast, cpu: cpu, chunkMs: 320).passed)
        XCTAssertFalse(SelfTestSet.judge(mismatch: "x: tokens differ", accelerator: fast, cpu: cpu, chunkMs: 320).passed)
        let slowTail = [0.003, 0.003, 0.003, 0.003, 0.003, 0.003, 0.003, 0.003, 0.2, 0.2]
        XCTAssertFalse(SelfTestSet.judge(mismatch: nil, accelerator: slowTail, cpu: [0.1], chunkMs: 320).passed, "p90 over half the chunk")
        XCTAssertFalse(SelfTestSet.judge(mismatch: nil, accelerator: [0.009], cpu: [0.008], chunkMs: 320).passed, "not faster than the CPU")
    }
}
