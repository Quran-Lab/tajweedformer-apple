import Foundation
import XCTest
@testable import TajweedFormer

/// A stop is read only from an answer whose status is 401 or 403 (3.1.5; SPEC 15.3 of contract 1.19.2): a body that
/// names a stop reason under any other status is not a stop. Nothing is remembered, no model file is removed, and the
/// launch's network calls go on.
///
/// Over the suite's stub API and CDN; the device's key store is a stand-in. 3.1.5 also opened a downloaded plaintext
/// model after each answer; a 4.0 build opens only under a lease the Core holds, so here the model's files are a
/// stand-in folder and what is checked is that nothing removes them. (The shared vector `model_gate.json` has the same
/// two answers as cases since contract 1.22.1.)
final class StopStatusTests: XCTestCase {
    let fm = FileManager.default

    override func tearDown() {
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// A body that names a stop reason.
    static func body(_ error: String) -> [String: Any] { ["error": error, "message": "Not now.", "reason": "key_revoked"] }

    /// A storage with a stand-in build folder under models (the device forms of a 4.0 build).
    func installed() throws -> URL {
        let storage = CloudFixtures.storage()
        let dir = storage.appendingPathComponent("models/v4.0/" + String(repeating: "a", count: 40))
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["layers.zfw.qld", "tokens.txt.qld", "manifest.json"] { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        return storage
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

    /// Every answer of the API is a 429 whose body names the stop reason `key_revoked`: nothing is remembered, no
    /// model file is removed, and the launch's calls are not stopped.
    func testA429OfTheAPIThatNamesAStopReasonStopsNothing() async throws {
        let storage = try installed()
        let files = modelFiles(storage)
        let reply = StubProtocol.Reply.json(Self.body("rate_limited"), status: 429)
        StubProtocol.reset { s in s.url.host == CloudFixtures.api.host ? reply : StubProtocol.Reply(status: 404) }
        let options = CloudFixtures.options(updates: .manual, storage: storage)
        let client = try TajweedClient(key: CloudFixtures.key, configuration: options, cloud: { root in CloudFixtures.cloud(storage: root, options: options) })
        defer { client.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        _ = await cloud.refreshConfig()
        XCTAssertNil(cloud.gate.stop, "nothing is remembered")
        XCTAssertFalse(fm.fileExists(atPath: storage.appendingPathComponent("cloud/model-stop.json").path))
        XCTAssertFalse(cloud.isStopped, "the launch's calls go on")
        XCTAssertEqual(modelFiles(storage), files, "no model file is removed")
    }

    /// A model request is answered 404 with a body that names the stop reason `key_revoked` (a build the download
    /// server does not have): the CDN client tells the gate, which remembers nothing, and no model file is removed.
    func testA404OfAModelRequestThatNamesAStopReasonStopsNothing() async throws {
        let storage = try installed()
        let files = modelFiles(storage)
        let gate = ModelGate(storage: storage)
        let reply = StubProtocol.Reply.json(Self.body("not_found"), status: 404)
        StubProtocol.reset { _ in reply }
        let client = CDNClient(http: HTTPClient(session: StubProtocol.session()), base: URL(string: "https://cdn.quranlab.ai/models")!,
                               auth: .fixed(key: "qlk_v1_test", token: "qlt_test"), verifier: ManifestVerifier(trustedKeys: [], requireSignature: false),
                               refused: { gate.note($0, from: .model) })
        do {
            _ = try await client.manifest(ModelID("v4.0", repository: "Quran-Lab/m"), revision: String(repeating: "b", count: 40))
            XCTFail("a 404 is no manifest")
        } catch {
            XCTAssertNotEqual(TajweedError(from: error).code, "server_rejected", "no refusal")
            XCTAssertNotEqual(TajweedError(from: error).code, "invalid_key")
        }
        XCTAssertFalse(StubProtocol.seen.isEmpty, "the CDN was asked")
        XCTAssertNil(gate.stop, "nothing is remembered")
        XCTAssertFalse(fm.fileExists(atPath: storage.appendingPathComponent("cloud/model-stop.json").path))
        XCTAssertEqual(modelFiles(storage), files, "no model file is removed")
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
