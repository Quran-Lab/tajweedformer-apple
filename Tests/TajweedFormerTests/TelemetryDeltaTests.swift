import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 2.0.1 telemetry: deltas sealed with a report id (a retry resends the same bytes), never across midnight, sent
/// every 15 minutes in use, at the background and at launch; the new counters from scored results and from the
/// sharing sheet (the SDK's and the app's own); the server's answers; registration once per UTC day.
final class TelemetryDeltaTests: XCTestCase {
    /// 2026-09-21 00:00:00 UTC.
    static let midnight = Date(timeIntervalSince1970: 1_789_948_800)

    override func tearDown() {
        Contributions.setPresenter(nil)
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    static func store(_ storage: URL, clock: @escaping @Sendable () -> Date) -> AnalyticsStore {
        AnalyticsStore(storage: storage, enabled: true,
                       context: .init(platform: "ios", sdkVersion: SDKInfo.version, appVersion: "2.1", deviceClass: "A17", soc: "a17",
                                      osMajor: 18, ramTier: "8_16"),
                       clock: clock)
    }

    static func json(_ d: Data) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:] }

    static func sessions(_ body: [String: Any]) -> Int {
        let cohorts = (body["cohorts"] as? [[String: Any]]) ?? []
        return cohorts.reduce(0) { (n: Int, c: [String: Any]) -> Int in n + ((c["sessions"] as? Int) ?? 0) }
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 10, _ done: () async -> Bool) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if await done() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: sealing

    /// A delta sealed and not sent (offline) is on disk with its report id; the next launch sends exactly those bytes.
    func testARetrySendsTheSameBytesWithTheSameReportID() async throws {
        let storage = CloudFixtures.storage()
        let at = Self.midnight.addingTimeInterval(3_600)
        let a = Self.store(storage, clock: { at })
        a.record(AnalyticsAndIssueTests.session(AnalyticsAndIssueTests.cpu, 60, [0.01]))
        let n = await a.flush(send: { (_: Data) async throws(CloudError) -> Void in throw CloudError.offline("down") })
        XCTAssertEqual(n, 0)
        let kept = try XCTUnwrap(a.sealed.first)
        XCTAssertEqual(a.sealed.count, 1)
        XCTAssertTrue(kept.reportID.count == 32 && kept.reportID.allSatisfy { $0.isHexDigit && !$0.isUppercase }, kept.reportID)
        XCTAssertEqual(Self.json(kept.body)["report_id"] as? String, kept.reportID)
        XCTAssertTrue(a.pending.isEmpty, "sealed: no longer open")

        let relaunched = Self.store(storage, clock: { at.addingTimeInterval(600) })
        XCTAssertEqual(relaunched.sealed.first?.reportID, kept.reportID, "the sealed delta survives a relaunch")
        let sent = Locked<[Data]>([])
        let m = await relaunched.flush(send: { (d: Data) async throws(CloudError) -> Void in sent.withLock { $0.append(d) } })
        XCTAssertEqual(m, 1)
        XCTAssertEqual(sent.withLock { $0 }, [kept.body], "the retry is the same body, byte for byte, with the same report id")
        XCTAssertTrue(relaunched.sealed.isEmpty)
    }

    /// Counts go to the UTC day they happened in: a send point after midnight sends two deltas, one per day.
    func testNoDeltaSpansMidnight() async throws {
        let now = Locked(Self.midnight.addingTimeInterval(86_400 - 60))   // 23:59 on 2026-09-21
        let a = Self.store(CloudFixtures.storage(), clock: { now.withLock { $0 } })
        a.record(AnalyticsAndIssueTests.session(AnalyticsAndIssueTests.cpu, 60, [0.01]))
        now.withLock { $0 = Self.midnight.addingTimeInterval(86_400 + 60) }   // 00:01 the next day
        a.record(AnalyticsAndIssueTests.session(AnalyticsAndIssueTests.cpu, 30, [0.01]))
        a.record(AnalyticsAndIssueTests.session(AnalyticsAndIssueTests.cpu, 30, [0.01]))
        let sent = Locked<[[String: Any]]>([])
        let n = await a.flush(send: { (d: Data) async throws(CloudError) -> Void in sent.withLock { $0.append(Self.json(d)) } })
        XCTAssertEqual(n, 2)
        let bodies = sent.withLock { $0 }
        XCTAssertEqual(bodies.map { ($0["day"] as? String) ?? "" }, ["2026-09-21", "2026-09-22"], "oldest first, one per day")
        XCTAssertEqual(bodies.map { Self.sessions($0) }, [1, 2])
        XCTAssertNotEqual(bodies[0]["report_id"] as? String, bodies[1]["report_id"] as? String)
    }

    // MARK: the counters

    /// From scored results: ayahs, per-surah ayahs, words, and per rule what was checked and flagged (qalqalah and
    /// gemination included, flags never above checks, valid keys only, at most 32).
    func testTheNewFieldsFromScoredResults() throws {
        let a = Self.store(CloudFixtures.storage(), clock: { Self.midnight })
        var s = ScoreTelemetry(cohort: AnalyticsAndIssueTests.cpu, surah: 36)
        s.classes["vowel_sub"] = .init(sites: 12, flagged: 2)
        s.classes["insertion"] = .init(sites: 3, flagged: 0)
        s.maddCounts = [2: 4, 6: 1]
        s.maddFlagged = 1
        s.qalqalahChecked = 2
        s.qalqalahFlagged = 1
        s.geminationChecked = 3
        s.wordsScored = 7
        s.wordsFlagged = 2
        a.record(.scored(s))
        a.record(.scored(ScoreTelemetry(cohort: AnalyticsAndIssueTests.cpu, surah: 36)))
        a.record(.scored(ScoreTelemetry(cohort: AnalyticsAndIssueTests.cpu, surah: 0)))
        let p = a.payload(try XCTUnwrap(a.pending.first), reportID: AnalyticsStore.reportID())
        XCTAssertEqual(p["ayahs"] as? Int, 3, "one per scored result")
        XCTAssertEqual(p["surah_ayahs"] as? [String: Int], ["36": 2], "surahs 1 to 114 only")
        XCTAssertEqual(p["words"] as? Int, 7)
        XCTAssertEqual(p["rule_checks"] as? [String: Int], ["vowel_sub": 12, "insertion": 3, "madd": 5, "qalqalah": 2, "gemination": 3, "word": 7])
        XCTAssertEqual(p["rule_flags"] as? [String: Int], ["vowel_sub": 2, "madd": 1, "qalqalah": 1, "word": 2])
        XCTAssertNil(p["launches"], "zero counters are left out")
        XCTAssertNil(p["share_asked"])

        // many rules: valid keys only, the 32 most checked, every flag key among the checks with no larger count
        let b = Self.store(CloudFixtures.storage(), clock: { Self.midnight })
        var many = ScoreTelemetry(cohort: AnalyticsAndIssueTests.cpu, surah: 1)
        for i in 0..<40 { many.classes[String(format: "rule_%02d", i)] = .init(sites: 100 + i, flagged: i) }
        many.classes["Bad-Key"] = .init(sites: 1_000, flagged: 1)
        b.record(.scored(many))
        let q = b.payload(try XCTUnwrap(b.pending.first), reportID: AnalyticsStore.reportID())
        let checks = try XCTUnwrap(q["rule_checks"] as? [String: Int])
        let flags = try XCTUnwrap(q["rule_flags"] as? [String: Int])
        XCTAssertEqual(checks.count, 32)
        XCTAssertNil(checks["Bad-Key"])
        XCTAssertNil(checks["rule_00"], "the least checked go")
        for (k, f) in flags { XCTAssertLessThanOrEqual(f, try XCTUnwrap(checks[k], k), k) }
        for k in checks.keys { XCTAssertTrue(AnalyticsStore.ruleKey(k), k) }
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: q).count, 32 * 1024)
    }

    /// share_asked, share_yes and share_no from the SDK's sheet and from the app's own UI; the settings switch is not
    /// a sheet answer.
    func testShareCountersFromTheSheetAndTheAppsOwnUI() async throws {
        let storage = Fixtures.storage()
        CloudFixtures.seedConfig(storage: storage)
        let o = CloudFixtures.options(contributions: true, storage: storage)
        let cloud = CloudFixtures.cloud(storage: storage, options: o)
        QuranLab.configure(key: CloudFixtures.key, options: o, cloud: cloud)
        func today() -> AnalyticsStore.Day { cloud.analytics.pending.last ?? AnalyticsStore.Day(day: "") }

        XCTAssertNotNil(Contributions.sessionCompleted(feedback: true))   // the SDK's sheet
        Contributions.answer(share: false)
        XCTAssertEqual([today().shareAsked, today().shareYes, today().shareNo], [1, 0, 1])

        let asked = Locked(0)
        Contributions.setPresenter { (_: SharingMoment) in asked.withLock { $0 += 1 } }   // the app's own UI
        XCTAssertNotNil(Contributions.askNow())
        try await waitUntil("the app's handler") { asked.withLock { $0 } == 1 }
        Contributions.answer(share: true)
        XCTAssertEqual([today().shareAsked, today().shareYes, today().shareNo], [2, 1, 1])

        await Contributions.setSharing(false)
        await Contributions.setSharing(true)
        XCTAssertEqual([today().shareAsked, today().shareYes, today().shareNo], [2, 1, 1], "the settings switch is not a sheet answer")
        XCTAssertTrue(Contributions.isActive)
    }

    // MARK: send points and answers

    /// The 15-minute timer while the app is in use, the background, and the return to the foreground (a launch).
    func testFifteenMinutesBackgroundAndForegroundSendPoints() async throws {
        StubProtocol.reset(CloudFixtures.server())
        let t0 = Date()
        let now = Locked(t0)
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage(), options: CloudFixtures.options(updates: .manual),
                                        clock: { now.withLock { $0 } })
        func events() -> [[String: Any]] { StubProtocol.seen("/v1/events").map { $0.json ?? [:] } }
        cloud.record(AnalyticsAndIssueTests.session(AnalyticsAndIssueTests.cpu, 60, [0.01]))
        now.withLock { $0 = t0.addingTimeInterval(14 * 60) }
        let early = await cloud.tick()
        XCTAssertFalse(early, "14 minutes: not yet")
        XCTAssertTrue(events().isEmpty)
        now.withLock { $0 = t0.addingTimeInterval(15 * 60) }
        let due = await cloud.tick()
        XCTAssertTrue(due, "15 minutes in use: a delta")
        XCTAssertEqual(events().count, 1)
        XCTAssertEqual(events().first.map { Self.sessions($0) }, 1)

        cloud.record(AnalyticsAndIssueTests.session(AnalyticsAndIssueTests.cpu, 30, [0.01]))
        now.withLock { $0 = t0.addingTimeInterval(17 * 60) }
        cloud.wentToBackground()
        try await waitUntil("the background delta") { events().count == 2 }
        XCTAssertEqual(Self.sessions(events()[1]), 1, "the background delta has what was counted since the last one")
        now.withLock { $0 = t0.addingTimeInterval(60 * 60) }
        let inBackground = await cloud.tick()
        XCTAssertFalse(inBackground, "no timer deltas in the background")

        cloud.cameToForeground()
        try await waitUntil("the foreground delta") { events().count == 3 }
        XCTAssertEqual(events()[2]["launches"] as? Int, 1, "a return to the foreground is a launch")
        XCTAssertEqual(Set(events().compactMap { $0["report_id"] as? String }).count, 3, "a fresh report id per delta")
    }

    /// A launch: counted, registered (once that day), and its delta sent at once.
    func testALaunchIsCountedAndSent() async throws {
        StubProtocol.reset(CloudFixtures.server())
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage(), options: CloudFixtures.options(updates: .manual))
        await cloud.launch()
        XCTAssertEqual(StubProtocol.seen("/v1/register").count, 1)
        let body = try XCTUnwrap(StubProtocol.seen("/v1/events").last?.json)
        XCTAssertEqual(body["launches"] as? Int, 1)
        XCTAssertEqual(body["sdk_version"] as? String, "2.0.1")
        XCTAssertEqual((body["report_id"] as? String)?.count, 32)
        XCTAssertEqual(body["cohorts"] as? [[String: AnyHashable]], [], "a delta with no session has no cohorts")
    }

    /// 503 (and the network) keeps the delta and its report id for the retry; 202 deletes it; 400 drops it and
    /// reports `bad_request:events`.
    func testA503KeepsTheSameReportIDA400Drops() async throws {
        let status = Locked(503)
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            s.path == "/v1/events" ? .json(["ok": status.withLock { $0 } == 202, "error": "x"], status: status.withLock { $0 }) : nil
        }))
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage(), options: CloudFixtures.options(updates: .manual))
        cloud.record(AnalyticsAndIssueTests.session(AnalyticsAndIssueTests.cpu, 60, [0.01]))
        await cloud.flush()
        let kept = try XCTUnwrap(cloud.analytics.sealed.first)
        XCTAssertEqual(cloud.analytics.sealed.count, 1, "503: kept")
        status.withLock { $0 = 202 }
        await cloud.flush()
        let seen = StubProtocol.seen("/v1/events")
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen[0].body, seen[1].body, "the retry is the same body")
        XCTAssertEqual(seen[1].json?["report_id"] as? String, kept.reportID)
        XCTAssertTrue(cloud.analytics.sealed.isEmpty, "202: deleted")

        status.withLock { $0 = 400 }
        cloud.record(AnalyticsAndIssueTests.session(AnalyticsAndIssueTests.cpu, 30, [0.01]))
        await cloud.flush()
        XCTAssertTrue(cloud.analytics.sealed.isEmpty, "400: dropped, never retried")
        try await waitUntil("the bad_request issue") {
            StubProtocol.seen("/v1/issues").contains { $0.json?["code"] as? String == "bad_request:events" }
                || cloud.issues.pending.contains { $0.code == "bad_request:events" }
        }
    }

    /// Registration once per UTC day: twice in one day is one call; the next day one more.
    func testRegisterOncePerUTCDay() async throws {
        StubProtocol.reset(CloudFixtures.server())
        let storage = CloudFixtures.storage()
        let now = Locked(Self.midnight.addingTimeInterval(3_600))
        let cloud = CloudFixtures.cloud(storage: storage, clock: { now.withLock { $0 } })
        let first = await cloud.register()
        let again = await cloud.register()
        XCTAssertTrue(first)
        XCTAssertFalse(again, "already registered today")
        let relaunch = CloudFixtures.cloud(storage: storage, clock: { now.withLock { $0 } })
        let sameDay = await relaunch.register()
        XCTAssertFalse(sameDay)
        XCTAssertEqual(StubProtocol.seen("/v1/register").count, 1)
        now.withLock { $0 = Self.midnight.addingTimeInterval(86_400 + 60) }
        let nextDay = await relaunch.register()
        XCTAssertTrue(nextDay)
        XCTAssertEqual(StubProtocol.seen("/v1/register").count, 2)
        XCTAssertEqual(StubProtocol.seen("/v1/register").last?.json?["new_install"] as? Bool, false)
    }
}
