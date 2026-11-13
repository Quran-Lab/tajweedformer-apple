import Foundation
import XCTest
@testable import TajweedFormer

/// The learner's stored answer about sharing that is there and cannot be read is not "never answered" (3.1.4).
///
/// While it cannot be read, sharing is neither on nor off in that process: nothing is uploaded, nothing is
/// deleted, nobody is asked, no state is written and no session is counted; it is read again at the next need.
/// Only a file that is not there is "never answered". A file that reads and does not parse is the same for
/// uploads and asks, and it is not written over.
///
/// "Cannot be read" is the test's switch (`StorageLock`): the SDK's read of the file fails as the read of a file
/// of a protected class fails while the device is locked. No test here locks a device.
final class UnreadableStateTests: UnreadableStorageTestCase {
    /// A "Not now" as an earlier launch left it: asked once, at session 3 of 5.
    static let storedDeclined = """
        {"v":1,"consent":"declined","asks":1,"lastAskSession":3,"sessions":5,"thanked":false,"decidedAt":1794300000,\
        "guardian":false,"sharedOnce":false,"consentCount":0,"deleting":false}
        """

    /// A final no: the sheet was shown three times.
    static let storedFinal = """
        {"v":1,"consent":"final","asks":3,"lastAskSession":20,"sessions":22,"thanked":false,"decidedAt":1794300000,\
        "guardian":false,"sharedOnce":false,"consentCount":0,"deleting":false}
        """

    /// A stored yes and a queue with an unsent recording; the next process cannot read the answer at its first
    /// read; one session finishes; then the answer reads again. The stored bytes are what they were, the queue is
    /// whole, nothing was asked, nothing was uploaded while it could not be read, and the upload goes on once it
    /// reads.
    func testAStoredYesThatCannotBeReadStaysAYesAndItsQueueStaysWhole() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        let made = try await firstProcess(server, storage)
        let state = storage.appendingPathComponent("cloud/sharing-state.json")
        let answer = try Data(contentsOf: state)
        let folder = made.root.appendingPathComponent(made.id)
        let queued = Self.listing(folder)
        XCTAssertFalse(queued.isEmpty, "the first process left a recording in the queue")

        // the next process: the stored answer is there and cannot be read
        StorageLock.refuse(["cloud/sharing-state.json"])
        server.down.withLock { $0 = false }
        let mark = StubProtocol.seen.count
        let cloud = await launch(storage: storage)
        XCTAssertTrue(Contributions.isEnabled, "sharing is offered to this app")
        // one finished session
        let moment = Contributions.sessionCompleted(feedback: true)
        await cloud.outbox.drain(ignoringBackoff: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(moment, "nobody is asked")
        XCTAssertFalse(Contributions.isActive, "nothing is shared meanwhile")
        XCTAssertEqual(try Data(contentsOf: state), answer, "the stored answer is what it was, byte for byte")
        XCTAssertEqual(Self.listing(folder), queued, "the queue is whole")
        XCTAssertEqual(Self.uploads(after: mark), [], "nothing is uploaded while the answer cannot be read")

        // it reads again, in the same process
        StorageLock.open()
        XCTAssertEqual(Contributions.consent, .granted, "the stored yes is a yes")
        XCTAssertEqual(try Data(contentsOf: state), answer, "and reading it wrote nothing")
        await cloud.outbox.drain(ignoringBackoff: true)
        let outbox = cloud.outbox
        let id = made.id
        let up = await until(10) { await outbox.item(id)?.status == .uploaded }
        XCTAssertTrue(up, "the upload goes on once the answer reads")
        XCTAssertEqual(server.segments(id).count, 1)
    }

