import Foundation
import QuranLabCore
import XCTest
@testable import TajweedFormer

/// Contract 21.6 (`sdk_4.0.0/ACCEL_40.md`, SDK 4.0.2): a lease in force that does not allow accelerator programs
/// (`qlc_accel_allowed` 0, or the Core's `QLC_E_LEASE` with `QLC_D_LEASE_NO_ACCEL` at a prepare or a load) is not a
/// failure. The promotion takes the deny list's path: no attempt starts or goes on, the CPU engine runs, nothing is
/// counted (no failure, no backoff, no `failed`, no incident, no new reason), and the key goes on from where it stood
/// under a lease that allows programs. Apple 4.0.1 threw it as a `denylist` failure of the download stage, so after the
/// backoff list the key was `failed`, also once a later lease allowed programs. On the promotion's fakes
/// (`PromotionTests.Harness`).
final class LeaseNoAccelTests: XCTestCase {
    var h = PromotionTests.Harness()

    override func setUp() {
        h = PromotionTests.Harness()
    }

    /// What the Core's refusal of a prepare or a load for the lease becomes in the pipeline (`prepareFailure`).
    static var coreRefusal: PromotionFailure {
        TajweedRecognizer.prepareFailure(CoreFailure(Int32(QLC_E_LEASE), detail: Int32(QLC_D_LEASE_NO_ACCEL), call: "qlc_accel_prepare").recognizerError)
    }

    func testTheCoresRefusalIsMarkedAsTheLeasesNotAsAFailure() {
        let f = Self.coreRefusal
        XCTAssertTrue(f.leaseNoAccel, f.detail)
        XCTAssertFalse(TajweedRecognizer.prepareFailure(.neuralEngineUnavailable("the accelerator program was not prepared (accel_program)")).leaseNoAccel)
        XCTAssertFalse(TajweedRecognizer.prepareFailure(.offline("x")).leaseNoAccel)
    }

    /// 21.6 item 5: a lease without bit 3, then a lease with it. The first gives no failure, no backoff, no incident
    /// and the CPU engine (its demotion recorded once, `not_attested` since the server takes the 19th reason, 21.2);
    /// the second runs the attempt to the promotion.
    func testALeaseWithoutProgramsThenALeaseWithThem() async {
        h.leaseAllows.withLock { $0 = false }
        let c = h.controller()
        await c.run(h.stages())
        XCTAssertEqual(h.calls.withLock { $0 }, [], "no download, compile, golden test or load")
        guard case .disabled(let why) = c.state else { return XCTFail("\(c.state)") }
        XCTAssertTrue(why.hasPrefix("lease_no_accel"), why)
        var r = c.record
        XCTAssertEqual(r?.status, .pending)
        XCTAssertEqual(r?.failures, 0)
        XCTAssertNil(r?.notBefore)
        XCTAssertEqual(r?.attempts, 0, "no attempt started")
        XCTAssertEqual(r?.denied, true)
        XCTAssertEqual(r?.lastReason, .notAttested)
        XCTAssertEqual(h.incidents.withLock { $0 }.count, 0)
        XCTAssertEqual(h.promotions.map { $0.kind }, [.demoted(.notAttested)], "its demotion, once")
        await c.run(h.stages())
        XCTAssertEqual(h.promotions.count, 1, "once while the state holds")
        // a lease that allows programs: the attempt runs (this launch, the key never tried)
        h.leaseAllows.withLock { $0 = true }
        await c.run(h.stages())
        XCTAssertEqual(c.state, .ready)
        XCTAssertEqual(h.calls.withLock { $0 }, ["download", "compile", "warmup", "golden"])
        r = c.record
        XCTAssertEqual(r?.status, .ready)
        XCTAssertEqual(r?.attempts, 1)
        XCTAssertEqual(r?.failures, 0)
        XCTAssertEqual(r?.denied, false)
    }

