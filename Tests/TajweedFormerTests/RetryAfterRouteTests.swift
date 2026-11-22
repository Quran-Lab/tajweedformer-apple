import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.2, contract 28.11 items 2, 3 and 6 (`sdk_4.0.0/ENDPOINTS_40.md`, dd76474): every route honours a 429's
/// `Retry-After`, the essential ones included, and the hold outlives a restart of the process. A 429 with Retry-After
/// 90: no request of that route for 90 s, then one; another host is never asked; a new process started 10 s after the
/// 429 sends nothing on that route for the remaining 80 s. On the SDK's real HTTP code and its own callers over the
/// stand-in server, with a clock the test moves. The lease route's own test is in LeaseFailoverTests (it needs the
/// Core's test release).
final class RetryAfterRouteTests: XCTestCase {
    typealias H = HostFailoverTests
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
        StubProtocol.reset { _ in .down }
    }

    /// An HTTP client over the stand-in's api hosts a, b, g whose holds are kept in `file`: a new one is a new process.
    static func client(_ clock: Locked<Date>, file: URL) -> HTTPClient {
        let e = EndpointSet(api: [H.a, H.b, H.g], models: [H.cdn, H.cdnB], clock: { clock.withLock { $0 } }, holdsFile: file)
        return HTTPClient(session: StubProtocol.session(), endpoints: e)
    }

    /// 28.10 item 1's slow down, with the Retry-After of 28.11 item 6.
    static let slowDown = StubProtocol.Reply.json(["error": "rate_limited", "message": "too many requests, retry later"], status: 429,
                                                  headers: ["Retry-After": "90"])
    static let allOK = ["api.test": H.ok, "api-b.test": H.ok, "api-g.test": H.ok]

    /// Every route of the API the SDK asks, as its request goes (the method does not change a hold).
    static let routes = ["v1/config", "v1/register", "v1/attest/challenge", "v1/attest", "v1/attest/assert", "v1/model-key",
                         "v1/events", "v1/issues", "v1/uploads", "v1/uploads/u1/urls", "v1/uploads/u1/takes", "v1/contributions/summary"]

    /// Item 6 on every route, at the HTTP client every caller goes through.
    func testEveryRouteHoldsItsRetryAfterAcrossARestart() async throws {
        for path in Self.routes {
            let clock = Locked(Self.t0)
            let file = CloudFixtures.storage().appendingPathComponent("cloud/retry-after.json")
            let http = Self.client(clock, file: file)
            H.serve(["api.test": Self.slowDown, "api-b.test": H.ok, "api-g.test": H.ok])
            let first = await SlowDownTests.ask(http, path)
            XCTAssertEqual(first.status, 429, path)
            XCTAssertEqual(H.asked, ["api.test"], "\(path): another host is never asked")
            H.serve(Self.allOK)
            clock.withLock { $0 = Self.t0.addingTimeInterval(5) }
            let held = await SlowDownTests.ask(http, path)
            XCTAssertEqual(held.status, 429, path)
            XCTAssertEqual(held.header("Retry-After"), "85", path)
            XCTAssertEqual(H.asked, [], "\(path): nothing for 90 s")
            let other = await SlowDownTests.ask(http, path == "v1/config" ? "v1/register" : "v1/config")
            XCTAssertEqual(other.status, 200, "\(path): another route goes on")
            // a new process 10 s after the 429
            clock.withLock { $0 = Self.t0.addingTimeInterval(10) }
            let again = Self.client(clock, file: file)
            H.serve(Self.allOK)
            for at in [10.0, 50, 89.5] {
                clock.withLock { $0 = Self.t0.addingTimeInterval(at) }
                let r = await SlowDownTests.ask(again, path)
                XCTAssertEqual(r.status, 429, "\(path) at \(at) s")
            }
            XCTAssertEqual(H.asked, [], "\(path): the new process sends nothing on that route for the remaining 80 s")
            clock.withLock { $0 = Self.t0.addingTimeInterval(90) }
            let after = await SlowDownTests.ask(again, path)
            XCTAssertEqual(after.status, 200, path)
            XCTAssertEqual(H.asked, ["api.test"], "\(path): then one, on the host that asked to wait")
        }
    }

    /// Contract e330c08 (28.11 item 2): on the `models` role a hold is per file path and host. A standby answers an
    /// accelerator file with a 503 and `Retry-After: 3600` (it holds the CPU set only): that path is held on that host,
    /// and nothing else is, so a CPU file is still asked there; the held path is answered at once with no request.
    func testAModelFileHoldIsPerPathAndHost() async throws {
        let clock = Locked(Self.t0)
        let (http, _) = H.client(clock)
        let folder = "/models/Quran-Lab/tajweedformer-v4/b/sdk/v4.0/"
        let accelerator = folder + "coreml/tajweedformer_v4.mlmodelc/weights/weight.bin.qle"
        let cpu = folder + "layers.zfw.qle"
        StubProtocol.reset { s in
            if s.url.host == "cdn.test", s.path == accelerator {
                return .json(["error": "unavailable"], status: 503, headers: ["Retry-After": "3600"])
            }
            return StubProtocol.Reply(status: 200, headers: ["content-length": "4"], body: Data("abcd".utf8))
        }
        func get(_ path: String) async -> String {
            let part = CloudFixtures.storage().appendingPathComponent("file.part")
            FileManager.default.createFile(atPath: part.path, contents: nil)
            let request = URLRequest(url: URL(string: "https://cdn.test" + path)!)
            do throws(CloudError) {
                let r = try await http.stream(request, offset: 0, size: 4, into: part, started: { _, _ in }, received: { _ in })
                return "\(r.status)"
            } catch {
                return "\(error)"
            }
        }
        _ = await get(accelerator)
        XCTAssertEqual(StubProtocol.seen(accelerator).count, 1)
        let cpuAnswer = await get(cpu)
        XCTAssertEqual(cpuAnswer, "200", "a CPU file is still asked of that host")
        XCTAssertEqual(StubProtocol.seen(cpu).map { $0.url.host ?? "" }, ["cdn.test"])
        clock.withLock { $0 = Self.t0.addingTimeInterval(60) }
        let held = await get(accelerator)
        XCTAssertTrue(held.contains("503"), "the accelerator file is held on that host: \(held)")
        XCTAssertEqual(StubProtocol.seen(accelerator).count, 1, "and not asked there before its Retry-After")
        clock.withLock { $0 = Self.t0.addingTimeInterval(3601) }
        _ = await get(accelerator)
        XCTAssertEqual(StubProtocol.seen(accelerator).count, 2, "after it, asked again")
    }

    /// Item 3: a 429's hold of a route and a 503's hold of one host both outlive a restart; a hold whose end is more
    /// than 21600 s after the clock at start (a clock that moved back) is read as ending now, one within that is kept.
    func testHoldsOfRoutesAndHostsAndAClockThatMovedBack() async throws {
        let clock = Locked(Self.t0)
        let file = CloudFixtures.storage().appendingPathComponent("cloud/retry-after.json")
        let http = Self.client(clock, file: file)
        StubProtocol.reset { s in
            guard s.url.host == "api.test" else { return H.ok }
            if s.path == "/v1/config" { return .json(["error": "rate_limited"], status: 429, headers: ["Retry-After": "3600"]) }
            if s.path == "/v1/register" { return .json(["error": "unavailable"], status: 503, headers: ["Retry-After": "60"]) }
            return H.ok
        }
        _ = await SlowDownTests.ask(http, "v1/config")
        let registered = await SlowDownTests.ask(http, "v1/register")
        XCTAssertEqual(registered.status, 200)
        XCTAssertEqual(H.asked, ["api.test", "api.test", "api-b.test"])
        // a new process 10 s later: its order starts at api.test again
        clock.withLock { $0 = Self.t0.addingTimeInterval(10) }
        let restarted = Self.client(clock, file: file)
        H.serve(Self.allOK)
        let config = await SlowDownTests.ask(restarted, "v1/config")
        XCTAssertEqual(config.status, 429)
        XCTAssertEqual(H.asked, [], "the config route is still held")
        _ = await SlowDownTests.ask(restarted, "v1/register")
        XCTAssertEqual(H.asked, ["api-b.test"], "api.test is still held for the registration")
        // the clock moved back a day before the next start: the holds end now
        let back = RetryAfterHolds(file: file, now: Self.t0.addingTimeInterval(-86_400))
        XCTAssertEqual(back.snapshot.routes, [:])
        XCTAssertEqual(back.snapshot.hosts, [:])
        // within 21600 s of the clock at start: kept
        let near = RetryAfterHolds(file: file, now: Self.t0.addingTimeInterval(-17_000))
        XCTAssertEqual(Set(near.snapshot.routes.keys), ["config"])
        XCTAssertEqual(Set(near.snapshot.hosts.keys), ["register https://api.test"])
    }

    // MARK: the SDK's own callers

    /// One caller of a route: the path its requests go to, whether the install has App Attest (an Apple team), what
    /// puts the Client where the route is asked (`prepare`, before the 429), and the call.
    struct Caller: Sendable {
        let path: String
        var apple = false
        var prepare: (@Sendable (QuranLabCloud) async -> Void)?
        let call: @Sendable (QuranLabCloud) async -> Void
    }

    static let token: @Sendable (QuranLabCloud) async -> Void = { c in
        await c.tokens?.invalidate()
        _ = try? await c.tokens?.token()
    }

    static let callers: [Caller] = [
        Caller(path: "/v1/config", call: { c in _ = await c.refreshConfig() }),
        Caller(path: "/v1/register", call: { c in _ = await c.register() }),
        // the token without App Attest (Android's way, and an Apple device without it)
        Caller(path: "/v1/attest", call: token),
        // App Attest: the challenge, the attestation, and the assertion of an attested key
        Caller(path: "/v1/attest/challenge", apple: true, call: token),
        Caller(path: "/v1/attest", apple: true, call: token),
        Caller(path: "/v1/attest/assert", apple: true, prepare: { c in _ = try? await c.tokens?.token() }, call: token),
        // one report kept and sent once the route may go (each send point sends what is queued, one request each)
        Caller(path: "/v1/events", prepare: { c in
            c.analytics.record(.modelLoaded(revision: "4.0.0", milliseconds: 12, cohort: PromotionTests.cohort))
        }, call: { c in _ = await c.flush() }),
        Caller(path: "/v1/issues", prepare: { c in
            c.issues.add(QuranLabCloud.issue(kind: "engine_failed", code: "engine:3", app: CloudFixtures.app, backend: .exact, revision: "sha-a"))
        }, call: { c in _ = await c.flush() }),
    ]

    /// Item 6 through the SDK's own callers: a 429 with Retry-After 90 on the route; the caller again 5 s later, then a
    /// new Client on the same storage (a new process) at 10, 50 and 89 s: no request of the route, and an App Attest
    /// attestation or a challenge is not made for a route that cannot take it; at 90 s one request.
    func testEachCallerHoldsItsRouteAcrossARestart() async throws {
        for c in Self.callers {
            let name = c.path + (c.apple ? " (App Attest)" : "")
            let storage = CloudFixtures.storage()
            let now = Locked(Self.t0)
            let busy = Locked(false)
            let attester = FakeAttester(isSupported: c.apple)
            let attestKeys = MemoryAttestKeyStore()
            var options = CloudFixtures.options()
            if c.apple { options.cloud?.appleTeamID = "ABCDE12345" }
            let make = { [options] in
                CloudFixtures.cloud(storage: storage, options: options, attester: attester, attestKeys: attestKeys, clock: { now.withLock { $0 } })
            }
            let path = c.path
            // App Attest: the API takes the attestation (the key is kept, and later tokens are its assertions)
            StubProtocol.reset(CloudFixtures.server(token: c.apple ? CloudFixtures.attestedToken : CloudFixtures.token, extra: { s in
                guard s.path == path, busy.withLock({ $0 }) else { return nil }
                return Self.slowDown
            }))
            let first = make()
            if let prepare = c.prepare { await prepare(first) }
            busy.withLock { $0 = true }
            let before = StubProtocol.seen(path).count
            await c.call(first)
            XCTAssertEqual(StubProtocol.seen(path).count, before + 1, "\(name): the 429")
            busy.withLock { $0 = false }
            let attests = attester.state.with { $0.attestations }
            let challenges = StubProtocol.seen("/v1/attest/challenge").count
            now.withLock { $0 = Self.t0.addingTimeInterval(5) }
            await c.call(first)
            XCTAssertEqual(StubProtocol.seen(path).count, before + 1, "\(name): nothing for 90 s")
            now.withLock { $0 = Self.t0.addingTimeInterval(10) }
            let again = make()
            for at in [10.0, 50, 89] {
                now.withLock { $0 = Self.t0.addingTimeInterval(at) }
                await c.call(again)
            }
            XCTAssertEqual(StubProtocol.seen(path).count, before + 1, "\(name): the new process sends nothing for the remaining 80 s")
            if path == "/v1/attest" || path == "/v1/attest/assert" {
                XCTAssertEqual(StubProtocol.seen("/v1/attest/challenge").count, challenges, "\(name): no challenge for a held route")
                XCTAssertEqual(attester.state.with { $0.attestations }, attests, "\(name): no App Attest attestation for a held route")
            }
            now.withLock { $0 = Self.t0.addingTimeInterval(90) }
            await c.call(again)
            XCTAssertEqual(StubProtocol.seen(path).count, before + 2, "\(name): then one")
            XCTAssertEqual(Set(StubProtocol.seen(path).map { $0.url.host ?? "" }).count, 1, "\(name): one host")
        }
    }
}
