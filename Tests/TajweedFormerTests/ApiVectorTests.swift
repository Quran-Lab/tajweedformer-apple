import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5, contract section 37 (`API_40.md`): `vectors/api_40.json`'s `routes`, `classes`, `buckets` and `sends`
/// through the SDK's own route reader, class mapper (34.9.1's, shared with `hosts`), buckets and telemetry store. Each
/// test fails when it reads fewer cases than the file holds (37.8 item 1).
final class ApiVectorTests: XCTestCase {
    static func vectors() throws -> [String: Any] { try V40.json("api_40.json") }

    override func tearDown() { AnalyticsStore.sendsApiCounts.withLock { $0 = true } }

    func testRoutes() throws {
        let cases = try XCTUnwrap(try Self.vectors()["routes"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 18, "every case of the file is read")
        for c in cases {
            let m = try XCTUnwrap(c["method"] as? String), p = try XCTUnwrap(c["path"] as? String)
            XCTAssertEqual(ApiRoute.of(method: m, path: p), c["route"] as? String, "\(m) \(p)")
        }
    }

    /// An answer of the vectors as the class mapper reads it.
    static func answer(_ a: [String: Any]) -> ApiClass.Answer {
        var x = ApiClass.Answer(status: a["status"] as? Int)
        if let s = x.status {
            if (200..<300).contains(s) { x.taken = !((a["not_answer"] as? Bool) ?? false) }
            if s == 304 { x.taken = (a["conditional"] as? Bool) ?? false }
        }
        x.apiError = (a["json_error"] as? Bool) ?? false
        x.cut = (a["cut"] as? Bool) ?? false
        if let e = a["error"] as? String { x.noStatus = e == "other" ? "no_answer" : e }
        return x
    }

    func testClasses() throws {
        let cases = try XCTUnwrap(try Self.vectors()["classes"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 21, "every case of the file is read")
        let readings: [String: AnswerClass] = ["taken": .taken, "refusal": .refused, "slow_down": .slowDown, "unreachable": .unreachable]
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let route = try XCTUnwrap(c["route"] as? String)
            let got = ApiClass.of(route: route, Self.answer(try XCTUnwrap(c["answer"] as? [String: Any])))
            XCTAssertEqual(got.reading, readings[c["reading"] as? String ?? ""], name)
            XCTAssertEqual(got.fail, c["class"] as? String, name)
        }
    }

    func testBuckets() throws {
        let b = try XCTUnwrap(try Self.vectors()["buckets"] as? [String: Any])
        XCTAssertEqual(b["total_ms_bounds"] as? [Double], ApiCount.msBounds)
        XCTAssertEqual(b["connect_ms_bounds"] as? [Double], ApiCount.msBounds)
        XCTAssertEqual(b["ready_s_bounds"] as? [Double], ReadyCount.sBounds)
        let ms = try XCTUnwrap(b["ms"] as? [[String: Any]]), s = try XCTUnwrap(b["s"] as? [[String: Any]])
        XCTAssertEqual(ms.count, 12)
        XCTAssertEqual(s.count, 12)
        for x in ms {
            XCTAssertEqual(HostCount.bucket(try XCTUnwrap(x["ms"] as? Double), ApiCount.msBounds), x["bucket"] as? Int, "\(x)")
        }
        for x in s {
            XCTAssertEqual(HostCount.bucket(try XCTUnwrap(x["s"] as? Double), ReadyCount.sBounds), x["bucket"] as? Int, "\(x)")
        }
    }

    /// 37.7 `sends`: one install's steps through the telemetry store, and the bodies it seals.
    func testSends() async throws {
        AnalyticsStore.sendsApiCounts.withLock { $0 = true }
        let cases = try XCTUnwrap(try Self.vectors()["sends"] as? [[String: Any]])
        // 14 at 222c408: the five of 37.4's idle install appended
        XCTAssertEqual(cases.count, 14, "every case of the file is read")
        for c in cases { try replay(c) }
    }

    private func replay(_ c: [String: Any]) throws {
        let name = c["name"] as? String ?? "?"
        let storage = CloudFixtures.storage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let now = Locked(ISO8601DateFormatter().date(from: "2026-11-24T12:00:00Z")!)
        let store = AnalyticsStore(storage: storage, enabled: true, context: HostsSendVectorTests.context, clock: { now.withLock { $0 } })
        var off = false
        var bodies: [[String: Any]] = []
        var seen: Set<String> = []
        func collect() {
            for s in store.sealed where !seen.contains(s.reportID) {
                seen.insert(s.reportID)
                guard let b = (try? JSONSerialization.jsonObject(with: s.body)) as? [String: Any] else { continue }
                if b["api"] != nil || b["ready"] != nil { bodies.append(b) }
            }
        }
        for step in try XCTUnwrap(c["steps"] as? [[Any]], name) {
            switch step[0] as? String {
            case "call":
                guard !off else { continue }
                let route = try XCTUnwrap(step[1] as? String)
                let hosts = try XCTUnwrap(step[2] as? [String]), answers = try XCTUnwrap(step[3] as? [[String: Any]])
                // 28.3: the hosts in order; an unreachable one sends the request on, and the move is on the host left
                for (i, (h, a)) in zip(hosts, answers).enumerated() {
                    let x = Self.answer(a)
                    let conn = a["conn"] as? String
                    let proto = (a["proto"] as? String).map { $0 == "h1" ? "http/1.1" : $0 }
                    let m = ApiMeasure(totalMs: a["ms"] as? Double, reused: conn == "new" ? false : conn == "reused" ? true : nil,
                                       connectMs: a["connect_ms"] as? Double, proto: proto)
                    let sample = ApiSample.of(host: h, route: route, answer: x, cancelled: false, measure: m, ownMs: nil)
                    store.record(.apiCall(sample))
                    let reading = ApiClass.of(route: route, x).reading
                    guard reading == .unreachable else { break }
                    if i + 1 < answers.count, let why = sample.fail {
                        store.record(.apiMove(host: h, route: route, to: hosts[i + 1], why: why))
                    }
                }
            case "ready":
                guard !off else { continue }
                switch step[1] as? String {
                case "first": store.record(.ready(ReadySample(kind: .first, seconds: try XCTUnwrap(step[2] as? Double))))
                case "later": store.record(.ready(ReadySample(kind: .later, seconds: try XCTUnwrap(step[2] as? Double))))
                default: store.record(.ready(ReadySample(kind: .notReady)))
                }
            case "seal":
                // 37.4: a seal marked `other` is a delta that carries something besides api and ready (a launch here)
                if step.count > 1, step[1] as? String == "other" { store.count(.launch) }
                store.seal()
                collect()
            case "midnight":
                // 34.9.3 item 4: the day's counts close with its last delta, then the new day begins (37.4: idle counts
                // still waiting are dropped by the next seal, an earlier day's)
                if step.count > 1, step[1] as? String == "other" { store.count(.launch) }
                store.seal()
                collect()
                now.withLock { $0 = ISO8601DateFormatter().date(from: "2026-11-25T00:00:30Z")! }
            case "off":
                store.dropAll()
                off = true
            default:
                XCTFail("\(name): an unknown step \(step)")
            }
        }
        let want = try XCTUnwrap(c["bodies"] as? [[String: Any]], name)
        XCTAssertEqual(bodies.count, want.count, "\(name): the bodies")
        for (k, w) in want.enumerated() where k < bodies.count {
            let got = bodies[k]
            XCTAssertEqual(got["day"] as? String, w["day"] as? String, "\(name): body \(k)'s day")
            XCTAssertEqual(Self.entries(got["api"]), Self.entries(w["api"]), "\(name): body \(k)'s api")
            XCTAssertEqual((got["ready"] as? [String: Any]).map { NSDictionary(dictionary: $0) },
                           (w["ready"] as? [String: Any]).map { NSDictionary(dictionary: $0) }, "\(name): body \(k)'s ready")
        }
    }

    /// `api` entries keyed by host and route; a key of `fail` or `proto` left out reads as 0.
    static func entries(_ v: Any?) -> NSDictionary {
        var out: [String: Any] = [:]
        for e in v as? [[String: Any]] ?? [] {
            var x = e
            for k in ["fail", "proto"] { if let m = x[k] as? [String: Int] { x[k] = m.filter { $0.value != 0 } } }
            out["\(e["host"] ?? "?") \(e["route"] ?? "?")"] = x
        }
        return NSDictionary(dictionary: out)
    }
}

/// SDK 4.0.5 (37.6 item 1): `api` and `ready` go out by default (qlab-api takes them since 2026-11-23 13:55Z); with the
/// switch off they stay out of every body and are counted meanwhile; with telemetry off in the signed config nothing is
/// counted.
final class ApiHoldTests: XCTestCase {
    override func tearDown() { AnalyticsStore.sendsApiCounts.withLock { $0 = true } }

