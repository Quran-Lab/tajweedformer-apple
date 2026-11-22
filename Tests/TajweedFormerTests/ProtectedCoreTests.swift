import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// The protected model through the real Core and the SDK's own platform table (storage, clocks, key store, state),
/// with a fake transport for the server, driven by the contract's vectors: lease.json's ECDH lease for
/// manifest_40.json's build, with lease.json's install key, as the Core's own tests/test_core.c does.
///
/// Needs the Core's TEST release (4.0.0-c1, the contract's test keys): build the xcframework with
/// `scripts/build_core_xcframework.py --test-release`. With a real release linked these tests skip.
final class ProtectedCoreTests: XCTestCase {
    static let challenge = "c1.1790000300.AAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBB"

    struct FixedClocks: CoreClocks {
        var wall: Int64
        var bootMs: Int64
        var id: [UInt8]
        func wallMs() -> Int64 { wall }
        func boot() -> (ms: Int64, id: [UInt8]) { (bootMs, id) }
    }

    /// The Core's state, its sealing key and its counter, in memory.
    final class MemoryState: CoreStateKeeping, @unchecked Sendable {
        private let lock = NSLock()
        private var blob: Data?
        private var count: UInt64 = 0
        private let key = SymmetricKey(size: .bits256)
        func load() -> Data? { lock.lock(); defer { lock.unlock() }; return blob }
        func save(_ b: Data) { lock.lock(); blob = b; lock.unlock() }
        func seal(_ s: Data) -> Data? { (try? AES.GCM.seal(s, using: key))?.combined }
        func open(_ s: Data) -> Data? { (try? AES.GCM.SealedBox(combined: s)).flatMap { try? AES.GCM.open($0, using: key) } }
        func counter() -> UInt64 { lock.lock(); defer { lock.unlock() }; return count }
        func raise(_ v: UInt64) -> Bool { lock.lock(); count = max(count, v); lock.unlock(); return true }
    }

    /// One fixed install key (the vector's).
    final class FixedKeys: InstallKeySource, @unchecked Sendable {
        let key: any InstallKey
        init(_ key: any InstallKey) { self.key = key }
        func current() -> (any InstallKey)? { key }
        var generation: Int { 1 }
        func makeNext() -> (key: any InstallKey, generation: Int)? { (key, 1) }
        func promote(_ key: any InstallKey, generation: Int) {}
        func discard(generation: Int) {}
    }

    /// The server: scripted answers, every request recorded.
    final class FakeTransport: LeaseTransport, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [URLRequest] = []
        var answer: (URLRequest, Int) -> HTTPClient.Response
        /// A request that gets no answer at all (a dropped connection), as URLSession reports it.
        var drop: (URLRequest) -> Bool = { _ in false }

        init(_ answer: @escaping (URLRequest, Int) -> HTTPClient.Response) { self.answer = answer }

        func send(_ request: URLRequest) async throws(CloudError) -> HTTPClient.Response {
            let n = lock.withLock { () -> Int in
                requests.append(request)
                return requests.filter { $0.url?.path == request.url?.path }.count
            }
            if drop(request) { throw CloudError.offline("The network connection was lost. [NSURLErrorDomain -1005]") }
            return answer(request, n)
        }

