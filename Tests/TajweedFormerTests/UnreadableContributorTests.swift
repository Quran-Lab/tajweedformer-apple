import CryptoKit
import Foundation
import Security
import XCTest
@testable import TajweedFormer

/// The contributor's id, device key and recovery code that are there and cannot be read are not "not there"
/// (3.1.4): no new id, key or code is made, nothing is replaced or deleted, no recording begins and nothing is
/// uploaded until they read; a deletion is not asked with a key that is not the learner's. After they read again
/// they are the same bytes as before, and a deletion is signed with the key that was there.
///
/// Two places hold the three: the Keychain, and files in the SDK's storage for a process without a Keychain (the
/// CI's test process is one). Both are tested with stand-ins: the files through the test's switch for a read the
/// system refuses (`StorageLock`), the Keychain through a stand-in kept in memory (`MemoryKeychain`) that can be
/// locked. No test here touches a real Keychain or locks a device.
final class UnreadableContributorTests: UnreadableStorageTestCase {
    /// The deletion routes beside the upload routes: a nonce, and 202.
    func serve(_ server: SharingTests.Server) {
        let answers = server.handler
        StubProtocol.reset { (s: StubProtocol.Seen) -> StubProtocol.Reply in
            if s.path == "/v1/contributions/challenge" { return .json(["nonce": "d1.1794000000.AAAA.BBBB", "expires_in": 300]) }
            if s.path == "/v1/contributions/delete" { return .json(["ok": true], status: 202) }
            return answers(s)
        }
    }

    /// "Delete what I shared", and whether the call threw.
    func deleteShared() async -> Bool {
        do {
            try await Contributions.deleteShared()
            return false
        } catch {
            return true
        }
    }

