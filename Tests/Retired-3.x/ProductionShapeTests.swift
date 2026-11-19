import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// The shape of a production build of model 4.0.0 for SDK 3.0, one that signs NO tolerance (revision v4.0-2026-11-11,
/// build d841ec6c...): signed with the release key, a version, no tolerance of either kind, self-test expected files
/// with tokens only. It is a fixture of that shape, not the build an SDK gets: which build that is, is the signed
/// config's to say, and a build id changes with every signing (a later build of 4.0.0 has the same files and signs a
/// `golden_raw_tolerance`; `GoldenAndDenyTests` takes that tolerance's numbers through the promotion pipeline).
///
/// The fixture (`Fixtures/production`) is that build's own manifest.json, byte for byte, and two files of its
/// self-test set (`selftest/selftest.json`, `selftest/expected_c16_l64.json`), checked here against the SHA-256 the
/// manifest signs for them. The model's weights and clips are not in the repository. So these tests cover: the
/// manifest's acceptance by the SDK with the key compiled into it (what `client.model()` does first), which files an
/// iPhone or a Mac downloads from it, the self-test set as the SDK reads it, the golden test's verdict and what it
/// keeps when the build signs no tolerance. They do not run the model: `scripts/prove-on-mac.sh` does, on a Mac.
final class ProductionShapeTests: XCTestCase {
    static let build = "d841ec6c57bbcc69799f30d68f6306aa33d5c1bd"
    static let contexts = ["c16_l64", "c24_l72", "c24_l256", "c8_l64"]