        func bodies(_ path: String) -> [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return requests.filter { $0.url?.path.hasSuffix(path) == true }.compactMap {
                $0.httpBody.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            }
        }
    }

    static func response(_ status: Int, _ body: [String: Any]) -> HTTPClient.Response {
        HTTPClient.Response(status: status, headers: [:], body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }

    struct Setup {
        let runtime: ProtectedRuntime
        let transport: FakeTransport
        let manifest: ModelManifest
        let key: SoftwareInstallKey
        let lease: Data
        let fields: [String: Any]
        let cert: String
        let storage: URL
        let state: MemoryState
        let certified: Locked<Int>
    }

    func requireTestCore() throws {
        guard CoreHost.version.hasPrefix("4.0.0-c1 ") else {
            throw XCTSkip("the linked Core is \(CoreHost.version), not the test release 4.0.0-c1 (build_core_xcframework.py --test-release)")
        }
    }

    /// A certificate for `key` signed by the contract's test signer (an `att none` desktop-style certificate).
    static func certificate(for key: any InstallKey, signer: Curve25519.Signing.PrivateKey, now: Int64, validity: Int64 = 86_400) throws -> String {
        let text = "quranlab-install-cert 1\napp ios:ai.quranlab.sdk.tests\nplatform ios\nkey apps-one\ninstall \(key.installHash)\n"
            + "sign \(Data(SHA256.hash(data: key.spki)).hex)\natt none\nhw 0\niat \(now - 100)\nexp \(now + validity)\nrecheck 0\nbatch -\ndigest -\n"
        let sig = try signer.signature(for: Data(text.utf8))
        return Data(text.utf8).base64URL + "." + sig.base64URL
    }

    /// `piece`: the data piece of the n-th lease answer (n counts the lease requests, refused ones too).
    func prepare(piece: ((Int) -> String?)? = nil, answer override: ((URLRequest, Int) -> HTTPClient.Response?)? = nil,
                 clocks clocksOverride: (any CoreClocks)? = nil, certValidity: Int64 = 86_400) throws -> Setup {
        try requireTestCore()
        let lv = try V40.json("lease.json")
        let signer = try V40.signer(lv)
        let ecdh = try XCTUnwrap(lv["install_ecdh"] as? [String: Any])
        let key = try XCTUnwrap(SoftwareInstallKey(der: try XCTUnwrap(Data(base64URL: try XCTUnwrap(ecdh["pkcs8_b64u"] as? String)))))
        XCTAssertEqual(key.installHash, ecdh["install_hash_hex"] as? String, "the vector's install key")
        let accept = try XCTUnwrap((lv["accept"] as? [[String: Any]])?.first)
        let lease = V40.hex(try XCTUnwrap(accept["lease_hex"] as? String))
        let fields = try XCTUnwrap(accept["fields"] as? [String: Any])
        let now = Int64(try XCTUnwrap(lv["now"] as? Int))
        let cert = try Self.certificate(for: key, signer: signer.private, now: now, validity: certValidity)
        var m = try ModelManifest.parse(try V40.manifest().data)
        // the vector's lease names lease.json's build; the build id is otherwise the manifest bytes' SHA-256
        m.sha256 = try XCTUnwrap(lv["build"] as? String) + String(repeating: "0", count: 24)
        var leaseAnswer: [String: Any] = ["v": 1, "lease": lease.base64URL, "iat": fields["iat"]!, "exp": fields["exp"]!,
                                          "refresh_after": fields["refresh_after"]!,
                                          "base": "https://cdn.quranlab.ai/models/Quran-Lab/m/b/sdk/v4.0/", "install_cert": cert]
        let answer = leaseAnswer
        let transport = FakeTransport { (r: URLRequest, n: Int) -> HTTPClient.Response in
            if let o = override?(r, n) { return o }
            if r.url?.path.hasSuffix("v1/attest/challenge") == true { return Self.response(200, ["challenge": Self.challenge]) }
            if r.url?.path.hasSuffix("v1/model-key") == true {
                var a = answer
                if let p = piece?(n) { a["piece"] = p }
                return Self.response(200, a)
            }
            return Self.response(404, ["error": "not_found"])
        }
        let certified = Locked(0)
        let server = LeaseServer(transport: transport, apiURL: URL(string: "https://api.quranlab.ai")!, key: "qlk_v1_apps-one_sig",
                                 platform: "ios", token: { (_: Bool) async throws(CloudError) -> String in "qlt_test" },
                                 certify: { (_: any InstallKey) async throws(CloudError) -> String in
                                     certified.withLock { $0 += 1 }
                                     return cert
                                 },
                                 trustedKeys: [signer.public])
        let storage = Fixtures.storage()
        let state = MemoryState()
        let clocks: any CoreClocks = clocksOverride
            ?? FixedClocks(wall: now * 1000, bootMs: 5_000_000, id: Array(SHA256.hash(data: Data("boot-1".utf8))))
        let runtime = ProtectedRuntime(storage: storage, server: server, keys: FixedKeys(key), state: state, clocks: clocks)
        return Setup(runtime: runtime, transport: transport, manifest: m, key: key, lease: lease, fields: fields, cert: cert,
                     storage: storage, state: state, certified: certified)
    }

    /// The build folder with manifest_40.json's stored containers in it (the CDN forms, as the downloader leaves them).
    func stageFolder(_ s: Setup) throws -> URL {
        let v = try V40.json("manifest_40.json")
        let folder = s.storage.appendingPathComponent("models/v4.0/\(s.manifest.build)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, hex) in try XCTUnwrap(v["containers_hex"] as? [String: String]) where path.hasSuffix(".qle") {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try V40.hex(hex).write(to: url)
        }
        return folder
    }

    // MARK: the lease

    func testALeaseIsAskedAcceptedAndKept() async throws {
        let s = try prepare()
        let rec = try await s.runtime.ensureLease(s.manifest)
        XCTAssertEqual(rec.expiresAt, Int64(try XCTUnwrap(s.fields["exp"] as? Int)))
        XCTAssertEqual(rec.build, s.manifest.build)
        XCTAssertEqual(rec.base, "https://cdn.quranlab.ai/models/Quran-Lab/m/b/sdk/v4.0/")
        // the request is 18.4.4's
        let body = try XCTUnwrap(s.transport.bodies("v1/model-key").first)
        XCTAssertEqual(body["v"] as? Int, 1)
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["install_cert"] as? String, s.cert)
        XCTAssertEqual(body["install_key"] as? String, s.key.spki.base64URL)
        XCTAssertEqual(body["install_sign_key"] as? String, s.key.spki.base64URL)
        XCTAssertEqual(body["challenge"] as? String, Self.challenge)
        XCTAssertEqual(body["model"] as? String, "v4.0")
        XCTAssertEqual(body["version"] as? String, "4.1.0")
        XCTAssertEqual(body["build"] as? String, s.manifest.build)
        XCTAssertEqual(body["key_id"] as? String, "d14d9aeeeecb3a238cb86c41a5e8b0c2")
        let core = try XCTUnwrap(body["core"] as? [String: Any])
        XCTAssertEqual(core["release"] as? String, "4.0.0-c1")
        XCTAssertEqual((core["proof"] as? String)?.count, 22, "16 bytes, base64url")
        XCTAssertEqual(Set(core.keys), ["release", "target", "proof", "signals", "piece"])
        // install_sig: the install key over "quranlab-lease-ask 1\n" challenge "\n" build "\n"
        let sig = try XCTUnwrap(Data(base64URL: try XCTUnwrap(body["install_sig"] as? String)))
        let text = Data("quranlab-lease-ask 1\n\(Self.challenge)\n\(s.manifest.build)\n".utf8)
        let pub = try P256.Signing.PublicKey(derRepresentation: s.key.spki)
        XCTAssertTrue(pub.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: sig), for: text))
        // the challenge carried the key and the token
        let ch = try XCTUnwrap(s.transport.requests.first { $0.url?.path.hasSuffix("v1/attest/challenge") == true })
        XCTAssertEqual(ch.value(forHTTPHeaderField: "x-qlab-key"), "qlk_v1_apps-one_sig")
        XCTAssertEqual(ch.value(forHTTPHeaderField: "authorization"), "Bearer qlt_test")
        // a valid lease is not asked for again: no network
        let before = s.transport.requests.count
        _ = try await s.runtime.ensureLease(s.manifest)
        XCTAssertEqual(s.transport.requests.count, before)
        XCTAssertTrue(s.runtime.hasValidLease(build: s.manifest.build))
        // the state the Core saved brings the lease back in a new Core
        let again = ProtectedRuntime(storage: s.storage, server: nil, keys: FixedKeys(s.key), state: s.state,
                                     clocks: FixedClocks(wall: 0, bootMs: 5_001_000, id: Array(SHA256.hash(data: Data("boot-1".utf8)))))
        let st = again.status()
        XCTAssertTrue(st.hasLease && st.valid, "the saved state holds the lease")
    }

    // MARK: install and open

    func testEveryEncryptedFileInstallsToItsDeviceForm() async throws {
        let s = try prepare()
        _ = try await s.runtime.ensureLease(s.manifest)
        let folder = try stageFolder(s)
        let encrypted = s.manifest.files.filter(\.isEncrypted)
        XCTAssertEqual(encrypted.count, 9)
        for f in encrypted {
            try s.runtime.install(s.manifest, decodedPath: f.localPath, in: folder)
            XCTAssertTrue(ModelInstaller.present(f, in: folder), "\(f.localPath): the device form, of the contract's size")
            let header = try Data(contentsOf: folder.appendingPathComponent(f.localPath + ".qld")).prefix(1024)
            XCTAssertEqual(Array(header.prefix(8)), [0x89, 0x51, 0x4C, 0x45, 0x0D, 0x0A, 0x1A, 0x0A])
            XCTAssertEqual(header[header.startIndex + 13], 2, "device form")
            XCTAssertTrue(String(decoding: header.dropFirst(96).prefix(24), as: UTF8.self).hasPrefix("Quran Lab TajweedFormer."), "the notice")
        }
        // nothing the SDK wrote is plaintext: no decoded file exists beside the containers
        for f in encrypted { XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(f.localPath).path)) }
        // the vector build has no layout file (P3b), so the Core stops after decrypting every file: manifestInvalid
        let folderModel = ModelFolder(id: ModelID("v4.0", repository: "Quran-Lab/test"), directory: folder, manifest: s.manifest,
                                      vocabulary: Vocabulary(symbols: (0..<38).map { "t\($0)" }, blank: 0),
                                      verifiedFiles: Set(encrypted.map(\.localPath)), coreMLProblem: "test")
        XCTAssertThrowsError(try s.runtime.openEngine(folderModel, context: "c16_l64")) { e in
            guard case RecognizerError.manifestInvalid = e else { return XCTFail("\(e)") }
        }
        // a changed byte in a device form: refused by its tag at the next install's check, and installed again
        let layers = folder.appendingPathComponent("layers.zfw.qld")
        var bytes = try Data(contentsOf: layers)
        bytes[2000] ^= 1
        try bytes.write(to: layers)
        XCTAssertThrowsError(try s.runtime.openEngine(folderModel, context: "c16_l64")) { e in
            guard case RecognizerError.checksumMismatch = e else { return XCTFail("\(e)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layers.path), "a device form that fails its tag goes")
    }

    // MARK: refusals

    /// A signed stop for another install and challenge (refusal_signed.json) is not acted on by the Core, so the lease
    /// stays; an unsigned stop neither.
    func testAStopThatIsNotThisRequestsChangesNothing() async throws {
        let s = try prepare()
        _ = try await s.runtime.ensureLease(s.manifest)
        let host = try XCTUnwrap(try s.runtime.host())
        for c in try XCTUnwrap(try V40.json("refusal_signed.json")["cases"] as? [[String: Any]]) {
            let body = try JSONSerialization.data(withJSONObject: try XCTUnwrap(c["body"] as? [String: Any]))
            XCTAssertFalse(host.refusal(body, apiKeyID: "apps-one"), c["name"] as? String ?? "")
        }
        XCTAssertTrue(s.runtime.hasValidLease(build: s.manifest.build))
    }

    /// 18.4.10: a token renewed once, a new challenge once, a new certificate once; then the answer decides.
    func testTheRepeatsTheTableAllowsHappenOnce() async throws {
        let s = try prepare(answer: { (r: URLRequest, n: Int) -> HTTPClient.Response? in
            guard r.url?.path.hasSuffix("v1/model-key") == true else { return nil }
            switch n {
            case 1: return Self.response(401, ["error": "invalid_token"])
            case 2: return Self.response(401, ["error": "challenge_invalid"])
            case 3: return Self.response(401, ["error": "install_cert_invalid", "why": "expired"])
            default: return nil
            }
        })
        let rec = try await s.runtime.ensureLease(s.manifest)
        XCTAssertEqual(rec.build, s.manifest.build)
        XCTAssertEqual(s.transport.bodies("v1/model-key").count, 4)
        XCTAssertEqual(s.certified.withLock { $0 }, 2, "the first certificate, then one more for install_cert_invalid")
    }

    func testARefusalThatIsNotAStopFailsAndBacksOff() async throws {
        let s = try prepare(answer: { (r: URLRequest, _: Int) -> HTTPClient.Response? in
            r.url?.path.hasSuffix("v1/model-key") == true ? Self.response(403, ["error": "lease_attestation_required"]) : nil
        })
        do throws(RecognizerError) {
            _ = try await s.runtime.ensureLease(s.manifest)
            XCTFail("no lease")
        } catch {
            guard case .serverRejected(403, "lease_attestation_required", _, _) = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(s.runtime.hasValidLease(build: s.manifest.build))
    }

    /// The route switched off (production answers 404 today): no lease, and the error says the route is off.
    func testTheRouteSwitchedOff() async throws {
        let s = try prepare(answer: { (r: URLRequest, _: Int) -> HTTPClient.Response? in
            r.url?.path.hasSuffix("v1/model-key") == true ? Self.response(404, ["error": "not_found"]) : nil
        })
        do throws(RecognizerError) {
            _ = try await s.runtime.ensureLease(s.manifest)
            XCTFail("no lease")
        } catch {
            guard case .serverRejected(404, "model_key_off", _, _) = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: the data piece (18.6.7, R9; piece.json)

    static func piece(_ i: Int) throws -> (id: Int, b64u: String, bytes: Data) {
        let p = try XCTUnwrap((try V40.json("piece.json")["pieces"] as? [[String: Any]])?[i])
        return (try XCTUnwrap(p["id"] as? Int), try XCTUnwrap(p["b64u"] as? String), V40.hex(try XCTUnwrap(p["bytes_hex"] as? String)))
    }

    /// The pieces signed with the pinned test key are taken; the refused ones change nothing.
    func testThePiecesOfTheVector() throws {
        try requireTestCore()
        let s = try prepare()
        let host = try XCTUnwrap(try s.runtime.host())
        let v = try V40.json("piece.json")
        for p in try XCTUnwrap(v["pieces"] as? [[String: Any]]) {
            XCTAssertTrue(host.piece(V40.hex(try XCTUnwrap(p["bytes_hex"] as? String))), p["name"] as? String ?? "")
        }
        for r in try XCTUnwrap(v["refused"] as? [[String: Any]]) {
            XCTAssertFalse(host.piece(V40.hex(try XCTUnwrap(r["bytes_hex"] as? String))), r["name"] as? String ?? "")
        }
    }

    /// The core.piece each lease request named, in order.
    static func named(_ s: Setup) -> [Int] {
        s.transport.bodies("v1/model-key").map { (($0["core"] as? [String: Any])?["piece"] as? Int) ?? -1 }
    }

    /// Spec fix 16 (quranlab-core d128af8, contract c7f6e9b): each answer's piece goes to the Core right after the
    /// accept, always, and the Core keeps it pending until the next model open. The vectors' build has no layout, so no
    /// model opens here: every lease asks under no piece, whatever the answers handed over (a piece with a changed
    /// signature byte among them), also after a restart from the saved state. The sequences with model opens are
    /// `PieceOrderTests` (piece_order.json, on a test build).
    func testAPieceStaysPendingWithoutAModelOpen() async throws {
        let p7 = try Self.piece(0), p8 = try Self.piece(1)
        let refused = try XCTUnwrap(try V40.json("piece.json")["refused"] as? [[String: Any]])
        let bad = try XCTUnwrap(refused.first { $0["name"] as? String == "one signature byte changed" })
        let badPiece = V40.hex(try XCTUnwrap(bad["bytes_hex"] as? String)).base64URL
        let s = try prepare(piece: { (n: Int) -> String? in n == 1 ? p7.b64u : n == 2 ? p8.b64u : n == 3 ? badPiece : p7.b64u })
        _ = try await s.runtime.ensureLease(s.manifest)
        _ = try await s.runtime.renew(s.manifest)
        _ = try await s.runtime.renew(s.manifest)
        XCTAssertEqual(Self.named(s), [0, 0, 0], "handed over, pending: no model opened")
        // a restart: a new Core from the state the last one saved, the pending piece in it
        let again = ProtectedRuntime(storage: s.storage, server: s.runtime.server, keys: FixedKeys(s.key), state: s.state,
                                     clocks: FixedClocks(wall: Int64(try XCTUnwrap(try V40.json("lease.json")["now"] as? Int)) * 1000 + 60_000,
                                                         bootMs: 5_060_000, id: Array(SHA256.hash(data: Data("boot-1".utf8)))))
        _ = try await again.renew(s.manifest)
        XCTAssertEqual(Self.named(s), [0, 0, 0, 0], "still pending after a restart with no open")
        XCTAssertTrue(again.hasValidLease(build: s.manifest.build))
    }

    /// Only a refusal goes to the Core (a 4xx with a body, 429 aside: 18.4.10): a 429 or a 503 makes no Core call
    /// (piece_order.json `busy`), so the lease in hand stays and the next ask is made as before.
    func testA429OrA5xxIsNotARefusal() async throws {
        let s = try prepare(answer: { (r: URLRequest, n: Int) -> HTTPClient.Response? in
            guard r.url?.path.hasSuffix("v1/model-key") == true else { return nil }
            switch n {
            case 2: return Self.response(429, ["error": "rate_limited"])
            case 3: return Self.response(503, ["error": "unavailable"])
            default: return nil
            }
        })
        _ = try await s.runtime.ensureLease(s.manifest)
        for status in [429, 503] {
            do throws(RecognizerError) {
                _ = try await s.runtime.renew(s.manifest)
                XCTFail("no lease on \(status)")
            } catch {}
            XCTAssertTrue(s.runtime.hasValidLease(build: s.manifest.build), "the lease in hand stays after a \(status)")
        }
        _ = try await s.runtime.renew(s.manifest)
        XCTAssertEqual(Self.named(s), [0, 0, 0, 0])
    }

    /// Without a piece in force a refused proof is not repeated.
    func testARefusedProofWithoutAPieceIsNotRepeated() async throws {
        let s = try prepare(answer: { (r: URLRequest, _: Int) -> HTTPClient.Response? in
            r.url?.path.hasSuffix("v1/model-key") == true ? Self.response(403, ["error": "lease_integrity_failed", "why": "core"]) : nil
        })
        do throws(RecognizerError) {
            _ = try await s.runtime.ensureLease(s.manifest)
            XCTFail("no lease")
        } catch {
            guard case .serverRejected(403, "lease_integrity_failed", _, _) = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(s.transport.bodies("v1/model-key").count, 1)
        // ERRORS_40 24.3 (69326fb): the report's error_code is the check the answer names
        XCTAssertEqual(s.runtime.lastFailure.withLock { $0 }?.cause,
                       ErrorCause(stage: "lease", reason: "integrity_failed", httpStatus: 403, errorCode: "core"))
    }

    /// ERRORS_40 24.3 (69326fb): a verdict refused at the lease: `integrity_failed`, `error_code` `verdict:boot`, the
    /// developer's message names the check, and the app's code is `server_rejected`.
    func testAnIntegrityRefusalOfTheLeaseNamesItsCheck() async throws {
        let s = try prepare(answer: { (r: URLRequest, _: Int) -> HTTPClient.Response? in
            r.url?.path.hasSuffix("v1/model-key") == true
                ? Self.response(403, ["error": "lease_integrity_failed", "message": "not verified", "why": "verdict", "check": "boot"]) : nil
        })
        do throws(RecognizerError) {
            _ = try await s.runtime.ensureLease(s.manifest)
            XCTFail("no lease")
        } catch {
            let cause = try XCTUnwrap(s.runtime.lastFailure.withLock { $0 }?.cause)
            XCTAssertEqual(cause, ErrorCause(stage: "lease", reason: "integrity_failed", httpStatus: 403, errorCode: "verdict:boot"))
            let made = TajweedError(from: error, cause: cause)
            XCTAssertEqual(made.code, "server_rejected")
            XCTAssertTrue(made.message.contains("verdict:boot"), made.message)
        }
    }

    // MARK: 18.4.7.1, the grace when Quran Lab cannot be reached

    /// Clocks the test moves: the wall and the boot clock together, on one boot (the Core's clock is the lease's anchor
    /// plus the boot clock, 18.4.7).
    final class MovingClocks: CoreClocks, @unchecked Sendable {
        private let t: Locked<(wall: Int64, boot: Int64)>
        let id = Array(SHA256.hash(data: Data("boot-1".utf8)))
        init(wallS: Int64) { t = Locked((wallS * 1000, 5_000_000)) }
        func wallMs() -> Int64 { t.withLock { $0.wall } }
        func boot() -> (ms: Int64, id: [UInt8]) { (t.withLock { $0.boot }, id) }
        func advance(seconds: Int64) { t.withLock { $0.wall += seconds * 1000; $0.boot += seconds * 1000 } }
    }

    /// What the scripted lease route answers after the first lease: a lease, a 503 lease_unavailable with Retry-After
    /// 30, a JSON refusal, or a 503 that comes late.
    enum Route: Sendable { case lease, unavailable, refusal, late(Double) }

    static func response(_ status: Int, _ body: [String: Any], headers: [String: String]) -> HTTPClient.Response {
        HTTPClient.Response(status: status, headers: headers, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }

    func prepareGrace(_ route: Locked<Route>) throws -> (Setup, MovingClocks, Locked<[ErrorCause]>) {
        let now = Int64(try XCTUnwrap(try V40.json("lease.json")["now"] as? Int))
        let clocks = MovingClocks(wallS: now)
        let s = try prepare(answer: { (r: URLRequest, n: Int) -> HTTPClient.Response? in
            guard r.url?.path.hasSuffix("v1/model-key") == true, n > 1 else { return nil }
            switch route.withLock({ $0 }) {
            case .lease: return nil
            case .unavailable:
                return Self.response(503, ["error": "lease_unavailable", "message": "try again"], headers: ["Retry-After": "30"])
            case .refusal: return Self.response(403, ["error": "lease_attestation_required", "message": "no"])
            case .late(let seconds):
                Thread.sleep(forTimeInterval: seconds)
                return Self.response(503, ["error": "lease_unavailable"], headers: ["Retry-After": "30"])
            }
        }, clocks: clocks, certValidity: 30 * 86_400)
        let silent = Locked<[ErrorCause]>([])
        s.runtime.onSilent = { c in silent.withLock { $0.append(c) } }
        return (s, clocks, silent)
    }

    /// Past exp with the server down (503 lease_unavailable): the open goes on in the grace, until exp + 86400, reported
    /// as lease, grace, 503, lease_unavailable; a second open within the minute asks nothing. Then a refusal ends the
    /// grace for good: a later 503 gives none back.
    func testGraceWhenUnreachableEndsAtARefusal() async throws {
        let route = Locked(Route.lease)
        let (s, clocks, silent) = try prepareGrace(route)
        let first = try await s.runtime.ensureLease(s.manifest)
        let exp = first.expiresAt
        clocks.advance(seconds: exp - s.runtime.status().now + 3600) // the Core's clock, anchored at the lease's iat
        route.withLock { $0 = .unavailable }
        XCTAssertFalse(s.runtime.hasValidLease(build: s.manifest.build), "past exp")
        let inGrace = try await s.runtime.ensureLease(s.manifest)
        XCTAssertEqual(inGrace.build, s.manifest.build)
        let g = try XCTUnwrap(try s.runtime.host()).leaseGrace()
        XCTAssertTrue(g.inGrace)
        XCTAssertEqual(g.until, exp + 86_400)
        XCTAssertEqual(silent.withLock { $0 }.last, ErrorCause(stage: "lease", reason: "grace", httpStatus: 503, errorCode: "lease_unavailable"))
        let asked = s.transport.bodies("v1/model-key").count
        _ = try await s.runtime.ensureLease(s.manifest)
        XCTAssertEqual(s.transport.bodies("v1/model-key").count, asked, "an unreachable outcome less than a minute old serves the open")
        // a refusal ends it (an open in the grace waits for the row of failures, 18.4.7.3: a wait drawn from 600 to
        // 1800 s)
        s.runtime.graceReuse = 0
        clocks.advance(seconds: s.runtime.retryState.notBefore - clocks.wallMs() / 1000 + 1)
        route.withLock { $0 = .refusal }
        do {
            _ = try await s.runtime.ensureLease(s.manifest)
            XCTFail("a refusal ends the grace")
        } catch {}
        XCTAssertFalse(try XCTUnwrap(try s.runtime.host()).leaseGrace().inGrace)
        route.withLock { $0 = .unavailable }
        do {
            _ = try await s.runtime.ensureLease(s.manifest)
            XCTFail("no grace after a refusal, whatever comes after")
        } catch {}
    }

    /// The grace ends at exp + 86400: at exp + 24.5 h with the server down the open fails.
    func testNoGraceAfterADay() async throws {
        let route = Locked(Route.lease)
        let (s, clocks, _) = try prepareGrace(route)
        let first = try await s.runtime.ensureLease(s.manifest)
        clocks.advance(seconds: first.expiresAt - s.runtime.status().now + 88_200)
        route.withLock { $0 = .unavailable }
        do {
            _ = try await s.runtime.ensureLease(s.manifest)
            XCTFail("no grace at exp + 24.5 h")
        } catch {}
        XCTAssertFalse(try XCTUnwrap(try s.runtime.host()).leaseGrace().inGrace)
    }

    /// An open past exp waits for its attempt at most `graceWait` (10 s; here 0.5 s): an answer that comes late is
    /// unreachable, and the open goes on in the grace with reason timeout.
    func testAnOpenWaitsAtMostTheGraceWait() async throws {
        let route = Locked(Route.lease)
        let (s, clocks, silent) = try prepareGrace(route)
        s.runtime.graceWait = 0.5
        let first = try await s.runtime.ensureLease(s.manifest)
        clocks.advance(seconds: first.expiresAt - s.runtime.status().now + 60)
        route.withLock { $0 = .late(3) }
        let t0 = Date()
        _ = try await s.runtime.ensureLease(s.manifest)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.5, "the open did not wait for the late answer")
        XCTAssertEqual(silent.withLock { $0 }.last?.reason, "grace")
        XCTAssertEqual(silent.withLock { $0 }.last?.errorCode, "timeout")
        try await Task.sleep(nanoseconds: 3_500_000_000)
    }

    /// 18.4.7.3 item 6 (SDK 4.0.2, dd76474): a run of 503 lease_unavailable with Retry-After 30 gives waits between 600
    /// and 1800 s, never 30 (4.0.1 waited the 30), and not one value each time; a valid lease opens with no request while
    /// a retry waits.
    func testTheRefreshBacksOffWhatever503sRetryAfterSays() async throws {
        let route = Locked(Route.lease)
        let (s, clocks, _) = try prepareGrace(route)
        let first = try await s.runtime.ensureLease(s.manifest)
        route.withLock { $0 = .unavailable }
        var waits: [Int64] = []
        for _ in 0..<3 {
            do {
                _ = try await s.runtime.renew(s.manifest)
                XCTFail("no lease on a 503")
            } catch {}
            let wait = s.runtime.retryState.notBefore - clocks.wallMs() / 1000
            waits.append(wait)
            clocks.advance(seconds: wait)
        }
        XCTAssertTrue(waits.allSatisfy { (600...1800).contains($0) }, "\(waits)")
        XCTAssertFalse(waits.contains(30))
        XCTAssertGreaterThan(Set(waits).count, 1, "drawn afresh at each failure: \(waits)")
        XCTAssertEqual(s.runtime.lastFailure.withLock { $0 }?.cause,
                       ErrorCause(stage: "lease", reason: "lease_unavailable", httpStatus: 503, errorCode: "lease_unavailable"))
        // one more failure: the row's wait is running now
        do {
            _ = try await s.runtime.renew(s.manifest)
            XCTFail("no lease on a 503")
        } catch {}
        XCTAssertFalse(s.runtime.retryState.due(now: clocks.wallMs() / 1000))
        // a valid lease opens with no request during the row (its refresh, when due, waits for the row)
        let asked = s.transport.bodies("v1/model-key").count
        XCTAssertTrue(s.runtime.hasValidLease(build: s.manifest.build))
        _ = try await s.runtime.ensureLease(s.manifest)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(s.transport.bodies("v1/model-key").count, asked, "no request while the row waits")
        XCTAssertGreaterThan(first.expiresAt, clocks.wallMs() / 1000)
    }

    /// 18.4.7.3 items 5 and 6, 28.11 item 3 (SDK 4.0.2, dd76474): the row and its next attempt outlive a restart: a new
    /// process on the same storage sends nothing on the lease route before the kept time (its refresh is due and
    /// waits), then its refresh asks, and the lease it gets ends the row on disk too.
    func testARestartWhileARetryWaitsSendsNothingBeforeTheKeptTime() async throws {
        let route = Locked(Route.lease)
        let (s, clocks, _) = try prepareGrace(route)
        let first = try await s.runtime.ensureLease(s.manifest)
        // past refresh_after, the lease still valid
        clocks.advance(seconds: first.refreshAfter - s.runtime.status().now + 60)
        XCTAssertTrue(s.runtime.hasValidLease(build: s.manifest.build))
        route.withLock { $0 = .unavailable }
        do {
            _ = try await s.runtime.renew(s.manifest)
            XCTFail("no lease on a 503")
        } catch {}
        let kept = s.runtime.retryState
        XCTAssertTrue((600...1800).contains(kept.notBefore - clocks.wallMs() / 1000), "\(kept)")
        let file = s.storage.appendingPathComponent("cloud/lease-retry.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the row is on disk")
        route.withLock { $0 = .lease }
        clocks.advance(seconds: 10)
        let again = ProtectedRuntime(storage: s.storage, server: s.runtime.server, keys: FixedKeys(s.key), state: s.state, clocks: clocks)
        XCTAssertEqual(again.retryState, kept, "the new process reads the row back")
        let asked = s.transport.bodies("v1/model-key").count
        _ = try await again.ensureLease(s.manifest)
        again.tick()
        clocks.advance(seconds: kept.notBefore - clocks.wallMs() / 1000 - 1)
        _ = try await again.ensureLease(s.manifest)
        again.tick()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(s.transport.bodies("v1/model-key").count, asked, "nothing before the kept time")
        clocks.advance(seconds: 1)
        _ = try await again.ensureLease(s.manifest)
        for _ in 0..<50 where s.transport.bodies("v1/model-key").count == asked { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(s.transport.bodies("v1/model-key").count, asked + 1, "at the kept time the refresh asks")
        for _ in 0..<50 where FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(again.retryState, LeaseRetry(), "the lease ended the row")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// 18.4.7.3 item 4: with no lease, an app's call asks at once even while the row waits (no Retry-After hold: the
    /// stand-in transport keeps none), and fails with the code it failed with before (here a 503 lease_unavailable:
    /// download_failed).
    func testACallWithNoLeaseAsksAtOnceDuringTheRow() async throws {
        let now = Int64(try XCTUnwrap(try V40.json("lease.json")["now"] as? Int))
        let clocks = MovingClocks(wallS: now)
        let s = try prepare(answer: { (r: URLRequest, _: Int) -> HTTPClient.Response? in
            guard r.url?.path.hasSuffix("v1/model-key") == true else { return nil }
            return Self.response(503, ["error": "lease_unavailable"], headers: ["Retry-After": "30"])
        }, clocks: clocks, certValidity: 30 * 86_400)
        var codes: [String] = []
        for _ in 0..<2 {
            do {
                _ = try await s.runtime.ensureLease(s.manifest)
                XCTFail("no lease on a 503")
            } catch {
                codes.append(TajweedError(from: error).code)
            }
            XCTAssertFalse(s.runtime.retryState.due(now: clocks.wallMs() / 1000), "the row waits")
        }
        XCTAssertEqual(s.transport.bodies("v1/model-key").count, 2, "each call asked at once")
        XCTAssertEqual(codes, ["download_failed", "download_failed"])
    }

    /// 18.4.7.3 item 2: a Retry-After longer than the drawn time is the wait (3000 s).
    func testALongRetryAfterIsTheWait() async throws {
        let now = Int64(try XCTUnwrap(try V40.json("lease.json")["now"] as? Int))
        let clocks = MovingClocks(wallS: now)
        let s = try prepare(answer: { (r: URLRequest, n: Int) -> HTTPClient.Response? in
            guard r.url?.path.hasSuffix("v1/model-key") == true, n > 1 else { return nil }
            return Self.response(503, ["error": "lease_unavailable"], headers: ["Retry-After": "3000"])
        }, clocks: clocks, certValidity: 30 * 86_400)
        _ = try await s.runtime.ensureLease(s.manifest)
        do {
            _ = try await s.runtime.renew(s.manifest)
            XCTFail("no lease on a 503")
        } catch {}
        XCTAssertEqual(s.runtime.retryState.notBefore - clocks.wallMs() / 1000, 3000)
    }

    /// A lease is held to the exp and refresh_after the Core accepted (18.4.7.2: never cut to a class's length).
    func testTheLeaseIsHeldToItsOwnExp() async throws {
        let s = try prepare()
        let rec = try await s.runtime.ensureLease(s.manifest)
        XCTAssertEqual(rec.expiresAt, Int64(try XCTUnwrap(s.fields["exp"] as? Int)))
        XCTAssertEqual(rec.refreshAfter, Int64(try XCTUnwrap(s.fields["refresh_after"] as? Int)))
    }

    // MARK: the grace fault matrix (Stage B Apple): each answer of the lease route past exp, through the real Core

    /// One fault past exp: what the lease route answers, how far past exp the open is, and what must happen. The
    /// answers are the ones a fault proxy gives (the staging rows' set); the Core, its clocks and saved state are real.
    struct GraceFault {
        let name: String
        let pastExp: Int64
        /// nil: no answer at all (the connection dropped)
        let answer: @Sendable () -> HTTPClient.Response?
        let grace: Bool
        let reason: String?
        let status: Int?
    }

    func testGraceFaultMatrix() async throws {
        let html = Data("<html><body>Blocked by policy</body></html>".utf8)
        let faults: [GraceFault] = [
            GraceFault(name: "503 lease_unavailable, Retry-After 30", pastExp: 3600,
                       answer: { Self.response(503, ["error": "lease_unavailable"], headers: ["Retry-After": "30"]) },
                       grace: true, reason: "lease_unavailable", status: 503),
            GraceFault(name: "500", pastExp: 3600, answer: { Self.response(500, ["error": "internal"], headers: [:]) },
                       grace: true, reason: "http", status: 500),
            GraceFault(name: "429 rate_limited", pastExp: 3600, answer: { Self.response(429, ["error": "rate_limited"], headers: ["Retry-After": "120"]) },
                       grace: true, reason: "rate_limited", status: 429),
            GraceFault(name: "connection dropped (no answer)", pastExp: 3600,
                       answer: { nil },
                       grace: true, reason: "network", status: nil),
            GraceFault(name: "403 with an HTML body (a firewall's page)", pastExp: 3600,
                       answer: { HTTPClient.Response(status: 403, headers: ["content-type": "text/html"], body: html) },
                       grace: true, reason: "http", status: 403),
            GraceFault(name: "200 that is not a lease (a captive portal)", pastExp: 3600,
                       answer: { HTTPClient.Response(status: 200, headers: ["content-type": "text/html"], body: html) },
                       grace: true, reason: "invalid_answer", status: 200),
            GraceFault(name: "403 JSON refusal (lease_attestation_required)", pastExp: 3600,
                       answer: { Self.response(403, ["error": "lease_attestation_required", "message": "no"], headers: [:]) },
                       grace: false, reason: nil, status: nil),
            GraceFault(name: "503 at exp + 23.5 h", pastExp: 84_600,
                       answer: { Self.response(503, ["error": "lease_unavailable"], headers: ["Retry-After": "30"]) },
                       grace: true, reason: "lease_unavailable", status: 503),
            GraceFault(name: "503 at exp + 24.5 h", pastExp: 88_200,
                       answer: { Self.response(503, ["error": "lease_unavailable"], headers: ["Retry-After": "30"]) },
                       grace: false, reason: nil, status: nil),
        ]
        var rows: [String] = []
        for f in faults {
            let now = Int64(try XCTUnwrap(try V40.json("lease.json")["now"] as? Int))
            let clocks = MovingClocks(wallS: now)
            let faulty = Locked(false)
            let s = try prepare(answer: { (r: URLRequest, n: Int) -> HTTPClient.Response? in
                guard faulty.withLock({ $0 }), r.url?.path.hasSuffix("v1/model-key") == true else { return nil }
                return f.answer()
            }, clocks: clocks, certValidity: 30 * 86_400)
            // no answer at all: the transport throws, as URLSession does for a dropped connection
            s.transport.drop = { (r: URLRequest) -> Bool in
                faulty.withLock { $0 } && r.url?.path.hasSuffix("v1/model-key") == true && f.answer() == nil
            }
            let silent = Locked<[ErrorCause]>([])
            s.runtime.onSilent = { c in silent.withLock { $0.append(c) } }
            let first = try await s.runtime.ensureLease(s.manifest)
            clocks.advance(seconds: first.expiresAt - s.runtime.status().now + f.pastExp)
            faulty.withLock { $0 = true }
            var opened = false
            var error = ""
            do {
                _ = try await s.runtime.ensureLease(s.manifest)
                opened = true
            } catch let e {
                error = TajweedError(from: e).code
            }
            let g = try XCTUnwrap(try s.runtime.host()).leaseGrace()
            let report = silent.withLock { $0 }.last { $0.reason == "grace" }
            var ok = opened == f.grace && g.inGrace == f.grace
            if f.grace {
                ok = ok && report?.errorCode == f.reason && report?.httpStatus == f.status
            }
            let observed = opened
                ? "opened in grace (until exp + \((g.until - first.expiresAt) / 3600) h); report lease/grace/\(report?.httpStatus.map(String.init) ?? "-")/\(report?.errorCode ?? "-")"
                : "no grace: \(error)"
            rows.append("GRACEROW | \(f.name) | \(f.grace ? "grace, report lease/grace/\(f.status.map(String.init) ?? "-")/\(f.reason ?? "-")" : "no grace") | \(observed) | \(ok ? "pass" : "FAIL")")
            XCTAssertTrue(ok, "\(f.name): \(observed)")
        }
        // a JSON refusal ends a grace that is running, and a later 503 gives none back (testGraceWhenUnreachableEndsAtARefusal)
        for r in rows { print(r) }
    }
}
