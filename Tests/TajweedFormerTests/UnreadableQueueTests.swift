import Foundation
import XCTest
@testable import TajweedFormer

/// A file of a queued recording that is there and cannot be read is not "not there" (3.1.4): the recording's
/// stamp, its item file, and what a recording left by a killed app is recovered from (the capture file, a
/// segment's marker, the open segment's audio). While one of them cannot be read the recording is left as it is:
/// nothing of it is deleted, nothing is written over, nothing is uploaded; it is looked at again at the next pass.
/// The learner's answer reads in all of these tests (a yes).
///
/// "Cannot be read" is the test's switch (`StorageLock`); no test here locks a device.
final class UnreadableQueueTests: UnreadableStorageTestCase {
    /// The recording's stamp (the count of the learner's changes of mind it was begun under): one that cannot be
    /// read is not the stamp 0 of a recording of an earlier SDK. The recording is neither deleted as one of an
    /// earlier consent nor uploaded without its stamp; once the stamp reads, it is uploaded.
    func testARecordingWhoseStampCannotBeReadIsNeitherDeletedNorUploaded() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        let made = try await firstProcess(server, storage)
        let folder = made.root.appendingPathComponent(made.id)
        let queued = Self.listing(folder)
        XCTAssertTrue(queued.contains { $0.hasPrefix("stamp.json ") }, "\(queued)")

        StorageLock.refuse(["\(made.id)/stamp.json"])
        server.down.withLock { $0 = false }
        let mark = StubProtocol.seen.count
        let cloud = await launch(storage: storage)
        XCTAssertEqual(Contributions.consent, .granted)
        await cloud.outbox.drain(ignoringBackoff: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(Self.listing(folder), queued, "the recording is there as it was")
        XCTAssertEqual(Self.uploads(after: mark), [], "and nothing of it is uploaded while its stamp cannot be read")

        StorageLock.open()
        await cloud.outbox.drain(ignoringBackoff: true)
        let outbox = cloud.outbox
        let id = made.id
        let up = await until(10) { await outbox.item(id)?.status == .uploaded }
        XCTAssertTrue(up, "once the stamp reads, the recording is uploaded")
    }

    /// The item file of a recording that was uploaded: one that cannot be read is not written over by the item of
    /// a new recording, and the recording is not started again at the server.
    func testAnItemFileThatCannotBeReadIsNotWrittenOverAndItsRecordingIsNotStartedAgain() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        let made = try await firstProcess(server, storage, uploads: true)
        let folder = made.root.appendingPathComponent(made.id)
        let item = folder.appendingPathComponent(ContributionOutbox.itemName)
        let before = try Data(contentsOf: item)
        let kept = Self.listing(folder)

        StorageLock.refuse(["\(made.id)/\(ContributionOutbox.itemName)"])
        let mark = StubProtocol.seen.count
        let cloud = await launch(storage: storage)
        XCTAssertEqual(Contributions.consent, .granted)
        await cloud.outbox.drain(ignoringBackoff: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(try Data(contentsOf: item), before, "the item file is what it was, byte for byte")
        XCTAssertEqual(Self.listing(folder), kept, "and so is the rest of the recording's folder")
        XCTAssertEqual(Self.uploads(after: mark), [], "nothing is sent for it")

        StorageLock.open()
        await cloud.outbox.drain(ignoringBackoff: true)
        let status = await cloud.outbox.item(made.id)?.status
        XCTAssertEqual(status, .uploaded, "once it reads, it is the uploaded recording it was")
        XCTAssertEqual(Self.uploads(after: mark), [], "and nothing is sent for a recording that was uploaded")
    }

    /// The other side of the line, so that the two cannot drift together: an item file that was READ and is not an
    /// item (damaged) is taken as no item, as before 3.1.4. Its recording, which has ended and is not sent, is
    /// taken up as one still to send and is uploaded. (An item file the system does not give is held: the test
    /// above.)
    func testADamagedItemFileIsTakenAsNoItemAndItsRecordingIsSent() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        let made = try await firstProcess(server, storage)
        let folder = made.root.appendingPathComponent(made.id)
        try Data("not an item".utf8).write(to: folder.appendingPathComponent(ContributionOutbox.itemName))

