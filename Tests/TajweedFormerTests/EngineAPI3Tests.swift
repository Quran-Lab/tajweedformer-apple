import Foundation
import XCTest
import ZipformerCore
@testable import TajweedFormer

/// The SDK against zf_tajweed.h API 3: the head bits, the open options' layout, and the decoded layer's top-2 from
/// the engine. These need only the xcframework (no model).
final class EngineAPI3Tests: XCTestCase {
    func testHeadBitsAreTheEngines() {
        XCTAssertEqual(zf_tajweed_api_version(), 3)
        let c: [(TajweedHead, Int)] = [
            (.logProbs, Int(ZF_TAJWEED_HEAD_LOG_PROBS)), (.inter1LogProbs, Int(ZF_TAJWEED_HEAD_INTER1)),
            (.inter4LogProbs, Int(ZF_TAJWEED_HEAD_INTER4)), (.idLogProbs, Int(ZF_TAJWEED_HEAD_ID)),
            (.timingLogProbs, Int(ZF_TAJWEED_HEAD_TIMING)), (.gem, Int(ZF_TAJWEED_HEAD_GEM)),
            (.tafkheem, Int(ZF_TAJWEED_HEAD_TAFKHEEM)), (.ghunna, Int(ZF_TAJWEED_HEAD_GHUNNA)),
            (.qalqalah, Int(ZF_TAJWEED_HEAD_QALQALAH)), (.face, Int(ZF_TAJWEED_HEAD_FACE)),
            (.boundary, Int(ZF_TAJWEED_HEAD_BOUNDARY)), (.conf, Int(ZF_TAJWEED_HEAD_CONF)),
        ]
        XCTAssertEqual(c.count, TajweedHead.allCases.count)
        for (h, bit) in c {
            XCTAssertEqual(Int(h.engineBit), bit, h.rawValue)
            // the engine's own name, period and width for the bit
            var ms: Int32 = 0, cols: Int32 = 0
            let name = zf_tajweed_head_info(UInt32(bit), &ms, &cols).map { String(cString: $0) }
            XCTAssertEqual(name, h.rawValue)
            XCTAssertEqual(Int(ms), h.frameMs, h.rawValue)
            XCTAssertEqual(Int(cols), h.width, h.rawValue)
        }
        XCTAssertEqual(Int(HeadSelection(TajweedHead.scorer).engineMask), Int(ZF_TAJWEED_HEADS_SCORER))
        XCTAssertEqual(Int(HeadSelection.all.engineMask), Int(ZF_TAJWEED_HEADS_ALL))
    }

    /// The mapping alone (no engine needed for the numbers): the selection, the scorer's heads and log_probs.
    func testHeadMaskMapping() {
        XCTAssertEqual(HeadSelection.default.engineMask, 0b1001_0011_0011, "log_probs, inter1, timing, gem, qalqalah, conf")
        XCTAssertEqual(HeadSelection([]).engineMask, 0b0001_0011_0011, "the scorer's heads are always kept")
        XCTAssertEqual(HeadSelection.adding([.ghunna]).engineMask, 0b1001_1011_0011)
        XCTAssertEqual(HeadSelection.all.engineMask, (1 << 12) - 1)
    }

    /// API 3 appended `no_pin`: 40 bytes on 64-bit, and the SDK only ever starts from the engine's defaults.
    func testOpenOptionsLayout() {
        XCTAssertEqual(MemoryLayout<ZfTajweedOpenOptions>.size, 40)
        let o = zf_tajweed_open_default_options()
        XCTAssertEqual(o.struct_size, MemoryLayout<ZfTajweedOpenOptions>.size)
        // the engine's default pinning: pinned on iOS (one stream on a phone), not pinned on macOS
        #if os(macOS)
        XCTAssertEqual(o.no_pin, 1)
        #else
        XCTAssertEqual(o.no_pin, 0)
        #endif
        XCTAssertEqual(o.load_engine, 1)
    }

    /// zf_tajweed_top2 through the SDK: ties go to the lower id, the runner-up is the best of the others, the margin
    /// is the engine's.
    func testTop2ComesFromTheEngine() {
        let v = TajweedHeads.vocab
        var lp = [Float](repeating: -10, count: 3 * v)
        lp[0 * v + 0] = -0.1; lp[0 * v + 5] = -2.5                 // blank first, runner-up 5
        lp[1 * v + 7] = -0.4; lp[1 * v + 3] = -0.4                 // a tie: the lower id wins, the other is the runner-up
        lp[2 * v + 37] = -0.01; lp[2 * v + 36] = -5.75
        let f = DecodedTake.top2(lp, frames: 3)
        XCTAssertEqual(f.map(\.top1), [0, 3, 37])
        XCTAssertEqual(f.map(\.runnerUp), [5, 7, 36])
        XCTAssertEqual(f[0].margin, Double(Float(-0.1) - Float(-2.5)), accuracy: 1e-6)
        XCTAssertEqual(f[1].margin, 0)
        XCTAssertEqual(f[2].top1LogProb, -0.01)
        // the decoded layer uses them
        var h = TajweedHeads(chunk: ["log_probs": lp, "conf": [Float](repeating: 3, count: 6)])
        h.append(TajweedHeads())
        let d = DecodedTake(heads: h, vocabulary: Vocabulary(symbols: (0..<v).map { "t\($0)" }, blank: 0))
        XCTAssertEqual(d.tokens.map(\.id), [3, 37])
        XCTAssertEqual(d.frames.count, 3)
    }