    func testTheSwitchHoldsTheFields() throws {
        XCTAssertTrue(AnalyticsStore.sendsApiCounts.withLock { $0 }, "on: the server takes api and ready")
        // off: counted, and left out of the day's delta
        AnalyticsStore.sendsApiCounts.withLock { $0 = false }
        let store = AnalyticsStore(storage: CloudFixtures.storage(), enabled: true, context: HostsSendVectorTests.context)
        store.record(.apiCall(ApiSample(host: "api.quranlab.ai", route: "config", fail: nil, totalMs: 80, reused: false,
                                        connectMs: 40, proto: "h2")))
        store.record(.ready(ReadySample(kind: .later, seconds: 0.8)))
        store.count(.launch)
        store.seal()
        let body = try XCTUnwrap((try JSONSerialization.jsonObject(with: try XCTUnwrap(store.sealed.last).body)) as? [String: Any])
        XCTAssertNil(body["api"])
        XCTAssertNil(body["ready"])
        // on: the next day's counts go out
        AnalyticsStore.sendsApiCounts.withLock { $0 = true }
        store.record(.apiCall(ApiSample(host: "api.quranlab.ai", route: "config", fail: "timeout")))
        store.seal()
        let on = try XCTUnwrap((try JSONSerialization.jsonObject(with: try XCTUnwrap(store.sealed.last).body)) as? [String: Any])
        let api = try XCTUnwrap(on["api"] as? [[String: Any]])
        XCTAssertEqual(api.first?["fail"] as? [String: Int], ["timeout": 1])
        XCTAssertEqual(api.first?["day_first"] as? Int, 1)
    }