    /// A stored "Not now" and a stored final no that cannot be read: the learner is not asked again, at a finished
    /// session or at the app's own moment, and the stored answer is not written over. Once it reads, it is the
    /// answer that was stored, and its count of sessions goes on from where it was: the session that finished
    /// while it could not be read was not counted.
    func testAStoredNoThatCannotBeReadIsNotAskedAgainAndIsNotWrittenOver() async throws {
        let cases: [(name: String, stored: String, consent: SharingConsent, asks: Int, sessions: Int)] = [
            ("declined", Self.storedDeclined, .declined, 1, 5),
            ("final", Self.storedFinal, .final, 3, 22),
        ]
        for c in cases {
            let server = SharingTests.Server()
            StubProtocol.reset(server.handler)
            let storage = CloudFixtures.storage()
            let state = storage.appendingPathComponent("cloud/sharing-state.json")
            try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
            let answer = Data(c.stored.utf8)
            try answer.write(to: state)

            StorageLock.refuse(["cloud/sharing-state.json"])
            _ = await launch(storage: storage)
            XCTAssertTrue(Contributions.isEnabled, "\(c.name): sharing is offered to this app")
            XCTAssertNil(Contributions.sessionCompleted(feedback: true), "\(c.name): the learner is not asked again after a session")
            XCTAssertNil(Contributions.askNow(), "\(c.name): and not at the app's own moment")
            XCTAssertEqual(try Data(contentsOf: state), answer, "\(c.name): the stored answer is what it was, byte for byte")

            StorageLock.open()
            XCTAssertEqual(Contributions.consent, c.consent, "\(c.name): the stored answer")
            XCTAssertEqual(Contributions.state().asks, c.asks, "\(c.name): the sheets shown")
            XCTAssertNil(Contributions.sessionCompleted(feedback: true), "\(c.name): one more session, now that it reads: not asked")
            XCTAssertEqual(Contributions.state().sessions, c.sessions + 1,
                           "\(c.name): the stored count of sessions went on by this one; the session that could not be read was not counted")
            StorageLock.reset()
            QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
        }
    }

    /// A stored answer that reads and does not parse (here: cut off in the middle), with a queue: it is not
    /// written over by a fresh state, nobody is asked, and the queue is neither deleted nor uploaded.
    func testAStoredAnswerThatDoesNotParseIsNotWrittenOver() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        let made = try await firstProcess(server, storage)
        let state = storage.appendingPathComponent("cloud/sharing-state.json")
        let folder = made.root.appendingPathComponent(made.id)
        let queued = Self.listing(folder)
        let damaged = Data("{\"v\":1,\"consent\":\"gran".utf8)
        try damaged.write(to: state)

        server.down.withLock { $0 = false }
        let mark = StubProtocol.seen.count
        let cloud = await launch(storage: storage)
        XCTAssertTrue(Contributions.isEnabled, "sharing is offered to this app")
        let moment = Contributions.sessionCompleted(feedback: true)
        let asked = Contributions.askNow()
        await cloud.outbox.drain(ignoringBackoff: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(moment, "nobody is asked after a session")
        XCTAssertNil(asked, "and not at the app's own moment")
        XCTAssertFalse(Contributions.isActive)
        XCTAssertEqual(try Data(contentsOf: state), damaged, "the file is not written over")
        XCTAssertEqual(Self.listing(folder), queued, "the queue is whole")
        XCTAssertEqual(Self.uploads(after: mark), [], "nothing is uploaded")

        // a second start, and still no act of the learner: the same
        cloud.outbox.shutdown()
        let again = await launch(storage: storage)
        XCTAssertNil(Contributions.sessionCompleted(feedback: true), "the second start: nobody is asked")
        await again.outbox.drain(ignoringBackoff: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(try Data(contentsOf: state), damaged, "the second start: the file is not written over")
        XCTAssertEqual(Self.listing(folder), queued, "the second start: the queue is whole")
        XCTAssertEqual(Self.uploads(after: mark), [], "the second start: nothing is uploaded")
    }

    /// The files kept aside from a damaged answer in a storage's `cloud` folder, with their bytes.
    static func keptAside(_ storage: URL) -> [Data] {
        let dir = storage.appendingPathComponent("cloud")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("sharing-state.damaged-") }.sorted().compactMap { try? Data(contentsOf: dir.appendingPathComponent($0)) }
    }

