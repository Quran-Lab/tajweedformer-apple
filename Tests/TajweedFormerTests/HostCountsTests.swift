import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.2, STEERING_40 34.6: the per-host download counts. Each model file request's host,
/// bytes, time to status, rate and outcome go into the telemetry day, per `models` host of the allow-list, at most 8 a
/// day; `hosts` is sent behind `AnalyticsStore.sendsHostCounts` (on: qlab-api takes it since 2026-11-21). On the SDK's
/// real streaming code over the stand-in server; the bodies are held to the contract's `telemetry` vectors.
final class HostCountsTests: XCTestCase {
    static let a = "cdn.quranlab.ai", b = "cdn-b.tajweedformer.com"

    override func tearDown() {
        AnalyticsStore.sendsHostCounts.withLock { $0 = true }
        StubProtocol.reset { _ in .down }
    }

    func testTheBuckets() {
        XCTAssertEqual([0, 99, 100, 249, 250, 999, 1000, 1499, 1500, 9999, 10_000, 60_000].map { HostCount.bucket(Double($0), HostCount.ttfbBounds) },
                       [0, 0, 1, 1, 2, 3, 4, 4, 5, 7, 8, 8])
        XCTAssertEqual([0, 31.9, 32, 255, 1023, 8191, 8192].map { HostCount.bucket($0, HostCount.kbpsBounds) }, [0, 0, 1, 3, 5, 8, 9])
        XCTAssertEqual(HostCount.kilobytesPerSecond(512_000, 2), 256)
        var c = HostCount()
        c.add(ModelHostSample(host: Self.a, ttfbMs: 120, bytes: 300_000, bodySeconds: 2, unreachable: false, lastByte: true))
        c.add(ModelHostSample(host: Self.a, ttfbMs: nil, bytes: 0, bodySeconds: 0, unreachable: true, lastByte: false))
        c.add(ModelHostSample(host: Self.a, ttfbMs: 40, bytes: 1000, bodySeconds: 0.01, unreachable: false, lastByte: true))
        XCTAssertEqual(c.files, 2)
        XCTAssertEqual(c.bytes, 301_000)
        XCTAssertEqual(c.requests, 3)
        XCTAssertEqual(c.unreachable, 1)
        XCTAssertEqual(c.ttfb, [1, 1, 0, 0, 0, 0, 0, 0, 0], "a request without a status has no time to status")
        XCTAssertEqual(c.kbps, [0, 0, 0, 1, 0, 0, 0, 0, 0, 0], "300 kB in 2 s is 150 kB/s; the small transfer is not timed")
    }