    /// 37.8 item 6: an idle install, on a fake clock: after the first send that follows its start,
    /// no delta (no `POST /v1/events`) for an hour of send points (every 15 minutes), each send's own `events` request
    /// counted and held; then one take, and the next send point seals one body that carries the held `events` counts
    /// beside the take's. A failed `events` request is sent at the next send point; held counts are dropped at 00:00 UTC.
    func testAnIdleInstallSendsNothing() throws {
        let t = Locked(ISO8601DateFormatter().date(from: "2026-11-24T12:00:00Z")!)
        let store = AnalyticsStore(storage: CloudFixtures.storage(), enabled: true, context: HostsSendVectorTests.context, clock: { t.withLock { $0 } })
        func events(fail: String? = nil) {
            store.record(.apiCall(ApiSample(host: "api.quranlab.ai", route: "events", fail: fail, totalMs: fail == nil ? 60 : nil,
                                            reused: true, connectMs: nil, proto: "h2")))
        }
        // the start: a launch and the config, sent
        store.count(.launch)
        store.record(.apiCall(ApiSample(host: "api.quranlab.ai", route: "config", fail: nil, totalMs: 80, reused: false, connectMs: 40, proto: "h2")))
        XCTAssertEqual(store.seal(), 1, "the first send after the start")
        events()
        // an hour of send points, each send's own request counted: nothing sealed, nothing posted
        for _ in 0..<4 {
            t.withLock { $0 = $0.addingTimeInterval(15 * 60) }
            XCTAssertEqual(store.seal(), 0, "an idle delta is not sealed")
            events()
        }
        // one take: the next send point posts, with the held events counts beside the take's
        store.count(.launch)
        t.withLock { $0 = $0.addingTimeInterval(15 * 60) }
        XCTAssertEqual(store.seal(), 1)
        let body = try XCTUnwrap((try JSONSerialization.jsonObject(with: try XCTUnwrap(store.sealed.last).body)) as? [String: Any])
        let api = try XCTUnwrap(body["api"] as? [[String: Any]])
        XCTAssertEqual(api.map { $0["route"] as? String }, ["events"])
        XCTAssertEqual(api.first?["requests"] as? Int, 5, "the start's send and the four of the idle hour")
        XCTAssertEqual(api.first?["day_first"] as? Int, 1)
        // a failed events request goes at the next send point
        events(fail: "http_503")
        XCTAssertEqual(store.seal(), 1, "a failure is content")
        // held counts are dropped at 00:00 UTC, never sent alone
        events()
        XCTAssertEqual(store.seal(), 0)
        t.withLock { $0 = ISO8601DateFormatter().date(from: "2026-11-25T00:00:30Z")! }
        XCTAssertEqual(store.seal(), 0, "the earlier day's idle counts are dropped")
        store.count(.launch)
        XCTAssertEqual(store.seal(), 1)
        let next = try XCTUnwrap((try JSONSerialization.jsonObject(with: try XCTUnwrap(store.sealed.last).body)) as? [String: Any])
        XCTAssertNil(next["api"], "nothing of the dropped counts")
    }

