import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5, contract section 35 (`sdk_4.0.0/SPLIT_40.md`): `split_40.json` replayed through `SplitDecide`. Each case
/// builds a decide from its `init`, feeds its `events` in order, and compares what each event returns with the case's
/// `actions` ([event index, actions], none where an index is absent), then the memory with `memory_after`. The test
/// fails when it read fewer cases than the file holds (35.10).
final class SplitVectorTests: XCTestCase {
    static func vectors() throws -> [String: Any] { try V40.json("split_40.json") }

    func testTheConstantsAreTheContracts() throws {
        let c = try XCTUnwrap(try Self.vectors()["constants"] as? [String: Int])
        typealias K = SplitConstants
        let mine: [String: Int] = [
            "TICK_MS": K.tickMs, "WARMUP_MS": K.warmupMs, "WINDOW_MS": K.windowMs, "ETA_MIN_MS": K.etaMinMs,
            "LEFT_MIN": K.leftMin, "STALL_MS": K.stallMs, "FLOOR_BPS": K.floorBps, "GAIN_MIN_X100": K.gainMinX100,
            "STEAL_MIN": K.stealMin, "STEAL_ETA_MIN_MS": K.stealEtaMinMs, "MAX_STEALS": K.maxSteals, "MAX_HOSTS": K.maxHosts,
            "MAX_HOST_CHANGES": K.maxHostChanges, "ALIGN": K.align, "PHONE_BOUND_MS": K.phoneBoundMs,
        ]
        XCTAssertEqual(c, mine)
        XCTAssertEqual(try Self.vectors()["gain_buckets_x100"] as? [Int], K.gainBucketsX100)
    }

