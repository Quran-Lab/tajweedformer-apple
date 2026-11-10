import Foundation
import XCTest
@testable import TajweedFormer

/// The self-test set (role `selftest`) and its pass rule: tokens on clean clips, flagged sites and words on every clip
/// (planted ones included), compared as sets both ways; speed is never part of it. The promotion pipeline that uses it
/// is in PromotionTests.
final class AcceleratorTests: XCTestCase {
    static let cohort = TelemetryCohort(revision: "r1", context: "c16_l64", backend: "cpu", preset: "balanced", wordLevel: "off",
                                        wordBucket: "", siteOverrides: 0)

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
    func testAMissedPlantedFlagIsNotPromoted() throws {
        let set = try XCTUnwrap(SelfTestSet.load(Fixtures.v4mini().appendingPathComponent("decoded"), context: "c16_l64"))
        let planted = try XCTUnwrap(set.expected["Husary_112001_planted"])
        let why = SelfTestSet.compare(clip: "Husary_112001_planted", expected: planted, tokens: planted.tokens, flaggedSites: [], flaggedWords: [])
        let r = SelfTestSet.judge(mismatch: why, accelerator: [0.002], cpu: [0.008])
        XCTAssertFalse(r.passed)
        XCTAssertTrue(r.reason!.contains("Husary_112001_planted") && r.reason!.contains("missed"), r.reason!)
    }

    // MARK: the planted-clip rule: tokens on clean clips, flags on every clip

    func testClipKindsComeFromTheSet() throws {
        let set = try XCTUnwrap(SelfTestSet.load(Fixtures.v4mini().appendingPathComponent("decoded"), context: "c16_l64"))
        XCTAssertEqual(set.clips.map(\.planted), [false, false, true], "kind clean, kind absent (clean), kind planted")
    }

    func testPlantedClipWithOtherTokensButTheSameFlagsIsPromoted() throws {
        let set = try XCTUnwrap(SelfTestSet.load(Fixtures.v4mini().appendingPathComponent("decoded"), context: "c16_l64"))
        let planted = try XCTUnwrap(set.expected["Husary_112001_planted"])
        let extraToken = planted.tokens + [9]
        let why = SelfTestSet.compare(clip: "Husary_112001_planted", planted: true, expected: planted, tokens: extraToken,
                                      flaggedSites: planted.flaggedSites, flaggedWords: planted.flaggedWords)
        XCTAssertNil(why, "a planted clip's tokens may differ when its flags agree")
        XCTAssertTrue(SelfTestSet.judge(mismatch: why, accelerator: [0.002], cpu: [0.008]).passed)
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

    /// Quran Lab (11-10): the golden test's verdict is the decisions only; a slower build passes.
    func testTheSelfTestRuleHasNoLatencyGate() {
        let fast = [0.003, 0.004, 0.003, 0.005], cpu = [0.008, 0.009, 0.010]
        XCTAssertTrue(SelfTestSet.judge(mismatch: nil, accelerator: fast, cpu: cpu).passed)
        XCTAssertFalse(SelfTestSet.judge(mismatch: "x: tokens differ", accelerator: fast, cpu: cpu).passed)
        let slowTail = [0.003, 0.003, 0.003, 0.003, 0.003, 0.003, 0.003, 0.003, 0.2, 0.2]
        XCTAssertTrue(SelfTestSet.judge(mismatch: nil, accelerator: slowTail, cpu: [0.1]).passed, "a slow p90 passes")
        let slower = SelfTestSet.judge(mismatch: nil, accelerator: [0.009], cpu: [0.008])
        XCTAssertTrue(slower.passed, "slower than the CPU passes")
        XCTAssertLessThan(slower.speedup, 1)
    }
}
