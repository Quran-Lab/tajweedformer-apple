import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0's automatic counters of section D (17.8): learner, learner_gap and streak once per active day, take_s,
/// session_s, hour_speech_s, the metric switches; and 17.9's judged_tenure and weekly trend.
final class LearnerAnalyticsTests: XCTestCase {
    static let day1 = Date(timeIntervalSince1970: 1_789_948_800 + 12 * 3600)   // 2026-09-21 12:00 UTC, a Monday

    func store(_ now: Locked<Date>) -> AnalyticsStore {
        AnalyticsStore(storage: Fixtures.storage(), enabled: true,
                       context: .init(platform: "ios", sdkVersion: "4.0.0", appVersion: "1.0", deviceClass: "phone", soc: nil, osMajor: 18,
                                      ramTier: "4gb"),
                       clock: { now.withLock { $0 } })
    }

    func take(seconds: Double, hours: [Int: Int] = [:]) -> AnalyticsEvent {
        var t = SessionTelemetry(cohort: TelemetryCohort(revision: "4.1.0", build: "", context: "c16_l64", backend: "cpu"), audioSeconds: seconds,
                                 chunkSeconds: [0.01], chunkAudioSeconds: 0.32)
        t.count(audioMs: Int(seconds * 1000), selected: ["log_probs"], computeMicroseconds: 1000) { _ in [] }
        t.hourSpeechMs = hours
        return .sessionFinished(t)
    }