    static func fixture(_ path: String) throws -> Data {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "production", withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: dir.appendingPathComponent(path))
    }

    static var releaseKey: ManifestVerifier { ManifestVerifier(trustedKeys: [ManifestVerifier.quranLabPublicKey], requireSignature: true) }

    static func manifest() throws -> ModelManifest {
        try ModelManifest.accept(try fixture("manifest.json"), verifier: releaseKey, build: build, version: "4.0.0")
    }

    func testTheProductionManifestIsAcceptedWithTheReleaseKey() throws {
        XCTAssertEqual(ConfigVerifier.keyID(ManifestVerifier.quranLabPublicKey), "660a07197c4808da")
        let data = try Self.fixture("manifest.json")
        XCTAssertEqual(String(Manifest30VectorTests.sha256(data).prefix(40)), Self.build, "the fixture is the production manifest, byte for byte")
        // as the Client accepts it: the build and the version the signed config names, the key compiled into the SDK
        let m = try Self.manifest()
        XCTAssertEqual(m.version, "4.0.0")
        XCTAssertEqual(m.build, Self.build)
        XCTAssertEqual(m.revision, "v4.0-2026-11-11")
        XCTAssertEqual(m.minSDKVersion, "3.0.0")
        XCTAssertEqual(m.modelID, "v4.0")
        XCTAssertEqual(m.contexts, Self.contexts)
        XCTAssertEqual(m.defaultContext, "c16_l64")
        XCTAssertEqual(m.files.count, 82)
        // this build signs no tolerance of either kind, so its accelerator builds are judged on identical tokens (the
        // next build of 4.0.0 signs a `golden_raw_tolerance`, and the golden stage then judges by it)
        XCTAssertNil(m.goldenToleranceField)
        XCTAssertNil(m.goldenRawField)
        XCTAssertFalse(m.goldenToleranceSigned)
        XCTAssertFalse(m.goldenRawSigned)
        XCTAssertTrue(m.goldenRaw.isEmpty)
        XCTAssertNil(m.rawTolerance(build: "coreml"))
        XCTAssertNil(m.rawTolerance(build: "coreml-compact"))
        XCTAssertEqual(m.tokensOnlyBuilds, [])
        // a folder opened without a config takes it too
        XCTAssertNoThrow(try ModelManifest.accept(data, verifier: Self.releaseKey))
        // and it is refused for what it is not
        XCTAssertThrowsError(try ModelManifest.accept(data, verifier: Self.releaseKey, build: String(repeating: "0", count: 40), version: "4.0.0")) {
            XCTAssertEqual(Manifest30VectorTests.code($0), "checksum_mismatch", "another build than the config names")
        }
        XCTAssertThrowsError(try ModelManifest.accept(data, verifier: Self.releaseKey, build: Self.build, version: "4.0.1")) {
            XCTAssertEqual(Manifest30VectorTests.code($0), "model_invalid", "another version than the config names")
        }
        XCTAssertThrowsError(try ModelManifest.accept(data, verifier: Self.releaseKey, sdkVersion: "2.0.3")) {
            XCTAssertEqual(Manifest30VectorTests.code($0), "model_incompatible", "it needs SDK 3.0.0")
        }
        let other = ManifestVerifier(trustedKeys: [Curve25519.Signing.PrivateKey().publicKey.rawRepresentation], requireSignature: true)
        XCTAssertThrowsError(try ModelManifest.accept(data, verifier: other)) {
            XCTAssertEqual(Manifest30VectorTests.code($0), "signature_invalid", "only the release key")
        }
        var changed = String(decoding: data, as: UTF8.self)
        changed = changed.replacingOccurrences(of: "\"v4.0-2026-11-11\"", with: "\"v4.0-2026-11-12\"")
        XCTAssertThrowsError(try ModelManifest.accept(Data(changed.utf8), verifier: Self.releaseKey)) {
            XCTAssertEqual(Manifest30VectorTests.code($0), "signature_invalid", "a changed header value")
        }
    }

    /// What an iPhone or a Mac downloads from the production build: the CPU set of a context first, then (iOS 18,
    /// macOS 15) the CoreML build with its keep table and the self-test set; the reference table never by itself.
    func testWhatAnAppleDeviceDownloadsFromTheProductionBuild() throws {
        let m = try Self.manifest()
        let cpuBytes: [String: Int64] = ["c16_l64": 55_526_553, "c24_l72": 55_625_740, "c24_l256": 55_638_843, "c8_l64": 55_427_720]
        for ctx in Self.contexts {
            let cpu = DownloadProfile(context: ctx, coreML: false).cpuFiles(m)
            XCTAssertEqual(Set(cpu.map(\.localPath)), ["tokens.txt", "calibration.json", "layers.zfw", "frontend.zfw", "\(ctx)/frames.zfw",
                                                       "\(ctx)/model_engine2.onnx.zfg", "\(ctx)/model_engine2.onnx.zfg.bin"], ctx)
            XCTAssertEqual(DownloadProfile.bytes(cpu), cpuBytes[ctx], "\(ctx): the first download")
            XCTAssertTrue(DownloadProfile(context: ctx, coreML: false).appleFiles(m).isEmpty)
        }
        let appleBytes: [String: [Int64]] = ["c16_l64": [120_554_409, 54_985_769], "c24_l72": [120_554_733, 54_986_093],
                                             "c24_l256": [120_554_858, 54_986_218]]
        for (ctx, bytes) in appleBytes {
            for (i, compact) in [false, true].enumerated() {
                let profile = DownloadProfile(context: ctx, coreML: true, compact: compact)
                let apple = profile.appleFiles(m)
                let role = compact ? "coreml-compact" : "coreml"
                XCTAssertEqual(apple.count, 13, "\(ctx) \(role): the package, the keep table, the self-test set")
                XCTAssertEqual(apple.filter { $0.role == role }.count, 5)
                XCTAssertEqual(apple.filter { $0.role == "coreml-keeps" }.map(\.localPath), ["coreml/\(ctx)/keeps.bin"])
                XCTAssertEqual(Set(apple.filter { $0.role == "selftest" }.map(\.localPath)),
                               ["selftest/selftest.json", "selftest/expected_\(ctx).json", "selftest/Husary_001001.s16", "selftest/Abdul_001001.s16",
                                "selftest/Saood_001001.s16", "selftest/Husary_112001.s16", "selftest/Husary_112001_vsub2.s16"])
                XCTAssertEqual(DownloadProfile.bytes(apple), bytes[i], "\(ctx) \(role)")
                // the program comes as a delta against the CPU weights already on the device
                let delta = try XCTUnwrap(profile.programDelta(m), "\(ctx) \(role)")
                XCTAssertEqual(delta.delta.size, compact ? 1_717_685 : 76_101_680)
                XCTAssertEqual(delta.program.localPath, "\(role)/tajweedformer_v4.mlmodelc/weights/weight.bin")
            }
        }
        // c8_l64 has no CoreML build: the exact CPU engine runs it everywhere
        XCTAssertTrue(DownloadProfile(context: "c8_l64", coreML: true).appleFiles(m).isEmpty)
        XCTAssertTrue(DownloadProfile(context: "c8_l64", coreML: true, compact: true).appleFiles(m).isEmpty)
        // the reference table is data the app asks for: listed, optional, in no profile
        let reference = m.files(role: "reference")
        XCTAssertEqual(reference.map(\.localPath), ["expected_tj3.zfx"])
        XCTAssertEqual(reference.first?.need, .optional)
        for ctx in Self.contexts {
            XCTAssertFalse(DownloadProfile(context: ctx, coreML: true).files(m).contains { $0.role == "reference" }, ctx)
        }
    }

    /// What a device fetches for the Neural Engine when the app names no build: the fp16 CoreML build (its package,
    /// the context's keep table, the self-test set), with the program as its delta against the CPU weights already on
    /// the device. Nothing of the compact build, which is fetched only for a Session whose backend names
    /// `coreml-compact`. The first download (`prefetch`, `client.model()`) is the CPU set whatever the build.
    func testTheDefaultAcceleratorDownloadIsTheFp16Build() throws {
        let m = try Self.manifest()
        XCTAssertEqual(TajweedSessionOptions().backend, .auto)
        XCTAssertNil(TajweedModel.namedCompact(.auto), "a Session that names no build gets the fp16 one")
        XCTAssertNil(TajweedModel.namedCompact(.cpu))
        XCTAssertEqual(TajweedModel.namedCompact(.coremlCompact), true, "the compact build, by name")
        XCTAssertFalse(DownloadProfile(context: "c16_l64").compact, "a profile that names no build is the fp16 one")
        // per context: every file, and what is downloaded when the program comes as its delta
        let compact: [String: (whole: Int64, fetched: Int64)] = ["c16_l64": (54_985_769, 2_807_802), "c24_l72": (54_986_093, 2_808_126),
                                                                 "c24_l256": (54_986_218, 2_808_251)]
        let fp16: [String: (whole: Int64, fetched: Int64)] = ["c16_l64": (120_554_409, 77_186_293), "c24_l72": (120_554_733, 77_186_617),
                                                              "c24_l256": (120_554_858, 77_186_742)]
        for (isCompact, want) in [(true, compact), (false, fp16)] {
            let role = isCompact ? "coreml-compact" : "coreml"
            for (ctx, bytes) in want {
                let profile = DownloadProfile(context: ctx, coreML: true, compact: isCompact)
                let files = profile.appleFiles(m)
                var roles: [String: Int] = [:]
                for f in files { roles[f.role, default: 0] += 1 }
                XCTAssertEqual(roles, [role: 5, "coreml-keeps": 1, "selftest": 7], "\(role) \(ctx)")
                XCTAssertFalse(files.contains { $0.role.hasPrefix("correction") }, "no correction")
                let other = isCompact ? "coreml/tajweedformer_v4.mlmodelc/" : "coreml-compact/tajweedformer_v4.mlmodelc/"
                XCTAssertFalse(files.contains { $0.localPath.hasPrefix(other) }, "\(role) \(ctx): nothing of the other build")
                XCTAssertEqual(DownloadProfile.bytes(files), bytes.whole, "\(role) \(ctx): every file")
                let delta = try XCTUnwrap(profile.programDelta(m), "\(role) \(ctx)")
                XCTAssertEqual(DownloadProfile.bytes(files) - delta.program.size + delta.delta.size, bytes.fetched, "\(role) \(ctx): with the delta")
                // installing a build deletes no file of the other build
                XCTAssertFalse(profile.otherBuildFiles(m).contains { $0.role == "coreml" || $0.role == "coreml-compact" })
            }
        }
        // the first download of a device is the CPU set: 55,526,553 bytes at c16_l64, with either build to follow
        XCTAssertEqual(DownloadProfile.bytes(DownloadProfile(context: "c16_l64", coreML: false).cpuFiles(m)), 55_526_553)
        XCTAssertEqual(DownloadProfile(context: "c16_l64", coreML: true, compact: true).cpuFiles(m).map(\.localPath),
                       DownloadProfile(context: "c16_l64", coreML: true, compact: false).cpuFiles(m).map(\.localPath))
        // by default the Neural Engine's build adds 77.2 MB to it; the compact build, by name, adds 2.8 MB
        XCTAssertEqual(fp16["c16_l64"]?.fetched, 77_186_293)
        XCTAssertEqual(compact["c16_l64"]?.fetched, 2_807_802)
    }

    /// The self-test set of the production build: the expected file holds tokens only, and that is all the SDK reads.
    func testTheSelfTestSetHasTokensOnly() throws {
        let m = try Self.manifest()
        let list = try Self.fixture("selftest/selftest.json"), expected = try Self.fixture("selftest/expected_c16_l64.json")
        // the two fixture files are the production build's: the manifest signs these hashes
        XCTAssertEqual(Manifest30VectorTests.sha256(list), m.file(local: "selftest/selftest.json")?.localSHA256)
        XCTAssertEqual(Manifest30VectorTests.sha256(expected), m.file(local: "selftest/expected_c16_l64.json")?.localSHA256)
        let e = try XCTUnwrap(JSONSerialization.jsonObject(with: expected) as? [String: Any])
        XCTAssertEqual(Set(e.keys), ["format", "context", "engine", "clips"])
        let clips = try XCTUnwrap(e["clips"] as? [String: [String: Any]])
        XCTAssertEqual(clips.count, 5)
        for (id, c) in clips { XCTAssertEqual(Set(c.keys), ["chunks", "tokens"], "\(id): tokens only, no sites, words or presets") }

        // a folder with the two files and clips of the listed lengths (the audio itself is not in the repository)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tf-prod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("selftest"), withIntermediateDirectories: true)
        try list.write(to: dir.appendingPathComponent("selftest/selftest.json"))
        try expected.write(to: dir.appendingPathComponent("selftest/expected_c16_l64.json"))
        let listed = try XCTUnwrap((JSONSerialization.jsonObject(with: list) as? [String: Any])?["clips"] as? [[String: Any]])
        for c in listed {
            let file = try XCTUnwrap(c["file"] as? String), samples = try XCTUnwrap(c["samples"] as? Int)
            try Data(count: 2 * samples).write(to: dir.appendingPathComponent("selftest/\(file)"))
        }
        let set = try XCTUnwrap(SelfTestSet.load(dir, context: "c16_l64"))
        XCTAssertEqual(set.clips.map(\.id), ["Husary_001001", "Abdul_001001", "Saood_001001", "Husary_112001", "Husary_112001_vsub2"])
        XCTAssertEqual(set.clips.map(\.planted), [false, false, false, false, true], "the planted clip's tokens do not count in the golden test")
        XCTAssertEqual(set.clips.map(\.samples.count), [81_920, 69_381, 43_546, 93_205, 94_229])
        XCTAssertEqual(set.clips.map(\.mustDecode), [true, true, true, false, false])
        for c in set.clips {
            XCTAssertEqual(set.expected[c.id], clips[c.id]?["tokens"] as? [Int], c.id)
        }
        XCTAssertEqual(set.expected["Husary_001001"]?.count, 21)
        XCTAssertEqual(set.expected["Husary_112001_vsub2"]?.count, 16)
        // a context whose expected file is not on the device has no set: the SDK's own clips stand in
        XCTAssertNil(SelfTestSet.load(dir, context: "c24_l72"))
    }

    /// The Model's sample clips are the folder's self-test clips once they are on the device, from the same tokens-only
    /// files (the bundled test folder's set has that shape too).
    func testTheSampleClipsComeFromTheFoldersSelfTestSet() async throws {
        let server = try Fixtures.v4mini().appendingPathComponent("server")
        let m = try ModelManifest.read(server)
        let verifier = ManifestVerifier(trustedKeys: [try Fixtures.v4miniKey()], requireSignature: true)
        // the CPU set alone: the SDK's own three clips
        let bare = Fixtures.storage().appendingPathComponent("model")
        _ = try await ModelInstaller(source: DirectoryFileSource(root: server)).install(m, profile: DownloadProfile(context: "c16_l64", coreML: false), into: bare)
        let without = TajweedModel(try ModelFolder.open(directory: bare, verifier: verifier), client: nil)
        XCTAssertEqual(without.sampleClips.map(\.name), ["Abdul_112002", "Husary_001003", "Saood_112002"])
        // with the accelerator's files (which bring the self-test set): the folder's clips, with their kinds
        let full = Fixtures.storage().appendingPathComponent("model")
        _ = try await ModelInstaller(source: DirectoryFileSource(root: server)).install(m, profile: DownloadProfile(context: "c16_l64", coreML: true), into: full)
        let with = TajweedModel(try ModelFolder.open(directory: full, verifier: verifier), client: nil)
        XCTAssertEqual(with.sampleClips.map(\.name), ["Husary_001001", "Husary_112001", "Husary_112001_planted"])
        XCTAssertEqual(with.sampleClips.map(\.kind), ["clean", "clean", "planted"])
        XCTAssertTrue(with.sampleClips.allSatisfy { $0.durationMs == 100 })
    }

    // MARK: the golden test without a tolerance

    static func clip(_ id: String, clean: Bool = true, expected: [Int]?, cpu: [Int], accelerator: [Int], shift: Float = 0.25) -> GoldenRaw.Clip {
        let c = Vectors30.logProbs(cpu)
        // the accelerator's values away from the CPU's by `shift` on every token but the top one
        let a = Vectors30.logProbs(accelerator).map { $0 < -1 ? $0 + shift : $0 }
        let frames20 = 2 * cpu.count
        let gemCPU = [Float](repeating: 0, count: frames20 * 2).enumerated().map { $0.offset % 2 == 0 ? Float(0.9) : Float(0.1) }
        let gemAccelerator = gemCPU.enumerated().map { $0.offset % 2 == 0 ? Float(0.8) : Float(0.2) }
        return GoldenRaw.Clip(id: id, clean: clean, expectedTokens: expected,
                              cpu: ["log_probs": GoldenRaw.Matrix(c, cols: 38), "gem": GoldenRaw.Matrix(gemCPU, cols: 2)],
                              accelerator: ["log_probs": GoldenRaw.Matrix(a, cols: 38), "gem": GoldenRaw.Matrix(gemAccelerator, cols: 2)])
    }

    /// A build without a tolerance (this fixture's): identical tokens decide, and the distances are measured,
    /// kept and reported all the same.
    func testWithoutAToleranceTheTokensDecideAndTheMeasuresAreKept() throws {
        let tolerance = try Self.manifest().rawTolerance(build: "coreml")
        XCTAssertNil(tolerance)
        let ids = [0, 3, 3, 0, 4, 0, 5, 5]
        // the same tokens, other values: passes, with what was measured
        let same = GoldenRaw.evaluate([Self.clip("a", expected: [3, 4, 5], cpu: ids, accelerator: ids)], tolerance: tolerance)
        XCTAssertTrue(same.pass)
        let lp = try XCTUnwrap(same.ctc["log_probs"].flatMap { $0 })
        XCTAssertEqual(lp.tokenEdits, 0)
        XCTAssertEqual(lp.lpMean, 0.25, accuracy: 1e-6)
        XCTAssertEqual(lp.lpP99, 0.25, accuracy: 1e-6)
        XCTAssertEqual(lp.frames, 8)
        XCTAssertEqual(try XCTUnwrap(same.pMean), 0.1, accuracy: 1e-6)
        XCTAssertEqual(same.attrValues, 32)
        let kept = same.divergence(tolerance: tolerance)
        XCTAssertEqual(kept.tokensExpected, 3)
        XCTAssertEqual(try XCTUnwrap(kept.heads?["log_probs"] ?? nil).lpMean ?? -1, 0.25, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(kept.heads?["attr"] ?? nil).pMean ?? -1, 0.1, accuracy: 1e-6)
        XCTAssertNil(kept.tolerance, "no tolerance to report")
        XCTAssertEqual(kept.failed, [])
        // however far the values are, the tokens decide
        let far = GoldenRaw.evaluate([Self.clip("a", expected: [3, 4, 5], cpu: ids, accelerator: ids, shift: -9)], tolerance: tolerance)
        XCTAssertTrue(far.pass)
        XCTAssertEqual(try XCTUnwrap(far.ctc["log_probs"].flatMap { $0 }).lpMean, 9, accuracy: 1e-6)
        // a planted clip's tokens do not count; its frames do
        let planted = GoldenRaw.evaluate([Self.clip("a", expected: [3, 4, 5], cpu: ids, accelerator: ids),
                                          Self.clip("p", clean: false, expected: [3, 4, 5], cpu: ids, accelerator: [0, 3, 3, 0, 4, 0, 0, 0])],
                                         tolerance: tolerance)
        XCTAssertTrue(planted.pass)
        XCTAssertEqual(try XCTUnwrap(planted.ctc["log_probs"].flatMap { $0 }).frames, 16)
        // one token differs on a clean clip: not promoted
        let differs = GoldenRaw.evaluate([Self.clip("a", expected: [3, 4, 5], cpu: ids, accelerator: [0, 3, 3, 0, 4, 0, 0, 0])], tolerance: tolerance)
        XCTAssertEqual(differs.reason, .goldenMismatch)
        XCTAssertEqual(differs.failed, ["log_probs.token_edits"])
        XCTAssertEqual(differs.divergence(tolerance: tolerance).heads?["log_probs"]??.tokenEdits, 1)
        // the CPU engine itself must give the shipped tokens
        let cpu = GoldenRaw.evaluate([Self.clip("a", expected: [3, 4], cpu: ids, accelerator: ids)], tolerance: tolerance)
        XCTAssertEqual(cpu.reason, .cpuMismatch)
        XCTAssertEqual(cpu.cpuMismatchClip, "a")
    }

    /// The measures of a golden test that passed are kept with the promotion's record, on disk, so a later launch (and
    /// `scripts/prove-on-mac.sh`) still has them; a record written before they were kept still reads.
    func testAPassedGoldenTestKeepsItsMeasuresInTheRecord() async throws {
        let ids = [0, 3, 3, 0, 4, 0, 5, 5]
        let measures = GoldenRaw.evaluate([Self.clip("a", expected: [3, 4, 5], cpu: ids, accelerator: ids)], tolerance: nil).divergence(tolerance: nil).bounded
        let h = PromotionTests.Harness()
        h.goldens.withLock { $0 = [.passed(accelerator: [0.002, 0.003], cpu: [0.008, 0.009], measures: measures)] }
        let c = h.controller()
        await c.run(h.stages())
        XCTAssertEqual(c.state, .ready)
        XCTAssertEqual(c.record?.golden, measures)
        XCTAssertEqual(c.lastGolden?.heads?["log_probs"]??.lpMean ?? -1, 0.25, accuracy: 1e-6)
        XCTAssertNil(c.lastGolden?.tolerance)
        // the next launch reads them from disk (the golden test does not run again for a promoted key)
        let later = h.controller(launch: "L2")
        XCTAssertEqual(later.lastGolden, measures)
        XCTAssertEqual(h.count("golden"), 1)
        // a golden test that reports none (a record of an earlier SDK) leaves the field out
        let old = #"{"key":"k","status":"ready","attempts":1,"failures":0,"denied":false}"#
        XCTAssertNil(try PromotionRecord.decoder().decode(PromotionRecord.self, from: Data(old.utf8)).golden)
        // a golden test that fails keeps what it measured as well, with the measure that decided it
        let differs = GoldenRaw.evaluate([Self.clip("a", expected: [3, 4, 5], cpu: ids, accelerator: [0, 3, 3, 0, 4, 0, 0, 0])], tolerance: nil)
        let divergence = differs.divergence(tolerance: nil)
        h.failures.withLock { $0[.golden] = PromotionFailure(.goldenMismatch, "the tokens differ", clip: "a", divergence: divergence) }
        let other = h.controller(revision: "r2")
        await other.run(h.stages())
        XCTAssertNotEqual(other.state, .ready)
        XCTAssertEqual(other.record?.lastStage, .golden)
        XCTAssertEqual(other.record?.golden, divergence.bounded)
        XCTAssertEqual(other.lastGolden?.failed, ["log_probs.token_edits"])
        XCTAssertEqual(other.lastGolden?.heads?["log_probs"]??.tokenEdits, 1)
    }
}
