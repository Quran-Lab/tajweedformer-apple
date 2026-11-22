import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// The contract's SDK 4.0 vectors (quranlab-contract sdk_4.0.0/vectors at 7ee6ff4, test keys only), copied into
/// Fixtures/vectors40.
enum V40 {
    static func json(_ name: String) throws -> [String: Any] {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "vectors40", withExtension: nil, subdirectory: "Fixtures"))
        let data = try Data(contentsOf: dir.appendingPathComponent(name))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func hex(_ s: String) -> Data {
        var out = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    /// The contract's test signer (Ed25519): its public key, and its private key to sign test certificates.
    static func signer(_ v: [String: Any]) throws -> (public: Data, private: Curve25519.Signing.PrivateKey) {
        let s = try XCTUnwrap(v["signer"] as? [String: Any])
        let seed = hex(try XCTUnwrap(s["seed_hex"] as? String))
        return (hex(try XCTUnwrap(s["public_hex"] as? String)), try Curve25519.Signing.PrivateKey(rawRepresentation: seed))
    }

    /// manifest_40.json's signed manifest as the CDN serves it.
    static func manifest() throws -> (data: Data, object: [String: Any], signer: Data, signedText: String) {
        let v = try json("manifest_40.json")
        let m = try XCTUnwrap(v["manifest"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: m, options: [.sortedKeys])
        return (data, m, try signer(v).public, try XCTUnwrap(v["signed_text"] as? String))
    }
}

final class ProtectedVectorTests: XCTestCase {
    // MARK: install_sig (install_cert.json attest_proof)

    /// The text the SDK signs at `POST /v1/attest` is the contract's: each vector's signature verifies over it exactly
    /// when the vector says it is valid.
    func testTheAttestProofTextIsTheContracts() throws {
        let v = try V40.json("install_cert.json")
        let cases = try XCTUnwrap((v["attest_proof"] as? [String: Any])?["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 5)
        for c in cases {
            let name = c["name"] as? String ?? ""
            let agreement = try XCTUnwrap(Data(base64URL: try XCTUnwrap(c["install_key_b64u"] as? String)))
            let signing = try XCTUnwrap(Data(base64URL: try XCTUnwrap(c["install_sign_key_b64u"] as? String)))
            let sig = try XCTUnwrap(Data(base64URL: try XCTUnwrap(c["install_sig_b64u"] as? String)))
            let hash = Data(SHA256.hash(data: agreement)).hex
            let text = SoftwareInstallKey.attestText(challenge: c["challenge"] as? String, installHash: hash)
            let pub = try P256.Signing.PublicKey(derRepresentation: signing)
            let ok = (try? P256.Signing.ECDSASignature(derRepresentation: sig)).map { pub.isValidSignature($0, for: text) } ?? false
            XCTAssertEqual(ok, c["valid"] as? Bool, name)
        }
    }

    /// An install key's own proof verifies with its public key (one Apple key agrees and signs), with a challenge and
    /// with "-" without one.
    func testAnInstallKeysProofVerifies() throws {
        let key = SoftwareInstallKey(P256.KeyAgreement.PrivateKey())
        let pub = try P256.Signing.PublicKey(derRepresentation: key.spki)
        for challenge in ["c1.1790000300.AAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBB", nil] {
            let sig = try XCTUnwrap(Data(base64URL: try XCTUnwrap(key.attestProof(challenge: challenge))))
            let text = SoftwareInstallKey.attestText(challenge: challenge, installHash: key.installHash)
            XCTAssertTrue(pub.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: sig), for: text))
            XCTAssertTrue(String(data: text, encoding: .utf8)!.hasPrefix("quranlab-attest 1\n\(challenge ?? "-")\n"))
        }
        XCTAssertEqual(key.spki.count, 91, "SubjectPublicKeyInfo DER of a P-256 key")
        XCTAssertEqual(P256SPKI.wrap(key.agreement.publicKey.x963Representation), key.spki, "the SPKI the Secure Enclave path builds")
    }

    // MARK: the install certificate (install_cert.json cases)

    func testInstallCertificates() throws {
        let v = try V40.json("install_cert.json")
        let signer = try V40.signer(v).public
        let now = Int64(try XCTUnwrap(v["now"] as? Int))
        for c in try XCTUnwrap(v["cases"] as? [[String: Any]]) {
            let name = c["name"] as? String ?? ""
            let cert = InstallCertificate.parse(try XCTUnwrap(c["cert"] as? String), trustedKeys: [signer])
            switch c["refuse"] as? String {
            case "signature":
                XCTAssertNil(cert, name)
            case "expired":
                let parsed = try XCTUnwrap(cert, name)
                XCTAssertLessThanOrEqual(parsed.expiresAt, now, name)
            default:
                let parsed = try XCTUnwrap(cert, name)
                XCTAssertGreaterThan(parsed.expiresAt, now, name)
                let text = try XCTUnwrap(c["text"] as? String)
                XCTAssertTrue(text.contains("\ninstall \(parsed.install)\n"), name)
                XCTAssertTrue(text.contains("\nkey \(parsed.key)\n"), name)
                XCTAssertTrue(text.contains("\natt \(parsed.att)\n"), name)
            }
        }
        // a certificate signed by a key the SDK does not trust is refused
        XCTAssertNil(InstallCertificate.parse(try XCTUnwrap((v["cases"] as? [[String: Any]])?.first?["cert"] as? String),
                                              trustedKeys: [Data(repeating: 7, count: 32)]))
    }

    // MARK: the signed manifest (manifest_40.json)

    func testTheEncryptedManifestParsesAndVerifies() throws {
        let (data, _, signer, signedText) = try V40.manifest()
        let m = try ModelManifest.parse(data)
        XCTAssertEqual(m.encryption, ModelManifest.Encryption(keyID: "d14d9aeeeecb3a238cb86c41a5e8b0c2", root: 1))
        XCTAssertEqual(m.signedText(), signedText, "the signed text with the encryption line and the qle1 file lines")
        let trusted = try ManifestVerifier(trustedKeys: [signer], requireSignature: true).verifySignature(m, required: true)
        XCTAssertNoThrow(try trusted.checkCompatible(sdkVersion: "4.0.0"))
        let layers = try XCTUnwrap(m.file(local: "layers.zfw"))
        XCTAssertTrue(layers.isEncrypted)
        XCTAssertEqual(layers.path, "layers.zfw.qle")
        XCTAssertEqual(layers.deviceFormSize, 1024 + 3000 + 16)
        XCTAssertFalse(try XCTUnwrap(m.file(local: "calibration.json")).isEncrypted, "calibration stays plain")
    }

    /// One changed value in each signed line is refused (the vector's `refuse`).
    func testAChangedLineIsRefused() throws {
        let v = try V40.json("manifest_40.json")
        let (_, object, signer, _) = try V40.manifest()
        let verifier = ManifestVerifier(trustedKeys: [signer], requireSignature: true)
        for r in try XCTUnwrap(v["refuse"] as? [[String: Any]]) {
            let path = try XCTUnwrap(r["set"] as? [Any])
            let changed = try XCTUnwrap(Self.set(object, path[...], to: try XCTUnwrap(r["value"])) as? [String: Any])
            let data = try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys])
            var refused = false
            do {
                _ = try verifier.verifySignature(try ModelManifest.parse(data), required: true)
            } catch {
                refused = true
            }
            XCTAssertTrue(refused, "line \(r["line"] ?? "?")")
        }
    }

    static func set(_ value: Any, _ path: ArraySlice<Any>, to new: Any) -> Any {
        guard let first = path.first else { return new }
        if var o = value as? [String: Any], let k = first as? String {
            o[k] = set(o[k] as Any, path.dropFirst(), to: new)
            return o
        }
        if var a = value as? [Any], let i = first as? Int {
            a[i] = set(a[i], path.dropFirst(), to: new)
            return a
        }
        return value
    }

    /// A build without `encryption` is not one SDK 4.0 runs; a qle1 entry in such a manifest is malformed.
    func testOnlyAProtectedBuildIsCompatible() throws {
        var (_, object, _, _) = try V40.manifest()
        object["encryption"] = nil
        XCTAssertThrowsError(try ModelManifest.parse(try JSONSerialization.data(withJSONObject: object)))
    }

    // MARK: the device form (container.json)

    /// The size the SDK expects of a device form is the contract's (header, payload, a tag per MiB record), for every
    /// accepted device-form case of version 2.
    func testTheDeviceFormSize() throws {
        let v = try V40.json("container.json")
        var n = 0
        for c in try XCTUnwrap(v["accept"] as? [[String: Any]]) where (c["form"] as? Int) == 2 && (c["version"] as? Int) == 2 {
            let payload = try XCTUnwrap((c["payload_size"] as? Int) ?? ((c["plaintext"] as? [String: Any])?["size"] as? Int))
            let size = try XCTUnwrap((c["file_size"] as? Int) ?? (c["size"] as? Int))
            let f = ModelManifest.File(path: "x.qle", size: 0, sha256: String(repeating: "0", count: 64), role: "weights", encoding: "qle1",
                                       decoded: .init(path: "x", size: Int64(payload), sha256: String(repeating: "0", count: 64)))
            XCTAssertEqual(f.deviceFormSize, Int64(size), c["name"] as? String ?? "")
            n += 1
        }
        XCTAssertGreaterThan(n, 0, "the vector has device-form cases of version 2")
    }

    // MARK: the lease answer and the refusals (lease.json, refusal_signed.json, 18.4.10)

    func testALeaseAnswerParses() throws {
        let v = try V40.json("lease.json")
        let a = try XCTUnwrap((v["accept"] as? [[String: Any]])?.first)
        let f = try XCTUnwrap(a["fields"] as? [String: Any])
        let lease = V40.hex(try XCTUnwrap(a["lease_hex"] as? String))
        let body: [String: Any] = ["v": 1, "lease": lease.base64URL, "iat": f["iat"]!, "exp": f["exp"]!, "refresh_after": f["refresh_after"]!,
                                   "base": "https://cdn.quranlab.ai/models/Quran-Lab/m/b/sdk/v4.0/", "install_cert": "x.y"]
        let parsed = try XCTUnwrap(LeaseAnswer.parse(try JSONSerialization.data(withJSONObject: body)))
        XCTAssertEqual(parsed.lease, lease)
        XCTAssertEqual(parsed.expiresAt, Int64(try XCTUnwrap(f["exp"] as? Int)))
        XCTAssertNotNil(ProtectedRuntime.acceptedBase(parsed.base))
        // a base elsewhere, or over http, is never used
        XCTAssertNil(ProtectedRuntime.acceptedBase(URL(string: "https://example.org/models/")))
        XCTAssertNil(ProtectedRuntime.acceptedBase(URL(string: "http://cdn.quranlab.ai/models/")))
        XCTAssertNil(ProtectedRuntime.acceptedBase(URL(string: "https://quranlab.ai.example.org/")))
        // the C SDK's base_ok: a folder (ends in '/'), no port, user, query, fragment or ".."
        XCTAssertNotNil(ProtectedRuntime.acceptedBase(URL(string: "https://quranlab.ai/m/")))
        for bad in ["https://cdn.quranlab.ai/models/x", "https://cdn.quranlab.ai:8443/models/", "https://u@cdn.quranlab.ai/models/",
                    "https://cdn.quranlab.ai/models/?a=1/", "https://cdn.quranlab.ai/models/#x/", "https://cdn.quranlab.ai/a/../b/",
                    "https://.quranlab.ai/m/", "https://xquranlab.ai/m/"] {
            XCTAssertNil(ProtectedRuntime.acceptedBase(URL(string: bad)), bad)
        }
        // not version 1, no lease: not an answer
        XCTAssertNil(LeaseAnswer.parse(Data("{\"v\":2}".utf8)))
    }

    func testTheRefusalTable() throws {
        func body(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
        let v = try V40.json("refusal_signed.json")
        for c in try XCTUnwrap(v["cases"] as? [[String: Any]]) {
            let b = body(try XCTUnwrap(c["body"] as? [String: Any]))
            let r = LeaseRefusal.classify(status: try XCTUnwrap(c["status"] as? Int), body: b)
            // every stop body classifies as a stop; whether it is acted on is the Core's check of the signature
            guard case .stop = r else { return XCTFail("\(c["name"] ?? "") is a stop: \(r)") }
        }
        XCTAssertEqual(LeaseRefusal.classify(status: 401, body: body(["error": "invalid_token"])), .renewToken)
        XCTAssertEqual(LeaseRefusal.classify(status: 401, body: body(["error": "invalid_token", "reason": "key_revoked"])),
                       .stop(error: "invalid_token", reason: "key_revoked"))
        XCTAssertEqual(LeaseRefusal.classify(status: 401, body: body(["error": "install_cert_invalid", "why": "expired"])), .reattest(why: "expired"))
        XCTAssertEqual(LeaseRefusal.classify(status: 401, body: body(["error": "challenge_invalid"])), .newChallenge)
        XCTAssertEqual(LeaseRefusal.classify(status: 400, body: body(["error": "invalid_body"])), .sdkBug)
        XCTAssertEqual(LeaseRefusal.classify(status: 403, body: body(["error": "sdk_too_old", "min_sdk": "4.0.1"])), .sdkTooOld(minSDK: "4.0.1"))
        XCTAssertEqual(LeaseRefusal.classify(status: 403, body: body(["error": "lease_attestation_required"])),
                       .refused(code: "lease_attestation_required", why: nil))
        XCTAssertEqual(LeaseRefusal.classify(status: 403, body: body(["error": "lease_integrity_failed", "why": "core"])),
                       .refused(code: "lease_integrity_failed", why: "core"))
        XCTAssertEqual(LeaseRefusal.classify(status: 404, body: body(["error": "build_unknown"])), .buildUnknown)
        XCTAssertEqual(LeaseRefusal.classify(status: 404, body: body(["error": "not_found"])), .routeOff)
        XCTAssertEqual(LeaseRefusal.classify(status: 429, body: body(["error": "rate_limited"])), .later)
        XCTAssertEqual(LeaseRefusal.classify(status: 503, body: body(["error": "not_configured"])), .later)
    }

    /// 18.4.7.3 (SDK 4.0.2, dd76474): every failure waits a time drawn afresh, uniformly, from 600 to 1800 s; a
    /// Retry-After of 30 at every failure changes none of it (4.0.1 waited the 30).
    func testTheLeaseRetryWait() {
        var asked: [ClosedRange<Int64>] = []
        var r = LeaseRetry()
        for _ in 0..<7 { r.failed(now: 1000, retryAfter: 30, draw: { (range: ClosedRange<Int64>) -> Int64 in asked.append(range); return range.upperBound }) }
        XCTAssertEqual(asked, Array(repeating: 600...1800, count: 7))
        XCTAssertEqual(r.notBefore - 1000, 1800)
        // drawn afresh from the platform's random source at each failure: always inside the range, never the 30, and
        // spread (installs that failed together do not come back together)
        var drawn: Set<Int64> = []
        for _ in 0..<50 {
            var x = LeaseRetry()
            var waits: [Int64] = []
            for _ in 0..<5 {
                x.failed(now: 0, retryAfter: 30)
                waits.append(x.notBefore)
            }
            XCTAssertTrue(waits.allSatisfy { (600...1800).contains($0) }, "\(waits)")
            XCTAssertFalse(waits.contains(30))
            XCTAssertGreaterThan(Set(waits).count, 1, "a fresh draw at each failure: \(waits)")
            drawn.insert(waits[0])
        }
        XCTAssertGreaterThan(drawn.count, 10, "the waits are spread")
        XCTAssertFalse(r.due(now: 1000))
        XCTAssertTrue(r.due(now: 1000 + 1800))
        r.succeeded()
        XCTAssertTrue(r.due(now: 0))
    }

    /// 28.11 item 3 (SDK 4.0.2): the row as a start reads it back; a next attempt more than 21600 s ahead of the clock
    /// (a clock that moved back) is now; a nearer one is kept.
    func testTheLeaseRowReadBack() throws {
        var r = LeaseRetry()
        r.failed(now: 10_000, draw: { _ in 1000 })
        XCTAssertEqual(r.readBack(now: 10_500), r, "a wait that runs is kept")
        let back = r.readBack(now: 10_000 - 30_000)
        XCTAssertEqual(back.notBefore, 10_000 - 30_000, "a clock that moved back: the attempt is due now")
        XCTAssertEqual(back.failures, 1)
        // kept on disk by the runtime: a new runtime on the same storage reads it back
        let storage = Fixtures.storage()
        let f = JSONFile<LeaseRetry>(url: storage.appendingPathComponent("cloud/lease-retry.json"))
        f.write(r)
        let again = ProtectedRuntime(storage: storage, server: nil, keys: InstallKeyring(storage: storage),
                                     clocks: ProtectedCoreTests.MovingClocks(wallS: 10_200))
        XCTAssertEqual(again.retryState, r)
        XCTAssertFalse(again.retryState.due(now: 10_200))
    }

    // MARK: the vocabulary

    func testTheV4VocabularyIsCarriedByItsHash() throws {
        let v = try Vocabularies.vocabulary(sha256: "66fe6eb81b15506270f9e3c6efb0724cda757cd54326f26ca4bcd6be4f3b2aa4")
        XCTAssertEqual(v.count, 38)
        XCTAssertEqual(v.blank, 0)
        XCTAssertEqual(v.symbol(1), "|")
        XCTAssertThrowsError(try Vocabularies.vocabulary(sha256: String(repeating: "a", count: 64)))
    }

    // MARK: the 4.0 config (18.4.5; qlab-api sdk4-server)

    /// SDK 4.0's signed config names each build's key id and no base: the key id is read, the manifest is held to it,
    /// and the model folder is Quran Lab's CDN.
    func testTheConfigNamesTheKeyIDAndNoBase() throws {
        let build = String(repeating: "a", count: 40), kid = "d14d9aeeeecb3a238cb86c41a5e8b0c2"
        let o: [String: Any] = [
            "v": 1, "app": "ios:x", "channel": "stable", "issued_at": 1, "expires_at": 4_000_000_000, "denylist": [] as [Any],
            "flags": ["metrics": ["juz": true, "hours": false]] as [String: Any],
            "models": ["Quran-Lab/tajweedformer-v4": ["revision": build, "version": "4.1.0", "source": "stable", "model_id": "v4.0",
                                                      "folder": "sdk/v4.0", "key_id": kid]] as [String: Any],
            "recommended": ["model": "Quran-Lab/tajweedformer-v4", "model_id": "v4.0", "folder": "sdk/v4.0", "revision": build,
                            "version": "4.1.0", "source": "stable", "key_id": kid] as [String: Any],
        ]
        let c = try JSONDecoder().decode(RemoteConfig.self, from: JSONSerialization.data(withJSONObject: o))
        XCTAssertEqual(c.recommended?.key_id, kid)
        XCTAssertEqual(c.models["Quran-Lab/tajweedformer-v4"]?.key_id, kid)
        XCTAssertNil(c.base)
        XCTAssertEqual(ModelHost.manifestBase(explicit: nil), ModelHost.defaultBase)
        XCTAssertEqual(c.flags.metrics, ["juz": true, "hours": false])
        let m = try ModelManifest.parse(try V40.manifest().data)
        XCTAssertNoThrow(try m.checkKeyID(kid))
        XCTAssertNoThrow(try m.checkKeyID(nil))
        XCTAssertThrowsError(try m.checkKeyID("00000000000000000000000000000000"))
    }
}
