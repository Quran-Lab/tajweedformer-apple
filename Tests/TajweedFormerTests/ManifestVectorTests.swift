import Foundation
import XCTest
@testable import TajweedFormer

/// The two real signed manifests of model V4 (the shared manifest vectors, verbatim): both verify with the key compiled
/// into the SDK (key id 660a07197c4808da) through the SDK's own verifier; each is refused with one changed byte in a
/// header value, in a tolerance value and in a file line; and the signed text of the build with `golden_tolerance`
/// carries its lines in the reference order (sorted by the build key's UTF-8 bytes, between the header and the file
/// lines). Any SDK that builds the signed text differently fails here, without the model.
final class ManifestVectorTests: XCTestCase {
    static let withTolerance = "manifest_v4.0_build519235d0_signed"
    static let withoutTolerance = "manifest_v4.0_build_d4644956_signed"

    func vector(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/manifest_vectors"))
        return try Data(contentsOf: url)
    }

    var pinned: ManifestVerifier { ManifestVerifier(trustedKeys: [ManifestVerifier.quranLabPublicKey], requireSignature: true) }

    func object(_ d: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any]) }

    func parse(_ o: [String: Any]) throws -> ModelManifest { try ModelManifest.parse(JSONSerialization.data(withJSONObject: o)) }

    /// One character of `s` changed (the last one, or the one at `at`), keeping its kind (hex stays hex, digits digits).
    static func flip(_ s: String, at: Int? = nil) -> String {
        var c = Array(s)
        let i = at ?? (c.count - 1)
        c[i] = c[i] == "0" ? "1" : c[i] == "a" ? "b" : c[i].isNumber ? "0" : c[i].isHexDigit ? "a" : "x"
        return String(c)
    }

    func testBothRealManifestsVerifyWithThePinnedKey() throws {
        XCTAssertEqual(ConfigVerifier.keyID(ManifestVerifier.quranLabPublicKey), "660a07197c4808da")
        for name in [Self.withTolerance, Self.withoutTolerance] {
            let m = try ModelManifest.parse(vector(name))
            XCTAssertNotNil(m.signature, name)
            XCTAssertNoThrow(try pinned.verifySignature(m, required: true), name)
        }
        // the tolerance is trusted: the signature covers its lines
        let t = try pinned.verifySignature(ModelManifest.parse(vector(Self.withTolerance)), required: true)
        XCTAssertEqual(t.tolerance(build: "coreml"), .init(tokenDiffs: 0, siteFlagDiffs: 1, wordFlagDiffs: 1))
        XCTAssertEqual(t.tolerance(build: "npu:tensor_g5:c16_l64"), .init(tokenDiffs: 0, siteFlagDiffs: 1, wordFlagDiffs: 1))
        let plain = try pinned.verifySignature(ModelManifest.parse(vector(Self.withoutTolerance)), required: true)
        XCTAssertTrue(plain.goldenTolerance.isEmpty)
        XCTAssertEqual(plain.tolerance(build: "coreml"), .exact)
    }

    func testOneChangedByteIsRefused() throws {
        for name in [Self.withTolerance, Self.withoutTolerance] {
            let o = try object(vector(name))
            // a header value
            var header = o
            header["revision"] = Self.flip(try XCTUnwrap(o["revision"] as? String))
            XCTAssertThrowsError(try pinned.verifySignature(parse(header), required: true), "\(name): revision")
            var sha = o
            sha["tokens_sha256"] = Self.flip(try XCTUnwrap(o["tokens_sha256"] as? String), at: 0)
            XCTAssertThrowsError(try pinned.verifySignature(parse(sha), required: true), "\(name): tokens_sha256")
            // a file line: one hex digit of a file's sha256, one digit of its size
            var files = try XCTUnwrap(o["files"] as? [[String: Any]])
            var f0 = files[0]
            f0["sha256"] = Self.flip(try XCTUnwrap(f0["sha256"] as? String), at: 0)
            files[0] = f0
            var line = o
            line["files"] = files
            XCTAssertThrowsError(try pinned.verifySignature(parse(line), required: true), "\(name): a file's sha256")
            files = try XCTUnwrap(o["files"] as? [[String: Any]])
            f0 = files[0]
            f0["size"] = try XCTUnwrap(f0["size"] as? Int) + 1
            files[0] = f0
            line["files"] = files
            XCTAssertThrowsError(try pinned.verifySignature(parse(line), required: true), "\(name): a file's size")
        }
        // a tolerance value (the build with golden_tolerance): refused, not quietly read as exact
        let o = try object(vector(Self.withTolerance))
        var tol = try XCTUnwrap(o["golden_tolerance"] as? [String: Any])
        var coreml = try XCTUnwrap(tol["coreml"] as? [String: Any])
        coreml["token_diffs"] = 1
        tol["coreml"] = coreml
        var loose = o
        loose["golden_tolerance"] = tol
        XCTAssertThrowsError(try pinned.verifySignature(parse(loose), required: true), "a tolerance value")
        // and the untouched vector still parses and verifies after the same JSON round trip
        XCTAssertNoThrow(try pinned.verifySignature(parse(o), required: true))
    }

    func testTheSignedTextHasTheToleranceLinesInTheReferenceOrder() throws {
        let m = try ModelManifest.parse(vector(Self.withTolerance))
        let lines = String(decoding: m.signedMessage, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let contexts = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("contexts ") })
        let firstFile = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("file ") })
        XCTAssertEqual(Array(lines[(contexts + 1)..<firstFile]), [
            "golden_tolerance coreml 0 1 1",
            "golden_tolerance coreml-compact 0 1 1",
            "golden_tolerance npu:exynos2500:c16_l64 0 1 1",
            "golden_tolerance npu:exynos2600:c16_l64 0 1 1",
            "golden_tolerance npu:tensor_g3:c16_l64 0 1 1",
            "golden_tolerance npu:tensor_g4:c16_l64 0 1 1",
            "golden_tolerance npu:tensor_g5:c16_l64 0 1 1",
        ])
        XCTAssertEqual(lines.first, "quranlab-model-manifest 3")
        XCTAssertFalse(lines[firstFile...].contains { $0.hasPrefix("golden_tolerance") }, "none after the file lines")
        let plain = try ModelManifest.parse(vector(Self.withoutTolerance))
        XCTAssertFalse(String(decoding: plain.signedMessage, as: UTF8.self).contains("golden_tolerance"))
        print("v4-manifest vectors: \(lines.filter { $0.hasPrefix("golden_tolerance") }.count) golden_tolerance lines, \(lines.filter { $0.hasPrefix("file ") }.count) file lines in the 519235d0 signed text")
    }
}
