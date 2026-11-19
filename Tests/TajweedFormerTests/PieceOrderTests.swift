import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// piece_order.json's four sequences through the SDK's lease
/// flow and REAL model opens: the answer's piece handed over right after the accept, pending in the Core until the
/// next open, the last good piece only once a lease asked under it was accepted and a model opened after that.
///
/// A model opens only from a build with a layout, so this runs on a test build made by the Core's
/// `tools/make_test_build.py` (docs/mac-checklist-4.0.md step 4: the same lease key and install key as the vectors):
/// `QLC_TEST_BUILD=<its --out folder> swift test --filter PieceOrderTests`. Without it, or without the Core's test
/// release, it skips.
///
/// How the vector's steps map to the SDK's calls: an `ask` that does not repeat a refused proof is one
/// `ProtectedRuntime.renew`; the fake server answers it by the step after it (`accept` and its `piece`: 200 with that
/// piece; `refuse`: 403 lease_integrity_failed, why core; `busy`: 429; anything else: 503, which makes no Core call).
/// After a proof refused under a piece the SDK asks once more by itself, at once: that is the vector's next `ask`
/// (made before a `restart` that the vector puts between them; the Core's state is the same on both sides). `open`,
/// `close`: the runtime opens and closes the model; `open_fails`: an open with one device form moved aside (the Core
/// moves its count of opens, then fails); `restart`: the model closed and a new runtime made from the saved state.
final class PieceOrderTests: XCTestCase {
    typealias P = ProtectedCoreTests

    struct TestBuild {
        let cdn: URL
        let manifest: ModelManifest
        let lease: Data
        let key: SoftwareInstallKey
    }

