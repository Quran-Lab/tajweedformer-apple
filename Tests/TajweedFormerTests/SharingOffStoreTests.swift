import Foundation
import XCTest
@testable import TajweedFormer

/// "Delete what I shared" when the device cannot store the learner's answer (SPEC 11.7, "When the device cannot store
/// the off", contract 1.5.1): the server is asked all the same; an accepted deletion turns sharing off in the
/// process, deletes the queue, and stores the off as soon as the device can (the write after the queue is deleted);
/// a deletion the server did not take changes nothing, on the device as in the process, and leaves no mark that a
/// later launch would take for an off.
///
/// The device that cannot store is a switch of the tests (`Contributions.refusesWrites`): it refuses the write of the
/// saved answer, and the write and the removal of the mark that a deletion was asked, and nothing else.
///
/// Since 3.1.4 that mark is a file of its own in the storage folder (`DeletionMark`), no longer a field of the
/// saved answer: where these tests looked for the mark in the saved answer they look for the file.
final class SharingOffStoreTests: XCTestCase {
    override func tearDown() {
        Contributions.refusesWrites.withLock { $0 = nil }
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// A launch: a new server client and outbox on `storage`, with what the disk says about the learner's answer.
    func launch(storage: URL) async -> QuranLabCloud {
        let options = CloudFixtures.options(contributions: true, storage: storage)
        let cloud = CloudFixtures.cloud(storage: storage, options: options)
        _ = await cloud.refreshConfig()
        QuranLab.configure(key: CloudFixtures.key, options: options, cloud: cloud)
        return cloud
    }

    /// A recording of 1 s that has ended; its id.
    func record() throws -> String {
        let capture = try XCTUnwrap(Contributions.capture(revision: "test-rev", backend: .exact, weightsSHA256: nil), "sharing is on")
        for i in 0..<10 { try capture.append(SharingTests.audio(4800, seed: i + 1), rate: 48_000) }
        capture.finish(completed: true)
        return capture.id
    }

    func until(_ seconds: TimeInterval, _ done: @Sendable () async -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if await done() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await done()
    }

    static func stateURL(_ storage: URL) -> URL { storage.appendingPathComponent("cloud/sharing-state.json") }

    /// The saved answer as the device has it.
    static func onDevice(_ storage: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL(storage))) as? [String: Any])
    }

    /// A first process with sharing on and `count` recordings that wait unsent (the upload routes are unreachable; the
    /// deletion routes answer as `challenge` says).
    func waiting(_ count: Int, challenge: @escaping @Sendable () -> StubProtocol.Reply) async throws -> (storage: URL, cloud: QuranLabCloud, ids: [String]) {
        let server = SharingTests.Server()
        let answers = server.handler
        StubProtocol.reset { (s: StubProtocol.Seen) -> StubProtocol.Reply in
            if s.path == "/v1/contributions/challenge" { return challenge() }
            if s.path == "/v1/contributions/delete" { return .json(["ok": true], status: 202) }
            return answers(s)
        }
        server.down.withLock { $0 = true }
        let storage = CloudFixtures.storage()
        let cloud = await launch(storage: storage)
        Contributions.answer(share: true)
        var ids: [String] = []
        for _ in 0..<count { ids.append(try record()) }
        let outbox = cloud.outbox
        let there = await until(15) { await outbox.items.count == count }
        XCTAssertTrue(there, "the recordings wait in the queue")
        XCTAssertEqual(try Self.onDevice(storage)["consent"] as? String, "granted")
        return (storage, cloud, ids)
    }

    /// The device is full: the answer cannot be stored while the queue's files are there. The server accepts the
    /// deletion. The server was asked; sharing is off in this process; the queue is gone; and the write after the
    /// queue was deleted stored the off, so a new process reads off.
    func testAnAcceptedDeleteWhoseOffCannotBeStoredIsStoredOnceTheQueueIsGone() async throws {
        let q = try await waiting(2) { .json(["nonce": "d1.1794000000.AAAA.BBBB", "expires_in": 300]) }
        let before = try Self.onDevice(q.storage)
        let root = q.cloud.outbox.root
        Contributions.refusesWrites.withLock {
            $0 = { !((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty }
        }
        try await Contributions.deleteShared()
        XCTAssertEqual(StubProtocol.seen("/v1/contributions/challenge").count, 1, "the server was asked all the same")
        XCTAssertEqual(StubProtocol.seen("/v1/contributions/delete").count, 1)
        XCTAssertEqual(Contributions.consent, .final, "sharing is off in this process")
        XCTAssertFalse(Contributions.isActive)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], "the queue is gone")
        // the write after the queue was deleted stored the off, with its count and without a mark
        XCTAssertTrue(Contributions.isStored)
        let after = try Self.onDevice(q.storage)
        XCTAssertEqual(after["consent"] as? String, "final")
        XCTAssertEqual(after["deleting"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DeletionMark.url(q.storage).path), "no mark is left")
        XCTAssertEqual(after["consentCount"] as? Int, ((before["consentCount"] as? Int) ?? 0) + 1)
        // a new process on the same storage reads off
        Contributions.refusesWrites.withLock { $0 = nil }
        q.cloud.outbox.shutdown()
        _ = await launch(storage: q.storage)
        XCTAssertEqual(Contributions.consent, .final, "a new process reads off")
        XCTAssertNil(Contributions.askNow(), "and nobody is asked again")
    }

    /// The device cannot store anything, and the server does not take the deletion: the server was asked; nothing
    /// changed in this process; the device has the earlier state, which never got the mark; a new process reads
    /// sharing on, and the recording is still there.
    func testARefusedDeleteWhoseWritesFailChangesNothing() async throws {
        let q = try await waiting(1) { StubProtocol.Reply(status: 503) }
        let before = try Data(contentsOf: Self.stateURL(q.storage))
        Contributions.refusesWrites.withLock { $0 = { true } }
        var threw = false
        do { try await Contributions.deleteShared() } catch { threw = true }
        XCTAssertTrue(threw, "the call says that the server did not take the deletion")
        XCTAssertEqual(StubProtocol.seen("/v1/contributions/challenge").count, 1, "the server was asked all the same")
        XCTAssertEqual(Contributions.consent, .granted, "nothing changed in this process")
        XCTAssertTrue(Contributions.isActive)
        XCTAssertFalse(Contributions.state().deleting)
        XCTAssertEqual(SharingOffTests.unsent(q.cloud), q.ids, "the recording is still in the queue")
        XCTAssertEqual(try Data(contentsOf: Self.stateURL(q.storage)), before, "the device has the earlier state, which never got the mark")
        XCTAssertFalse(FileManager.default.fileExists(atPath: DeletionMark.url(q.storage).path), "and no mark was written")
        // a new process
        Contributions.refusesWrites.withLock { $0 = nil }
        q.cloud.outbox.shutdown()
        let next = await launch(storage: q.storage)
        XCTAssertEqual(Contributions.consent, .granted, "a new process reads sharing on")
        XCTAssertFalse(Contributions.state().deleting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: next.outbox.root.appendingPathComponent(q.ids[0]).path), "and the recording is still there")
    }

    /// The one order that leaves the mark on the device after a refusal: the mark was stored, then the device
    /// stopped storing, and taking the mark back failed. In the process nothing changed. The mark is taken back on
    /// the device as soon as it can store again: at the next read of the state, at most a second later. A new
    /// process then reads sharing on.
    func testAMarkWhoseTakingBackCouldNotBeStoredIsTakenBackAsSoonAsTheDeviceCan() async throws {
        let full = Locked(false)
        let q = try await waiting(1) {
            // the device stops storing while the server is being asked
            full.withLock { $0 = true }
            return StubProtocol.Reply(status: 503)
        }
        Contributions.refusesWrites.withLock { $0 = { full.withLock { $0 } } }
        var threw = false
        do { try await Contributions.deleteShared() } catch { threw = true }
        XCTAssertTrue(threw)
        XCTAssertEqual(Contributions.consent, .granted, "nothing changed in this process")
        XCTAssertFalse(Contributions.state().deleting)
        XCTAssertFalse(Contributions.isStored)
        let mark = DeletionMark.url(q.storage).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: mark), "the window: the device still has the mark")
        XCTAssertNotEqual(try Self.onDevice(q.storage)["deleting"] as? Bool, true, "the saved answer itself does not carry it")
        // the device can store again
        full.withLock { $0 = false }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        _ = Contributions.state()
        XCTAssertTrue(Contributions.isStored, "stored at the next read of the state")
        let after = try Self.onDevice(q.storage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mark), "the mark is taken back on the device")
        XCTAssertNotEqual(after["deleting"] as? Bool, true)
        XCTAssertEqual(after["consent"] as? String, "granted")
        // a new process reads sharing on
        q.cloud.outbox.shutdown()
        _ = await launch(storage: q.storage)
        XCTAssertEqual(Contributions.consent, .granted)
    }

    /// The state in force in the process is what the queue is judged by, also while the device cannot store it:
    /// sharing turned off and on again on a device that refuses the write, and a recording made after that is
    /// uploaded (its stamp is the count in force, which the file does not have yet).
    func testSharingOnAgainWorksWhileTheDeviceCannotStoreTheAnswer() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        let cloud = await launch(storage: storage)
        Contributions.answer(share: true)
        Contributions.refusesWrites.withLock { $0 = { true } }
        await Contributions.setSharing(false)
        await Contributions.setSharing(true)
        XCTAssertEqual(Contributions.consent, .granted)
        XCTAssertFalse(Contributions.isStored)
        let id = try record()
        let outbox = cloud.outbox
        let up = await until(5) { await outbox.item(id)?.status == .uploaded }
        XCTAssertTrue(up, "the recording made after sharing came on again is uploaded")
    }
}
