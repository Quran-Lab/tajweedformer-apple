import Foundation
import XCTest
@testable import TajweedFormer

/// The registration's `model_revision` is the revision of the model this install holds, whatever its id (3.1.5):
/// of the model Quran Lab's config names for the app, else of any model in the store. To 3.1.1 it was the revision
/// of the model id `v4.0` only, and an install on another model id sent none. The other model here has a made-up
/// id; the store's pointer files are written by the test (no model is downloaded), and the server is the suite's
/// stand-in.
final class RegisterRevisionTests: XCTestCase {
    override func tearDown() {
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// A made-up model, not one Quran Lab has.
    static let other = (id: "example-1.0", repository: "Example-Org/example-model", folder: "sdk/example-1.0")

    /// The store holds `revision` as the current revision of the model `id`, as an install leaves it.
    static func hold(_ storage: URL, id: String, revision: String) throws {
        let base = storage.appendingPathComponent("models/\(id)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent(revision), withIntermediateDirectories: true)
        try Data(revision.utf8).write(to: base.appendingPathComponent("current"))
    }

    /// A config that names the made-up model for this app.
    static func recommendingTheOther() -> StubProtocol.Reply {
        CloudFixtures.config(recommended: ["model": other.repository, "model_id": other.id, "folder": other.folder,
                                           "revision": String(repeating: "e", count: 40), "version": "1.0.0", "source": "stable"])
    }

    /// The body of the registration an install on `storage` sends, with `config` as the server's config.
    func registration(_ storage: URL, config: StubProtocol.Reply = CloudFixtures.config()) async throws -> [String: Any] {
        StubProtocol.reset(CloudFixtures.server(config: config))
        let cloud = CloudFixtures.cloud(storage: storage)
        _ = await cloud.refreshConfig()
        let sent = await cloud.register()
        XCTAssertTrue(sent, "the registration was sent")
        return try XCTUnwrap(StubProtocol.seen("/v1/register").last?.json)
    }

    /// The model the config names has another id than `v4.0`: its revision is sent.
    func testTheRevisionOfTheModelTheConfigNamesIsSentWhateverItsId() async throws {
        let storage = CloudFixtures.storage()
        try Self.hold(storage, id: Self.other.id, revision: "rev-example")
        let config = Self.recommendingTheOther()
        let body = try await registration(storage, config: config)
        XCTAssertEqual(body["model_revision"] as? String, "rev-example")
        // with another model beside it whose id sorts first: the config's model still decides
        let both = CloudFixtures.storage()
        try Self.hold(both, id: Self.other.id, revision: "rev-example")
        try Self.hold(both, id: "another-2.0", revision: "rev-another")
        let named = try await registration(both, config: config)
        XCTAssertEqual(named["model_revision"] as? String, "rev-example", "the model the config names")
    }

    /// Without a config that names a model: the store's model, whatever its id.
    func testTheRevisionOfTheOnlyModelInTheStoreIsSentWhateverItsId() async throws {
        let storage = CloudFixtures.storage()
        try Self.hold(storage, id: Self.other.id, revision: "rev-example")
        let body = try await registration(storage)
        XCTAssertEqual(body["model_revision"] as? String, "rev-example")
        // two models and no config naming one (an install holds one; this is the rule should it hold two): the
        // first by its id
        let both = CloudFixtures.storage()
        try Self.hold(both, id: Self.other.id, revision: "rev-example")
        try Self.hold(both, id: "another-2.0", revision: "rev-another")
        let first = try await registration(both)
        XCTAssertEqual(first["model_revision"] as? String, "rev-another")
    }

    /// As before: an install on `v4.0` sends its revision, and an install without a model sends none.
    func testAnInstallOnTheFirstModelIdAndOneWithoutAModelAreAsBefore() async throws {
        let storage = CloudFixtures.storage()
        try Self.hold(storage, id: "v4.0", revision: "rev-v4")
        let body = try await registration(storage)
        XCTAssertEqual(body["model_revision"] as? String, "rev-v4")
        let empty = try await registration(CloudFixtures.storage())
        XCTAssertNil(empty["model_revision"], "no model on the device: no revision")
        XCTAssertEqual(empty["new_install"] as? Bool, true)
    }
}
