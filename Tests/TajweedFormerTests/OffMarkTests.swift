import Foundation
import XCTest
@testable import TajweedFormer

/// The learner's switch while the stored answer cannot be read because the system does not give it (3.1.4).
///
/// An off that is asked then writes a small mark of its own in the storage folder. While the mark is there
/// nothing is recorded for sharing and nothing is uploaded, in that process and in the next; the next read of the
/// answer that succeeds applies it (sharing off, the count of the learner's changes of mind up) and removes it.
/// When the mark cannot be written either, that call throws `storage_failed`, and the process records and uploads
/// nothing more. An on that is asked while the answer cannot be read throws `storage_failed` and changes nothing.
///
/// Through the public switch (`client.sharing.setOn`). "Cannot be read" is the test's switch (`StorageLock`), the
/// device that cannot store is the suite's other switch (`Contributions.refusesWrites`), the server is the
/// suite's stub. No test here locks a device.
final class OffMarkTests: UnreadableStorageTestCase {
    override func tearDown() {
        Contributions.refusesWrites.withLock { $0 = nil }
        super.tearDown()
    }

    /// Where the mark of an off is kept.
    static func mark(_ storage: URL) -> URL { storage.appendingPathComponent("cloud/off-pending.json") }

    /// The public switch; the error's code when it threw.
    func setOn(_ on: Bool) async -> String? {
        do {
            try await TajweedSharing().setOn(on)
            return nil
        } catch {
            return error.code
        }
    }

    /// What a process left: the learner's yes, one unsent recording, the saved answer's bytes and its count.
    struct Left {
        let storage: URL
        let state: URL
        let answer: Data
        let count: Int
        let folder: URL
    }

    func yesWithAQueue(_ server: SharingTests.Server) async throws -> Left {
        let storage = CloudFixtures.storage()
        let made = try await firstProcess(server, storage)
        let state = storage.appendingPathComponent("cloud/sharing-state.json")
        let count = try XCTUnwrap(try UnreadableStateTests.saved(storage)["consentCount"] as? Int)
        return Left(storage: storage, state: state, answer: try Data(contentsOf: state), count: count,
                    folder: made.root.appendingPathComponent(made.id))
    }

    /// A stored yes that the process cannot read; the learner turns sharing off. The call does not throw, the mark
    /// is written, the stored answer is not touched, and nothing is shared. The answer reads again in the same
    /// process: sharing is off, a take begins no recording, the stored answer says off with its count one up, the
    /// mark is gone, and the unsent recording is deleted and never uploaded.
    func testAnOffAskedWhileTheAnswerCannotBeReadIsAppliedWhenItReads() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let left = try await yesWithAQueue(server)
        let mark = Self.mark(left.storage)