    /// The id is a file (a process without a Keychain) that the next process cannot read: a take there begins no
    /// recording under another id, the file is not written over, and nothing is uploaded meanwhile. Once it
    /// reads: the same id, the queued recording goes up under it, and a deletion names it and is signed with the
    /// device key that was there.
    func testAContributorIdThatCannotBeReadIsNotMadeAnew() async throws {
        MemoryKeychain(absent: true).install()
        let server = SharingTests.Server()
        serve(server)
        let storage = CloudFixtures.storage()
        let made = try await firstProcess(server, storage)
        let file = storage.appendingPathComponent("cloud/contributor")
        let old = try Data(contentsOf: file)
        let oldID = String(decoding: old, as: UTF8.self)
        XCTAssertEqual(oldID.count, 32)
        let publicKey = try XCTUnwrap(ContributorKey.key(storage: storage)).publicKey

        StorageLock.refuse(["cloud/contributor"])
        server.down.withLock { $0 = false }
        let mark = StubProtocol.seen.count
        let cloud = await launch(storage: storage)
        XCTAssertEqual(Contributions.consent, .granted)
        // a take while the id cannot be read
        let second = try record()
        await cloud.outbox.drain(ignoringBackoff: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(second, "no recording begins while the id cannot be read")
        XCTAssertEqual(try Data(contentsOf: file), old, "the id on the device is what it was, byte for byte")
        XCTAssertEqual(Self.uploads(after: mark), [], "nothing is uploaded while the id cannot be read")
        XCTAssertEqual(Contributions.consent, .granted, "the learner's yes is still a yes")

        StorageLock.open()
        XCTAssertEqual(QuranLab.contributorID, oldID, "the same id as before")
        await cloud.outbox.drain(ignoringBackoff: true)
        let outbox = cloud.outbox
        let id = made.id
        let up = await until(10) { await outbox.item(id)?.status == .uploaded }
        XCTAssertTrue(up, "the queued recording is uploaded once the id reads")
        XCTAssertEqual(server.started.withLock { $0[id] }, oldID, "under the id it was recorded under")
        let threw = await deleteShared()
        XCTAssertFalse(threw)
        let request = try XCTUnwrap(StubProtocol.seen("/v1/contributions/delete").last)
        try Self.checkDeletion(request, contributor: oldID, signedBy: publicKey)
    }

    /// The device key and the recovery code are files that the next process cannot read: a take there makes no new
    /// key and no new code, the files are not written over, nothing is uploaded, and "delete what I shared" asks
    /// the server nothing (a request signed by another key would be answered 202 and delete nothing) and changes
    /// nothing. Once they read: the same bytes, and the deletion is signed with the key that was there.
    func testADeviceKeyAndRecoveryCodeThatCannotBeReadAreNotMadeAnew() async throws {
        MemoryKeychain(absent: true).install()
        let server = SharingTests.Server()
        serve(server)
        let storage = CloudFixtures.storage()
        _ = try await firstProcess(server, storage)
        let keyFile = storage.appendingPathComponent("cloud/contributor-key")
        let codeFile = storage.appendingPathComponent("cloud/contributor-recovery")
        let oldKey = try Data(contentsOf: keyFile), oldCode = try Data(contentsOf: codeFile)
        let oldID = QuranLab.contributorID
        let publicKey = try XCTUnwrap(ContributorKey.key(storage: storage)).publicKey

        StorageLock.refuse(["cloud/contributor-key", "cloud/contributor-recovery"])
        server.down.withLock { $0 = false }
        let mark = StubProtocol.seen.count
        let cloud = await launch(storage: storage)
        XCTAssertEqual(Contributions.consent, .granted)
        let second = try record()
        await cloud.outbox.drain(ignoringBackoff: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(second, "no recording begins while the key cannot be read")
        XCTAssertEqual(try Data(contentsOf: keyFile), oldKey, "the device key is what it was, byte for byte")
        XCTAssertEqual(try Data(contentsOf: codeFile), oldCode, "the recovery code is what it was, byte for byte")
        XCTAssertEqual(Self.uploads(after: mark), [], "nothing is uploaded while the key cannot be read")
        // a deletion while the key cannot be read
        let threw = await deleteShared()
        XCTAssertTrue(threw, "the call says it could not be done")
        XCTAssertEqual(StubProtocol.seen("/v1/contributions/challenge").count, 0, "the server is not asked")
        XCTAssertEqual(StubProtocol.seen("/v1/contributions/delete").count, 0, "with a key that is not the learner's")
        XCTAssertEqual(Contributions.consent, .granted, "and nothing changes: sharing is as it was")
        XCTAssertEqual(try Data(contentsOf: keyFile), oldKey)
        XCTAssertEqual(try Data(contentsOf: codeFile), oldCode)

        StorageLock.open()
        XCTAssertEqual(QuranLab.contributorID, oldID)
        let again = await deleteShared()
        XCTAssertFalse(again, "once the key reads, the deletion is asked")
        let request = try XCTUnwrap(StubProtocol.seen("/v1/contributions/delete").last)
        try Self.checkDeletion(request, contributor: oldID, signedBy: publicKey)
        XCTAssertEqual(Contributions.consent, .final, "an accepted deletion turns sharing off, as before")
    }

    /// The learner's summary is not asked of the server while the id cannot be read: the call gives nothing, and no
    /// request goes out with an empty contributor.
    func testTheSummaryIsNotAskedWhileTheIdCannotBeRead() async throws {
        MemoryKeychain(absent: true).install()
        let server = SharingTests.Server()
        serve(server)
        let storage = CloudFixtures.storage()
        _ = try await firstProcess(server, storage)
        StorageLock.refuse(["cloud/contributor"])
        _ = await launch(storage: storage)
        let summary = await Contributions.summary()
        XCTAssertNil(summary)
        XCTAssertEqual(StubProtocol.seen("/v1/contributions/summary").count, 0, "no request without the contributor")
    }

    /// The device key's stored bytes read, and they are a Secure Enclave key that the enclave does not give (here: a
    /// blob that is not one of this machine's enclave, or a machine without one; the stand-in for an enclave that
    /// answers "not now"). That is a key that is there and cannot be read: no new key is made in its place, the
    /// stored bytes stay, no recording begins, and a deletion is not asked.
    func testADeviceKeyTheEnclaveDoesNotGiveIsNotReplaced() async throws {
        MemoryKeychain(absent: true).install()
        let server = SharingTests.Server()
        serve(server)
        let storage = CloudFixtures.storage()
        _ = try await firstProcess(server, storage)
        let keyFile = storage.appendingPathComponent("cloud/contributor-key")
        // the stored form of an enclave key: the kind byte 1, then the enclave's blob
        let blob = Data([1]) + Data((0..<96).map { UInt8(($0 * 7 + 3) % 251) })
        try blob.write(to: keyFile)

        let cloud = await launch(storage: storage)
        XCTAssertEqual(Contributions.consent, .granted)
        let second = try record()
        await cloud.outbox.drain(ignoringBackoff: true)
        XCTAssertNil(second, "no recording begins with a key the enclave does not give")
        XCTAssertEqual(try Data(contentsOf: keyFile), blob, "the stored key is what it was: no new key took its place")
        let threw = await deleteShared()
        XCTAssertTrue(threw, "a deletion says it could not be done")
        XCTAssertEqual(StubProtocol.seen("/v1/contributions/challenge").count, 0, "and the server is not asked")
        XCTAssertEqual(Contributions.consent, .granted, "sharing is as it was")
        XCTAssertEqual(try Data(contentsOf: keyFile), blob)
    }

    /// The three are in the Keychain, and the next process finds a Keychain that cannot be read (every call is
    /// answered `errSecInteractionNotAllowed`, the status of a read before the first unlock): no id, key or code
    /// is made beside it in a file, no recording begins, nothing is uploaded, a deletion is not asked. Once it
    /// reads: the same bytes as before, the same id, and a deletion is signed with the key that was there.
    func testWhileTheKeychainCannotBeReadNothingIsMadeAnewAndTheOldItemsComeBack() async throws {
        let keychain = MemoryKeychain()
        keychain.install()
        let server = SharingTests.Server()
        serve(server)
        let storage = CloudFixtures.storage()
        _ = try await firstProcess(server, storage)
        let names = ["contributor", "contributor-key", "contributor-recovery"]
        let before = keychain.stored
        XCTAssertEqual(before.keys.sorted(), names, "the first share put the three in the Keychain")
        let fm = FileManager.default
        for name in names {
            XCTAssertFalse(fm.fileExists(atPath: storage.appendingPathComponent("cloud/\(name)").path), "\(name) is in the Keychain, not in a file")
        }
        let oldID = String(decoding: before["contributor"] ?? Data(), as: UTF8.self)
        XCTAssertEqual(QuranLab.contributorID, oldID)
        let publicKey = try XCTUnwrap(ContributorKey.key(storage: storage)).publicKey

        keychain.setLocked(true)
        server.down.withLock { $0 = false }
        let mark = StubProtocol.seen.count
        let cloud = await launch(storage: storage)
        XCTAssertEqual(Contributions.consent, .granted)
        let second = try record()
        await cloud.outbox.drain(ignoringBackoff: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(second, "no recording begins while the Keychain cannot be read")
        for name in names {
            XCTAssertFalse(fm.fileExists(atPath: storage.appendingPathComponent("cloud/\(name)").path),
                           "no \(name) is made in a file beside the one the Keychain holds")
        }
        XCTAssertEqual(Self.uploads(after: mark), [], "nothing is uploaded while the Keychain cannot be read")
        let threw = await deleteShared()
        XCTAssertTrue(threw, "a deletion says it could not be done")
        XCTAssertEqual(StubProtocol.seen("/v1/contributions/challenge").count, 0, "and the server is not asked")
        XCTAssertEqual(Contributions.consent, .granted, "sharing is as it was")
        XCTAssertEqual(keychain.stored, before, "the Keychain holds what it held")

        keychain.setLocked(false)
        XCTAssertEqual(keychain.stored, before, "the same bytes as before")
        XCTAssertEqual(QuranLab.contributorID, oldID, "the same id")
        let again = await deleteShared()
        XCTAssertFalse(again)
        let request = try XCTUnwrap(StubProtocol.seen("/v1/contributions/delete").last)
        try Self.checkDeletion(request, contributor: oldID, signedBy: publicKey)
    }
}
