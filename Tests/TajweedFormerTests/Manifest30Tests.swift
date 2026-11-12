import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// The shared manifest vectors of SDK 3.0.0 (`manifest_30.json`): what the SDK does with each manifest.json, in the
/// order of the acceptance checks, with the outcome every SDK must give. The vector's test key is trusted only here,
/// through the verifier's list of keys; it is never in the SDK.
final class Manifest30VectorTests: XCTestCase {
    static func bytes(_ hex: String) -> Data {
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// The catalogue code of what `accept` threw.
    static func code(_ e: any Error) -> String { (e as? RecognizerError).map { TajweedError(from: $0).code } ?? "\(e)" }

    func testEveryCaseOfTheVector() throws {
        let v = try Vectors30.json("manifest_30.json")
        let sdk = try XCTUnwrap(v["sdk_version"] as? String)
        // the vector is for the 3.0 line: `sdk_version` names the version it was built with, and this SDK is that
        // version or a later 3.0.x. The cases are judged as THIS SDK's version: every case holds for 3.0.0 to 3.0.99.
        XCTAssertTrue(ModelManifest.version(SDKInfo.version, isAtLeast: sdk), "SDK \(SDKInfo.version) is not older than the vector's \(sdk)")
        XCTAssertEqual(SDKInfo.version.split(separator: ".").prefix(2).joined(separator: "."), sdk.split(separator: ".").prefix(2).joined(separator: "."), "the same line of releases")
        let key = Self.bytes(try XCTUnwrap(v["public_key_hex"] as? String))
        XCTAssertEqual(ConfigVerifier.keyID(key), v["key_id"] as? String)
        XCTAssertNotEqual(key, ManifestVerifier.quranLabPublicKey, "the test key is not the SDK's")
        let verifier = ManifestVerifier(trustedKeys: [key], requireSignature: true)
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 35)
        var accepted = 0, refused = 0
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let data = Data(try XCTUnwrap(c["manifest"] as? String, name).utf8)
            XCTAssertEqual(Self.sha256(data), c["sha256"] as? String, "\(name): the manifest's bytes")
            let config = c["config"] as? [String: Any]
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            let m: ModelManifest
            do {
                m = try ModelManifest.accept(data, verifier: verifier, build: config?["revision"] as? String,
                                             version: config?["version"] as? String, sdkVersion: SDKInfo.version)
            } catch {
                XCTAssertEqual(expect["outcome"] as? String, "refused", "\(name): refused with \(error)")
                XCTAssertEqual(Self.code(error), expect["code"] as? String, name)
                refused += 1
                continue
            }
            accepted += 1
            XCTAssertEqual(expect["outcome"] as? String, "ok", "\(name): accepted")
            XCTAssertEqual(m.version, expect["version"] as? String, name)
            XCTAssertEqual(m.build, expect["build"] as? String, name)
            XCTAssertEqual(m.build, String(Self.sha256(data).prefix(40)), "\(name): the build id is the manifest's SHA-256, 40 hex")
            XCTAssertEqual(m.goldenToleranceSigned, expect["golden_tolerance_signed"] as? Bool, name)
            XCTAssertEqual(m.goldenRawSigned, expect["golden_raw_signed"] as? Bool, name)
            if let want = expect["golden_raw_tolerance"] as? [String: Any] {
                XCTAssertEqual(Set(m.goldenRaw.keys), Set(want.keys), "\(name): the well-formed builds")
                for (build, entry) in want {
                    let reference = try XCTUnwrap(GoldenRawTolerance.build(build, JSONValue(any: entry)), "\(name) \(build)").tolerance
                    XCTAssertEqual(m.rawTolerance(build: build), reference, "\(name) \(build)")
                }
            } else {
                XCTAssertTrue(m.goldenRaw.isEmpty, "\(name): no tolerance in force")
            }
            XCTAssertEqual(m.tokensOnlyBuilds, expect["tokens_only_builds"] as? [String], name)
            XCTAssertEqual(m.signedText(tolerance: m.goldenToleranceSigned, raw: m.goldenRawSigned), c["signed_text"] as? String,
                           "\(name): the text the signature verified on")
        }
        XCTAssertEqual(accepted + refused, cases.count)
        XCTAssertGreaterThan(accepted, 8)
        XCTAssertGreaterThan(refused, 20)
    }

    /// A folder's manifest goes through the same checks in production: the SDK's own verifier refuses every case of
    /// the vector (it does not trust the test key), and a verifier that does not require a signature is test only.
    func testTheSDKsOwnKeyRefusesTheTestKeysManifests() throws {
        let v = try Vectors30.json("manifest_30.json")
        let production = ManifestVerifier(trustedKeys: [ManifestVerifier.quranLabPublicKey], requireSignature: true)
        for c in try XCTUnwrap(v["cases"] as? [[String: Any]]) {
            let data = Data(try XCTUnwrap(c["manifest"] as? String).utf8)
            XCTAssertThrowsError(try ModelManifest.accept(data, verifier: production), c["name"] as? String ?? "?")
        }
        XCTAssertTrue(ManifestVerifier.standard.requireSignature, "outside tests a signature is always required")
    }

    func testVersions() throws {
        let v = try XCTUnwrap(try Vectors30.json("manifest_30.json")["versions"] as? [String: Any])
        for s in try XCTUnwrap(v["valid"] as? [String]) { XCTAssertNotNil(ModelVersion(s), s) }
        for s in try XCTUnwrap(v["invalid"] as? [String]) {
            XCTAssertNil(ModelVersion(s), "'\(s)'")
            XCTAssertFalse(ModelManifest.version(s, isAtLeast: "0.0.0"), "'\(s)' is never ordered")
            XCTAssertFalse(ModelManifest.version("9999.0.0", isAtLeast: s), "'\(s)' is never ordered")
        }
        for o in try XCTUnwrap(v["order"] as? [[Any]]) {
            let a = try XCTUnwrap(ModelVersion(try XCTUnwrap(o[0] as? String))), b = try XCTUnwrap(ModelVersion(try XCTUnwrap(o[1] as? String)))
            let want = try XCTUnwrap(o[2] as? Int)
            XCTAssertEqual(a < b ? -1 : a == b ? 0 : 1, want, "\(o[0]) against \(o[1])")
            XCTAssertEqual(ModelManifest.version(try XCTUnwrap(o[0] as? String), isAtLeast: try XCTUnwrap(o[1] as? String)), want >= 0)
        }
    }

    /// The two production manifests of V4 (2.x builds): their signatures verify with the production key, and SDK 3.0.0
    /// refuses both, because a 2.x build has no version.
    func testTheProductionManifestsOf2xAreRefused() throws {
        let v = try Vectors30.json("manifest_30.json")
        let real = try XCTUnwrap(v["real_manifests"] as? [[String: Any]])
        XCTAssertEqual(real.count, 2)
        for r in real {
            let file = try XCTUnwrap(r["file"] as? String)
            let name = String(try XCTUnwrap(file.split(separator: "/").last).dropLast(5))
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/manifest_vectors"), file)
            let data = try Data(contentsOf: url)
            let key = Self.bytes(try XCTUnwrap(r["trusted_key"] as? String))
            XCTAssertEqual(key, ManifestVerifier.quranLabPublicKey, "the production key")
            let verifier = ManifestVerifier(trustedKeys: [key], requireSignature: true)
            XCTAssertNoThrow(try verifier.verifySignature(ModelManifest.parse(data), required: true), "\(file): the signature verifies")
            XCTAssertThrowsError(try ModelManifest.accept(data, verifier: verifier), file) {
                XCTAssertEqual(Self.code($0), (r["expect"] as? [String: Any])?["code"] as? String, file)
            }
        }
    }
}
