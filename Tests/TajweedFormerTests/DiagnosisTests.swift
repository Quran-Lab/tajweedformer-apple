import Foundation
import XCTest
@testable import TajweedFormer

/// `client.diagnose()` against the shared schema (`diagnosis.schema.json`, with `diagnosis_examples.json`): the rules of
/// the schema are written out here, proved on the shared examples (every valid one passes, every invalid one fails),
/// and then applied to what this SDK reports.
final class DiagnosisTests: XCTestCase {
    static let versionPattern = #"^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,5})$"#

    static func matches(_ v: Any?, _ pattern: String) -> Bool {
        guard let s = v as? String else { return false }
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    static func isNull(_ v: Any?) -> Bool { v is NSNull }
    static func isBool(_ v: Any?) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    static func isCount(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
        return n.doubleValue >= 0 && n.doubleValue == n.doubleValue.rounded()
    }

    /// The codes `lastError` may carry: the embedded catalogue's.
    static var codes: [String] { ErrorCatalogue.shared.codes }

    /// The eleven fields of a report, in the order every SDK writes them.
    static let fields = ["sdk", "key", "config", "model", "context", "backend", "microphone", "storage", "lastError", "droppedChunks", "connection"]

    /// Why `r` is not a report of the schema; nil when it is one.
    static func problem(_ r: [String: Any], codes: [String] = DiagnosisTests.codes) -> String? {
        guard Set(r.keys) == Set(fields) else { return "fields \(r.keys.sorted())" }
        guard let sdk = r["sdk"] as? [String: Any], Set(sdk.keys) == ["version", "latest"], matches(sdk["version"], versionPattern),
              isNull(sdk["latest"]) || matches(sdk["latest"], versionPattern) else { return "sdk" }
        guard let key = r["key"] as? [String: Any], Set(key.keys) == ["accepted", "reason"], isNull(key["accepted"]) || isBool(key["accepted"])
        else { return "key" }
        if (key["accepted"] as? Bool) == false, isBool(key["accepted"]) {
            guard ["invalid_key", "sdk_too_old", "server_rejected"].contains(key["reason"] as? String ?? "") else { return "key.reason" }
        } else if !isNull(key["reason"]) {
            return "key.reason"
        }
        guard ["fresh", "stale", "none"].contains(r["config"] as? String ?? "") else { return "config" }
        if !isNull(r["model"]) {
            guard let m = r["model"] as? [String: Any], Set(m.keys) == ["version", "build", "verified"], matches(m["version"], versionPattern),
                  matches(m["build"], "^[0-9a-f]{40}$"), isBool(m["verified"]) else { return "model" }
        }
        guard isNull(r["context"]) || matches(r["context"], "^c[0-9]+_l[0-9]+$") else { return "context" }
        if !isNull(r["backend"]) {
            guard let b = r["backend"] as? [String: Any], Set(b.keys) == ["kind", "name", "stage", "reason"],
                  let kind = b["kind"] as? String, ["cpu", "accelerator"].contains(kind),
                  ["cpu", "downloading", "compiling", "testing", "promoted", "demoted"].contains(b["stage"] as? String ?? ""),
                  isNull(b["reason"]) || matches(b["reason"], "^[a-z][a-z0-9_]{0,31}$") else { return "backend" }
            let names = kind == "cpu" ? "^(cpu|wasm)$" : "^(coreml|coreml-compact|npu:[a-z0-9_]+)$"
            guard matches(b["name"], names) else { return "backend.name" }
        }
        guard ["granted", "denied", "notAsked", "none"].contains(r["microphone"] as? String ?? "") else { return "microphone" }
        guard let storage = r["storage"] as? [String: Any], Set(storage.keys) == ["models", "sharingQueueBytes"],
              isCount(storage["sharingQueueBytes"]), let models = storage["models"] as? [[String: Any]] else { return "storage" }
        for m in models {
            guard Set(m.keys) == ["version", "build", "bytes"], matches(m["version"], versionPattern), matches(m["build"], "^[0-9a-f]{40}$"),
                  isCount(m["bytes"]) else { return "storage.models" }
        }
        guard isNull(r["lastError"]) || codes.contains(r["lastError"] as? String ?? "") else { return "lastError" }
        guard isCount(r["droppedChunks"]) else { return "droppedChunks" }
        guard ConnectionKind.allCases.map(\.rawValue).contains(r["connection"] as? String ?? "") else { return "connection" }
        return nil
    }

    func testTheRulesAgreeWithTheSharedExamples() throws {
        let e = try Vectors30.json("diagnosis_examples.json")
        let valid = try XCTUnwrap(e["valid"] as? [[String: Any]]), invalid = try XCTUnwrap(e["invalid"] as? [[String: Any]])
        XCTAssertEqual(valid.count, 7)
        XCTAssertEqual(invalid.count, 17)
        for x in valid {
            XCTAssertNil(Self.problem(try XCTUnwrap(x["report"] as? [String: Any])), x["name"] as? String ?? "?")
        }
        for x in invalid {
            XCTAssertNotNil(Self.problem(try XCTUnwrap(x["report"] as? [String: Any])), x["name"] as? String ?? "?")
        }
        // the schema's own list of codes for lastError
        let schema = try Vectors30.json("diagnosis.schema.json")
        let listed = try XCTUnwrap(((schema["properties"] as? [String: Any])?["lastError"] as? [String: Any])?["enum"] as? [Any]).compactMap { $0 as? String }
        XCTAssertTrue(Set(listed).isSubset(of: Set(Self.codes)), "every code the schema lists is in the catalogue")
        XCTAssertEqual(schema["required"] as? [String], Self.fields, "the schema's fields, in order")
        let connection = try XCTUnwrap(((schema["properties"] as? [String: Any])?["connection"] as? [String: Any])?["enum"] as? [String])
        XCTAssertEqual(connection, ConnectionKind.allCases.map(\.rawValue))
    }

    static func report(_ d: TajweedDiagnosis) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(d.json.utf8)) as? [String: Any])
    }

    /// The eleven fields in the order every SDK writes them.
    func testTheFieldsAreWrittenInTheSharedOrder() throws {
        let d = TajweedDiagnosis(sdkVersion: "3.0.0", sdkLatest: "3.0.1", key: .init(accepted: false, reason: "invalid_key"), config: "stale",
                                 model: .init(version: "4.0.0", build: AnalyticsAndIssueTests.build, verified: true), context: "c16_l64",
                                 backend: TajweedBackend(kind: .accelerator, name: "coreml", stage: .promoted, reason: nil), microphone: "denied",
                                 storage: .init(models: [.init(version: "4.0.0", build: AnalyticsAndIssueTests.build, bytes: 61_244_310)], sharingQueueBytes: 12),
                                 lastError: "microphone_denied", droppedChunks: 3, connection: "metered")
        XCTAssertNil(Self.problem(try Self.report(d)))
        var at = d.json.startIndex
        XCTAssertEqual(try Vectors30.json("names.json")["diagnosis"].flatMap { ($0 as? [String: Any])?["fields"] as? [String] }, Self.fields)
        XCTAssertEqual(Self.fields.count, 11)
        XCTAssertEqual(Self.fields.last, "connection")
        XCTAssertEqual(try Self.report(d)["droppedChunks"] as? Int, 3)
        XCTAssertEqual(try Self.report(d)["connection"] as? String, "metered")
        XCTAssertTrue(d.json.hasSuffix("  \"connection\": \"metered\"\n}"), "the last field")
        for field in Self.fields {
            let r = try XCTUnwrap(d.json.range(of: "\n  \"\(field)\": ", range: at..<d.json.endIndex), field)
            at = r.upperBound
        }
        let demoted = TajweedDiagnosis(sdkVersion: "3.0.0", sdkLatest: nil, key: .init(accepted: nil, reason: nil), config: "none", model: nil,
                                       context: nil, backend: TajweedBackend(kind: .cpu, name: "cpu", stage: .demoted, reason: "failover"),
                                       microphone: "notAsked", storage: .init(models: [], sharingQueueBytes: 0), lastError: nil, droppedChunks: 0,
                                       connection: "unknown")
        XCTAssertNil(Self.problem(try Self.report(demoted)))
        // a value outside the four is not a report
        var bad = try Self.report(demoted)
        bad["connection"] = "wifi"
        XCTAssertEqual(Self.problem(bad), "connection")
        bad["connection"] = nil
        XCTAssertNotNil(Self.problem(bad), "a report without the field")
    }

    /// A first start without a connection: no key answer, no config, no model, and the error the app got.
    func testAFirstStartWithoutAConnection() async throws {
        let storage = CloudFixtures.storage()
        StubProtocol.reset { _ in .down }
        let client = try TajweedClient(key: CloudFixtures.key, configuration: CloudFixtures.options(storage: storage),
                                       cloud: { CloudFixtures.cloud(storage: $0) })
        defer { client.close() }
        let failed = await { () async -> String? in
            do throws(TajweedError) { _ = try await client.model(); return nil } catch { return error.code }
        }()
        XCTAssertEqual(failed, "needs_connection")
        let d = await client.diagnose()
        let r = try Self.report(d)
        XCTAssertNil(Self.problem(r))
        XCTAssertEqual(d.sdkVersion, SDKInfo.version)
        XCTAssertNil(d.key.accepted)
        XCTAssertEqual(d.config, "none")
        XCTAssertNil(d.model)
        XCTAssertNil(d.context)
        XCTAssertNil(d.backend)
        XCTAssertEqual(d.storage, client.storage)
        XCTAssertEqual(d.lastError, "needs_connection")
        XCTAssertEqual(d.droppedChunks, 0)
    }

    /// Quran Lab answers and names no model build for this SDK version yet (`models: {}`, `recommended: null`): the
    /// model call fails with `model_unavailable`, the report says so, and nothing is retried in a loop.
    func testNoModelForThisSDKYet() async throws {
        let storage = CloudFixtures.storage()
        let none = CloudFixtures.config(models: [:], extra: ["recommended": NSNull()])
        StubProtocol.reset(CloudFixtures.server(config: none))
        let client = try TajweedClient(key: CloudFixtures.key, configuration: CloudFixtures.options(storage: storage),
                                       cloud: { CloudFixtures.cloud(storage: $0) })
        defer { client.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        _ = await cloud.refreshConfig()
        for call in ["model", "prefetch"] {
            let failed = await { () async -> TajweedError? in
                do throws(TajweedError) {
                    if call == "model" { _ = try await client.model() } else { try await client.prefetch() }
                    return nil
                } catch { return error }
            }()
            XCTAssertEqual(failed?.code, "model_unavailable", call)
            XCTAssertEqual(failed?.docs, "https://sdk.quranlab.ai/docs/errors#model_unavailable")
        }
        let asked = StubProtocol.seen("/v1/config").count
        XCTAssertLessThanOrEqual(asked, 3, "the config is not asked for in a loop")
        XCTAssertTrue(StubProtocol.seen.allSatisfy { !$0.path.contains("manifest.json") }, "no download is tried")
        let d = await client.diagnose()
        XCTAssertNil(Self.problem(try Self.report(d)))
        XCTAssertEqual(d.key.accepted, true)
        XCTAssertEqual(d.config, "fresh")
        XCTAssertNil(d.model)
        XCTAssertEqual(d.lastError, "model_unavailable")
    }

    /// A key the server refuses: the report names the reason, and the model call says `invalid_key`.
    func testARefusedKey() async throws {
        let storage = CloudFixtures.storage()
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            s.path.hasPrefix("/v1/attest") || s.path == "/v1/register" || s.path == "/v1/config"
                ? .json(["error": "invalid_key", "message": "unknown key"], status: 401) : nil
        }))
        let client = try TajweedClient(key: CloudFixtures.key, configuration: CloudFixtures.options(storage: storage),
                                       cloud: { CloudFixtures.cloud(storage: $0) })
        defer { client.close() }
        let failed = await { () async -> String? in
            do throws(TajweedError) { _ = try await client.model(); return nil } catch { return error.code }
        }()
        XCTAssertEqual(failed, "invalid_key")
        let d = await client.diagnose()
        XCTAssertNil(Self.problem(try Self.report(d)))
        XCTAssertEqual(d.key.accepted, false)
        XCTAssertEqual(d.key.reason, "invalid_key")
        XCTAssertEqual(d.lastError, "invalid_key")
    }
}
