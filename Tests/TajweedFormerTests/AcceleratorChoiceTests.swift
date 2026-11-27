import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5, the developer report of 2026-11-23 (items 2 and 3) at the level they are decided: which engines run the
/// Neural Engine's promotion and load a build, what `model.backend`'s stage reads while a build loads, and that a build
/// stays warm while the Model holds its controller (an options change keeps it).
final class AcceleratorChoiceTests: XCTestCase {
    /// Item 2: a `.cpu` engine (`.exact`) sets up the default build's promotion too, never loads a promoted build, and its
    /// takes stay on the CPU engine (`startTake` leases for `.automatic` only). A CPU-only context never promotes.
    func testACPUEnginePromotesTheDefaultBuildAndNeverLoadsIt() {
        XCTAssertTrue(TajweedRecognizer.setsUpPromotion(requested: .automatic, context: "c16_l64"))
        XCTAssertTrue(TajweedRecognizer.setsUpPromotion(requested: .exact, context: "c16_l64"), "to 4.0.4 a .cpu engine never promoted")
        XCTAssertFalse(TajweedRecognizer.mayUseAccelerator(requested: .exact, context: "c16_l64"), "its own takes never use it")
        XCTAssertTrue(TajweedRecognizer.loadsPromotedBuild(requested: .automatic))
        XCTAssertFalse(TajweedRecognizer.loadsPromotedBuild(requested: .exact))
        if let cpuOnly = ModelContexts.cpuOnly.first {
            XCTAssertFalse(TajweedRecognizer.setsUpPromotion(requested: .exact, context: cpuOnly))
            XCTAssertFalse(TajweedRecognizer.setsUpPromotion(requested: .automatic, context: cpuOnly))
        }
    }

    /// Item 3: a build promoted earlier that is loaded again reads `loading` (it read `testing`), and each other state
    /// its stage as before.
    func testAReloadReadsLoading() async {
        let h = PromotionTests.Harness()
        let c = h.controller()
        XCTAssertEqual(TajweedRecognizer.stage(.preparing, c).0, .downloading, "a key never tried")
        await c.run(h.stages())
        XCTAssertEqual(c.record?.status, .ready)
        XCTAssertEqual(TajweedRecognizer.stage(.preparing, c).0, .loading, "a promoted key loading again")
        XCTAssertEqual(TajweedRecognizer.stage(.ready, c).0, .promoted)
        XCTAssertEqual(TajweedRecognizer.stage(.cpu, c).0, .cpu)
        XCTAssertEqual(TajweedRecognizer.stage(.disabled("x"), nil).0, .cpu)
        XCTAssertEqual(TajweedBackend(kind: .cpu, name: "cpu", stage: .loading, reason: nil).description, "cpu (loading)")
    }

    /// Item 3: one controller per key while anything holds it (`AcceleratorController.shared`): the Model keeps the
    /// replaced engine's controller (`State.warm`), so a new engine of the same build gets it, loaded and warm, with no
    /// stage run again. With nothing holding it, a new engine gets a new controller that has to load the build.
    func testAHeldControllerStaysWarmForTheNextEngine() async {
        let h = PromotionTests.Harness()
        let env = h.env(revision: "warm-" + UUID().uuidString)
        var warm: AcceleratorController? = AcceleratorController.shared(env)
        await warm?.run(h.stages())
        XCTAssertEqual(warm?.state, .ready)
        let ran = h.calls.withLock { $0 }
        let again = AcceleratorController.shared(env)
        XCTAssertTrue(again === warm, "the same controller for the new engine")
        XCTAssertEqual(again.state, .ready, "warm at once")
        await again.run(h.stages())
        XCTAssertEqual(h.calls.withLock { $0 }, ran, "nothing ran again")
        warm = nil
        _ = warm
        let other = h.env(revision: "cold-" + UUID().uuidString)
        do {
            let c = AcceleratorController.shared(other)
            await c.run(h.stages())
            XCTAssertEqual(c.state, .ready)
        }
        // nothing holds it now: a new engine gets a controller that has not loaded the build in this process
        XCTAssertNotEqual(AcceleratorController.shared(other).state, .ready)
    }
}

/// SDK 4.0.5 (plan A2): the Client opens the API's connection while it starts: one `GET /v1/health` to the api role's
/// first host, sent on the Client's own session without waiting, so the launch's first call finds the connection open.
/// A Client without a key sends nothing.
final class PreconnectTests: XCTestCase {
    override func tearDown() {
        QuranLabCloud.preconnectsWithOwnSession.withLock { $0 = false }
        StubProtocol.reset { _ in .down }
    }

    func testTheClientOpensTheAPIConnectionAsItStarts() async throws {
        QuranLabCloud.preconnectsWithOwnSession.withLock { $0 = true }
        let gate = StubProtocol.Gate()
        defer { gate.open() }
        StubProtocol.reset { s in
            // the health answer is held: the Client's start must not wait for it
            if s.path == "/v1/health" {
                var r = StubProtocol.Reply.json(["ok": true])
                r.hold = gate
                return r
            }
            return .down
        }
        let t0 = Date()
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage())
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2, "the Client's start does not wait for the connection")
        for _ in 0..<100 where StubProtocol.seen("/v1/health").isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        let seen = StubProtocol.seen("/v1/health")
        XCTAssertEqual(seen.count, 1, "one request, at the start")
        XCTAssertEqual(seen.first?.method, "GET")
        XCTAssertEqual(seen.first?.url.host, CloudFixtures.api.host, "the api role's first host")
        XCTAssertNil(seen.first?.headers["authorization"], "nothing of the install goes with it")
        withExtendedLifetime(cloud) {}

        // a Client without a key: nothing
        StubProtocol.reset { _ in .down }
        let keyless = QuranLabCloud(key: nil, options: CloudFixtures.options(), storage: CloudFixtures.storage(),
                                    attester: FakeAttester(isSupported: false), attestKeys: MemoryAttestKeyStore(),
                                    installKeys: CloudFixtures.installKeys)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(StubProtocol.seen("/v1/health").isEmpty)
        withExtendedLifetime(keyless) {}
    }
}
