import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// Model files come from one host: the folder URL, the base the app or the signed config names, and the old bare CDN
/// bases that keep their `/hf` paths.
final class ModelHostTests: XCTestCase {
    static let models = "https://cdn.quranlab.ai/models/Quran-Lab/tajweedformer-v4/abc/sdk/v4.0/"

    func folder(_ base: String) -> String {
        ModelHost.folderURL(base: URL(string: base)!, repository: "Quran-Lab/tajweedformer-v4", revision: "abc", folder: "sdk/v4.0").absoluteString
    }

    func verified(_ reply: StubProtocol.Reply) throws -> RemoteConfig {
        try ConfigVerifier(trustedKeys: [CloudFixtures.signer.publicKey.rawRepresentation])
            .verify(body: reply.body, signature: reply.headers["x-qlab-signature"], keyID: reply.headers["x-qlab-key-id"])
    }

    func resolved(base: Any?) throws -> String {
        let config = try verified(CloudFixtures.config(base: base))
        return ModelHost.folderURL(base: ModelHost.base(explicit: nil, config: config), repository: "Quran-Lab/tajweedformer-v4",
                                   revision: "abc", folder: "sdk/v4.0").absoluteString
    }

    func testTheDefaultBaseIsTheModelsPath() throws {
        XCTAssertEqual(ModelHost.defaultBase.absoluteString, "https://cdn.quranlab.ai/models")
        XCTAssertEqual(ModelHost.base(explicit: nil, config: nil), ModelHost.defaultBase)
        XCTAssertNil(CloudOptions().cdnURL, "the default leaves the config free to name a base")
        XCTAssertEqual(folder(ModelHost.defaultBase.absoluteString), Self.models)
        XCTAssertEqual(try resolved(base: nil), Self.models, "a config without a base")
    }

    func testASignedBaseIsUsed() throws {
        XCTAssertEqual(try resolved(base: "https://mirror.example/m"), "https://mirror.example/m/Quran-Lab/tajweedformer-v4/abc/sdk/v4.0/")
        XCTAssertEqual(try resolved(base: "https://mirror.example/"), "https://mirror.example/Quran-Lab/tajweedformer-v4/abc/sdk/v4.0/")
    }

    func testTheBareAndRegionalHostsKeepHF() throws {
        XCTAssertEqual(folder("https://cdn.quranlab.ai"), "https://cdn.quranlab.ai/hf/Quran-Lab/tajweedformer-v4/abc/sdk/v4.0/")
        XCTAssertEqual(folder("https://cdn.quranlab.ai/"), "https://cdn.quranlab.ai/hf/Quran-Lab/tajweedformer-v4/abc/sdk/v4.0/")
        for region in ["weur", "eeur", "enam", "wnam", "apac", "oc"] {
            XCTAssertEqual(folder("https://\(region).cdn.quranlab.ai"), "https://\(region).cdn.quranlab.ai/hf/Quran-Lab/tajweedformer-v4/abc/sdk/v4.0/")
        }
        XCTAssertEqual(try resolved(base: "https://cdn.quranlab.ai"), "https://cdn.quranlab.ai/hf/Quran-Lab/tajweedformer-v4/abc/sdk/v4.0/", "signed")
    }

    func testTheModelsPathNeverGetsHF() {
        XCTAssertEqual(folder("https://cdn.quranlab.ai/models"), Self.models)
        XCTAssertEqual(folder("https://cdn.quranlab.ai/models/"), Self.models)
        XCTAssertEqual(folder("https://eeur.cdn.quranlab.ai/models"), "https://eeur.cdn.quranlab.ai/models/Quran-Lab/tajweedformer-v4/abc/sdk/v4.0/")
    }

    func testOnlyTheExactHostsGetHF() {
        for near in ["https://xx.cdn.quranlab.ai", "https://cdn.quranlab.ai.evil.example", "https://evilcdn.quranlab.ai", "http://cdn.quranlab.ai"] {
            XCTAssertFalse(folder(near).contains("/hf/"), near)
        }
    }

    func testANonHTTPSBaseIsIgnored() throws {
        for bad: Any in ["http://evil.example", "ftp://evil.example/m", "evil.example", "", "https://", "https://evil.example/?x=1", 42, true, ["https://evil.example"]] {
            XCTAssertNil(try verified(CloudFixtures.config(base: bad)).modelBase, "\(bad)")
            XCTAssertEqual(try resolved(base: bad), Self.models, "\(bad) leaves the default, and the config still verifies")
        }
    }

    func testAnExplicitBaseWinsOverTheConfig() throws {
        let config = try verified(CloudFixtures.config(base: "https://mirror.example/m"))
        XCTAssertEqual(ModelHost.base(explicit: URL(string: "https://own.example/x")!, config: config).absoluteString, "https://own.example/x")
        XCTAssertEqual(ModelHost.base(explicit: nil, config: config).absoluteString, "https://mirror.example/m")
    }

