import Foundation
import XCTest
@testable import TajweedFormer

/// After a move to another model id, the old id's files leave the store (SDK 4.0.1; 3.0.2's rule, 124b335, in 4.0's
/// store of protected builds): once a model of id X is installed and the one in use, the store folders of every
/// other model id are removed, and nothing else. One test per rule:
/// - only folders of the SDK's own model store that are model folders, never other files or folders, and never the
///   sharing outbox, the learner's choices, the lease or the Core's state (they live outside `models/`);
/// - never before the model in use is current;
/// - `previous` and a pending revision of the id in use are untouched;
/// - a pinned store stays as it is;
/// - the id of a Model that is open, of the model a Client is opening, and of a download under way (an install
///   running, or ranges the background session carries) stay.
/// The other model ids are made-up ones: the rule is about ids, not about a model.
final class ModelStoreOtherIDsTests: XCTestCase {
    static let other = ModelID("test-other", repository: "Quran-Lab/test-other")
    static let third = ModelID("test-third", repository: "Quran-Lab/test-third")
    static let fourth = ModelID("test-fourth", repository: "Quran-Lab/test-fourth")
    static let fifth = ModelID("test-fifth", repository: "Quran-Lab/test-fifth")
    static let sixth = ModelID("test-sixth", repository: "Quran-Lab/test-sixth")
    /// The API routes that answer at once in the tests through the server client; every other request (the lease,
    /// the CDN) is the install's.
    static let apiRoutes = ["/v1/attest/challenge", "/v1/attest", "/v1/attest/assert", "/v1/register", "/v1/config", "/v1/events", "/v1/issues"]
    let fm = FileManager.default

    override func tearDown() {
        StubProtocol.reset { _ in .down }
    }

    func store(_ storage: URL, updates: UpdatePolicy = .automatic) -> ModelStore {
        ModelStore(root: storage.appendingPathComponent("models"), verifier: ManifestVerifier(trustedKeys: [], requireSignature: false),
                   updates: updates, installKeys: CloudFixtures.installKeys)
    }

    /// A revision folder of `id` as a finished 4.0 install leaves it: the manifest, the install record, a device form
    /// (`.qld`, ciphertext bound to this install); `pointer` names it `current`, `previous` or `pending`.
    @discardableResult
    func revision(_ s: ModelStore, _ id: ModelID, _ rev: String, _ pointer: String? = nil) throws -> URL {
        let dir = s.base(id).appendingPathComponent(rev)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try V40.manifest().data.write(to: dir.appendingPathComponent(ModelManifest.fileName))
        try Data("record".utf8).write(to: dir.appendingPathComponent(InstallRecord.fileName))
        try Data(count: 4096).write(to: dir.appendingPathComponent("layers.zfw.qld"))
        if let pointer { try Data(rev.utf8).write(to: s.base(id).appendingPathComponent(pointer)) }
        return dir
    }

    /// The model folder of a revision (what the SDK holds for a model it opened from the store).
    func folder(_ s: ModelStore, _ id: ModelID, _ rev: String) throws -> ModelFolder {
        try folder(id, s.base(id).appendingPathComponent(rev))
    }

    func folder(_ id: ModelID, _ dir: URL) throws -> ModelFolder {
        ModelFolder(id: id, directory: dir, manifest: try ModelManifest.parse(try V40.manifest().data),
                    vocabulary: Vocabulary(symbols: (0..<38).map { "t\($0)" }, blank: 0), verifiedFiles: [], coreMLProblem: nil)
    }

