import Foundation
import QuranLabCore
import XCTest
@testable import TajweedFormer

/// The calls the Core gained between 932f419 and 4a5663c, as the SDK uses them: the named detail codes, the
/// resampler and top-K (R8), the learner's days (R10), the recited result's fields (R5), the accelerator's lease check
/// (R2). The parts that need no Core state run on any Core; the rest on the test release (ProtectedCoreTests).
final class CoreCallsTests: XCTestCase {
    // MARK: named detail codes

    func testTheNamedDetailCodesDecideTheErrors() {
        guard case .neuralEngineUnavailable = CoreFailure(status: QLC_E_LEASE, detail: QLC_D_LEASE_NO_ACCEL, call: "qlc_accel_prepare").recognizerError else {
            return XCTFail("a lease without the accelerator flag leaves the device on the CPU engine")
        }
        guard case .offline = CoreFailure(status: QLC_E_LEASE, detail: QLC_D_LEASE_EXPIRED, call: "qlc_model_open").recognizerError else {
            return XCTFail("an expired lease needs a connection")
        }
        guard case .neuralEngineUnavailable(let why) = CoreFailure(status: QLC_E_ENGINE, detail: QLC_D_ACCEL_PROGRAM, call: "qlc_accel_prepare").recognizerError else {
            return XCTFail("a program the runtime refused")
        }
        XCTAssertTrue(why.contains("accel_program"))
        XCTAssertTrue(CoreFailure(status: QLC_E_FILE, detail: QLC_D_FILE_PLAIN_SHA256, call: "qlc_install").isPlaintextMismatch)
        XCTAssertTrue(CoreFailure(status: QLC_E_BUSY, detail: 0, call: "qlc_install").isBusy)
        XCTAssertEqual(ProtectedRuntime.leaseExpiredDetail, 8)
    }

    // MARK: R8, the resampler and top-K from the Core

    /// Any chunking gives the same samples as one call, and n samples give ceil(n * 16000 / rate) in all.
    func testTheCoresResamplerIsTheSameHoweverTheAudioIsSplit() throws {
        let input = (0..<4410).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        let one = try SampleRateConverter(inputRate: 44_100)
        let whole = one.process(input) + one.flush()
        let pieces = try SampleRateConverter(inputRate: 44_100)
        var split: [Float] = []
        for c in stride(from: 0, to: input.count, by: 333) { split += pieces.process(Array(input[c..<min(input.count, c + 333)])) }
        split += pieces.flush()
        XCTAssertEqual(whole, split)
        XCTAssertEqual(whole.count, Int((Double(input.count) * 16_000 / 44_100).rounded(.up)))
        let same = try SampleRateConverter(inputRate: 16_000)
        XCTAssertEqual(same.process(input), input)
    }

    /// Top-2 of a frame: highest first, ties to the lower id, the margin the top-1 less the runner-up.
    func testTheTop2IsTheCoresTopK() {
        var lp = [Float](repeating: -9, count: 2 * HeadsBuffer.vocab)
        lp[3] = -0.5; lp[7] = -0.5; lp[9] = -2
        lp[HeadsBuffer.vocab + 1] = -0.1; lp[HeadsBuffer.vocab + 2] = -1.6
        let f = DecodedTake.top2(lp, frames: 2)
        XCTAssertEqual(f.count, 2)
        XCTAssertEqual(f[0].top1, 3, "a tie goes to the lower id")
        XCTAssertEqual(f[0].runnerUp, 7)
        XCTAssertEqual(f[0].margin, 0)
        XCTAssertEqual(f[1].top1, 1)
        XCTAssertEqual(f[1].runnerUp, 2)
        XCTAssertEqual(f[1].margin, 1.5, accuracy: 1e-6)
    }

    // MARK: R10, the learner's days

    func testDayNumbersAreTheCoresDays() {
        XCTAssertEqual(DayMath.number("1970-01-01"), 0)
        XCTAssertEqual(DayMath.number("2026-09-21"), 20_717)
        XCTAssertEqual(DayMath.string(number: 20_717), "2026-09-21")
        var d = CoreDays()
        d.firstDay = 20_717
        d.active = [20_717, 20_718]
        d.local = [20_717, 20_718]
        d.streaks = [20_718: 2]
        d.sealed = [20_717]
        d.weeks = [20_717: (judged: 3, correct: 2)]
        d.trendWeek = -1
        let j = LearnerJournal(core: d)
        XCTAssertEqual(j.firstDay, "2026-09-21")
        XCTAssertEqual(j.activeDays, ["2026-09-21", "2026-09-22"])
        XCTAssertEqual(j.streaks, ["2026-09-22": 2])
        XCTAssertEqual(j.sentDays, ["2026-09-21"])
        XCTAssertEqual(j.weeks["2026-09-21"], JudgedWeek(judged: 3, correct: 2))
        XCTAssertNil(j.trendWeek)
    }

