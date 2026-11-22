import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.2, contract 28.11 (`sdk_4.0.0/ENDPOINTS_40.md` dd76474, the Ramadan capacity model): every route honours a
/// `Retry-After` on a 429 and on a 503 that carries one, a 429 asks no other host, and the routes that can wait
/// (telemetry, error reports and issues, uploads) step back further after a 429, across restarts. On the SDK's real
/// HTTP code over the stand-in server, with a clock the test moves (28.11 item 6).
final class SlowDownTests: XCTestCase {
    typealias H = HostFailoverTests

    /// One request of `path` and its answer (a failure as status 0).
    static func ask(_ http: HTTPClient, _ path: String) async -> HTTPClient.Response {
        switch await H.get(http, path) {
        case .success(let r): return r
        case .failure: return HTTPClient.Response(status: 0, headers: [:], body: Data())
        }
    }

    override func tearDown() {
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
        StubProtocol.reset { _ in .down }
    }

    /// Item 1 and 28.3: a 429 on any route asks no other host, and until its Retry-After no request of that route asks
    /// any host (the SDK answers its own 429 with the seconds left); then it asks again. A route without a hold is
    /// asked as before.
    func testA429AsksNoOtherHostAndHoldsItsRoute() async throws {
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let (http, e) = H.client(clock)
        H.serve(["api.test": .json(["error": "rate_limited"], status: 429, headers: ["Retry-After": "120"]), "api-b.test": H.ok])
        let first = await Self.ask(http, "v1/events")
        XCTAssertEqual(first.status, 429)
        XCTAssertEqual(H.asked, ["api.test"], "a 429 never fails over")
        H.serve(["api.test": H.ok, "api-b.test": H.ok])
        let held = await Self.ask(http, "v1/events")
        XCTAssertEqual(held.status, 429)
        XCTAssertEqual(held.header("Retry-After"), "120")
        XCTAssertEqual((try? JSONSerialization.jsonObject(with: held.body)) .flatMap { ($0 as? [String: Any])?["error"] as? String }, "rate_limited",
                       "the route's last 429's error")
        XCTAssertEqual(H.asked, [], "no host is asked before the Retry-After")
        let other = await Self.ask(http, "v1/register")
        XCTAssertEqual(other.status, 200, "another route goes on")
        clock.withLock { $0 = $0.addingTimeInterval(100) }
        let later = await Self.ask(http, "v1/events")
        XCTAssertEqual(later.header("Retry-After"), "20")
        clock.withLock { $0 = $0.addingTimeInterval(21) }
        H.serve(["api.test": H.ok, "api-b.test": H.ok])
        let after = await Self.ask(http, "v1/events")
        XCTAssertEqual(after.status, 200)
        XCTAssertEqual(H.asked, ["api.test"])
        XCTAssertNil(e.lastFailover)
    }

    /// Item 1: a 503 with a Retry-After holds that route on that host: the request fails over (28.3), and the next one
    /// of the route skips that host until its Retry-After; with every host held none is asked.
    func testA503WithRetryAfterHoldsTheRouteOnThatHost() async throws {
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let (http, _) = H.client(clock)
        H.serve(["api.test": .json(["error": "unavailable"], status: 503, headers: ["Retry-After": "60"]), "api-b.test": H.ok])
        let c1 = await Self.ask(http, "v1/config")
        XCTAssertEqual(c1.status, 200)
        XCTAssertEqual(H.asked, ["api.test", "api-b.test"])
        H.serve(["api.test": H.ok, "api-b.test": .json(["error": "unavailable"], status: 503, headers: ["Retry-After": "60"]),
                 "api-g.test": H.ok])
        let c2 = await Self.ask(http, "v1/config")
        XCTAssertEqual(c2.status, 200)
        XCTAssertEqual(H.asked, ["api-b.test", "api-g.test"], "api.test is held for the config route")
        H.serve(["api.test": H.ok, "api-b.test": H.ok, "api-g.test": .json(["error": "unavailable"], status: 503, headers: ["Retry-After": "60"])])
        // api-g, the sticky host, was not held yet: asked, and held now
        let third = await Self.ask(http, "v1/config")
        XCTAssertEqual(third.status, 503)
        XCTAssertEqual(H.asked, ["api-g.test"], "api.test and api-b.test are held")
        H.serve(["api.test": H.ok, "api-b.test": H.ok, "api-g.test": H.ok])
        let none = await Self.ask(http, "v1/config")
        XCTAssertEqual(none.status, 503, "every host held")
        XCTAssertNotNil(none.header("Retry-After"))
        XCTAssertEqual(H.asked, [], "no host is asked")
        clock.withLock { $0 = $0.addingTimeInterval(61) }
        let c4 = await Self.ask(http, "v1/config")
        XCTAssertEqual(c4.status, 200)
    }