    /// 21.6 item 5: the same refusal ten times in a row never makes the key `failed`, whether the controller asked the
    /// lease first or the Core refused the compile in the middle of an attempt; the attempt then goes on where it stood
    /// once a lease allows programs.
    func testTheSameRefusalTenTimesNeverEndsTheKey() async {
        h.leaseAllows.withLock { $0 = false }
        let c = h.controller()
        for _ in 0..<10 {
            await c.run(h.stages())
            h.advance(30 * 86_400)
        }
        XCTAssertEqual(c.record?.status, .pending)
        XCTAssertEqual(c.record?.failures, 0)
        XCTAssertEqual(h.count("download"), 0)
        // the Core's refusal at the compile (the lease changed after the controller asked): ten launches in a row
        let k = h.controller(revision: "r-core")
        h.leaseAllows.withLock { $0 = nil }
        h.failures.withLock { $0[.compile] = Self.coreRefusal }
        for i in 0..<10 {
            let c2 = h.controller(revision: "r-core", launch: "L\(i)")
            await c2.run(h.stages())
            h.advance(30 * 86_400)
        }
        let r = k.record
        XCTAssertEqual(r?.status, .pending, "never failed, never retry")
        XCTAssertEqual(r?.failures, 0)
        XCTAssertNil(r?.notBefore)
        XCTAssertEqual(r?.attempts, 1, "one attempt, held at its compile, never counted")
        XCTAssertEqual(r?.completed, .download, "it stands after its download")
        XCTAssertEqual(h.count("download"), 1, "the build is not downloaded again")
        XCTAssertEqual(h.incidents.withLock { $0 }.count, 0)
        // a lease with programs: the attempt goes on from its compile
        h.failures.withLock { $0[.compile] = nil }
        h.resetCalls()
        let c3 = h.controller(revision: "r-core", launch: "L10")
        await c3.run(h.stages())
        XCTAssertEqual(c3.state, .ready)
        XCTAssertEqual(h.calls.withLock { $0 }, ["compile", "warmup", "golden"])
        XCTAssertEqual(c3.record?.attempts, 1)
    }

    /// 21.6 item 3: a promoted key whose load the Core refuses for the lease stays promoted; the session runs on the
    /// CPU, and the build loads again (no golden test) under a lease that allows programs.
    func testAPromotedKeyWhoseLoadTheCoreRefusesStaysPromoted() async {
        let c = h.controller()
        await c.run(h.stages())
        XCTAssertEqual(c.record?.status, .ready)
        // the next launch: the reload is refused for the lease
        h.failures.withLock { $0[.compile] = Self.coreRefusal }
        h.resetCalls()
        let next = h.controller(launch: "L2")
        await next.run(h.stages())
        XCTAssertEqual(h.calls.withLock { $0 }, ["compile"], "the load was tried and refused")
        XCTAssertEqual(next.record?.status, .ready, "still promoted")
        XCTAssertEqual(next.record?.failures, 0)
        XCTAssertNil(next.record?.backoffUntil)
        XCTAssertNil(next.leaseForSession(), "this session runs on the CPU")
        XCTAssertEqual(h.incidents.withLock { $0 }.count, 0)
        // a refused load for the lease is that lease's demotion (`not_attested` since 21.2's switch is on), never a failure's
        XCTAssertFalse(h.promotions.contains { if case .demoted(let r) = $0.kind { return r != .denylist && r != .notAttested } else { return false } })
        // a lease that allows programs (the Core accepted one): the build loads again, no golden test
        h.failures.withLock { $0[.compile] = nil }
        h.resetCalls()
        await next.run(h.stages())
        XCTAssertEqual(next.state, .ready)
        XCTAssertEqual(h.calls.withLock { $0 }, ["compile", "warmup"])
        XCTAssertNotNil(next.leaseForSession())
        // and the lease asked before a session: a lease without programs keeps that session on the CPU, still promoted
        next.endLease()
        h.leaseAllows.withLock { $0 = false }
        XCTAssertNil(next.leaseForSession())
        XCTAssertEqual(next.record?.status, .ready)
    }

    /// 21.6 item 2: every lease the Core accepts tells the recognizers that watch it (`AcceleratorRegistry`), each
    /// asking the lease again; a recognizer gone is no longer told.
    func testEveryLeaseTheCoreAcceptsIsToldToTheWatchers() async throws {
        let id = UUID()
        let told = Locked(0)
        AcceleratorRegistry.watchLease(id) { told.withLock { $0 += 1 } }
        AcceleratorRegistry.leaseAccepted()
        AcceleratorRegistry.leaseAccepted()
        let end = Date().addingTimeInterval(5)
        while told.withLock({ $0 }) < 2, Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(told.withLock { $0 }, 2)
        AcceleratorRegistry.remove(id)
        AcceleratorRegistry.leaseAccepted()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(told.withLock { $0 }, 2)
    }

