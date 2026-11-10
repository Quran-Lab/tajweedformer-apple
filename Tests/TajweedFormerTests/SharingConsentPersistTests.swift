import Foundation
import XCTest
@testable import TajweedFormer

/// A learner who said yes is never asked again: the grant keeps the consent version it was given across SDK upgrades
/// (2.0.0's state read as 2.0.0 wrote it), copy decks and the app's wording; every session JSON carries that version;
/// the settings switch records the version in force when it is turned on; withdrawal and deletion work under any
/// version.
final class SharingConsentPersistTests: XCTestCase {
    override func tearDown() {
        try? Contributions.setWording(nil)
        Contributions.setPresenter(nil)
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// The sharing state exactly as SDK 2.0.0 declared it (its `SharingState`, the consent as its raw string), written
    /// the way 2.0.0 wrote it: `JSONEncoder()` to `cloud/sharing-state.json`.
    struct State200: Codable {
        var v = 1
        var consent = "unknown"
        var asks = 0
        var lastAskSession = 0
        var sessions = 0
        var thanked = false
        var decidedAt: Double?
        var consentVersion: String?
        var guardian = false
        var sharedOnce = false
    }

    static func write200(_ s: State200, storage: URL) throws {
        let url = storage.appendingPathComponent("cloud/sharing-state.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(s).write(to: url, options: .atomic)
    }

    /// A learner who agreed under 2.0.0 and has been sharing since.
    static func granted200(version: String?) -> State200 {
        State200(consent: "granted", asks: 1, lastAskSession: 2, sessions: 41, thanked: true, decidedAt: 1_794_200_000,
                 consentVersion: version, guardian: false, sharedOnce: true)
    }

    /// Every moment handed to the app's own UI.
    let seen = Locked<[SharingMoment]>([])

    /// A launch on `storage` with the stub server, its config in force, and a presenter that records every moment.
    @discardableResult
    func launch(_ server: SharingTests.Server, storage: URL) async -> QuranLabCloud {
        let options = CloudFixtures.options(contributions: true, storage: storage)
        let cloud = CloudFixtures.cloud(storage: storage, options: options)
        _ = await cloud.refreshConfig()
        QuranLab.configure(key: CloudFixtures.key, options: options, cloud: cloud)
        let seen = self.seen
        Contributions.setPresenter { (m: SharingMoment) in seen.withLock { $0.append(m) } }
        return cloud
    }

    /// No moment reached the app's UI (the presenter hands them over on the main actor: give it the time).
    func assertNothingPresented(_ why: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(seen.withLock { $0 }, [], why, file: file, line: line)
    }

    /// Waits until `done`.
    func waitUntil(_ what: String, timeout: TimeInterval = 15, _ done: () async -> Bool) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if await done() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// One shared session through the real capture and outbox; returns its session JSON (`count`: the session starts
    /// the server has seen in this test, this one included).
    func sharedSession(_ cloud: QuranLabCloud, count: Int) async throws -> [String: Any] {
        let c = try XCTUnwrap(Contributions.capture(revision: "test-rev", backend: .exact, weightsSHA256: nil), "sharing is on")
        let n = 48_000
        var at = 0
        while at < n {
            let k = min(4_800, n - at)
            try c.append(SharingTests.audio(k, seed: at + 1), rate: 48_000)
            at += k
        }
        c.finish(completed: true)
        try await waitUntil("the upload") {
            let items = await cloud.outbox.items
            return SharingTests.starts.count >= count && !items.isEmpty && items.allSatisfy { $0.status == .uploaded }
        }
        XCTAssertEqual(SharingTests.starts.count, count, "the session reached the server")
        return try XCTUnwrap(SharingTests.starts.last?.json)
    }

    /// A finished session with feedback, many times over: never an ask.
    func assertNeverAsked(_ sessions: Int, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        for i in 0..<sessions {
            XCTAssertNil(Contributions.sessionCompleted(feedback: true), "\(why) (session \(i + 1))", file: file, line: line)
        }
        XCTAssertNil(Contributions.askNow(), "\(why): not even at the app's own timing", file: file, line: line)
    }

    // MARK: upgrades from 2.0.0

    /// 2.0.0 recorded the version at the grant (`share-2026-11-07b`, its bundled deck): with the 2.0.1 deck in force
    /// no sheet, no pause; sharing is on and the session JSON carries the old version, before and after a session.
    func testA200GrantKeepsSharingUnderItsOwnVersion() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        try Self.write200(Self.granted200(version: "share-2026-11-07b"), storage: storage)
        let cloud = await launch(server, storage: storage)
        XCTAssertEqual(Contributions.consentVersionInForce, "share-2026-11-09", "the 2.0.1 deck is in force")
        XCTAssertEqual(Contributions.consent, .granted)
        XCTAssertTrue(Contributions.isActive, "no pause")
        assertNeverAsked(3, "a 2.0.0 grant before a session")
        let meta = try await sharedSession(cloud, count: 1)
        XCTAssertEqual(meta["consent_version"] as? String, "share-2026-11-07b", "the version the learner agreed to")
        XCTAssertNil(meta["consent_text_sha256"])
        assertNeverAsked(30, "a 2.0.0 grant after a session")
        try await assertNothingPresented("no sheet, no thank-you again, nothing handed to the app")
        XCTAssertTrue(Contributions.isActive)
        XCTAssertEqual(Contributions.state().consentVersion, "share-2026-11-07b")

        // and after a restart (the state read back from disk)
        let again = await launch(server, storage: storage)
        XCTAssertTrue(Contributions.isActive)
        assertNeverAsked(5, "a 2.0.0 grant after a restart")
        let next = try await sharedSession(again, count: 2)
        XCTAssertEqual(next["consent_version"] as? String, "share-2026-11-07b")
        try await assertNothingPresented("nothing after the restart either")
    }

    /// A granted 2.0.0 state without a version agreed to the deck 2.0.0 bundled on Apple platforms.
    func testA200GrantWithoutAVersionIsTheBundled200Deck() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        try Self.write200(Self.granted200(version: nil), storage: storage)
        let cloud = await launch(server, storage: storage)
        XCTAssertTrue(Contributions.isActive)
        XCTAssertEqual(Contributions.consentVersion, "share-2026-11-07b")
        assertNeverAsked(3, "a 2.0.0 grant without a version")
        let meta = try await sharedSession(cloud, count: 1)
        XCTAssertEqual(meta["consent_version"] as? String, "share-2026-11-07b")
        assertNeverAsked(10, "after the session")
        try await assertNothingPresented("no sheet")
    }