    /// The saved answer as the device has it now, parsed.
    static func saved(_ storage: URL) throws -> [String: Any] {
        let state = storage.appendingPathComponent("cloud/sharing-state.json")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])
    }

    /// A stored answer that does not parse, and the learner's own switch, on: a new answer is begun. The damaged
    /// file is kept aside under another name with its bytes, the unsent queue is gone and nothing of it was
    /// uploaded, the new state has the learner's yes and its asks used up, and the SDK never asks by itself: not
    /// after a session, not at the app's own moment, also after the learner has turned sharing off again. A
    /// recording made after the yes is uploaded.
    func testADamagedAnswerIsReplacedByTheLearnersOwnSwitchOn() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        let made = try await firstProcess(server, storage)
        let state = storage.appendingPathComponent("cloud/sharing-state.json")
        let folder = made.root.appendingPathComponent(made.id)
        let damaged = Data("{\"v\":1,\"consent\":\"gran".utf8)
        try damaged.write(to: state)

        server.down.withLock { $0 = false }
        let mark = StubProtocol.seen.count
        let cloud = await launch(storage: storage)
        XCTAssertEqual(Self.keptAside(storage), [], "nothing is kept aside before the learner acts")
        await Contributions.setSharing(true)
        XCTAssertEqual(Contributions.consent, .granted, "the learner's yes")
        XCTAssertEqual(Self.keptAside(storage), [damaged], "the damaged file is kept aside under another name, with its bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the unsent queue is gone")
        let now = try Self.saved(storage)
        XCTAssertEqual(now["consent"] as? String, "granted", "the new state is on the device")
        XCTAssertEqual(now["asks"] as? Int, SharingState.maxAsks, "with its asks used up")
        XCTAssertNil(Contributions.sessionCompleted(feedback: true), "the SDK does not ask after a session")
        // a recording made under the new yes is uploaded, and it is the only one
        let next = try XCTUnwrap(try record(), "sharing is on")
        let outbox = cloud.outbox
        let up = await until(10) { await outbox.item(next)?.status == .uploaded }
        XCTAssertTrue(up, "a recording made after the yes is uploaded")
        XCTAssertFalse(Self.uploads(after: mark).isEmpty)
        XCTAssertEqual(server.segments(made.id).count, 0, "nothing of the earlier queue was uploaded")
        // off again: still nobody is asked, ever
        await Contributions.setSharing(false)
        XCTAssertEqual(Contributions.consent, .final)
        for _ in 0..<9 { XCTAssertNil(Contributions.sessionCompleted(feedback: true), "the SDK never asks this install by itself again") }
        XCTAssertNil(Contributions.askNow(), "nor at the app's own moment")
    }

    /// A stored answer that does not parse, and the learner's own switch, off: it works and is stored. The damaged
    /// file is kept aside, the unsent queue is gone, nothing was uploaded, and a new process reads off and never
    /// asks.
    func testADamagedAnswerIsReplacedByTheLearnersOwnSwitchOff() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        let made = try await firstProcess(server, storage)
        let state = storage.appendingPathComponent("cloud/sharing-state.json")
        let folder = made.root.appendingPathComponent(made.id)
        let damaged = Data("not an answer".utf8)
        try damaged.write(to: state)

        server.down.withLock { $0 = false }
        let mark = StubProtocol.seen.count
        let cloud = await launch(storage: storage)
        await Contributions.setSharing(false)
        XCTAssertEqual(Contributions.consent, .final, "the learner's off")
        XCTAssertTrue(Contributions.isStored)
        XCTAssertEqual(Self.keptAside(storage), [damaged], "the damaged file is kept aside under another name, with its bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the unsent queue is gone")
        let now = try Self.saved(storage)
        XCTAssertEqual(now["consent"] as? String, "final", "the off is on the device")
        XCTAssertEqual(now["asks"] as? Int, SharingState.maxAsks)
        XCTAssertEqual(Self.uploads(after: mark), [], "nothing was uploaded")

        cloud.outbox.shutdown()
        _ = await launch(storage: storage)
        XCTAssertEqual(Contributions.consent, .final, "a new process reads off")
        XCTAssertNil(Contributions.sessionCompleted(feedback: true), "and nobody is asked")
        XCTAssertNil(Contributions.askNow())
        XCTAssertEqual(Self.keptAside(storage), [damaged], "the file kept aside is still there")
    }

    /// The control: only a file that is not there is "never answered". A first launch asks after a session with
    /// feedback.
    func testOnlyAFileThatIsNotThereIsNeverAnswered() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        _ = await launch(storage: storage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent("cloud/sharing-state.json").path))
        XCTAssertEqual(Contributions.consent, .unknown)
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .ask(reask: false, guardian: false))
    }
}
