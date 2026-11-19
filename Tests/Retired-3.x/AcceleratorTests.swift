import Foundation
import XCTest
@testable import TajweedFormer

/// The self-test set (role `selftest`) as SDK 3.0.0 reads it: the clips, their kind, and per clip the expected tokens
/// (nothing else of the expected file). The golden test that uses it is in GoldenRawTests and PromotionTests.
final class AcceleratorTests: XCTestCase {
    static let cohort = TelemetryCohort(revision: "4.0.0", build: "", context: "c16_l64", backend: "cpu")

    // MARK: the self-test set

    func testTheSelfTestSetParsesTheLayoutSchema() throws {
        let set = try XCTUnwrap(SelfTestSet.load(Fixtures.v4mini().appendingPathComponent("decoded"), context: "c16_l64"))
        XCTAssertEqual(set.clips.map(\.id), ["Husary_001001", "Husary_112001", "Husary_112001_planted"])
        XCTAssertEqual(set.clips[0].samples.count, 1600)
        XCTAssertTrue(set.clips[0].mustDecode)
        XCTAssertEqual(set.expected["Husary_001001"], [3, 4, 5])
        XCTAssertEqual(set.expected["Husary_112001_planted"], [3, 4, 6])
        XCTAssertNil(try SelfTestSet.load(Fixtures.v4mini().appendingPathComponent("decoded"), context: "c24_l256"))
    }

    func testClipKindsComeFromTheSet() throws {
        let set = try XCTUnwrap(SelfTestSet.load(Fixtures.v4mini().appendingPathComponent("decoded"), context: "c16_l64"))
        XCTAssertEqual(set.clips.map(\.planted), [false, false, true], "kind clean, kind absent (clean), kind planted")
    }

    /// An expected file of a 2.x build (flagged sites and words, word scores) and one of a 3.0 build (tokens only)
    /// both load, and give the tokens; a set without kind fields has clean clips only.
    func testBothShapesOfTheExpectedFileLoad() throws {
        let dir = Fixtures.storage().appendingPathComponent("selftest")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pcm = Data(repeating: 0, count: 3200)
        try pcm.write(to: dir.appendingPathComponent("a.s16"))
        try pcm.write(to: dir.appendingPathComponent("b.s16"))
        let meta: [String: Any] = ["format": "quranlab.selftest/1", "clips": [
            ["id": "a", "surah": 1, "ayah": 1, "file": "selftest/a.s16", "samples": 1600, "sample_rate": 16000, "must_decode": true],
            ["id": "b", "surah": 112, "ayah": 1, "file": "selftest/b.s16", "samples": 1600, "sample_rate": 16000, "must_decode": false]]]
        let old: [String: Any] = ["format": "quranlab.selftest-expected/1", "context": "c16_l64", "calibration_sha256": "x", "clips": [
            "a": ["chunks": 1, "tokens": [3], "flagged_sites": [], "flagged_words": []],
            "b": ["chunks": 1, "tokens": [4], "flagged_sites": [[0, "vowel_sub"]], "flagged_words": [0], "word_scores": [7.25]]]]
        let new: [String: Any] = ["format": "quranlab.selftest-expected/1", "context": "c16_l64", "engine": "int8", "clips": [
            "a": ["chunks": 1, "tokens": [3]], "b": ["chunks": 1, "tokens": [4]]]]
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("selftest.json"))
        for exp in [old, new] {
            try JSONSerialization.data(withJSONObject: exp).write(to: dir.appendingPathComponent("expected_c16_l64.json"))
            let set = try XCTUnwrap(SelfTestSet.load(dir.deletingLastPathComponent(), context: "c16_l64"))
            XCTAssertEqual(set.clips.map(\.planted), [false, false])
            XCTAssertEqual(set.expected, ["a": [3], "b": [4]])
        }
        // "planted": true is read too
        var m2 = meta
        var clips = m2["clips"] as! [[String: Any]]
        clips[1]["planted"] = true
        m2["clips"] = clips
        try JSONSerialization.data(withJSONObject: m2).write(to: dir.appendingPathComponent("selftest.json"))
        XCTAssertEqual(try XCTUnwrap(SelfTestSet.load(dir.deletingLastPathComponent(), context: "c16_l64")).clips.map(\.planted), [false, true])
        // a clip without tokens in the expected file: the set is not usable
        let missing: [String: Any] = ["format": "quranlab.selftest-expected/1", "context": "c16_l64", "clips": ["a": ["chunks": 1, "tokens": [3]]]]
        try JSONSerialization.data(withJSONObject: missing).write(to: dir.appendingPathComponent("expected_c16_l64.json"))
        XCTAssertNil(SelfTestSet.load(dir.deletingLastPathComponent(), context: "c16_l64"))
    }

    /// A shipped 2.x self-test set (revision 07f): `kind` on every clip, `planted` an object on the planted clip,
    /// unknown keys, and an expected file with the 2.x fields. Placeholders stand in for the audio.
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
        XCTAssertEqual(set.expected["Husary_001001"]?.count, 21)
        XCTAssertNotNil(set.expected["Husary_112001_vsub2"])
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

    /// The golden test's verdict is the comparison only; a slower build passes.
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
