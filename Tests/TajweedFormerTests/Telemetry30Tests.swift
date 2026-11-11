import Foundation
import XCTest
@testable import TajweedFormer

/// The shared telemetry vector of SDK 3.0.0 (`telemetry_30.json`): the SDK-measured counters of a cohort from takes
/// with known outputs, and the two app-reported APIs (`reportRecited`, `reportChecks`) call by call. The takes are
/// counted by the code a Session's end runs (`SessionTelemetry.count`), the reports by the validation the public
/// calls run and the store they write to.
final class Telemetry30VectorTests: XCTestCase {
    static let day = Date(timeIntervalSince1970: 1_794_355_200)   // 2026-11-11 UTC

    func store() -> AnalyticsStore {
        AnalyticsStore(storage: CloudFixtures.storage(), enabled: true,
                       context: .init(platform: "ios", sdkVersion: SDKInfo.version, appVersion: "3.2", deviceClass: "A17", soc: "a17",
                                      osMajor: 18, ramTier: "8_16"),
                       clock: { Self.day })
    }

    func payload(_ s: AnalyticsStore) throws -> [String: Any] {
        s.payload(try XCTUnwrap(s.pending.first), reportID: "6f1c0e9a4b2d47e8a1c3f5d7b9e0a2c4")
    }

    /// The six app-reported fields and `reported` of a payload, as the vector writes a day.
    func reported(_ p: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for k in AnalyticsStore.appReported + ["reported"] { if let v = p[k] { out[k] = v } }
        return out
    }

