import Foundation
import XCTest
@testable import TajweedFormer

/// After a move to another model id, the old id's folders leave the store (SDK 3.0.2): once a model of id X is
/// installed, verified and the one in use, the store folders of every other model id are removed. Until 3.0.1
/// nothing removed them, so `models/<old id>` stayed for ever. One test per rule:
/// - only folders of the SDK's own model store that are model folders, never arbitrary files or folders;
/// - never before the new one is verified and current;
/// - a failed or unverified install of the new id leaves the old id whole;
/// - `previous` inside the id in use is untouched;
/// - an install that is pinned stays as it is (the store's pinned revision, and a pinned model version).
/// The second model id of these tests is a made-up one (`test-other`): the rule is about ids, not about a model.
final class ModelStoreOtherIDsTests: XCTestCase {
    static let other = ModelID("test-other", repository: "Quran-Lab/test-other")
    let fm = FileManager.default

    override func tearDown() {
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    func store(_ root: URL, updates: UpdatePolicy = .automatic) -> ModelStore {
        ModelStore(root: root, verifier: ManifestVerifier(trustedKeys: [], requireSignature: false), updates: updates)
    }

    func root() -> URL {
        let d = fm.temporaryDirectory.appendingPathComponent("tf-ids-\(UUID().uuidString)/models")
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A verified revision `revision` of model `id` in the store: the bundled test folder under that id, placed as a
    /// finished download is. Not made current.
    func place(_ store: ModelStore, _ id: ModelID, _ revision: String) throws -> ModelFolder {
        let folder = store.downloadFolder(id, cdnRevision: revision)
        try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: Fixtures.v4mini().appendingPathComponent("decoded"), to: folder)
        let m = try Fixtures.manifest(for: folder, revision: revision)
        let named = ModelManifest(modelID: id.name, family: m.family, revision: revision, version: m.version, minSDKVersion: m.minSDKVersion,
                                  engineFormat: m.engineFormat, coremlFormat: m.coremlFormat, tokens: m.tokens, tokensSHA256: m.tokensSHA256,
                                  defaultContext: m.defaultContext, contexts: m.contexts, files: m.files)
        try named.write(to: folder)
        return try store.place(folder, id: id, cdnRevision: revision)
    }

    /// The folders and files directly under `dir`, sorted.
    func names(_ dir: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    /// Every regular file under `dir` with its size, as one string (to see that a folder is whole).
    func snapshot(_ dir: URL) -> [String] {
        guard let e = fm.enumerator(atPath: dir.path) else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            let path = dir.appendingPathComponent(rel).path
            let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue { out.append("\(rel) \(size ?? -1)") }
        }
        return out.sorted()
    }

    /// The move: the old id holds a current and a previous revision; the new id is installed, verified and made
    /// current. The old id's folder goes, whole; the new id's stays whole; what is not a model folder of the store
    /// stays: a file in the store's root (`recommended.json`), a folder with a stray file, a folder with a file the
    /// store does not write next to a revision.
    func testAfterAMoveToAnotherModelIDTheOldIDsFolderIsRemoved() throws {
        let root = root()
        let s = store(root)
        let old = ModelID.v4_0
        _ = try place(s, old, "rev-1")
        try s.activate(old, revision: "rev-1")
        _ = try place(s, old, "rev-2")
        try s.activate(old, revision: "rev-2")
        XCTAssertEqual(names(s.base(old)), ["current", "previous", "rev-1", "rev-2"])
        try Data("{}".utf8).write(to: root.appendingPathComponent("recommended.json"))
        try fm.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: root.appendingPathComponent("notes/readme.txt"))
        // a folder that looks like a model's and holds one file the store does not write
        try fm.createDirectory(at: root.appendingPathComponent("mixed/rev-9"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("mixed/rev-9/manifest.json"))
        try Data("rev-9".utf8).write(to: root.appendingPathComponent("mixed/current"))
        try Data("x".utf8).write(to: root.appendingPathComponent("mixed/extra.bin"))
        XCTAssertTrue(ModelStore.isStoreFolder(s.base(old)))
        XCTAssertFalse(ModelStore.isStoreFolder(root.appendingPathComponent("notes")), "a folder with a stray file")
        XCTAssertFalse(ModelStore.isStoreFolder(root.appendingPathComponent("mixed")), "a file the store does not write")
        XCTAssertFalse(ModelStore.isStoreFolder(root.appendingPathComponent("recommended.json")), "a file")

        let new = try place(s, Self.other, "rev-a")
        // placed and verified, not current yet: nothing goes
        XCTAssertEqual(s.removeOtherModels(inUse: new), [], "the new model is not current yet")
        XCTAssertEqual(names(root), ["mixed", "notes", "recommended.json", "test-other", "v4.0"])
        try s.activate(Self.other, revision: "rev-a")
        let whole = snapshot(s.base(Self.other))
        print("MODEL IDS before: \(names(root)); v4.0 holds \(names(s.base(old)))")
        XCTAssertEqual(s.removeOtherModels(inUse: new), ["v4.0"])
        print("MODEL IDS after: \(names(root)); test-other holds \(names(s.base(Self.other)))")
        XCTAssertEqual(names(root), ["mixed", "notes", "recommended.json", "test-other"])
        XCTAssertFalse(fm.fileExists(atPath: s.base(old).path), "the old id's folder is gone, current and previous")
        XCTAssertEqual(snapshot(s.base(Self.other)), whole, "the id in use is whole")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("notes/readme.txt"), encoding: .utf8), "mine")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("mixed/extra.bin").path))
        // the model in use still opens
        XCTAssertNoThrow(try ModelFolder.open(directory: new.directory, verifier: s.verifier, expecting: Self.other))
        // and a second call finds nothing more to remove
        XCTAssertEqual(s.removeOtherModels(inUse: new), [])
    }

    /// Never before the new one is verified and current: a revision that is staged (pending) next to a current one,
    /// a model that was placed and never made current, and a folder outside the store (the app's own, a bundled
    /// one) remove nothing.
    func testAModelThatIsNotTheCurrentOneOfItsIDRemovesNothing() throws {
        let root = root()
        let s = store(root)
        _ = try place(s, .v4_0, "rev-1")
        try s.activate(.v4_0, revision: "rev-1")
        let before = snapshot(s.base(.v4_0))
        let first = try place(s, Self.other, "rev-a")
        XCTAssertEqual(s.removeOtherModels(inUse: first), [], "placed, no current pointer")
        try s.activate(Self.other, revision: "rev-a")
        let staged = try place(s, Self.other, "rev-b")
        try s.markPending(Self.other, revision: "rev-b")
        XCTAssertEqual(s.removeOtherModels(inUse: staged), [], "staged for the next load, not current")
        XCTAssertEqual(snapshot(s.base(.v4_0)), before, "the old id is whole")
        // a folder of the same model outside the store
        let outside = fm.temporaryDirectory.appendingPathComponent("tf-ids-outside-\(UUID().uuidString)")
        try fm.copyItem(at: first.directory, to: outside)
        let own = try ModelFolder.open(directory: outside, verifier: s.verifier, expecting: Self.other)
        XCTAssertEqual(s.removeOtherModels(inUse: own), [], "not this store's folder")
        XCTAssertEqual(snapshot(s.base(.v4_0)), before)
    }

    /// `previous` inside the id in use is untouched, and so is a staged revision of it: only other ids go.
    func testPreviousAndPendingOfTheIDInUseAreUntouched() throws {
        let root = root()
        let s = store(root)
        _ = try place(s, .v4_0, "rev-1")
        try s.activate(.v4_0, revision: "rev-1")
        _ = try place(s, Self.other, "rev-a")
        try s.activate(Self.other, revision: "rev-a")
        let inUse = try place(s, Self.other, "rev-b")
        try s.activate(Self.other, revision: "rev-b")
        _ = try place(s, Self.other, "rev-c")
        try s.markPending(Self.other, revision: "rev-c")
        XCTAssertEqual(names(s.base(Self.other)), ["current", "pending", "previous", "rev-a", "rev-b", "rev-c"])
        let whole = snapshot(s.base(Self.other))
        XCTAssertEqual(s.removeOtherModels(inUse: inUse), ["v4.0"])
        XCTAssertEqual(s.previousRevision(Self.other), "rev-a")
        XCTAssertEqual(s.pendingRevision(Self.other), "rev-c")
        XCTAssertEqual(snapshot(s.base(Self.other)), whole, "current, previous and the staged revision are whole")
    }

    /// A store pinned to a revision stays as it is.
    func testAStorePinnedToARevisionStaysAsItIs() throws {
        let root = root()
        _ = try place(store(root), .v4_0, "rev-1")
        try store(root).activate(.v4_0, revision: "rev-1")
        let pinned = store(root, updates: .pinned("rev-a"))
        let new = try place(pinned, Self.other, "rev-a")
        try pinned.activate(Self.other, revision: "rev-a")
        XCTAssertEqual(pinned.removeOtherModels(inUse: new), [], "pinned")
        XCTAssertTrue(fm.fileExists(atPath: pinned.base(.v4_0).appendingPathComponent("rev-1/manifest.json").path))
        // the same store, not pinned: the old id goes
        XCTAssertEqual(store(root).removeOtherModels(inUse: new), ["v4.0"])
    }

    // MARK: through the install the SDK makes

    /// A store folder of another model id as an earlier install left it: a current revision with a manifest and a
    /// file, and a resumable download.
    func leaveAnotherID(in storage: URL) throws -> URL {
        let base = storage.appendingPathComponent("models/test-other")
        try fm.createDirectory(at: base.appendingPathComponent("rev-old/c16_l64"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent(".download-abc"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: base.appendingPathComponent("rev-old/manifest.json"))
        try Data(count: 4096).write(to: base.appendingPathComponent("rev-old/c16_l64/frames.zfw"))
        try Data("rev-old".utf8).write(to: base.appendingPathComponent("current"))
        return base
    }

    func cloud(_ storage: URL) throws -> QuranLabCloud {
        let keys = [CloudFixtures.signer.publicKey.rawRepresentation, try Fixtures.v4miniKey()]
        return CloudFixtures.cloud(storage: storage, options: CloudFixtures.options(signingKeys: keys, storage: storage))
    }

    /// The first install of the model the config names, on a device that still holds another model id: once the
    /// new model is downloaded, verified and current, the other id's folder is gone.
    func testInstallingTheModelInUseRemovesAnotherIDsFolder() async throws {
        try StubbedModelServer.serve()
        let storage = CloudFixtures.storage()
        let other = try leaveAnotherID(in: storage)
        let cloud = try cloud(storage)
        let outcome = await cloud.install(.v4_0, context: nil, activate: true)
        guard case .installed(let model, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(cloud.store.currentRevision(.v4_0), model.revision)
        XCTAssertFalse(fm.fileExists(atPath: other.path), "the other id's folder is gone")
        XCTAssertEqual(names(storage.appendingPathComponent("models")).filter { !$0.hasSuffix(".json") }, ["v4.0"])
    }

    /// An install pinned to a model version stays as it is: the other id's folder is kept.
    func testAnInstallPinnedToAModelVersionKeepsAnotherIDsFolder() async throws {
        try StubbedModelServer.serve()
        let storage = CloudFixtures.storage()
        let other = try leaveAnotherID(in: storage)
        let before = snapshot(other)
        let cloud = try cloud(storage)
        await cloud.pin(version: "4.0.0")
        let outcome = await cloud.install(.v4_0, context: nil, activate: true)
        guard case .installed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(snapshot(other), before, "pinned: the other id is whole")
    }

    /// A failed install of the new id leaves the old id whole: the download server lacks one of the model's files.
    func testAFailedInstallLeavesAnotherIDsFolderWhole() async throws {
        let server = try Fixtures.v4mini().appendingPathComponent("server")
        let build = String(Manifest30VectorTests.sha256(try Data(contentsOf: server.appendingPathComponent("manifest.json"))).prefix(40))
        StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(models: ["Quran-Lab/tajweedformer-v4": build]), extra: { s in
            guard s.url.host == CloudFixtures.cdn.host, let at = s.path.range(of: "/sdk/v4.0/") else { return nil }
            let path = String(s.path[at.upperBound...])
            guard !path.hasPrefix("layers.zfw"), let data = try? Data(contentsOf: server.appendingPathComponent(path)) else {
                return StubProtocol.Reply(status: 404)
            }
            return StubProtocol.Reply(status: 200, headers: ["content-type": "application/octet-stream"], body: data)
        }))
        let storage = CloudFixtures.storage()
        let other = try leaveAnotherID(in: storage)
        let before = snapshot(other)
        let cloud = try cloud(storage)
        let outcome = await cloud.install(.v4_0, context: nil, activate: true)
        if case .installed = outcome { XCTFail("the install must not succeed without the weights") }
        XCTAssertNil(cloud.store.currentRevision(.v4_0), "nothing became current")
        XCTAssertEqual(snapshot(other), before, "the old id is whole")
    }
}
