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

    /// The optional fields of a report and the values of `downloadProtocol`, as the shared names.json lists them.
    static let optionalFields: [String] = {
        let names = (try? Vectors30.json("names.json"))?["diagnosis"] as? [String: Any]
        return names?["optional_fields"] as? [String] ?? []
    }()
    static let protocols: [String] = {
        let names = (try? Vectors30.json("names.json"))?["diagnosis"] as? [String: Any]
        return names?["downloadProtocol"] as? [String] ?? []
    }()

    /// Why `r` is not a report of the schema; nil when it is one.
    static func problem(_ r: [String: Any], codes: [String] = DiagnosisTests.codes) -> String? {
        // the eleven fields, the optional ones of names.json, and SDK 4.0's
        // `protected` where a runtime exists (its own shape below)
        guard Set(r.keys).subtracting(optionalFields + ["protected", "endpoints"]) == Set(fields) else { return "fields \(r.keys.sorted())" }
        // 4.0.1 (ENDPOINTS_40.md 28.7, DIAGNOSIS_40 25.3): `endpoints` where the Client has a key; Apple writes no webFrame
        if let e = r["endpoints"] {
            guard let e = e as? [String: Any], Set(e.keys) == ["api", "models", "lastFailover"],
                  isNull(e["api"]) || e["api"] is String, isNull(e["models"]) || e["models"] is String else { return "endpoints" }
            if !isNull(e["lastFailover"]) {
                // 4.0.5 (ATTEST_40.md 40.5): `check` last, a string only for invalid_answer
                guard let f = e["lastFailover"] as? [String: Any], Set(f.keys) == ["role", "from", "to", "reason", "status", "at", "check"],
                      isNull(f["check"]) || (f["reason"] as? String == "invalid_answer" && f["check"] is String),
                      ["api", "models", "web_frame"].contains(f["role"] as? String ?? ""), f["from"] is String,
                      isNull(f["to"]) || f["to"] is String,
                      ["network", "timeout", "http", "redirect", "invalid_answer"].contains(f["reason"] as? String ?? ""),
                      isNull(f["status"]) || isCount(f["status"]), isCount(f["at"]) else { return "endpoints.lastFailover" }
            }
        }
        if let named = r["downloadProtocol"] {
            guard isNull(named) || protocols.contains(named as? String ?? "") else { return "downloadProtocol" }
        }
        if let p = r["protected"] {
            guard let p = p as? [String: Any],
                  Set(p.keys).subtracting(["attestation", "lastFailure"])
                    == ["keyStore", "lease", "leaseExpires", "leaseClass", "refreshAfter", "graceUntil", "core"],
                  p["attestation"].map { a in (a as? [String: Any]).map { Set($0.keys) == ["state", "why", "failures", "nextTry"] } ?? false } ?? true,
                  p["lastFailure"].map { f in (f as? [String: Any]).map { Set($0.keys) == ["stage", "reason", "httpStatus", "errorCode", "hostRole", "fallback", "chain"] } ?? false } ?? true,
                  isNull(p["keyStore"]) || ["secureEnclave", "keychain", "software", "file"].contains(p["keyStore"] as? String ?? ""),
                  let lease = p["lease"] as? String, ["valid", "grace", "expired", "stopped", "none"].contains(lease),
                  isNull(p["leaseClass"]) || ["attested", "standard"].contains(p["leaseClass"] as? String ?? ""),
                  isNull(p["leaseExpires"]) == (lease == "none"),
                  !["none", "stopped"].contains(lease) || (isNull(p["leaseClass"]) && isNull(p["refreshAfter"])),
                  isNull(p["graceUntil"]) == (lease != "grace") else { return "protected" }
        }
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
        XCTAssertEqual(valid.count, 9)
        XCTAssertEqual(invalid.count, 18)
        XCTAssertEqual(Self.optionalFields, ["downloadProtocol"])
        XCTAssertEqual(Self.protocols, ["h3", "h2", "http/1.1"])
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

    /// SDK 4.0.5: the
    /// attestation and the last lease failure after `core`, only when known, and `lastFailover.check`; the section's
    /// example, field for field.
    func testTheAttestationAndTheLastLeaseFailure() throws {
        var d = TajweedDiagnosis(sdkVersion: "4.0.5", sdkLatest: nil, key: .init(accepted: true, reason: nil), config: "fresh", model: nil,
                                 context: nil, backend: nil, microphone: "granted", storage: .init(models: [], sharingQueueBytes: 0),
                                 lastError: nil, droppedChunks: 0, connection: "unmetered")
        var p = TajweedDiagnosis.Protected(keyStore: "secureEnclave", lease: "valid", leaseExpires: 1_796_209_600, leaseClass: "attested",
                                           refreshAfter: 1_795_080_000, graceUntil: nil, core: "4.0.0-c3 ios-arm64")
        XCTAssertFalse(d.json.contains("attestation"))
        p.attestation = .init(state: "attested", why: nil, failures: 0, nextTry: nil)
        let hops = [CauseHop(stage: "lease", hostRole: "api", host: "first", httpStatus: 200, reason: "invalid_answer", errorName: nil,
                             errorCode: "expired_on_arrival"),
                    CauseHop(stage: "lease", hostRole: "api", host: "standby", httpStatus: 503, reason: "http", errorName: nil,
                             errorCode: "service_unavailable")]
        p.lastFailure = .init(stage: "lease", reason: "invalid_answer", httpStatus: 200, errorCode: "expired_on_arrival", hostRole: "api",
                              fallback: true, chain: hops.map(\.diagnosisJSON))
        d.protected = p
        d.endpoints = .init(api: "api.quranlab.ai", models: "cdn.quranlab.ai",
                            lastFailover: .init(role: "api", from: "api.quranlab.ai", to: nil, reason: "invalid_answer", status: 200,
                                                at: 1_795_080_100, check: "expired_on_arrival"))
        XCTAssertNil(Self.problem(try Self.report(d)))
        let r = try Self.report(d)
        let prot = try XCTUnwrap(r["protected"] as? [String: Any])
        let a = try XCTUnwrap(prot["attestation"] as? [String: Any])
        XCTAssertEqual(a["state"] as? String, "attested")
        XCTAssertTrue(Self.isNull(a["why"]) && Self.isNull(a["nextTry"]))
        let f = try XCTUnwrap(prot["lastFailure"] as? [String: Any])
        XCTAssertEqual(f["errorCode"] as? String, "expired_on_arrival")
        XCTAssertEqual(f["fallback"] as? Bool, true)
        let chain = try XCTUnwrap(f["chain"] as? [[String: Any]])
        XCTAssertEqual(chain.count, 2)
        XCTAssertEqual(chain[1]["host"] as? String, "standby")
        XCTAssertNil(chain[0]["errorName"], "absent, never null")
        let e = try XCTUnwrap((r["endpoints"] as? [String: Any])?["lastFailover"] as? [String: Any])
        XCTAssertEqual(e["check"] as? String, "expired_on_arrival")
        XCTAssertTrue(d.json.contains("\"core\": \"4.0.0-c3 ios-arm64\", \"attestation\": {\"state\": \"attested\""), d.json)
    }

    /// SDK 4.0, contract section 25 (DIAGNOSIS_40.md at e5623a8): `protected` after the eleven shared fields, only with a
    /// runtime, its fields in the section's order: the section's example with an Apple key store, then its null rules.
    func testTheProtectedObjectOfSection25() throws {
        var d = TajweedDiagnosis(sdkVersion: "4.0.0", sdkLatest: nil, key: .init(accepted: true, reason: nil), config: "fresh", model: nil,
                                 context: nil, backend: nil, microphone: "granted", storage: .init(models: [], sharingQueueBytes: 0),
                                 lastError: nil, droppedChunks: 0, connection: "unmetered")
        XCTAssertFalse(d.json.contains("protected"), "no runtime: the eleven fields only")
        d.protected = .init(keyStore: "secureEnclave", lease: "valid", leaseExpires: 1_795_600_000, leaseClass: "attested",
                            refreshAfter: 1_795_100_000, graceUntil: nil, core: "4.0.0-c3 ios-arm64")
        XCTAssertNil(Self.problem(try Self.report(d)))
        XCTAssertTrue(d.json.hasSuffix("  \"protected\": {\"keyStore\": \"secureEnclave\", \"lease\": \"valid\", \"leaseExpires\": 1795600000, \"leaseClass\": \"attested\", \"refreshAfter\": 1795100000, \"graceUntil\": null, \"core\": \"4.0.0-c3 ios-arm64\"}\n}"), d.json)
        // in grace: graceUntil; stopped: no class or refresh; none: no exp; no key yet: keyStore null; no Core: core null
        d.protected = .init(keyStore: "keychain", lease: "grace", leaseExpires: 1_790_604_800, leaseClass: "standard",
                            refreshAfter: 1_790_548_000, graceUntil: 1_790_691_200, core: "4.0.0-c3 ios-arm64-simulator")
        XCTAssertNil(Self.problem(try Self.report(d)))
        d.protected = .init(keyStore: "file", lease: "stopped", leaseExpires: 1_790_604_800, leaseClass: nil, refreshAfter: nil,
                            graceUntil: nil, core: "4.0.0-c3 macos-arm64")
        XCTAssertNil(Self.problem(try Self.report(d)))
        d.protected = .init(keyStore: nil, lease: "none", leaseExpires: nil, leaseClass: nil, refreshAfter: nil, graceUntil: nil, core: nil)
        XCTAssertNil(Self.problem(try Self.report(d)))
        let p = try XCTUnwrap(try Self.report(d)["protected"] as? [String: Any])
        XCTAssertTrue(Self.isNull(p["keyStore"]) && Self.isNull(p["core"]) && Self.isNull(p["leaseExpires"]))
        // the rules refuse a stopped lease with a class, and a grace without its end
        d.protected = .init(keyStore: "keychain", lease: "stopped", leaseExpires: 1, leaseClass: "attested", refreshAfter: nil, graceUntil: nil, core: nil)
        XCTAssertEqual(Self.problem(try Self.report(d)), "protected")
        d.protected = .init(keyStore: "keychain", lease: "grace", leaseExpires: 1, leaseClass: "standard", refreshAfter: 1, graceUntil: nil, core: nil)
        XCTAssertEqual(Self.problem(try Self.report(d)), "protected")
    }

    /// SDK 4.0.1, ENDPOINTS_40.md 28.7 and DIAGNOSIS_40 25.3: `endpoints` after `protected`, its fields in the table's
    /// order (api, models, lastFailover; no webFrame on Apple), lastFailover's six in theirs, `to` and `status` null
    /// when none answered (a list of one host, or no network).
    func testTheEndpointsObjectOf28_7() throws {
        var d = TajweedDiagnosis(sdkVersion: "4.0.1", sdkLatest: nil, key: .init(accepted: true, reason: nil), config: "fresh", model: nil,
                                 context: nil, backend: nil, microphone: "granted", storage: .init(models: [], sharingQueueBytes: 0),
                                 lastError: nil, droppedChunks: 0, connection: "unmetered")
        XCTAssertFalse(d.json.contains("endpoints"), "no key: no endpoints")
        d.protected = .init(keyStore: "secureEnclave", lease: "valid", leaseExpires: 1_795_600_000, leaseClass: "attested",
                            refreshAfter: 1_795_100_000, graceUntil: nil, core: "4.0.0-c3 ios-arm64")
        d.endpoints = .init(api: "api-b.tajweedformer.com", models: "cdn.quranlab.ai",
                            lastFailover: .init(role: "api", from: "api.quranlab.ai", to: "api-b.tajweedformer.com", reason: "http",
                                                status: 503, at: 1_795_200_000, check: nil))
        XCTAssertNil(Self.problem(try Self.report(d)))
        XCTAssertTrue(d.json.hasSuffix("\"core\": \"4.0.0-c3 ios-arm64\"},\n  \"endpoints\": {\"api\": \"api-b.tajweedformer.com\", "
            + "\"models\": \"cdn.quranlab.ai\", \"lastFailover\": {\"role\": \"api\", \"from\": \"api.quranlab.ai\", "
            + "\"to\": \"api-b.tajweedformer.com\", \"reason\": \"http\", \"status\": 503, \"at\": 1795200000, \"check\": null}}\n}"), d.json)
        // none answered: to and status null; no failover yet: lastFailover null
        d.endpoints = .init(api: "api.quranlab.ai", models: "cdn.quranlab.ai",
                            lastFailover: .init(role: "models", from: "cdn.quranlab.ai", to: nil, reason: "network", status: nil, at: 1_795_200_001, check: nil))
        XCTAssertNil(Self.problem(try Self.report(d)))
        XCTAssertTrue(d.json.contains("\"to\": null, \"reason\": \"network\", \"status\": null"), d.json)
        d.endpoints = .init(api: "api.quranlab.ai", models: "cdn.quranlab.ai", lastFailover: nil)
        XCTAssertNil(Self.problem(try Self.report(d)))
        XCTAssertTrue(d.json.hasSuffix("  \"endpoints\": {\"api\": \"api.quranlab.ai\", \"models\": \"cdn.quranlab.ai\", \"lastFailover\": null}\n}"))
        // the rules refuse a reason that is not one of 28.7's, and a field that is not the table's
        var bad = try Self.report(d)
        bad["endpoints"] = ["api": "api.quranlab.ai", "models": "cdn.quranlab.ai", "lastFailover": NSNull(), "webFrame": "web.quranlab.ai"]
        XCTAssertEqual(Self.problem(bad), "endpoints")
        bad["endpoints"] = ["api": "api.quranlab.ai", "models": "cdn.quranlab.ai",
                            "lastFailover": ["role": "api", "from": "api.quranlab.ai", "to": NSNull(), "reason": "refused", "status": 403, "at": 1]]
        XCTAssertEqual(Self.problem(bad), "endpoints.lastFailover")
    }
}
