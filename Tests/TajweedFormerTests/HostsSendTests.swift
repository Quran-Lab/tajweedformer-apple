import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5, STEERING_40 34.9.2 to 34.9.4 (the 4.0.4 erratum, which Apple did not ship before 4.0.5): the contract's
/// `hosts_send` vectors replayed through the SDK's own telemetry store, with a fake clock and a fake server. Each step
/// counts a host, ends a download (today's host counts sealed alone and sent at once), makes a send point, passes
/// midnight, restarts the process (a new store on the same storage, whose launch is a send point) or turns telemetry
/// off. Then the bodies sealed (their day, kind and host entries), what was posted with what answer, what still waits,
/// and what the server counted per day and host (entries, and installs by `day_first`) are the case's.
final class HostsSendVectorTests: XCTestCase {
    static let context = AnalyticsStore.Context(platform: "macos", sdkVersion: "4.0.5", appVersion: "1.0", deviceClass: "arm64",
                                                soc: "m2", osMajor: 26, ramTier: "8_16")

    /// The fake server: each body by its id once; every post and its answer.
    final class Server: @unchecked Sendable {
        var counted: [String: [String: Any]] = [:]
        var countedOrder: [String] = []
        var posts: [(id: String, answer: String, counted: Bool?, duplicate: Bool?)] = []
    }

