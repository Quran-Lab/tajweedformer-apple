import CoreML
import Foundation
import XCTest
@testable import TajweedFormer

/// The real Apple profiles (TAJWEED_V4_APPLE: a decoded layout v2 folder with the default fp16 build
/// `coreml/tajweedformer_v4.mlmodelc`, the compact int8 build `coreml-compact/tajweedformer_v4.mlmodelc`, the keep
/// tables `coreml/<ctx>/keeps.bin`, and the CPU files). For each build the folder ships: the install fetches the CPU set
/// first, then the build's files (never a correction); the CPU engine runs; the recognizer starts on the CPU engine,
/// runs the promotion pipeline (compile, warm-up, golden test, measure) and is promoted at the next take, or stays on
/// the CPU engine with the reason.
final class AppleProfileTests: XCTestCase {
    func source() throws -> URL {
        guard let p = ProcessInfo.processInfo.environment["TAJWEED_V4_APPLE"] else { throw XCTSkip("set TAJWEED_V4_APPLE") }
        return URL(fileURLWithPath: p)
    }

    func testBothBuilds() async throws {
        let src = try source()
        let m = try Fixtures.manifest(for: src, revision: "apple-test")
        var ran = 0
        for compact in [false, true] {
            let profile = DownloadProfile(context: m.defaultContext, coreML: true, compact: compact)
            guard !profile.appleFiles(m).isEmpty else {
                print("v4-apple \(compact ? "compact" : "default"): not in the folder, skipped")
                continue
            }
            try await check(src, m, profile)
            ran += 1
        }
        XCTAssertGreaterThan(ran, 0)
    }

    func check(_ src: URL, _ m: ModelManifest, _ profile: DownloadProfile) async throws {
        let name = profile.compact ? "compact" : "default"
        let ctx = profile.context
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tf-apple-\(UUID().uuidString)")
        let installer = ModelInstaller(source: DirectoryFileSource(root: src))
        let cpuInstall = try await installer.install(m, profile: DownloadProfile(context: ctx, coreML: false), into: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("coreml").path), "\(name): the first install is the CPU set")
        let r = try await installer.installAccelerator(m, profile: profile, into: dir)
        print("v4-apple \(name) install: CPU set \(cpuInstall.downloadedBytes) bytes first, then the build \(r.downloadedBytes) bytes")
        XCTAssertEqual(r.downloadedBytes, r.profileBytes, "\(name): nothing outside the profile")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("coreml/engine.zfs").path), "\(name): no correction")
        for f in ["layers.zfw", "frontend.zfw"] {
            XCTAssertEqual(try ModelManifest.digest(dir.appendingPathComponent(f)).1, try ModelManifest.digest(src.appendingPathComponent(f)).1, "\(name) \(f)")
        }
        let other = profile.compact ? "coreml/tajweedformer_v4.mlmodelc" : "coreml-compact/tajweedformer_v4.mlmodelc"
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(other).path), "\(name): never both builds")
        Fixtures.configure(storage: Fixtures.storage())
        let model = try TajweedModel.open(directory: dir, verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
        XCTAssertTrue(model.isUsable(context: ctx))
        let build = try XCTUnwrap(model.coreML(context: ctx))
        XCTAssertEqual(build.compact, profile.compact)
        XCTAssertEqual(build.frontFunction, "front_\(ctx)")

        // the CPU engine
        let exact = try TajweedRecognizer(model: model, backend: .exact)
        let clip = try Fixtures.samples("Husary_001001")
        try await exact.startTake()
        try await exact.append(clip)
        let cpuHeads = try await exact.finish()
        XCTAssertFalse(cpuHeads.greedy.isEmpty)

        // the package's functions on this machine (a hosted runner has no Neural Engine: CoreML runs on its CPU)
        guard #available(macOS 15.0, iOS 18.0, *) else { return }
        let auto = try TajweedRecognizer(model: model, backend: .automatic)
        try await auto.prepare()
        let first = await auto.activeBackend
        XCTAssertEqual(first, .exact, "CPU first")
        let ready = await auto.awaitReady(timeout: 900)
        let state = await auto.acceleratorState
        let st = await auto.acceleratorSelfTest
        print("v4-apple \(name) accelerator: \(state), self-test \(st.map { $0.passed ? "passed" : "failed: " + ($0.reason ?? "") } ?? "none")"
              + String(format: ", p90 %.2f ms, median %.2f ms, cpu median %.2f ms, speedup %.2f", st?.p90Ms ?? 0, st?.medianMs ?? 0,
                       st?.cpuMedianMs ?? 0, st?.speedup ?? 0))
        try await auto.startTake()
        let active = await auto.activeBackend
        XCTAssertEqual(active, ready ? .neuralEngine : .exact, "promoted at the take boundary when ready")
        try await auto.append(clip)
        let heads = try await auto.finish()
        print("v4-apple \(name) Husary_001001 on \(active.map(\.rawValue) ?? "none"): cpu \(cpuHeads.greedy.count) tokens, this \(heads.greedy.count), edits \(Self.edits(cpuHeads.greedy, heads.greedy))")
        if !ready {
            let reason = await auto.fallbackReason
            print("v4-apple \(name) fallback: \(reason.map(\.rawValue) ?? "none")")
        }
    }

    static func edits(_ a: [Int], _ b: [Int]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
