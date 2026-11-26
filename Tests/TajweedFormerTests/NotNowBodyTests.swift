import Foundation
import XCTest
@testable import TajweedFormer

/// Contract ACCEL_40.md 21.7 (quranlab-contract promo-not-now b18e059): a compile or a load that the device's lock or
/// the app's leaving cut is counted in the entry's `not_now`, by why. `vectors/accel_40.json` `not_now` (copied into
/// Fixtures/vectors40, SOURCE.txt): every case the server takes is made here from the counts the SDK records and sent
/// through the body as it goes out (sorted keys, parsed back); the cases it refuses are each one the SDK cannot make.
final class NotNowBodyTests: XCTestCase {
    override func tearDown() {
        AnalyticsStore.notNowSent.withLock { $0 = true }
    }

    static let ctx = "c16_l64"

    func store() -> AnalyticsStore {
        AnalyticsStore(storage: Fixtures.storage(), enabled: true,
                       context: .init(platform: "ios", sdkVersion: "4.0.5", appVersion: "1", deviceClass: "phone", soc: nil, osMajor: 26, ramTier: "8gb"))
    }

    func block() throws -> [String: Any] {
        try XCTUnwrap(try V40.json("accel_40.json")["not_now"] as? [String: Any])
    }

    /// A value inside each bucket the vectors name.
    static let compileMs: [String: Double] = ["le_1000": 900, "le_5000": 4_000, "le_15000": 12_000, "le_30000": 20_000,
                                              "le_60000": 50_000, "le_120000": 100_000, "gt_120000": 200_000]
    static let speedup: [String: Double] = ["lt_0_5": 0.4, "lt_1": 0.9, "le_1_5": 1.4, "le_2": 1.9, "le_3": 2.9, "le_5": 4.9, "gt_5": 6]

    /// The entry the SDK sends after the counts of `entry` were recorded the way the SDK records them (each cut one
    /// `notNow` event, compiles and loads in turn; each attempt one `attempt` event); counts above 100 are set on the
    /// day's entry, as a day of many runs would hold them.
    func sent(_ entry: [String: Any]) throws -> [String: Any]? {
        let s = store()
        let build = try XCTUnwrap(entry["build"] as? String)
        func rec(_ kind: PromotionTelemetry.Kind) {
            s.record(.promotion(PromotionTelemetry(backend: "ane", revision: "4.0.0", build: build, context: Self.ctx, kind: kind)))
        }
        let notNow = entry["not_now"] as? [String: Int] ?? [:]
        var many: [String: Int] = [:]
        for (why, n) in notNow {
            if n > 100 { many[why] = n; rec(.notNow(stage: .compile, why: why)); continue }
            for i in 0..<n { rec(.notNow(stage: i % 2 == 0 ? .compile : .warmup, why: why)) }
        }
        var compile = (entry["compile_ms"] as? [String: Int] ?? [:]).flatMap { k, n in Array(repeating: Self.compileMs[k], count: n) }
        var speed = (entry["speedup"] as? [String: Int] ?? [:]).flatMap { k, n in Array(repeating: Self.speedup[k], count: n) }
        let promoted = entry["promoted"] as? Int ?? 0
        for i in 0..<(entry["attempts"] as? Int ?? 0) {
            rec(.attempt(promoted: i < promoted, stage: nil, reason: nil,
                         compileMs: compile.isEmpty ? nil : compile.removeFirst(), speedup: speed.isEmpty ? nil : speed.removeFirst()))
        }
        var day = try XCTUnwrap(s.pending.first)
        if !many.isEmpty {
            let k = try XCTUnwrap(day.promotions.keys.first)
            var p = try XCTUnwrap(day.promotions[k])
            for (why, n) in many { p.notNow?[why] = n }
            day.promotions[k] = p
        }
        let body = try JSONSerialization.data(withJSONObject: s.payload(day, reportID: String(repeating: "a", count: 32)), options: [.sortedKeys])
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let entries = o["promotions"] as? [[String: Any]] ?? []
        XCTAssertLessThanOrEqual(entries.count, 1)
        return entries.first
    }

    /// The entry as the server takes it, with what the SDK leaves out (zero counts, empty objects) left out.
    static func trimmed(_ entry: [String: Any]) -> [String: Any] {
        var e: [String: Any] = [:]
        for (k, v) in entry {
            if let n = v as? Int, n == 0 { continue }
            if let o = v as? [String: Any] {
                let kept = o.filter { ($0.value as? Int) != 0 }
                if !kept.isEmpty { e[k] = kept }
                continue
            }
            e[k] = v
        }
        return e
    }

    /// The p2 doubles 15 and 16 the server writes from `not_now`: locked, then background (0 when left out).
    static func p2(_ entry: [String: Any], _ keys: [String]) -> [Int] {
        let n = entry["not_now"] as? [String: Int] ?? [:]
        return keys.map { n[$0] ?? 0 }
    }

    func testTheBlockIsTheOneThisSDKFollows() throws {
        let b = try block()
        XCTAssertEqual(b["keys"] as? [String], ["locked", "background"])
        XCTAssertEqual(b["from"] as? String, "4.0.5")
        XCTAssertEqual(b["again_max"] as? Int, AcceleratorController.notNowRunsMax, "a run goes on with a cut stage this often")
        XCTAssertEqual(b["p2_doubles"] as? [Int], [15, 16])
        XCTAssertEqual((b["cases"] as? [[String: Any]])?.count, 15)
        XCTAssertTrue(AnalyticsStore.notNowSent.withLock { $0 }, "on: qlab-api takes not_now since 2026-11-26 13:46Z")
    }