    /// A send point: the bodies sealed and sent now, oldest first (sent, so the next one has only what came after).
    func seal(_ a: AnalyticsStore) async -> [[String: Any]] {
        let sent = Locked<[Data]>([])
        _ = await a.flush(send: { (d: Data) async throws(CloudError) -> Void in sent.withLock { $0.append(d) } })
        return sent.withLock { $0 }.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    /// The one body a send point seals now.
    func firstBody(_ a: AnalyticsStore) async throws -> [String: Any] {
        let bodies = await seal(a)
        return try XCTUnwrap(bodies.first)
    }

    func testLearnerFactsOncePerActiveDay() async throws {
        let now = Locked(Self.day1)
        let a = store(now)
        a.record(take(seconds: 30))
        var b = try await firstBody(a)
        XCTAssertEqual(b["learner"] as? [String: Int], ["active": 1, "new": 1, "d1": 0, "d7": 0, "d30": 0])
        XCTAssertEqual(b["learner_gap"] as? [String: Int], ["new": 1])
        XCTAssertEqual(b["streak"] as? [String: Int], ["1": 1])
        // another take the same day: its delta carries no learner facts
        a.record(take(seconds: 30))
        b = try await firstBody(a)
        XCTAssertNil(b["learner"])
        XCTAssertNil(b["learner_gap"])
        // the next day: d1, a gap of 1, a streak of 2
        now.withLock { $0 = Self.day1.addingTimeInterval(86_400) }
        a.record(take(seconds: 30))
        b = try await firstBody(a)
        XCTAssertEqual(b["learner"] as? [String: Int], ["active": 1, "new": 0, "d1": 1, "d7": 0, "d30": 0])
        XCTAssertEqual(b["learner_gap"] as? [String: Int], ["1": 1])
        XCTAssertEqual(b["streak"] as? [String: Int], ["2_3": 1])
        // a week after the first day, after five days away: d7, a gap of 6, the streak starts again
        now.withLock { $0 = Self.day1.addingTimeInterval(7 * 86_400) }
        a.record(take(seconds: 30))
        b = try await firstBody(a)
        XCTAssertEqual(b["learner"] as? [String: Int], ["active": 1, "new": 0, "d1": 0, "d7": 1, "d30": 0])
        XCTAssertEqual(b["learner_gap"] as? [String: Int], ["6": 1])
        XCTAssertEqual(b["streak"] as? [String: Int], ["1": 1])
        // 40 days later: more than 30 days since the previous active day
        now.withLock { $0 = Self.day1.addingTimeInterval(47 * 86_400) }
        a.record(take(seconds: 30))
        b = try await firstBody(a)
        XCTAssertEqual(b["learner_gap"] as? [String: Int], ["gt_30": 1])
    }

    func testTakeSessionAndHourSeconds() throws {
        let now = Locked(Self.day1)
        let a = store(now)
        a.record(take(seconds: 90, hours: [9: 1200, 10: 400]))
        a.record(take(seconds: 30, hours: [10: 600]))
        a.closeSession()
        let p = a.payload(try XCTUnwrap(a.pending.first), reportID: AnalyticsStore.reportID())
        XCTAssertEqual((p["take_s"] as? [String: Int])?["le_120"], 1)
        XCTAssertEqual((p["take_s"] as? [String: Int])?["le_30"], 1)
        XCTAssertEqual((p["session_s"] as? [String: Int])?["le_300"], 1, "one session of 120 s")
        XCTAssertEqual(p["hour_speech_s"] as? [String: Double], ["9": 1.2, "10": 1.0])
        // the session's sets start again: an ayah counted before is not a repeat in the next session
        a.recitedBegan(1)
        a.count(take: 1, measured: CoreRecited(surah: 1, first: 1, last: 7, score: 9), report: nil, late: false)
        a.closeSession()
        a.recitedBegan(2)
        a.count(take: 2, measured: CoreRecited(surah: 1, first: 1, last: 7, score: 9), report: nil, late: false)
        XCTAssertEqual(a.pending.first?.v4?.repeatAyahs, 0)
    }

    func testAKilledSessionIsClosedAtTheNextStart() throws {
        let now = Locked(Self.day1)
        let storage = Fixtures.storage()
        let context = AnalyticsStore.Context(platform: "ios", sdkVersion: "4.0.0", appVersion: "1.0", deviceClass: "phone", soc: nil, osMajor: 18,
                                             ramTier: "4gb")
        let a = AnalyticsStore(storage: storage, enabled: true, context: context, clock: { now.withLock { $0 } })
        a.record(take(seconds: 700))
        a.waitForSave()
        let again = AnalyticsStore(storage: storage, enabled: true, context: context, clock: { now.withLock { $0 } })
        XCTAssertEqual((again.payload(try XCTUnwrap(again.pending.first), reportID: AnalyticsStore.reportID())["session_s"] as? [String: Int])?["le_1200"], 1)
    }

    func testTheMetricSwitches() async throws {
        let now = Locked(Self.day1)
        let a = store(now)
        a.metricsOff.withLock { $0 = ["juz", "learner", "lengths"] }
        a.record(take(seconds: 30))
        a.recitedBegan(1)
        a.count(take: 1, measured: CoreRecited(surah: 2, first: 255, last: 255, score: 9), report: nil, late: false)
        let b = try await firstBody(a)
        XCTAssertNil(b["juz_ayahs"])
        XCTAssertNil(b["learner"])
        XCTAssertNil(b["take_s"])
        XCTAssertEqual(b["ayahs"] as? Int, 1, "a switch turns off its group only")
        XCTAssertNotNil(b["recited_takes"])
    }

    func testTenureBoundaries() {
        var j = LearnerJournal()
        j.markActive(utc: "2026-09-21", local: "2026-09-21")
        for (n, want) in [(0, "w1"), (6, "w1"), (7, "w2_4"), (27, "w2_4"), (28, "m2_3"), (89, "m2_3"), (90, "later")] {
            XCTAssertEqual(j.tenure(on: DayMath.add("2026-09-21", n)!), want, "day \(n)")
        }
    }

    func testTheWeeklyTrend() {
        func journal(last: (Int, Int), prior: (Int, Int)) -> LearnerJournal {
            var j = LearnerJournal()
            j.weeks["2026-11-02"] = JudgedWeek(judged: last.0, correct: last.1)            // the week that ended
            j.weeks["2026-10-26"] = JudgedWeek(judged: prior.0, correct: prior.1)          // one of the four before
            return j
        }
        let sealing = "2026-11-10"   // a Tuesday: the week of 2026-11-02 ended
        var j = journal(last: (40, 36), prior: (40, 30))
        XCTAssertEqual(j.takeTrend(sealing: sealing), "better", "90 % against 75 %")
        XCTAssertNil(j.takeTrend(sealing: "2026-11-15"), "once per week")
        j = journal(last: (40, 30), prior: (40, 36))
        XCTAssertEqual(j.takeTrend(sealing: sealing), "worse")
        j = journal(last: (40, 31), prior: (40, 30))
        XCTAssertEqual(j.takeTrend(sealing: sealing), "same", "2.5 points")
        j = journal(last: (19, 19), prior: (40, 30))
        XCTAssertEqual(j.takeTrend(sealing: sealing), "not_enough")
        j = LearnerJournal()
        XCTAssertNil(j.takeTrend(sealing: sealing), "an install that judges nothing sends no trend")
        XCTAssertEqual(DayMath.monday("2026-11-14"), "2026-11-09")
        XCTAssertEqual(DayMath.monday("2026-11-16"), "2026-11-16")
        XCTAssertEqual(DayMath.monday("2026-11-15"), "2026-11-09")
    }

    func testJudgedTenureOnTheWire() throws {
        let now = Locked(Self.day1)
        let a = store(now)
        a.record(take(seconds: 30))
        a.count(take: nil, measured: nil, report: SessionShared.Recited(surah: 112, ayahFrom: 1, ayahTo: 4, outcome: .correct,
                                                                        perAyah: [2: .incorrect()]), late: false)
        let p = a.payload(try XCTUnwrap(a.pending.first), reportID: AnalyticsStore.reportID())
        XCTAssertEqual(p["judged_tenure"] as? [String: [String: Int]], ["w1": ["judged": 4, "correct": 3]])
        XCTAssertTrue((p["reported"] as? [String] ?? []).contains("judged_tenure"))
    }
}
