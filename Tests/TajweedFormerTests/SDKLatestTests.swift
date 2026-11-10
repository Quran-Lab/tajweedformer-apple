import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// `sdk_latest` in the signed config: one debug line per launch when the SDK is older; none when equal, older or
/// malformed. And a config with fields this SDK does not know still verifies and parses (the signature covers the
/// bytes as received; the decoder ignores unknown top-level fields), so adding the field breaks no installed app.
final class SDKLatestTests: XCTestCase {
    let lines = Locked<[String]>([])

    override func setUp() {
        let lines = self.lines
        SDKLatest.logged.withLock { $0 = false }
        SDKLatest.sink.withLock { $0 = { line in lines.withLock { $0.append(line) } } }
    }

    func body(_ latest: Any?) -> Data {
        var o: [String: Any] = ["v": 1]
        if let latest { o["sdk_latest"] = latest }
        return try! JSONSerialization.data(withJSONObject: o)
    }

    func testANewerSDKIsLoggedOncePerLaunch() {
        let b = body(["version": "2.1.0", "severity": "recommended", "url": "https://github.com/Quran-Lab/tajweedformer-apple/releases"])
        SDKLatest.note(body: b, running: "2.0.1")
        SDKLatest.note(body: b, running: "2.0.1")
        XCTAssertEqual(lines.withLock { $0 },
                       ["Quran Lab SDK 2.1.0 is available (recommended), you have 2.0.1: https://github.com/Quran-Lab/tajweedformer-apple/releases"])
    }

    func testEqualOlderOrMalformedSayNothing() {
        let cases: [Any?] = [
            ["version": "2.0.1", "severity": "info", "url": "https://x"], ["version": "2.0.0", "severity": "info", "url": "https://x"],
            ["version": "2.0", "severity": "info", "url": "https://x"], ["version": "3.0.0-beta", "severity": "info", "url": "https://x"],
            ["version": "v3", "severity": "info", "url": "https://x"], ["version": 3, "severity": "info", "url": "https://x"],
            ["version": "3.0.0", "url": "https://x"], ["version": "3.0.0", "severity": "info"], "3.0.0", nil,
        ]
        for latest in cases { SDKLatest.note(body: body(latest), running: "2.0.1") }
        SDKLatest.note(body: Data("not json".utf8), running: "2.0.1")
        XCTAssertEqual(lines.withLock { $0 }, [])
    }

    func testVersionOrder() {
        XCTAssertTrue(SDKLatest.isNewer("2.0.10", than: "2.0.9"))
        XCTAssertTrue(SDKLatest.isNewer("2.1", than: "2.0.9"))
        XCTAssertFalse(SDKLatest.isNewer("2.0.1.0", than: "2.0.1"))
        XCTAssertFalse(SDKLatest.isNewer("junk", than: "2.0.1"))
        XCTAssertFalse(SDKLatest.isNewer("3.0.0", than: "junk"))
    }

    /// The 2.0.0 parser and this one are the same code (ConfigVerifier.verify: Ed25519 over the body bytes as received,
    /// then JSONDecoder on RemoteConfig, whose synthesized decoding ignores keys it does not declare).
    func testAConfigWithUnknownTopLevelFieldsVerifiesAndParses() throws {
        let r = CloudFixtures.config(extra: ["sdk_latest": ["version": "2.1.0", "severity": "required", "url": "https://x"],
                                            "some_future_field": ["a": [1, 2, 3]]])
        let v = ConfigVerifier(trustedKeys: [CloudFixtures.signer.publicKey.rawRepresentation])
        let cfg = try v.verify(body: r.body, signature: r.headers["x-qlab-signature"], keyID: r.headers["x-qlab-key-id"])
        XCTAssertEqual(cfg.models["Quran-Lab/tajweedformer-v4"]?.revision, "rev-b")
        // the signature covers those bytes: a change to the new field fails the check
        let tampered = Data(String(decoding: r.body, as: UTF8.self).replacingOccurrences(of: "2.1.0", with: "9.9.9").utf8)
        XCTAssertThrowsError(try v.verify(body: tampered, signature: r.headers["x-qlab-signature"], keyID: r.headers["x-qlab-key-id"]))
    }
}