    /// The names in `dir`, without the owed downloads' records (SDK 4.0.5, `.owed`: no model id).
    func names(_ dir: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != ".owed" }.sorted() }

    /// Every regular file under `dir` with its size (to see that a folder is whole).
    func snapshot(_ dir: URL) -> [String] {
        guard let e = fm.enumerator(atPath: dir.path) else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            let path = dir.appendingPathComponent(rel).path
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                out.append("\(rel) \((try? fm.attributesOfItem(atPath: path))?[.size] as? Int ?? -1)")
            }
        }
        return out.sorted()
    }

    /// What lives beside the store and must never be touched: the sharing outbox, the learner's choices, the lease,
    /// the Core's state.
    static let learners = ["outbox/rec-1/seg-0.ogg": Data(count: 2048), "cloud/sharing-state.json": Data(#"{"consent":"granted"}"#.utf8),
                           "cloud/lease.json": Data(#"{"build":"b"}"#.utf8), "core/state.qlc": Data(count: 64)]

    func leaveTheLearnersFiles(_ storage: URL) throws {
        for (path, data) in Self.learners {
            let url = storage.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    /// The learner's files that are not as they were left.
    func learnersFilesChanged(_ storage: URL) -> [String] {
        Self.learners.keys.sorted().filter { (try? Data(contentsOf: storage.appendingPathComponent($0))) != Self.learners[$0] }
    }

    /// The move: the old id holds a current and a previous revision and a download left by an earlier process; the
    /// new id is installed and current. The old id's folder goes, whole; the new id's stays whole; what is not a model
    /// folder of the store stays (a file in the store's root, a folder with a stray file, a folder with a file the
    /// store does not write next to a revision), and so does everything outside the store.
    func testAfterAMoveToAnotherModelIDTheOldIDsFilesGo() throws {
        let storage = CloudFixtures.storage()
        let s = store(storage)
        try revision(s, .v4_0, "rev-0", "previous")
        try revision(s, .v4_0, "rev-1", "current")
        try fm.createDirectory(at: s.base(.v4_0).appendingPathComponent(".download-rev-2"), withIntermediateDirectories: true)
        try Data(count: 512).write(to: s.base(.v4_0).appendingPathComponent(".download-rev-2/layers.zfw.qle.part"))
        try Data("{}".utf8).write(to: s.root.appendingPathComponent("recommended.json"))
        try fm.createDirectory(at: s.root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: s.root.appendingPathComponent("notes/readme.txt"))
        try fm.createDirectory(at: s.root.appendingPathComponent("mixed/rev-9"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: s.root.appendingPathComponent("mixed/rev-9/manifest.json"))
        try Data("rev-9".utf8).write(to: s.root.appendingPathComponent("mixed/current"))
        try Data("x".utf8).write(to: s.root.appendingPathComponent("mixed/extra.bin"))
        try leaveTheLearnersFiles(storage)
        XCTAssertTrue(ModelStore.isStoreFolder(s.base(.v4_0)))
        XCTAssertFalse(ModelStore.isStoreFolder(s.root.appendingPathComponent("notes")), "a folder with a stray file")
        XCTAssertFalse(ModelStore.isStoreFolder(s.root.appendingPathComponent("mixed")), "a file the store does not write")
        XCTAssertFalse(ModelStore.isStoreFolder(s.root.appendingPathComponent("recommended.json")), "a file")

        try revision(s, Self.other, "rev-a")
        let new = try folder(s, Self.other, "rev-a")
        XCTAssertEqual(s.removeOtherModels(inUse: new), [], "the new model is not current yet")
        XCTAssertEqual(names(s.root), ["mixed", "notes", "recommended.json", "test-other", "v4.0"])
        try Data("rev-a".utf8).write(to: s.base(Self.other).appendingPathComponent("current"))
        let whole = snapshot(s.base(Self.other))
        XCTAssertEqual(s.removeOtherModels(inUse: new), ["v4.0"])
        XCTAssertEqual(names(s.root), ["mixed", "notes", "recommended.json", "test-other"])
        XCTAssertFalse(fm.fileExists(atPath: s.base(.v4_0).path), "the old id's folder is gone: current, previous, its old download")
        XCTAssertEqual(snapshot(s.base(Self.other)), whole, "the id in use is whole")
        XCTAssertEqual(try String(contentsOf: s.root.appendingPathComponent("notes/readme.txt"), encoding: .utf8), "mine")
        XCTAssertTrue(fm.fileExists(atPath: s.root.appendingPathComponent("mixed/extra.bin").path))
        XCTAssertEqual(learnersFilesChanged(storage), [], "the outbox, the choices, the lease and the Core's state are whole")
        XCTAssertEqual(s.removeOtherModels(inUse: new), [], "nothing more to remove")
    }

    /// Never before the model in use is current: a revision staged next to the current one, a model placed and never
    /// made current, and a folder outside the store remove nothing.
    func testAModelThatIsNotTheCurrentOneOfItsIDRemovesNothing() throws {
        let storage = CloudFixtures.storage()
        let s = store(storage)
        try revision(s, .v4_0, "rev-1", "current")
        let before = snapshot(s.base(.v4_0))
        try revision(s, Self.other, "rev-a")
        XCTAssertEqual(s.removeOtherModels(inUse: try folder(s, Self.other, "rev-a")), [], "no current pointer")
        try Data("rev-a".utf8).write(to: s.base(Self.other).appendingPathComponent("current"))
        try revision(s, Self.other, "rev-b", "pending")
        XCTAssertEqual(s.removeOtherModels(inUse: try folder(s, Self.other, "rev-b")), [], "staged, not current")
        let elsewhere = try folder(Self.other, fm.temporaryDirectory.appendingPathComponent("elsewhere-\(UUID().uuidString)"))
        XCTAssertEqual(s.removeOtherModels(inUse: elsewhere), [], "not this store's folder")
        XCTAssertEqual(snapshot(s.base(.v4_0)), before, "the old id is whole")
    }

    /// `previous` and a pending revision of the id in use are untouched: only other ids go.
    func testPreviousAndPendingOfTheIDInUseAreUntouched() throws {
        let storage = CloudFixtures.storage()
        let s = store(storage)
        try revision(s, .v4_0, "rev-1", "current")
        try revision(s, Self.other, "rev-a", "previous")
        try revision(s, Self.other, "rev-b", "current")
        try revision(s, Self.other, "rev-c", "pending")
        let whole = snapshot(s.base(Self.other))
        XCTAssertEqual(s.removeOtherModels(inUse: try folder(s, Self.other, "rev-b")), ["v4.0"])
        XCTAssertEqual(s.previousRevision(Self.other), "rev-a")
        XCTAssertEqual(s.pendingRevision(Self.other), "rev-c")
        XCTAssertEqual(snapshot(s.base(Self.other)), whole)
    }

    /// A store pinned to a revision stays as it is; the ids it is told to keep stay too.
    func testAPinnedStoreAndTheIDsKeptStay() throws {
        let storage = CloudFixtures.storage()
        try revision(store(storage), .v4_0, "rev-1", "current")
        try revision(store(storage), Self.other, "rev-a", "current")
        let inUse = try folder(store(storage), Self.other, "rev-a")
        XCTAssertEqual(store(storage, updates: .pinned("rev-a")).removeOtherModels(inUse: inUse), [], "pinned")
        XCTAssertEqual(store(storage).removeOtherModels(inUse: inUse, keeping: ["v4.0"]), [], "kept")
        XCTAssertEqual(store(storage).removeOtherModels(inUse: inUse), ["v4.0"])
    }

    // MARK: through the Client's server client

    /// The background session's stand-in: the range tasks it still carries, by name (`<folder>|<path>|...`).
    final class Carrying: BackgroundRangeTransport, @unchecked Sendable {
        let keys: Locked<[String]>
        init(_ keys: [String]) { self.keys = Locked(keys) }
        func start(_ request: URLRequest, key: String) { keys.withLock { $0.append(key) } }
        func pending(prefix: String) async -> Set<String> { Set(keys.withLock { $0 }.filter { $0.hasPrefix(prefix) }) }
        func cancel(prefix: String) async -> Set<String> {
            keys.withLock { k in
                let gone = Set(k.filter { $0.hasPrefix(prefix) })
                k.removeAll { $0.hasPrefix(prefix) }
                return gone
            }
        }
    }

    /// What is in use keeps its id's files: a Model that is open (the third id), an install under way (the fourth,
    /// held at its first request past the config), the model a Client is opening (the fifth), ranges the background
    /// session carries (the sixth). The id that is none of these goes. When each ends (the Model closed, the install
    /// over, the open done, the ranges ended) its id goes at the next removal. The learner's files outside the store
    /// are whole.
    func testWhatIsInUseOrUnderWayKeepsItsFiles() async throws {
        let storage = CloudFixtures.storage()
        let s = store(storage)
        try revision(s, .v4_0, "rev-1", "current")
        try revision(s, Self.other, "rev-a", "current")
        try revision(s, Self.third, "rev-z", "current")
        try revision(s, Self.fifth, "rev-f", "current")
        try fm.createDirectory(at: s.base(Self.sixth).appendingPathComponent(".download-rev-s"), withIntermediateDirectories: true)
        try Data(count: 100).write(to: s.base(Self.sixth).appendingPathComponent(".download-rev-s/layers.zfw.qle.part"))
        try leaveTheLearnersFiles(storage)
        let carrying = Carrying(["models/test-sixth/.download-rev-s|layers.zfw|0|99|1000"])
        let gate = StubProtocol.Gate()
        let config = CloudFixtures.config(models: ["Quran-Lab/tajweedformer-v4": "rev-1", Self.fourth.repository: "rev-q"])
        StubProtocol.reset(CloudFixtures.server(config: config, extra: { seen in
            guard !Self.apiRoutes.contains(seen.path) else { return nil }
            var r = StubProtocol.Reply(status: 503)
            r.hold = gate
            return r
        }))
        var options = CloudFixtures.options()
        options.cloud?.backgroundDownloads = .whenLeaving
        options.cloud?.backgroundTransport = carrying
        let cloud = CloudFixtures.cloud(storage: storage, options: options)
        defer { cloud.shutdown() }
        _ = await cloud.refreshConfig()
        // the id as a local value (Swift 6.3.3's region checker does not understand `Self.fourth` inside the Task)
        let fourth = Self.fourth
        let installing = Task { [cloud] in await cloud.install(fourth, context: nil, activate: true) }
        var running = false
        for _ in 0..<400 where !running {
            running = await cloud.updater.runningModelNames().contains(Self.fourth.name)
            if !running { try await Task.sleep(nanoseconds: 25_000_000) }
        }
        XCTAssertTrue(running, "the fourth model's install is under way")
        try fm.createDirectory(at: s.base(Self.fourth).appendingPathComponent(".download-rev-q"), withIntermediateDirectories: true)
        // a Model of the third model is open; a Client is opening the fifth
        let model = TajweedModel(try folder(s, Self.third, "rev-z"), client: nil)
        let opening = UUID()
        ModelsInUse.hold(opening, s.base(Self.fifth))
        defer { ModelsInUse.release(opening) }

        let inUse = try folder(s, Self.other, "rev-a")
        let removed = await cloud.removeOtherModels(inUse: inUse)
        XCTAssertEqual(removed, ["v4.0"], "only the id that is neither in use nor under way")
        XCTAssertEqual(names(s.root), ["test-fifth", "test-fourth", "test-other", "test-sixth", "test-third"])

        // each ends: its id goes at the next removal
        gate.open()
        _ = await installing.value
        await model.close()
        ModelsInUse.release(opening)
        let later = await cloud.removeOtherModels(inUse: inUse)
        XCTAssertEqual(Set(later), [Self.third.name, Self.fourth.name, Self.fifth.name])
        XCTAssertEqual(names(s.root), ["test-other", "test-sixth"], "the background session still carries the sixth's ranges")
        _ = await carrying.cancel(prefix: "models/test-sixth/")
        let last = await cloud.removeOtherModels(inUse: inUse)
        XCTAssertEqual(last, [Self.sixth.name])
        XCTAssertEqual(names(s.root), ["test-other"])
        XCTAssertEqual(learnersFilesChanged(storage), [], "the outbox, the choices, the lease and the Core's state are whole")
    }

    /// Through the install: an install of another id that fails leaves the old id whole.
    func testAnInstallThatFailsLeavesTheOldIDWhole() async throws {
        let storage = CloudFixtures.storage()
        let s = store(storage)
        try revision(s, .v4_0, "rev-1", "current")
        let before = snapshot(s.base(.v4_0))
        let config = CloudFixtures.config(models: [Self.other.repository: "rev-a"])
        StubProtocol.reset(CloudFixtures.server(config: config, extra: { seen in
            Self.apiRoutes.contains(seen.path) ? nil : StubProtocol.Reply(status: 503)
        }))
        let cloud = CloudFixtures.cloud(storage: storage)
        defer { cloud.shutdown() }
        let outcome = await cloud.install(Self.other, context: nil, activate: true)
        if case .installed = outcome { XCTFail("the install was to fail") }
        XCTAssertEqual(snapshot(s.base(.v4_0)), before, "the old id is whole")
    }
}
