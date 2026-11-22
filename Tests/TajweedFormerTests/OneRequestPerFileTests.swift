import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.2, SPEC 16.7: one request per model file. A fresh install of the default context's CPU
/// set and the Core ML build of a stand-in build with the file list of manifest_40.json and the sizes the CDN logs of
/// 2026-11-21 give for the release build (the weights 54.8 MB, the Core ML package's weights 130 MB, three context
/// files of 1.4 MB in all, four small files of 0.4 MB; the keep table and the self-test clip small),
/// from the stand-in server through the SDK's installer and CDN client: the model-file requests and their Range
/// headers are counted. Then the same install with the transfer of the largest file cut once: one resume, from the
/// byte the cut left, with `If-Range`. The same test on 4.0.1 (cf13697, its default ranges of 8 MiB) counted 32
/// requests for this install.
final class OneRequestPerFileTests: XCTestCase {
    static let base = URL(string: "https://cdn.quranlab.ai/models/Quran-Lab/tajweedformer-v4/\(String(repeating: "e", count: 40))/sdk/v4.0/")!
    static let etag = "\"release-1\""
    static let largest = "coreml/tajweedformer_v4.mlmodelc/weights/weight.bin.qle"

    /// The build's files: stored path, context, role, size.
    static let layout: [(path: String, context: String, role: String, size: Int)] = [
        ("tokens.txt.qle", "*", "tokens", 100_000),
        ("calibration.json.qle", "*", "calibration", 10_000),
        ("layers.zfw.qle", "*", "weights", 54_800_000),
        ("frontend.zfw.qle", "*", "frontend", 200_000),
        ("expected_tj3.zfx.qle", "*", "reference", 90_000),
        ("c16_l64/model_engine2.onnx.zfg.qle", "c16_l64", "graph", 300_000),
        ("c16_l64/model_engine2.onnx.zfg.bin.qle", "c16_l64", "graph-data", 900_000),
        ("c16_l64/frames.zfw.qle", "c16_l64", "frames", 200_000),
        (largest, "*", "coreml", 130_000_000),
        ("c16_l64/keeps.bin.qle", "c16_l64", "coreml-keeps", 20_000),
        ("selftest/clip01.wav.qle", "*", "selftest", 100_000),
    ]

    /// Bytes that stand for each file's ciphertext: a random MiB, each copy of it marked with its place.
    static let stored: [String: Data] = {
        var g = SystemRandomNumberGenerator()
        var block = Data(count: 1 << 20)
        block.withUnsafeMutableBytes { raw in
            for i in 0..<(raw.count / 8) { raw.storeBytes(of: g.next() as UInt64, toByteOffset: i * 8, as: UInt64.self) }
        }
        var out: [String: Data] = [:]
        for (k, f) in layout.enumerated() {
            var d = Data(capacity: f.size)
            var n: UInt64 = UInt64(k) << 32
            while d.count < f.size {
                var piece = block.prefix(min(block.count, f.size - d.count))
                withUnsafeBytes(of: n) { mark in piece.replaceSubrange(piece.startIndex..<(piece.startIndex + min(8, piece.count)), with: mark.prefix(piece.count)) }
                d.append(piece)
                n += 1
            }
            out[f.path] = d
        }
        return out
    }()

    static func manifest() -> ModelManifest {
        let files = layout.map { f -> ModelManifest.File in
            let sha = Data(SHA256.hash(data: stored[f.path]!)).hex
            let apple = DownloadProfile.appleRoles.contains(f.role) || f.role == "selftest"
            return ModelManifest.File(path: f.path, size: Int64(f.size), sha256: sha, platforms: apple ? ["apple"] : ["*"], context: f.context,
                                      role: f.role, encoding: "qle1",
                                      decoded: .init(path: String(f.path.dropLast(4)), size: Int64(f.size - 20), sha256: sha))
        }
        var m = ModelManifest(modelID: "v4.0", revision: "one-request", version: "4.0.0", minSDKVersion: "4.0.0",
                              tokensSHA256: String(repeating: "0", count: 64), defaultContext: "c16_l64", contexts: ["c16_l64"], files: files)
        m.encryption = .init(keyID: "d14d9aeeeecb3a238cb86c41a5e8b0c2", root: 1)
        return m
    }

