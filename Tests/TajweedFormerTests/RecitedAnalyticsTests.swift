import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0's recited counts as the day's delta carries them.
final class RecitedAnalyticsTests: XCTestCase {
    func store() -> AnalyticsStore {
        AnalyticsStore(storage: Fixtures.storage(), enabled: true,
                       context: .init(platform: "ios", sdkVersion: "4.0.0", appVersion: "1.0", deviceClass: "phone", soc: nil, osMajor: 18,
                                      ramTier: "4gb"))
    }

    func testAMeasuredTakeIsCountedOnceWithTheAppsOutcomesPairedToIt() throws {
        let a = store()
        a.recitedBegan(42)
        let report = SessionShared.Recited(surah: 2, ayahFrom: 255, ayahTo: 257, outcome: .incorrect(mistakes: 2, rules: ["madd"]),
                                           perAyah: [255: .correct])
        let measured = CoreRecited(surah: 2, first: 255, last: 257, score: 9)
        a.count(take: 42, measured: measured, report: report, late: false)
        a.count(take: 42, measured: measured, report: report, late: false)   // the same take again: nothing
        let d = try XCTUnwrap(a.pending.first)
        XCTAssertEqual(d.ayahs, 3, "measured")
        XCTAssertEqual(d.surahAyahs["2"], 3)
        let v = try XCTUnwrap(d.v4)
        XCTAssertEqual(v.recitedTakes, ["measured": 1])
        XCTAssertEqual(v.juzAyahs, ["3": 3], "2:255 to 2:257 are in juz 3 (from 2:253)")
        XCTAssertEqual(v.appAyahs, 0, "the app's report of a measured take adds no ayahs")
        XCTAssertEqual(v.judged["ayahs"], 3)
        XCTAssertEqual(v.judged["correct"], 1)
        XCTAssertEqual(v.judged["incorrect"], 2)
        XCTAssertEqual(v.judged["mistakes"], 2, "a range outcome's mistakes count once")
        XCTAssertEqual(v.judged["measured"], 3)
        XCTAssertEqual(v.judged["first"], 3)
        XCTAssertEqual(d.ruleChecks["madd"], 2, "each incorrect ayah's rule")
        XCTAssertEqual(d.ruleFlags["madd"], 2)
        XCTAssertTrue(a.pendingTakeIDs.isEmpty, "counted: no longer pending")
    }

    func testTheAppsReportCountsWhereTheDetectorCountedNothing() throws {
        let a = store()
        a.recitedBegan(7)
        a.count(take: 7, measured: nil, report: SessionShared.Recited(surah: 112, ayahFrom: 1, ayahTo: 4), late: false)
        a.recitedBegan(8)
        a.count(take: 8, measured: nil, report: nil, late: false)
        let v = try XCTUnwrap(a.pending.first?.v4)
        XCTAssertEqual(v.appAyahs, 4)
        XCTAssertEqual(v.appSurahAyahs, ["112": 4])
        XCTAssertEqual(v.recitedTakes, ["app": 1, "none": 1])
        XCTAssertEqual(a.pending.first?.ayahs, 0, "the measured count stays measured only")
        XCTAssertEqual(QuranParts.juz(surah: 112, ayah: 1), 30)
        XCTAssertEqual(QuranParts.juz(surah: 1, ayah: 7), 1)
        XCTAssertEqual(QuranParts.juz(surah: 2, ayah: 141), 1)
        XCTAssertEqual(QuranParts.juz(surah: 2, ayah: 142), 2)
    }

    func testARepeatInTheSameSessionAndARecoveredTake() throws {
        let a = store()
        a.recitedBegan(1)
        a.count(take: 1, measured: CoreRecited(surah: 1, first: 1, last: 7, score: 9), report: nil, late: false)
        a.recitedBegan(2)
        // a kill left take 2 pending; the next start finishes it in the Core and counts it as recovered
        XCTAssertEqual(a.pendingTakeIDs, [2])
        a.countRecovered(take: 2, measured: CoreRecited(surah: 1, first: 5, last: 7, score: 9))
        let v = try XCTUnwrap(a.pending.first?.v4)
        XCTAssertEqual(v.repeatAyahs, 3)
        XCTAssertEqual(v.recitedTakes, ["measured": 2, "recovered": 1])
    }

    /// 17.1: `ayahs` and `surah_ayahs` are measured and never listed in `reported`; the app's are `app_ayahs` and
    /// `app_surah_ayahs`; `coverage` is not sent.
    func testTheBodyAndItsReportedList() throws {
        let a = store()
        a.recitedBegan(1)
        a.count(take: 1, measured: CoreRecited(surah: 1, first: 1, last: 7, score: 9), report: nil, late: false)
        a.count(take: nil, measured: nil, report: SessionShared.Recited(surah: 112, ayahFrom: 1, ayahTo: 4, outcome: .correct), late: true)
        a.recordLease(.ok)
        a.recordLease(.offline)
        let p = a.payload(try XCTUnwrap(a.pending.first), reportID: "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(p["ayahs"] as? Int, 7)
        XCTAssertEqual(p["app_ayahs"] as? Int, 4)
        XCTAssertNil(p["coverage"])
        let reported = try XCTUnwrap(p["reported"] as? [String])
        XCTAssertFalse(reported.contains("ayahs"))
        XCTAssertFalse(reported.contains("surah_ayahs"))
        XCTAssertTrue(reported.contains("app_ayahs"))
        XCTAssertTrue(reported.contains("judged"))
        XCTAssertEqual((p["lease"] as? [String: Any])?["ok"] as? Int, 1)
        XCTAssertEqual(((p["lease"] as? [String: Any])?["failed"] as? [String: Int])?["offline"], 1)
    }

    func testTheOutcomeRules() {
        XCTAssertNoThrow(try TajweedRecitedOutcome.correct.check("o"))
        XCTAssertNoThrow(try TajweedRecitedOutcome.incorrect(mistakes: 1000, rules: ["madd", "qalqalah"]).check("o"))
        XCTAssertThrowsError(try TajweedRecitedOutcome.incorrect(mistakes: 0).check("o"))
        XCTAssertThrowsError(try TajweedRecitedOutcome.incorrect(mistakes: 1001).check("o"))
        XCTAssertThrowsError(try TajweedRecitedOutcome.incorrect(rules: ["Madd"]).check("o"))
        XCTAssertThrowsError(try TajweedRecitedOutcome.incorrect(rules: (0..<9).map { "r\($0)" }).check("o"))
    }
}
