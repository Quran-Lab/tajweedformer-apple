import Foundation
import XCTest
@testable import TajweedFormer

/// HTTP/3 on the model requests, and the protocol of the last model download in `diagnose()` (3.1.5).
/// The mark that the server speaks HTTP/3 is on the model requests and on no other request. The protocol a model
/// request went by is read from the task's metrics and kept on the device as a local record; `diagnose()` reads
/// it, and nothing sends it. The suite's stub server answers inside the process, so the system's metrics name no
/// protocol here: the tests give one through a stand-in for the metric (`HTTPClient.networkProtocolOverride`). That
/// a real connection to Quran Lab's host goes by HTTP/3 is not shown by any test.
final class DownloadProtocolTests: XCTestCase {
    override func tearDown() {
        HTTPClient.networkProtocolOverride.withLock { $0 = nil }
        ModelDownloadRecord.reset()
    }

    /// The mark is set on a model request (with or without a range) and on nothing else.
    func testOnlyModelRequestsSayThatTheServerSpeaksHTTP3() throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.test/Quran-Lab/tajweedformer-v4/abc/sdk/v4.0/layers.zfw.gz"))
        let ranged = CDNClient.request(url, range: "bytes=0-9", key: "k", token: "t")
        XCTAssertTrue(ranged.assumesHTTP3Capable)
        XCTAssertEqual(ranged.value(forHTTPHeaderField: "range"), "bytes=0-9")
        XCTAssertEqual(ranged.value(forHTTPHeaderField: "x-qlab-key"), "k")
        XCTAssertEqual(ranged.value(forHTTPHeaderField: "authorization"), "Bearer t")
        let whole = CDNClient.request(url, range: nil, key: "k", token: "t")
        XCTAssertTrue(whole.assumesHTTP3Capable)
        XCTAssertNil(whole.value(forHTTPHeaderField: "range"))
        // the API's requests, and a request as the system makes it, do not carry it
        let api = try HTTPClient.jsonRequest(CloudFixtures.api.appendingPathComponent("v1/register"), body: ["a": 1], auth: "t")
        XCTAssertFalse(api.assumesHTTP3Capable)
        XCTAssertFalse(URLRequest(url: url).assumesHTTP3Capable)
    }

    /// No model request was answered yet: no protocol, and the report's JSON has no such key. After a download whose
    /// requests went by `h3` (the stand-in for the metric says so): `h3`, in the typed report and as the optional key
    /// `downloadProtocol` of the JSON, written after the eleven fields and before 4.0's `protected`
    /// (DIAGNOSIS_40 25.1). A later download by another protocol replaces it; nothing of it is kept on the device. 4.0:
    /// on the CDN client a run makes (3.1.5 ran this through the public Client on a plaintext folder; a 4.0 build
    /// installs only under a lease, which a stub server cannot give).
    func testDiagnoseReportsTheProtocolOfTheLastModelRequest() async throws {
        ModelDownloadRecord.reset()
        var d = TajweedDiagnosis(sdkVersion: "4.0.0", sdkLatest: nil, key: .init(accepted: true, reason: nil), config: "fresh", model: nil,
                                 context: nil, backend: nil, microphone: "notAsked", storage: .init(models: [], sharingQueueBytes: 0),
                                 lastError: nil, droppedChunks: 0, connection: "unmetered", downloadProtocol: ModelDownloadRecord.networkProtocol)
        XCTAssertNil(d.downloadProtocol, "no model request was answered yet")
        XCTAssertNil(try DiagnosisTests.report(d)["downloadProtocol"], "and the JSON has no such key")
        StubProtocol.reset { seen in ModelDownloadTests.served(seen) }
        // model requests go by h3; any other request names nothing
        HTTPClient.networkProtocolOverride.withLock { $0 = { request in request.url?.host == "cdn.quranlab.ai" ? "h3" : nil } }
        var client = CDNClient(http: HTTPClient(session: StubProtocol.session()), base: URL(string: "https://cdn.quranlab.ai/models")!,
                               auth: .fixed(key: "qlk_v1_test", token: "qlt_test"), verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
        client.protocolSeen = { ModelDownloadRecord.note($0) }
        let source = client.source(ModelID("v4.0", repository: "Quran-Lab/m"), revision: "b", base: ModelDownloadTests.base)
        _ = try await source.bytes(ModelDownloadTests.weights, lower: 0, upper: 99, size: Int64(ModelDownloadTests.stored.count))
        d = TajweedDiagnosis(sdkVersion: "4.0.0", sdkLatest: nil, key: .init(accepted: true, reason: nil), config: "fresh", model: nil,
                             context: nil, backend: nil, microphone: "notAsked", storage: .init(models: [], sharingQueueBytes: 0),
                             lastError: nil, droppedChunks: 0, connection: "unmetered", downloadProtocol: ModelDownloadRecord.networkProtocol)
        XCTAssertEqual(d.downloadProtocol, "h3")
        XCTAssertEqual(try DiagnosisTests.report(d)["downloadProtocol"] as? String, "h3", "the optional key of the shared report")
        XCTAssertNil(DiagnosisTests.problem(try DiagnosisTests.report(d)), "the report is one of the shared schema")
        XCTAssertTrue(d.json.hasSuffix("  \"downloadProtocol\": \"h3\"\n}"), "written after the eleven fields")
        d.protected = .init(keyStore: "file", lease: "valid", leaseExpires: 1_795_600_000, leaseClass: "standard", refreshAfter: 1_795_100_000,
                            graceUntil: nil, core: "4.0.0-c1 macos-arm64")
        XCTAssertTrue(d.json.contains("  \"downloadProtocol\": \"h3\",\n  \"protected\": {"), "downloadProtocol, then protected: \(d.json)")
        XCTAssertNil(DiagnosisTests.problem(try DiagnosisTests.report(d)))
        // a download by another protocol
        HTTPClient.networkProtocolOverride.withLock { $0 = { _ in "h2" } }
        _ = try await source.bytes(ModelDownloadTests.weights, lower: 0, upper: 99, size: Int64(ModelDownloadTests.stored.count))
        XCTAssertEqual(ModelDownloadRecord.networkProtocol, "h2")
    }

    /// What is held: the last protocol named, nothing after a reset; and a protocol the shared schema does not
    /// know is not written to the report's JSON.
    func testTheLastProtocolIsHeldInMemory() throws {
        ModelDownloadRecord.reset()
        XCTAssertNil(ModelDownloadRecord.networkProtocol)
        ModelDownloadRecord.note("http/1.1")
        XCTAssertEqual(ModelDownloadRecord.networkProtocol, "http/1.1")
        ModelDownloadRecord.note("h3")
        XCTAssertEqual(ModelDownloadRecord.networkProtocol, "h3")
        ModelDownloadRecord.reset()
        XCTAssertNil(ModelDownloadRecord.networkProtocol)
        var d = TajweedDiagnosis(sdkVersion: "4.0.0", sdkLatest: nil, key: .init(accepted: true, reason: nil), config: "fresh", model: nil,
                                 context: nil, backend: nil, microphone: "notAsked", storage: .init(models: [], sharingQueueBytes: 0),
                                 lastError: nil, droppedChunks: 0, connection: "unmetered")
        d.downloadProtocol = "spdy/3"
        XCTAssertNil(try DiagnosisTests.report(d)["downloadProtocol"], "not one of the schema's values: not written")
        XCTAssertNil(DiagnosisTests.problem(try DiagnosisTests.report(d)))
        d.downloadProtocol = "http/1.1"
        XCTAssertEqual(try DiagnosisTests.report(d)["downloadProtocol"] as? String, "http/1.1")
        XCTAssertNil(DiagnosisTests.problem(try DiagnosisTests.report(d)))
    }
}
