import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5, contract section 30 (`LIVE_PROMOTION_41.md`): every case of `vectors/live_41.json` (format 2, copied
/// into Fixtures/vectors41, SOURCE.txt) through the SDK's rules (`LiveRules`) and its take decide (`LiveTake`). Each
/// test fails when it reads fewer cases than the file holds (30.11). `takes`: each take is built from its `init`, its
/// events are fed in order, and the actions returned after event i are compared with the entry `[i, actions]`.
final class LiveVectorTests: XCTestCase {
    static func vectors() throws -> [String: Any] {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "vectors41", withExtension: nil, subdirectory: "Fixtures"))
        let data = try Data(contentsOf: dir.appendingPathComponent("live_41.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The cases of a section, and that there are as many as the file of 9fa3085 holds.
    static func cases(_ name: String, _ count: Int) throws -> [[String: Any]] {
        let c = try XCTUnwrap(try vectors()[name] as? [[String: Any]], name)
        XCTAssertEqual(c.count, count, "every case of \(name) is read")
        return c
    }

    func testTheFormatAndTheConstants() throws {
        let v = try Self.vectors()
        XCTAssertEqual(v["format"] as? Int, 2)
        let c = try XCTUnwrap(v["constants"] as? [String: Any])
        XCTAssertEqual(c["RING_SECONDS"] as? Int, LiveRules.ringSeconds)
        XCTAssertEqual(c["LATEST_START_SECONDS"] as? Double, LiveRules.latestStartSeconds)
        XCTAssertEqual(c["SOURCE_LEFT_MIN_SECONDS"] as? Double, LiveRules.sourceLeftMinSeconds)
        XCTAssertEqual(c["SHADOW_MS"] as? Int, LiveRules.shadowMs)
        XCTAssertEqual(c["SHADOW_MIN_CHUNKS"] as? Int, LiveRules.shadowMinChunks)
        XCTAssertEqual(c["INEXACT_WINDOWS"] as? Int, LiveRules.inexactWindows)
        XCTAssertEqual(c["STEADY_CHUNKS"] as? Int, LiveRules.steadyChunks)
        XCTAssertEqual(c["PAUSE_FRAMES"] as? Int, LiveRules.pauseFrames)
        XCTAssertEqual(c["SWAP_CAP_MS"] as? Int, LiveRules.swapCapMs)
        XCTAssertEqual(c["STALL_WAIT_MS"] as? Int, LiveRules.stallWaitMs)
        XCTAssertEqual(c["BLANK"] as? Int, LiveRules.blank)
        XCTAssertEqual(v["reasons"] as? [String], LiveRules.reasons)
        XCTAssertEqual(v["held"] as? [String], LiveRules.held)
        XCTAssertEqual(v["outcomes"] as? [String], LiveRules.outcomes)
        XCTAssertEqual(v["latency_ms"] as? [String], LiveRules.latencyKeys)
        let contexts = try XCTUnwrap(v["contexts"] as? [String: [String: Int]])
        XCTAssertEqual(contexts.count, 4)
        for (ctx, x) in contexts {
            let ms = try XCTUnwrap(LiveRules.chunkMs(context: ctx), ctx)
            XCTAssertEqual(x["chunk_ms"], ms, ctx)
            XCTAssertEqual(x["advance_samples"], LiveRules.advance(chunkMs: ms), ctx)
            XCTAssertEqual(x["shadow_chunks"], LiveRules.shadowChunks(chunkMs: ms), ctx)
            XCTAssertEqual(x["swap_cap_chunks"], LiveRules.ceilDiv(LiveRules.swapCapMs, ms), ctx)
            XCTAssertEqual(x["stall_wait_chunks"], LiveRules.ceilDiv(LiveRules.stallWaitMs, ms), ctx)
        }
    }

    // MARK: 30.2

    static func device(_ c: [String: Any]) -> LiveRules.Device {
        var d = LiveRules.Device()
        if let v = c["low_power"] as? Bool { d.lowPower = v }
        if let v = c["battery"] as? Double { d.battery = v }
        if let v = c["charging"] as? Bool { d.charging = v }
        if let v = c["thermal"] as? String { d.thermal = v }
        if let v = c["finishing"] as? Bool { d.finishing = v }
        if let v = c["source_left_seconds"] as? Double { d.sourceLeftSeconds = v }
        return d
    }

    static func change(_ c: [String: Any]) -> LiveRules.DeviceChange {
        LiveRules.DeviceChange(lowPower: c["low_power"] as? Bool, battery: c["battery"] as? Double, charging: c["charging"] as? Bool,
                               thermal: c["thermal"] as? String, finishing: c["finishing"] as? Bool,
                               sourceLeftSeconds: c["source_left_seconds"] as? Double)
    }

    func testStart() throws {
        for c in try Self.cases("start", 21) {
            let x = try XCTUnwrap(c["conditions"] as? [String: Any])
            var k = LiveRules.Conditions()
            k.flagOn = LiveRules.flagOn(x["flag"])
            k.appCPU = (x["app_cpu"] as? Bool) ?? false
            k.onCPU = (x["on_cpu"] as? Bool) ?? true
            k.attempted = (x["attempted"] as? Bool) ?? false
            k.failedOver = (x["failed_over"] as? Bool) ?? false
            k.stall = (x["stall"] as? Bool) ?? false
            k.takeSeconds = (x["take_seconds"] as? Double) ?? 0
            k.device = Self.device(x)
            let why = LiveRules.start(k)
            XCTAssertEqual(why == nil, c["starts"] as? Bool, "\(x)")
            XCTAssertEqual(why, c["reason"] as? String, "\(x)")
        }
    }

    // MARK: 30.3, 30.4

    func testReplay() throws {
        for c in try Self.cases("replay", 8) {
            let ctx = try XCTUnwrap(c["context"] as? String)
            // the generator's dict spread writes the plan's `samples` (replayed) over the take's: the take had
            // from_sample + samples so far
            let from = try XCTUnwrap(c["from_sample"] as? Int), replayed = try XCTUnwrap(c["samples"] as? Int)
            let p = LiveRules.replayPlan(chunkMs: try XCTUnwrap(LiveRules.chunkMs(context: ctx)), taken: from + replayed)
            XCTAssertEqual(p.fromSample, from, ctx)
            XCTAssertEqual(p.samples, replayed, ctx)
            XCTAssertEqual(p.firstChunk, c["first_chunk"] as? Int, ctx)
            XCTAssertEqual(p.exact, c["exact"] as? Bool, ctx)
        }
    }

    func testTheFirstWindow() throws {
        for c in try Self.cases("window", 6) {
            let ctx = try XCTUnwrap(c["context"] as? String), ms = try XCTUnwrap(LiveRules.chunkMs(context: ctx))
            let p = LiveRules.replayPlan(chunkMs: ms, taken: try XCTUnwrap(c["samples"] as? Int))
            XCTAssertEqual(p.firstChunk, c["first_chunk"] as? Int, ctx)
            XCTAssertEqual(p.exact, c["exact"] as? Bool, ctx)
            XCTAssertEqual(LiveRules.comparableFrom(p), c["comparable_from"] as? Int, ctx)
            let w = LiveRules.firstWindow(chunkMs: ms, plan: p, newest: try XCTUnwrap(c["newest_both"] as? Int))
            XCTAssertEqual([w.lowerBound, w.upperBound], c["window"] as? [Int], ctx)
        }
    }

    static func verdict(_ x: Any) -> LiveRules.Verdict {
        if let s = x as? String, s == "failed" { return .failed }
        return (x as? Bool) == true ? .within : .outside
    }

    func testShadow() throws {
        for c in try Self.cases("shadow", 9) {
            let windows = try XCTUnwrap(c["windows"] as? [Any]).map(Self.verdict)
            let got = LiveRules.shadowOutcome(exact: try XCTUnwrap(c["exact"] as? Bool), windows: windows)
            XCTAssertEqual(got.result, c["outcome"] as? String, "\(c)")
            XCTAssertEqual(got.window, c["decided_by_window"] as? Int, "\(c)")
        }
    }

    // MARK: 30.5, 30.6, 30.8, 30.9

    func testSwap() throws {
        for c in try Self.cases("swap", 14) {
            let ctx = try XCTUnwrap(c["context"] as? String)
            let got = LiveRules.swapStep(chunkMs: try XCTUnwrap(LiveRules.chunkMs(context: ctx)), commitChunk: try XCTUnwrap(c["commit_chunk"] as? Int),
                                         k: try XCTUnwrap(c["chunk"] as? Int), tail: try XCTUnwrap(c["tail"] as? [Int]),
                                         stalled: try XCTUnwrap(c["stalled"] as? Bool), bar: c["word_bar"] as? Int)
            XCTAssertEqual(got, c["step"] as? String, "\(c)")
        }
    }

    func testRecordAndConfig() throws {
        let records = try Self.cases("record", 6)
        XCTAssertEqual(records.compactMap { $0["outcome"] as? String }, LiveRules.outcomes)
        for c in records {
            let o = try XCTUnwrap(c["outcome"] as? String)
            XCTAssertEqual(LiveRules.recordRule(o), c["record"] as? String, o)
        }
        for c in try Self.cases("config", 5) {
            XCTAssertEqual(LiveRules.flagOn(c["value"] is NSNull ? nil : c["value"]), c["on"] as? Bool, "\(c["value"] ?? "nil")")
        }
    }

    func testTelemetryAsTheServerChecksIt() throws {
        for c in try Self.cases("telemetry", 17) {
            let live = try XCTUnwrap(c["live"])
            XCTAssertEqual(LiveRules.liveProblem(live), c["refused"] as? String, "\(live)")
        }
    }

    // MARK: 30.11, whole takes

    static func initOf(_ x: [String: Any]) throws -> LiveTake.Init {
        var i = LiveTake.Init(context: try XCTUnwrap(x["context"] as? String))
        i.wordBar = x["word_bar"] as? Int
        i.fast = (x["source"] as? String) == "fast"
        i.flagOn = LiveRules.flagOn(x["flag"] is NSNull ? nil : x["flag"])
        i.appCPU = (x["app_cpu"] as? Bool) ?? false
        i.chunksSoFar = (x["chunks_so_far"] as? Int) ?? 0
        i.samplesSoFar = (x["samples_so_far"] as? Int) ?? 0
        i.device = device((x["conditions"] as? [String: Any]) ?? [:])
        return i
    }

    static func event(_ e: [Any]) throws -> LiveTake.Event {
        let kind = try XCTUnwrap(e.first as? String)
        let t = try XCTUnwrap(e[1] as? Int)
        func int(_ i: Int) throws -> Int { try XCTUnwrap(e[i] as? Int, "\(e)") }
        switch kind {
        case "ready": return .ready(t: t, n: try int(2))
        case "unready": return .unready(t: t)
        case "cond": return .cond(t: t, change(try XCTUnwrap(e[2] as? [String: Any])))
        case "cpu": return .cpu(t: t, k: try int(2), n: try int(3), tail: try XCTUnwrap(e[4] as? [Int]), late: try XCTUnwrap(e[5] as? Bool))
        case "acc": return .acc(t: t, k: try int(2))
        case "verdict": return .verdict(t: t, try XCTUnwrap(LiveRules.Verdict(rawValue: try XCTUnwrap(e[2] as? String))))
        case "fail": return .fail(t: t, cause: try XCTUnwrap(e[2] as? String))
        case "interrupted": return .interrupted(t: t)
        case "resumed": return .resumed(t: t)
        case "failover": return .failover(t: t, k: try int(2))
        case "end": return .end(t: t, n: try int(2), why: try XCTUnwrap(e[3] as? String))
        default: throw XCTSkip("an unknown event \(e)")
        }
    }

    /// An action as the vectors write it.
    static func json(_ a: LiveTake.Action) -> [Any] {
        switch a {
        case .emit(let k, let engine): return ["emit", k, engine.rawValue]
        case .replay(let from, let samples, let first, let exact): return ["replay", from, samples, first, exact]
        case .judge(let a, let b): return ["judge", a, b]
        case .outcome(let o, let record): return ["outcome", o, record.map { $0 as Any } ?? NSNull()]
        case .closeCPU: return ["close_cpu"]
        case .changed(let from): return ["changed", "acc", from]
        case .releaseAcc: return ["release_acc"]
        case .tally(let t): return ["tally", t.object]
        }
    }

    static func canonical(_ v: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]), as: UTF8.self)
    }

    func testTakes() throws {
        let v = try Self.vectors()
        var day = LiveDay()
        var names: [String] = []
        for c in try Self.cases("takes", 29) {
            let name = try XCTUnwrap(c["name"] as? String)
            names.append(name)
            var take = LiveTake(try Self.initOf(try XCTUnwrap(c["init"] as? [String: Any], name)))
            let events = try XCTUnwrap(c["events"] as? [[Any]], name)
            var want: [Int: Any] = [:]
            for entry in try XCTUnwrap(c["actions"] as? [[Any]], name) { want[try XCTUnwrap(entry[0] as? Int)] = entry[1] }
            var got: [Int: [[Any]]] = [:]
            var tally: LiveTally?
            for (i, e) in events.enumerated() {
                let actions = take.feed(try Self.event(e))
                if !actions.isEmpty { got[i] = actions.map(Self.json) }
                for a in actions { if case .tally(let t) = a { tally = t } }
            }
            XCTAssertEqual(Set(got.keys), Set(want.keys), "\(name): the events that gave actions")
            for i in got.keys.sorted() {
                guard let w = want[i] else { continue }
                XCTAssertEqual(try Self.canonical(got[i]!), try Self.canonical(w), "\(name): the actions after event \(i) \(events[i])")
            }
            let t = try XCTUnwrap(tally, "\(name): the take's tally")
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            XCTAssertEqual(try Self.canonical(t.object), try Self.canonical(try XCTUnwrap(expect["tally"])), "\(name): the tally")
            day.add(t)
        }
        XCTAssertEqual(Set(names).count, 29, "29 takes, each its own")
        // 30.9: every take's tally added up is the file's day, and the server takes it
        XCTAssertEqual(try Self.canonical(day.object), try Self.canonical(try XCTUnwrap(v["day_of_the_takes"])))
        XCTAssertNil(LiveRules.liveProblem(day.object))
    }
}
