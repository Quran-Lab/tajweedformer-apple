import Foundation
import XCTest
@testable import TajweedFormer

/// Accelerator incidents as issue reports (the platform client doc, section 7.1): the body of each kind from a forced
/// failure (a failover at a chunk; a promotion failure at each stage) against the closed schema, the path-stripped
/// message, nothing identifying, and the first report of each kind per revision always sent across the daily dedupe.
final class IncidentTests: XCTestCase {
    static let app = AppIdentity(platform: "ios", bundleID: "com.example.quran", version: "1.2")

    /// The 7.1 schema, closed: every key known, every value of its type and range.
    static func validate(_ body: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        let top: Set<String> = ["day", "platform", "sdk_version", "app_version", "os_version", "device_class", "revision", "kind", "code",
                                "message", "detail"]
        XCTAssertTrue(Set(body.keys).isSubset(of: top), "unknown keys \(Set(body.keys).subtracting(top))", file: file, line: line)
        XCTAssertNil(body["backend"], "no backend for these kinds", file: file, line: line)
        XCTAssertNotNil(body["revision"] as? String, file: file, line: line)
        let kind = body["kind"] as? String ?? ""
        XCTAssertTrue(["accelerator_failover", "promotion_failed"].contains(kind), kind, file: file, line: line)
        let stages = ["download", "compile", "warmup", "golden", "session"]
        let causes = ["exception", "nan", "out_of_range", "blank", "timeout", "crash_on_last_run", "golden_mismatch", "cpu_mismatch",
                      "compile_error", "compile_timeout", "load_error", "verify", "network", "storage", "other"]
        let code = body["code"] as? String ?? ""
        let parts = code.split(separator: ":").map(String.init)
        XCTAssertEqual(parts.count, 2, code, file: file, line: line)
        if parts.count == 2 {
            XCTAssertTrue(stages.contains(parts[0]) && causes.contains(parts[1]), code, file: file, line: line)
        }
        if let m = body["message"] {
            let s = m as? String ?? ""
            XCTAssertTrue(!s.isEmpty && s.count <= 200, file: file, line: line)
            XCTAssertNil(s.range(of: #"/[A-Za-z]|://|[0-9]{5,}"#, options: .regularExpression), "not stripped: \(s)", file: file, line: line)
        }
        guard let d = body["detail"] as? [String: Any] else { return XCTFail("no detail", file: file, line: line) }
        let allowed: Set<String> = ["stage", "cause", "error_domain", "error_code", "chunk", "elapsed_ms", "deadline_ms", "clip", "divergence",
                                    "device_model", "os_build", "chip", "accelerator", "compute_units", "delegate", "context", "thermal",
                                    "low_power", "stall_ms", "attempt"]
        XCTAssertTrue(Set(d.keys).isSubset(of: allowed), "unknown detail keys \(Set(d.keys).subtracting(allowed))", file: file, line: line)
        XCTAssertTrue(stages.contains(d["stage"] as? String ?? ""), file: file, line: line)
        XCTAssertTrue(causes.contains(d["cause"] as? String ?? ""), file: file, line: line)
        XCTAssertEqual("\(d["stage"]!):\(d["cause"]!)", code, file: file, line: line)
        func matches(_ k: String, _ re: String, _ max: Int) {
            guard let v = d[k] else { return }
            let s = v as? String ?? ""
            XCTAssertTrue(s.count <= max && s.range(of: "^" + re + "$", options: .regularExpression) != nil, "\(k) = \(v)", file: file, line: line)
        }
        matches("error_domain", "[A-Za-z0-9_.:-]+", 64)
        matches("error_code", "[A-Za-z0-9_.:-]+", 32)
        matches("clip", "[A-Za-z0-9_.-]+", 32)
        matches("device_model", "[A-Za-z0-9_.,-]+", 32)
        matches("os_build", "[A-Za-z0-9_.:/-]+", 64)
        matches("chip", "[a-z0-9_]+", 24)
        matches("accelerator", "ane|gpu|npu:[a-z0-9_]+", 32)
        matches("compute_units", "cpuAndNeuralEngine|cpuAndGPU|all|cpuOnly|npu|gpu", 32)
        matches("thermal", "nominal|fair|serious|critical", 16)
        func int(_ k: String, _ r: ClosedRange<Int>) {
            guard let v = d[k] else { return }
            XCTAssertTrue((v as? Int).map { r.contains($0) } ?? false, "\(k) = \(v)", file: file, line: line)
        }
        int("chunk", 0...1_000_000)
        int("stall_ms", 0...600_000)
        int("attempt", 1...100)
        for k in ["elapsed_ms", "deadline_ms"] {
            if let v = d[k] { XCTAssertTrue((v as? Double).map { (0...600_000).contains($0) } ?? false, "\(k) = \(v)", file: file, line: line) }
        }
        if let v = d["low_power"] { XCTAssertTrue(v is Bool, file: file, line: line) }
        if let dv = d["divergence"] {
            let o = dv as? [String: Any] ?? [:]
            XCTAssertTrue(Set(o.keys).isSubset(of: ["tokens_expected", "tokens_differ", "sites_differ", "words_differ"]), file: file, line: line)
            for (_, x) in o { XCTAssertTrue((x as? Int).map { (0...100_000).contains($0) } ?? false, file: file, line: line) }
        }
    }

    static func json(_ r: IssueReport) throws -> [String: Any] {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        return try XCTUnwrap(JSONSerialization.jsonObject(with: enc.encode(r)) as? [String: Any])
    }

    func testAFailoverReportFollowsTheSchema() throws {
        let f = TakeRunner.Failover(cause: .deadline, detail: "no answer from /var/mobile/Containers/Data/x.mlmodelc at https://cdn.example/a?k=123456 after 1234567 us",
                                    chunk: 12, replayFrom: 0, stallMs: 143.6, cold: true, elapsedMs: 300.2, deadlineMs: 300,
                                    errorDomain: "com.apple.CoreML", errorCode: "-7")
        let h = PromotionTests.Harness()
        let c = h.controller()
        c.failedOver(f)
        let inc = try XCTUnwrap(h.incidents.withLock { $0 }.last)
        let body = try Self.json(QuranLabCloud.incidentReport(inc, app: Self.app, chip: "a17pro", deviceModel: "iPhone16,2", osBuild: "23C71"))
        Self.validate(body)
        XCTAssertEqual(body["kind"] as? String, "accelerator_failover")
        XCTAssertEqual(body["code"] as? String, "session:timeout")
        let d = try XCTUnwrap(body["detail"] as? [String: Any])
        XCTAssertEqual(d["chunk"] as? Int, 12)
        XCTAssertEqual(d["stall_ms"] as? Int, 144)
        XCTAssertEqual(d["error_domain"] as? String, "com.apple.CoreML")
        XCTAssertEqual(d["device_model"] as? String, "iPhone16,2")
        XCTAssertEqual(d["accelerator"] as? String, "ane")
        let m = try XCTUnwrap(body["message"] as? String)
        XCTAssertFalse(m.contains("mobile") || m.contains("cdn.example") || m.contains("1234567"), m)
        print("v4-incident failover body: \(String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self))")
    }

    func testAPromotionFailureReportAtEachStageFollowsTheSchema() async throws {
        let cases: [(PromotionStage, PromotionFailure)] = [
            (.download, PromotionFailure(.network, "offline: the network connection was lost")),
            (.compile, PromotionFailure(.compileError, "cannot load front_c16_l64: /private/var/x/coremldata.bin", errorDomain: "com.apple.CoreML", errorCode: "0")),
            (.warmup, PromotionFailure(.nonFinite, "warm-up: log_probs is NaN or infinite")),
            (.golden, PromotionFailure(.goldenMismatch, "Husary_001001: tokens differ (20 against 21 expected)", clip: "Husary_001001",
                                       divergence: Divergence(expected: [1, 2, 3], tokens: [1, 3], expectedSites: ["5|vowel_sub"], sites: [],
                                                              expectedWords: [1], words: [1]))),
        ]
        for (i, (stage, failure)) in cases.enumerated() {
            let h = PromotionTests.Harness()
            h.failures.withLock { $0[stage] = failure }
            let c = h.controller(revision: "inc\(i)")
            await c.run(h.stages())
            let inc = try XCTUnwrap(h.incidents.withLock { $0 }.last)
            let body = try Self.json(QuranLabCloud.incidentReport(inc, app: Self.app, chip: "m2", deviceModel: "Mac14,9", osBuild: "24A335"))
            Self.validate(body)
            XCTAssertEqual(body["kind"] as? String, "promotion_failed")
            XCTAssertEqual((body["detail"] as? [String: Any])?["attempt"] as? Int, 1)
            if stage == .golden {
                let d = try XCTUnwrap(body["detail"] as? [String: Any])
                XCTAssertEqual(d["clip"] as? String, "Husary_001001")
                XCTAssertEqual(d["divergence"] as? [String: Int], ["tokens_expected": 3, "tokens_differ": 1, "sites_differ": 1, "words_differ": 0])
            }
        }
    }

    /// No audio, text or identifier: only the schema's fields, and nothing of this install's ids.
    func testNothingIdentifyingIsSent() throws {
        Fixtures.configure()
        let inc = AcceleratorIncident(kind: .failover, stage: "session", cause: "exception", message: "prediction failed", revision: "v4.0+abc",
                                      context: "c16_l64")
        let data = try JSONEncoder().encode(QuranLabCloud.incidentReport(inc, app: Self.app))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(QuranLab.contributorID))
        XCTAssertFalse(text.contains("com.example.quran"), "not even the bundle id (the token says which app)")
        Self.validate(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }

    /// The first report of each kind per revision is kept until the server accepts it, whatever the daily dedupe;
    /// later ones go once a day per signature. A refusal (400) drops it, and the next one is again a first.
    func testTheFirstReportPerRevisionIsKeptUntilAccepted() async throws {
        let dir = Fixtures.storage()
        let ledger = IncidentLedger(storage: dir)
        let r = QuranLabCloud.incidentReport(AcceleratorIncident(kind: .failover, stage: "session", cause: "nan", revision: "rev-1", context: "c16_l64"),
                                             app: Self.app)
        XCTAssertTrue(ledger.isFirst(kind: r.kind, revision: "rev-1"))
        ledger.addFirst(r)
        XCTAssertFalse(ledger.isFirst(kind: r.kind, revision: "rev-1"), "one first waits")
        XCTAssertTrue(ledger.isFirst(kind: "promotion_failed", revision: "rev-1"), "per kind")
        XCTAssertTrue(ledger.isFirst(kind: r.kind, revision: "rev-2"), "per revision")
        // the daily dedupe for the later ones
        XCTAssertTrue(ledger.allowToday("sig", day: "2026-11-10"))
        XCTAssertFalse(ledger.allowToday("sig", day: "2026-11-10"))
        XCTAssertTrue(ledger.allowToday("sig", day: "2026-11-11"))
        // a network failure keeps it; a 400 drops it (not accepted: the next is a first again)
        _ = await ledger.flush { (_: Data) async throws(CloudError) -> Void in throw .offline("down") }
        XCTAssertEqual(ledger.pending.count, 1)
        _ = await ledger.flush { (_: Data) async throws(CloudError) -> Void in throw .rejected(status: 400, code: "invalid_body", message: "") }
        XCTAssertEqual(ledger.pending.count, 0)
        XCTAssertTrue(ledger.isFirst(kind: r.kind, revision: "rev-1"))
        // accepted: later reports of the kind for the revision are ordinary ones
        ledger.addFirst(r)
        let sent = await ledger.flush { (_: Data) async throws(CloudError) -> Void in }
        XCTAssertEqual(sent, 1)
        XCTAssertFalse(ledger.isFirst(kind: r.kind, revision: "rev-1"))
        XCTAssertFalse(IncidentLedger(storage: dir).isFirst(kind: r.kind, revision: "rev-1"), "kept on disk")
    }

    /// With `flags.issues` off, the first incident of a kind for a revision still goes; a second does not.
    func testTheFirstGoesEvenWhenIssuesAreOff() throws {
        let storage = CloudFixtures.storage()
        CloudFixtures.seedConfig(storage: storage, flags: ["issues": false])
        StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(flags: ["issues": false])))
        let cloud = CloudFixtures.cloud(storage: storage)
        let inc = AcceleratorIncident(kind: .promotionFailed, stage: "compile", cause: "compile_error", revision: "rev-9", context: "c16_l64")
        cloud.reportIncident(inc)
        XCTAssertFalse(cloud.incidents.isFirst(kind: "promotion_failed", revision: "rev-9"), "queued (or already accepted)")
        cloud.reportIncident(inc)
        XCTAssertTrue(cloud.issues.pending.isEmpty, "a later one follows flags.issues")
    }
}
