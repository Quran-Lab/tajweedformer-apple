import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// The V4 folder in manifest format 3 (folder layout v2): the signed text, the Apple download profile, the resumable
/// gzip install (the CPU set first, then the accelerator files), and what makes a folder (or its CoreML files) unusable. The folder is
/// Fixtures/v4mini, written by scripts/make_test_folder_v4.py with the format 3 rules.
final class TajweedModelTests: XCTestCase {
    func server() throws -> URL { try Fixtures.v4mini().appendingPathComponent("server") }

    func manifest() throws -> ModelManifest {
        try ModelManifest.parse(Data(contentsOf: server().appendingPathComponent("manifest.json")))
    }

    func verifier() throws -> ManifestVerifier { ManifestVerifier(trustedKeys: [try Fixtures.v4miniKey()], requireSignature: true) }

    func scratch() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tf-model-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The SDK's signed text is the writer's, byte for byte, and the signature verifies; any change breaks it.
    func testSignedTextMatchesTheWriter() throws {
        let m = try manifest()
        let want = try Data(contentsOf: Fixtures.v4mini().appendingPathComponent("signed_text.txt"))
        XCTAssertEqual(String(decoding: m.signedMessage, as: UTF8.self), String(decoding: want, as: UTF8.self))
        XCTAssertNoThrow(try verifier().verifySignature(m, required: true))
        XCTAssertEqual(m.contexts, ["c16_l64", "c24_l72"])
        XCTAssertEqual(m.engineFormat, 3)
        // the JSON the SDK writes back keeps the signature valid
        let again = try ModelManifest.parse(m.jsonData())
        XCTAssertEqual(again.signedMessage, m.signedMessage)
        XCTAssertNoThrow(try verifier().verifySignature(again, required: true))
        // another revision (or any other field) is another text
        let other = ModelManifest(modelID: m.modelID, revision: "v4.0-other", tokensSHA256: m.tokensSHA256,
                                  defaultContext: m.defaultContext, contexts: m.contexts, files: m.files, signature: m.signature)
        XCTAssertThrowsError(try verifier().verifySignature(other, required: true))
        // unsigned, when a signature is required
        var unsigned = m
        unsigned.signature = nil
        XCTAssertThrowsError(try verifier().verifySignature(unsigned, required: true))
    }