    /// Item 2's waits: the larger of the Retry-After (300 s without one) and the doubled wait, at most 3600 s; an
    /// accepted answer ends the row.
    func testTheRowsWaits() {
        let rows = SlowDownRows()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual((0..<6).map { _ in rows.slowed("uploads", retryAfter: nil, now: t) }, [300, 600, 1200, 2400, 3600, 3600])
        XCTAssertFalse(rows.allows("uploads", now: t.addingTimeInterval(3599)))
        XCTAssertTrue(rows.allows("uploads", now: t.addingTimeInterval(3600)))
        rows.accepted("uploads")
        XCTAssertTrue(rows.allows("uploads", now: t))
        XCTAssertEqual(rows.slowed("events", retryAfter: 120, now: t), 120)
        XCTAssertEqual(rows.slowed("events", retryAfter: 120, now: t), 240)
        XCTAssertEqual(rows.slowed("issues", retryAfter: 7200, now: t), 7200, "a Retry-After is never cut")
    }

    /// Item 3 for the rows: kept in the SDK's storage and read back at the next start (the count goes on doubling);
    /// a wait more than 21600 s after the clock at start ends then; an accepted answer clears it on disk too.
    func testTheRowsOutliveARestart() {
        let file = CloudFixtures.storage().appendingPathComponent("cloud/slow-down.json")
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = SlowDownRows(file: file, now: t)
        XCTAssertEqual(rows.slowed("uploads", retryAfter: nil, now: t), 300)
        XCTAssertEqual(rows.slowed("uploads", retryAfter: nil, now: t), 600)
        let again = SlowDownRows(file: file, now: t.addingTimeInterval(10))
        XCTAssertEqual(again.row("uploads"), rows.row("uploads"))
        XCTAssertFalse(again.allows("uploads", now: t.addingTimeInterval(599)))
        XCTAssertEqual(again.slowed("uploads", retryAfter: nil, now: t.addingTimeInterval(600)), 1200, "the row goes on")
        let back = SlowDownRows(file: file, now: t.addingTimeInterval(-86_400))
        XCTAssertTrue(back.allows("uploads", now: t.addingTimeInterval(-86_400)), "a clock that moved back: the wait ends now")
        XCTAssertEqual(back.row("uploads")?.count, 3)
        again.accepted("uploads")
        XCTAssertNil(SlowDownRows(file: file, now: t).row("uploads"))
    }

    /// Item 4: a 429 with Retry-After 120 on telemetry; the next send point 30 s later sends nothing, nor one of a new
    /// process 60 s after the 429 (the wait is kept across restarts); the one after 120 s sends the same report.
    func testTelemetryWaitsTheRetryAfterOfA429() async throws {
        let storage = CloudFixtures.storage()
        let now = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let refuse = Locked(true)
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            guard s.path == "/v1/events" else { return nil }
            return refuse.withLock { $0 } ? .json(["error": "rate_limited"], status: 429, headers: ["Retry-After": "120"]) : nil
        }))
        let cloud = CloudFixtures.cloud(storage: storage, clock: { now.withLock { $0 } })
        _ = await cloud.refreshConfig()
        cloud.analytics.record(.modelLoaded(revision: "4.0.0", milliseconds: 12, cohort: PromotionTests.cohort))
        _ = await cloud.flush()
        XCTAssertEqual(StubProtocol.seen("/v1/events").count, 1)
        XCTAssertEqual(cloud.slowDown.row("events")?.wait, 120)
        refuse.withLock { $0 = false }
        now.withLock { $0 = $0.addingTimeInterval(30) }
        _ = await cloud.flush()
        XCTAssertEqual(StubProtocol.seen("/v1/events").count, 1, "the send point 30 s later sends nothing")
        now.withLock { $0 = $0.addingTimeInterval(30) }
        let again = CloudFixtures.cloud(storage: storage, clock: { now.withLock { $0 } })
        _ = await again.flush()
        XCTAssertEqual(StubProtocol.seen("/v1/events").count, 1, "nor a new process's at 60 s")
        now.withLock { $0 = $0.addingTimeInterval(61) }
        let sent = await again.flush()
        let events = StubProtocol.seen("/v1/events")
        XCTAssertGreaterThan(events.count, 1, "the one after 120 s sends")
        XCTAssertEqual(events[1].body, events[0].body, "the same report")
        XCTAssertGreaterThan(sent.events, 0)
        XCTAssertNil(again.slowDown.row("events"), "an accepted answer ends the row")
    }
}
