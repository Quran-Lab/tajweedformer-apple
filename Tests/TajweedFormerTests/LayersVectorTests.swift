import Foundation
import XCTest
@testable import TajweedFormer

/// The decoded layer and the per-word scores against the cross-SDK vectors: every frame's top-1 and runner-up, every greedy token's frames,
/// peak, margin and confidence, the words, and each word's score (the largest fused LLR in the word). Needs
/// TAJWEED_SCORER_FIXTURE (the heads) and TAJWEED_LAYERS_VECTORS (layers_vectors.json).
final class LayersVectorTests: XCTestCase {
    func testDecodedLayerAndWordScores() throws {
        guard let root = ProcessInfo.processInfo.environment["TAJWEED_SCORER_FIXTURE"],
              let vpath = ProcessInfo.processInfo.environment["TAJWEED_LAYERS_VECTORS"] else {
            throw XCTSkip("set TAJWEED_SCORER_FIXTURE and TAJWEED_LAYERS_VECTORS")
        }
        let base = URL(fileURLWithPath: root)
        let meta = try XCTUnwrap(JSONValue(data: Data(contentsOf: base.appendingPathComponent("vectors.json"))))
        let order = try XCTUnwrap(meta["head_order"]?.array).compactMap(\.string)
        let widths = try XCTUnwrap(meta["head_widths"]?.array).compactMap { $0.number.map(Int.init) }
        let rates = try XCTUnwrap(meta["head_ms"]?.array).compactMap { $0.number.map(Int.init) }
        let presets = try XCTUnwrap(meta["presets"]?.object)
        let want = try XCTUnwrap(JSONValue(data: Data(contentsOf: URL(fileURLWithPath: vpath))))
        let byName = Dictionary((want["vectors"]?.array ?? []).compactMap { v in v["name"]?.string.map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
        let vocab = try Vocabulary(tokensFile: base.appendingPathComponent("model/tokens.txt"))
        let cal = try TajweedCalibration(data: Data(contentsOf: base.appendingPathComponent("model/calibration.json")))
        var scorers: [String: EngineTajweedScorer] = [:]
        var decodedOK = 0, wordsOK = 0, total = 0
        for v in try XCTUnwrap(meta["vectors"]?.array) {
            let name = try XCTUnwrap(v["name"]?.string)
            guard let ref = byName[name] else { continue }
            let ctx = try XCTUnwrap(v["context"]?.string)
            let n40 = Int(v["n40"]!.number!), n20 = Int(v["n20"]!.number!)
            let raw = try Data(contentsOf: base.appendingPathComponent(v["heads"]!.string!))
            let floats: [Float] = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            var chunk: [String: [Float]] = [:], o = 0
            for (i, h) in order.enumerated() {
                let n = (rates[i] == 40 ? n40 : n20) * widths[i]
                chunk[h] = Array(floats[o..<o + n])
                o += n
            }
            let heads = TajweedHeads(chunk: chunk)
            total += 1
            // decoded layer
            let d = DecodedTake(heads: heads, vocabulary: vocab)
            var bad: [String] = []
            let rf = ref["decoded"]?["frames"]?.array ?? []
            if rf.count != d.frames.count { bad.append("frame count") }
            for (f, r) in zip(d.frames, rf) {
                if f.top1 != Int(r["top1"]?.number ?? -1) || f.runnerUp != Int(r["runnerUp"]?.number ?? -1) { bad.append("frame ids"); break }
                if abs(f.margin - (r["margin"]?.number ?? .nan)) > 1e-5 { bad.append("frame margin"); break }
            }
            let rt = ref["decoded"]?["tokens"]?.array ?? []
            if rt.count != d.tokens.count { bad.append("token count \(d.tokens.count) != \(rt.count)") }
            for (t, r) in zip(d.tokens, rt) {
                if t.id != Int(r["id"]?.number ?? -1) || t.frame0 != Int(r["frame0"]?.number ?? -1) || t.frame1 != Int(r["frame1"]?.number ?? -1)
                    || t.peakFrame != Int(r["peakFrame"]?.number ?? -1) || t.unit != r["unit"]?.string {
                    bad.append("token fields"); break
                }
                if abs(t.margin - (r["margin"]?.number ?? .nan)) > 1e-5 { bad.append("token margin"); break }
                if let c = r["confidence"]?.number, abs((t.confidence ?? .nan) - c) > 1e-9 { bad.append("token confidence"); break }
            }
            if d.transcript != ref["decoded"]?["transcript"]?.string { bad.append("transcript") }
            if (ref["decoded"]?["words"]?.array ?? []).count != d.words.count { bad.append("word count") }
            if bad.isEmpty { decodedOK += 1 } else { XCTFail("\(name) decoded: \(bad)") }
            // the engine's greedy ids are the decoded tokens
            XCTAssertEqual(d.tokens.map(\.id), heads.greedy, name)

            // word scores per preset: the max fused LLR of the word's sites
            let scorer = try scorers[ctx] ?? EngineTajweedScorer(directory: base.appendingPathComponent("model"), context: ctx)
            scorers[ctx] = scorer
            var wbad: [String] = []
            for (preset, list) in ref["words"]?.object ?? [:] {
                let req = TajweedScoreRequest(surah: Int(v["surah"]!.number!), ayah: Int(v["ayah"]!.number!),
                                              settings: try TajweedSettings.resolve(calibration: cal, remote: presets[preset], debugBuild: false),
                                              remote: presets[preset])
                let res = try scorer.score(heads: heads, req)
                for r in list.array ?? [] {
                    let w = Int(r["word"]?.number ?? -1)
                    guard w >= 0, w < res.words.count else { wbad.append("\(preset) word \(w) missing"); continue }
                    let mine = res.words[w].score
                    switch (mine, r["score"]?.number) {
                    case (nil, nil): break
                    case (let a?, let b?): if abs(a - b) > 1e-3 { wbad.append("\(preset) word \(w) \(a) != \(b)") }
                    default: wbad.append("\(preset) word \(w) presence")
                    }
                }
            }
            if wbad.isEmpty { wordsOK += 1 } else { XCTFail("\(name) words: \(wbad.prefix(4))") }
        }
        print("v4-layers decoded \(decodedOK)/\(total), word scores \(wordsOK)/\(total)")
        XCTAssertGreaterThanOrEqual(total, 48)
        XCTAssertEqual(decodedOK, total)
        XCTAssertEqual(wordsOK, total)
    }

    /// The word decision: a calibration word block's presets, the portal's word level, the app's custom threshold and
    /// its range, and the flag rule.
    func testWordSettings() throws {
        var cal = try XCTUnwrap(JSONValue(data: TajweedSettingsTests.fixture("calibration_fixture")))
        guard case .object(var top) = cal, case .object(var ctxs)? = top["contexts"], case .object(var c16)? = ctxs["c16_l64"] else {
            return XCTFail("fixture shape")
        }
        c16["word"] = .object(["status": .string("validated"), "default_preset": .string("general"), "flag_rule": .string("score >= tau"),
                               "presets": .object(["strict": .object(["tau": .number(6.5)]), "general": .object(["tau": .number(4.93)]),
                                                   "beginner": .object(["tau": .number(4.0)])]),
                               "floor": .number(2.0), "custom_range": .array([.number(2.0), .number(30)])])
        ctxs["c16_l64"] = .object(c16)
        top["contexts"] = .object(ctxs)
        cal = .object(top)
        let calibration = try TajweedCalibration(json: cal)
        let d = try TajweedSettings.resolve(calibration: calibration, remote: nil, debugBuild: false)
        XCTAssertEqual(d.word.level, "general")
        XCTAssertEqual(d.word.threshold, 4.93)
        XCTAssertEqual(d.word.flags(4.93), true, "score >= tau")
        XCTAssertEqual(d.word.flags(4.92), false)
        let portal = try TajweedSettings.resolve(calibration: calibration, remote: .object(["v": .number(1), "word": .object(["preset": .string("beginner")])]),
                                                 debugBuild: false)
        XCTAssertEqual(portal.word.threshold, 4.0)
        XCTAssertEqual(portal.word.source, .remote)
        let app = try TajweedSettings.resolve(calibration: calibration, remote: .object(["v": .number(1), "word": .object(["preset": .string("beginner")])]),
                                              app: TajweedOptions(word: .custom(7.25)), debugBuild: false)
        XCTAssertEqual(app.word.threshold, 7.25)
        XCTAssertEqual(app.word.source, .app)
        let outOfRange = try TajweedSettings.resolve(calibration: calibration, remote: .object(["v": .number(1), "word": .object(["threshold": .number(99)])]),
                                                     debugBuild: false)
        XCTAssertTrue(outOfRange.dropped.contains("remote.word"))
        XCTAssertEqual(outOfRange.word.level, "general")
        XCTAssertThrowsError(try TajweedSettings.resolve(calibration: calibration, remote: nil, app: TajweedOptions(word: .custom(1)), debugBuild: false))
        // without a word block: scores, no flags
        let none = try TajweedSettings.resolve(calibration: TajweedCalibration(data: TajweedSettingsTests.fixture("calibration_fixture")),
                                               remote: nil, debugBuild: false)
        XCTAssertNil(none.word.flags(10))
    }
}
