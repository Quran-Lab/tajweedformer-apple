import Foundation
import XCTest
@testable import TajweedFormer

/// A stop is read only from an answer whose status is 401 or 403 (3.1.5; SPEC 15.3 of contract 1.19.2): a body that
/// names a stop reason under any other status is not a stop. Nothing is remembered, no model file is removed, the
/// model keeps opening, and the launch's network calls go on.
///
/// Over the suite's stub API and CDN, with a model from a real download of the bundled test folder; the device's key
/// store is a stand-in. (The shared vector `model_gate.json` has the same two answers as cases since contract 1.22.1;
/// these tests look at them one at a time, with what the vector does not name.)
final class StopStatusTests: XCTestCase {
    let fm = FileManager.default

    override func setUp() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { _ in FakeCPUEngine() } }
    }

    override func tearDown() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = nil }
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// A body that names a stop reason.
    static func body(_ error: String) -> [String: Any] { ["error": error, "message": "Not now.", "reason": "key_revoked"] }

    /// A first launch that downloads the build; the storage, the device and the build id.
    func downloaded() async throws -> (storage: URL, device: MemoryInstallKeyStore, build: String) {
        let build = try OnlineOnlyTests.serve()
        let device = MemoryInstallKeyStore()
        let storage = CloudFixtures.storage()
        let client = try StubbedModelServer.client(storage: storage, installKeys: device)
        let got = await OnlineOnlyTests.model(client)
        client.close()
        XCTAssertEqual(got.build, build, "the first launch downloads the build: \(String(describing: got.error))")
        return (storage, device, build)
    }

    func modelFiles(_ storage: URL) -> [String] {
        let dir = storage.appendingPathComponent("models")
        guard let e = fm.enumerator(atPath: dir.path) else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            if rel.hasPrefix("recommended.json") { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.appendingPathComponent(rel).path, isDirectory: &isDir), !isDir.boolValue { out.append(rel) }
        }
        return out.sorted()
    }

    /// Every answer of the API is a 429 whose body names the stop reason `key_revoked`: the model that was downloaded
    /// opens, nothing is remembered, no model file is removed, and the launch's calls are not stopped.
    func testA429OfTheAPIThatNamesAStopReasonStopsNothing() async throws {
        let made = try await downloaded()
        let files = modelFiles(made.storage)
        let reply = StubProtocol.Reply.json(Self.body("rate_limited"), status: 429)
        StubProtocol.reset { s in s.url.host == CloudFixtures.api.host ? reply : StubProtocol.Reply(status: 404) }
        let client = try StubbedModelServer.client(storage: made.storage, installKeys: made.device)
        let cloud = try XCTUnwrap(QuranLab.cloud)
        _ = await cloud.refreshConfig()
        XCTAssertNil(cloud.gate.stop, "nothing is remembered")
        XCTAssertFalse(fm.fileExists(atPath: made.storage.appendingPathComponent("cloud/model-stop.json").path))
        XCTAssertFalse(cloud.isStopped, "the launch's calls go on")
        let got = await OnlineOnlyTests.model(client)
        XCTAssertEqual(got.build, made.build, "the model opens: \(String(describing: got.error))")
        XCTAssertEqual(modelFiles(made.storage), files, "no model file is removed")
        client.close()
    }

    /// A model request is answered 404 with a body that names the stop reason `key_revoked` (the config names a build
    /// the download server does not have): nothing is remembered, no model file is removed, and the model that was
    /// downloaded keeps opening.
    func testA404OfAModelRequestThatNamesAStopReasonStopsNothing() async throws {
        let made = try await downloaded()
        let files = modelFiles(made.storage)
        let newer = String(repeating: "b", count: 40)
        let reply = StubProtocol.Reply.json(Self.body("not_found"), status: 404)
        try OnlineOnlyTests.serve(named: newer, cdn: { _, _ in reply })
        let client = try StubbedModelServer.client(storage: made.storage, installKeys: made.device)
        let cloud = try XCTUnwrap(QuranLab.cloud)
        _ = await cloud.refreshConfig()
        _ = await cloud.checkForUpdate(.recommended)
        XCTAssertFalse(OnlineOnlyTests.modelRequests.isEmpty, "the CDN was asked")
        XCTAssertNil(cloud.gate.stop, "nothing is remembered")
        XCTAssertFalse(fm.fileExists(atPath: made.storage.appendingPathComponent("cloud/model-stop.json").path))
        XCTAssertFalse(cloud.isStopped)
        XCTAssertEqual(modelFiles(made.storage), files, "no model file is removed")
        let got = await OnlineOnlyTests.model(client)
        XCTAssertNotEqual(got.error?.code, "server_rejected", "no refusal")
        XCTAssertNotEqual(got.error?.code, "invalid_key")
        client.close()
    }

    /// The model gate itself: an answer that names a stop reason stops the model only under 401 or 403.
    func testTheGateTakesAStopOnlyFromA401OrA403() {
        for status in [400, 404, 409, 410, 429] {
            let storage = CloudFixtures.storage()
            let gate = ModelGate(storage: storage)
            gate.note(.rejected(status: status, code: "x", message: "", reason: "key_revoked"), from: .api)
            XCTAssertNil(gate.stop, "HTTP \(status) with a stop reason is not a stop")
            XCTAssertFalse(fm.fileExists(atPath: storage.appendingPathComponent("cloud/model-stop.json").path), "HTTP \(status)")
        }
        for status in [401, 403] {
            let gate = ModelGate(storage: CloudFixtures.storage())
            gate.note(.rejected(status: status, code: "x", message: "", reason: "key_revoked"), from: .api)
            XCTAssertEqual(gate.stop?.reason, "key_revoked", "HTTP \(status) with a stop reason is a stop")
        }
    }

    /// A range the background session fetched comes back 404 with a body that names a stop reason: it is not a
    /// refusal (its bytes are discarded as for any other failed range).
    func testABackgroundRangeAnswered404WithAStopReasonIsNotARefusal() throws {
        let storage = CloudFixtures.storage()
        let folder = "models/v4.0/.download-test"
        try fm.createDirectory(at: storage.appendingPathComponent(folder), withIntermediateDirectories: true)
        let gate = ModelGate(storage: storage)
        let sink = RangeDelivery.Sink(storage: storage, refused: { gate.note($0, from: .model) }, redirected: { _ in })
        let range = BackgroundRange(folder: folder, path: "c16_l64/frames.zfw.gz", lower: 100, upper: 199, size: 1000)
        let asked = try XCTUnwrap(URL(string: "https://cdn.test/Quran-Lab/tajweedformer-v4/abc/sdk/v4.0/c16_l64/frames.zfw.gz"))
        let file = fm.temporaryDirectory.appendingPathComponent("range-" + UUID().uuidString)
        try JSONSerialization.data(withJSONObject: Self.body("not_found")).write(to: file)
        let arrival = RangeDelivery.Arrival(body: file, key: range.key, status: 404, asked: asked, final: asked, redirects: 0,
                                            contentRange: nil)
        let outcome = RangeDelivery.deliver(arrival, sink: sink)
        XCTAssertNotEqual(outcome, .refused, "a 404 is not a refusal, whatever its body names")
        XCTAssertNil(gate.stop, "and the gate remembers nothing")
    }
}
