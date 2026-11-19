import Foundation
import XCTest
@testable import TajweedFormer

/// The promotion key holds the whole accelerator program (every file the Core's prepare loads), so a build that changes
/// only model.mil (the A20 stride fix) is a new key with a fresh golden test.
final class ProgramDigestTests: XCTestCase {
    static func sha(_ c: Character) -> String { String(repeating: c, count: 64) }

    static func files(mil: Character = "a", weights: Character = "b", keeps: Character = "c") -> [ModelManifest.File] {
        let pkg = "coreml/tajweedformer_v4.mlmodelc"
        return [
            .init(path: "\(pkg)/model.mil", size: 10, sha256: sha(mil), platforms: ["apple"], role: "coreml"),
            .init(path: "\(pkg)/weights/weight.bin", size: 10, sha256: sha(weights), platforms: ["apple"], role: "coreml"),
            .init(path: "\(pkg)/metadata.json", size: 10, sha256: sha("d"), platforms: ["apple"], role: "coreml"),
            .init(path: "coreml/tajweedformer_v4.mlmodel", size: 10, sha256: sha("e"), platforms: ["apple"], role: "coreml"),
            .init(path: "c16_l64/keeps.bin", size: 10, sha256: sha(keeps), platforms: ["apple"], context: "c16_l64", role: "coreml-keeps"),
            // not the program of this build and context
            .init(path: "c24_l72/keeps.bin", size: 10, sha256: sha("f"), platforms: ["apple"], context: "c24_l72", role: "coreml-keeps"),
            .init(path: "coreml-compact/x.mlmodelc/model.mil", size: 10, sha256: sha("1"), platforms: ["apple"], role: "coreml-compact"),
            .init(path: "selftest/selftest.json", size: 10, sha256: sha("2"), role: "selftest"),
            .init(path: "layers.zfw", size: 10, sha256: sha("3"), context: "c16_l64", role: "weights"),
        ]
    }

    func digest(_ f: [ModelManifest.File], context: String = "c16_l64", compact: Bool = false) -> String? {
        AcceleratorController.programDigest(files: f, context: context, compact: compact)
    }

    func testEveryFileOfTheProgramChangesTheDigest() throws {
        let base = try XCTUnwrap(digest(Self.files()))
        XCTAssertEqual(base.count, 64)
        XCTAssertNotEqual(digest(Self.files(mil: "9")), base, "model.mil alone")
        XCTAssertNotEqual(digest(Self.files(weights: "9")), base, "weight.bin alone")
        XCTAssertNotEqual(digest(Self.files(keeps: "9")), base, "the context's keep table")
        // files the prepare does not load leave it as it is
        var other = Self.files()
        other.removeAll { $0.role == "selftest" || $0.role == "weights" || $0.context == "c24_l72" || $0.role == "coreml-compact" }
        XCTAssertEqual(digest(other), base)
        XCTAssertEqual(digest(Array(Self.files().reversed())), base, "in path order whatever the manifest's order")
        // the compact build is its own program; no package, no digest
        XCTAssertNotNil(digest(Self.files(), compact: true))
        XCTAssertNotEqual(digest(Self.files(), compact: true), base)
        XCTAssertNil(digest(Self.files().filter { $0.role != "coreml" }))
    }

    func testTheProgramIsPartOfThePromotionKey() throws {
        let a = AcceleratorController.key(revision: "r", context: "c16_l64", build: "coreml", osBuild: "23A100", deviceModel: "iPhone17,1",
                                          program: String(try XCTUnwrap(digest(Self.files())).prefix(16)))
        let b = AcceleratorController.key(revision: "r", context: "c16_l64", build: "coreml", osBuild: "23A100", deviceModel: "iPhone17,1",
                                          program: String(try XCTUnwrap(digest(Self.files(mil: "9"))).prefix(16)))
        XCTAssertNotEqual(a, b, "a new model.mil is a new key")
        // the parts the failure path reads are where they were
        XCTAssertEqual(a.split(separator: "|").prefix(2).map(String.init), ["r", "c16_l64"])
        XCTAssertEqual(AcceleratorController.key(revision: "r", context: "c", build: "coreml", osBuild: "o", deviceModel: "d"), "r|c|coreml|o|d")
    }
}
