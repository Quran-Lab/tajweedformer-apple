import Foundation
import XCTest
@testable import TajweedFormer

/// The key compiled into the SDK verifies what production actually serves: a /v1/config response
/// captured from api.quranlab.ai, byte for byte.
final class ProductionKeyTests: XCTestCase {
    let body = #"{"v":1,"app":"ios:ai.quranlab.selftest","channel":"stable","issued_at":1790564473,"expires_at":1790650873,"models":{"Quran-Lab/zipformer_p-arabic-v3":{"revision":"506422c82a81c86e7ae74a5a2ab4641724bcd3b3","source":"stable"}},"denylist":[],"flags":{"analytics":true,"issues":true,"contributions":true}}"#
    let signature = "ed25519=7i4YtabWYrDTzXmWiw83cNrN-DpWFPbK1Qd4jKVxEigY3lMFI1cDploIW9OH9NNhR7kHxAc2tCPLG8M9LkFxCQ"

    func testCompiledKeyIdMatchesProduction() {
        XCTAssertEqual(ConfigVerifier.keyID(ManifestVerifier.quranLabPublicKey), "660a07197c4808da")
    }

    func testProductionConfigVerifiesWithTheCompiledKey() throws {
        let v = ConfigVerifier(trustedKeys: [ManifestVerifier.quranLabPublicKey])
        let cfg = try v.verify(body: Data(body.utf8), signature: signature, keyID: "660a07197c4808da",
                               now: Date(timeIntervalSince1970: 1790564474))
        XCTAssertEqual(cfg.v, 1)
    }

    func testOneChangedByteIsRefused() {
        let v = ConfigVerifier(trustedKeys: [ManifestVerifier.quranLabPublicKey])
        let tampered = Data(body.replacingOccurrences(of: "stable", with: "stabl3").utf8)
        XCTAssertThrowsError(try v.verify(body: tampered, signature: signature, keyID: "660a07197c4808da",
                                          now: Date(timeIntervalSince1970: 1790564474)))
    }
}
