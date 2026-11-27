import Foundation
import QuranLabCore
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5: an accelerator prepare that meets a Core busy with something else (another model open that a take holds,
/// a model the Core would not close in time, a program being prepared) is not a failure of the build. Apple 4.0.1 and
/// 4.0.2 counted it as a `compile_error` against the retry budget and reported it: 23 of the 4.0.x compile failures of
/// the 7 days to 2026-11-25 read "engine failed (-11): qlc_model_open: a model of this Core is open". On the
/// promotion's fakes (`PromotionTests.Harness`). Not compiled or run on 11-25 (no Mac).
final class BusyCoreTests: XCTestCase {
    var h = PromotionTests.Harness()

    override func setUp() {
        h = PromotionTests.Harness()
    }

    func testABusyCoreIsMarkedNotNow() {
        let busy = CoreFailure(Int32(QLC_E_BUSY), call: "qlc_model_open").recognizerError
        XCTAssertTrue(TajweedRecognizer.prepareFailure(busy).notNow, "\(busy)")
        XCTAssertTrue(TajweedRecognizer.prepareFailure(.sessionActive).notNow)
        XCTAssertTrue(TajweedRecognizer.prepareFailure(CoreFailure(Int32(QLC_E_BUSY), call: "qlc_accel_prepare").recognizerError).notNow)
        // the build's own failures stay failures
        XCTAssertFalse(TajweedRecognizer.prepareFailure(.neuralEngineUnavailable("the accelerator program was not prepared (accel_program)")).notNow)
        XCTAssertFalse(TajweedRecognizer.prepareFailure(.engineFailed(code: Int(QLC_E_NOMEM), message: "not enough memory")).notNow)
        XCTAssertFalse(LeaseNoAccelTests.coreRefusal.notNow)
    }

    /// A busy Core at the compile: nothing counted, reported or recorded as a failure, the CPU engine meanwhile; the
    /// next run of the same launch goes on with the same attempt and promotes.
    func testABusyCompileCountsNothingAndTheNextRunGoesOn() async {
        var f = PromotionFailure(.compileError, "engine failed (-11): qlc_model_open: a model of this Core is open")
        f.notNow = true
        h.failures.withLock { $0[.compile] = f }
        let c = h.controller(revision: "busy")
        await c.run(h.stages())
        XCTAssertEqual(c.state, .cpu)
        let r = c.record
        XCTAssertEqual(r?.failures, 0)
        XCTAssertNil(r?.lastReason)
        XCTAssertNil(r?.notBefore, "no backoff")
        XCTAssertEqual(r?.completed, .download, "the attempt stays where it stood")
        XCTAssertTrue(h.incidents.withLock { $0 }.isEmpty, "nothing reported")
        XCTAssertTrue(h.promotions.isEmpty, "no attempt ended in the telemetry")
        h.failures.withLock { $0 = [:] }
        h.resetCalls()
        await c.run(h.stages())
        XCTAssertEqual(c.state, .ready)
        XCTAssertEqual(h.calls.withLock { $0 }.first, "compile", "it goes on at the compile, not from the download")
        XCTAssertEqual(c.record?.attempts, 1, "the same attempt")
    }

    /// A promoted key whose load meets a busy Core stays promoted and loads at the next run.
    func testABusyReloadKeepsThePromotion() async {
        let c = h.controller(revision: "kept")
        await c.run(h.stages())
        XCTAssertEqual(c.state, .ready)
        var f = PromotionFailure(.compileError, "qlc_model_open: a model of this Core is open")
        f.notNow = true
        h.failures.withLock { $0[.compile] = f }
        let next = h.controller(revision: "kept", launch: "L2")
        await next.run(h.stages())
        XCTAssertEqual(next.record?.status, .ready, "still promoted")
        XCTAssertEqual(next.state, .cpu)
        h.failures.withLock { $0 = [:] }
        await next.run(h.stages())
        XCTAssertEqual(next.state, .ready)
    }
}
