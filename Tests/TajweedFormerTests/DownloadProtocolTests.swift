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
    override func setUp() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { _ in FakeCPUEngine() } }
    }

    override func tearDown() {
        HTTPClient.networkProtocolOverride.withLock { $0 = nil }
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = nil }
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
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

    /// No model request was answered yet: `diagnose()` names no protocol, and the report's JSON has no such key.
    /// After a download whose requests went by `h3` (the stand-in for the metric says so): `h3`, in the typed report
    /// and as the optional key `downloadProtocol` of the JSON. It is held in memory for this
    /// Client in this process (SPEC 16.3): the next Client starts without one, also on the same storage, and a
    /// later download by another protocol replaces it.
    func testDiagnoseReportsTheProtocolOfTheLastModelRequestOfThisClient() async throws {
        try StubbedModelServer.serve()
        let storage = CloudFixtures.storage()
        let client = try StubbedModelServer.client(storage: storage)
        var d = await client.diagnose()
        XCTAssertNil(d.downloadProtocol, "no model request was answered yet")
        XCTAssertNil(try DiagnosisTests.report(d)["downloadProtocol"], "and the JSON has no such key")
        // model requests go by h3; any other request names nothing
        HTTPClient.networkProtocolOverride.withLock {
            $0 = { request in request.url?.host == CloudFixtures.cdn.host ? "h3" : nil }
        }
        defer { HTTPClient.networkProtocolOverride.withLock { $0 = nil } }
        let model = try await client.model()
        await model.close()
        d = await client.diagnose()
        XCTAssertEqual(d.downloadProtocol, "h3")
        XCTAssertEqual(try DiagnosisTests.report(d)["downloadProtocol"] as? String, "h3", "the optional key of the shared report")
        XCTAssertNil(DiagnosisTests.problem(try DiagnosisTests.report(d)), "the report is one of the shared schema")
        XCTAssertTrue(d.json.hasSuffix("  \"downloadProtocol\": \"h3\"\n}"), "written after the eleven fields")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent("cloud/model-download.json").path),
                       "nothing of it is kept on the device")
        client.close()
        // the next Client on the same storage: the model is on the device, no model request is made, no protocol
        HTTPClient.networkProtocolOverride.withLock { $0 = nil }
        try StubbedModelServer.serve()
        let next = try StubbedModelServer.client(storage: storage)
        defer { next.close() }
        d = await next.diagnose()
        XCTAssertNil(d.downloadProtocol, "a protocol of an earlier Client says nothing about this one")
        // a download by another protocol
        HTTPClient.networkProtocolOverride.withLock { $0 = { _ in "h2" } }
        try next.removeModels()
        let again = try await next.model()
        await again.close()
        d = await next.diagnose()
        XCTAssertEqual(d.downloadProtocol, "h2")
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
        var d = TajweedDiagnosis(sdkVersion: "3.1.5", sdkLatest: nil, key: .init(accepted: true, reason: nil), config: "fresh", model: nil,
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