    func testBuild() throws -> TestBuild {
        guard CoreHost.version.hasPrefix("4.0.0-c1 ") else { throw XCTSkip("needs the Core's test release 4.0.0-c1") }
        guard let dir = ProcessInfo.processInfo.environment["QLC_TEST_BUILD"], !dir.isEmpty else {
            throw XCTSkip("QLC_TEST_BUILD names no test build (make_test_build.py --out)")
        }
        let out = URL(fileURLWithPath: dir)
        let cdn = out.appendingPathComponent("cdn/sdk/v4.0")
        var m = try ModelManifest.parse(try Data(contentsOf: cdn.appendingPathComponent("manifest.json")))
        let build = try String(contentsOf: out.appendingPathComponent("build.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        // the test lease names build.txt's build; the build id is otherwise the manifest bytes' SHA-256
        m.sha256 = build + String(repeating: "0", count: 24)
        let key = try XCTUnwrap(SoftwareInstallKey(der: try Data(contentsOf: out.appendingPathComponent("install_key.der"))))
        return TestBuild(cdn: cdn, manifest: m, lease: try Data(contentsOf: out.appendingPathComponent("lease.bin")), key: key)
    }

    /// The answers for one sequence, one per lease request in order, read from the steps.
    static func answers(_ steps: [[String: Any]]) -> [String] {
        var out: [String] = []
        for (i, st) in steps.enumerated() where st["op"] as? String == "ask" {
            let next = i + 1 < steps.count ? steps[i + 1] : [:]
            switch next["op"] as? String {
            case "accept":
                let piece = i + 2 < steps.count && steps[i + 2]["op"] as? String == "piece" ? steps[i + 2]["name"] as? String ?? "" : ""
                out.append("accept:" + piece)
            case "refuse": out.append("refuse")
            case "busy": out.append("busy")
            default: out.append("none")
            }
        }
        return out
    }

    func testThePieceOrderSequences() async throws {
        let tb = try testBuild()
        let order = try V40.json("piece_order.json")
        let sequences = try XCTUnwrap(order["sequences"] as? [[String: Any]])
        XCTAssertEqual(sequences.count, 4)
        var pieces: [String: String] = [:]
        for (i, name) in ["piece7", "piece8", "piece9"].enumerated() { pieces[name] = try P.piece(i).b64u }
        let refused = try XCTUnwrap(try V40.json("piece.json")["refused"] as? [[String: Any]])
        let bad = try XCTUnwrap(refused.first { $0["name"] as? String == "one signature byte changed" })
        pieces["piece_bad_sig"] = V40.hex(try XCTUnwrap(bad["bytes_hex"] as? String)).base64URL
        for seq in sequences {
            try await run(seq, tb, pieces)
        }
    }

    private func run(_ seq: [String: Any], _ tb: TestBuild, _ pieces: [String: String]) async throws {
        let name = seq["name"] as? String ?? "?"
        let steps = try XCTUnwrap(seq["steps"] as? [[String: Any]])
        let want = try XCTUnwrap(seq["asks"] as? [Int])
        let script = Locked(Self.answers(steps))
        let lv = try V40.json("lease.json")
        let signer = try V40.signer(lv)
        let now = Int64(Date().timeIntervalSince1970)
        let cert = try P.certificate(for: tb.key, signer: signer.private, now: now)
        let base: [String: Any] = ["v": 1, "lease": tb.lease.base64URL, "iat": now - 60, "exp": now + 604_800, "refresh_after": now + 72_000,
                                   "base": "https://cdn.quranlab.ai/models/Quran-Lab/m/b/sdk/v4.0/", "install_cert": cert]
        // the first request is the set-up's own lease (before the sequence: the files are installed under it)
        let setUpDone = Locked(false)
        let transport = P.FakeTransport { (r: URLRequest, _: Int) -> HTTPClient.Response in
            if r.url?.path.hasSuffix("v1/attest/challenge") == true { return P.response(200, ["challenge": P.challenge]) }
            guard r.url?.path.hasSuffix("v1/model-key") == true else { return P.response(404, ["error": "not_found"]) }
            if !setUpDone.withLock({ $0 }) { return P.response(200, base) }
            let a = script.withLock { (s: inout [String]) -> String in s.isEmpty ? "none" : s.removeFirst() }
            if a.hasPrefix("accept:") {
                var o = base
                let p = String(a.dropFirst(7))
                if !p.isEmpty { o["piece"] = pieces[p] }
                return P.response(200, o)
            }
            switch a {
            case "refuse": return P.response(403, ["error": "lease_integrity_failed", "message": "the Core could not be verified", "why": "core"])
            case "busy": return P.response(429, ["error": "rate_limited"])
            default: return P.response(503, ["error": "unavailable"])
            }
        }
        let server = LeaseServer(transport: transport, apiURL: URL(string: "https://api.quranlab.ai")!, key: "qlk_v1_apps-one_sig",
                                 platform: "ios", token: { (_: Bool) async throws(CloudError) -> String in "qlt_test" },
                                 certify: { (_: any InstallKey) async throws(CloudError) -> String in cert },
                                 trustedKeys: [signer.public])
        let storage = Fixtures.storage()
        let state = P.MemoryState()
        func runtime() -> ProtectedRuntime {
            ProtectedRuntime(storage: storage, server: server, keys: P.FixedKeys(tb.key), state: state, clocks: SystemClocks())
        }
        var rt = runtime()
        // set-up: a lease, then every file of the build installed to its device form
        _ = try await rt.ensureLease(tb.manifest)
        setUpDone.withLock { $0 = true }
        let folderURL = storage.appendingPathComponent("models/v4.0/\(tb.manifest.build)")
        try copyTree(tb.cdn, to: folderURL)
        let encrypted = tb.manifest.files.filter(\.isEncrypted).filter { FileManager.default.fileExists(atPath: folderURL.appendingPathComponent($0.localPath + ".qle").path) }
        for f in encrypted { try rt.install(tb.manifest, decodedPath: f.localPath, in: folderURL) }
        let folder: ModelFolder
        do throws(RecognizerError) {
            folder = ModelFolder(id: ModelID("v4.0", repository: "Quran-Lab/test"), directory: folderURL, manifest: tb.manifest,
                                 vocabulary: try Vocabularies.vocabulary(sha256: tb.manifest.tokensSHA256),
                                 verifiedFiles: Set(encrypted.map(\.localPath)), coreMLProblem: "test")
        } catch {
            throw XCTSkip("the test build's vocabulary is not one the SDK carries: \(error)")
        }
        let first = transport.bodies("v1/model-key").count
        var lastWant = 0
        var repeatOwed = false
        for st in steps {
            switch st["op"] as? String ?? "" {
            case "ask":
                if repeatOwed {
                    // the SDK's own repeat of a proof refused under a piece: made in the same renew
                    repeatOwed = false
                } else {
                    _ = try? await rt.renew(tb.manifest)
                }
                lastWant = st["want"] as? Int ?? 0
            case "refuse":
                repeatOwed = lastWant != 0
            case "open":
                _ = try rt.openModel(folder, context: tb.manifest.defaultContext)
            case "close":
                rt.closeModel()
            case "open_fails":
                let target = try XCTUnwrap(encrypted.max { $0.deviceFormSize < $1.deviceFormSize })
                let qld = folderURL.appendingPathComponent(target.localPath + ".qld")
                let aside = qld.appendingPathExtension("aside")
                try FileManager.default.moveItem(at: qld, to: aside)
                XCTAssertThrowsError(try rt.openModel(folder, context: tb.manifest.defaultContext), "\(name): the open fails")
                try FileManager.default.moveItem(at: aside, to: qld)
            case "restart":
                rt.closeModel()
                rt = runtime()
            default:
                break   // accept, piece, busy: the server's answers
            }
        }
        rt.closeModel()
        let named = transport.bodies("v1/model-key").dropFirst(first).map { (($0["core"] as? [String: Any])?["piece"] as? Int) ?? -1 }
        XCTAssertEqual(Array(named), want, name)
    }

    private func copyTree(_ from: URL, to: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        guard let e = fm.enumerator(at: from, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let u as URL in e {
            let rel = String(u.path.dropFirst(from.path.count + 1))
            let dest = to.appendingPathComponent(rel)
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            } else {
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: u, to: dest)
            }
        }
    }
}