    /// A 2.0.0 "off" stays off and is never asked; a 2.0.0 decline stays declined.
    func testA200OffOrDeclineStaysSo() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let off = CloudFixtures.storage()
        try Self.write200(State200(consent: "final", asks: 1, lastAskSession: 2, sessions: 20, decidedAt: 1_794_200_000,
                                   consentVersion: "share-2026-11-07b"), storage: off)
        await launch(server, storage: off)
        XCTAssertEqual(Contributions.consent, .final)
        XCTAssertFalse(Contributions.isActive)
        XCTAssertNil(Contributions.capture(revision: "r", backend: .exact, weightsSHA256: nil))
        assertNeverAsked(30, "turned off under 2.0.0")
        try await assertNothingPresented("no sheet")

        let declined = CloudFixtures.storage()
        try Self.write200(State200(consent: "declined", asks: 1, lastAskSession: 5, sessions: 6, decidedAt: 1_794_200_000),
                          storage: declined)
        await launch(server, storage: declined)
        XCTAssertEqual(Contributions.consent, .declined)
        XCTAssertFalse(Contributions.isActive)
        XCTAssertEqual(Contributions.state().asks, 1, "the ask count carried over")
    }

    // MARK: a deck or wording change after a grant

    /// A 2.0.1 grant to another deck than the one in force (an earlier deck version on disk): no ask, the old version
    /// in the JSON.
    func testADeckChangeKeepsTheGrantAndItsVersion() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        await launch(server, storage: storage)
        _ = Contributions.update { s in
            s.consent = .granted
            s.asks = 1
            s.lastAskSession = 1
            s.sessions = 1
            s.decidedAt = 1_794_300_000
            s.consentVersion = "share-2026-10-01"
        }
        let cloud = await launch(server, storage: storage)
        XCTAssertNotEqual(Contributions.consentVersionInForce, "share-2026-10-01")
        XCTAssertTrue(Contributions.isActive)
        assertNeverAsked(30, "a grant to an earlier deck")
        let meta = try await sharedSession(cloud, count: 1)
        XCTAssertEqual(meta["consent_version"] as? String, "share-2026-10-01")
        XCTAssertNil(meta["consent_text_sha256"])
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .thanks, "the thank-you after the first shared session")
        assertNeverAsked(30, "after the session")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(seen.withLock { $0 }, [.thanks], "never an ask")
    }

    /// A grant under the app's own wording keeps its `custom-...` version and hash when the app changes its wording or
    /// goes back to the deck's words; a learner who agrees after the change records the new version.
    func testAWordingChangeKeepsACustomGrantAndANewLearnerGetsTheNewVersion() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        let cloud = await launch(server, storage: storage)
        try Contributions.setWording(["sheet.title": "Share your recitation with Quran Lab"])
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .ask(reask: false, guardian: false))
        Contributions.answer(share: true)
        let version = Contributions.consentVersionInForce
        let hash = try XCTUnwrap(Contributions.consentTextSHA256)
        XCTAssertTrue(version.hasPrefix("custom-"))
        let first = try await sharedSession(cloud, count: 1)
        XCTAssertEqual(first["consent_version"] as? String, version)
        XCTAssertEqual(first["consent_text_sha256"] as? String, hash)
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .thanks)
        try await waitUntil("the ask and the thank-you handed over") { seen.withLock { $0.count } == 2 }
        XCTAssertEqual(seen.withLock { $0 }, [.ask(reask: false, guardian: false), .thanks])
        seen.withLock { $0 = [] }

        try Contributions.setWording(["sheet.title": "Help the next learner", "sheet.share": "Share"])
        XCTAssertNotEqual(Contributions.consentVersionInForce, version, "the new wording has its own version")
        XCTAssertTrue(Contributions.isActive, "no pause")
        assertNeverAsked(30, "a wording change after a custom grant")
        let second = try await sharedSession(cloud, count: 2)
        XCTAssertEqual(second["consent_version"] as? String, version, "the version agreed to")
        XCTAssertEqual(second["consent_text_sha256"] as? String, hash, "the hash agreed to")
        try Contributions.setWording(nil)
        XCTAssertTrue(Contributions.isActive, "back to the deck's words: still no pause")
        let third = try await sharedSession(cloud, count: 3)
        XCTAssertEqual(third["consent_version"] as? String, version)
        XCTAssertEqual(third["consent_text_sha256"] as? String, hash)
        try await assertNothingPresented("never asked after the wording changed")

        // a new learner (another install) after the change agrees to the new words
        try Contributions.setWording(["sheet.title": "Help the next learner", "sheet.share": "Share"])
        let newVersion = Contributions.consentVersionInForce
        let newHash = try XCTUnwrap(Contributions.consentTextSHA256)
        let other = await launch(server, storage: CloudFixtures.storage())
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .ask(reask: false, guardian: false))
        Contributions.answer(share: true)
        XCTAssertEqual(Contributions.state().consentVersion, newVersion)
        let fourth = try await sharedSession(other, count: 4)
        XCTAssertEqual(fourth["consent_version"] as? String, newVersion)
        XCTAssertEqual(fourth["consent_text_sha256"] as? String, newHash)
    }

    // MARK: the settings switch

    /// "Not now" three times, then the settings switch: granted to the version in force at that moment, which the
    /// JSON carries; switching it on again changes nothing; after a later wording change the version stays.
    func testTheSettingsSwitchRecordsTheVersionInForceThen() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        let cloud = await launch(server, storage: storage)
        for _ in 0..<40 {
            if Contributions.sessionCompleted(feedback: true) != nil { Contributions.answer(share: false) }
        }
        XCTAssertEqual(Contributions.state().asks, 3)
        XCTAssertEqual(Contributions.consent, .final)
        try Contributions.setWording(["sheet.title": "Words in force when the learner turned it on"])
        let version = Contributions.consentVersionInForce
        await Contributions.setSharing(true)
        XCTAssertTrue(Contributions.isActive)
        XCTAssertEqual(Contributions.state().consentVersion, version)
        try Contributions.setWording(nil)
        await Contributions.setSharing(true)
        XCTAssertEqual(Contributions.state().consentVersion, version, "already on: the version stays")
        let meta = try await sharedSession(cloud, count: 1)
        XCTAssertEqual(meta["consent_version"] as? String, version)
        XCTAssertEqual(meta["consent_text_sha256"] as? String, Contributions.state().consentTextSHA256)
    }

    // MARK: withdrawal

    /// A 2.0.0 grant: the settings switch stops it at once (the queue deleted) and it is never asked again, across a
    /// restart; "Delete what I shared" works under the old version on another install.
    func testWithdrawalAndDeleteUnderA200Version() async throws {
        let server = SharingTests.Server()
        let base = server.handler
        StubProtocol.reset { (s: StubProtocol.Seen) -> StubProtocol.Reply in
            if s.path == "/v1/contributions/challenge" { return .json(["nonce": "d1.1794000000.AAAA.BBBB", "expires_in": 300]) }
            if s.path == "/v1/contributions/delete" { return .json(["ok": true], status: 202) }
            return base(s)
        }
        let storage = CloudFixtures.storage()
        try Self.write200(Self.granted200(version: "share-2026-11-07b"), storage: storage)
        let cloud = await launch(server, storage: storage)
        XCTAssertTrue(Contributions.isActive)
        server.down.withLock { $0 = true }
        let c = try XCTUnwrap(Contributions.capture(revision: "test-rev", backend: .exact, weightsSHA256: nil))
        try c.append(SharingTests.audio(48_000), rate: 48_000)
        c.finish(completed: true)
        try await waitUntil("the session queued") {
            let items = await cloud.outbox.items
            return items.count == 1 && items[0].lastError != nil
        }
        await Contributions.setSharing(false)
        XCTAssertEqual(Contributions.consent, .final)
        XCTAssertFalse(Contributions.isActive)
        let left = await cloud.outbox.items
        XCTAssertTrue(left.isEmpty, "the unsent queue is deleted")
        assertNeverAsked(30, "turned off after a yes")
        server.down.withLock { $0 = false }
        await launch(server, storage: storage)
        XCTAssertEqual(Contributions.consent, .final)
        assertNeverAsked(30, "turned off after a yes, after a restart")

        let other = CloudFixtures.storage()
        try Self.write200(Self.granted200(version: "share-2026-11-07b"), storage: other)
        await launch(server, storage: other)
        XCTAssertTrue(Contributions.isActive)
        _ = ContributorKey.key(storage: QuranLab.configuration.storageDirectory)
        let code = Contributions.contributionCode
        try await Contributions.deleteShared()
        XCTAssertEqual(StubProtocol.seen("/v1/contributions/delete").count, 1)
        XCTAssertEqual(Contributions.consent, .final)
        XCTAssertNotEqual(Contributions.contributionCode, code, "a new contributor after a deletion")
        assertNeverAsked(30, "after a deletion")
        try await assertNothingPresented("no sheet")
    }
}