    // MARK: top-K

    /// A Swift reference of the documented order: highest value first, equal values by the lower id (stable argsort).
    static func argsort(_ row: [Float]) -> [Int] { row.indices.sorted { row[$0] != row[$1] ? row[$0] > row[$1] : $0 < $1 } }

    func testTopKBounds() throws {
        let lp = [Float](repeating: -3.6, count: 2 * 38)
        let names = (0..<38).map { "t\($0)" }
        XCTAssertThrowsError(try TajweedRanking.rank(lp, head: .logProbs, k: 0, names: names))
        XCTAssertThrowsError(try TajweedRanking.rank(lp, head: .logProbs, k: 39, names: names))
        XCTAssertNoThrow(try TajweedRanking.rank(lp, head: .logProbs, k: 1, names: names))
        XCTAssertNoThrow(try TajweedRanking.rank(lp, head: .logProbs, k: 38, names: names))
        XCTAssertThrowsError(try TajweedRanking.rank([0.5, 0.5], head: .gem, k: 3, names: ["single", "held"]), "gem has 2 classes")
        XCTAssertThrowsError(try TajweedRanking.rank([0.1, 0.2], head: .conf, k: 1, names: ["truthful"]), "a logit has no ranking")
        XCTAssertThrowsError(try TajweedRanking.rank([], head: .inter4LogProbs, k: 2, names: names), "a head not computed")
    }

    /// Ties go to the lower id; margins are to the next rank, 0 for the last of the row; k = 2 is top-2.
    func testTopKTiesMarginsAndTop2() throws {
        var lp = [Float](repeating: -9, count: 38)
        lp[7] = -0.5; lp[3] = -0.5; lp[20] = -1.25
        let r = try TajweedRanking.rank(lp, head: .logProbs, k: 4, names: (0..<38).map { "t\($0)" })
        let e = r.entries(frame: 0)
        XCTAssertEqual(e.map(\.id), [3, 7, 20, 0])
        XCTAssertEqual(e.map(\.name), ["t3", "t7", "t20", "t0"])
        XCTAssertEqual(e[0].margin, 0)
        XCTAssertEqual(e[2].margin, -1.25 - -9)
        XCTAssertEqual(e[3].margin, 0, "the next rank (t1) has the same value")
        let full = try TajweedRanking.rank(lp, head: .logProbs, k: 38, names: (0..<38).map { "t\($0)" })
        XCTAssertEqual(full.entries(frame: 0).last?.margin, 0, "the last entry of the row")
        let two = try TajweedRanking.rank(lp, head: .logProbs, k: 2, names: (0..<38).map { "t\($0)" })
        let top2 = DecodedTake.top2(lp, frames: 1)[0]
        XCTAssertEqual(two.entries(frame: 0).map(\.id), [top2.top1, top2.runnerUp])
    }

    /// k = 38 is the full stable argsort, on rows with ties and on a class head with its names.
    func testFullRankingIsTheArgsort() throws {
        var g = SystemRandomNumberGenerator()
        let rows = 5
        let lp: [Float] = (0..<(rows * 38)).map { _ in Float(Int.random(in: -40...0, using: &g)) / 4 }   // many ties
        let r = try TajweedRanking.rank(lp, head: .timingLogProbs, k: 38, names: (0..<38).map { "t\($0)" })
        XCTAssertEqual(r.frames, rows)
        for t in 0..<rows {
            XCTAssertEqual(r.entries(frame: t).map(\.id), Self.argsort(Array(lp[(t * 38)..<((t + 1) * 38)])))
        }
        let ghunna: [Float] = [0.1, 0.4, 0.1, 0.3, 0.1]
        let c = try TajweedRanking.rank(ghunna, head: .ghunna, k: 5,
                                        names: TajweedHead.ghunna.classNames(vocabulary: Vocabulary(symbols: ["x"], blank: 0)))
        XCTAssertEqual(c.entries(frame: 0).map(\.name), ["plain", "ikhfa", "none", "geminate", "idgham"])
        XCTAssertEqual(c.entries(frame: 0).map(\.id), Self.argsort(ghunna))
    }
}
