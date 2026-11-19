import Foundation
import XCTest
@testable import TajweedFormer

/// The public calls that forward a background session's events, and the time an install asks the system for
/// (3.1.5). No background URLSession is made here and no app is suspended: these tests show the SDK's own
/// bookkeeping (which identifiers are its own, that a completion handler is called exactly once, also when the
/// call comes before the Client is made) and, with a stand-in for the system's assertion, that an install begins
/// it once and ends it however it ends. That the system relaunches an app and that a download goes on after the
/// learner leaves are shown only by a phone.
final class BackgroundEventsTests: XCTestCase {
    override func setUp() {
        BackgroundEvents.patience.withLock { $0 = 0.3 }
    }

    override func tearDown() {
        BackgroundEvents.patience.withLock { $0 = 20 }
        InstallGrace.override.withLock { $0 = nil }
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// Waits until the counter is above 0, at most `seconds`.
    static func waitUntilCalled(_ called: Locked<Int>, seconds: Double = 10) async throws {
        let end = Date().addingTimeInterval(seconds)
        while called.withLock({ $0 }) == 0, Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testTheSDKsSessionsAreKnownByTheirIdentifier() {
        XCTAssertTrue(TajweedClient.isBackgroundSession(BackgroundUploader.identifier(for: CloudFixtures.app)), "the upload queue's session")
        XCTAssertTrue(TajweedClient.isBackgroundSession("ai.quranlab.contributions.org.example.app"))
        XCTAssertFalse(TajweedClient.isBackgroundSession("org.example.app.downloads"))
        XCTAssertFalse(TajweedClient.isBackgroundSession(""))
    }

    /// A session that is not the SDK's: false, and the handler is left to its owner.
    func testAnotherSessionsHandlerIsNotTaken() async throws {
        let called = Locked(0)
        let taken = TajweedClient.handleBackgroundEvents(identifier: "org.example.app.downloads") { called.withLock { $0 += 1 } }
        XCTAssertFalse(taken)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(called.withLock { $0 }, 0, "not the SDK's to call")
        // the form for SwiftUI returns at once
        let started = Date()
        await TajweedClient.backgroundEvents(identifier: "org.example.app.downloads")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// The system's call comes before the app has made a Client, and no Client is made: the handler is called all
    /// the same, once, after the short wait (0.3 seconds here; 20 in an app).
    func testAHandlerThatComesBeforeTheClientIsCalledOnceAllTheSame() async throws {
        let id = "ai.quranlab.contributions.test." + UUID().uuidString
        let called = Locked(0)
        let taken = TajweedClient.handleBackgroundEvents(identifier: id) { called.withLock { $0 += 1 } }
        XCTAssertTrue(taken)
        XCTAssertEqual(called.withLock { $0 }, 0, "not before its session delivered, or the wait passed")
        try await Self.waitUntilCalled(called)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(called.withLock { $0 }, 1, "exactly once")
    }

    /// The handler waits for its session: when the session is made, it is handed the handler, and calling it then
    /// (the session delivered its events) calls the app's handler once; the wait's own call does not call it again.
    func testAWaitingHandlerIsHandedToItsSessionAndCalledOnce() async throws {
        BackgroundEvents.patience.withLock { $0 = 1.0 }
        let id = "ai.quranlab.contributions.test." + UUID().uuidString
        let called = Locked(0)
        XCTAssertTrue(TajweedClient.handleBackgroundEvents(identifier: id) { called.withLock { $0 += 1 } })
        XCTAssertNil(BackgroundEvents.take("ai.quranlab.contributions.another"), "only its own session takes it")
        let handed = try XCTUnwrap(BackgroundEvents.take(id), "the session, once made, is handed the waiting handler")
        XCTAssertNil(BackgroundEvents.take(id), "once")
        handed()
        try await Self.waitUntilCalled(called)
        XCTAssertEqual(called.withLock { $0 }, 1)
        handed()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(called.withLock { $0 }, 1, "neither a second call nor the wait calls it again")
    }

    /// The form for SwiftUI returns when the handler would be called.
    func testTheAsyncFormReturns() async throws {
        let started = Date()
        await TajweedClient.backgroundEvents(identifier: "ai.quranlab.contributions.test." + UUID().uuidString)
        let took = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(took, 0.25, "it waited for the session")
        XCTAssertLessThan(took, 10)
    }

    /// An install asks the system for time once and gives it back however it ends: here two installs that fail,
    /// one on the network and one on a refusal of the model host. The system's assertion is a stand-in that counts.
    /// 4.0: through the public Client over the suite's stub API and CDN; 3.1.5 also ran a download that succeeds and
    /// a launch that finds its model, which in 4.0 need a lease the Core holds (Stage B's staging run has both).
    func testAnInstallAsksForTimeOnceAndGivesItBackHoweverItEnds() async throws {
        let begun = Locked<[String]>([])
        let ended = Locked(0)
        InstallGrace.override.withLock {
            $0 = { name in
                begun.withLock { $0.append(name) }
                return { ended.withLock { $0 += 1 } }
            }
        }
        let refusal = StubProtocol.Reply.json(["error": "missing or invalid x-qlab-key", "reason": "key_revoked"], status: 401)
        for answer in [StubProtocol.Reply.down, refusal] {
            StubProtocol.reset(CloudFixtures.server(extra: { s in s.url.host == CloudFixtures.cdn.host ? answer : nil }))
            let options = CloudFixtures.options(updates: .manual, storage: CloudFixtures.storage())
            let client = try TajweedClient(key: CloudFixtures.key, configuration: options, cloud: { root in
                CloudFixtures.cloud(storage: root, options: options, installKeys: MemoryInstallKeyStore())
            })
            let before = begun.withLock { $0 }.count
            do {
                _ = try await client.model()
                XCTFail("no build can come")
            } catch {}
            client.close()
            XCTAssertEqual(begun.withLock { $0 }.count, before + 1, "asked for once when the install started")
            XCTAssertTrue(begun.withLock { $0 }.allSatisfy { $0 == "ai.quranlab.model-download" })
            XCTAssertEqual(ended.withLock { $0 }, begun.withLock { $0 }.count, "given back when the install failed")
        }
    }
}
