import CoreML
import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// The real Apple profiles (TAJWEED_V4_APPLE: a decoded layout v2 folder with the default fp16 build
/// `coreml/tajweedformer_v4.mlmodelc`, the compact int8 build `coreml-compact/tajweedformer_v4.mlmodelc`, the keep
/// tables `coreml/<ctx>/keeps.bin`, and the CPU files). For each build the folder ships: the install fetches the CPU set
/// first, then the build's files (never a correction); the CPU engine runs; the recognizer starts on the CPU engine,
/// runs the promotion pipeline (compile, warm-up, golden test, measure) and is promoted at the next take, or stays on
/// the CPU engine with the reason.
///
/// A folder whose packages carry their keep tables inside has no `keeps.bin`, and an accelerator build serves a
/// context only by a signed tolerance under `<build>:<context>` (SPEC 5.4). The folder has no signed manifest of its
/// own (the test writes one for it), so since 3.0.2 the test signs that manifest with a key of its own and gives each
/// build the identical-tokens entry for every context its package has functions for (read from the function names of
/// the package's program) and the manifest has no keep table for. A folder with keep tables gets no such entry and no
/// signature: it runs exactly as before. Until then a folder without keep tables had nothing to run and the test
/// failed.
final class AppleProfileTests: XCTestCase {
    func source() throws -> URL {
        guard let p = ProcessInfo.processInfo.environment["TAJWEED_V4_APPLE"] else { throw XCTSkip("set TAJWEED_V4_APPLE") }
        return URL(fileURLWithPath: p)
    }

    /// The contexts a compiled package has a front and a back function for, sorted: read from the function names
    /// of its program (`model.mil`: `func front_<context><...>(`). Empty for a package that is not multifunction.
    static func contexts(ofPackage package: URL) -> [String] {
        guard let text = try? String(contentsOf: package.appendingPathComponent("model.mil"), encoding: .utf8),
              let pattern = try? NSRegularExpression(pattern: #"func\s+(front|back)_(c[0-9]+_l[0-9]+)\s*<"#) else { return [] }
        var halves: [String: Set<String>] = [:]
        let whole = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: whole) {
            guard let half = Range(match.range(at: 1), in: text), let context = Range(match.range(at: 2), in: text) else { continue }
            halves[String(text[context]), default: []].insert(String(text[half]))
        }
        return halves.filter { $0.value == ["front", "back"] }.keys.sorted()
    }

    /// The identical-tokens entry a first build without keep tables signs per context (SPEC 5.1): zero token edits
    /// on every compared head, no bound on a distance.
    static var identicalTokens: [String: Any] { ["log_probs": ["token_edits": 0, "lp_mean": 30.0, "lp_p99": 30.0]] }

