import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5, contract section 38 (`CONTINUITY_40.md`): every case of `vectors/continuity_40.json` (copied into
/// Fixtures/vectors40, SOURCE.txt) through the SDK's rules (`ContinuityRules`). Each test fails when it reads fewer
/// cases than the file holds (38.10). `relaunch` and `leave` are replayed for every platform the file has: the rules are
/// one function, and Apple's own cases (iOS tasks, its hand-over) are among them.
final class ContinuityVectorTests: XCTestCase {
    static func vectors() throws -> [String: Any] { try V40.json("continuity_40.json") }

    static func cases(_ name: String, _ count: Int) throws -> [[String: Any]] {
        let c = try XCTUnwrap(try vectors()[name] as? [[String: Any]], name)
        XCTAssertEqual(c.count, count, "every case of \(name) is read")
        return c
    }

    static func canonical(_ v: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]), as: UTF8.self)
    }

    func testTheConstants() throws {
        let v = try Self.vectors()
        XCTAssertEqual(v["format"] as? Int, 1)
        let c = try XCTUnwrap(v["constants"] as? [String: Any])
        XCTAssertEqual(c["PIECE"] as? Int, ContinuityRules.piece)
        XCTAssertEqual(c["PROBE_MS"] as? Int, ContinuityRules.probeMs)
        XCTAssertEqual(c["STALL_MS"] as? Int, ContinuityRules.stallMs)
        XCTAssertEqual(c["RESUME_MS_BOUNDS"] as? [Int], ContinuityRules.resumeMsBounds)
        XCTAssertEqual(c["KINDS"] as? [String], ContinuityRules.kinds)
        XCTAssertEqual(c["RESTART_WHY"] as? [String], ContinuityRules.restartWhy)
        XCTAssertEqual(c["CONTINUED"] as? [String], ContinuityRules.continued)
    }

    // MARK: reading the states

    static func spans(_ v: Any?) -> [ContinuityRules.Span] {
        ((v as? [[Int]]) ?? []).compactMap { $0.count == 2 ? ContinuityRules.Span($0[0], $0[1]) : nil }
    }

    static func validator(_ v: Any?) -> ContinuityRules.Validator? {
        guard let o = v as? [String: Any], let e = o["etag"] as? String, let h = o["host"] as? String, let end = o["end"] as? Int else { return nil }
        return ContinuityRules.Validator(etag: e, host: h, end: end)
    }

    static func relaunchFile(_ f: [String: Any]) throws -> ContinuityRules.RelaunchFile {
        var x = ContinuityRules.RelaunchFile(path: try XCTUnwrap(f["path"] as? String), size: try XCTUnwrap(f["size"] as? Int))
        x.have = spans(f["have"])
        x.validator = validator(f["validator"])
        if let b = f["beside"] as? [String: Any], let bytes = b["bytes"] as? Int, let e = b["etag"] as? String, let h = b["host"] as? String {
            x.beside = ContinuityRules.Validator(etag: e, host: h, end: bytes)
        }
        x.mapOK = (f["map_ok"] as? Bool) ?? true
        x.full = f["full"] as? String
        for t in (f["tasks"] as? [[String: Any]]) ?? [] {
            x.tasks.append(ContinuityRules.KeptTask(lo: try XCTUnwrap(t["lo"] as? Int), hi: try XCTUnwrap(t["hi"] as? Int),
                                                    state: try XCTUnwrap(t["state"] as? String), exact: (t["exact"] as? Bool) ?? true,
                                                    delivered: (t["delivered"] as? Bool) ?? false))
        }
        return x
    }

    static func relaunchState(_ s: [String: Any]) throws -> ContinuityRules.RelaunchState {
        let config = try XCTUnwrap(s["config"] as? [String: Any])
        var st = ContinuityRules.RelaunchState(p: try XCTUnwrap(config["p"] as? String))
        st.platform = (s["platform"] as? String) ?? "apple"
        st.stop = (s["stop"] as? Bool) ?? false
        st.token = (s["token"] as? String) ?? "valid"
        st.network = (s["network"] as? String) ?? "up"
        st.lease = (s["lease"] as? String) ?? "held"
        st.builds = (config["builds"] as? [String: String]) ?? [:]
        for d in (s["owed"] as? [[String: Any]]) ?? [] {
            st.owed.append(ContinuityRules.Owed(build: try XCTUnwrap(d["build"] as? String), context: try XCTUnwrap(d["context"] as? String),
                                                kind: try XCTUnwrap(d["kind"] as? String), by: try XCTUnwrap(d["by"] as? String),
                                                source: (d["source"] as? String) ?? "record",
                                                files: try XCTUnwrap(d["files"] as? [[String: Any]]).map(relaunchFile)))
        }
        return st
    }

    static func json(_ r: ContinuityRules.Request) -> [Any] {
        [r.path, r.host, r.range.map { $0 as Any } ?? NSNull(), r.ifRange.map { $0 as Any } ?? NSNull()]
    }

    static func json(_ a: ContinuityRules.Action) -> [Any] {
        switch a {
        case .removeModels: return ["remove_models"]
        case .dropOwed(let b, let why): return why.map { ["drop_owed", b, $0] } ?? ["drop_owed", b]
        case .waitNetwork: return ["wait_network"]
        case .token(let t): return ["token", t]
        case .lease(let l): return ["lease", l]
        case .owe(let b, let k): return ["owe", b, k]
        case .manifest(let b): return ["manifest", b]
        case .takeBeside(let p): return ["take_beside", p]
        case .restart(let p, let why): return ["restart", p, why]
        case .adopt(let p, let lo, let hi): return ["adopt", p, lo, hi]
        case .keepTask(let p, let lo, let hi): return ["keep_task", p, lo, hi]
        case .cancelTask(let p, let lo, let hi): return ["cancel_task", p, lo, hi]
        case .hash(let p): return ["hash", p]
        case .place(let p): return ["place", p]
        case .request(let r): return ["request"] + json(r)
        case .count(let f, let n): return ["count", f, n]
        }
    }

    static func json(_ a: ContinuityRules.LeaveAction) -> [Any] {
        switch a {
        case .cancelRequest(let p, let at): return ["cancel_request", p, at]
        case .task(let r): return ["task"] + json(r)
        case .work(let policy, let expedited, let network): return ["work", policy, expedited, network]
        case .flush(let p, let at): return ["flush", p, at]
        case .count(let f, let n): return ["count", f, n]
        }
    }

    // MARK: 38.4, 38.5

    func testRelaunch() throws {
        var names: [String] = []
        for c in try Self.cases("relaunch", 23) {
            let name = try XCTUnwrap(c["name"] as? String)
            names.append(name)
            let got = ContinuityRules.relaunch(try Self.relaunchState(try XCTUnwrap(c["state"] as? [String: Any], name)))
            XCTAssertEqual(try Self.canonical(got.map(Self.json)), try Self.canonical(try XCTUnwrap(c["actions"], name)), name)
        }
        XCTAssertEqual(Set(names).count, 23)
        // Apple's own: iOS tasks finished, running with bytes, running silent, cancelled, not exactly their range
        for n in ["ios_task_done_while_dead", "ios_task_running_delivers", "ios_task_running_silent", "ios_force_quit", "task_done_not_exact"] {
            XCTAssertTrue(names.contains(n), n)
        }
    }

    func testLeave() throws {
        var platforms: [String] = []
        for c in try Self.cases("leave", 6) {
            let name = try XCTUnwrap(c["name"] as? String)
            let s = try XCTUnwrap(c["state"] as? [String: Any], name)
            let platform = try XCTUnwrap(s["platform"] as? String)
            platforms.append(platform)
            var downloads: [(kind: String, files: [ContinuityRules.LeaveFile])] = []
            for d in try XCTUnwrap(s["downloads"] as? [[String: Any]]) {
                var files: [ContinuityRules.LeaveFile] = []
                for f in try XCTUnwrap(d["files"] as? [[String: Any]]) {
                    var x = ContinuityRules.LeaveFile(path: try XCTUnwrap(f["path"] as? String), size: try XCTUnwrap(f["size"] as? Int))
                    x.have = Self.spans(f["have"])
                    x.validator = Self.validator(f["validator"])
                    if let r = f["running"] as? [String: Any], let h = r["host"] as? String, let at = r["at"] as? Int { x.running = (h, at) }
                    files.append(x)
                }
                downloads.append((try XCTUnwrap(d["kind"] as? String), files))
            }
            let got = ContinuityRules.leave(platform: platform, apiLevel: (s["api_level"] as? Int) ?? 0, p: try XCTUnwrap(s["p"] as? String),
                                            downloads: downloads)
            XCTAssertEqual(try Self.canonical(got.map(Self.json)), try Self.canonical(try XCTUnwrap(c["actions"], name)), name)
        }
        XCTAssertEqual(platforms.filter { $0 == "apple" }.count, 2, "iOS, and iOS in pieces of 64 MiB")
    }

    // MARK: 38.6, 38.3, 38.8

    func testTheFirstAnswer() throws {
        for c in try Self.cases("answer", 9) {
            let name = try XCTUnwrap(c["name"] as? String)
            let f = try XCTUnwrap(c["file"] as? [String: Any]), a = try XCTUnwrap(c["answer"] as? [String: Any])
            let got = ContinuityRules.firstAnswer(size: try XCTUnwrap(f["size"] as? Int), from: try XCTUnwrap(f["from"] as? Int),
                                                  ifRange: try XCTUnwrap(f["if_range"] as? Bool), single: try XCTUnwrap(f["single"] as? Bool),
                                                  status: try XCTUnwrap(a["status"] as? Int), start: a["start"] as? Int, end: a["end"] as? Int,
                                                  total: a["total"] as? Int, length: a["length"] as? Int)
            XCTAssertEqual([got.action], c["action"] as? [String], name)
            XCTAssertEqual(got.restarted, c["restarted"] as? String, name)
        }
    }

    func testTheLeaseAnswer() throws {
        for c in try Self.cases("lease", 12) {
            let confirmed = try XCTUnwrap(c["confirmed"] as? Bool), answer = try XCTUnwrap(c["answer"] as? String)
            XCTAssertEqual(ContinuityRules.leaseAnswer(confirmed: confirmed, answer: answer), c["actions"] as? [String], "\(confirmed) \(answer)")
        }
    }

    func testTheOwedRecord() throws {
        for c in try Self.cases("record", 9) {
            let how = try XCTUnwrap(c["stopped_by"] as? String)
            XCTAssertEqual(ContinuityRules.recordAfter(how), c["owed_record"] as? String, how)
        }
    }

    func testTelemetryAsTheServerChecksIt() throws {
        for c in try Self.cases("telemetry", 11) {
            let e = try XCTUnwrap(c["entry"] as? [String: Any])
            XCTAssertEqual(ContinuityRules.downloadsProblem(e), c["refused"] as? String, "\(e)")
        }
        for c in try Self.cases("resume_ms_buckets", 12) {
            XCTAssertEqual(ContinuityRules.resumeBucket(ms: try XCTUnwrap(c["ms"] as? Int)), c["bucket"] as? Int, "\(c)")
        }
    }
}
