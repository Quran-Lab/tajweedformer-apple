import Foundation
import XCTest
@testable import TajweedFormer

/// Which context a Session runs (`inference_context.json`): the app's choice, else the signed config's
/// `inference.context` when the build has it, else the manifest's default. Each case's config goes through the SDK's
/// own config type, so what the parser ignores is part of the test.
final class InferenceContextVectorTests: XCTestCase {
    func config(_ partial: [String: Any]) throws -> RemoteConfig {
        var o: [String: Any] = ["v": 1, "app": "ios:x", "channel": "stable", "issued_at": 1, "expires_at": 4_000_000_000, "models": [:] as [String: Any],
                                "denylist": [] as [Any], "flags": [:] as [String: Any]]
        for (k, v) in partial { o[k] = v }
        return try JSONDecoder().decode(RemoteConfig.self, from: JSONSerialization.data(withJSONObject: o))
    }

    func testEveryCaseOfTheVector() throws {
        let cases = try XCTUnwrap(try Vectors30.json("inference_context.json")["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 19)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let manifest = try XCTUnwrap(c["manifest"] as? [String: Any], name)
            let contexts = try XCTUnwrap(manifest["contexts"] as? [String], name)
            let fallback = try XCTUnwrap(manifest["default_context"] as? String, name)
            let cfg = try (c["config"] as? [String: Any]).map { try config($0) }
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            do throws(RecognizerError) {
                let got = try RemoteConfig.context(app: c["app"] as? String, inference: cfg?.inferenceContext, contexts: contexts, defaultContext: fallback)
                XCTAssertEqual(got.context, expect["context"] as? String, name)
                XCTAssertEqual(got.source, expect["source"] as? String, name)
                XCTAssertNil(expect["error"], name)
                // the call a Session makes gives the same context
                XCTAssertEqual(try RemoteConfig.context(app: c["app"] as? String, config: cfg, contexts: contexts, defaultContext: fallback), got.context, name)
            } catch {
                XCTAssertEqual(TajweedError(from: error).code, expect["error"] as? String, name)
            }
        }
    }
}