    /// 37.8 item 4: on a fake clock, an ask 5 minutes after the Client was made and ready 0.8 s later counts in `later`'s
    /// first bucket (under 1 s); a failed ask counts `not_ready` only.
    func testTheReadyClockStartsAtTheAsk() async throws {
        let t = Locked(1000.0)
        ReadyClock.now.withLock { $0 = { t.withLock { $0 } } }
        ReadyClock.forgetForTests()
        defer {
            ReadyClock.now.withLock { $0 = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 } }
            ReadyClock.forgetForTests()
        }
        t.withLock { $0 += 300 }
        let ask = try XCTUnwrap(ReadyClock.begin(), "the process's first ask")
        XCTAssertNil(ReadyClock.begin(), "one count per process")
        t.withLock { $0 += 0.8 }
        let seconds = ReadyClock.now.withLock { $0 }() - ask.start
        var r = ReadyCount()
        r.add(ReadySample(kind: .later, seconds: seconds))
        r.add(ReadySample(kind: .notReady))
        XCTAssertEqual(r.later, [1, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(r.first, [Int](repeating: 0, count: 9))
        XCTAssertEqual(r.notReady, 1)
    }
}

/// SDK 4.0.5, 37.8 item 2: what the SDK's real HTTP code counts against stand-in API hosts on loopback (URLSession and
/// `routed`, the counts read at the client's sink): a first host that refuses the connection and a second that answers,
/// a 304 config, a 429, a cut body.
final class ApiStandInTests: XCTestCase {
    final class Sink: @unchecked Sendable {
        let events = Locked<[AnalyticsEvent]>([])
        var calls: [ApiSample] { events.withLock { $0 }.compactMap { if case .apiCall(let s) = $0 { return s } else { return nil } } }
        var moves: [String] {
            events.withLock { $0 }.compactMap { if case .apiMove(_, let r, _, let why) = $0 { return "\(r) \(why)" } else { return nil } }
        }
        /// The counts are told once a request ends; give the last one a moment.
        func settle(_ n: Int) async {
            for _ in 0..<100 where calls.count < n { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
    }

    func client(_ hosts: [URL]) -> (HTTPClient, Sink) {
        let endpoints = EndpointSet(api: hosts, models: [URL(string: "https://cdn.quranlab.ai")!])
        let http = HTTPClient(session: HostSession.make(), endpoints: endpoints)
        let sink = Sink()
        http.apiSink.withLock { $0 = { e in sink.events.withLock { $0.append(e) } } }
        return (http, sink)
    }

    func testARefusedConnectionAMoveA304A429AndACut() async throws {
        let dead = try HostServer("dead")
        let deadOrigin = dead.origin
        dead.stop()
        let b = try HostServer("b") { r in
            switch r.path {
            case "/v1/config":
                return r.headers["if-none-match"] != nil ? .answer(status: 304, headers: [:], body: Data()) : .json(["ok": true])
            case "/v1/events": return .json(["error": "rate_limited"], status: 429)
            case "/v1/register": return .truncated(status: 200, headers: ["content-type": "application/json"], body: Data(repeating: 32, count: 4000), sent: 100)
            default: return .json(["error": "not_found"], status: 404)
            }
        }
        // the first host refuses the connection, the second answers: `connect` and a move on the first
        var (http, sink) = client([deadOrigin, b.origin])
        _ = try await http.checked(URLRequest(url: deadOrigin.appendingPathComponent("v1/config")))
        await sink.settle(2)
        XCTAssertEqual(sink.calls.map(\.fail), ["connect", nil])
        XCTAssertEqual(sink.moves, ["config connect"], "the move is on the host left")
        let ok = try XCTUnwrap(sink.calls.last)
        XCTAssertEqual(ok.route, "config")
        XCTAssertNotNil(ok.totalMs, "an answer read whole is timed")
        XCTAssertEqual(ok.reused, false, "a new connection")
        XCTAssertEqual(ok.proto, "h1", "HTTP/1.1 on loopback")
        XCTAssertNil(sink.calls.first?.totalMs, "no status: no time")

        // a 304 to a config sent with If-None-Match: taken, timed
        (http, sink) = client([b.origin])
        var conditional = URLRequest(url: b.origin.appendingPathComponent("v1/config"))
        conditional.setValue("\"etag\"", forHTTPHeaderField: "if-none-match")
        _ = try await http.send(conditional, accepting: { $0.status == 304 })
        await sink.settle(1)
        XCTAssertEqual(sink.calls.map(\.fail), [nil])
        XCTAssertNotNil(sink.calls.first?.totalMs)

        // a 429: http_429, the request ends on its host (no move, even with a host after it)
        (http, sink) = client([b.origin, deadOrigin])
        var events = URLRequest(url: b.origin.appendingPathComponent("v1/events"))
        events.httpMethod = "POST"
        _ = try? await http.checked(events)
        await sink.settle(1)
        XCTAssertEqual(sink.calls.map(\.fail), ["http_429"])
        XCTAssertEqual(sink.moves, [])

        // a body that ends before its length: `cut`, not timed
        (http, sink) = client([b.origin])
        var register = URLRequest(url: b.origin.appendingPathComponent("v1/register"))
        register.httpMethod = "POST"
        _ = try? await http.checked(register)
        await sink.settle(1)
        XCTAssertEqual(sink.calls.first?.fail, "cut")
        XCTAssertNil(sink.calls.first?.totalMs)
        withExtendedLifetime(b) {}
    }
}