    func testEveryCaseReplays() throws {
        let cases = try XCTUnwrap(try Self.vectors()["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 25, "every case of the file is read")
        var replayed = 0
        for c in cases {
            try replay(c)
            replayed += 1
        }
        XCTAssertEqual(replayed, cases.count)
    }

    private func replay(_ c: [String: Any]) throws {
        let name = c["name"] as? String ?? "?"
        let i = try XCTUnwrap(c["init"] as? [String: Any], name)
        let mem = i["memory"] as? [String: Any] ?? [:]
        let memory = SplitMemory(winner: mem["winner"] as? [String: String] ?? [:],
                                 phoneBoundUntil: mem["phone_bound_until"] as? [String: Int] ?? [:],
                                 bad: mem["bad"] as? [String] ?? [])
        let d = SplitDecide(size: try XCTUnwrap(i["size"] as? Int, name), order: try XCTUnwrap(i["order"] as? [String], name),
                            noHelper: i["no_helper"] as? [String] ?? [], shareOn: i["share_on"] as? Bool ?? true,
                            memory: memory, conn: i["conn"] as? String ?? "cellular")
        var want: [Int: [SplitAction]] = [:]
        for entry in try XCTUnwrap(c["actions"] as? [[Any]], name) {
            let k = try XCTUnwrap(entry[0] as? Int, name)
            want[k] = try XCTUnwrap(entry[1] as? [[Any]], name).map { try Self.action($0) }
        }
        let events = try XCTUnwrap(c["events"] as? [[Any]], name)
        for (k, e) in events.enumerated() {
            let got = d.event(try Self.event(e))
            guard got == (want[k] ?? []) else {
                XCTFail("\(name): event \(k) \(e): got \(got), want \(want[k] ?? [])")
                return
            }
        }
        let after = try XCTUnwrap(c["memory_after"] as? [String: Any], name)
        let snap = memory.snapshot
        XCTAssertEqual(snap.winner, after["winner"] as? [String: String] ?? [:], "\(name): the winner")
        XCTAssertEqual(snap.phoneBoundUntil, after["phone_bound_until"] as? [String: Int] ?? [:], "\(name): the phone-bound hold")
        XCTAssertEqual(snap.bad, after["bad"] as? [String] ?? [], "\(name): the bad hosts")
    }

    static func event(_ e: [Any]) throws -> SplitEvent {
        let kind = try XCTUnwrap(e[0] as? String)
        let t = try XCTUnwrap(e[1] as? Int)
        func s(_ i: Int) throws -> String { try XCTUnwrap(e[i] as? String, "\(e)") }
        func n(_ i: Int) throws -> Int { try XCTUnwrap(e[i] as? Int, "\(e)") }
        switch kind {
        case "main": return .main(t: t, id: try s(2), host: try s(3), lo: try n(4))
        case "req": return .req(t: t, id: try s(2), host: try s(3), lo: try n(4), end: try n(5))
        case "host_out": return .hostOut(t: t, host: try s(2), why: try s(3))
        case "status": return .status(t: t, id: try s(2), kind: try s(3))
        case "bytes": return .bytes(t: t, id: try s(2), n: try n(3))
        case "lane": return .lane(t: t, host: try s(2), n: try n(3))
        case "end": return .end(t: t, id: try s(2), how: try s(3))
        case "tick": return .tick(t: t)
        case "hash": return .hash(t: t, ok: try XCTUnwrap(e[2] as? Bool))
        default: throw XCTSkip("unknown event \(kind)")
        }
    }

    static func action(_ a: [Any]) throws -> SplitAction {
        let kind = try XCTUnwrap(a[0] as? String)
        func s(_ i: Int) throws -> String { try XCTUnwrap(a[i] as? String, "\(a)") }
        func n(_ i: Int) throws -> Int { try XCTUnwrap(a[i] as? Int, "\(a)") }
        switch kind {
        case "start": return .start(id: try s(1), host: try s(2), lo: try n(3), end: try n(4))
        case "cut": return .cut(id: try s(1), at: try n(2))
        case "resume": return .resume(lo: try n(1), end: try n(2))
        case "verdict": return .verdict(kind: try s(1), ratio: try n(2))
        case "p": return .p(host: try s(1))
        case "count": return .count(field: try s(1), host: try s(2), n: try n(3))
        case "refused": return .refused
        case "restart": return .restart
        default: throw XCTSkip("unknown action \(kind)")
        }
    }
}

/// SDK 4.0.5: a model request its caller cancels is no answer of its host. Red on 4.0.3, where the
/// cancel moved the file to the next host and told a failover (`lastFailover`), so the app's leaving or the call's
/// cancel sent the next attempt elsewhere.
final class CancelIsNoFailoverTests: XCTestCase {
    override func tearDown() {
        StubProtocol.reset { _ in .down }
    }

    func testACancelledRangeStaysOnItsHostAndTellsNoFailover() async throws {
        let body = Data(repeating: 7, count: 4096)
        var stalls = StubProtocol.Reply(status: 206, headers: ["content-type": "application/octet-stream",
                                                               "content-range": "bytes 0-4095/4096"], body: body)
        stalls.stallAfter = 1024
        let held = stalls
        StubProtocol.reset { _ in held }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let endpoints = EndpointSet(api: EndpointSet.builtInOrigins(.api), models: EndpointSet.builtInOrigins(.models), clock: { now })
        let client = CDNClient(http: HTTPClient(session: StubProtocol.session(), endpoints: endpoints), base: ModelHost.defaultBase,
                               auth: .fixed(key: "qlk_v1_test", token: "qlt_test"),
                               verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
        let base = try XCTUnwrap(URL(string: "https://cdn.quranlab.ai/models/Quran-Lab/m/b/sdk/v4.0/"))
        let source = client.source(ModelID("v4.0", repository: "Quran-Lab/m"), revision: "b", base: base)
        let hosts = try XCTUnwrap(source.hosts)
        let first = hosts.host(for: "f.qle")
        let part = CloudFixtures.storage().appendingPathComponent("f.part")
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let call = Task { () -> RecognizerError? in
            do throws(RecognizerError) {
                _ = try await source.stream("f.qle", lower: 0, upper: 4095, size: 4096, validator: nil, into: part, hash: nil,
                                            started: { _, _ in }, received: { _ in })
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        call.cancel()
        let failure = await call.value
        XCTAssertNotNil(failure, "the cancelled request ends")
        XCTAssertEqual(hosts.host(for: "f.qle"), first, "the file stays on its host")
        XCTAssertNil(endpoints.lastFailover, "no failover is told")
        XCTAssertFalse(hosts.fellBack, "one host was asked")
    }
}

/// SDK 4.0.5: the switch in the signed config, read so that nothing malformed fails a config.
final class DownloadSplitFlagTests: XCTestCase {
    private func flags(_ json: String) throws -> RemoteConfig.Flags {
        try JSONDecoder().decode(RemoteConfig.Flags.self, from: Data(json.utf8))
    }

    func testTheSwitchIsReadAndAnythingMalformedIsShareZero() throws {
        let f = try flags(#"{"download_split": {"share": 25, "no_helper": ["cdn3.quranlab.ai", "CDN-G.tajweedformer.com", "evil.example.com", 7, "cdn3.quranlab.ai"]}}"#)
        XCTAssertEqual(f.download_split.share, 25)
        XCTAssertEqual(f.download_split.no_helper, ["cdn3.quranlab.ai", "cdn-g.tajweedformer.com"], "allow-listed, lower case, once")
        XCTAssertEqual(try flags("{}").download_split, DownloadSplit(), "absent: share 0, no host")
        for bad in [#"{"share": 101}"#, #"{"share": -1}"#, #"{"share": 2.5}"#, #"{"share": "25"}"#, #"[25]"#, #"25"#, "null"] {
            XCTAssertEqual(try flags(#"{"download_split": \#(bad)}"#).download_split.share, 0, bad)
        }
    }

    func testTheShareIsADrawOfTheDeviceValueAndTheDay() {
        let seed = Data(repeating: 7, count: 16)
        XCTAssertFalse(DownloadSplit(.object(["share": .number(0)])).inShare(seed: seed, day: "2026-11-23"))
        XCTAssertTrue(DownloadSplit(.object(["share": .number(100)])).inShare(seed: seed, day: "2026-11-23"))
        // about a quarter of the days are in at 25
        let quarter = DownloadSplit(.object(["share": .number(25)]))
        let inDays = (1...400).filter { quarter.inShare(seed: seed, day: "day-\($0)") }.count
        XCTAssertTrue((60...140).contains(inDays), "\(inDays) of 400")
    }
}