    func testAMissingFolderMeansSdkModelID() throws {
        func rec(_ extra: [String: Any]) -> [String: Any] {
            ["model": "Quran-Lab/tajweedformer-v4", "model_id": "v4.0", "revision": "abc", "source": "stable"].merging(extra) { _, b in b }
        }
        for (name, r) in [("absent", rec([:])), ("empty", rec(["folder": ""])), ("not a string", rec(["folder": 7]))] {
            let got = try XCTUnwrap(try verified(CloudFixtures.config(recommended: r)).recommended, name)
            XCTAssertEqual(got.modelID.folder, "sdk/v4.0", name)
        }
        let named = try XCTUnwrap(try verified(CloudFixtures.config(recommended: rec(["folder": "sdk/other"]))).recommended)
        XCTAssertEqual(named.modelID.folder, "sdk/other")
    }

    // MARK: through the signed config and the updater

    static var recommended: [String: Any] {
        ["model": "Quran-Lab/tajweedformer-v4", "model_id": "v4.0", "folder": "sdk/v4.0", "revision": "rev-c", "source": "stable"]
    }

    func manifestRequest(_ config: StubProtocol.Reply, cdnURL: URL?, updates: UpdatePolicy = .automatic) async throws -> StubProtocol.Seen {
        StubProtocol.reset(CloudFixtures.server(config: config))
        let storage = CloudFixtures.storage()
        let cloud = CloudFixtures.cloud(storage: storage, options: CloudFixtures.options(updates: updates, storage: storage, cdnURL: cdnURL))
        _ = await cloud.refreshConfig()
        _ = await cloud.install(.v4_0, context: nil, activate: true)
        XCTAssertTrue(StubProtocol.seen("/manifest.json").isEmpty, "no file index")
        return try XCTUnwrap(StubProtocol.seen.first { $0.path.hasSuffix("/manifest.json") })
    }

    func testTheManifestComesFromTheDefaultWithTheAppKey() async throws {
        let seen = try await manifestRequest(CloudFixtures.config(recommended: Self.recommended), cdnURL: nil)
        XCTAssertEqual(seen.url.absoluteString, "https://cdn.quranlab.ai/models/Quran-Lab/tajweedformer-v4/rev-c/sdk/v4.0/manifest.json")
        XCTAssertEqual(seen.headers["x-qlab-key"], CloudFixtures.key)
    }

    func testTheManifestComesFromTheSignedBase() async throws {
        let seen = try await manifestRequest(CloudFixtures.config(recommended: Self.recommended, base: "https://mirror.example/m"), cdnURL: nil)
        XCTAssertEqual(seen.url.absoluteString, "https://mirror.example/m/Quran-Lab/tajweedformer-v4/rev-c/sdk/v4.0/manifest.json")
        XCTAssertEqual(seen.headers["x-qlab-key"], CloudFixtures.key)
    }

    func testTheAppsBaseWinsThroughTheUpdater() async throws {
        let seen = try await manifestRequest(CloudFixtures.config(recommended: Self.recommended, base: "https://mirror.example/m"),
                                             cdnURL: URL(string: "https://own.example/x")!)
        XCTAssertEqual(seen.url.absoluteString, "https://own.example/x/Quran-Lab/tajweedformer-v4/rev-c/sdk/v4.0/manifest.json")
    }

    func testABaseFromAConfigThatDoesNotVerifyIsNotUsed() async throws {
        let forged = CloudFixtures.config(base: "https://evil.example/m", key: Curve25519.Signing.PrivateKey())
        let seen = try await manifestRequest(forged, cdnURL: nil, updates: .pinned("rev-p"))
        XCTAssertEqual(seen.url.absoluteString, "https://cdn.quranlab.ai/models/Quran-Lab/tajweedformer-v4/rev-p/sdk/v4.0/manifest.json")
    }

    // MARK: the manifest's signature is what protects the download

    func client(_ body: Data) throws -> CDNClient {
        StubProtocol.reset { _ in StubProtocol.Reply(body: body) }
        return CDNClient(http: HTTPClient(session: StubProtocol.session()), base: ModelHost.defaultBase, key: "k",
                         verifier: ManifestVerifier(trustedKeys: [try Fixtures.v4miniKey()], requireSignature: true))
    }

    func testASignedManifestIsAcceptedAndATamperedOneRefused() async throws {
        let good = try Data(contentsOf: Fixtures.v4mini().appendingPathComponent("server/manifest.json"))
        let m = try await client(good).manifest(.v4_0, revision: "abc")
        XCTAssertEqual(m.modelID, "v4.0")
        var o = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        o["revision"] = "another"
        let bad = try JSONSerialization.data(withJSONObject: o)
        do {
            _ = try await client(bad).manifest(.v4_0, revision: "abc")
            XCTFail("a tampered manifest was accepted")
        } catch {
            guard case RecognizerError.signatureInvalid = error else { return XCTFail("\(error)") }
        }
    }
}