    /// `m` (the manifest the test made for `folder`) as the test runs it: for each build whose package has functions
    /// for a context the manifest lists no keep table for, the identical-tokens entry under `<build>:<context>`,
    /// signed with a key made here, and the verifier that trusts that key. `added`: the keys of those entries. A
    /// folder with a keep table for every such context gets none: the manifest and the verifier are the ones the
    /// test always used (unsigned, no signature required).
    static func served(_ m: ModelManifest, folder: URL) throws -> (manifest: ModelManifest, verifier: ManifestVerifier, added: [String]) {
        var entries: [String: Any] = [:]
        for build in ["coreml", "coreml-compact"] {
            guard let package = ModelFolder.packages(m.files(role: build)).first else { continue }
            for context in contexts(ofPackage: folder.appendingPathComponent(package)) where m.contexts.contains(context) {
                if m.files.contains(where: { $0.role == "coreml-keeps" && $0.context == context }) { continue }
                entries["\(build):\(context)"] = identicalTokens
            }
        }
        guard !entries.isEmpty else { return (m, ManifestVerifier(trustedKeys: [], requireSignature: false), []) }
        var signed = m
        signed.goldenRawField = JSONValue(any: try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: entries)))
        let key = Curve25519.Signing.PrivateKey()
        signed.signature = try key.signature(for: Data(signed.signedText().utf8)).base64EncodedString()
        let verifier = ManifestVerifier(trustedKeys: [key.publicKey.rawRepresentation], requireSignature: false)
        return (try verifier.verifySignature(signed, required: true), verifier, entries.keys.sorted())
    }

    func testBothBuilds() async throws {
        let src = try source()
        let made = try Self.served(try Fixtures.manifest(for: src, revision: "apple-test"), folder: src)
        let m = made.manifest
        print("v4-apple: " + (made.added.isEmpty ? "the folder has keep tables: the manifest is unsigned, as before"
                                                 : "no keep table for \(made.added): the test signed the identical-tokens entry under each"))
        var ran = 0
        for compact in [false, true] {
            let profile = DownloadProfile(context: m.defaultContext, coreML: true, compact: compact)
            guard !profile.appleFiles(m).isEmpty else {
                print("v4-apple \(compact ? "compact" : "default"): not in the folder, skipped")
                continue
            }
            try await check(src, m, profile, made.verifier)
            ran += 1
        }
        XCTAssertGreaterThan(ran, 0)
    }

    /// What can be checked without a real Apple folder (the public runner has none): on a folder whose fp16 package
    /// is the stand-in of a one-file package, the contexts are read from the package's function names; the test's
    /// manifest gets an entry for each context that has functions, is a context of the folder and has no keep
    /// table, and for no other; with it the build serves those contexts, by that tolerance. On a folder with keep
    /// tables nothing is added and nothing is signed.
    func testAFolderWithoutKeepTablesIsServedByTheEntriesTheTestSigns() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { throw XCTSkip("needs macOS 15 / iOS 18") }
        let dir = try await TajweedOneFilePackageTests.bareFolder()
        XCTAssertEqual(Self.contexts(ofPackage: dir.appendingPathComponent("coreml/tajweedformer_v4.mlmodelc")), ["c16_l64", "c24_l256", "c24_l72"])
        let plain = try Fixtures.manifest(for: dir, revision: "apple-test")
        XCTAssertEqual(plain.contexts.sorted(), ["c16_l64", "c24_l72", "c8_l64"], "the folder's contexts")
        XCTAssertTrue(DownloadProfile(context: plain.defaultContext, coreML: true).appleFiles(plain).isEmpty, "unsigned: nothing is served")
        let made = try Self.served(plain, folder: dir)
        // c24_l256 has functions and is not a context of the folder; c8_l64 is one and has no functions
        XCTAssertEqual(made.added, ["coreml:c16_l64", "coreml:c24_l72"])
        let m = made.manifest
        XCTAssertTrue(m.goldenRawSigned)
        for context in ["c16_l64", "c24_l72"] {
            XCTAssertEqual(m.serving(build: "coreml", context: context)?.by, .tolerance, context)
            XCTAssertEqual(m.rawTolerance(build: "coreml", context: context)?.heads["log_probs"], GoldenRawTolerance.Head(tokenEdits: 0, lpMean: 30, lpP99: 30), context)
        }
        XCTAssertNil(m.serving(build: "coreml", context: "c8_l64"), "no functions for c8_l64: not signed, not served")
        XCTAssertNil(m.serving(build: "coreml-compact", context: "c16_l64"), "the folder has no compact package")
        XCTAssertFalse(DownloadProfile(context: m.defaultContext, coreML: true).appleFiles(m).isEmpty, "the test's run finds the build")
        // written and opened as the test's install does: the entries are trusted again from the file
        try m.write(to: dir)
        let model = try ModelFolder.open(directory: dir, verifier: made.verifier)
        let build = try XCTUnwrap(model.coreML(context: "c16_l64"))
        XCTAssertNil(build.keeps)
        XCTAssertEqual(build.frontFunction, "front_c16_l64")

        // a folder with keep tables: nothing added, nothing signed, the same manifest
        let tables = FileManager.default.temporaryDirectory.appendingPathComponent("tf-apple-tables-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: Fixtures.v4mini().appendingPathComponent("decoded"), to: tables)
        let before = try Fixtures.manifest(for: tables, revision: "apple-test")
        let same = try Self.served(before, folder: tables)
        XCTAssertEqual(same.added, [])
        XCTAssertEqual(same.manifest, before)
        XCTAssertNil(same.manifest.signature)
        XCTAssertFalse(same.verifier.requireSignature)
        XCTAssertTrue(same.verifier.trustedKeys.isEmpty)
        XCTAssertFalse(DownloadProfile(context: before.defaultContext, coreML: true).appleFiles(same.manifest).isEmpty, "served by its keep tables, as before")
    }

    func check(_ src: URL, _ m: ModelManifest, _ profile: DownloadProfile, _ verifier: ManifestVerifier) async throws {
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
        let model = try ModelFolder.open(directory: dir, verifier: verifier)
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
        let auto = try TajweedRecognizer(model: model, backend: .automatic, compact: profile.compact)
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