    /// The stored path a model request asks for, or nil.
    static func path(_ seen: StubProtocol.Seen) -> String? {
        guard let at = seen.url.path.range(of: "/sdk/v4.0/") else { return nil }
        return String(seen.url.path[at.upperBound...])
    }

    static var modelRequests: [StubProtocol.Seen] { StubProtocol.seen.filter { path($0) != nil } }

    /// The stand-in model host: each file as a real host serves it (`ModelDownloadTests.served`, with the release
    /// build's ETag); `cut`: the first request of the largest file ends after this many bytes of its body.
    static func serve(cut: Int? = nil) {
        let first = Locked(true)
        StubProtocol.reset { seen in
            guard let p = path(seen), let d = stored[p] else { return StubProtocol.Reply(status: 404) }
            var reply = ModelDownloadTests.served(seen, data: d, etag: etag)
            if let cut, p == largest, first.withLock({ (f: inout Bool) -> Bool in defer { f = false }; return f }) { reply.breakAfter = cut }
            return reply
        }
    }

    /// A fresh install of the default context's CPU set and the Core ML build into a new folder.
    static func install() async throws -> (report: InstallReport, core: ModelDownloadTests.CoreStandIn, folder: URL) {
        let folder = CloudFixtures.storage().appendingPathComponent("models/v4.0/.download-one-request", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let client = CDNClient(http: HTTPClient(session: StubProtocol.session()), base: URL(string: "https://cdn.quranlab.ai/models")!,
                               auth: .fixed(key: "qlk_v1_test", token: "qlt_test"), verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
        var installer = ModelInstaller(source: client.source(ModelID("v4.0", repository: "Quran-Lab/tajweedformer-v4"), revision: "one-request",
                                                             base: base),
                                       retryPauses: [0, 0, 0, 0, 0])
        let core = ModelDownloadTests.CoreStandIn()
        installer.install = core.install(in: folder)
        let report = try await installer.install(manifest(), profile: DownloadProfile(context: "c16_l64", coreML: true), into: folder)
        return (report, core, folder)
    }

    override func tearDown() { StubProtocol.reset { _ in .down } }

    /// A fresh install: one request per file, no Range header, every file installed by the Core once.
    func testAFreshInstallAsksEachFileOnceWhole() async throws {
        Self.serve()
        let (report, core, folder) = try await Self.install()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        XCTAssertNil(report.appleUnavailable)
        let asked = Self.modelRequests
        let ranges = asked.compactMap { $0.headers["range"] }
        print("one request per file: \(asked.count) model-file requests for \(Self.layout.count) files, \(ranges.count) with a Range: \(ranges)")
        XCTAssertEqual(asked.count, Self.layout.count, "one request per file")
        XCTAssertEqual(Set(asked.compactMap(Self.path)), Set(Self.layout.map(\.path)))
        XCTAssertEqual(ranges, [], "a fresh install sends no Range")
        XCTAssertEqual(Set(core.installed.withLock { $0 }), Set(Self.layout.map(\.path)))
    }

    /// The transfer of the largest file cut once, 4 MB in: one resume of it, from the byte the cut left, with the
    /// first answer's ETag as `If-Range`; every other file once, whole.
    func testOneCutInTheLargestFileIsOneResumeWithIfRange() async throws {
        let cut = 4_000_000
        Self.serve(cut: cut)
        let (report, core, folder) = try await Self.install()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        XCTAssertNil(report.appleUnavailable)
        let asked = Self.modelRequests
        let largest = asked.filter { Self.path($0) == Self.largest }
        print("one request per file, one cut: \(asked.count) model-file requests; the largest file's: "
            + "\(largest.map { "\($0.headers["range"] ?? "whole") if-range \($0.headers["if-range"] ?? "none")" })")
        XCTAssertEqual(asked.count, Self.layout.count + 1, "one more request for the cut")
        XCTAssertEqual(largest.count, 2)
        XCTAssertNil(largest.first?.headers["range"])
        XCTAssertEqual(largest.last?.headers["range"], "bytes=\(cut)-", "resumed from the byte the cut left")
        XCTAssertEqual(largest.last?.headers["if-range"], Self.etag)
        XCTAssertEqual(asked.filter { Self.path($0) != Self.largest }.compactMap { $0.headers["range"] }, [])
        XCTAssertEqual(core.installed.withLock { $0 }.filter { $0 == Self.largest }.count, 1)
    }
}
