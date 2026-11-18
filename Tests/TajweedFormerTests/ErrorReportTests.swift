import Foundation
import XCTest
@testable import TajweedFormer

/// Contract section 24 on the SDK's real code: each failure made by a stand-in server (`StubProtocol`), a key store that
/// fails, or the code that makes the app's error, and the report it leaves in the book (`cloud/error-reports.json`):
/// its stage, reason, status, code and count; the code the app gets (24.4); the send point and its body (24.2, 24.6);
/// `flags.issues`; the telemetry of a failed download (24.8).
final class ErrorReportTests: XCTestCase {
    override func tearDown() {
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// A Client on a fresh storage over the stand-in server, and its server client.
    private func makeClient(_ storage: URL, installKeys: any InstallKeyStoring = CloudFixtures.installKeys) throws -> (TajweedClient, QuranLabCloud) {
        let c = try TajweedClient(key: CloudFixtures.key, configuration: CloudFixtures.options(storage: storage),
                                  cloud: { CloudFixtures.cloud(storage: $0, installKeys: installKeys) })
        return (c, try XCTUnwrap(QuranLab.cloud))
    }

    private static func modelError(_ c: TajweedClient) async -> TajweedError? {
        do throws(TajweedError) { _ = try await c.model(); return nil } catch { return error }
    }

    /// The book once every occurrence so far is in it.
    private static func book(_ cloud: QuranLabCloud) -> ErrorReportBook {
        cloud.errorReports.waitForSave()
        return cloud.errorReports.snapshot
    }

    /// 24.4: the config answered 503 and nothing is on the device: `download_failed` naming the answer, never
    /// `needs_connection` (Apple 3.1.4 answered `needs_connection`). Two reports with the cause's stage (24.1):
    /// the config's own, silent (code `none`), and the model call's (`download_failed`).
    func testAServerFailureIsDownloadFailed() async throws {
        StubProtocol.reset(CloudFixtures.server(config: StubProtocol.Reply(status: 503)))
        let (client, cloud) = try makeClient(CloudFixtures.storage())
        defer { client.close() }
        let e = await Self.modelError(client)
        XCTAssertEqual(e?.code, "download_failed")
        XCTAssertTrue(e?.message.contains("503") ?? false, e?.message ?? "")
        let q = Self.book(cloud).queue
        XCTAssertEqual(q.map(\.code), ["none", "download_failed"])
        for r in q {
            XCTAssertEqual(r.stage, "config")
            XCTAssertEqual(r.reason, "http")
            XCTAssertEqual(r.httpStatus, 503)
            XCTAssertEqual(r.count, 1)
            XCTAssertEqual(r.firstReport, true)
            XCTAssertEqual(r.firstLaunch, true)
        }
    }

    /// 24.4: no request got any answer and nothing is on the device: `needs_connection`, reported at the stage that
    /// failed first (the token), with the system's error domain and code and never its message.
    func testNoAnswerAtAllIsNeedsConnection() async throws {
        StubProtocol.reset { _ in .down }
        let (client, cloud) = try makeClient(CloudFixtures.storage())
        defer { client.close() }
        let e = await Self.modelError(client)
        XCTAssertEqual(e?.code, "needs_connection")
        let q = Self.book(cloud).queue
        XCTAssertEqual(q.map(\.stage), ["attest"])
        XCTAssertEqual(q.first?.reason, "network")
        XCTAssertEqual(q.first?.code, "needs_connection")
        XCTAssertNil(q.first?.httpStatus)
        XCTAssertEqual(q.first?.errorName, NSURLErrorDomain)
        XCTAssertEqual(q.first?.errorCode, String(NSURLErrorNotConnectedToInternet))
    }

    /// The manifest answered 502: `download_failed`, stage `manifest`; and the failed download counts in the day's
    /// telemetry under `http` (24.8: to 3.1.5 a 5xx, worded as no answer, counted as `network`).
    func testAManifestThatAnswers502() async throws {
        StubProtocol.reset(CloudFixtures.server(extra: { s in s.url.host == CloudFixtures.cdn.host ? StubProtocol.Reply(status: 502) : nil }))
        let (client, cloud) = try makeClient(CloudFixtures.storage())
        defer { client.close() }
        let e = await Self.modelError(client)
        XCTAssertEqual(e?.code, "download_failed")
        let q = Self.book(cloud).queue
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(q.first?.stage, "manifest")
        XCTAssertEqual(q.first?.reason, "http")
        XCTAssertEqual(q.first?.httpStatus, 502)
        XCTAssertEqual(q.first?.code, "download_failed")
        let p = cloud.analytics.payload(try XCTUnwrap(cloud.analytics.pending.first), reportID: "6f1c0e9a4b2d47e8a1c3f5d7b9e0a2c4")
        let downloads = try XCTUnwrap(p["downloads"] as? [[String: Any]])
        XCTAssertEqual(downloads.count, 1)
        XCTAssertEqual(downloads.first?["failed"] as? Int, 1)
        XCTAssertEqual(downloads.first?["failure_reasons"] as? [String: Int], ["http": 1])
    }

    /// The device's key store fails: `storage_failed`, stage `storage`.
    func testAKeyStoreThatFails() async throws {
        StubProtocol.reset(CloudFixtures.server())
        let keys = MemoryInstallKeyStore()
        keys.fail("the keychain is locked")
        let (client, cloud) = try makeClient(CloudFixtures.storage(), installKeys: keys)
        defer { client.close() }
        let e = await Self.modelError(client)
        XCTAssertEqual(e?.code, "storage_failed")
        let q = Self.book(cloud).queue
        XCTAssertEqual(q.map(\.stage), ["storage"])
        XCTAssertEqual(q.first?.code, "storage_failed")
    }

    /// 24.1: the microphone refused is reported (stage `audio`); the app's own misuse is not.
    func testTheMicrophoneIsReportedAndMisuseIsNot() throws {
        StubProtocol.reset(CloudFixtures.server())
        let (client, cloud) = try makeClient(CloudFixtures.storage())
        defer { client.close() }
        _ = TajweedError(.microphoneDenied)
        _ = TajweedError(.sessionClosed)
        _ = TajweedError(from: .cancelled)
        _ = TajweedError.argument("a context the model does not have")
        let q = Self.book(cloud).queue
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(q.first?.stage, "audio")
        XCTAssertEqual(q.first?.reason, "permission_denied")
        XCTAssertEqual(q.first?.code, "microphone_denied")
    }

    /// 24.6: a send point sends each queued report as one `POST /v1/issues` with `kind: "error"` and the closed
    /// `error` object, no message, frames or detail; the 202 takes it off the queue and puts it on the reported list.
    func testTheSendPointAndItsBody() async throws {
        StubProtocol.reset(CloudFixtures.server(config: StubProtocol.Reply(status: 503)))
        let (client, cloud) = try makeClient(CloudFixtures.storage())
        defer { client.close() }
        _ = await Self.modelError(client)
        _ = Self.book(cloud)
        _ = await cloud.flush()
        let sent = StubProtocol.seen("/v1/issues").compactMap(\.json).filter { $0["kind"] as? String == "error" }
        XCTAssertEqual(sent.map { $0["code"] as? String }, ["none", "download_failed"])
        let body = try XCTUnwrap(sent.last)
        XCTAssertEqual(body["code"] as? String, "download_failed")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["sdk_version"] as? String, SDKInfo.version)
        XCTAssertTrue(Set(body.keys).isSubset(of: ["day", "platform", "sdk_version", "app_version", "os_version", "device_class",
                                                   "revision", "backend", "kind", "code", "error"]), "\(body.keys)")
        let error = try XCTUnwrap(body["error"] as? [String: Any])
        XCTAssertTrue(Set(error.keys).isSubset(of: ["stage", "reason", "http_status", "error_name", "error_code", "count", "retries",
                                                    "first_launch", "first_report", "build", "device_model", "ram_tier",
                                                    "storage_free", "abi"]), "\(error.keys)")
        XCTAssertEqual(error["stage"] as? String, "config")
        XCTAssertEqual(error["reason"] as? String, "http")
        XCTAssertEqual(error["http_status"] as? Int, 503)
        XCTAssertEqual(error["count"] as? Int, 1)
        XCTAssertEqual(error["first_report"] as? Bool, true)
        XCTAssertEqual(error["abi"] as? String, "arm64")
        let after = Self.book(cloud)
        XCTAssertTrue(after.queue.isEmpty)
        XCTAssertEqual(after.reported.count, 2)
    }

