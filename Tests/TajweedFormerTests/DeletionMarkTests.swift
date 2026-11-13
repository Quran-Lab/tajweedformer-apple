import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// "Delete what I shared" in a process that ends before the server has answered (3.1.4).
///
/// Before the server is asked, the SDK writes on the device that a deletion was asked: a mark, a small file of
/// its own in the storage folder. A start that finds the mark turns sharing off, as before, and then asks the
/// server again, with the same contributor and the same device key; the mark goes only when the server has
/// answered 202 and the device's part is done. Until 3.1.3 such a start turned sharing off and never asked the
/// server again.
///
/// The server is the suite's stub. "The process ends" is: the first process's call is left waiting for an answer
/// to its challenge that never comes, its upload queue is shut down, and a new server client and queue open the
/// same storage. The contributor's id, key and recovery code are files here (a process without a Keychain, by
/// the Keychain's stand-in), so that the next start finds what the first one left. No test kills a process.
final class DeletionMarkTests: UnreadableStorageTestCase {
    /// What the challenge and the delete route answer, per call (1-based), and the gate the first challenge waits
    /// behind when a test lets the first process end while it asks.
    final class Routes: @unchecked Sendable {
        let delete = Locked<(Int) -> StubProtocol.Reply>({ _ in .json(["ok": true], status: 202) })
        let held = Locked<StubProtocol.Gate?>(nil)

        static func nonce(_ n: Int) -> String { "d1.1794000000.AAAA.N\(n)" }
    }

    static var challenges: [StubProtocol.Seen] { StubProtocol.seen("/v1/contributions/challenge") }
    static var deletions: [StubProtocol.Seen] { StubProtocol.seen("/v1/contributions/delete") }

    /// Where the mark is kept.
    static func mark(_ storage: URL) -> URL { storage.appendingPathComponent("cloud/deletion-pending.json") }

    override func setUp() {
        MemoryKeychain(absent: true).install()
    }

    func serve(_ server: SharingTests.Server, _ routes: Routes) {
        let answers = server.handler
        StubProtocol.reset { (s: StubProtocol.Seen) -> StubProtocol.Reply in
            if s.path == "/v1/contributions/challenge" {
                let n = DeletionMarkTests.challenges.count
                var r = StubProtocol.Reply.json(["nonce": Routes.nonce(n), "expires_in": 300])
                // the server that is being asked and has not answered
                if n == 1, let gate = routes.held.withLock({ $0 }) { r.hold = gate }
                return r
            }
            if s.path == "/v1/contributions/delete" {
                let n = DeletionMarkTests.deletions.count
                return routes.delete.withLock { $0(n) }
            }
            return answers(s)
        }
    }

    /// What the first process leaves: the learner said yes, made a recording that waits unsent, and tapped
    /// "delete what I shared"; the process ended while the server was being asked (the challenge is not answered,
    /// the deletion request never left).
    struct Left {
        let storage: URL
        let folder: URL
        let contributor: String
        let publicKey: P256.Signing.PublicKey
        let asking: Task<Void, Never>
        let gate: StubProtocol.Gate
    }

    func endedWhileAsking(_ server: SharingTests.Server, _ routes: Routes) async throws -> Left {
        let gate = StubProtocol.Gate()
        routes.held.withLock { $0 = gate }
        let storage = CloudFixtures.storage()
        let made = try await share(server, storage)
        let contributor = QuranLab.contributorID
        let publicKey = try XCTUnwrap(ContributorKey.key(storage: storage)).publicKey
        let asking = Task { _ = try? await Contributions.deleteShared() }
        let asked = await until(10) { DeletionMarkTests.challenges.count == 1 }
        XCTAssertTrue(asked, "the first process asked the server")
        XCTAssertEqual(DeletionMarkTests.deletions.count, 0, "the deletion request never left the first process")
        made.cloud.outbox.shutdown()
        server.down.withLock { $0 = false }
        return Left(storage: storage, folder: made.cloud.outbox.root.appendingPathComponent(made.id), contributor: contributor,
                    publicKey: publicKey, asking: asking, gate: gate)
    }

    /// The first process is over: what it was still waiting for ends with the test.
    func finish(_ left: Left) async {
        left.asking.cancel()
        await left.asking.value
        left.gate.open()
    }

