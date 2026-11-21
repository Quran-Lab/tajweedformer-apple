import Foundation
import QuranLabCore
import XCTest
@testable import TajweedFormer

/// Gate C (the first 24 hours of SDK 4.0, 2026-11-20), for every native SDK: when the Core fails a model open the
/// error report names the Core's status in `error_code` (`busy`, `nomem`, `engine`, `arg`), reason `memory` for
/// `nomem` (ERRORS_40 24.3 `model_open`, 24.4 rule 4: the app gets `engine_failed`, "not enough memory"); and a Model
/// that `client.model()` opened and does not hand out is closed, never dropped open.
final class ModelOpenReportTests: XCTestCase {
    func testTheCoreStatusIsTheErrorCode() throws {
        let cases: [(Int32, String, String)] = [(Int32(QLC_E_BUSY), "engine", "busy"), (Int32(QLC_E_NOMEM), "memory", "nomem"),
                                                (Int32(QLC_E_ENGINE), "engine", "engine"), (Int32(QLC_E_ARG), "engine", "arg")]
        for (status, reason, code) in cases {
            let e = CoreFailure(status, call: "qlc_model_open").recognizerError
            let cause = ErrorCause.of(e, stage: "model_open")
            XCTAssertEqual(cause.stage, "model_open", code)
            XCTAssertEqual(cause.reason, reason, code)
            XCTAssertEqual(cause.errorCode, code)
            // a token of 24.2, never the status number
            XCTAssertNotNil(cause.errorCode?.range(of: #"^[A-Za-z0-9_.:-]{1,32}$"#, options: .regularExpression))
            // the code the app gets: engine_failed (24.4 rule 4)
            XCTAssertEqual(ErrorRules.code(stage: cause.stage, reason: cause.reason, errorCode: cause.errorCode), "engine_failed", code)
            XCTAssertEqual(TajweedError(from: e, stage: "model_open").code, "engine_failed", code)
        }
        // out of memory says so to the app
        let nomem = TajweedError(from: CoreFailure(Int32(QLC_E_NOMEM), call: "qlc_model_open").recognizerError, stage: "model_open")
        XCTAssertTrue(nomem.message.contains("not enough memory"), nomem.message)
        // the same names in a take (stage session, whose reasons have `memory` too) and at the accelerator
        let inTake = ErrorCause.of(CoreFailure(Int32(QLC_E_NOMEM), call: "qlc_stream_push").recognizerError, stage: "session")
        XCTAssertEqual([inTake.reason, inTake.errorCode], ["memory", "nomem"])
        let accel = ErrorCause.of(RecognizerError.engineFailed(code: Int(QLC_E_BUSY), message: "busy"), stage: "accelerator")
        XCTAssertEqual([accel.reason, accel.errorCode], ["load", "busy"])
        // every status has a name; a value that is no Core status keeps its number
        for s in [QLC_E_ARG, QLC_E_NOMEM, QLC_E_STORAGE, QLC_E_MANIFEST, QLC_E_NEEDS_CONNECTION, QLC_E_LEASE, QLC_E_FILE, QLC_E_ENGINE,
                  QLC_E_STOPPED, QLC_E_KEYSTORE, QLC_E_BUSY] {
            XCTAssertNotNil(CoreFailure.statusName(Int(s)), "\(s)")
        }
        XCTAssertEqual(ErrorCause.of(RecognizerError.engineFailed(code: -99, message: "x"), stage: "model_open").errorCode, "-99")
        // every engine failure the SDK makes carries a Core status: no placeholder that would read as one (a -1 read as
        // `arg`)
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TajweedFormer")
        let e = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in e where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertNil(text.range(of: #"engineFailed\(code: *-?[0-9]"#, options: .regularExpression), "\(url.lastPathComponent): a literal code")
        }
    }

    /// ERRORS_40 24.3 at 7f097b9: errors_40.json's `core_open`, each Core status that fails `qlc_model_open` (Apple
    /// answers engine_failed for all four) to the report's reason and error_code and the app's code.
    func testTheCoreOpenVector() throws {
        let cases = try XCTUnwrap(try V40.json("errors_40.json")["core_open"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 4)
        for c in cases {
            let status = try XCTUnwrap(c["status"] as? Int), name = c["name"] as? String ?? "?"
            XCTAssertEqual("QLC_E_" + (CoreFailure.statusName(status) ?? "?").uppercased(), name)
            let e = CoreFailure(Int32(status), call: "qlc_model_open").recognizerError
            let cause = ErrorCause.of(e, stage: try XCTUnwrap(c["stage"] as? String))
            XCTAssertEqual(cause.stage, c["stage"] as? String, name)
            XCTAssertEqual(cause.reason, c["reason"] as? String, name)
            XCTAssertEqual(cause.errorCode, c["error_code"] as? String, name)
            XCTAssertEqual(ErrorRules.code(stage: cause.stage, reason: cause.reason, errorCode: cause.errorCode), c["code"] as? String, name)
            XCTAssertEqual(TajweedError(from: e, stage: "model_open").code, c["code"] as? String, name)
        }
    }

    /// The report a failed model open leaves in the book carries the name (the book's entry is what is sent).
    func testTheReportCarriesTheName() throws {
        let storage = CloudFixtures.storage()
        StubProtocol.reset(CloudFixtures.server())
        let client = try TajweedClient(key: CloudFixtures.key, configuration: CloudFixtures.options(storage: storage),
                                       cloud: { CloudFixtures.cloud(storage: $0) })
        defer {
            client.close()
            QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
        }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        _ = TajweedError(from: CoreFailure(Int32(QLC_E_NOMEM), call: "qlc_model_open").recognizerError, stage: "model_open")
        cloud.errorReports.waitForSave()
        let entry = try XCTUnwrap(cloud.errorReports.snapshot.queue.first { $0.stage == "model_open" })
        XCTAssertEqual(entry.reason, "memory")
        XCTAssertEqual(entry.errorCode, "nomem")
        XCTAssertEqual(entry.code, "engine_failed")
        XCTAssertNil(entry.hostRole, "no host's answer")
    }

    /// A Model `client.model()` does not hand out is discarded closed: its engine gone, the Model closed for good,
    /// and with no Core model open for its folder nothing else is touched (the Core's own close is
    /// `ProtectedRuntime.closeIdleModel`, which leaves another folder's model and a model in use as they are).
    func testADiscardedModelIsClosed() async throws {
        let folder = try ModelOpenReportTests.testFolder()
        let model = TajweedModel(folder, client: nil)
        await model.discard(closingCore: true)
        let after = await { () async -> String? in
            do throws(TajweedError) { _ = try await model.session(); return nil } catch { return error.code }
        }()
        XCTAssertEqual(after, "model_missing", "a discarded Model takes no Session")
        // no runtime, or a runtime with no open model: nothing to close, nothing fails
        let storage = CloudFixtures.storage()
        let runtime = ProtectedRuntime(storage: storage, server: nil, keys: InstallKeyring(storage: storage))
        runtime.closeIdleModel(of: folder)
        XCTAssertNil(runtime.openModel(of: folder))
    }

    /// A folder of manifest_40.json's build (nothing in it is opened here), as ProtectedCoreTests makes one.
    static func testFolder() throws -> ModelFolder {
        let m = try ModelManifest.parse(try V40.manifest().data)
        return ModelFolder(id: ModelID("v4.0", repository: "Quran-Lab/test"), directory: CloudFixtures.storage(), manifest: m,
                           vocabulary: Vocabulary(symbols: (0..<38).map { "t\($0)" }, blank: 0), verifiedFiles: [], coreMLProblem: "test")
    }
}