    /// 24.5: `flags.issues: false` records nothing, and drops the queue at the next send point.
    func testIssuesOff() async throws {
        StubProtocol.reset(CloudFixtures.server())
        let (client, cloud) = try makeClient(CloudFixtures.storage())
        defer { client.close() }
        cloud.errorReports.occur(ErrorCause(stage: "runtime", reason: "memory"), code: "engine_failed", enabled: true)
        XCTAssertEqual(Self.book(cloud).queue.count, 1)
        // Quran Lab turns issues off in the signed config
        StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(flags: ["issues": false])))
        _ = await cloud.refreshConfig()
        XCTAssertEqual(cloud.currentConfig?.flags.issues, false)
        _ = TajweedError(.microphoneDenied)
        _ = await cloud.flush()
        XCTAssertTrue(Self.book(cloud).queue.isEmpty)
        XCTAssertTrue(StubProtocol.seen("/v1/issues").compactMap(\.json).filter { $0["kind"] as? String == "error" }.isEmpty)
    }

    /// 24.1 item 2: a telemetry report the server refused (400) is a silent failure: stage `events`, code `none`.
    func testARefusedTelemetryReport() async throws {
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            switch s.path {
            case "/v1/events": return .json(["error": "invalid_body"], status: 400)
            case "/v1/issues": return StubProtocol.Reply(status: 503)
            default: return nil
            }
        }))
        let (client, cloud) = try makeClient(CloudFixtures.storage())
        defer { client.close() }
        cloud.analytics.count(.launch)
        _ = await cloud.flush()
        let q = Self.book(cloud).queue.filter { $0.stage == "events" }
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(q.first?.reason, "http")
        XCTAssertEqual(q.first?.httpStatus, 400)
        XCTAssertEqual(q.first?.code, "none")
    }
}
