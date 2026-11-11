import Foundation
import XCTest
@testable import TajweedFormer

/// The decoded layer against the cross-SDK vectors: every frame's top-1 and runner-up, every greedy token's frames, peak, margin and confidence, and
/// the words. Needs TAJWEED_SCORER_FIXTURE (the heads) and TAJWEED_LAYERS_VECTORS (layers_vectors.json). The vectors'
/// per-word scores belonged to the 2.x scorer, which SDK 3.0.0 does not have.
final class LayersVectorTests: XCTestCase {
    func testDecodedLayer() throws {
        guard let root = ProcessInfo.processInfo.environment["TAJWEED_SCORER_FIXTURE"],
              let vpath = ProcessInfo.processInfo.environment["TAJWEED_LAYERS_VECTORS"] else {
            throw XCTSkip("set TAJWEED_SCORER_FIXTURE and TAJWEED_LAYERS_VECTORS")
        }
        let base = URL(fileURLWithPath: root)
        let meta = try XCTUnwrap(JSONValue(data: Data(contentsOf: base.appendingPathComponent("vectors.json"))))
        let order = try XCTUnwrap(meta["head_order"]?.array).compactMap(\.string)
        let widths = try XCTUnwrap(meta["head_widths"]?.array).compactMap { $0.number.map(Int.init) }
        let rates = try XCTUnwrap(meta["head_ms"]?.array).compactMap { $0.number.map(Int.init) }
        let want = try XCTUnwrap(JSONValue(data: Data(contentsOf: URL(fileURLWithPath: vpath))))
        let byName = Dictionary((want["vectors"]?.array ?? []).compactMap { v in v["name"]?.string.map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
        let vocab = try Vocabulary(tokensFile: base.appendingPathComponent("model/tokens.txt"))
        var decodedOK = 0, total = 0
        for v in try XCTUnwrap(meta["vectors"]?.array) {
            let name = try XCTUnwrap(v["name"]?.string)
            guard let ref = byName[name] else { continue }
            let n40 = Int(v["n40"]!.number!), n20 = Int(v["n20"]!.number!)
            let raw = try Data(contentsOf: base.appendingPathComponent(v["heads"]!.string!))
            let floats: [Float] = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            var chunk: [String: [Float]] = [:], o = 0
            for (i, h) in order.enumerated() {
                let n = (rates[i] == 40 ? n40 : n20) * widths[i]
                chunk[h] = Array(floats[o..<o + n])
                o += n
            }
            let heads = HeadsBuffer(chunk: chunk)
            total += 1
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
        }
        print("v4-layers decoded \(decodedOK)/\(total)")
        XCTAssertGreaterThanOrEqual(total, 48)
        XCTAssertEqual(decodedOK, total)
    }
}
