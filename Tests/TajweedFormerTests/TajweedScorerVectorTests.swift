import Foundation
import XCTest
@testable import TajweedFormer

/// the reference vectors through the SDK's scorer (the engine's, in
/// TajweedFormerCore): flags identical at every site, madd, qalqalah and gemination item, LLRs within 1e-3. The fixture
/// (release asset tajweed_scorer_fixture.tar.gz, made by make_scorer_fixture.py from the reference vectors) is
/// TAJWEED_SCORER_FIXTURE: model/ (calibration.json, tokens.txt, a test expected table), vectors.json, per vector
/// its heads (float32) and the reference verdicts per preset. The comparison is the engine's own
/// (tajweed/tests/run_vectors.py compare()).
final class TajweedScorerVectorTests: XCTestCase {
    static func close(_ a: JSONValue?, _ b: JSONValue?, _ tol: Double) -> Bool {
        switch (a, b) {
        case (.number(let x)?, .number(let y)?): return abs(x - y) <= tol
        case (.null?, .null?), (nil, nil), (.null?, nil), (nil, .null?): return true
        default: return a == b
        }
    }

    /// run_vectors.py compare(): the mismatches between the SDK's verdict JSON and the reference's.
    static func compare(_ c: JSONValue, _ r: JSONValue) -> [String] {
        var bad: [String] = []
        if c["path"] != r["path"] { return ["path differs"] }
        if c["path_edit_cost"] != r["path_edit_cost"] { bad.append("path_edit_cost") }
        for (wc, wr) in zip(c["path_forms"]?.array ?? [], r["path_forms"]?.array ?? []) {
            for k in ["pick", "L", "R", "mode", "wajh", "cross"] where wc[k] != wr[k] { bad.append("path_forms \(k)") }
        }
        let sc = c["sites"]?.array ?? [], sr = r["sites"]?.array ?? []
        guard sc.map({ $0["i"] }) == sr.map({ $0["i"] }) else { return bad + ["site windows differ"] }
        for (a, b) in zip(sc, sr) {
            let tag = "site \(b["i"]?.number.map { Int($0) } ?? -1)"
            if a["expected"] != b["expected"] { bad.append("\(tag) expected") }
            if (a["flagged"]?.bool ?? false) != (b["flagged"]?.bool ?? false) || a["class"] != b["class"] { bad.append("\(tag) verdict") }
            let pa = a["per_class"]?.object ?? [:], pb = b["per_class"]?.object ?? [:]
            guard Set(pa.keys) == Set(pb.keys) else { bad.append("\(tag) classes"); continue }
            for (cls, y) in pb {
                let x = pa[cls]!
                if x["alt"] != y["alt"] || x["alt_window"] != y["alt_window"] { bad.append("\(tag) \(cls) alt") }
                if (x["enabled"]?.bool ?? false) != (y["enabled"]?.bool ?? false) || (x["flagged"]?.bool ?? false) != (y["flagged"]?.bool ?? false) {
                    bad.append("\(tag) \(cls) enabled/flagged")
                }
                for f in ["llr_log_probs", "llr_inter1", "fused"] where !close(x[f], y[f], 1e-3) { bad.append("\(tag) \(cls) \(f)") }
                if !close(x["threshold"], y["threshold"], 1e-12) { bad.append("\(tag) \(cls) threshold") }
            }
        }
        for (part, pname) in [("madd", "ratio"), ("qalqalah", "p_burst"), ("gemination", "p_held")] {
            if (c[part] == nil) != (r[part] == nil) { bad.append("\(part) present"); continue }
            guard let ir = r[part]?["items"]?.array, let ic = c[part]?["items"]?.array else { continue }
            guard ic.map({ $0["i"] }) == ir.map({ $0["i"] }) else { bad.append("\(part) items"); continue }
            if part == "madd" && !close(c[part]?["unit_frames"], r[part]?["unit_frames"], 1e-9) { bad.append("madd unit") }
            for (a, b) in zip(ic, ir) {
                var keys = ["flagged"]
                if part == "madd" { keys += ["cls", "count", "aared_at_stop", "scoring"] }
                for k in keys where a[k] != b[k] { bad.append("\(part) \(k)") }
                if (a["reported"]?.bool ?? true) != (b["reported"]?.bool ?? true) { bad.append("\(part) reported") }
                if !close(a[pname], b[pname], 1e-5) { bad.append("\(part) \(pname)") }
            }
        }
        return bad
    }