    func testEveryCaseReplays() async throws {
        let hs = try XCTUnwrap(try V40.json("steering_40.json")["hosts_send"] as? [String: Any])
        XCTAssertEqual(hs["dl_sends"] as? Int, AnalyticsStore.downloadSendsPerDay)
        let days = try XCTUnwrap(hs["days"] as? [String])
        let cases = try XCTUnwrap(hs["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 8, "every case of the file is read")
        var replayed = 0
        for c in cases {
            try await replay(c, days: days)
            replayed += 1
        }
        XCTAssertEqual(replayed, cases.count)
    }

    private static func date(_ day: String, _ time: String) -> Date {
        ISO8601DateFormatter().date(from: "\(day)T\(time)Z")!
    }

    private func replay(_ c: [String: Any], days: [String]) async throws {
        let name = c["name"] as? String ?? "?"
        let storage = CloudFixtures.storage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let now = Locked(Self.date(days[0], "12:00:00"))
        func make() -> AnalyticsStore {
            AnalyticsStore(storage: storage, enabled: true, context: Self.context, clock: { now.withLock { $0 } })
        }
        var store = make()
        let server = Server()
        var off = false
        // every body sealed, by its id, in the order sealed
        var seen: [String] = []
        var bodies: [String: [String: Any]] = [:]
        func noteSealed() {
            for s in store.sealed where !seen.contains(s.reportID) {
                seen.append(s.reportID)
                bodies[s.reportID] = (try? JSONSerialization.jsonObject(with: s.body)) as? [String: Any] ?? [:]
            }
        }
        func sender(_ answers: [Any]) -> (Data) async throws(CloudError) -> Void {
            let queue = Locked(answers.map { "\($0)" })
            return { (d: Data) async throws(CloudError) -> Void in
                let body = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
                let id = body["report_id"] as? String ?? "?"
                let answer = queue.withLock { (q: inout [String]) -> String in q.isEmpty ? "202" : q.removeFirst() }
                switch answer {
                case "202", "lost":
                    let dup = server.counted[id] != nil
                    if !dup {
                        server.counted[id] = body
                        server.countedOrder.append(id)
                    }
                    server.posts.append((id, answer, !dup, dup))
                    if answer == "lost" { throw .offline("the answer was lost") }
                case "none":
                    server.posts.append((id, "not sent", nil, nil))
                    throw .offline("not sent")
                default:
                    server.posts.append((id, answer, false, nil))
                    throw .offline("HTTP \(answer)")
                }
            }
        }
        for step in try XCTUnwrap(c["steps"] as? [[String: Any]], name) {
            let answers = step["answers"] as? [Any] ?? []
            switch step["do"] as? String {
            case "count":
                guard !off else { continue }
                let host = try XCTUnwrap(step["host"] as? String)
                let add = step["add"] as? [String: Any] ?? [:]
                store.hostCount(host) { x in
                    x.requests += add["requests"] as? Int ?? 0
                    x.unreachable += add["unreachable"] as? Int ?? 0
                    x.files += add["files"] as? Int ?? 0
                    x.bytes += Int64(add["bytes"] as? Int ?? 0)
                    for (i, n) in (add["ttfb_ms"] as? [Int] ?? []).enumerated() { x.ttfb[i] += n }
                    for (i, n) in (add["kbps"] as? [Int] ?? []).enumerated() { x.kbps[i] += n }
                    for (k, n) in add["fail"] as? [String: Int] ?? [:] { x.fail[k, default: 0] += n }
                    for (k, n) in add["proto"] as? [String: Int] ?? [:] { x.proto[k, default: 0] += n }
                }
            case "download_end":
                guard !off else { continue }
                let sealedOne = store.sealAfterDownload()
                noteSealed()
                // as the Client does (34.9.2 item 4): nothing sealed for the download, nothing sent
                if sealedOne { _ = await store.flush(sealing: false, send: sender(answers)) }
            case "send_point":
                guard !off else { continue }
                store.seal()
                noteSealed()
                _ = await store.flush(send: sender(answers))
            case "midnight":
                now.withLock { $0 = Self.date(days[1], "00:00:30") }
            case "restart":
                store.waitForSave()
                store = make()
                // the launch is a send point
                store.seal()
                noteSealed()
                _ = await store.flush(send: sender(answers))
            case "analytics_off":
                store.dropAll()
                off = true
            default:
                XCTFail("\(name): an unknown step \(step)")
            }
        }
        // the bodies sealed: r1, r2, ... in the order sealed
        let ids = Dictionary(uniqueKeysWithValues: seen.enumerated().map { ($0.element, "r\($0.offset + 1)") })
        let want = try XCTUnwrap(c["sealed"] as? [[String: Any]], name)
        XCTAssertEqual(seen.count, want.count, "\(name): the bodies sealed")
        for (k, w) in want.enumerated() where k < seen.count {
            let got = bodies[seen[k]] ?? [:]
            XCTAssertEqual(got["day"] as? String, w["day"] as? String, "\(name): r\(k + 1)'s day")
            // a download's body is the head, `cohorts: []`, `report_id` and `hosts`, and nothing else (34.9.2 item 2)
            let kind = got["downloads"] == nil && (got["cohorts"] as? [Any])?.isEmpty == true ? "download" : "delta"
            XCTAssertEqual(kind, w["kind"] as? String, "\(name): r\(k + 1)'s kind")
            if kind == "download" {
                XCTAssertEqual(Set(got.keys), ["v", "day", "product", "platform", "sdk_version", "app_version", "device", "cohorts", "report_id", "hosts"],
                               "\(name): r\(k + 1) has nothing else")
            }
            XCTAssertEqual(Self.entries(got["hosts"]), Self.entries(w["hosts"]), "\(name): r\(k + 1)'s hosts")
        }
        // what was posted, with what answer
        let posts = try XCTUnwrap(c["posts"] as? [[String: Any]], name)
        XCTAssertEqual(server.posts.map { "\(ids[$0.id] ?? "?") \($0.answer)" }, posts.map { "\($0["id"] ?? "?") \($0["answer"] ?? "?")" },
                       "\(name): the posts")
        for (k, p) in posts.enumerated() where k < server.posts.count {
            if let counted = p["counted"] as? Bool { XCTAssertEqual(server.posts[k].counted, counted, "\(name): post \(k) counted") }
            if let dup = p["duplicate"] as? Bool { XCTAssertEqual(server.posts[k].duplicate, dup, "\(name): post \(k) duplicate") }
        }
        // what still waits
        let waiting = c["waiting"] as? [String] ?? []
        XCTAssertEqual(store.sealed.map { ids[$0.reportID] ?? "?" }, waiting, "\(name): what waits")
        // what the server counted
        XCTAssertEqual(Self.sums(server.countedOrder.compactMap { server.counted[$0] }), Self.normalize(c["server_sums"]), "\(name): the server's sums")
    }

    /// Host entries keyed by host, without the five fields of section 35 (4.0.5's, 0 in these cases) and without the
    /// zeros of `fail` and `proto`.
    static func entries(_ v: Any?) -> NSDictionary {
        var out: [String: Any] = [:]
        for e in v as? [[String: Any]] ?? [] {
            var x = e.filter { !HostCountsTests.splitFields.contains($0.key) }
            for k in ["fail", "proto"] { if let m = x[k] as? [String: Int] { x[k] = m.filter { $0.value != 0 } } }
            out[e["host"] as? String ?? "?"] = x
        }
        return NSDictionary(dictionary: out)
    }

    /// The server's sums per day and host (34.9.4): the counts, `entries` (the bodies naming the host) and `installs`
    /// (of them, `day_first` 1).
    static func sums(_ bodies: [[String: Any]]) -> NSDictionary {
        var out: [String: [String: [String: Any]]] = [:]
        for b in bodies {
            let day = b["day"] as? String ?? "?"
            for e in b["hosts"] as? [[String: Any]] ?? [] {
                let host = e["host"] as? String ?? "?"
                var x = out[day]?[host] ?? ["files": 0, "bytes": 0, "requests": 0, "unreachable": 0, "hedged": 0, "slow_switches": 0,
                                            "fail": [String: Int](), "proto": [String: Int](), "entries": 0, "installs": 0]
                for k in ["files", "bytes", "requests", "unreachable", "hedged", "slow_switches"] {
                    x[k] = (x[k] as? Int ?? 0) + (e[k] as? Int ?? 0)
                }
                for k in ["fail", "proto"] {
                    var m = x[k] as? [String: Int] ?? [:]
                    for (c, n) in e[k] as? [String: Int] ?? [:] where n != 0 { m[c, default: 0] += n }
                    x[k] = m
                }
                x["entries"] = (x["entries"] as? Int ?? 0) + 1
                x["installs"] = (x["installs"] as? Int ?? 0) + ((e["day_first"] as? Int) == 1 ? 1 : 0)
                out[day, default: [:]][host] = x
            }
        }
        return normalize(out)
    }

    static func normalize(_ v: Any?) -> NSDictionary {
        guard let d = v as? [String: Any] else { return NSDictionary() }
        var out: [String: Any] = [:]
        for (day, hosts) in d {
            var hs: [String: Any] = [:]
            for (host, x) in hosts as? [String: [String: Any]] ?? [:] {
                var y = x
                for k in ["fail", "proto"] { if let m = y[k] as? [String: Int] { y[k] = m.filter { $0.value != 0 } } }
                hs[host] = y
            }
            out[day] = hs
        }
        return NSDictionary(dictionary: out)
    }
}

/// SDK 4.0.5 (34.9.1): the class of each way a model request ends, and the version.
final class FailClassTests: XCTestCase {
    func testEachWayARequestEndsHasItsClass() {
        func noAnswer(_ code: Int) -> CloudError { .offline(ErrorCause.noAnswer(URLError(URLError.Code(rawValue: code)))) }
        XCTAssertEqual(FailClass.of(noAnswer(NSURLErrorNotConnectedToInternet), status: nil, cancelled: false), "offline")
        XCTAssertEqual(FailClass.of(noAnswer(NSURLErrorCannotFindHost), status: nil, cancelled: false), "dns")
        XCTAssertEqual(FailClass.of(noAnswer(NSURLErrorCannotConnectToHost), status: nil, cancelled: false), "connect")
        XCTAssertEqual(FailClass.of(noAnswer(NSURLErrorServerCertificateUntrusted), status: nil, cancelled: false), "tls")
        XCTAssertEqual(FailClass.of(noAnswer(NSURLErrorTimedOut), status: nil, cancelled: false), "timeout")
        XCTAssertEqual(FailClass.of(.offline("\(HTTPClient.silentHost) 10 s [NSURLErrorDomain -1001]"), status: nil, cancelled: false), "timeout")
        XCTAssertEqual(FailClass.of(noAnswer(NSURLErrorBadURL), status: nil, cancelled: false), "no_answer")
        XCTAssertEqual(FailClass.of(.rejected(status: 302, code: HTTPClient.redirectCode, message: ""), status: 302, cancelled: false), "http_3xx")
        XCTAssertEqual(FailClass.of(HTTPClient.failure(status: 403, body: Data()), status: 403, cancelled: false), "http_403")
        XCTAssertEqual(FailClass.of(HTTPClient.failure(status: 404, body: Data()), status: 404, cancelled: false), "http_404")
        XCTAssertEqual(FailClass.of(HTTPClient.failure(status: 429, body: Data()), status: 429, cancelled: false), "http_429")
        XCTAssertEqual(FailClass.of(HTTPClient.failure(status: 416, body: Data()), status: 416, cancelled: false), "http_4xx")
        XCTAssertEqual(FailClass.of(HTTPClient.failure(status: 503, body: Data()), status: 503, cancelled: false), "http_503")
        XCTAssertEqual(FailClass.of(HTTPClient.failure(status: 502, body: Data()), status: 502, cancelled: false), "http_5xx")
        XCTAssertEqual(FailClass.of(.offline("the network connection was lost"), status: 206, cancelled: false), "cut")
        XCTAssertEqual(FailClass.of(.badAnswer("a 200 of 5 bytes for a file of 9"), status: 200, cancelled: false), "bad_body")
        // in no class: taken, cancelled, a write of the device, a hold that sent nothing, a hedge's loser
        XCTAssertNil(FailClass.of(nil, status: 200, cancelled: false))
        XCTAssertNil(FailClass.of(noAnswer(NSURLErrorCancelled), status: nil, cancelled: true))
        XCTAssertNil(FailClass.of(.storage("disk full"), status: 206, cancelled: false))
        XCTAssertNil(FailClass.of(.offline(HTTPClient.heldNotAsked), status: nil, cancelled: false))
        XCTAssertNil(FailClass.of(.offline(HTTPClient.hedgeLost), status: nil, cancelled: false))
        XCTAssertEqual(["http/1.1", "HTTP/1.0", "h2", "h3", "h3-29", "spdy/3", nil].map(FailClass.proto), ["h1", "h1", "h2", "h3", "h3", nil, nil])
    }

    /// The counts of a real stand-in request: a 404 and a cut body are counted by class, and a request that got a status
    /// by its version (the stub names none, so the override stands for the system's metrics).
    func testAStandInsRequestsAreCountedByClassAndVersion() async throws {
        HTTPClient.networkProtocolOverride.withLock { $0 = { _ in "h2" } }
        defer {
            HTTPClient.networkProtocolOverride.withLock { $0 = nil }
            StubProtocol.reset { _ in .down }
        }
        let samples = Locked<[ModelHostSample]>([])
        let http = HTTPClient(session: StubProtocol.session())
        http.modelHosts.withLock { $0 = { s in samples.withLock { $0.append(s) } } }
        let body = Data(repeating: 9, count: 100_000)
        StubProtocol.reset { s in
            switch s.path {
            case "/m/missing.qle": return StubProtocol.Reply(status: 404, headers: [:], body: Data())
            case "/m/cut.qle":
                var r = StubProtocol.Reply(status: 200, headers: ["content-length": "100000"], body: body)
                r.breakAfter = 40_000
                return r
            case "/m/ok.qle": return StubProtocol.Reply(status: 200, headers: [:], body: body)
            default: return .down
            }
        }
        let dir = CloudFixtures.storage()
        for p in ["missing", "cut", "ok", "nothing"] {
            let part = dir.appendingPathComponent(p + ".part")
            FileManager.default.createFile(atPath: part.path, contents: nil)
            let url = try XCTUnwrap(URL(string: "https://cdn.quranlab.ai/m/\(p).qle"))
            _ = try? await http.stream(URLRequest(url: url), offset: 0, size: 100_000, into: part, started: { _, _ in }, received: { _ in })
        }
        let got = samples.withLock { $0 }
        XCTAssertEqual(got.map(\.fail), ["http_404", "cut", nil, "offline"])
        XCTAssertEqual(got.map(\.proto), ["h2", "h2", "h2", nil], "a version for each request that got a status")
        var c = HostCount()
        got.forEach { c.add($0) }
        let e = c.entry(host: "cdn.quranlab.ai")
        XCTAssertEqual(e["fail"] as? [String: Int], ["http_404": 1, "cut": 1, "offline": 1])
        XCTAssertEqual(e["proto"] as? [String: Int], ["h2": 3])
        XCTAssertEqual(e["day_first"] as? Int, 1)
    }
}

/// SDK 4.0.5 (STEERING_40 34.9.7): where a build's model requests went and how its files and download ended, as the
/// trace tells them and the telemetry store keeps them.
final class DownloadTraceTests: XCTestCase {
    final class Told: @unchecked Sendable {
        let events = Locked<[String]>([])
        func trace() -> DownloadTrace {
            let t = DownloadTrace()
            t.tell.withLock { $0 = { [self] e in
                switch e {
                case .modelMove(let h, let to, let why): events.withLock { $0.append("move \(h) \(to) \(why)") }
                case .modelOutcome(let h, let f, let c): events.withLock { $0.append("\(f) \(h)" + (c.map { " \($0)" } ?? "")) }
                default: break
                }
            } }
            return t
        }
    }

    func testMovesAndOutcomes() {
        let told = Told(), t = told.trace()
        // a file asked of cdn4, unreachable (timeout), resumed on cdn3: one move on cdn4; finished on cdn3: moved there
        t.asking("w", "cdn4.quranlab.ai")
        t.left("w", "cdn4.quranlab.ai", cls: "timeout")
        t.asking("w", "cdn3.quranlab.ai")
        t.lastByte("w", "cdn3.quranlab.ai")
        t.fileEnded("w", .done)
        // a file finished on its first host: no outcome (files only)
        t.asking("s", "cdn3.quranlab.ai")
        t.lastByte("s", "cdn3.quranlab.ai")
        t.fileEnded("s", .done)
        // the order came round to the host it left: no move
        t.asking("x", "cdn4.quranlab.ai")
        t.left("x", "cdn4.quranlab.ai", cls: "connect")
        t.asking("x", "cdn4.quranlab.ai")
        // a refusal ends the request on its host: no move; the file failed with its class
        t.failed("x", cls: "http_404")
        t.fileEnded("x", .failed)
        // the hedge, 34.5's cut
        t.moved("h", from: "cdn4.quranlab.ai", to: "cdn2.quranlab.ai", why: "hedge")
        t.fileEnded("h", .cancelled)
        t.moved("c", from: "cdn2.quranlab.ai", to: "cdn.quranlab.ai", why: "slow")
        t.fileEnded("c", .paused)
        t.downloadEnded(ready: false)
        XCTAssertEqual(told.events.withLock { $0 }, [
            "move cdn4.quranlab.ai cdn3.quranlab.ai timeout", "moved cdn3.quranlab.ai",
            "failed cdn4.quranlab.ai http_404",
            "move cdn4.quranlab.ai cdn2.quranlab.ai hedge", "cancelled cdn2.quranlab.ai",
            "move cdn2.quranlab.ai cdn.quranlab.ai slow", "paused cdn.quranlab.ai",
            "not_ready cdn.quranlab.ai",
        ])
        let r = Told(), u = r.trace()
        u.asking("a", "cdn2.quranlab.ai")
        u.lastByte("a", "cdn2.quranlab.ai")
        u.fileEnded("a", .done)
        u.downloadEnded(ready: true)
        XCTAssertEqual(r.events.withLock { $0 }, ["ready cdn2.quranlab.ai"], "ready on the host of the last file")
        XCTAssertEqual(DownloadTrace.end(of: .offline(ErrorCause.noAnswer(URLError(.notConnectedToInternet))), cancelled: false), .paused)
        XCTAssertEqual(DownloadTrace.end(of: .offline(ErrorCause.noAnswer(URLError(.timedOut))), cancelled: false), .failed)
        XCTAssertEqual(DownloadTrace.end(of: .cancelled, cancelled: false), .cancelled)
    }

    /// 34.9.7 item 4 in the store: at most 32 (from, to, why) a day across the day's sends; the outcome on its host.
    func testTheStoreKeepsTheBoundsAndTheOutcome() throws {
        let store = AnalyticsStore(storage: CloudFixtures.storage(), enabled: true, context: HostsSendVectorTests.context)
        let whys = FailClass.moveWhy
        for i in 0..<20 { store.record(.modelMove(host: "cdn4.quranlab.ai", to: "cdn3.quranlab.ai", why: whys[i % whys.count])) }
        store.seal()
        for i in 0..<40 { store.record(.modelMove(host: "cdn2.quranlab.ai", to: "cdn\(i % 3 == 0 ? "" : "3").quranlab.ai", why: whys[i % whys.count])) }
        store.record(.modelMove(host: "cdn2.quranlab.ai", to: "cdn2.quranlab.ai", why: "dns"))
        store.record(.modelMove(host: "cdn2.quranlab.ai", to: "cdn.example.com", why: "dns"))
        store.record(.modelOutcome(host: "cdn2.quranlab.ai", field: "failed", cls: "http_404"))
        store.record(.modelOutcome(host: "cdn2.quranlab.ai", field: "ready", cls: nil))
        store.seal()
        var pairs = 0
        for s in store.sealed {
            let b = try XCTUnwrap((try JSONSerialization.jsonObject(with: s.body)) as? [String: Any])
            for e in b["hosts"] as? [[String: Any]] ?? [] {
                let mv = e["moves"] as? [[String: Any]] ?? []
                pairs += mv.count
                XCTAssertFalse(mv.contains { $0["to"] as? String == e["host"] as? String }, "never to its own host")
                XCTAssertNil(HostCountsTests.refusal([e]), "the server takes the entry")
                if e["host"] as? String == "cdn2.quranlab.ai" {
                    XCTAssertEqual((e["outcome"] as? [String: Any])?["ready"] as? Int, 1)
                    XCTAssertEqual(((e["outcome"] as? [String: Any])?["failed"] as? [String: Int]), ["http_404": 1])
                }
            }
        }
        XCTAssertEqual(pairs, HostCount.movesMax, "32 distinct (from, to, why) in the day, across its two sends")
    }
}