    /// Every case the server takes (`field` null) from a body of 4.0.5 or later: the SDK's entry is the case's entry
    /// (zero counts and an empty `not_now` left out, as the SDK leaves them), its p2 doubles the case's.
    func testEveryCaseTheServerTakesIsTheEntryTheSDKSends() throws {
        let b = try block()
        let keys = try XCTUnwrap(b["keys"] as? [String])
        let from = try XCTUnwrap(b["from"] as? String)
        var made = 0
        for c in try XCTUnwrap(b["cases"] as? [[String: Any]]) where c["field"] is NSNull {
            let name = c["name"] as? String ?? "?"
            XCTAssertTrue(ModelManifest.version(try XCTUnwrap(c["sdk"] as? String), isAtLeast: from), name)
            let want = Self.trimmed(try XCTUnwrap(c["entry"] as? [String: Any]))
            let p2 = try XCTUnwrap(c["p2"] as? [Int], name)
            guard let got = try sent(try XCTUnwrap(c["entry"] as? [String: Any])) else {
                XCTFail("\(name): no entry sent"); continue
            }
            XCTAssertEqual(got as NSDictionary, want as NSDictionary, name)
            XCTAssertEqual(Self.p2(got, keys), p2, name)
            if let n = got["not_now"] as? [String: Any] {
                XCTAssertFalse(n.isEmpty, name)
                XCTAssertTrue(Set(n.keys).isSubset(of: keys), name)
                XCTAssertTrue(n.values.allSatisfy { ($0 as? Int).map { (1...10_000_000).contains($0) } ?? false }, name)
            }
            made += 1
        }
        XCTAssertEqual(made, 6, "the six cases the server takes")
    }

    /// The cases the server refuses, each one the SDK cannot send: a body before 4.0.5 (this SDK is 4.0.5 and the
    /// switch names the field only from it), a key outside the two (a cut is `locked` or `background`), a count
    /// that is not an integer from 0 to 10,000,000 (counts only grow by 1, and the body clips them), a value that is
    /// not an object.
    func testNoCaseTheServerRefusesIsOneTheSDKCanSend() throws {
        let b = try block()
        let keys = try XCTUnwrap(b["keys"] as? [String])
        let from = try XCTUnwrap(b["from"] as? String)
        var refused = 0
        for c in try XCTUnwrap(b["cases"] as? [[String: Any]]) {
            guard let field = c["field"] as? String else { continue }
            refused += 1
            let name = c["name"] as? String ?? "?"
            let sdk = try XCTUnwrap(c["sdk"] as? String)
            XCTAssertTrue(c["p2"] is NSNull, name)
            if !ModelManifest.version(sdk, isAtLeast: from) {
                XCTAssertEqual(field, "not_now", name)
                continue
            }
            let value = (c["entry"] as? [String: Any])?["not_now"]
            if field == "not_now" {
                XCTAssertNil(value as? [String: Any], "\(name): refused only when it is not an object")
            } else {
                let key = String(field.dropFirst("not_now.".count))
                let v = (value as? [String: Any])?[key]
                let fine = keys.contains(key) && (v as? NSNumber).map { n in
                    CFGetTypeID(n) != CFBooleanGetTypeID() && n.doubleValue == n.doubleValue.rounded() && (0...10_000_000).contains(n.doubleValue)
                } ?? false
                XCTAssertFalse(fine, "\(name): the SDK could send this")
            }
        }
        XCTAssertEqual(refused, 9)
        // a count past the bound goes out at the bound
        let s = store()
        let build = String(repeating: "4b", count: 20)
        s.record(.promotion(PromotionTelemetry(backend: "ane", revision: "4.0.0", build: build, context: Self.ctx,
                                               kind: .notNow(stage: .compile, why: "locked"))))
        var day = try XCTUnwrap(s.pending.first)
        let k = try XCTUnwrap(day.promotions.keys.first)
        day.promotions[k]?.notNow = ["locked": 10_000_001, "background": 0]
        let entry = try XCTUnwrap((s.payload(day, reportID: String(repeating: "b", count: 32))["promotions"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["not_now"] as? [String: Int], ["locked": 10_000_000])
    }

    /// The switch off: the cuts are still counted and kept with the day, and no `not_now` goes, nor an entry with
    /// nothing else counted.
    func testOffTheCutsAreKeptAndLeftOutOfTheBody() throws {
        AnalyticsStore.notNowSent.withLock { $0 = false }
        let s = store()
        s.record(.promotion(PromotionTelemetry(backend: "ane", revision: "4.0.0", build: String(repeating: "4b", count: 20),
                                               context: Self.ctx, kind: .notNow(stage: .compile, why: "locked"))))
        let day = try XCTUnwrap(s.pending.first)
        XCTAssertEqual(day.promotions.values.first?.notNow, ["locked": 1])
        XCTAssertNil(s.payload(day, reportID: String(repeating: "c", count: 32))["promotions"])
        AnalyticsStore.notNowSent.withLock { $0 = true }
        let on = try XCTUnwrap(s.payload(day, reportID: String(repeating: "d", count: 32))["promotions"] as? [[String: Any]])
        XCTAssertEqual(on.first?["not_now"] as? [String: Int], ["locked": 1])
        XCTAssertNil(on.first?["attempts"], "a cut is not an attempt")
    }
}
