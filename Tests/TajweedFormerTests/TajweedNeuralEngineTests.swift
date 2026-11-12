import CoreML
import Foundation
import XCTest
@testable import TajweedFormer

/// The V4 CoreML backend through the SDK's own host code (zf_fbank features, keeps table, front/back, every head)
/// on the packages built by tajweedformer-coreml's v4-coreml workflow. TAJWEED_COREML is a folder with one
/// subfolder per context: `<context>/package.mlpackage`, `<context>/keeps.bin` and `<context>/basmala.json`
/// (each Basmala clip's greedy token ids from the fp32 ONNX of the same context, the workflow's parity output).
/// Must pass: every Basmala clip decodes, token for token, as the fp32 ONNX; every head finite and of its shape.
/// A hosted runner has no Neural Engine, so this checks the host contract, not the ANE's numerics.
final class TajweedNeuralEngineTests: XCTestCase {
    func testBasmalaThroughTheHostContract() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { throw XCTSkip("needs macOS 15 / iOS 18") }
        guard let root = ProcessInfo.processInfo.environment["TAJWEED_COREML"] else {
            throw XCTSkip("set TAJWEED_COREML to the V4 CoreML test folder")
        }
        let base = URL(fileURLWithPath: root)
        let contexts = try FileManager.default.contentsOfDirectory(atPath: base.path).filter {
            FileManager.default.fileExists(atPath: base.appendingPathComponent("\($0)/keeps.bin").path)
        }.sorted()
        XCTAssertFalse(contexts.isEmpty)
        for ctx in contexts {
            let dir = base.appendingPathComponent(ctx)
            let compiled = try await MLModel.compileModel(at: dir.appendingPathComponent("package.mlpackage"))
            let expect = try XCTUnwrap(JSONValue(data: Data(contentsOf: dir.appendingPathComponent("basmala.json")))?.object)
            for units in [MLComputeUnits.cpuOnly, .cpuAndNeuralEngine] {
                let e = try TajweedNeuralEngine(model: compiled, keeps: dir.appendingPathComponent("keeps.bin"), computeUnits: units)
                XCTAssertEqual(e.ctcFrames * 4, e.advance)
                for (clip, ids) in expect.sorted(by: { $0.key < $1.key }) {
                    e.reset()
                    let s = try Fixtures.samples(clip)
                    _ = try s.withUnsafeBufferPointer { (p) throws(RecognizerError) in try e.push(p) }
                    _ = try e.finish()
                    let h = e.take
                    XCTAssertGreaterThan(h.n40, 0)
                    XCTAssertTrue(h.isFinite, "\(ctx) \(clip): non-finite heads")
                    for (name, width, ms) in HeadsBuffer.layout {
                        XCTAssertEqual(h[name].count, (ms == 40 ? h.n40 : h.n20) * width, "\(ctx) \(clip) \(name)")
                    }
                    let want = (ids.array ?? []).compactMap { $0.number.map(Int.init) }
                    XCTAssertFalse(h.greedy.isEmpty, "\(ctx) \(clip): blank decode")
                    XCTAssertEqual(h.greedy, want, "\(ctx) \(clip) [\(units.rawValue)]: tokens differ from the fp32 ONNX")
                    let ms = e.chunkSeconds.sorted()
                    print("v4-coreml \(ctx) \(clip) units \(units.rawValue): \(h.greedy.count) tokens, \(e.chunkSeconds.count) chunks,"
                          + " median chunk \(String(format: "%.1f", 1000 * ms[ms.count / 2])) ms")
                }
            }
        }
    }
}
