import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// QLPD1 program deltas: the cross-SDK vectors rebuilt byte for byte (int8 rowmajor, transposed, colblock, Tcolblock,
/// units 8x4 with strided runs from the graph data, the front end, fp16 planes), the wrong CPU files refused, and the
/// accelerator install: the delta preferred, the full program the fallback, the result checked before CoreML sees it.
/// The real CoreML delta of the shipped revision is not staged anywhere: only these vectors test the decoder.
final class ProgramDeltaTests: XCTestCase {
    func vectors() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "progdelta_vectors", withExtension: nil, subdirectory: "Fixtures"))
    }

    func scratch() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tf-qlpd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The decoded .qlpd of a case.
    func delta(_ name: String) throws -> URL {
        let out = scratch().appendingPathComponent(name + ".qlpd")
        _ = try Gzip.inflate(try vectors().appendingPathComponent("cases/\(name).qlpd.gz"), to: out)
        return out
    }

    func cases() throws -> [[String: Any]] {
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: vectors().appendingPathComponent("vectors.json"))) as? [String: Any])
        return try XCTUnwrap(j["cases"] as? [[String: Any]])
    }

    func testEveryVectorRebuildsByteForByte() throws {
        let v = try vectors()
        let cpu = ProgramDelta.CPUFiles(folder: v.appendingPathComponent("cpu"), context: "c16_l64")
        let all = try cases()
        XCTAssertEqual(all.count, 7)
        var kinds = Set<String>()
        for c in all {
            let name = try XCTUnwrap(c["name"] as? String)
            let out = scratch().appendingPathComponent("weight.bin")
            let sha = try ProgramDelta.rebuild(delta: try delta(name), cpu: cpu, to: out, expectedSHA256: c["sha256"] as? String,
                                               expectedSize: (c["size"] as? Int).map(Int64.init))
            XCTAssertEqual(sha, c["sha256"] as? String, name)
            XCTAssertEqual(try Data(contentsOf: out), try Data(contentsOf: v.appendingPathComponent("cases/\(name).bin")), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path + ".part"))
            for t in (c["tensors"] as? [[String: Any]]) ?? [] { kinds.insert("\(t["kind"] ?? "")/\(t["layout"] ?? "none")") }
        }
        print("v4-qlpd vectors: \(all.count) cases rebuilt byte for byte (\(kinds.sorted().joined(separator: ", ")))")
    }

    /// The CPU files the delta was not made against: refused by their hash; and even with a false hash claimed, the
    /// rebuilt bytes do not match the target, so nothing is written.
    func testWrongCPUFilesAreRefused() throws {
        let v = try vectors()
        let wrong = ProgramDelta.CPUFiles(folder: v.appendingPathComponent("cpu_wrong"), context: "c16_l64")
        let out = scratch().appendingPathComponent("weight.bin")
        XCTAssertThrowsError(try ProgramDelta.rebuild(delta: try delta("int8_rowmajor_per_row"), cpu: wrong, to: out)) { e in
            XCTAssertTrue("\(e)".contains("not the one this delta was made against"), "\(e)")
        }
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: v.appendingPathComponent("vectors.json"))) as? [String: Any])
        let claimed = try XCTUnwrap((j["cpu_sha256"] as? [String: String])?["layers.zfw"])
        let lying = ProgramDelta.CPUFiles(folder: v.appendingPathComponent("cpu_wrong"), context: "c16_l64", layersSHA256: claimed,
                                          frontendSHA256: (j["cpu_sha256"] as? [String: String])?["frontend.zfw"])
        XCTAssertThrowsError(try ProgramDelta.rebuild(delta: try delta("int8_rowmajor_per_row"), cpu: lying, to: out)) { e in
            XCTAssertTrue("\(e)".contains("SHA-256 differs"), "\(e)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "nothing written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path + ".part"))
        // and a manifest that lists another program is refused before any work
        XCTAssertThrowsError(try ProgramDelta.rebuild(delta: try delta("fp16_planes"), cpu: ProgramDelta.CPUFiles(folder: v.appendingPathComponent("cpu"), context: "c16_l64"),
                                                      to: out, expectedSHA256: String(repeating: "0", count: 64)))
    }

    func testHalfConversionRoundsToNearestEven() {
        XCTAssertEqual(ProgramDelta.half(1), 0x3c00)
        XCTAssertEqual(ProgramDelta.half(-2), 0xc000)
        XCTAssertEqual(ProgramDelta.half(65504), 0x7bff)
        XCTAssertEqual(ProgramDelta.half(70000), 0x7c00)
        XCTAssertEqual(ProgramDelta.half(Float(bitPattern: 0x3f80_1000)), 0x3c00, "halfway rounds to even (down)")
        XCTAssertEqual(ProgramDelta.half(Float(bitPattern: 0x3f80_3000)), 0x3c02, "halfway rounds to even (up)")
        XCTAssertEqual(ProgramDelta.half(5.960464477539063e-08), 0x0001, "the smallest subnormal")
        XCTAssertEqual(ProgramDelta.half(0), 0)
        for v: Float in [0.1, -3.75, 1e-6, 1234.5, -0.000123] {
            XCTAssertEqual(ProgramDelta.half(v), Float16(v).bitPattern, "\(v)")
        }
    }

    // MARK: the install

    final class Logged: ModelFileSource, @unchecked Sendable {
        let inner: DirectoryFileSource
        let seen = Locked<[String]>([])
        init(_ root: URL) { inner = DirectoryFileSource(root: root) }
        func bytes(_ path: String, lower: Int64, upper: Int64, size: Int64) async throws(RecognizerError) -> Data {
            seen.withLock { if !$0.contains(path) { $0.append(path) } }
            return try await inner.bytes(path, lower: lower, upper: upper, size: size)
        }
    }

    /// A server folder with the vectors' CPU files, a CoreML package whose weight.bin is a vector's target, its delta,
    /// and a keep table; the device folder holds the CPU set already.
    func folders(case name: String, deviceCPU: String = "cpu", listProgramOnServer: Bool = true) throws -> (ModelManifest, URL, URL) {
        let v = try vectors()
        let server = scratch(), device = scratch()
        let fm = FileManager.default
        func put(_ src: URL, _ rel: String, in dir: URL) throws {
            let dst = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dst)
        }
        let cpuFiles = [("layers.zfw", "layers.zfw", "weights"), ("frontend.zfw", "frontend.zfw", "frontend"),
                        ("model_engine2.onnx.zfg", "c16_l64/model_engine2.onnx.zfg", "graph"),
                        ("model_engine2.onnx.zfg.bin", "c16_l64/model_engine2.onnx.zfg.bin", "graph-data")]
        var files: [ModelManifest.File] = []
        for (src, rel, role) in cpuFiles {
            try put(v.appendingPathComponent("cpu/\(src)"), rel, in: server)
            try put(v.appendingPathComponent("\(deviceCPU)/\(src)"), rel, in: device)
            let (size, sha) = try ModelManifest.digest(server.appendingPathComponent(rel))
            files.append(.init(path: rel, size: size, sha256: sha, context: rel.hasPrefix("c16") ? "c16_l64" : "*", role: role))
        }
        let pkg = "coreml/tajweedformer_v4.mlmodelc"
        try put(v.appendingPathComponent("cases/\(name).bin"), "\(pkg)/weights/weight.bin", in: server)
        try put(try delta(name), "\(pkg)/weights/weight.bin.qlpd", in: server)
        try Data("model".utf8).write(to: server.appendingPathComponent("\(pkg)/model.mil"))
        try fm.createDirectory(at: server.appendingPathComponent("coreml/c16_l64"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: server.appendingPathComponent("coreml/c16_l64/keeps.bin"))
        for (rel, role, ctx) in [("\(pkg)/weights/weight.bin", "coreml", "*"), ("\(pkg)/weights/weight.bin.qlpd", "coreml-delta", "*"),
                                 ("\(pkg)/model.mil", "coreml", "*"), ("coreml/c16_l64/keeps.bin", "coreml-keeps", "c16_l64")] {
            let (size, sha) = try ModelManifest.digest(server.appendingPathComponent(rel))
            files.append(.init(path: rel, size: size, sha256: sha, platforms: ["apple"], context: ctx, role: role, need: .optional))
        }
        if !listProgramOnServer { try fm.removeItem(at: server.appendingPathComponent("\(pkg)/weights/weight.bin")) }
        let m = ModelManifest(modelID: "v4.0", revision: "qlpd-test", tokensSHA256: String(repeating: "a", count: 64), defaultContext: "c16_l64",
                              contexts: ["c16_l64"], files: files)
        return (m, server, device)
    }

    func testTheDeltaIsPreferredAndTheProgramIsChecked() async throws {
        let (m, server, device) = try folders(case: "int8_units8x4_zfg_strided")
        let src = Logged(server)
        let profile = DownloadProfile(context: "c16_l64", coreML: true)
        XCTAssertNotNil(profile.programDelta(m))
        let r = try await ModelInstaller(source: src).installAccelerator(m, profile: profile, into: device)
        XCTAssertTrue(r.programFromDelta)
        XCTAssertNil(r.programDeltaFallback)
        let seen = src.seen.withLock { $0 }
        XCTAssertTrue(seen.contains { $0.hasSuffix("weight.bin.qlpd") })
        XCTAssertFalse(seen.contains { $0.hasSuffix("weights/weight.bin") }, "the full program is not downloaded")
        let pkg = "coreml/tajweedformer_v4.mlmodelc/weights/"
        XCTAssertEqual(try Data(contentsOf: device.appendingPathComponent(pkg + "weight.bin")),
                       try Data(contentsOf: server.appendingPathComponent(pkg + "weight.bin")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: device.appendingPathComponent(pkg + "weight.bin.qlpd").path), "the delta is removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: device.appendingPathComponent(".rebuild").path))
        print("v4-qlpd install: delta \(seen.filter { $0.hasSuffix(".qlpd") }.count) file, program rebuilt and checked, \(r.downloadedBytes) bytes fetched")
    }

    func testABadDeltaFallsBackToTheFullProgram() async throws {
        let (m, server, device) = try folders(case: "int8_rowmajor_per_row", deviceCPU: "cpu_wrong")
        let src = Logged(server)
        let r = try await ModelInstaller(source: src).installAccelerator(m, profile: DownloadProfile(context: "c16_l64", coreML: true), into: device)
        XCTAssertFalse(r.programFromDelta)
        XCTAssertNotNil(r.programDeltaFallback)
        XCTAssertTrue(src.seen.withLock { $0 }.contains { $0.hasSuffix("weights/weight.bin") }, "the full program after the delta failed")
        let pkg = "coreml/tajweedformer_v4.mlmodelc/weights/weight.bin"
        XCTAssertEqual(try Data(contentsOf: device.appendingPathComponent(pkg)), try Data(contentsOf: server.appendingPathComponent(pkg)))
    }

    func testNoDeltaAndNoProgramMeansNoAccelerator() async throws {
        let (m, server, device) = try folders(case: "int8_rowmajor_per_row", deviceCPU: "cpu_wrong", listProgramOnServer: false)
        do {
            _ = try await ModelInstaller(source: Logged(server)).installAccelerator(m, profile: DownloadProfile(context: "c16_l64", coreML: true), into: device)
            XCTFail("installed without a program")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: device.appendingPathComponent("coreml/tajweedformer_v4.mlmodelc/weights/weight.bin").path))
        }
    }

    /// A real delta against the real CPU files (TAJWEED_QLPD_DIR: a folder with `deltas.json` and the .qlpd files;
    /// TAJWEED_QLPD_CPU: the decoded CPU files of their revision). Local only, never in the repository.
    func testRealDeltasWhenStaged() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["TAJWEED_QLPD_DIR"], let cpuDir = env["TAJWEED_QLPD_CPU"] else {
            print("v4-qlpd real: skipped (no staged deltas; the CoreML delta of the shipped revision is not staged at all)")
            throw XCTSkip("set TAJWEED_QLPD_DIR and TAJWEED_QLPD_CPU")
        }
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("deltas.json"))) as? [String: Any])
        let list = (j["deltas"] as? [[String: Any]]) ?? []
        var done = 0
        for d in list {
            guard let rel = d["delta"] as? String, let sha = (d["target"] as? [String: Any])?["sha256"] as? String else { continue }
            var file = URL(fileURLWithPath: dir).appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: file.path) else {
                print("v4-qlpd real: \(rel) is listed but not staged (skipped)")
                continue
            }
            if rel.hasSuffix(".gz") {
                let out = scratch().appendingPathComponent("d.qlpd")
                _ = try Gzip.inflate(file, to: out)
                file = out
            }
            let out = scratch().appendingPathComponent("program")
            let t0 = Date()
            XCTAssertEqual(try ProgramDelta.rebuild(delta: file, cpu: .init(folder: URL(fileURLWithPath: cpuDir), context: "c16_l64"), to: out,
                                                    expectedSHA256: sha), sha, rel)
            print(String(format: "v4-qlpd real: %@ rebuilt in %.1f s", rel, Date().timeIntervalSince(t0)))
            try? FileManager.default.removeItem(at: out)
            done += 1
        }
        XCTAssertGreaterThan(done, 0)
    }
}
