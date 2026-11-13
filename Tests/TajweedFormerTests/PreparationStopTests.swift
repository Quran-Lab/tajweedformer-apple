import Foundation
import XCTest
@testable import TajweedFormer

/// A process that stops while the accelerator's build is being prepared (3.1.5; the `foreground` field of contract
/// 1.22.0, PLATFORM_CLIENT 7.1).
///
/// A stop at a stage where the model has not yet run on the accelerator (download, compile, warm-up) says nothing
/// about the build: it takes the normal retry budget (1 h, 6 h, 24 h), and a second stop at the same stage for the
/// same key ends the key. A stop at the golden test or the measurement stays deterministic and ends the key at once.
/// A stop while the app was not in the foreground is no failure at all: it counts nothing, the attempt resumes, and
/// the report says `foreground: false`. The first launch of 3.1.5 gives a key whose only failure was a stop at
/// download, compile or warm-up its retry back. Until 3.1.4 every stop ended the key for good.
///
/// The promotion pipeline's fakes (`PromotionTests.Harness`): no model, no CoreML, no Neural Engine. A stop is what a
/// launch finds on the device: the sentinel the pipeline writes around a stage, written here by the test in the form
/// the pipeline writes it.
final class PreparationStopTests: XCTestCase {
    var h = PromotionTests.Harness()

    override func setUp() {
        h = PromotionTests.Harness()
    }

    /// What a launch finds after a process stopped at `stage` of the attempt of `key`; `foreground` as the pipeline
    /// recorded it (nil: not recorded, as by 3.1.4).
    func stopped(_ c: AcceleratorController, at stage: PromotionStage, foreground: Bool?) throws {
        var r = c.store.record(c.key) ?? PromotionRecord(key: c.key)
        r.attempts += 1
        r.attemptStarted = h.now.withLock { $0 }
        r.launch = "L1"
        r.completed = stage == .download ? nil : PromotionStage.allCases[stage.order - 1]
        c.store.save(r)
        var o: [String: Any] = ["key": c.key, "stage": stage.rawValue]
        if let foreground { o["foreground"] = foreground }
        try FileManager.default.createDirectory(at: c.store.dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: o).write(to: c.store.sentinelURL)
    }

