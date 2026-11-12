import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// Which contexts an accelerator build serves (SPEC 5.4, the shared vector `accelerator_serves.json`, SDK 3.0.2).
/// A build (`coreml`, `coreml-compact`) serves a context when the manifest lists its package for Apple for that
/// context and, first, the SIGNED tolerance has a well-formed entry under `<build>:<context>`, else a keep table is
/// listed for the context; else it does not, and nothing of the build is fetched for that context. No list of
/// contexts written into the SDK takes part. The vector's test key is trusted only here.
final class AcceleratorServesVectorTests: XCTestCase {
    static let builds = ["coreml", "coreml-compact"]

    struct Expected {
        let served: Bool
        let by: String?
        let toleranceKey: String?
    }

    struct Case {
        let name: String
        let manifest: ModelManifest
        /// build, then context
        let serves: [String: [String: Expected]]
    }

    /// Every case of the vector, its manifest opened as a folder's manifest without a config and compared with
    /// `expect` (every manifest of this vector is accepted).
    static func cases() throws -> [Case] {
        let v = try Vectors30.json("accelerator_serves.json")
        let sdk = try XCTUnwrap(v["sdk_version"] as? String)
        XCTAssertTrue(ModelManifest.version(SDKInfo.version, isAtLeast: sdk), "SDK \(SDKInfo.version) is not older than the vector's \(sdk)")
        let key = Manifest30VectorTests.bytes(try XCTUnwrap(v["public_key_hex"] as? String))
        XCTAssertEqual(ConfigVerifier.keyID(key), v["key_id"] as? String)
        XCTAssertNotEqual(key, ManifestVerifier.quranLabPublicKey, "the test key is not the SDK's")
        let verifier = ManifestVerifier(trustedKeys: [key], requireSignature: true)
        var out: [Case] = []
        for c in try XCTUnwrap(v["cases"] as? [[String: Any]]) {
            let name = try XCTUnwrap(c["name"] as? String)
            let data = Data(try XCTUnwrap(c["manifest"] as? String, name).utf8)
            XCTAssertEqual(Manifest30VectorTests.sha256(data), c["sha256"] as? String, "\(name): the manifest's bytes")
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            XCTAssertEqual(expect["outcome"] as? String, "ok", name)
            let m = try ModelManifest.accept(data, verifier: verifier, sdkVersion: SDKInfo.version)
            XCTAssertEqual(m.version, expect["version"] as? String, name)
            XCTAssertEqual(m.build, expect["build"] as? String, name)
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
            var serves: [String: [String: Expected]] = [:]
            let table = try XCTUnwrap(c["serves"] as? [String: [String: [String: Any]]], name)
            XCTAssertEqual(Set(table.keys), Set(builds), "\(name): both builds")
            for (build, contexts) in table {
                XCTAssertEqual(Set(contexts.keys), Set(m.contexts), "\(name) \(build): every context of the manifest")
                for (context, e) in contexts {
                    serves[build, default: [:]][context] = Expected(served: try XCTUnwrap(e["served"] as? Bool, name), by: e["by"] as? String,
                                                                    toleranceKey: e["tolerance_key"] as? String)
                }
            }
            out.append(Case(name: name, manifest: m, serves: serves))
        }
        XCTAssertEqual(out.count, 14)
        return out
    }

    /// Every case of the vector, asked of the SDK's own selection: for both builds and every context of the manifest,
    /// whether the build serves the context, by what, and the key of the tolerance the golden stage uses there. That
    /// tolerance is the entry under the key, or none (identical tokens decide).
    func testEveryCaseOfTheVector() throws {
        var byTolerance = 0, byKeepTable = 0, not = 0
        for c in try Self.cases() {
            for build in Self.builds {
                for context in c.manifest.contexts {
                    let at = "\(c.name), \(build), \(context)"
                    let want = try XCTUnwrap(c.serves[build]?[context], at)
                    let got = c.manifest.serving(build: build, context: context)
                    XCTAssertEqual(got != nil, want.served, at)
                    XCTAssertEqual(got?.by.rawValue, want.by, at)
                    XCTAssertEqual(got?.toleranceKey, want.toleranceKey, at)
                    let inForce = c.manifest.rawTolerance(build: build, context: context)
                    XCTAssertEqual(inForce, want.toleranceKey.flatMap { c.manifest.rawTolerance(build: $0) }, "\(at): the golden stage's tolerance")
                    XCTAssertEqual(inForce != nil, want.toleranceKey != nil, at)
                    switch got?.by {
                    case .tolerance?: byTolerance += 1
                    case .keepTable?: byKeepTable += 1
                    case nil: not += 1
                    }
                }
                XCTAssertNil(c.manifest.serving(build: build, context: "c99_l1"), "\(c.name): a context the manifest does not have is never served")
            }
            let context = c.manifest.defaultContext
            XCTAssertNil(c.manifest.serving(build: "npu:exynos2500:\(context)", context: context), "\(c.name): not an Apple build")
            XCTAssertNil(c.manifest.serving(build: "coreml:\(context)", context: context), "\(c.name): a tolerance key is not a build")
        }
        XCTAssertGreaterThan(byTolerance, 10)
        XCTAssertGreaterThan(byKeepTable, 10)
        XCTAssertGreaterThan(not, 60)
    }

    /// The download list: the accelerator files of a build for a context are listed exactly where the build serves
    /// the context, and nowhere else is anything of a build, a keep table or the self-test set listed. Where it
    /// serves, the list holds the build's package and none of the other build's; the context's keep table when
    /// the manifest lists one.
    func testADownloadListHoldsABuildsFilesExactlyWhereItServes() throws {
        var served = 0, not = 0
        for c in try Self.cases() {
            for build in Self.builds {
                for context in c.manifest.contexts {
                    let at = "\(c.name), \(build), \(context)"
                    let want = try XCTUnwrap(c.serves[build]?[context], at)
                    let profile = DownloadProfile(context: context, coreML: true, compact: build == "coreml-compact")
                    let files = profile.appleFiles(c.manifest)
                    XCTAssertEqual(!files.isEmpty, want.served, "\(at): accelerator files \(files.map(\.path))")
                    XCTAssertEqual(profile.files(c.manifest).count, profile.cpuFiles(c.manifest).count + files.count, at)
                    guard want.served else {
                        not += 1
                        XCTAssertNil(profile.programDelta(c.manifest), at)
                        continue
                    }
                    served += 1
                    XCTAssertTrue(files.contains { $0.role == build }, "\(at): the build's package")
                    let other = build == "coreml" ? "coreml-compact" : "coreml"
                    XCTAssertFalse(files.contains { $0.role == other }, "\(at): nothing of the other build")
                    let listed = c.manifest.files.filter { $0.role == "coreml-keeps" && $0.context == context }.map(\.path)
                    XCTAssertEqual(files.filter { $0.role == "coreml-keeps" }.map(\.path), listed, "\(at): the context's keep table when one is listed")
                    if want.by == "keep table" { XCTAssertFalse(listed.isEmpty, at) }
                }
            }
        }
        XCTAssertGreaterThan(served, 30)
        XCTAssertGreaterThan(not, 60)
    }
}