    func testOnlyFormat3Loads() throws {
        let f2 = Data(#"{"format": 2, "model_id": "v3.2", "files": []}"#.utf8)
        XCTAssertThrowsError(try ModelManifest.parse(f2)) { e in
            guard case .manifestInvalid(let why)? = e as? RecognizerError else { return XCTFail("\(e)") }
            XCTAssertTrue(why.contains("format 2"), why)
        }
        var o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: server().appendingPathComponent("manifest.json"))) as? [String: Any])
        o["min_sdk_version"] = "9.0.0"
        let newer = try ModelManifest.parse(JSONSerialization.data(withJSONObject: o))
        XCTAssertThrowsError(try newer.checkCompatible())
        o["min_sdk_version"] = "2.0.0"
        o["engine_format"] = 2
        let old = try ModelManifest.parse(JSONSerialization.data(withJSONObject: o))
        XCTAssertThrowsError(try old.checkCompatible())
    }

    /// A manifest that marks the self-test set required (the 2.0.1 revision's folder does): the first install still
    /// fetches the bare CPU set, and the self-test set still comes with the accelerator.
    func testARequiredSelfTestSetIsNotPartOfTheCPUSet() throws {
        var o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: server().appendingPathComponent("manifest.json"))) as? [String: Any])
        let files = try XCTUnwrap(o["files"] as? [[String: Any]])
        o["files"] = files.map { (f: [String: Any]) -> [String: Any] in
            var g = f
            if (g["role"] as? String) == "selftest" { g["need"] = "required" }
            return g
        }
        let m = try ModelManifest.parse(JSONSerialization.data(withJSONObject: o))
        XCTAssertTrue(m.files.contains { $0.role == "selftest" && $0.need == .required })
        let p = DownloadProfile(context: "c16_l64", coreML: true)
        XCTAssertFalse(p.cpuFiles(m).contains { $0.role == "selftest" })
        XCTAssertTrue(p.appleFiles(m).contains { $0.role == "selftest" })
        XCTAssertFalse(DownloadProfile(context: "c16_l64", coreML: false).cpuFiles(m).contains { $0.role == "selftest" })
    }

    /// The Apple profile: the CPU set of the context first (the only thing a first install fetches), and later, from
    /// the promotion pipeline, the package, the context's keep table and the self-test set; never a correction (not
    /// used since 2.0.1), a native, NPU or other-context file. Without CoreML (older OS), the CPU set alone.
    func testAppleProfile() throws {
        let m = try manifest()
        let p = DownloadProfile(context: "c16_l64", coreML: true)
        XCTAssertEqual(Set(p.cpuFiles(m).map(\.localPath)), ["tokens.txt", "calibration.json", "expected_tj3.zfx", "layers.zfw",
                                                             "frontend.zfw", "c16_l64/model_engine2.onnx.zfg",
                                                             "c16_l64/model_engine2.onnx.zfg.bin", "c16_l64/frames.zfw"])
        XCTAssertEqual(Set(p.appleFiles(m).map(\.localPath)), ["coreml/tajweedformer_v4.mlmodelc/weights/weight.bin",
                                                               "coreml/tajweedformer_v4.mlmodelc/model.mil",
                                                               "coreml/tajweedformer_v4.mlmodelc/coremldata.bin",
                                                               "coreml/c16_l64/keeps.bin",
                                                               "selftest/selftest.json", "selftest/Husary_001001.s16",
                                                               "selftest/Husary_112001.s16", "selftest/Husary_112001_planted.s16", "selftest/expected_c16_l64.json"])
        let kept = Set(p.files(m).map(\.localPath))
        XCTAssertTrue(kept.contains("layers.zfw"), "the CPU weights are always downloaded")
        XCTAssertFalse(kept.contains("coreml/engine.zfs"), "no correction")
        XCTAssertFalse(kept.contains { $0.hasPrefix("c24_l72/") || $0.hasPrefix("npu/") || $0.hasSuffix("model_engine2.onnx") })
        XCTAssertFalse(kept.contains { $0.hasPrefix("coreml-compact/") }, "never both CoreML builds")
        XCTAssertTrue(p.otherBuildFiles(m).contains { $0.localPath == "coreml/engine.zfs" }, "a correction left by 2.0.0 is deleted")
        // the compact build: its own package, the same keep table
        let compact = DownloadProfile(context: "c16_l64", coreML: true, compact: true)
        XCTAssertEqual(Set(compact.appleFiles(m).map(\.localPath)), ["coreml-compact/tajweedformer_v4.mlmodelc/weights/weight.bin",
                                                                     "coreml-compact/tajweedformer_v4.mlmodelc/model.mil",
                                                                     "coreml-compact/tajweedformer_v4.mlmodelc/coremldata.bin",
                                                                     "coreml/c16_l64/keeps.bin",
                                                                     "selftest/selftest.json", "selftest/Husary_001001.s16",
                                                                     "selftest/Husary_112001.s16", "selftest/Husary_112001_planted.s16", "selftest/expected_c16_l64.json"])
        XCTAssertLessThan(DownloadProfile.bytes(compact.appleFiles(m)), DownloadProfile.bytes(p.appleFiles(m)) + 1_000_000)
        let cpu = DownloadProfile(context: "c16_l64", coreML: false)
        XCTAssertTrue(cpu.appleFiles(m).isEmpty)
        XCTAssertLessThan(DownloadProfile.bytes(p.files(m)), DownloadProfile.bytes(m.files))
    }

    /// The install: the CPU set, then the profile's accelerator files, gzip ones inflated and checked; no correction.
    /// Then the folder opens, verified, with c16_l64 usable on the CPU and its CoreML build found; c24_l72 comes later
    /// on demand.
    func testInstallVerifyAndAnotherContext() async throws {
        let m = try manifest()
        let dir = scratch()
        let installer = ModelInstaller(source: DirectoryFileSource(root: try server()), rangeSize: 64 << 10)
        let r = try await installer.install(m, profile: DownloadProfile(context: "c16_l64", coreML: true), into: dir)
        XCTAssertNil(r.appleUnavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("coreml/engine.zfs").path), "no correction")
        XCTAssertGreaterThan(r.downloadedBytes, 0)
        let leftovers = FileManager.default.enumerator(atPath: dir.path)!.compactMap { $0 as? String }.filter { $0.hasSuffix(".part") || $0.hasSuffix(".gz") }
        XCTAssertEqual(leftovers, [], "only decoded files are kept")
        let model = try TajweedModel.open(directory: dir, verifier: verifier())
        XCTAssertEqual(model.usableContexts, ["c16_l64"])
        let cm = try XCTUnwrap(model.coreML(context: "c16_l64"))
        XCTAssertEqual(cm.frontFunction, "front_c16_l64")
        XCTAssertEqual(cm.backFunction, "back_c16_l64")
        XCTAssertTrue(cm.package.path.hasSuffix("coreml/tajweedformer_v4.mlmodelc"))
        XCTAssertNil(model.coreML(context: "c24_l72"), "no keep table for c24_l72 yet")
        let decoded = try Fixtures.v4mini().appendingPathComponent("decoded")
        for f in ["layers.zfw", "c16_l64/frames.zfw", "coreml/tajweedformer_v4.mlmodelc/weights/weight.bin"] {
            XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(f)), try Data(contentsOf: decoded.appendingPathComponent(f)), f)
        }
        // another context: only its files
        let r2 = try await installer.install(m, profile: DownloadProfile(context: "c24_l72", coreML: true), into: dir)
        let small = DownloadProfile.bytes(m.files.filter { $0.context == "c24_l72" && ($0.need == .required || $0.role == "coreml-keeps" || $0.role == "selftest") })
        XCTAssertEqual(r2.downloadedBytes, small)
        let both = try TajweedModel.open(directory: dir, verifier: verifier())
        XCTAssertEqual(Set(both.usableContexts), ["c16_l64", "c24_l72"])
        XCTAssertNotNil(both.coreML(context: "c24_l72"))
    }

    /// Switching to the compact build installs its package and deletes the default one (never both on disk); the
    /// model then finds the compact build.
    func testSwitchingBuildsDeletesTheOther() async throws {
        let m = try manifest()
        let dir = scratch()
        let installer = ModelInstaller(source: DirectoryFileSource(root: try server()))
        _ = try await installer.install(m, profile: DownloadProfile(context: "c16_l64", coreML: true), into: dir)
        let fp16 = dir.appendingPathComponent("coreml/tajweedformer_v4.mlmodelc")
        let int8 = dir.appendingPathComponent("coreml-compact/tajweedformer_v4.mlmodelc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fp16.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: int8.path))
        XCTAssertEqual(try TajweedModel.open(directory: dir, verifier: verifier()).coreML(context: "c16_l64")?.compact, false)
        _ = try await installer.install(m, profile: DownloadProfile(context: "c16_l64", coreML: true, compact: true), into: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fp16.path), "the default build is deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("coreml/engine.zfs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: int8.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("coreml/c16_l64/keeps.bin").path), "the keep table stays")
        let model = try TajweedModel.open(directory: dir, verifier: verifier())
        let build = try XCTUnwrap(model.coreML(context: "c16_l64"))
        XCTAssertTrue(build.compact)
        XCTAssertEqual(build.frontFunction, "front_c16_l64")
    }

    /// A source that stops after `limit` bytes per call: the first install fails offline and leaves `.part` files; the
    /// next one resumes from them and fetches only the rest.
    struct FlakySource: ModelFileSource {
        let inner: DirectoryFileSource
        let budget: Locked<Int64>
        func bytes(_ path: String, lower: Int64, upper: Int64, size: Int64) async throws(RecognizerError) -> Data {
            let n = upper - lower + 1
            let ok = budget.withLock { b -> Bool in
                guard b >= n else { return false }
                b -= n
                return true
            }
            guard ok else { throw .offline("cut") }
            return try await inner.bytes(path, lower: lower, upper: upper, size: size)
        }
    }

    func testDownloadsResumeAcrossLaunches() async throws {
        let m = try manifest()
        let dir = scratch()
        let profile = DownloadProfile(context: "c16_l64", coreML: false)
        let total = DownloadProfile.bytes(profile.cpuFiles(m))
        let flaky = FlakySource(inner: DirectoryFileSource(root: try server()), budget: Locked(total / 2))
        do throws(RecognizerError) {
            _ = try await ModelInstaller(source: flaky, rangeSize: 1024).install(m, profile: profile, into: dir)
            XCTFail("the cut source finished")
        } catch {
            guard case .offline = error else { return XCTFail("\(error)") }
        }
        let fresh = ModelInstaller(source: DirectoryFileSource(root: try server()), rangeSize: 1024)
        let r = try await fresh.install(m, profile: profile, into: dir)
        XCTAssertLessThan(r.downloadedBytes, total, "the second launch fetched only what was missing")
        XCTAssertNoThrow(try TajweedModel.open(directory: dir, verifier: verifier()))
    }

    /// Stored bytes that do not match: both the part and the decoded file go, after one retry.
    struct CorruptSource: ModelFileSource {
        let inner: DirectoryFileSource
        let calls = Locked(0)
        func bytes(_ path: String, lower: Int64, upper: Int64, size: Int64) async throws(RecognizerError) -> Data {
            var d = try await inner.bytes(path, lower: lower, upper: upper, size: size)
            if path == "layers.zfw.gz" {
                calls.withLock { $0 += 1 }
                if !d.isEmpty { d[d.startIndex] ^= 0xff }
            }
            return d
        }
    }

    func testAMismatchDeletesBothAndRetriesOnce() async throws {
        let m = try manifest()
        let dir = scratch()
        let src = CorruptSource(inner: DirectoryFileSource(root: try server()))
        do throws(RecognizerError) {
            _ = try await ModelInstaller(source: src, rangeSize: 1 << 20).install(m, profile: DownloadProfile(context: "c16_l64", coreML: false), into: dir)
            XCTFail("a corrupt file was taken")
        } catch {
            XCTAssertEqual(error, .checksumMismatch(file: "layers.zfw.gz"))
        }
        XCTAssertEqual(src.calls.withLock { $0 }, 2, "one retry")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("layers.zfw.gz.part").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("layers.zfw").path))
    }

    /// A CPU file that does not match refuses the folder; a CoreML file that does not match, or a file in the package
    /// the manifest does not list, only turns CoreML off.
    func testWhatAFolderRefuses() async throws {
        let m = try manifest()
        let dir = scratch()
        _ = try await ModelInstaller(source: DirectoryFileSource(root: try server())).install(m, profile: DownloadProfile(context: "c16_l64", coreML: true), into: dir)
        try Data("extra".utf8).write(to: dir.appendingPathComponent("coreml/tajweedformer_v4.mlmodelc/extra.bin"))
        let a = try TajweedModel.open(directory: dir, verifier: verifier())
        XCTAssertNotNil(a.coreMLProblem)
        XCTAssertNil(a.coreML(context: "c16_l64"))
        XCTAssertEqual(a.usableContexts, ["c16_l64"], "the CPU engine still runs")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("coreml/tajweedformer_v4.mlmodelc/extra.bin"))
        try Data("tampered".utf8).write(to: dir.appendingPathComponent("c16_l64/frames.zfw"))
        XCTAssertThrowsError(try TajweedModel.open(directory: dir, verifier: verifier())) { e in
            XCTAssertEqual(e as? RecognizerError, .checksumMismatch(file: "c16_l64/frames.zfw"))
        }
    }

    /// gzip as the writer makes it (level 9, mtime 0) inflates to the decoded bytes, and a corrupt one is refused.
    func testGzipInflate() throws {
        let src = try server().appendingPathComponent("expected_tj3.zfx.gz")
        let out = scratch().appendingPathComponent("x")
        let r = try Gzip.inflate(src, to: out)
        let want = try Data(contentsOf: Fixtures.v4mini().appendingPathComponent("decoded/expected_tj3.zfx"))
        XCTAssertEqual(try Data(contentsOf: out), want)
        XCTAssertEqual(r.size, Int64(want.count))
        var bad = try Data(contentsOf: src)
        bad[bad.count - 6] ^= 0x01   // the trailer's size
        let badURL = scratch().appendingPathComponent("bad.gz")
        try bad.write(to: badURL)
        XCTAssertThrowsError(try Gzip.inflate(badURL, to: out))
    }
}