    /// The `detail` of the issue report of the last incident, as it is sent.
    func lastDetail() throws -> [String: Any] {
        let i = try XCTUnwrap(h.incidents.withLock { $0 }.last, "an incident was reported")
        let report = QuranLabCloud.incidentReport(i, app: CloudFixtures.app)
        let data = try JSONEncoder().encode(try XCTUnwrap(report.detail))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A stop in the foreground at download, compile or warm-up: the attempt ends with reason crash, the key waits
    /// 1 h (the first step of the retry budget), and is not ended. After the hour the pipeline runs again and
    /// promotes. The report names the stage and `crash_on_last_run`, with `foreground: true`.
    func testAStopAtPreparationInTheForegroundIsRetriedAfterTheBackoff() async throws {
        for (i, stage) in [PromotionStage.download, .compile, .warmup].enumerated() {
            h = PromotionTests.Harness()
            let c = h.controller(revision: "p\(i)")
            try stopped(c, at: stage, foreground: true)
            let next = h.controller(revision: "p\(i)", launch: "L2")
            let r = try XCTUnwrap(next.record, "\(stage)")
            XCTAssertEqual(r.lastReason, .crash, "\(stage)")
            XCTAssertEqual(r.lastStage, stage, "\(stage)")
            XCTAssertEqual(r.status, .retry, "\(stage): a stop before the model ran on the accelerator does not end the key")
            XCTAssertEqual(r.notBefore, h.now.withLock { $0 }.addingTimeInterval(3600), "\(stage): the first step of the retry budget")
            XCTAssertEqual(h.incidents.withLock { $0 }.last?.code, "\(stage.rawValue):crash_on_last_run", "\(stage)")
            XCTAssertEqual(try lastDetail()["foreground"] as? Bool, true, "\(stage): the report says the app was in the foreground")
            // after the hour
            h.advance(3601)
            let later = h.controller(revision: "p\(i)", launch: "L3")
            await later.run(h.stages())
            XCTAssertEqual(later.state, .ready, "\(stage): the next attempt promotes")
        }
    }

    /// A second stop at the same stage for the same key ends the key, as a deterministic failure does. A stop at
    /// another stage after it is retried (the next step of the budget, 6 h).
    func testASecondStopAtTheSameStageEndsTheKey() async throws {
        let c = h.controller(revision: "s1")
        try stopped(c, at: .compile, foreground: true)
        _ = h.controller(revision: "s1", launch: "L2")
        h.advance(3601)
        try stopped(c, at: .compile, foreground: true)
        let second = h.controller(revision: "s1", launch: "L3")
        XCTAssertEqual(second.record?.status, .failed, "a second stop at the compile ends the key")
        guard case .disabled = second.state else { return XCTFail("\(second.state)") }

        h = PromotionTests.Harness()
        let d = h.controller(revision: "s2")
        try stopped(d, at: .compile, foreground: true)
        _ = h.controller(revision: "s2", launch: "L2")
        h.advance(3601)
        try stopped(d, at: .warmup, foreground: true)
        let other = h.controller(revision: "s2", launch: "L3")
        XCTAssertEqual(other.record?.status, .retry, "a stop at another stage is the next failure of the budget")
        XCTAssertEqual(other.record?.notBefore, h.now.withLock { $0 }.addingTimeInterval(6 * 3600))
    }

    /// A stop at the golden test or the measurement ends the key at once, as before.
    func testAStopAtGoldenOrMeasureEndsTheKeyAtOnce() async throws {
        for (i, stage) in [PromotionStage.golden, .measure].enumerated() {
            h = PromotionTests.Harness()
            let c = h.controller(revision: "g\(i)")
            try stopped(c, at: stage, foreground: true)
            let next = h.controller(revision: "g\(i)", launch: "L2")
            XCTAssertEqual(next.record?.status, .failed, "\(stage)")
            XCTAssertEqual(next.record?.lastReason, .crash, "\(stage)")
        }
    }

    /// A stop while the app was not in the foreground (the pipeline recorded `foreground: false` with the stage)
    /// counts nothing: no failure, no wait, the attempt resumes where it was at the next run, and the report says
    /// `foreground: false`.
    func testAStopInTheBackgroundCountsNothing() async throws {
        for (i, stage) in [PromotionStage.compile, .warmup].enumerated() {
            h = PromotionTests.Harness()
            let c = h.controller(revision: "b\(i)")
            try stopped(c, at: stage, foreground: false)
            let next = h.controller(revision: "b\(i)", launch: "L2")
            let r = try XCTUnwrap(next.record, "\(stage)")
            XCTAssertEqual(r.failures, 0, "\(stage): no failure is counted")
            XCTAssertNotEqual(r.status, .failed, "\(stage)")
            XCTAssertNotEqual(r.status, .retry, "\(stage): no wait")
            XCTAssertNil(r.notBefore, "\(stage)")
            XCTAssertEqual(h.incidents.withLock { $0 }.last?.code, "\(stage.rawValue):crash_on_last_run", "\(stage): it is reported")
            XCTAssertEqual(try lastDetail()["foreground"] as? Bool, false, "\(stage): with foreground false")
            await next.run(h.stages())
            XCTAssertEqual(next.state, .ready, "\(stage): the attempt goes on and promotes")
        }
    }

    /// The first launch of 3.1.5: a key whose only failure was a stop at download, compile or warm-up gets its retry
    /// back, and promotes. A key ended by a stop at the golden test, or by a stop after another failure, stays ended.
    func testTheFirstLaunchOf315GivesAStopAtPreparationItsRetryBack() async throws {
        // the records as an earlier version left them, written to the store before any controller of this version
        // is made (a controller's start is the first launch, which runs the migration once)
        let store = PromotionStore(dir: h.storage)
        func ended(_ revision: String, stage: PromotionStage, failures: Int) {
            var r = PromotionRecord(key: AcceleratorController.key(revision: revision, context: "c16_l64", build: "coreml",
                                                                  osBuild: "23A100", deviceModel: "iPhone17,1"))
            r.status = .failed
            r.attempts = failures
            r.failures = failures
            r.lastStage = stage
            r.lastReason = .crash
            r.lastDetail = "\(stage.rawValue): the app stopped during the \(stage.rawValue) stage"
            store.save(r)
        }
        ended("m1", stage: .compile, failures: 1)
        ended("m2", stage: .golden, failures: 1)
        ended("m3", stage: .compile, failures: 2)
        // the first launch of 3.1.5
        let first = h.controller(revision: "m1", launch: "L9")
        XCTAssertNotNil(first.record, "the record the test wrote is the key's")
        XCTAssertEqual(first.record?.status, .retry, "the stop at the compile gets its retry back")
        await first.run(h.stages())
        XCTAssertEqual(first.state, .ready, "and it promotes")
        XCTAssertEqual(h.controller(revision: "m2", launch: "L9").record?.status, .failed, "a stop at the golden test stays ended")
        XCTAssertEqual(h.controller(revision: "m3", launch: "L9").record?.status, .failed, "a stop after another failure stays ended")
    }

    // The tests below use what 3.1.5 adds (the decisions taken after the first red run): they were not run on the
    // code of 3.1.4.

    /// A stop in the background at the golden test counts nothing either: the rule of the background holds at every
    /// stage (a stop in the foreground there ends the key at once).
    func testAStopInTheBackgroundAtTheGoldenTestCountsNothing() async throws {
        let c = h.controller(revision: "bg")
        try stopped(c, at: .golden, foreground: false)
        let next = h.controller(revision: "bg", launch: "L2")
        let r = try XCTUnwrap(next.record)
        XCTAssertEqual(r.failures, 0)
        XCTAssertNotEqual(r.status, .failed)
        XCTAssertEqual(try lastDetail()["foreground"] as? Bool, false)
        await next.run(h.stages())
        XCTAssertEqual(next.state, .ready, "the attempt goes on and promotes")
    }

    /// Background stops in a row at the same stage: the first two count nothing; the third counts as a stop in the
    /// foreground (the retry budget, reported with `foreground: false` as it was); the next one in the same row is
    /// the second counted stop at the stage and ends the key.
    func testTheThirdBackgroundStopInARowCountsAsAStopInTheForeground() async throws {
        XCTAssertEqual(PromotionPolicy.backgroundStopsCountedFrom, 3)
        let c = h.controller(revision: "row")
        for launch in ["L2", "L3"] {
            try stopped(c, at: .compile, foreground: false)
            let next = h.controller(revision: "row", launch: launch)
            XCTAssertEqual(next.record?.failures, 0, "\(launch): nothing counted")
        }
        try stopped(c, at: .compile, foreground: false)
        let third = h.controller(revision: "row", launch: "L4")
        XCTAssertEqual(third.record?.failures, 1, "the third in a row is counted")
        XCTAssertEqual(third.record?.status, .retry, "with the retry budget")
        XCTAssertEqual(third.record?.notBefore, h.now.withLock { $0 }.addingTimeInterval(3600))
        XCTAssertEqual(try lastDetail()["foreground"] as? Bool, false, "and reported as it was")
        h.advance(3601)
        try stopped(c, at: .compile, foreground: false)
        let fourth = h.controller(revision: "row", launch: "L5")
        XCTAssertEqual(fourth.record?.status, .failed, "the next one ends the key")
    }

    /// A row ends when the stage completes: two background stops at the compile, then a compile that completes, then
    /// two more background stops there count nothing.
    func testARowOfBackgroundStopsEndsWhenTheStageCompletes() async throws {
        let c = h.controller(revision: "ends")
        for launch in ["L2", "L3"] {
            try stopped(c, at: .compile, foreground: false)
            _ = h.controller(revision: "ends", launch: launch)
        }
        // the compile completes, the warm-up fails (no failure of the compile's row)
        h.failures.withLock { $0[.warmup] = PromotionFailure(.loadError, "injected") }
        let through = h.controller(revision: "ends", launch: "L4")
        await through.run(h.stages())
        XCTAssertEqual(through.record?.failures, 1)
        h.failures.withLock { $0 = [:] }
        h.advance(3601)
        for launch in ["L5", "L6"] {
            try stopped(c, at: .compile, foreground: false)
            let next = h.controller(revision: "ends", launch: launch)
            XCTAssertEqual(next.record?.failures, 1, "\(launch): a new row counts nothing")
        }
    }

    /// The pipeline records the foreground with the stage, and a change while the stage runs: the sentinel of the
    /// compile says what the app was when the compile began, and the app going to the background makes it say so.
    func testThePipelineRecordsTheForegroundWithTheStage() async throws {
        let foreground = Locked<Bool?>(true)
        var e = h.env(revision: "fg")
        e.foreground = { foreground.withLock { $0 } }
        let c = AcceleratorController(e)
        let seen = Locked<[Bool?]>([])
        let store = c.store
        var stages = h.stages()
        let compile = stages.compile
        stages.compile = { () async throws(PromotionFailure) -> UncheckedBox<any AcceleratorBackend> in
            seen.withLock { $0.append(store.sentinel()?.foreground) }
            foreground.withLock { $0 = false }
            c.presenceChanged()
            seen.withLock { $0.append(store.sentinel()?.foreground) }
            return try await compile()
        }
        await c.run(stages)
        XCTAssertEqual(seen.withLock { $0 }, [true, false], "the sentinel says the foreground, and follows the app")
    }
}
