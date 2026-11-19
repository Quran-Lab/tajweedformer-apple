import Foundation
import XCTest
@testable import TajweedFormer

/// Making the Client never downloads or installs a model: the first install of the CPU
/// set waits for the app's `client.model()` or `prefetch()`. The Client's start (its launch sequence: the
/// registration, the signed config, the queues, the update check) asks for no lease and no model file on a fresh
/// store. An update of a build the Client installed on this device is still checked at a later start.
///
/// The launch sequence that `TajweedClient(key:)` starts in the background is run here by the test, to its end, on a
/// server client over the stub API and CDN.
/// Tried before (to 3.1.4): the start's update check installed the model on a fresh store.
final class ClientStartTests: XCTestCase {
    /// A request for a lease or a model file: the model key route, or anything on the download server.
    static func modelRequests() -> [String] {
        StubProtocol.seen.filter { $0.path == "/v1/model-key" || $0.url.host == CloudFixtures.cdn.host || $0.path.contains("/models/") }
            .map { $0.url.absoluteString }
    }

    /// The files under the store's models folder.
    static func modelFiles(_ storage: URL) -> [String] {
        let root = storage.appendingPathComponent("models")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.path.dropFirst(root.path.count)) }
    }

    /// A build in the store under `revision`, made current: with this device's install record (the Client
    /// installed it) or without one (put there by something else).
    static func seed(_ storage: URL, revision: String, owned: Bool) throws {
        let base = storage.appendingPathComponent("models/v4.0")
        let dir = base.appendingPathComponent(revision)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{\"held\":\"\(revision)\"}".utf8).write(to: dir.appendingPathComponent(ModelManifest.fileName))
        if owned {
            let build = try XCTUnwrap(InstallRecord.buildOnDisk(dir))
            try InstallRecord.write(.installed, build: build, in: dir, keys: CloudFixtures.installKeys)
        }
        try Data(revision.utf8).write(to: base.appendingPathComponent("current"))
    }

    /// A Client made on a fresh store whose app makes no model call: its start registers and fetches the signed
    /// config, which names a model build, and asks for no lease and no model file; no model is on the device.
    func testAClientMadeOnAFreshStoreWithNoModelCallMakesNoModelRequest() async throws {
        StubProtocol.reset(CloudFixtures.server())
        let storage = CloudFixtures.storage()
        let cloud = CloudFixtures.cloud(storage: storage)
        defer { cloud.shutdown() }
        await cloud.launch()
        XCTAssertEqual(StubProtocol.seen("/v1/register").count, 1, "the start ran: it registered")
        XCTAssertNotNil(cloud.currentConfig?.models["Quran-Lab/tajweedformer-v4"], "and fetched the signed config, which names a model build")
        XCTAssertEqual(Self.modelRequests(), [], "no lease and no model request")
        XCTAssertNil(cloud.store.currentRevision(.v4_0), "no model is current")
        XCTAssertEqual(Self.modelFiles(storage), [], "no model file on the device")
    }

    /// A store holding a model this Client did not install (no install record of this device): the start neither
    /// downloads nor deletes; that is left to the app's `client.model()` or `prefetch()`.
    func testAModelTheClientDidNotInstallIsLeftToTheModelCall() async throws {
        let storage = CloudFixtures.storage()
        try Self.seed(storage, revision: "rev-a", owned: false)
        let before = Self.modelFiles(storage)
        StubProtocol.reset(CloudFixtures.server())
        let cloud = CloudFixtures.cloud(storage: storage)
        defer { cloud.shutdown() }
        await cloud.launch()
        XCTAssertEqual(StubProtocol.seen("/v1/register").count, 1, "the start ran")
        XCTAssertEqual(Self.modelRequests(), [], "no lease and no model request")
        XCTAssertEqual(Self.modelFiles(storage), before, "nothing deleted or added")
    }

    /// A later start of a Client on a store holding the build it installed, while the config names another build:
    /// that start's update check asks for the new build, as before.
    func testALaterStartStillChecksForAnUpdateOfTheBuildTheClientInstalled() async throws {
        let storage = CloudFixtures.storage()
        try Self.seed(storage, revision: "rev-a", owned: true)
        // the config names rev-b
        StubProtocol.reset(CloudFixtures.server())
        let cloud = CloudFixtures.cloud(storage: storage)
        defer { cloud.shutdown() }
        await cloud.launch()
        XCTAssertFalse(Self.modelRequests().isEmpty, "the later start's update check asked for the new build")
    }
}