    func testCALReferenceVectors() throws {
        guard let root = ProcessInfo.processInfo.environment["TAJWEED_SCORER_FIXTURE"] else {
            throw XCTSkip("set TAJWEED_SCORER_FIXTURE to the scorer fixture folder")
        }
        let base = URL(fileURLWithPath: root)
        let meta = try XCTUnwrap(JSONValue(data: Data(contentsOf: base.appendingPathComponent("vectors.json"))))
        let order = try XCTUnwrap(meta["head_order"]?.array).compactMap(\.string)
        let widths = try XCTUnwrap(meta["head_widths"]?.array).compactMap { $0.number.map(Int.init) }
        let rates = try XCTUnwrap(meta["head_ms"]?.array).compactMap { $0.number.map(Int.init) }
        let presets = try XCTUnwrap(meta["presets"]?.object)
        var scorers: [String: EngineTajweedScorer] = [:]
        var passed = 0, total = 0
        var tally: [String: (Int, Int)] = [:]
        for v in try XCTUnwrap(meta["vectors"]?.array) {
            let ctx = try XCTUnwrap(v["context"]?.string)
            let scorer = try scorers[ctx] ?? EngineTajweedScorer(directory: base.appendingPathComponent("model"), context: ctx)
            scorers[ctx] = scorer
            let n40 = Int(v["n40"]!.number!), n20 = Int(v["n20"]!.number!)
            let raw = try Data(contentsOf: base.appendingPathComponent(v["heads"]!.string!))
            let floats: [Float] = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            var chunk: [String: [Float]] = [:], o = 0
            for (i, name) in order.enumerated() {
                let n = (rates[i] == 40 ? n40 : n20) * widths[i]
                chunk[name] = Array(floats[o..<o + n])
                o += n
            }
            XCTAssertEqual(o, floats.count)
            let heads = TajweedHeads(chunk: chunk)
            XCTAssertEqual(heads.n20, n20)
            for (preset, file) in try XCTUnwrap(v["refs"]?.object) {
                let ref = try XCTUnwrap(JSONValue(data: Data(contentsOf: base.appendingPathComponent(file.string!))))
                let req = TajweedScoreRequest(surah: Int(v["surah"]!.number!), ayah: Int(v["ayah"]!.number!),
                                              settings: try TajweedSettings.resolve(calibration: TajweedCalibration(data:
                                                  Data(contentsOf: base.appendingPathComponent("model/calibration.json"))),
                                                  remote: presets[preset], debugBuild: false),
                                              remote: presets[preset])
                let res = try scorer.score(heads: heads, req)
                XCTAssertEqual(res.settingsDifferences, [], "the engine resolves the settings as the SDK does (API 2)")
                let got = try XCTUnwrap(JSONValue(data: Data(res.json.utf8)))
                let bad = Self.compare(got, ref)
                total += 1
                if bad.isEmpty { passed += 1 }
                let t = tally["\(ctx) \(preset)", default: (0, 0)]
                tally["\(ctx) \(preset)"] = (t.0 + (bad.isEmpty ? 1 : 0), t.1 + 1)
                XCTAssertTrue(bad.isEmpty, "\(ctx) \(v["name"]?.string ?? "?") \(preset): \(bad.prefix(5))")
                // the typed sites agree with the JSON
                XCTAssertEqual(res.sites.filter(\.flagged).count > 0, (got["sites"]?.array ?? []).contains { $0["flagged"]?.bool == true })
            }
        }
        for (k, t) in tally.sorted(by: { $0.key < $1.key }) { print("v4-scorer \(k): \(t.0)/\(t.1)") }
        print("v4-scorer CAL vectors: \(passed)/\(total)")
        XCTAssertEqual(passed, total)
        XCTAssertGreaterThanOrEqual(total, 96)
    }
}
