import Foundation
import XCTest
@testable import TajweedFormer

/// c8_l64: selectable like any other context. Until 3.0.1 the SDK carried a list of CPU-only contexts with c8_l64 in
/// it, and the Neural Engine was never chosen for it whatever the manifest listed. From 3.0.2 the manifest decides,
/// also for c8 (SPEC 5.4): a build serves c8_l64 when the signed tolerance names it or a keep table is listed for it,
/// and c8_l64 runs on the CPU engine when neither is there. The c8 model files do not exist yet, so the folder here is
/// the synthetic test folder with c16_l64's files copied to c8_l64 (selection logic only); it lists a c8_l64 keep
/// table, and the tests take it away where they need a manifest that gives c8 no accelerator.
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

    func open(_ dir: URL) throws -> ModelFolder {
        try Fixtures.manifest(for: dir).write(to: dir)
        return try ModelFolder.open(directory: dir, verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
    }

    func testC8IsSelectableAndTheDefaultStaysC16() throws {
        let model = try open(folder())
        XCTAssertTrue(model.contexts.contains(Self.c8))
        XCTAssertEqual(model.contexts.first, "c16_l64")
        XCTAssertEqual(model.manifest.defaultContext, "c16_l64")
        XCTAssertTrue(model.usableContexts.contains(Self.c8))
        XCTAssertNotNil(model.engineDirectory(context: Self.c8))

        func context(config: String? = nil, app: String? = nil) throws -> String {
            try RemoteConfig.context(app: app, inference: config, contexts: model.manifest.contexts,
                                     defaultContext: model.manifest.defaultContext).context
        }
        XCTAssertEqual(try context(app: Self.c8), Self.c8, "chosen by the app")
        XCTAssertEqual(try context(config: Self.c8), Self.c8, "chosen in the signed config (inference.context)")
        XCTAssertEqual(try context(config: "c16_l64", app: Self.c8), Self.c8, "the app's choice wins")
        XCTAssertEqual(try context(), "c16_l64", "the default")
    }

    /// Changed in 3.0.2 (was: the Neural Engine is never chosen for c8, by the SDK's own list, whatever is asked for
    /// and whatever the manifest lists). The manifest decides: the Neural Engine is considered for c8_l64 where a
    /// build serves it (here by a listed keep table) and not where none does; the exact backend never considers it.
    func testTheManifestDecidesWhetherTheNeuralEngineIsConsideredForC8() throws {
        let with = try open(folder())
        let bare = try folder()
        try fm.removeItem(at: bare.appendingPathComponent("coreml/\(Self.c8)"))
        let without = try open(bare)
        for backend: TajweedRecognizer.Backend in [.automatic, .neuralEngine] {
            XCTAssertTrue(TajweedRecognizer.mayUseAccelerator(requested: backend, model: with, context: Self.c8), backend.rawValue)
            XCTAssertFalse(TajweedRecognizer.mayUseAccelerator(requested: backend, model: without, context: Self.c8), backend.rawValue)
            XCTAssertTrue(TajweedRecognizer.mayUseAccelerator(requested: backend, model: without, context: "c16_l64"), backend.rawValue)
        }
        for model in [with, without] {
            XCTAssertFalse(TajweedRecognizer.mayUseAccelerator(requested: .exact, model: model, context: Self.c8))
            XCTAssertFalse(TajweedRecognizer.mayUseAccelerator(requested: .exact, model: model, context: "c16_l64"))
            XCTAssertFalse(TajweedRecognizer.mayUseAccelerator(requested: .automatic, model: model, context: "c99_l1"), "not a context of the model")
        }
    }

    /// Changed in 3.0.2 (was: a folder cannot hand c8 a CoreML build, even with a verified c8 keep table). The
    /// manifest decides: with a keep table listed for c8_l64 the folder gives c8 its build; without one, and without
    /// a signed key for it, it gives none and c8 runs on the CPU engine.
    func testTheManifestDecidesWhetherAFolderHandsC8ACoreMLBuild() throws {
        let model = try open(folder())
        XCTAssertNotNil(model.coreML(context: "c16_l64"), "the same folder gives c16_l64 its build")
        XCTAssertTrue(model.verifiedFiles.contains("coreml/\(Self.c8)/keeps.bin"), "the c8 keep table is there and verified")
        XCTAssertNotNil(model.coreML(context: Self.c8), "a keep table is listed for c8_l64: the build serves it")

        let bare = try folder()
        try fm.removeItem(at: bare.appendingPathComponent("coreml/\(Self.c8)"))
        let without = try open(bare)
        XCTAssertTrue(without.usableContexts.contains(Self.c8), "the CPU engine runs c8_l64")
        XCTAssertNil(without.coreML(context: Self.c8), "no keep table and no signed key for c8_l64: no build")
        XCTAssertNotNil(without.coreML(context: "c16_l64"), "c16_l64 keeps its build")
    }

    /// Changed in 3.0.2 (was: the c8 download is the CPU set only, whatever the manifest lists). With a keep table
    /// listed for c8_l64 its accelerator files are part of the profile; without one the download is the CPU set.
    func testTheC8DownloadFollowsTheManifest() throws {
        let dir = try folder()
        let m = try Fixtures.manifest(for: dir)
        let c8 = DownloadProfile(context: Self.c8, coreML: true)
        XCTAssertTrue(c8.coreML, "no context is CPU only by the SDK's own list")
        let apple = Set(c8.appleFiles(m).map(\.path))
        XCTAssertTrue(apple.contains("coreml/c8_l64/keeps.bin"), "\(apple)")
        XCTAssertTrue(apple.contains { $0.hasPrefix("coreml/tajweedformer_v4.mlmodelc/") }, "\(apple)")
        XCTAssertFalse(apple.contains("coreml/c16_l64/keeps.bin"), "another context's keep table is not part of it")
        let paths = Set(c8.cpuFiles(m).map(\.path))
        XCTAssertTrue(paths.contains("c8_l64/model_engine2.onnx.zfg"))
        XCTAssertTrue(paths.contains("layers.zfw"))
        XCTAssertFalse(paths.contains { $0.hasPrefix("c16_l64/") || $0.hasPrefix("coreml") })
        XCTAssertFalse(DownloadProfile(context: "c16_l64", coreML: true).appleFiles(m).isEmpty, "c16_l64 keeps its CoreML files")

        // the same folder without the c8 keep table: nothing of a build is fetched for c8
        try fm.removeItem(at: dir.appendingPathComponent("coreml/\(Self.c8)"))
        let bare = try Fixtures.manifest(for: dir)
        XCTAssertTrue(bare.contexts.contains(Self.c8))
        XCTAssertTrue(DownloadProfile(context: Self.c8, coreML: true).appleFiles(bare).isEmpty, "no keep table and no signed key for c8_l64")
        XCTAssertEqual(Set(DownloadProfile(context: Self.c8, coreML: true).files(bare).map(\.path)), paths, "the CPU set only")
        XCTAssertFalse(DownloadProfile(context: "c16_l64", coreML: true).appleFiles(bare).isEmpty)
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

    /// The exact CPU engine's greedy tokens for the bundled clip `Saood_112002` in c8_l64 of model 4.0.0: this test's
    /// own expectation (until 3.0.1 a table in the SDK's sources, which only this file read).
    static let saood112002Tokens = [2, 31, 24, 34, 27, 33, 15, 31, 25, 31, 9]

    /// Changed in 3.0.2 (was: the SDK's table has the c8 entry). The clip is bundled, and the SDK's sources carry no
    /// table of expected tokens: a model's folder says what its clips decode to.
    func testTheClipIsBundledAndTheSourcesCarryNoExpectedTokens() throws {
        XCTAssertEqual(Self.saood112002Tokens.count, 11)
        XCTAssertTrue(try SelfTestClips.load().clips.contains { $0.name == "Saood_112002" }, "the clip is in the SDK")
        let sources = Fixtures.repo.appendingPathComponent("Sources/TajweedFormer")
        guard let e = fm.enumerator(atPath: sources.path) else { throw XCTSkip("the sources are not in this checkout") }
        var read = 0
        while let rel = e.nextObject() as? String {
            guard rel.hasSuffix(".swift"), let text = try? String(contentsOf: sources.appendingPathComponent(rel), encoding: .utf8) else { continue }
            read += 1
            XCTAssertFalse(text.contains("saood112002Tokens"), "\(rel) names the table")
            XCTAssertNil(text.range(of: #"\[2, 31, 24, 34, 27"#, options: .regularExpression), "\(rel) holds the clip's tokens")
        }
        XCTAssertGreaterThan(read, 40, "the SDK's sources were read")
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
        XCTAssertEqual(engine.take.greedy, Self.saood112002Tokens)
    }
}
