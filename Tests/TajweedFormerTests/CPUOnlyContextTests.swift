import Foundation
import XCTest
@testable import TajweedFormer

/// c8_l64: selectable like any other context, and never on the Neural Engine. The c8 model files do not exist yet, so
/// the folder here is the synthetic test folder with c16_l64's files copied to c8_l64 (selection logic only), and it
/// deliberately lists a c8_l64 keep table, so that a manifest which wrongly ships CoreML files for it is covered too.
final class CPUOnlyContextTests: XCTestCase {
    static let c8 = "c8_l64"
    let fm = FileManager.default

    func folder(withC8: Bool = true) throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("tf-c8-\(UUID().uuidString)")
        try fm.copyItem(at: Fixtures.v4mini().appendingPathComponent("decoded"), to: dir)
        guard withC8 else { return dir }
        try fm.copyItem(at: dir.appendingPathComponent("c16_l64"), to: dir.appendingPathComponent(Self.c8))
        try fm.copyItem(at: dir.appendingPathComponent("coreml/c16_l64"), to: dir.appendingPathComponent("coreml/\(Self.c8)"))
        let url = dir.appendingPathComponent("calibration.json")
        var cal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var contexts = try XCTUnwrap(cal["contexts"] as? [String: Any])
        contexts[Self.c8] = contexts["c16_l64"]
        cal["contexts"] = contexts
        try JSONSerialization.data(withJSONObject: cal).write(to: url)
        return dir
    }

    func open(_ dir: URL) throws -> TajweedModel {
        try Fixtures.manifest(for: dir).write(to: dir)
        return try TajweedModel.open(directory: dir, verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
    }

    func testC8IsSelectableAndTheDefaultStaysC16() throws {
        let model = try open(folder())
        XCTAssertTrue(model.contexts.contains(Self.c8))
        XCTAssertEqual(model.contexts.first, "c16_l64")
        XCTAssertEqual(model.manifest.defaultContext, "c16_l64")
        XCTAssertTrue(model.usableContexts.contains(Self.c8))
        XCTAssertNotNil(model.engineDirectory(context: Self.c8))

        func context(remote: String? = nil, app: String? = nil) throws -> String {
            try TajweedSettings.resolve(calibration: model.calibration, remote: remote.flatMap { JSONValue(data: Data($0.utf8)) },
                                        app: TajweedOptions(context: app), debugBuild: false, backend: .int8).context
        }
        XCTAssertEqual(try context(app: Self.c8), Self.c8, "chosen by the app")
        XCTAssertEqual(try context(remote: #"{"v":1,"context":"c8_l64"}"#), Self.c8, "chosen in the portal")
        XCTAssertEqual(try context(), "c16_l64", "the default")
    }

    func testTheNeuralEngineIsNeverChosenForC8() {
        for backend: TajweedRecognizer.Backend in [.automatic, .neuralEngine, .exact] {
            XCTAssertFalse(TajweedRecognizer.mayUseAccelerator(requested: backend, context: Self.c8), backend.rawValue)
        }
        XCTAssertTrue(TajweedRecognizer.mayUseAccelerator(requested: .automatic, context: "c16_l64"))
        XCTAssertTrue(TajweedRecognizer.mayUseAccelerator(requested: .neuralEngine, context: "c16_l64"))
        XCTAssertFalse(TajweedRecognizer.mayUseAccelerator(requested: .exact, context: "c16_l64"))
    }

    func testAFolderCannotHandC8ACoreMLBuild() throws {
        let model = try open(folder())
        XCTAssertNotNil(model.coreML(context: "c16_l64"), "the same folder gives c16_l64 its build")
        XCTAssertTrue(model.verifiedFiles.contains("coreml/\(Self.c8)/keeps.bin"), "the c8 keep table is there and verified")
        XCTAssertNil(model.coreML(context: Self.c8))
    }

    func testTheC8DownloadIsTheCPUSetOnly() throws {
        let dir = try folder()
        let m = try Fixtures.manifest(for: dir)
        let c8 = DownloadProfile(context: Self.c8, coreML: true)
        XCTAssertFalse(c8.coreML)
        XCTAssertTrue(c8.appleFiles(m).isEmpty)
        let paths = Set(c8.cpuFiles(m).map(\.path))
        XCTAssertTrue(paths.contains("c8_l64/model_engine2.onnx.zfg"))
        XCTAssertTrue(paths.contains("layers.zfw"))
        XCTAssertFalse(paths.contains { $0.hasPrefix("c16_l64/") || $0.hasPrefix("coreml") })
        XCTAssertFalse(DownloadProfile(context: "c16_l64", coreML: true).appleFiles(m).isEmpty, "c16_l64 keeps its CoreML files")
    }

    func testInstallingC8LeavesTheCoreMLBuildOfOtherContexts() async throws {
        let src = try folder()
        let m = try Fixtures.manifest(for: src)
        let dst = try folder()
        try fm.removeItem(at: dst.appendingPathComponent(Self.c8))
        let keep = dst.appendingPathComponent("coreml/c16_l64/keeps.bin")
        let before = try Data(contentsOf: keep)
        let report = try await ModelInstaller(source: DirectoryFileSource(root: src))
            .install(m, profile: DownloadProfile(context: Self.c8, coreML: true), into: dst)
        XCTAssertNil(report.appleUnavailable)
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("c8_l64/model_engine2.onnx.zfg").path))
        XCTAssertEqual(try Data(contentsOf: keep), before)
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("coreml/tajweedformer_v4.mlmodelc/model.mil").path))
    }

    func testTheSelfTestExpectationForC8() throws {
        XCTAssertEqual(SelfTestClips.saood112002Tokens[Self.c8], [2, 31, 24, 34, 27, 33, 15, 31, 25, 31, 9])
        XCTAssertEqual(SelfTestClips.saood112002Tokens[Self.c8]?.count, 11)
        XCTAssertTrue(try SelfTestClips.load().clips.contains { $0.name == "Saood_112002" }, "the clip is in the SDK")
    }

    /// Real inference: needs a folder that ships c8_l64 (TAJWEED_V4_FOLDER), so it skips until those files exist.
    func testC8SelfTestTokensOnTheExactEngine() throws {
        let model = try TajweedConformanceTests.folder()
        guard model.isUsable(context: Self.c8) else { throw XCTSkip("TAJWEED_V4_FOLDER has no c8_l64 files") }
        let clip = try XCTUnwrap(try SelfTestClips.load().clips.first { $0.name == "Saood_112002" })
        let engine = try TajweedExactEngine(directory: model.directory, context: Self.c8)
        XCTAssertEqual(engine.chunkMs, 160)
        _ = try clip.samples.withUnsafeBufferPointer { (p) throws(RecognizerError) in try engine.push(p) }
        _ = try engine.finish()
        XCTAssertEqual(engine.take.greedy, SelfTestClips.saood112002Tokens[Self.c8])
    }
}