    /// Two JSON values with the same shape, strings and numbers (numbers to 1e-9).
    static func same(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case (is NSNull, is NSNull): return true
        case (let x as [String: Any], let y as [String: Any]):
            return Set(x.keys) == Set(y.keys) && x.allSatisfy { e in y[e.key].map { same(e.value, $0) } ?? false }
        case (let x as [Any], let y as [Any]):
            return x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
        case (let x as String, let y as String): return x == y
        case (let x as NSNumber, let y as NSNumber): return abs(x.doubleValue - y.doubleValue) <= 1e-9
        default: return false
        }
    }

    /// A take counts when it ended with its Heads: `finish`, or an `ended` event with any reason but `error`.
    static func counts(_ end: String) -> Bool { end == "finish" || (end.hasPrefix("ended:") && end != "ended:error") }

    func testTheCountersOfTheVectorsTakes() throws {
        let v = try Vectors30.json("telemetry_30.json")
        XCTAssertEqual(v["ctc_heads"] as? [String], HeadID.ctc.map(\.rawValue))
        let version = try XCTUnwrap(v["version"] as? String), build = try XCTUnwrap(v["build"] as? String)
        let ctc = Set(HeadID.ctc.map(\.rawValue))
        let s = store()
        let takes = try XCTUnwrap(v["takes"] as? [[String: Any]])
        XCTAssertEqual(takes.count, 6)
        for t in takes {
            let name = t["name"] as? String ?? "?"
            let cohort = TelemetryCohort(revision: version, build: build, context: try XCTUnwrap(t["context"] as? String, name),
                                         backend: try XCTUnwrap(t["backend"] as? String, name))
            let samples = try XCTUnwrap(t["samples"] as? Int, name), rate = try XCTUnwrap(t["sample_rate"] as? Int, name)
            let micros = try XCTUnwrap(t["chunk_compute_us"] as? [Int], name)
            let heads = try XCTUnwrap(t["heads"] as? [String: [Int]], name)
            let selected = try XCTUnwrap(t["selected"] as? [String], name).filter { ctc.contains($0) }
            var take = SessionTelemetry(cohort: cohort, audioSeconds: Double(samples) / Double(rate), chunkSeconds: micros.map { Double($0) / 1_000_000 },
                                        chunkAudioSeconds: 0.32)
            if Self.counts(try XCTUnwrap(t["end"] as? String, name)) {
                take.count(audioMs: 1000 * samples / rate, selected: selected, computeMicroseconds: micros.reduce(0, +)) { heads[$0] ?? [] }
            } else {
                take.counts = false
            }
            s.record(.sessionFinished(take))
        }
        let cohorts = try XCTUnwrap(try payload(s)["cohorts"] as? [[String: Any]])
        let want = try XCTUnwrap(v["cohorts"] as? [[String: Any]])
        XCTAssertEqual(cohorts.count, want.count)
        let removed = try XCTUnwrap(v["cohort_fields_removed"] as? [String])
        for w in want {
            let context = w["context"] as? String ?? "?"
            let mine = try XCTUnwrap(cohorts.first { $0["context"] as? String == context && $0["backend"] as? String == w["backend"] as? String }, context)
            // every field the vector lists, and none of the six counters it leaves out (a zero is not sent)
            for (k, value) in w { XCTAssertTrue(Self.same(mine[k] ?? NSNull(), value), "\(context) \(k): \(mine[k] ?? "absent") against \(value)") }
            for k in ["takes", "audio_s", "speech_s", "silence_s", "tokens", "compute_s"] where w[k] == nil { XCTAssertNil(mine[k], "\(context) \(k)") }
            for k in removed { XCTAssertNil(mine[k], "\(context): \(k) is not sent any more") }
        }
    }

    /// The example payload's shape: this SDK's payload of a day has no top-level or cohort field the example lacks.
    func testThePayloadHasNoFieldOutsideTheExample() throws {
        let v = try Vectors30.json("telemetry_30.json")
        let example = try XCTUnwrap(v["example_payload"] as? [String: Any])
        let s = store()
        var take = SessionTelemetry(cohort: TelemetryCohort(revision: "4.0.0", build: AnalyticsAndIssueTests.build, context: "c16_l64", backend: "cpu"),
                                    audioSeconds: 2, chunkSeconds: [0.006], chunkAudioSeconds: 0.32, coldStartMs: 300)
        // 24 frames, tokens at frames 1 and 3 and a timing head that hears nothing: 2 frames are speech, 22 are silence
        take.count(audioMs: 2000, selected: ["log_probs"], computeMicroseconds: 6000) { head in
            head == "log_probs" ? [0, 3, 0, 4] + [Int](repeating: 0, count: 20) : []
        }
        take.margins = [1.5]
        take.confidences = [0.9]
        s.record(.sessionFinished(take))
        s.record(.modelLoaded(revision: "4.0.0", milliseconds: 300, cohort: take.cohort))
        s.count(.launch)
        s.count(.shareAsked)
        s.count(.shareYes)
        s.record(.download(revision: "4.0.0", build: AnalyticsAndIssueTests.build, profile: "apple-cpu", bytes: 59_310_442, success: true, resumed: true))
        s.record(.promotion(PromotionTelemetry(backend: "ane", revision: "4.0.0", build: AnalyticsAndIssueTests.build, context: "c16_l64",
                                               kind: .attempt(promoted: true, stage: nil, reason: nil, compileMs: 9000, speedup: 2.5))))
        for r in try XCTUnwrap((v["example_reports"] as? [String: Any])?["recited"] as? [[Int]]) { s.reportRecited(surah: r[0], ayahFrom: r[1], ayahTo: r[2]) }
        for c in try XCTUnwrap((v["example_reports"] as? [String: Any])?["checks"] as? [[Any]]) {
            s.reportChecks(rule: try XCTUnwrap(c[0] as? String), checked: try XCTUnwrap(c[1] as? Int), flagged: try XCTUnwrap(c[2] as? Int))
        }
        let p = try payload(s)
        XCTAssertEqual(Set(p.keys), Set(example.keys), "the top-level fields")
        // the app-reported fields are the example's, from the example's reports
        XCTAssertTrue(Self.same(reported(p), reported(example)), "\(reported(p))")
        XCTAssertEqual(p["reported"] as? [String], v["reported_order"] as? [String])
        let mine = try XCTUnwrap((p["cohorts"] as? [[String: Any]])?.first), theirs = try XCTUnwrap((example["cohorts"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(mine.keys), Set(theirs.keys), "the cohort's fields")
        for k in ["fallbacks", "self_test", "latency_ms", "rtf", "cold_start_ms", "model_load_ms", "thermal", "margin", "confidence"] {
            XCTAssertEqual(Set((mine[k] as? [String: Any] ?? [:]).keys), Set((theirs[k] as? [String: Any] ?? [:]).keys), k)
        }
        let download = try XCTUnwrap((p["downloads"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(download.keys), Set(try XCTUnwrap((example["downloads"] as? [[String: Any]])?.first).keys))
        let promotion = try XCTUnwrap((p["promotions"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(promotion.keys), Set(try XCTUnwrap((example["promotions"] as? [[String: Any]])?.first).keys))
        XCTAssertEqual(promotion["build"] as? String, AnalyticsAndIssueTests.build)
        // a day without reports: none of the six fields, no `reported`
        let quiet = store()
        quiet.count(.launch)
        XCTAssertTrue(reported(try payload(quiet)).isEmpty)
        XCTAssertEqual((v["nothing_reported"] as? [String: Any])?["fields"] as? [String: Int], [:])
    }

    // MARK: reportRecited

    static func recited(_ c: [Int]) -> String {
        do throws(TajweedError) { _ = try TajweedSession.recited(surah: c[0], ayahFrom: c[1], ayahTo: c[2]); return "ok" } catch { return error.code }
    }

    func testReportRecitedCallByCall() throws {
        let v = try XCTUnwrap(try Vectors30.json("telemetry_30.json")["report_recited"] as? [String: Any])
        let refusedCode = try XCTUnwrap(v["refused_code"] as? String)
        for c in try XCTUnwrap(v["valid"] as? [[Int]]) { XCTAssertEqual(Self.recited(c), "ok", "\(c)") }
        for c in try XCTUnwrap(v["refused"] as? [[Int]]) { XCTAssertEqual(Self.recited(c), refusedCode, "\(c)") }
        // one UTC day, the takes in order: a report belongs to its take
        let s = store()
        let takes = try XCTUnwrap(v["takes"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(takes.count, 6)
        for t in takes {
            let name = t["name"] as? String ?? "?"
            let shared = SessionShared(backend: .cpu)
            var results: [String] = []
            for step in try XCTUnwrap(t["steps"] as? [[Any]], name) {
                if step[0] as? String == "recited" {
                    let call = try step.dropFirst().map { try XCTUnwrap($0 as? Int, name) }
                    do throws(TajweedError) {
                        let range = try TajweedSession.recited(surah: call[0], ayahFrom: call[1], ayahTo: call[2])
                        if let r = shared.report(range) { s.reportRecited(surah: r.surah, ayahFrom: r.ayahFrom, ayahTo: r.ayahTo) }
                        results.append("ok")
                    } catch {
                        results.append(error.code)
                    }
                } else {
                    let how = try XCTUnwrap(step[1] as? String, name)
                    if let r = shared.takeEnded(counts: how != "cancel" && Self.counts(how)) {
                        s.reportRecited(surah: r.surah, ayahFrom: r.ayahFrom, ayahTo: r.ayahTo)
                    }
                }
            }
            XCTAssertEqual(results, t["results"] as? [String], name)
            let day = s.pending.first.map { reported(s.payload($0, reportID: "6f1c0e9a4b2d47e8a1c3f5d7b9e0a2c4")) } ?? [:]
            XCTAssertTrue(Self.same(day, try XCTUnwrap(t["day_after"] as? [String: Any], name)), "\(name): \(day)")
        }
    }

    // MARK: reportChecks

    static func check(_ c: [Any]) -> String {
        guard let rule = c[0] as? String, let checked = c[1] as? Int, let flagged = c[2] as? Int else { return "untyped" }
        do throws(TajweedError) { try TajweedAnalytics.check(rule: rule, checked: checked, flagged: flagged); return "ok" } catch { return error.code }
    }

    /// One call as the public API runs it: validated, then counted.
    func call(_ s: AnalyticsStore, _ c: [Any]) -> String {
        let result = Self.check(c)
        if result == "ok", let rule = c[0] as? String, let checked = c[1] as? Int, let flagged = c[2] as? Int {
            s.reportChecks(rule: rule, checked: checked, flagged: flagged)
        }
        return result
    }

    func testReportChecksCallByCall() throws {
        let v = try XCTUnwrap(try Vectors30.json("telemetry_30.json")["report_checks"] as? [String: Any])
        XCTAssertEqual(v["rules_per_day"] as? Int, AnalyticsStore.rulesPerDay)
        let refusedCode = try XCTUnwrap(v["refused_code"] as? String)
        for c in try XCTUnwrap(v["valid"] as? [[Any]]) { XCTAssertEqual(Self.check(c), "ok", "\(c)") }
        for c in try XCTUnwrap(v["refused"] as? [[Any]]) { XCTAssertEqual(Self.check(c), refusedCode, "\(c)") }
        let pattern = try XCTUnwrap(v["rule_pattern"] as? String)
        for rule in ["a", "madd", "x23456789012345678901234", "x234567890123456789012345", "Madd", "1a", "a b", ""] {
            XCTAssertEqual(AnalyticsStore.ruleKey(rule), rule.range(of: pattern, options: .regularExpression) != nil, rule)
        }
        // a day's calls in order, each with its result, and the day after them
        let sequence = try XCTUnwrap(v["sequence"] as? [String: Any])
        let s = store()
        for c in try XCTUnwrap(sequence["calls"] as? [[String: Any]]) {
            let args = try XCTUnwrap(c["call"] as? [Any])
            XCTAssertEqual(call(s, args), c["result"] as? String, "\(args)")
        }
        let day = reported(try payload(s))
        XCTAssertTrue(Self.same(day, try XCTUnwrap(sequence["day_after"] as? [String: Any])), "\(day)")
        // 32 distinct rules a day
        let many = try XCTUnwrap(v["rules_a_day"] as? [String: Any])
        let m = store()
        for c in try XCTUnwrap(many["calls"] as? [[Any]]) { XCTAssertEqual(call(m, c), "ok", "\(c): a dropped rule still returns normally") }
        let full = reported(try payload(m))
        XCTAssertTrue(Self.same(full, try XCTUnwrap(many["day_after"] as? [String: Any])), "\(full)")
    }
}