    /// The counts of a stand-in server: a whole file whose status comes after 600 ms, a file cut after 40000 bytes and
    /// resumed on the next host, a file answered 503 then served by the next host, a request with no answer, and a
    /// file from a host off the allow-list (not counted).
    func testTheCountsOfAStandInServer() async throws {
        XCTAssertTrue(AnalyticsStore.sendsHostCounts.withLock { $0 }, "on in 4.0.2")
        AnalyticsStore.sendsHostCounts.withLock { $0 = false }
        let storage = CloudFixtures.storage()
        let store = AnalyticsStore(storage: storage, enabled: true,
                                   context: .init(platform: "ios", sdkVersion: "4.0.2", appVersion: "2.1", deviceClass: "A17", soc: "a17",
                                                  osMajor: 18, ramTier: "8_16"))
        let http = HTTPClient(session: StubProtocol.session())
        http.modelHosts.withLock { $0 = { s in store.record(.modelHost(s)) } }
        let files: [String: Data] = ["/m/whole.qle": Data(repeating: 1, count: 300 << 10), "/m/cut.qle": Data(repeating: 2, count: 100_000),
                                     "/m/failed.qle": Data(repeating: 3, count: 50_000), "/m/off.qle": Data(repeating: 4, count: 1000)]
        let slow = StubProtocol.Gate()
        StubProtocol.reset { s in
            guard let d = files[s.path] else { return StubProtocol.Reply(status: 404) }
            let host = s.url.host ?? ""
            if s.path == "/m/nothing.qle" { return .down }
            if host == Self.a, s.path == "/m/failed.qle" { return .json(["error": "unavailable"], status: 503) }
            var reply = ModelDownloadTests.served(s, data: d, etag: "\"x\"")
            if host == Self.a, s.path == "/m/whole.qle" { reply.hold = slow }
            if host == Self.a, s.path == "/m/cut.qle" { reply.breakAfter = 40_000 }
            return reply
        }
        func get(_ host: String, _ path: String, offset: Int64 = 0, size: Int) async -> CloudError? {
            let part = storage.appendingPathComponent(UUID().uuidString)
            if offset > 0 { try? Data(repeating: 2, count: Int(offset)).write(to: part) } else { FileManager.default.createFile(atPath: part.path, contents: nil) }
            var r = URLRequest(url: URL(string: "https://\(host)\(path)")!)
            if offset > 0 {
                r.setValue("bytes=\(offset)-", forHTTPHeaderField: "range")
                r.setValue("\"x\"", forHTTPHeaderField: "if-range")
            }
            do throws(CloudError) {
                _ = try await http.stream(r, offset: offset, size: Int64(size), into: part, started: { _, _ in }, received: { _ in })
                return nil
            } catch {
                return error
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            slow.open()
        }
        let whole = await get(Self.a, "/m/whole.qle", size: 300 << 10)
        XCTAssertNil(whole)
        let cut = await get(Self.a, "/m/cut.qle", size: 100_000)
        XCTAssertNotNil(cut)
        let resumed = await get(Self.b, "/m/cut.qle", offset: 40_000, size: 100_000)
        XCTAssertNil(resumed)
        let failed = await get(Self.a, "/m/failed.qle", size: 50_000)
        XCTAssertNotNil(failed)
        let failover = await get(Self.b, "/m/failed.qle", size: 50_000)
        XCTAssertNil(failover)
        StubProtocol.reset { _ in .down }
        let nothing = await get(Self.a, "/m/whole.qle", size: 300 << 10)
        XCTAssertNotNil(nothing)
        StubProtocol.reset { s in ModelDownloadTests.served(s, data: files["/m/off.qle"]!) }
        let off = await get("cdn.test", "/m/off.qle", size: 1000)
        XCTAssertNil(off)

        let hosts = try XCTUnwrap(store.pending.last?.hosts)
        XCTAssertEqual(Set(hosts.keys), [Self.a, Self.b], "hosts of the allow-list only")
        let ha = try XCTUnwrap(hosts[Self.a]), hb = try XCTUnwrap(hosts[Self.b])
        XCTAssertEqual(ha.files, 1, "the whole file's last byte came from the first host")
        XCTAssertEqual(ha.bytes, Int64(300 << 10) + 40_000)
        XCTAssertEqual(ha.requests, 4)
        XCTAssertEqual(ha.unreachable, 3, "the cut, the 503 and the request with no answer")
        XCTAssertEqual(ha.ttfb.reduce(0, +), 3, "three requests got a status")
        XCTAssertEqual(ha.ttfb[3], 1, "the held one between 500 and 1000 ms: \(ha.ttfb)")
        XCTAssertEqual(ha.kbps.reduce(0, +), 1, "one transfer of at least 256 KiB")
        XCTAssertEqual([ha.hedged, ha.slowSwitches, hb.hedged, hb.slowSwitches], [0, 0, 0, 0], "always 0 in 4.0.2")
        XCTAssertEqual(hb.files, 2, "the resumed file and the one the first host failed")
        XCTAssertEqual(hb.bytes, 110_000)
        XCTAssertEqual(hb.requests, 2)
        XCTAssertEqual(hb.unreachable, 0)
        XCTAssertEqual(hb.ttfb.reduce(0, +), 2)
        XCTAssertEqual(hb.kbps.reduce(0, +), 0, "no transfer of 256 KiB")

        // the switch is off: the day's delta carries no `hosts`; on, it does, and the body is one the contract accepts
        store.record(.modelLoaded(revision: "4.0.0", milliseconds: 12, cohort: PromotionTests.cohort))
        store.seal()
        let offBody = try XCTUnwrap(store.sealed.last.flatMap { try JSONSerialization.jsonObject(with: $0.body) as? [String: Any] })
        XCTAssertNil(offBody["hosts"], "not sent while the switch is off")
        AnalyticsStore.sendsHostCounts.withLock { $0 = true }
        StubProtocol.reset { s in ModelDownloadTests.served(s, data: files["/m/off.qle"]!) }
        _ = await get(Self.a, "/m/off.qle", size: 1000)
        store.seal()
        let on = try XCTUnwrap(store.sealed.last.flatMap { try JSONSerialization.jsonObject(with: $0.body) as? [String: Any] })
        let sent = try XCTUnwrap(on["hosts"] as? [[String: Any]])
        XCTAssertEqual(sent.map { $0["host"] as? String }, [Self.a])
        XCTAssertNil(Self.refusal(sent), "the body the SDK builds is one the server takes")
    }

    /// Contract 0d9f5d7: the build's manifest counts as one of `files` on the host it came from, with its request and
    /// its bytes; the host that failed it counts its request, unreachable.
    func testTheManifestCountsAsAFileOnItsHost() async throws {
        let store = AnalyticsStore(storage: CloudFixtures.storage(), enabled: true,
                                   context: .init(platform: "ios", sdkVersion: "4.0.2", appVersion: "2.1", deviceClass: "A17", soc: "a17",
                                                  osMajor: 18, ramTier: "8_16"))
        let e = EndpointSet(api: EndpointSet.builtInOrigins(.api),
                            models: [try XCTUnwrap(URL(string: "https://\(Self.a)")), try XCTUnwrap(URL(string: "https://\(Self.b)"))])
        let http = HTTPClient(session: StubProtocol.session(), endpoints: e)
        http.modelHosts.withLock { $0 = { s in store.record(.modelHost(s)) } }
        let manifest = Data("{\"model_id\":\"v4.0\"}".utf8)
        StubProtocol.reset { s in
            s.url.host == Self.a ? .json(["error": "unavailable"], status: 503)
                : StubProtocol.Reply(status: 200, headers: ["content-type": "application/json"], body: manifest)
        }
        _ = try await http.checked(URLRequest(url: try XCTUnwrap(URL(string: "https://\(Self.a)/models/x/sdk/v4.0/manifest.json"))), role: .models)
        let hosts = try XCTUnwrap(store.pending.last?.hosts)
        let ha = try XCTUnwrap(hosts[Self.a]), hb = try XCTUnwrap(hosts[Self.b])
        XCTAssertEqual([ha.requests, ha.unreachable, ha.files], [1, 1, 0], "the host that failed it")
        XCTAssertEqual([hb.requests, hb.unreachable, hb.files], [1, 0, 1], "the host it came from: one of files")
        XCTAssertEqual(hb.bytes, Int64(manifest.count))
        XCTAssertEqual(hb.ttfb.reduce(0, +), 1)
        XCTAssertEqual(hb.kbps.reduce(0, +), 0, "a small read has no rate")
    }

    /// Contract ec46782: with telemetry off in the signed config nothing is counted; a request its caller cancelled is
    /// counted as a request, without a status, and never as unreachable.
    func testNothingIsCountedWithTelemetryOffAndACancelIsNotUnreachable() async throws {
        let body = Data(repeating: 1, count: 1000)
        StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(flags: ["analytics": false]), extra: { s in
            s.path == "/m/f.qle" ? StubProtocol.Reply(status: 200, headers: [:], body: body) : nil
        }))
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage())
        _ = await cloud.refreshConfig()
        XCTAssertEqual(cloud.config.current?.flags.analytics, false)
        let part = CloudFixtures.storage().appendingPathComponent("f.part")
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let url = try XCTUnwrap(URL(string: "https://\(Self.a)/m/f.qle"))
        _ = try? await cloud.http.stream(URLRequest(url: url), offset: 0, size: 1000, into: part, started: { _, _ in }, received: { _ in })
        XCTAssertEqual(StubProtocol.seen("/m/f.qle").count, 1)
        XCTAssertTrue(cloud.analytics.pending.allSatisfy { $0.hosts == nil }, "telemetry off: nothing counted")

        let samples = Locked<[ModelHostSample]>([])
        let http = HTTPClient(session: StubProtocol.session())
        http.modelHosts.withLock { $0 = { s in samples.withLock { $0.append(s) } } }
        let gate = StubProtocol.Gate()
        StubProtocol.reset { _ in
            var r = StubProtocol.Reply(status: 200, headers: [:], body: body)
            r.hold = gate
            return r
        }
        let other = CloudFixtures.storage().appendingPathComponent("g.part")
        FileManager.default.createFile(atPath: other.path, contents: nil)
        let call = Task { () -> CloudError? in
            do throws(CloudError) {
                _ = try await http.stream(URLRequest(url: url), offset: 0, size: 1000, into: other, started: { _, _ in }, received: { _ in })
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        call.cancel()
        let failure = await call.value
        gate.open()
        XCTAssertNotNil(failure)
        let got = samples.withLock { $0 }
        XCTAssertEqual(got.count, 1, "the request counts")
        XCTAssertEqual(got.first?.unreachable, false, "a cancel is never unreachable")
        XCTAssertNil(got.first?.ttfbMs, "no status came")
    }

    /// The contract's `telemetry` vectors: every accepted body is one the SDK builds from the same counts (and passes
    /// the server's rules as the test reads them); every refused one fails those rules, and the SDK's builder never
    /// makes it from any counts (a host off the allow-list is left out, at most 8 hosts, fixed fields and buckets,
    /// no count below 0).
    func testTheContractsVectors() throws {
        // the bodies with section 35's fields, as once the server takes them
        AnalyticsStore.sendsSplitFields.withLock { $0 = true }
        defer { AnalyticsStore.sendsSplitFields.withLock { $0 = false } }
        let t = try XCTUnwrap(try V40.json("steering_40.json")["telemetry"] as? [String: Any])
        XCTAssertEqual(t["ttfb_buckets_ms"] as? [Double], HostCount.ttfbBounds)
        XCTAssertEqual(t["kbps_buckets"] as? [Double], HostCount.kbpsBounds)
        let cases = try XCTUnwrap(t["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 36, "every case of the file is read")
        XCTAssertEqual(t["fail_keys"] as? [String], FailClass.keys, "34.9.1's classes in the server's order")
        XCTAssertEqual(t["proto_keys"] as? [String], FailClass.protos)
        XCTAssertEqual(t["move_why"] as? [String], FailClass.moveWhy, "34.9.7's reasons of a move")
        XCTAssertEqual(t["moves_max"] as? Int, HostCount.movesMax)
        XCTAssertEqual(t["outcome_keys"] as? [String], FailClass.outcomeKeys)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let hosts = try XCTUnwrap(c["hosts"] as? [[String: Any]], name)
            let accepted = try XCTUnwrap(c["accepted"] as? Bool, name)
            XCTAssertEqual(Self.refusal(hosts) == nil, accepted, "\(name): \(Self.refusal(hosts) ?? "taken")")
            // the SDK's builder from the same counts
            var counts: [String: HostCount] = [:]
            for h in hosts {
                guard let host = h["host"] as? String else { continue }
                var x = HostCount()
                x.files = h["files"] as? Int ?? 0
                x.bytes = Int64(h["bytes"] as? Int ?? 0)
                x.requests = h["requests"] as? Int ?? 0
                x.unreachable = h["unreachable"] as? Int ?? 0
                x.hedged = h["hedged"] as? Int ?? 0
                x.slowSwitches = h["slow_switches"] as? Int ?? 0
                x.ttfb = h["ttfb_ms"] as? [Int] ?? []
                x.kbps = h["kbps"] as? [Int] ?? []
                x.fail = (h["fail"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Int }
                x.proto = (h["proto"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Int }
                // 34.9.7
                for m in h["moves"] as? [[String: Any]] ?? [] {
                    guard let to = m["to"] as? String, let why = m["why"] as? String, let n = m["n"] as? Int, n > 0 else { continue }
                    // as the counter keeps them: each (to, why) once
                    if let i = x.moves.firstIndex(where: { $0.to == to && $0.why == why }) { x.moves[i].n += n } else { x.moves.append(.init(to: to, why: why, n: n)) }
                }
                if let o = h["outcome"] as? [String: Any] {
                    x.outcome.moved = o["moved"] as? Int ?? 0
                    x.outcome.failed = (o["failed"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Int }
                    x.outcome.cancelled = o["cancelled"] as? Int ?? 0
                    x.outcome.paused = o["paused"] as? Int ?? 0
                    x.outcome.ready = o["ready"] as? Int ?? 0
                    x.outcome.notReady = o["not_ready"] as? Int ?? 0
                }
                counts[host] = x
            }
            // 34.9.4: an entry whose `day_first` is 0 had a body of its day before it
            let sealedBefore = Set(hosts.filter { ($0["day_first"] as? Int) == 0 }.compactMap { $0["host"] as? String })
            let built = HostCount.body(counts, sealedBefore: sealedBefore)
            XCTAssertNil(Self.refusal(built), "\(name): the SDK never builds a body the server refuses")
            if accepted {
                // SDK 4.0.5: the entry is 34.6's with 34.9.1's three fields (`fail` and `proto` without their zeros) and
                // the five of section 35 (all 0 here); a vector entry of an SDK before 4.0.4 is compared without 34.9's
                func plain(_ e: [String: Any], keep349: Bool) -> NSDictionary {
                    var x = e.filter { !Self.splitFields.contains($0.key) && (keep349 || !Self.fields349.contains($0.key)) }
                    for k in ["fail", "proto"] {
                        if let m = x[k] as? [String: Int] { x[k] = m.filter { $0.value != 0 } }
                    }
                    // 34.9.7: empty moves and an empty outcome are the same as none; a key left out of outcome is 0
                    if (x["moves"] as? [Any])?.isEmpty == true { x["moves"] = nil }
                    if var o = x["outcome"] as? [String: Any] {
                        if var f = o["failed"] as? [String: Int] {
                            f = f.filter { $0.value != 0 }
                            o["failed"] = f.isEmpty ? nil : f
                        }
                        o = o.filter { ($0.value as? Int).map { $0 != 0 } ?? true }
                        x["outcome"] = o.isEmpty ? nil : o
                    }
                    return NSDictionary(dictionary: x)
                }
                let want = Dictionary(uniqueKeysWithValues: hosts.map { ($0["host"] as? String ?? "", plain($0, keep349: true)) })
                let got = Dictionary(uniqueKeysWithValues: built.map { e -> (String, NSDictionary) in
                    let host = e["host"] as? String ?? ""
                    let theirs = hosts.first { $0["host"] as? String == host }
                    return (host, plain(e, keep349: theirs?["fail"] != nil))
                })
                XCTAssertEqual(got, want, "\(name): the same body")
                for e in built {
                    XCTAssertEqual(Set(e.keys).intersection(Self.fields349), Self.fields349, "\(name): the three fields of 34.9.1")
                    XCTAssertEqual(Set(e.keys).intersection(Self.splitFields), Self.splitFields, "\(name): the five fields of 35.9")
                    XCTAssertEqual(e["probes"] as? Int, 0)
                    XCTAssertEqual(e["gain"] as? [Int], [0, 0, 0, 0, 0, 0])
                }
            }
        }
    }

    /// The server's rules for `hosts` as 34.6 and its vectors state them: at most 8 entries, each host once and of the
    /// allow-list, role `models`, exactly the fields of 34.6, counts whole and at least 0, 9 and 10 buckets. Nil when
    /// taken, else why not.
    /// SDK 4.0.5 (SPLIT_40 35.9): the fields of section 35, optional to the server, all five in every 4.0.5 entry.
    static let splitFields: Set<String> = ["probes", "would_probe", "gain", "wasted", "arms"]
    /// SDK 4.0.5 (STEERING_40 34.9.1): the three fields of the 4.0.4 erratum, optional to the server, all three in every
    /// entry from 4.0.4. 34.9.7's `moves` and `outcome` are two more optional fields, each left out when empty, so not
    /// among them (28de700 had them here, and the vector test asked every entry for them).
    static let fields349: Set<String> = ["fail", "proto", "day_first"]

    /// A JSON number that is a boolean (`true` decodes as an NSNumber).
    static func isBool(_ v: Any) -> Bool { (v as AnyObject) is NSNumber && CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() }

    static func refusal(_ hosts: [[String: Any]]) -> String? {
        let fields: Set<String> = ["role", "host", "files", "bytes", "requests", "unreachable", "hedged", "slow_switches", "ttfb_ms", "kbps"]
        guard hosts.count <= 8 else { return "more than 8 entries" }
        var seen: Set<String> = []
        var movesInBody = 0
        defer { _ = movesInBody }
        for h in hosts {
            let keys = Set(h.keys)
            guard fields.isSubset(of: keys), keys.isSubset(of: fields.union(splitFields).union(fields349).union(["moves", "outcome"])) else { return "other fields" }
            // qlab-api HOSTS_SPEC: `fail` and `proto` closed objects of whole counts to 10,000,000 (a key left out is 0),
            // `day_first` the number 0 or 1
            for (k, allowed) in [("fail", FailClass.keys), ("proto", FailClass.protos)] where h[k] != nil {
                guard let m = h[k] as? [String: Any], Set(m.keys).isSubset(of: Set(allowed)),
                      m.values.allSatisfy({ !isBool($0) && ($0 as? Int).map { (0...10_000_000).contains($0) } == true }) else { return k }
            }
            if let d = h["day_first"] {
                guard !isBool(d), let n = d as? Int, n == 0 || n == 1 else { return "day_first" }
            }
            // 34.9.7 (qlab-api dl-moves-404): moves items exactly {to, why, n}, `to` another host of the allow-list, `why` a
            // class, slow or hedge, n from 1, each (to, why) once; outcome closed, `failed` of the 15 classes
            if let mv = h["moves"] {
                guard let mv = mv as? [[String: Any]] else { return "moves" }
                var pairs: Set<String> = []
                for m in mv {
                    guard Set(m.keys) == ["to", "why", "n"], let to = m["to"] as? String, Endpoints.hostAllowed(to), to != h["host"] as? String,
                          let why = m["why"] as? String, FailClass.moveWhy.contains(why), !isBool(m["n"] as Any),
                          let n = m["n"] as? Int, (1...10_000_000).contains(n), pairs.insert(to + " " + why).inserted else { return "a move" }
                }
                movesInBody += mv.count
            }
            if let o = h["outcome"] {
                guard let o = o as? [String: Any], Set(o.keys).isSubset(of: Set(FailClass.outcomeKeys)) else { return "outcome" }
                for (k, v) in o {
                    if k == "failed" {
                        guard let f = v as? [String: Any], Set(f.keys).isSubset(of: Set(FailClass.keys)),
                              f.values.allSatisfy({ !isBool($0) && ($0 as? Int).map { (0...10_000_000).contains($0) } == true }) else { return "outcome.failed" }
                    } else {
                        guard !isBool(v), let n = v as? Int, (0...10_000_000).contains(n) else { return "an outcome count" }
                    }
                }
            }
            // qlab-api HOSTS_SPEC (sdk-4.0.5-smart-download): each of 35.9 a whole count to 10,000,000, `gain` 6 of them,
            // `arms` two pairs
            if !keys.isDisjoint(with: splitFields) {
                for k in ["probes", "would_probe", "wasted"] where h[k] != nil {
                    guard let n = h[k] as? Int, (0...10_000_000).contains(n) else { return "a count of 35.9" }
                }
                if let g = h["gain"] {
                    guard let g = g as? [Int], g.count == 6, g.allSatisfy({ (0...10_000_000).contains($0) }) else { return "gain" }
                }
                if let a = h["arms"] {
                    guard let a = a as? [String: [Int]], Set(a.keys).isSubset(of: ["count", "acted"]),
                          a.values.allSatisfy({ $0.count == 2 && $0.allSatisfy { (0...10_000_000).contains($0) } }) else { return "arms" }
                }
            }
            guard h["role"] as? String == "models" else { return "another role" }
            guard let host = h["host"] as? String, Endpoints.hostAllowed(host) else { return "a host off the allow-list" }
            guard seen.insert(host).inserted else { return "the same host twice" }
            for k in ["files", "bytes", "requests", "unreachable", "hedged", "slow_switches"] {
                guard let n = h[k] as? Int, n >= 0 else { return "a count below 0" }
            }
            guard let ttfb = h["ttfb_ms"] as? [Int], ttfb.count == 9, ttfb.allSatisfy({ $0 >= 0 }),
                  let kbps = h["kbps"] as? [Int], kbps.count == 10, kbps.allSatisfy({ $0 >= 0 }) else { return "the buckets" }
        }
        if movesInBody > HostCount.movesMax { return "more than 32 moves" }
        return nil
    }
}