    /// 21.6 item 4: at the first start of 4.0.2 the records 4.0.1 wrote for this refusal (in its on-disk format, the
    /// fixture `promotion401/promotions.json`: `lastReason` `denylist`, `lastDetail` "download: lease_no_accel: ...", one
    /// in `retry` with `notBefore`, one `failed` after four) go back to `pending`, their count, backoff and `failed`
    /// state cleared; a key ended by a golden mismatch, one the config's deny list holds and one waiting after a
    /// network stop keep their verdicts. Once per store.
    func testThe401RecordsOfThisRefusalGoBackToPending() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "promotion401", withExtension: nil, subdirectory: "Fixtures"))
        let store = PromotionStore(dir: h.storage)
        try FileManager.default.createDirectory(at: h.storage, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.appendingPathComponent("promotions.json"), to: store.recordsURL)
        let before = store.all()
        XCTAssertEqual(before.count, 5, "the 4.0.1 file reads")
        let k = { (r: String) in "\(r)|c16_l64|coreml|23A100|iPhone17,1" }
        XCTAssertEqual(before[k("r1")]?.status, .retry)
        XCTAssertNotNil(before[k("r1")]?.notBefore)
        XCTAssertEqual(before[k("r2")]?.status, .failed)
        // the first controller of the start runs the migration
        let c = h.controller(revision: "r1")
        let after = store.all()
        for r in ["r1", "r2"] {
            let x = try XCTUnwrap(after[k(r)])
            XCTAssertEqual(x.status, .pending, r)
            XCTAssertEqual(x.failures, 0, r)
            XCTAssertNil(x.notBefore, r)
            XCTAssertNil(x.lastReason, r)
            XCTAssertFalse(x.denied, r)
            XCTAssertEqual(x.attempts, before[k(r)]?.attempts, r)
        }
        for r in ["r3", "r4", "r5"] { XCTAssertEqual(after[k(r)], before[k(r)], "\(r) keeps its verdict") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.migrated402URL.path))
        XCTAssertEqual(store.migrate402(), [], "once per store")
        // and the key goes on: a new attempt under a lease that allows programs
        XCTAssertEqual(c.state, .cpu)
    }

    func testTheMigrationRunsTheAttemptAgain() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "promotion401", withExtension: nil, subdirectory: "Fixtures"))
        let store = PromotionStore(dir: h.storage)
        try FileManager.default.createDirectory(at: h.storage, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.appendingPathComponent("promotions.json"), to: store.recordsURL)
        h.leaseAllows.withLock { $0 = true }
        let c = h.controller(revision: "r2", launch: "L4")
        await c.run(h.stages())
        XCTAssertEqual(c.state, .ready, "the key 4.0.1 ended for the lease is promoted")
        XCTAssertEqual(c.record?.attempts, 5)
    }

    /// SDK 4.0.5 (ACCEL_40 21.2, 21.6; the developer report of 11-23): a lease without accelerator programs (an install
    /// that is not attested, a command-line tool, a development key's) reads `not_attested` in `model.backend`, never
    /// `denylist`, which is the config's deny list only. The telemetry names it `not_attested` too (the server takes
    /// the 19th reason since 2026-11-23); with `sendsNotAttested` off it counts `denylist`, as 4.0.2 to 4.0.4 did.
    func testALeaseWithoutProgramsReadsNotAttested() async {
        defer { AcceleratorController.sendsNotAttested.withLock { $0 = true } }
        XCTAssertTrue(AcceleratorController.sendsNotAttested.withLock { $0 }, "on: the server takes the reason")
        h.leaseAllows.withLock { $0 = false }
        let c = h.controller()
        await c.run(h.stages())
        XCTAssertEqual(c.record?.lastReason, .notAttested)
        XCTAssertEqual(c.backendReason, "not_attested")
        XCTAssertEqual(h.promotions.map { $0.kind }, [.demoted(.notAttested)])
        // the switch off: the telemetry counts it denylist, model.backend still names it
        AcceleratorController.sendsNotAttested.withLock { $0 = false }
        let n = PromotionTests.Harness()
        n.leaseAllows.withLock { $0 = false }
        let nc = n.controller()
        await nc.run(n.stages())
        XCTAssertEqual(nc.record?.lastReason, .denylist)
        XCTAssertEqual(nc.backendReason, "not_attested")
        XCTAssertEqual(n.promotions.map { $0.kind }, [.demoted(.denylist)])
        AcceleratorController.sendsNotAttested.withLock { $0 = true }
        // the config's deny list: never not_attested
        let d = PromotionTests.Harness()
        d.denied.withLock { $0 = "deny rule r1" }
        let dc = d.controller()
        await dc.run(d.stages())
        XCTAssertEqual(dc.backendReason, "denylist")
        XCTAssertEqual(d.promotions.map { $0.kind }, [.demoted(.denylist)])
    }
}