    /// The Core's journal as the analytics see it: each change after the state that counts it is saved; the facts the
    /// same as with the state's own days.
    final class FakeDays: LearnerDaysSource, @unchecked Sendable {
        let journal = Locked(LearnerJournal())
        let ops = Locked<[String]>([])
        func read() -> LearnerJournal? { journal.withLock { $0 } }
        func mark(utc: String, local: String) {
            ops.withLock { $0.append("mark \(utc)") }
            journal.withLock { $0.markActive(utc: utc, local: local) }
        }
        func judged(utc: String, judged: Int, correct: Int) {
            ops.withLock { $0.append("judged \(utc) \(judged) \(correct)") }
            journal.withLock { j in
                for i in 0..<judged { j.judged(on: utc, correct: i < correct) }
            }
        }
        func seal(utc: String) {
            ops.withLock { $0.append("seal \(utc)") }
            journal.withLock { $0.sentDays = LearnerJournal.recent($0.sentDays + [utc], keep: 10) }
        }
        func trendSent(week: String) {
            ops.withLock { $0.append("trend \(week)") }
            journal.withLock { $0.trendWeek = week }
        }
    }

    /// The one body a send point seals now.
    func firstBody(_ a: AnalyticsStore) async throws -> [String: Any] {
        let sent = Locked<[Data]>([])
        _ = await a.flush(send: { (d: Data) async throws(CloudError) -> Void in sent.withLock { $0.append(d) } })
        return try XCTUnwrap(sent.withLock { $0 }.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }.first)
    }

    func testTheLearnerDaysGoToTheCoresJournal() async throws {
        let now = Locked(LearnerAnalyticsTests.day1)
        let a = AnalyticsStore(storage: Fixtures.storage(), enabled: true,
                               context: .init(platform: "ios", sdkVersion: "4.0.0", appVersion: "1.0", deviceClass: "phone", soc: nil,
                                              osMajor: 18, ramTier: "4gb"),
                               clock: { now.withLock { $0 } })
        let days = FakeDays()
        a.learnerDays.withLock { $0 = days }
        var t = SessionTelemetry(cohort: TelemetryCohort(revision: "4.1.0", build: "", context: "c16_l64", backend: "cpu"), audioSeconds: 30,
                                 chunkSeconds: [0.01], chunkAudioSeconds: 0.32)
        t.count(audioMs: 30_000, selected: ["log_probs"], computeMicroseconds: 1000) { _ in [] }
        a.record(.sessionFinished(t))
        var b = try await firstBody(a)
        XCTAssertEqual(b["learner"] as? [String: Int], ["active": 1, "new": 1, "d1": 0, "d7": 0, "d30": 0])
        XCTAssertEqual(b["streak"] as? [String: Int], ["1": 1])
        XCTAssertNil(a.stateSnapshot.learner, "the days are the Core's, not the state's")
        XCTAssertEqual(days.ops.withLock { $0 }, ["mark 2026-09-21", "seal 2026-09-21"])
        // a judged ayah counts into the Core's week once the count is saved
        a.recitedBegan(1)
        a.count(take: 1, measured: CoreRecited(surah: 1, first: 1, last: 1, score: 9, context: true),
                report: SessionShared.Recited(surah: 1, ayahFrom: 1, ayahTo: 1, outcome: .correct, perAyah: [:]), late: false)
        XCTAssertEqual(days.ops.withLock { $0 }.last, "judged 2026-09-21 1 1")
        b = try await firstBody(a)
        XCTAssertEqual((b["recited_takes"] as? [String: Int])?["context"], 1, "R5: a take the session context decided")
    }
}

extension ProtectedCoreTests {
    /// R2: the lease decides whether the accelerator build is downloaded at all (`qlc_accel_allowed`): unknown before a
    /// lease, 1 or 0 once one is held.
    func testTheAcceleratorIsAskedOfTheLease() async throws {
        let s = try prepare()
        _ = try await s.runtime.certificate()
        if CoreOptional.hasAccelerator { XCTAssertNil(s.runtime.acceleratorAllowed(), "no lease yet") }
        _ = try await s.runtime.ensureLease(s.manifest)
        if CoreOptional.hasAccelerator { XCTAssertNotNil(s.runtime.acceleratorAllowed(), "the lease in force answers") }
        #if targetEnvironment(simulator)
        XCTAssertFalse(AcceleratorGate.available, "never on the Simulator")
        #endif
    }

    /// R5, R10 on the test Core: the journal answers with no finished take, and the learner's days go in and come back.
    func testTheJournalHoldsTheLearnersDays() async throws {
        let s = try prepare()
        _ = try await s.runtime.certificate()
        let host = try XCTUnwrap(try s.runtime.host())
        XCTAssertEqual(host.recitedDone().count, 0)
        XCTAssertTrue(host.daysMark(utc: 20_717, local: 20_717))
        XCTAssertTrue(host.daysMark(utc: 20_718, local: 20_718))
        XCTAssertTrue(host.daysJudged(utc: 20_718, judged: 5, correct: 4))
        let d = try XCTUnwrap(host.daysRead())
        XCTAssertEqual(d.firstDay, 20_717)
        XCTAssertEqual(d.active, [20_717, 20_718])
        XCTAssertEqual(d.streaks[20_718], 2)
        XCTAssertEqual(d.weeks.values.map(\.judged).reduce(0, +), 5)
        let j = LearnerJournal(core: d)
        XCTAssertEqual(j.streak(endingAt: "2026-09-22"), 2)
    }
}
