// Debug builds only: the Client's test stands in for the Core through StagingHooks.core (NoWaitHarness), which a release
// build does not have.
#if DEBUG
import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// Apple 4.0.2, 2026-11-24: `manifest`, `incompatible`, model_incompatible with fallback true, from installs of an app
/// at their first launch after its update from SDK 3.1.4. The 3.x Client stored its config in the same folder
/// (`cloud/config.json`, signed, valid for a day); SDK 4 put it in force at once, and `client.model()`, which asks for a
/// config only when none is in force, installed the build it named before the launch's own config request had
/// answered: a plain build for SDK 3. The first model host served that build's signed manifest, which SDK 4 refuses
/// (not encrypted); 4.0.2 took it for an unreachable host, asked every other host and failed on the first host's answer,
/// with fallback true, as if the first host had failed. The next call, after the launch's config, installed the right
/// build.
final class StaleConfigTests: XCTestCase {
    override func tearDown() {
        NoWaitHarness.tearDown()
        super.tearDown()
    }

    static let repo = "Quran-Lab/tajweedformer-v4"

    /// A plain build (no `encryption`, as every build for SDK 3 is), signed with the fixtures' key: its manifest.json and
    /// its build id.
    static func plainBuild() throws -> (data: Data, build: String) {
        let tokens = ModelManifest.File(path: "tokens.txt", size: 3, sha256: String(repeating: "a", count: 64), role: "tokens")
        var m = ModelManifest(modelID: "v4.0", revision: "v4.0-for-sdk3", version: "4.0.0", minSDKVersion: "3.0.0",
                              tokensSHA256: TwoContextBuild.tokensSHA256, defaultContext: "c16_l64", contexts: ["c16_l64"], files: [tokens])
        m.signature = try CloudFixtures.signer.signature(for: Data(m.signedText().utf8)).base64EncodedString()
        let data = m.jsonData()
        return (data, try ModelManifest.parse(data).build)
    }

    /// The config a 3.x Client of the app left in `storage`: signed, unexpired, naming the plain build.
    static func storeSDK3Config(_ storage: URL, build: String) {
        let r = CloudFixtures.config(models: [repo: build])
        let saved = ConfigStore.Saved(body: r.body, signature: r.headers["x-qlab-signature"] ?? "", keyID: r.headers["x-qlab-key-id"],
                                      etag: r.headers["etag"])
        JSONFile<ConfigStore.Saved>(url: storage.appendingPathComponent("cloud/config.json")).write(saved)
    }

    /// The first launch after the update, through the public Client: the config the 3.x Client stored names the plain
    /// build, and the launch's own config request (which names the encrypted build) answers only once the plain build's
    /// manifest has been asked for, as on a phone. `model()` opens the encrypted build in this one call, and the plain
    /// build's manifest is asked of its first host only. Red on 4.0.2 to fdef139: model_incompatible, and the plain
    /// manifest asked of all five hosts.
    func testTheFirstModelCallAfterAnUpdateFromSDK3InstallsTheBuildForThisSDK() async throws {
        let storage = CloudFixtures.storage()
        let plain = try Self.plainBuild()
        let build = try TwoContextBuild.manifest()
        Self.storeSDK3Config(storage, build: plain.build)
        NoWaitHarness.setUp(connection: .unmetered)
        let asked = StubProtocol.Gate()
        var config = CloudFixtures.config(models: [Self.repo: build.build])
        config.hold = asked
        let manifestHeaders = ["content-type": "application/json"]
        StubProtocol.reset(CloudFixtures.server(config: config, extra: { (s: StubProtocol.Seen) -> StubProtocol.Reply? in
            guard let p = TwoContextBuild.path(s) else { return nil }
            if s.url.path.contains("/\(plain.build)/") {
                // the config request the launch made answers from here on
                asked.open()
                // no other host holds the plain build
                guard s.url.host == "cdn.test", p == ModelManifest.fileName else { return .json(["error": "service_unavailable"], status: 503) }
                return StubProtocol.Reply(status: 200, headers: manifestHeaders, body: plain.data)
            }
            if p == ModelManifest.fileName { return StubProtocol.Reply(status: 200, headers: manifestHeaders, body: build.data) }
            guard let d = TwoContextBuild.data(p) else { return StubProtocol.Reply(status: 404) }
            return ModelDownloadTests.served(s, data: d)
        }))
        let client = try NoWaitHarness.client(storage)
        defer { client.close() }
        var failure: TajweedError?
        var opened: String?
        do throws(TajweedError) {
            opened = try await client.model().build
        } catch {
            failure = error
        }
        XCTAssertNil(failure, "the first model() after the update opens the model (4.0.2: model_incompatible): \(failure?.code ?? "")")
        XCTAssertEqual(opened, build.build, "the build the config for this SDK names")
        XCTAssertFalse(NoWaitHarness.installed.withLock { $0 }.isEmpty, "the encrypted build's files were installed")
        let plainAsked = StubProtocol.seen.filter { $0.url.path.contains("/\(plain.build)/") }.map { $0.url.host ?? "" }
        XCTAssertEqual(plainAsked, ["cdn.test"], "the plain build's manifest is its first host's answer: no backup host is asked for it")
    }