        StorageLock.refuse(["cloud/sharing-state.json"])
        server.down.withLock { $0 = false }
        let sent = StubProtocol.seen.count
        let cloud = await launch(storage: left.storage)
        let code = await setOn(false)
        XCTAssertNil(code, "the off does not throw")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mark.path), "the off is written down as a mark of its own")
        XCTAssertEqual(try Data(contentsOf: left.state), left.answer, "the stored answer, which cannot be read, is not touched")
        XCTAssertFalse(Contributions.isActive, "nothing is shared")

        // the answer reads again, in the same process
        StorageLock.open()
        XCTAssertEqual(Contributions.consent, .final, "the off is applied: the stored yes is not in force again")
        let take = try record()
        XCTAssertNil(take, "a take begins no recording")
        let now = try UnreadableStateTests.saved(left.storage)
        XCTAssertEqual(now["consent"] as? String, "final", "the off is on the device")
        XCTAssertEqual(now["consentCount"] as? Int, left.count + 1, "with the count one up")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mark.path), "and the mark is gone")
        await cloud.outbox.drain(ignoringBackoff: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.folder.path), "the unsent recording is deleted")
        XCTAssertEqual(Self.uploads(after: sent), [], "and nothing was uploaded")
    }

    /// The same off, and the process ends before the answer reads. The next start reads it: sharing is off, the
    /// unsent recording is gone at that start, the mark is gone, and a take begins no recording.
    func testAnOffAskedWhileTheAnswerCannotBeReadIsAppliedByTheNextStart() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let left = try await yesWithAQueue(server)
        let mark = Self.mark(left.storage)

        StorageLock.refuse(["cloud/sharing-state.json"])
        server.down.withLock { $0 = false }
        let sent = StubProtocol.seen.count
        let cloud = await launch(storage: left.storage)
        let code = await setOn(false)
        XCTAssertNil(code, "the off does not throw")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mark.path), "the mark is on the device")
        // the process ends; the next one can read
        cloud.outbox.shutdown()
        StorageLock.open()
        let next = await launch(storage: left.storage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.folder.path), "the unsent recording is gone at the next start")
        XCTAssertEqual(Contributions.consent, .final, "the next start reads off")
        XCTAssertNil(try record(), "a take begins no recording")
        let now = try UnreadableStateTests.saved(left.storage)
        XCTAssertEqual(now["consent"] as? String, "final")
        XCTAssertEqual(now["consentCount"] as? Int, left.count + 1, "the count went up once")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mark.path), "the mark is gone")
        await next.outbox.drain(ignoringBackoff: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(Self.uploads(after: sent), [], "nothing was uploaded")
    }

    /// The mark cannot be written either (the device stores nothing). That call throws `storage_failed`, and the
    /// process records and uploads nothing more: also once the answer reads again, the stored yes is not in force
    /// in this process, and a take begins no recording.
    func testAnOffThatCannotBeWrittenDownThrowsAndTheProcessSharesNothingMore() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let left = try await yesWithAQueue(server)
        let mark = Self.mark(left.storage)

        StorageLock.refuse(["cloud/sharing-state.json"])
        Contributions.refusesWrites.withLock { $0 = { true } }
        server.down.withLock { $0 = false }
        let sent = StubProtocol.seen.count
        let cloud = await launch(storage: left.storage)
        let code = await setOn(false)
        XCTAssertEqual(code, "storage_failed", "the call says that the off could not be written down")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mark.path))
        XCTAssertEqual(try Data(contentsOf: left.state), left.answer, "the stored answer is not touched")
        XCTAssertFalse(Contributions.isActive, "nothing is shared")

        // the answer reads again, the device still stores nothing
        StorageLock.open()
        XCTAssertFalse(Contributions.isActive, "the stored yes is not in force in this process")
        XCTAssertNotEqual(Contributions.consent, .granted)
        XCTAssertNil(try record(), "a take begins no recording for the rest of the process")
        await cloud.outbox.drain(ignoringBackoff: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(Self.uploads(after: sent), [], "and nothing is uploaded")
    }

    /// The mark must not outlive its off. The off is asked while the answer cannot be read; the answer reads again
    /// while the device stores nothing, so the off is applied in the process and not yet on the device; the device
    /// stores again; the learner turns sharing ON. Their yes is the later answer: the mark is gone, and a new
    /// start reads sharing on.
    func testAMarkThatWasAppliedDoesNotTurnOffALaterYes() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let left = try await yesWithAQueue(server)
        let mark = Self.mark(left.storage)

        StorageLock.refuse(["cloud/sharing-state.json"])
        let cloud = await launch(storage: left.storage)
        let off = await setOn(false)
        XCTAssertNil(off, "the off does not throw")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mark.path), "the mark is on the device")
        // the answer reads again, and the device stores nothing
        Contributions.refusesWrites.withLock { $0 = { true } }
        StorageLock.open()
        XCTAssertEqual(Contributions.consent, .final, "the off is applied in the process")
        XCTAssertFalse(Contributions.isStored, "and is not on the device yet")
        // the device stores again, and the learner turns sharing on
        Contributions.refusesWrites.withLock { $0 = nil }
        let on = await setOn(true)
        XCTAssertNil(on, "the on does not throw")
        XCTAssertEqual(Contributions.consent, .granted)
        XCTAssertEqual(try UnreadableStateTests.saved(left.storage)["consent"] as? String, "granted", "the learner's yes is on the device")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mark.path), "the mark is gone: it does not outlive its off")
        // a new start
        cloud.outbox.shutdown()
        _ = await launch(storage: left.storage)
        XCTAssertEqual(Contributions.consent, .granted, "a new start reads the learner's later yes")
        XCTAssertEqual(try UnreadableStateTests.saved(left.storage)["consent"] as? String, "granted")
    }

    /// An on that is asked while the stored answer cannot be read throws `storage_failed` and changes nothing: no
    /// mark, the stored bytes as they were; once the answer reads, it is the answer that was stored.
    func testAnOnAskedWhileTheAnswerCannotBeReadThrowsAndChangesNothing() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        let state = storage.appendingPathComponent("cloud/sharing-state.json")
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        let answer = Data(UnreadableStateTests.storedFinal.utf8)
        try answer.write(to: state)

        StorageLock.refuse(["cloud/sharing-state.json"])
        _ = await launch(storage: storage)
        let code = await setOn(true)
        XCTAssertEqual(code, "storage_failed", "the call says that the yes could not be recorded")
        XCTAssertEqual(try Data(contentsOf: state), answer, "the stored answer is what it was")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.mark(storage).path), "and no mark is written")
        StorageLock.open()
        XCTAssertEqual(Contributions.consent, .final, "the answer that was stored")
        XCTAssertEqual(try Data(contentsOf: state), answer)
    }
}
