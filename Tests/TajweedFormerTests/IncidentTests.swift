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
                                    "low_power", "stall_ms", "attempt", "build", "foreground"]
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
        matches("build", "[0-9a-f]{40}", 40)
        // SDK 3.0.0: the raw golden test's measures per head, the tolerance, what failed, the CPU's token count; the 2.x
        // fields (tokens_differ, sites_differ, words_differ) are refused by the server
        if let dv = d["divergence"] {
            let o = dv as? [String: Any] ?? [:]
            XCTAssertTrue(Set(o.keys).isSubset(of: ["tokens_expected", "heads", "tolerance", "failed"]), "\(o.keys)", file: file, line: line)
            if let n = o["tokens_expected"] { XCTAssertTrue((n as? Int).map { (0...10_000_000).contains($0) } ?? false, file: file, line: line) }
            let fields: Set<String> = ["token_edits", "lp_mean", "lp_p99", "p_mean", "frames", "values"]
            for part in ["heads", "tolerance"] {
                guard let heads = o[part] else { continue }
                guard let m = heads as? [String: Any] else { XCTFail("\(part) is not an object", file: file, line: line); continue }
                for (name, value) in m {
                    XCTAssertNotNil(name.range(of: "^[a-z][a-z0-9_]{0,31}$", options: .regularExpression), name, file: file, line: line)
                    if part == "heads", value is NSNull { continue }
                    let e = value as? [String: Any] ?? ["?": 0]
                    XCTAssertTrue(Set(e.keys).isSubset(of: fields), "\(part).\(name): \(e.keys)", file: file, line: line)
                    for (k, x) in e {
                        let v = (x as? NSNumber)?.doubleValue ?? -1
                        let top: Double = k == "token_edits" ? 100_000 : k == "p_mean" ? 1 : k == "frames" || k == "values" ? 100_000_000 : 30
                        XCTAssertTrue((0...top).contains(v), "\(part).\(name).\(k) = \(x)", file: file, line: line)
                    }
                }
            }
            if let f = o["failed"] {
                let list = f as? [String] ?? ["?"]
                XCTAssertLessThanOrEqual(list.count, 32, file: file, line: line)
                for s in list { XCTAssertNotNil(s.range(of: "^[a-z][a-z0-9_]{0,31}\\.[a-z0-9_]{1,16}$", options: .regularExpression), s, file: file, line: line) }
            }
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
            (.golden, PromotionFailure(.goldenMismatch, "out of tolerance against the CPU engine: log_probs.token_edits", clip: "Husary_001001",
                                       divergence: Self.goldenDivergence())),
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
                let dv = try XCTUnwrap(d["divergence"] as? [String: Any])
                XCTAssertEqual(Set(dv.keys), ["tokens_expected", "heads", "tolerance", "failed"])
                XCTAssertEqual(dv["tokens_expected"] as? Int, 3)
                XCTAssertEqual(dv["failed"] as? [String], ["log_probs.token_edits", "log_probs.lp_mean", "log_probs.lp_p99"])
                let lp = try XCTUnwrap((dv["heads"] as? [String: Any])?["log_probs"] as? [String: Any])
                XCTAssertEqual(lp["token_edits"] as? Int, 1)
                XCTAssertEqual(lp["frames"] as? Int, 6)
                XCTAssertEqual(((dv["tolerance"] as? [String: Any])?["log_probs"] as? [String: Any])?["token_edits"] as? Int, 0)
            }
        }
    }

    /// What the raw golden test reports for one clean clip in which the accelerator missed a token.
    static func goldenDivergence() -> Divergence {
        let cpu = GoldenRaw.Matrix(Vectors30.logProbs([0, 3, 0, 4, 0, 5]), cols: 38)
        let acc = GoldenRaw.Matrix(Vectors30.logProbs([0, 3, 0, 0, 0, 5]), cols: 38)
        let tolerance = GoldenRawTolerance(heads: ["log_probs": .init(tokenEdits: 0, lpMean: 0.05, lpP99: 1.5)], pMean: nil)
        let clip = GoldenRaw.Clip(id: "Husary_001001", clean: true, expectedTokens: [3, 4, 5], cpu: ["log_probs": cpu], accelerator: ["log_probs": acc])
        return GoldenRaw.evaluate([clip], tolerance: tolerance).divergence(tolerance: tolerance)
    }

    /// The model is named by its version, with the build next to it, when the controller knows both.
    func testTheReportNamesTheVersionAndTheBuild() async throws {
        let h = PromotionTests.Harness()
        h.failures.withLock { $0[.compile] = PromotionFailure(.compileError, "cannot load") }
        var env = h.env(revision: AnalyticsAndIssueTests.build)
        env.version = "4.0.0"
        let c = AcceleratorController(env)
        await c.run(h.stages())
        let inc = try XCTUnwrap(h.incidents.withLock { $0 }.last)
        XCTAssertEqual(inc.revision, "4.0.0")
        XCTAssertEqual(inc.build, AnalyticsAndIssueTests.build)
        let body = try Self.json(QuranLabCloud.incidentReport(inc, app: Self.app, chip: "m2", deviceModel: "Mac14,9", osBuild: "24A335"))
        Self.validate(body)
        XCTAssertEqual(body["revision"] as? String, "4.0.0")
        XCTAssertEqual((body["detail"] as? [String: Any])?["build"] as? String, AnalyticsAndIssueTests.build)
        // the promotion's telemetry carries the same pair
        let p = try XCTUnwrap(h.promotions.last)
        XCTAssertEqual(p.revision, "4.0.0")
        XCTAssertEqual(p.build, AnalyticsAndIssueTests.build)
        let store = AnalyticsStore(storage: Fixtures.storage(), enabled: true,
                                   context: .init(platform: "ios", sdkVersion: "3.0.0", appVersion: "1", deviceClass: "phone", soc: nil, osMajor: 26, ramTier: "8gb"))
        for x in h.promotions { store.record(.promotion(x)) }
        let e = try XCTUnwrap(AnalyticsStore.promotions(store.pending.first!.promotions).first)
        XCTAssertEqual(e["revision"] as? String, "4.0.0")
        XCTAssertEqual(e["build"] as? String, AnalyticsAndIssueTests.build)
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

    /// 2.0.2: an app that never configured a Quran Lab client (as when a developer tests offline without
    /// `QuranLab.configure`): incident reports are kept on the device (2.0.1 dropped them: no client, nothing queued),
    /// stay while a client with a key is offline, and go once the network is there.
    func testIncidentsAreKeptOfflineWithoutAClientAndSentOnceConfigured() async throws {
        let storage = CloudFixtures.storage()
        QuranLab.configure(options: .init(modelSource: [], analytics: .off, storageDirectory: storage, cloud: nil))
        XCTAssertNil(QuranLab.cloud)
        QuranLab.reportIncident(AcceleratorIncident(kind: .failover, stage: "session", cause: "blank", revision: "rev-off", context: "c16_l64"))
        QuranLab.reportIncident(AcceleratorIncident(kind: .failover, stage: "session", cause: "timeout", revision: "rev-off", context: "c16_l64"))
        QuranLab.reportIncident(AcceleratorIncident(kind: .failover, stage: "session", cause: "timeout", revision: "rev-off", context: "c16_l64"))
        XCTAssertEqual(IncidentLedger(storage: storage).pending.map(\.code), ["session:blank"], "the first of the kind")
        XCTAssertEqual(IssueQueue(storage: storage).pending.map(\.code), ["session:timeout"], "later ones once a day per signature")
        // a client configured with a key, offline: everything stays
        StubProtocol.reset { _ in .down }
        let cloud = CloudFixtures.cloud(storage: storage)
        _ = await cloud.flush()
        XCTAssertEqual(cloud.incidents.pending.count, 1)
        XCTAssertEqual(cloud.issues.pending.count, 1)
        // online: both go
        StubProtocol.reset(CloudFixtures.server())
        let sent = await cloud.flush()
        XCTAssertEqual(sent.issues, 2)
        XCTAssertEqual(StubProtocol.seen("/v1/issues").count, 2)
        XCTAssertTrue(cloud.incidents.pending.isEmpty)
        XCTAssertTrue(cloud.issues.pending.isEmpty)
        for s in StubProtocol.seen("/v1/issues") { Self.validate(try XCTUnwrap(s.json)) }
        Fixtures.configure()
    }

    /// Reports are kept at most 7 days on the device.
    func testReportsOlderThanSevenDaysAreDropped() throws {
        let storage = CloudFixtures.storage()
        var old = QuranLabCloud.incidentReport(AcceleratorIncident(kind: .failover, stage: "session", cause: "nan", revision: "rev-7", context: "c16_l64"),
                                               app: Self.app)
        old.day = Day.string(Date().addingTimeInterval(-8 * 86_400))
        var recent = old
        recent.day = Day.string(Date().addingTimeInterval(-6 * 86_400))
        recent.code = "session:exception"
        let q = IssueQueue(storage: storage)
        q.add(old)
        q.add(recent)
        XCTAssertEqual(q.pending.map(\.code), ["session:exception"])
        XCTAssertEqual(IssueQueue(storage: storage).pending.map(\.code), ["session:exception"], "on disk too")
        let ledger = IncidentLedger(storage: storage)
        ledger.addFirst(old)
        XCTAssertTrue(ledger.pending.isEmpty)
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