    /// The process ends after the learner's tap and before the deletion request leaves. The next start finds
    /// sharing off and asks the server: a fresh challenge, the deletion for the same contributor, signed with the
    /// same device key, with neither the developer key nor a token. After the 202 the device's part is done (the
    /// unsent recording is gone, the contributor is a new one) and the mark is gone; a third start asks nothing.
    func testADeletionTheProcessEndedInIsAskedAgainAtTheNextStart() async throws {
        let server = SharingTests.Server()
        let routes = Routes()
        serve(server, routes)
        let left = try await endedWhileAsking(server, routes)
        let mark = DeletionMarkTests.mark(left.storage)

        // the next start
        let second = await launch(storage: left.storage)
        XCTAssertEqual(Contributions.consent, .final, "sharing is off, as before")
        let again = await until(10) { DeletionMarkTests.deletions.count == 1 }
        XCTAssertTrue(again, "the server is asked again")
        let request = try XCTUnwrap(DeletionMarkTests.deletions.first)
        try Self.checkDeletion(request, contributor: left.contributor, signedBy: left.publicKey)
        XCTAssertEqual(DeletionMarkTests.challenges.count, 2, "with a fresh challenge")
        XCTAssertEqual(request.json?["nonce"] as? String, Routes.nonce(2), "and that challenge's nonce")
        for r in DeletionMarkTests.challenges {
            XCTAssertNil(r.headers["authorization"], "no token on a challenge")
            XCTAssertNil(r.headers["x-qlab-key"], "no developer key on a challenge")
            XCTAssertEqual(r.json?["contributor"] as? String, left.contributor)
        }
        let folder = left.folder
        let done = await until(10) { !FileManager.default.fileExists(atPath: mark.path) && !FileManager.default.fileExists(atPath: folder.path) }
        XCTAssertTrue(done, "after the 202 the unsent recording is gone, and the mark with it")
        XCTAssertNotEqual(QuranLab.contributorID, left.contributor, "a new contributor after the deletion")
        XCTAssertEqual(Contributions.consent, .final)

        // a third start: nothing is asked
        second.outbox.shutdown()
        _ = await launch(storage: left.storage)
        XCTAssertEqual(Contributions.consent, .final)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(DeletionMarkTests.challenges.count, 2, "a third start asks nothing")
        XCTAssertEqual(DeletionMarkTests.deletions.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mark.path), "and the mark is gone")
        await finish(left)
    }

    /// The server answers the deletion of the next start with 401 `nonce_invalid` (or `timestamp_invalid`): it is
    /// asked once more in that start, with one fresh challenge. When that is refused the same way too, the start
    /// asks no more and the mark stays for the next start.
    func testARefusedNonceIsAnsweredOnceWithAFreshChallenge() async throws {
        for code in ["nonce_invalid", "timestamp_invalid"] {
            let server = SharingTests.Server()
            let routes = Routes()
            serve(server, routes)
            let left = try await endedWhileAsking(server, routes)
            let mark = DeletionMarkTests.mark(left.storage)
            let refused = StubProtocol.Reply.json(["error": code, "message": "Refused."], status: 401)

            // once refused, then accepted
            routes.delete.withLock { $0 = { n in n == 1 ? refused : .json(["ok": true], status: 202) } }
            let second = await launch(storage: left.storage)
            XCTAssertEqual(Contributions.consent, .final, code)
            let twice = await until(10) { DeletionMarkTests.deletions.count == 2 }
            XCTAssertTrue(twice, "\(code): asked once more")
            XCTAssertEqual(DeletionMarkTests.challenges.count, 3, "\(code): with one fresh challenge")
            XCTAssertEqual(DeletionMarkTests.deletions.last?.json?["nonce"] as? String, Routes.nonce(3), code)
            try Self.checkDeletion(try XCTUnwrap(DeletionMarkTests.deletions.last), contributor: left.contributor, signedBy: left.publicKey)
            let gone = await until(10) { !FileManager.default.fileExists(atPath: mark.path) }
            XCTAssertTrue(gone, "\(code): the mark is gone after the 202")
            second.outbox.shutdown()
            await finish(left)
            QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)

            // refused both times: no third request in that start, and the mark stays
            serve(server, routes)
            let other = try await endedWhileAsking(server, routes)
            routes.delete.withLock { $0 = { _ in refused } }
            _ = await launch(storage: other.storage)
            XCTAssertEqual(Contributions.consent, .final, code)
            let both = await until(10) { DeletionMarkTests.deletions.count == 2 }
            XCTAssertTrue(both, "\(code): asked, and once more")
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(DeletionMarkTests.deletions.count, 2, "\(code): and no more in this start")
            XCTAssertTrue(FileManager.default.fileExists(atPath: DeletionMarkTests.mark(other.storage).path), "\(code): the mark stays for the next start")
            await finish(other)
            QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
        }
    }

    /// The server answers the deletion of the next start with 503, with 429, or not at all: the start asks once,
    /// the mark stays, sharing stays off, and the contributor is not replaced. The start after that asks again,
    /// with the same contributor and key, and after its 202 the mark is gone.
    func testAnAnswerThatIsNotAnAnswerLeavesTheMarkForTheNextStart() async throws {
        let answers: [(name: String, reply: StubProtocol.Reply)] = [
            ("503", .json(["error": "unavailable", "message": "Later."], status: 503)),
            ("429", .json(["error": "rate_limited", "message": "Later."], status: 429)),
            ("no answer", .down),
        ]
        for a in answers {
            let server = SharingTests.Server()
            let routes = Routes()
            serve(server, routes)
            let left = try await endedWhileAsking(server, routes)
            let mark = DeletionMarkTests.mark(left.storage)
            let reply = a.reply
            routes.delete.withLock { $0 = { _ in reply } }

            let second = await launch(storage: left.storage)
            XCTAssertEqual(Contributions.consent, .final, a.name)
            let asked = await until(10) { DeletionMarkTests.deletions.count == 1 }
            XCTAssertTrue(asked, "\(a.name): the server is asked")
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(DeletionMarkTests.deletions.count, 1, "\(a.name): once in this start")
            XCTAssertTrue(FileManager.default.fileExists(atPath: mark.path), "\(a.name): the mark stays")
            XCTAssertEqual(Contributions.consent, .final, "\(a.name): sharing stays off")
            XCTAssertEqual(QuranLab.contributorID, left.contributor, "\(a.name): the contributor is not replaced before the 202")

            // the start after that
            second.outbox.shutdown()
            routes.delete.withLock { $0 = { _ in .json(["ok": true], status: 202) } }
            _ = await launch(storage: left.storage)
            XCTAssertEqual(Contributions.consent, .final, a.name)
            let again = await until(10) { DeletionMarkTests.deletions.count == 2 }
            XCTAssertTrue(again, "\(a.name): the next start asks again")
            try Self.checkDeletion(try XCTUnwrap(DeletionMarkTests.deletions.last), contributor: left.contributor, signedBy: left.publicKey)
            let gone = await until(10) { !FileManager.default.fileExists(atPath: mark.path) }
            XCTAssertTrue(gone, "\(a.name): after the 202 the mark is gone")
            await finish(left)
            QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
        }
    }

    /// The upgrade: a state that SDK 3.1.3 or an earlier one stored while it asked the server (`deleting` set),
    /// in a process that ended there. The first start of this SDK takes it for the mark: sharing is off, and the
    /// server is asked again with the contributor and the key that are on the device.
    func testAStoredDeletingOfAnEarlierSDKIsTakenForTheMark() async throws {
        let server = SharingTests.Server()
        let routes = Routes()
        serve(server, routes)
        let storage = CloudFixtures.storage()
        let made = try await share(server, storage)
        let contributor = QuranLab.contributorID
        let publicKey = try XCTUnwrap(ContributorKey.key(storage: storage)).publicKey
        await end(made.cloud)
        // as the earlier SDK left it: the state says that a deletion is being asked, and there is no mark file
        let state = storage.appendingPathComponent("cloud/sharing-state.json")
        var saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])
        saved["deleting"] = true
        try JSONSerialization.data(withJSONObject: saved).write(to: state)
        let fm = FileManager.default
        try? fm.removeItem(at: DeletionMarkTests.mark(storage))

        server.down.withLock { $0 = false }
        _ = await launch(storage: storage)
        XCTAssertEqual(Contributions.consent, .final, "sharing is off, as before")
        let asked = await until(10) { DeletionMarkTests.deletions.count == 1 }
        XCTAssertTrue(asked, "the server is asked")
        try Self.checkDeletion(try XCTUnwrap(DeletionMarkTests.deletions.first), contributor: contributor, signedBy: publicKey)
        let mark = DeletionMarkTests.mark(storage)
        let gone = await until(10) { !FileManager.default.fileExists(atPath: mark.path) }
        XCTAssertTrue(gone, "after the 202 no mark is left")
        let now = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])
        XCTAssertNotEqual(now["deleting"] as? Bool, true, "and the stored state no longer says that a deletion is being asked")
        XCTAssertEqual(now["consent"] as? String, "final")
    }

    /// The next start cannot read the device key: the server is not asked at all (a request signed by another key
    /// would be answered 202 and delete nothing), and the mark stays. The start after that reads the key and asks
    /// with it.
    func testAStartThatCannotReadTheDeviceKeyDoesNotAskAndKeepsTheMark() async throws {
        let server = SharingTests.Server()
        let routes = Routes()
        serve(server, routes)
        let left = try await endedWhileAsking(server, routes)
        let mark = DeletionMarkTests.mark(left.storage)
        let keyFile = left.storage.appendingPathComponent("cloud/contributor-key")
        let oldKey = try Data(contentsOf: keyFile)

        StorageLock.refuse(["cloud/contributor-key"])
        let second = await launch(storage: left.storage)
        XCTAssertEqual(Contributions.consent, .final, "sharing is off, as before")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(DeletionMarkTests.challenges.count, 1, "no challenge is asked for with a key that cannot be read")
        XCTAssertEqual(DeletionMarkTests.deletions.count, 0, "and no deletion")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mark.path), "the mark stays")
        XCTAssertEqual(try Data(contentsOf: keyFile), oldKey, "the device key is what it was")

        StorageLock.open()
        second.outbox.shutdown()
        _ = await launch(storage: left.storage)
        XCTAssertEqual(Contributions.consent, .final)
        let asked = await until(10) { DeletionMarkTests.deletions.count == 1 }
        XCTAssertTrue(asked, "the next start, which reads the key, asks")
        try Self.checkDeletion(try XCTUnwrap(DeletionMarkTests.deletions.first), contributor: left.contributor, signedBy: left.publicKey)
        let gone = await until(10) { !FileManager.default.fileExists(atPath: mark.path) }
        XCTAssertTrue(gone)
        await finish(left)
    }

    /// The next start finds the mark and cannot read the learner's stored answer: the mark is a mark all the
    /// same. Nothing is asked and nothing is written while the answer cannot be read; when it reads, in the same
    /// process, sharing is off and the server is asked.
    ///
    /// (The two tests after this one: the time while the mark is there, and a deletion over a damaged answer.)
    func testAMarkIsAMarkWhileTheStoredAnswerCannotBeRead() async throws {
        let server = SharingTests.Server()
        let routes = Routes()
        serve(server, routes)
        let left = try await endedWhileAsking(server, routes)
        let mark = DeletionMarkTests.mark(left.storage)
        let state = left.storage.appendingPathComponent("cloud/sharing-state.json")
        let answer = try Data(contentsOf: state)

        StorageLock.refuse(["cloud/sharing-state.json"])
        _ = await launch(storage: left.storage)
        XCTAssertFalse(Contributions.isActive, "nothing is shared")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(DeletionMarkTests.deletions.count, 0, "nothing is asked while the answer cannot be read")
        XCTAssertEqual(try Data(contentsOf: state), answer, "and nothing is written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mark.path), "the mark is there")

        StorageLock.open()
        XCTAssertEqual(Contributions.consent, .final, "the answer reads: sharing is off")
        let asked = await until(10) { DeletionMarkTests.deletions.count == 1 }
        XCTAssertTrue(asked, "and the server is asked")
        try Self.checkDeletion(try XCTUnwrap(DeletionMarkTests.deletions.first), contributor: left.contributor, signedBy: left.publicKey)
        let gone = await until(10) { !FileManager.default.fileExists(atPath: mark.path) }
        XCTAssertTrue(gone)
        await finish(left)
    }

    /// While the mark is there (the server has not confirmed the deletion: here it answers 503), the learner
    /// turns sharing on again. Their yes is stored at once, and it stands at the next start; but nothing is
    /// recorded for sharing and nothing is uploaded until the mark is gone: no recording may belong to a
    /// contributor whose deletion is being asked. After the next start's 202 a take is recorded and uploaded,
    /// under the new contributor.
    func testWhileTheMarkIsThereNothingIsRecordedAndTheLearnersYesWaits() async throws {
        let server = SharingTests.Server()
        let routes = Routes()
        serve(server, routes)
        let left = try await endedWhileAsking(server, routes)
        let mark = DeletionMarkTests.mark(left.storage)
        routes.delete.withLock { $0 = { _ in .json(["error": "unavailable", "message": "Later."], status: 503) } }

        let second = await launch(storage: left.storage)
        XCTAssertEqual(Contributions.consent, .final, "sharing is off, as before")
        let asked = await until(10) { DeletionMarkTests.deletions.count == 1 }
        XCTAssertTrue(asked, "the server is asked, and does not confirm")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mark.path), "the mark is there")
        // the learner turns sharing on again
        let before = StubProtocol.seen.count
        await Contributions.setSharing(true)
        XCTAssertEqual(Contributions.consent, .granted, "their yes is their answer at once")
        XCTAssertEqual(try UnreadableStateTests.saved(left.storage)["consent"] as? String, "granted", "and it is stored")
        XCTAssertFalse(Contributions.isActive, "but nothing is shared while the mark is there")
        let none = try record()
        XCTAssertNil(none, "a take makes no recording for sharing")
        await second.outbox.drain(ignoringBackoff: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(Self.uploads(after: before), [], "and nothing is uploaded")
        XCTAssertEqual(QuranLab.contributorID, left.contributor, "the contributor is still the one whose deletion is being asked")

        // the next start: the yes stands, the server confirms, and then sharing goes on under a new contributor
        second.outbox.shutdown()
        routes.delete.withLock { $0 = { _ in .json(["ok": true], status: 202) } }
        let third = await launch(storage: left.storage)
        XCTAssertEqual(Contributions.consent, .granted, "the learner's yes stands at the next start")
        let confirmed = await until(10) { DeletionMarkTests.deletions.count == 2 }
        XCTAssertTrue(confirmed, "the next start asks again")
        try Self.checkDeletion(try XCTUnwrap(DeletionMarkTests.deletions.last), contributor: left.contributor, signedBy: left.publicKey)
        let gone = await until(10) { !FileManager.default.fileExists(atPath: mark.path) && Contributions.isActive }
        XCTAssertTrue(gone, "after the 202 the mark is gone and sharing is on")
        XCTAssertEqual(Contributions.consent, .granted)
        let id = try XCTUnwrap(try record(), "now a take is recorded")
        let outbox = third.outbox
        let up = await until(10) { await outbox.item(id)?.status == .uploaded }
        XCTAssertTrue(up, "and uploaded")
        let under = server.started.withLock { $0[id] }
        XCTAssertNotNil(under)
        XCTAssertNotEqual(under, left.contributor, "under a new contributor, not the one that was deleted")
        XCTAssertEqual(under, QuranLab.contributorID)
        await finish(left)
    }

    /// "Delete what I shared" over a stored answer that does not parse: the deletion is the learner's own act. The
    /// server is asked and accepts; a new answer is begun with sharing off, the damaged file is kept aside under
    /// another name, and no mark is left.
    func testADeletionOverADamagedAnswerBeginsANewOneWithSharingOff() async throws {
        let server = SharingTests.Server()
        let routes = Routes()
        serve(server, routes)
        let storage = CloudFixtures.storage()
        let made = try await share(server, storage)
        let contributor = QuranLab.contributorID
        let publicKey = try XCTUnwrap(ContributorKey.key(storage: storage)).publicKey
        await end(made.cloud)
        let damaged = Data("{\"v\":1,\"consent\":".utf8)
        try damaged.write(to: storage.appendingPathComponent("cloud/sharing-state.json"))

        server.down.withLock { $0 = false }
        _ = await launch(storage: storage)
        var threw = false
        do { try await Contributions.deleteShared() } catch { threw = true }
        XCTAssertFalse(threw, "the deletion is asked and accepted")
        try Self.checkDeletion(try XCTUnwrap(DeletionMarkTests.deletions.first), contributor: contributor, signedBy: publicKey)
        XCTAssertEqual(Contributions.consent, .final, "sharing is off")
        XCTAssertEqual(try UnreadableStateTests.saved(storage)["consent"] as? String, "final", "a new answer is on the device")
        XCTAssertEqual(try UnreadableStateTests.saved(storage)["asks"] as? Int, SharingState.maxAsks, "with its asks used up")
        XCTAssertEqual(UnreadableStateTests.keptAside(storage), [damaged], "the damaged file is kept aside under another name")
        XCTAssertFalse(FileManager.default.fileExists(atPath: DeletionMarkTests.mark(storage).path), "no mark is left")
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.cloud.outbox.root.appendingPathComponent(made.id).path), "the unsent queue is gone")
    }

    /// Both marks at once: a deletion that a process ended in, and an off that the learner asked in the next
    /// process while the stored answer could not be read. When the answer reads, the off is applied once (the
    /// count of the learner's changes of mind goes up by one, not by two), the off's mark is gone, and the deletion
    /// is still asked of the server.
    func testAnOffAndADeletionThatAreBothWaitingAreAppliedOnceAndAsked() async throws {
        let server = SharingTests.Server()
        let routes = Routes()
        serve(server, routes)
        let left = try await endedWhileAsking(server, routes)
        let count = try XCTUnwrap(try UnreadableStateTests.saved(left.storage)["consentCount"] as? Int)
        let off = OffMarkTests.mark(left.storage)

        StorageLock.refuse(["cloud/sharing-state.json"])
        _ = await launch(storage: left.storage)
        var threw = false
        do { try await TajweedSharing().setOn(false) } catch { threw = true }
        XCTAssertFalse(threw, "the off does not throw")
        XCTAssertTrue(FileManager.default.fileExists(atPath: off.path), "the off's mark is written beside the deletion's")
        XCTAssertTrue(FileManager.default.fileExists(atPath: DeletionMarkTests.mark(left.storage).path))
        XCTAssertEqual(DeletionMarkTests.deletions.count, 0, "nothing is asked while the answer cannot be read")

        StorageLock.open()
        XCTAssertEqual(Contributions.consent, .final, "the answer reads: sharing is off")
        let now = try UnreadableStateTests.saved(left.storage)
        XCTAssertEqual(now["consentCount"] as? Int, count + 1, "the off was applied once")
        XCTAssertFalse(FileManager.default.fileExists(atPath: off.path), "the off's mark is gone")
        let asked = await until(10) { DeletionMarkTests.deletions.count == 1 }
        XCTAssertTrue(asked, "and the deletion is still asked")
        try Self.checkDeletion(try XCTUnwrap(DeletionMarkTests.deletions.first), contributor: left.contributor, signedBy: left.publicKey)
        let mark = DeletionMarkTests.mark(left.storage)
        let gone = await until(10) { !FileManager.default.fileExists(atPath: mark.path) }
        XCTAssertTrue(gone, "after the 202 the deletion's mark is gone too")
        await finish(left)
    }

    /// A deletion the server does not take while the process lives ends as before: the call throws, no mark is
    /// left, sharing is still on and the queue is as it was. Its requests carried neither the developer key nor a
    /// token.
    func testADeletionThatFailsWhileTheProcessLivesLeavesNoMark() async throws {
        let server = SharingTests.Server()
        let routes = Routes()
        serve(server, routes)
        routes.delete.withLock { $0 = { _ in .json(["error": "unavailable", "message": "Later."], status: 503) } }
        let storage = CloudFixtures.storage()
        let made = try await share(server, storage)
        let folder = made.cloud.outbox.root.appendingPathComponent(made.id)
        let contributor = QuranLab.contributorID
        var threw = false
        do { try await Contributions.deleteShared() } catch { threw = true }
        XCTAssertTrue(threw, "the call throws the error the app can show")
        XCTAssertEqual(DeletionMarkTests.deletions.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DeletionMarkTests.mark(storage).path), "no mark is left")
        XCTAssertEqual(Contributions.consent, .granted, "sharing is as it was")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "the queue is as it was")
        XCTAssertEqual(QuranLab.contributorID, contributor)
        for r in DeletionMarkTests.challenges + DeletionMarkTests.deletions {
            XCTAssertNil(r.headers["authorization"], "no token on \(r.path)")
            XCTAssertNil(r.headers["x-qlab-key"], "no developer key on \(r.path)")
        }
        // a start after that asks nothing
        await end(made.cloud)
        _ = await launch(storage: storage)
        XCTAssertEqual(Contributions.consent, .granted)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(DeletionMarkTests.deletions.count, 1, "a later start asks nothing: no deletion is pending")
    }
}