        server.down.withLock { $0 = false }
        let cloud = await launch(storage: storage)
        XCTAssertEqual(Contributions.consent, .granted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "the launch keeps the recording")
        await cloud.outbox.drain(ignoringBackoff: true)
        let outbox = cloud.outbox
        let id = made.id
        let up = await until(10) { await outbox.item(id)?.status == .uploaded }
        XCTAssertTrue(up, "the recording is uploaded, as before")
        XCTAssertEqual(server.segments(id).count, 1)
    }

    /// What a killed app leaves of a recording of one segment that was still open: no end, no item, no marker.
    func killedInItsFirstSegment(_ folder: URL) throws {
        let fm = FileManager.default
        for name in [ShareFiles.end, ContributionOutbox.itemName, ShareFiles.name(1) + ".json"] {
            try fm.removeItem(at: folder.appendingPathComponent(name))
        }
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent(ShareFiles.capture).path))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent(ShareFiles.name(1) + ".opus").path))
    }

    /// A recording a killed app left, whose capture file or whose open segment's audio cannot be read: it is not
    /// deleted as one with nothing to share, and nothing of it is uploaded; once the file reads, the recording is
    /// recovered and uploaded.
    func testARecordingOfAKilledAppWhoseFilesCannotBeReadIsNotDeleted() async throws {
        for what in [ShareFiles.capture, ShareFiles.name(1) + ".opus"] {
            let server = SharingTests.Server()
            StubProtocol.reset(server.handler)
            let storage = CloudFixtures.storage()
            let made = try await firstProcess(server, storage)
            let folder = made.root.appendingPathComponent(made.id)
            try killedInItsFirstSegment(folder)
            let left = Self.listing(folder)

            StorageLock.refuse(["\(made.id)/\(what)"])
            server.down.withLock { $0 = false }
            let mark = StubProtocol.seen.count
            let cloud = await launch(storage: storage)
            XCTAssertEqual(Contributions.consent, .granted, what)
            await cloud.outbox.drain(ignoringBackoff: true)
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertEqual(Self.listing(folder), left, "\(what) cannot be read: the recording is there as the killed app left it")
            XCTAssertEqual(Self.uploads(after: mark), [], "\(what) cannot be read: nothing of it is uploaded")

            StorageLock.open()
            await cloud.outbox.drain(ignoringBackoff: true)
            let outbox = cloud.outbox
            let id = made.id
            let up = await until(10) { await outbox.item(id)?.status == .uploaded }
            XCTAssertTrue(up, "\(what) reads again: the recording is recovered and uploaded")
            XCTAssertEqual(server.segments(id).count, 1, what)
            StorageLock.reset()
            QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
        }
    }

    /// A recording of two segments that has ended, whose first segment's marker cannot be read: the recording is
    /// not taken for one of a single segment. The first segment's audio stays on the device, the recording is not
    /// marked uploaded, and nothing of it is sent; once the marker reads, both segments are uploaded.
    func testASegmentWhoseMarkerCannotBeReadIsNotDeletedUnsent() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        let made = try await firstProcess(server, storage, seconds: 12)
        let folder = made.root.appendingPathComponent(made.id)
        let first = folder.appendingPathComponent(ShareFiles.name(1) + ".opus")
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: first.path), "\(Self.listing(folder))")
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent(ShareFiles.name(2) + ".opus").path), "two segments: \(Self.listing(folder))")

        StorageLock.refuse(["\(made.id)/\(ShareFiles.name(1)).json"])
        server.down.withLock { $0 = false }
        let mark = StubProtocol.seen.count
        let cloud = await launch(storage: storage)
        XCTAssertEqual(Contributions.consent, .granted)
        await cloud.outbox.drain(ignoringBackoff: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(fm.fileExists(atPath: first.path), "the first segment's audio is still on the device")
        let status = await cloud.outbox.item(made.id)?.status
        XCTAssertNotEqual(status, .uploaded, "the recording is not marked uploaded")
        XCTAssertEqual(Self.uploads(after: mark), [], "nothing of it is sent while a marker cannot be read")

        StorageLock.open()
        await cloud.outbox.drain(ignoringBackoff: true)
        let outbox = cloud.outbox
        let id = made.id
        let up = await until(15) { await outbox.item(id)?.status == .uploaded }
        XCTAssertTrue(up, "once the marker reads, the recording is uploaded")
        XCTAssertEqual(server.segments(id).count, 2, "both segments")
    }
}
