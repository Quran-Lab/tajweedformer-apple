import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5: the build's self-test set (the model's sample clips) comes with the CPU set, best effort, so
/// `model.sampleClips` on Apple is the build's own set, as on Android, C and the web. Up to 4.0.4 only an accelerator
/// build brought it: on a CPU-only build (TajweedFormer 4.1.x) Apple's sample clips were always the three the SDK carries,
/// which a feedback engine's live check cannot compare with the build's engine vectors (sdk.quranlab.ai/docs/engine).
final class SampleClipsTests: XCTestCase {
    static let base = URL(string: "https://cdn.quranlab.ai/models/Quran-Lab/tajweedformer-v4/\(String(repeating: "f", count: 40))/sdk/v4.1/")!

    /// A CPU-only build (no Core ML file, as 4.1.x ships): stored path, context, role, need, size.
    static let layout: [(path: String, context: String, role: String, need: ModelManifest.Need, size: Int)] = [
        ("tokens.txt.qle", "*", "tokens", .required, 2_000),
        ("calibration.json.qle", "*", "calibration", .required, 3_000),
        ("layers.zfw.qle", "*", "weights", .required, 40_000),
        ("frontend.zfw.qle", "*", "frontend", .required, 4_000),
        ("c16_l128/model_engine2.onnx.zfg.qle", "c16_l128", "graph", .required, 5_000),
        ("c16_l128/model_engine2.onnx.zfg.bin.qle", "c16_l128", "graph-data", .required, 6_000),
        ("c16_l128/frames.zfw.qle", "c16_l128", "frames", .required, 7_000),
        ("c8_l256/model_engine2.onnx.zfg.qle", "c8_l256", "graph", .required, 5_000),
        ("selftest/selftest.json.qle", "*", "selftest", .optional, 3_000),
        ("selftest/Husary_001001.s16.qle", "*", "selftest", .optional, 20_000),
        ("selftest/expected_c16_l128.json.qle", "c16_l128", "selftest", .optional, 1_200),
        ("selftest/expected_c16_l64.json.qle", "c16_l64", "selftest", .optional, 1_200),
        ("selftest/expected_c8_l256.json.qle", "c8_l256", "selftest", .optional, 1_200),
    ]
    static let selfTest = Set(layout.filter { $0.role == "selftest" }.map(\.path))

    static let stored: [String: Data] = Dictionary(uniqueKeysWithValues: layout.enumerated().map { k, f in
        (f.path, Data((0..<f.size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ k) }))
    })

    /// The default context is c16_l64; the device runs c16_l128.
    static func manifest() -> ModelManifest {
        let files = layout.map { f -> ModelManifest.File in
            let sha = Data(SHA256.hash(data: stored[f.path]!)).hex
            return ModelManifest.File(path: f.path, size: Int64(f.size), sha256: sha, platforms: ["*"], context: f.context, role: f.role,
                                      need: f.need, encoding: "qle1",
                                      decoded: .init(path: String(f.path.dropLast(4)), size: Int64(f.size - 20), sha256: sha))
        }
        var m = ModelManifest(modelID: "v4.1", revision: "sample-clips", version: "4.1.5", minSDKVersion: "4.0.0",
                              tokensSHA256: String(repeating: "0", count: 64), defaultContext: "c16_l64",
                              contexts: ["c16_l64", "c16_l128", "c8_l256"], files: files)
        m.encryption = .init(keyID: "d14d9aeeeecb3a238cb86c41a5e8b0c2", root: 1)
        return m
    }

    static func path(_ seen: StubProtocol.Seen) -> String? {
        guard let at = seen.url.path.range(of: "/sdk/v4.1/") else { return nil }
        return String(seen.url.path[at.upperBound...])
    }

    /// The stand-in model host; `missing`: stored paths it answers 404 for.
    static func serve(missing: Set<String> = []) {
        StubProtocol.reset { seen in
            guard let p = path(seen), !missing.contains(p), let d = stored[p] else { return StubProtocol.Reply(status: 404) }
            return ModelDownloadTests.served(seen, data: d, etag: "\"sample-clips\"")
        }
    }

    static func install() async throws -> (report: InstallReport, core: ModelDownloadTests.CoreStandIn, folder: URL) {
        let folder = CloudFixtures.storage().appendingPathComponent("models/v4.1/.download-sample-clips", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let client = CDNClient(http: HTTPClient(session: StubProtocol.session()), base: URL(string: "https://cdn.quranlab.ai/models")!,
                               auth: .fixed(key: "qlk_v1_test", token: "qlt_test"), verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
        var installer = ModelInstaller(source: client.source(ModelID("v4.1", repository: "Quran-Lab/tajweedformer-v4"), revision: "sample-clips",
                                                             base: base),
                                       retryPauses: [0, 0, 0, 0, 0])
        let core = ModelDownloadTests.CoreStandIn()
        installer.install = core.install(in: folder)
        let report = try await installer.install(manifest(), profile: DownloadProfile(context: "c16_l128", coreML: false), into: folder)
        return (report, core, folder)
    }

    override func tearDown() { StubProtocol.reset { _ in .down } }

    /// The profile: the set is never in the CPU set (a folder installed before 4.0.5 stays usable), and the sample
    /// files are selftest.json, the clips and the expected tokens of the device's context and of the default context.
    func testTheSampleFilesAreTheSetForThisContextAndTheDefaultOne() {
        let m = Self.manifest(), p = DownloadProfile(context: "c16_l128", coreML: false)
        XCTAssertFalse(p.cpuFiles(m).contains { $0.role == "selftest" })
        XCTAssertEqual(Set(p.sampleFiles(m).map(\.localPath)), ["selftest/selftest.json", "selftest/Husary_001001.s16",
                                                                 "selftest/expected_c16_l128.json", "selftest/expected_c16_l64.json"])
        XCTAssertEqual(p.appleFiles(m), [], "a CPU-only build has no accelerator files")
    }

    /// A fresh install of a CPU-only build brings the sample files with the CPU set, each asked once, and installed.
    func testACpuOnlyInstallBringsTheSampleClips() async throws {
        Self.serve()
        let (report, core, folder) = try await Self.install()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let asked = StubProtocol.seen.compactMap(Self.path)
        let want = Self.selfTest.subtracting(["selftest/expected_c8_l256.json.qle"])
        XCTAssertEqual(Set(asked).intersection(Self.selfTest), want)
        for p in want { XCTAssertEqual(asked.filter { $0 == p }.count, 1, p) }
        XCTAssertTrue(Set(core.installed.withLock { $0 }).isSuperset(of: want))
        XCTAssertGreaterThan(report.profileBytes, DownloadProfile.bytes(DownloadProfile(context: "c16_l128", coreML: false).cpuFiles(Self.manifest())))
    }

    /// Best effort: a host that has none of the set still installs the CPU set, with no error.
    func testAMissingSetLeavesTheInstallWhole() async throws {
        Self.serve(missing: Self.selfTest)
        let (report, core, folder) = try await Self.install()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        XCTAssertNil(report.appleUnavailable)
        let cpu = DownloadProfile(context: "c16_l128", coreML: false).cpuFiles(Self.manifest()).map(\.path)
        XCTAssertTrue(Set(core.installed.withLock { $0 }).isSuperset(of: cpu))
        XCTAssertTrue(Set(core.installed.withLock { $0 }).isDisjoint(with: Self.selfTest))
        XCTAssertEqual(report.profileBytes, DownloadProfile.bytes(DownloadProfile(context: "c16_l128", coreML: false).cpuFiles(Self.manifest())))
    }
}