    /// The manifest on its own: a signed manifest of the build asked for that runs on no SDK of this version is the first
    /// host's answer. model_incompatible, one host asked, and the cause names no fallback. Red on 4.0.2 to fdef139: both
    /// hosts asked, fallback true.
    func testAManifestThatDoesNotRunOnThisSDKIsTheFirstHostsAnswer() async throws {
        let plain = try Self.plainBuild()
        let cdn = URL(string: "https://cdn.test")!, cdnB = URL(string: "https://cdn-b.test")!
        let endpoints = EndpointSet(api: [CloudFixtures.api], models: [cdn, cdnB])
        let client = CDNClient(http: HTTPClient(session: StubProtocol.session(), endpoints: endpoints), base: cdn.appendingPathComponent("models"),
                               auth: .fixed(key: CloudFixtures.key, token: "t"),
                               verifier: ManifestVerifier(trustedKeys: [CloudFixtures.signer.publicKey.rawRepresentation], requireSignature: true))
        let body = plain.data
        StubProtocol.reset { s in
            s.url.host == "cdn.test" ? StubProtocol.Reply(status: 200, headers: ["content-type": "application/json"], body: body)
                : .json(["error": "service_unavailable"], status: 503)
        }
        let id = ModelID("v4.0", repository: Self.repo, folder: "sdk/v4.0")
        let revision = plain.build
        let (failure, trace) = await RequestTrace.scope { () async -> (RecognizerError?, RequestTrace.Entry?) in
            do throws(RecognizerError) {
                _ = try await client.manifest(id, revision: revision)
                return (nil, RequestTrace.last)
            } catch {
                return (error, RequestTrace.last)
            }
        }
        guard case .modelIncompatible(_)? = failure else { return XCTFail("model_incompatible, not \(String(describing: failure))") }
        XCTAssertEqual(StubProtocol.seen.map { $0.url.host ?? "" }, ["cdn.test"], "no backup host is asked")
        XCTAssertEqual(trace?.role, .models)
        XCTAssertEqual(trace?.fallback, false)
    }

    /// An app's update from SDK 3.x leaves the plain build in the store, this device's own (its install record), and
    /// current. When the first `model()` cannot install the build for this SDK (here: no network, so no config), its
    /// error is the install's, as on a first install: needs_connection. Red on 4.0.2 to e5b08ba: model_incompatible,
    /// "not an encrypted build", the plain folder's own error (Apple 4.0.2 and 4.0.3, 11-24 and 11-25).
    func testAPlainModelLeftByAnUpdateIsNotTheErrorWhenTheInstallCannotFinish() async throws {
        let storage = CloudFixtures.storage()
        let plain = try Self.plainBuild()
        let base = storage.appendingPathComponent("models/v4.0")
        let dir = base.appendingPathComponent("v4.0-for-sdk3")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try plain.data.write(to: dir.appendingPathComponent(ModelManifest.fileName))
        try InstallRecord.write(.installed, build: plain.build, in: dir, keys: CloudFixtures.installKeys)
        try Data("v4.0-for-sdk3".utf8).write(to: base.appendingPathComponent("current"))
        NoWaitHarness.setUp(connection: .none)
        StubProtocol.reset { _ in .down }
        let client = try NoWaitHarness.client(storage)
        defer { client.close() }
        var code: String?
        do throws(TajweedError) {
            _ = try await client.model()
        } catch {
            code = error.code
        }
        XCTAssertEqual(code, "needs_connection", "offline, with the plain model an update left (4.0.2: model_incompatible)")
    }
}
#endif
