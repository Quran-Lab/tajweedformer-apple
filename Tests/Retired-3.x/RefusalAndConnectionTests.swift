import Foundation
import XCTest
@testable import TajweedFormer

/// A stub API and CDN for a Client: the API answers as the fixtures say, the CDN serves the bundled test folder.
enum StubbedModelServer {
    /// Installs the stub and returns the build id of the folder it serves.
    @discardableResult
    static func serve() throws -> String {
        let server = try Fixtures.v4mini().appendingPathComponent("server")
        let build = String(Manifest30VectorTests.sha256(try Data(contentsOf: server.appendingPathComponent("manifest.json"))).prefix(40))
        StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(models: ["Quran-Lab/tajweedformer-v4": build]), extra: { s in
            guard s.url.host == CloudFixtures.cdn.host, let at = s.path.range(of: "/sdk/v4.0/") else { return nil }
            guard let data = try? Data(contentsOf: server.appendingPathComponent(String(s.path[at.upperBound...]))) else {
                return StubProtocol.Reply(status: 404)
            }
            return StubProtocol.Reply(status: 200, headers: ["content-type": "application/octet-stream"], body: data)
        }))
        return build
    }

    /// A Client over the stub, with its own storage; the config's and the test folder's keys are trusted. `app` is
    /// the identifier it registers with.
    static func client(storage: URL = CloudFixtures.storage(), app: AppIdentity = CloudFixtures.app,
                       installKeys: any InstallKeyStoring = CloudFixtures.installKeys) throws -> TajweedClient {
        let keys = [CloudFixtures.signer.publicKey.rawRepresentation, try Fixtures.v4miniKey()]
        var made = CloudFixtures.options(signingKeys: keys, storage: storage)
        made.cloud?.app = app
        let options = made
        return try TajweedClient(key: CloudFixtures.key, configuration: options, cloud: { root in
            CloudFixtures.cloud(storage: root, options: options, installKeys: installKeys)
        })
    }
}

/// `diagnose().connection` and `prefetch(unmeteredOnly:)`, which follows it (RULINGS point 2), with the connection
/// set by the test in place of the system's.
final class ConnectionTests: XCTestCase {
    override func tearDown() {
        ConnectionKind.override.withLock { $0 = nil }
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    func testTheFourValues() {
        XCTAssertEqual(ConnectionKind.allCases.map(\.rawValue), ["unmetered", "metered", "none", "unknown"])
        XCTAssertEqual(ConnectionKind.allCases.filter(\.downloadsWhenUnmeteredOnly), [.unmetered, .unknown])
    }

    /// With `unmeteredOnly`, prefetch downloads on `unmetered` and on `unknown`, and waits on `metered` and on
    /// `none`: nothing is asked of the download server and no model is on the device. Without the option it
    /// downloads on any connection. `diagnose()` reports the same connection.
    func testPrefetchUnmeteredOnlyDownloadsOnUnmeteredAndUnknownAndWaitsOnMeteredAndNone() async throws {
        var downloaded: [String] = [], waited: [String] = []
        for kind in ConnectionKind.allCases {
            let build = try StubbedModelServer.serve()
            ConnectionKind.override.withLock { $0 = { kind } }
            let client = try StubbedModelServer.client()
            try await client.prefetch(unmeteredOnly: true)
            let d = await client.diagnose()
            XCTAssertEqual(d.connection, kind.rawValue)
            let asked = StubProtocol.seen.contains { $0.path.hasSuffix("/sdk/v4.0/manifest.json") }
            if client.storage.models.isEmpty {
                waited.append(kind.rawValue)
                XCTAssertFalse(asked, "\(kind.rawValue): nothing is asked of the download server")
                XCTAssertNil(d.model, kind.rawValue)
                // the app asks again without the option: it downloads on any connection
                try await client.prefetch()
                XCTAssertEqual(client.storage.models.map(\.build), [build], "\(kind.rawValue): without the option")
            } else {
                downloaded.append(kind.rawValue)
                XCTAssertTrue(asked, kind.rawValue)
                XCTAssertEqual(client.storage.models.map(\.build), [build], kind.rawValue)
                XCTAssertEqual(d.model?.build, build, kind.rawValue)
            }
            // once the model is on the device the call is a no-op on any connection
            let before = StubProtocol.seen.count
            try await client.prefetch(unmeteredOnly: true)
            XCTAssertEqual(StubProtocol.seen.count, before, "\(kind.rawValue): nothing more is asked")
            client.close()
        }
        XCTAssertEqual(downloaded, ["unmetered", "unknown"])
        XCTAssertEqual(waited, ["metered", "none"])
    }

    /// Without a test's value the report says what the system says: one of the four.
    func testDiagnoseReportsTheSystemsConnection() async throws {
        StubProtocol.reset { _ in .down }
        let client = try StubbedModelServer.client()
        defer { client.close() }
        let d = await client.diagnose()
        XCTAssertTrue(ConnectionKind.allCases.map(\.rawValue).contains(d.connection), d.connection)
        XCTAssertNil(DiagnosisTests.problem(try DiagnosisTests.report(d)))
    }
}

/// A refusal says what to do: the server's 403 code picks its own message and fix from the embedded
/// catalogue, and a code the catalogue does not have gets the entry's own words with the code in them. The
/// answer's `reason` is read first (the API answers an origin, key-type or allow-list refusal as a 401
/// `invalid_key` and names the check there), then its `error`: refusals.json, the vector the four SDKs share.
final class RefusalReasonTests: XCTestCase {
    /// The codes a server's 403 carries. (The catalogue has one more reason, `local_needs_development_key`, which no
    /// 403 carries: it is the answer of the web SDK's origin check.)
    static let reasons = ["developer_not_approved", "not_a_member", "key_type_mismatch", "origin_not_allowed", "app_not_allowed", "app_blocked",
                          "environment_mismatch"]

    override func tearDown() {
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// The error `client.model()` throws when the server answers the token request with 403 and `code`, and the
    /// report of the Client afterwards.
    func refused(_ code: String) async throws -> (error: TajweedError?, report: TajweedDiagnosis) {
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            s.path.hasPrefix("/v1/attest") ? .json(["error": code, "message": "refused by the test's server"], status: 403) : nil
        }))
        let client = try StubbedModelServer.client()
        defer { client.close() }
        let error = await { () async -> TajweedError? in
            do throws(TajweedError) { _ = try await client.model(); return nil } catch { return error }
        }()
        return (error, await client.diagnose())
    }

    func testTheCatalogueHasAReasonForEveryServerCode() throws {
        let entry = try XCTUnwrap(ErrorCatalogue.shared.entries["server_rejected"])
        for code in Self.reasons {
            let texts = try XCTUnwrap(entry.reasons[code], code)
            XCTAssertFalse(texts.message.isEmpty, code)
            XCTAssertFalse(texts.fix.isEmpty, code)
            XCTAssertTrue(texts.message.contains("(\(code))"), "\(code): the message names the server's code in brackets")
        }
        // a key belongs to the first app that used it: the words a developer reads when another app uses it
        let other = try XCTUnwrap(entry.reasons["app_not_allowed"])
        XCTAssertEqual(other.message, "This key belongs to another app (app_not_allowed).")
        XCTAssertEqual(other.fix, "A key works for the first app that used it. Make a key for this app at https://sdk.quranlab.ai/keys, "
            + "or allow this app's identifier on the key's page.")
        // no other entry has reasons
        XCTAssertEqual(ErrorCatalogue.shared.entries.filter { !$0.value.reasons.isEmpty }.map(\.key), ["server_rejected"])
    }

    /// For each of the seven reasons: a stub server answers 403 with that code, and the error is `server_rejected`
    /// with exactly the catalogue's message and fix for that reason.
    func testEachReasonGivesItsOwnMessageAndFix() async throws {
        let entry = try XCTUnwrap(ErrorCatalogue.shared.entries["server_rejected"])
        for code in Self.reasons {
            let texts = try XCTUnwrap(entry.reasons[code], code)
            let got = try await refused(code)
            let e = try XCTUnwrap(got.error, code)
            XCTAssertEqual(e.code, "server_rejected", code)
            // `{origin}` is the app id here: an app has no origin
            XCTAssertEqual(e.message, texts.message.replacingOccurrences(of: "{origin}", with: CloudFixtures.app.bundleID), code)
            XCTAssertEqual(e.fix, texts.fix, code)
            XCTAssertFalse(e.message.contains("{"), "\(code): \(e.message)")
            XCTAssertFalse(e.fix.contains("{"), "\(code): \(e.fix)")
            XCTAssertEqual(e.docs, "https://sdk.quranlab.ai/docs/errors#server_rejected", code)
            XCTAssertEqual(got.report.key.accepted, false, code)
            XCTAssertEqual(got.report.key.reason, "server_rejected", code)
            XCTAssertEqual(got.report.lastError, "server_rejected", code)
        }
        let access = try XCTUnwrap(entry.reasons["developer_not_approved"])
        XCTAssertTrue(access.fix.contains("https://sdk.quranlab.ai/start"), access.fix)
        // word for word, through the stub server: the fix of a key that belongs to another app
        let other = try await refused("app_not_allowed")
        XCTAssertEqual(other.error?.message, "This key belongs to another app (app_not_allowed).")
        XCTAssertEqual(other.error?.fix, "A key works for the first app that used it. Make a key for this app at https://sdk.quranlab.ai/keys, "
            + "or allow this app's identifier on the key's page.")
        XCTAssertTrue(try XCTUnwrap(entry.reasons["origin_not_allowed"]).message.contains("{origin}"))
    }

    /// A 403 code the catalogue does not have: the entry's own message with the code as its detail, and its fix.
    func testAnUnknownRefusalGivesTheGenericMessageWithTheCode() async throws {
        let entry = try XCTUnwrap(ErrorCatalogue.shared.entries["server_rejected"])
        let got = try await refused("plan_expired")
        let e = try XCTUnwrap(got.error)
        XCTAssertEqual(e.code, "server_rejected")
        // `{detail}` is the server's code, as the shared vector has it (it was the code and the status)
        XCTAssertEqual(e.message, entry.message.replacingOccurrences(of: "{detail}", with: "plan_expired"))
        XCTAssertEqual(e.message, "Quran Lab refused this app: plan_expired.")
        XCTAssertEqual(e.fix, entry.fix)
        XCTAssertEqual(got.report.key.accepted, false)
        XCTAssertEqual(got.report.key.reason, "server_rejected")
    }

    /// The error `client.model()` throws when every API request of a fresh Client, registered as `app`, is answered
    /// with `status` and `body`, and the report of the Client afterwards.
    func answered(status: Int, body: Data, app: String) async throws -> (error: TajweedError?, report: TajweedDiagnosis) {
        StubProtocol.reset { s in
            s.url.host == CloudFixtures.api.host ? StubProtocol.Reply(status: status, body: body) : StubProtocol.Reply(status: 404)
        }
        let identity = AppIdentity(platform: CloudFixtures.app.platform, bundleID: app, name: "Halaqa", version: "1.0")
        let client = try StubbedModelServer.client(app: identity)
        defer { client.close() }
        let error = await { () async -> TajweedError? in
            do throws(TajweedError) { _ = try await client.model(); return nil } catch { return error }
        }()
        return (error, await client.diagnose())
    }

    /// Every case of the shared vector (refusals.json, 11): each API request of a fresh Client is answered with the
    /// case's status and body, `model()` is the call that needs the server, and the error it throws has exactly the
    /// case's code, message and fix. `{origin}` is the identifier the Client registered with. `diagnose()` then
    /// reports the key as not accepted with that code as its reason, and `lastError` is that code.
    func testEveryCaseOfTheRefusalVector() async throws {
        let v = try Vectors30.json("refusals.json")
        // `sdk` names the version the file was built with and fills {sdk} in its texts: this SDK is that version or a
        // later 3.0.x or 3.1.x, and puts its own version in its place before it compares
        let written = try XCTUnwrap(v["sdk"] as? String)
        XCTAssertTrue(ModelManifest.version(SDKInfo.version, isAtLeast: written), "SDK \(SDKInfo.version) is not older than the vector's \(written)")
        XCTAssertTrue(["3.0", "3.1"].contains(SDKInfo.version.split(separator: ".").prefix(2).joined(separator: ".")), "the vector holds for SDK 3.0.x and 3.1.x")
        let app = try XCTUnwrap(v["app"] as? String)
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 11)
        let reasons = try XCTUnwrap(ErrorCatalogue.shared.entries["server_rejected"]).reasons
        var byReason = 0
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let status = try XCTUnwrap(c["status"] as? Int, name)
            let answer = try XCTUnwrap(c["body"] as? [String: Any], name)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            let got = try await answered(status: status, body: try JSONSerialization.data(withJSONObject: answer), app: app)
            let e = try XCTUnwrap(got.error, "\(name): model() throws")
            XCTAssertEqual(e.code, expect["code"] as? String, name)
            let message = (expect["message"] as? String)?.replacingOccurrences(of: written, with: SDKInfo.version)
            let fix = (expect["fix"] as? String)?.replacingOccurrences(of: written, with: SDKInfo.version)
            XCTAssertEqual(e.message, message, name)
            XCTAssertEqual(e.fix, fix, name)
            XCTAssertEqual(e.docs, "https://sdk.quranlab.ai/docs/errors#" + e.code, name)
            // the entry of the catalogue's reasons the case names is the one whose words the error has
            if let reason = expect["reason"] as? String {
                let texts = try XCTUnwrap(reasons[reason], "\(name): \(reason)")
                XCTAssertEqual(e.message, texts.message.replacingOccurrences(of: "{origin}", with: app), name)
                XCTAssertEqual(e.fix, texts.fix, name)
                byReason += 1
            }
            XCTAssertEqual(got.report.key.accepted, false, name)
            XCTAssertEqual(got.report.key.reason, expect["code"] as? String, name)
            XCTAssertEqual(got.report.lastError, expect["code"] as? String, name)
        }
        XCTAssertEqual(byReason, 6, "the cases whose words are a reason's own")
    }

    /// The answer's `reason` decides the words; the network follows the status and the answer's `error`. A key that
    /// belongs to another app arrives as a 401 `invalid_key`: the error is `server_rejected` with that reason's
    /// words, and the launch's calls stop as for any refused key.
    func testTheReasonDecidesTheWordsAndTheErrorCodeTheNetwork() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["error": "invalid_key", "message": "This key is not valid.", "reason": "app_not_allowed"])
        StubProtocol.reset { s in
            s.url.host == CloudFixtures.api.host ? StubProtocol.Reply(status: 401, body: body) : StubProtocol.Reply(status: 404)
        }
        let client = try StubbedModelServer.client()
        defer { client.close() }
        let first = await { () async -> TajweedError? in
            do throws(TajweedError) { _ = try await client.model(); return nil } catch { return error }
        }()
        XCTAssertEqual(first?.code, "server_rejected")
        XCTAssertEqual(first?.message, "This key belongs to another app (app_not_allowed).")
        // the network follows the answer's `error`: after a refused key, no more calls until the next launch
        XCTAssertEqual(QuranLab.cloud?.isStopped, true)
        XCTAssertEqual(QuranLab.cloud?.rejection?.code, "invalid_key")
        XCTAssertEqual(QuranLab.cloud?.rejection?.reason, "app_not_allowed")
        let again = await { () async -> TajweedError? in
            do throws(TajweedError) { _ = try await client.model(); return nil } catch { return error }
        }()
        XCTAssertEqual(again?.code, "server_rejected", "the next call says the same, without asking the server")
        // the failure the SDK carries: the answer's `error` and its `reason`, side by side
        let carried = CloudError.rejected(status: 401, code: "invalid_key", message: "This key is not valid.", reason: "app_not_allowed")
        XCTAssertEqual(carried.recognizerError, .serverRejected(status: 401, code: "invalid_key", message: "This key is not valid.", reason: "app_not_allowed"))
        XCTAssertEqual(HTTPClient.reason(["error": "invalid_key", "reason": "app_not_allowed"]), "app_not_allowed")
        XCTAssertNil(HTTPClient.reason(["error": "invalid_key", "reason": NSNull()]))
        XCTAssertNil(HTTPClient.reason(["error": "invalid_key"]))
        XCTAssertNil(HTTPClient.reason(nil))
        // which code a refusal is raised with
        XCTAssertEqual(TajweedError.refusalCode(code: "invalid_key", reason: "app_not_allowed"), .serverRejected)
        XCTAssertEqual(TajweedError.refusalCode(code: "invalid_key", reason: "a_reason_from_later"), .invalidKey)
        XCTAssertEqual(TajweedError.refusalCode(code: "invalid_key", reason: nil), .invalidKey)
        XCTAssertEqual(TajweedError.refusalCode(code: "sdk_too_old", reason: nil), .sdkTooOld)
        XCTAssertEqual(TajweedError.refusalCode(code: "app_blocked", reason: nil), .serverRejected)
        XCTAssertEqual(TajweedError.refusalCode(code: "a_code_from_later", reason: nil), .serverRejected)
    }

    /// `invalid_key` and `sdk_too_old` keep their own codes.
    func testTheTwoRefusalsWithTheirOwnCodes() {
        XCTAssertEqual(TajweedError(from: .serverRejected(status: 401, code: "invalid_key", message: "")).code, "invalid_key")
        let old = TajweedError(from: .serverRejected(status: 403, code: "sdk_too_old", message: "min_sdk 3.1.0 this SDK is too old"))
        XCTAssertEqual(old.code, "sdk_too_old")
        XCTAssertTrue(old.fix.contains("3.1.0") || old.message.contains("3.1.0"), "\(old.message) \(old.fix)")
    }
}

/// `runtime_unsupported` (RULINGS point 1): where the processor is the problem, with the place the SDK runs said from
/// one constant.
final class RuntimeSupportTests: XCTestCase {
    func testAnIntelProcessorIsRuntimeUnsupported() {
        XCTAssertNil(RuntimeSupport.problem(architecture: "arm64"))
        XCTAssertNoThrow(try RuntimeSupport.check(architecture: "arm64"))
        XCTAssertNoThrow(try RuntimeSupport.check(), "the tests run on Apple silicon")
        for arch in ["x86_64", "another processor"] {
            XCTAssertThrowsError(try RuntimeSupport.check(architecture: arch), arch) { error in
                let e = error as? TajweedError
                XCTAssertEqual(e?.code, "runtime_unsupported", arch)
                XCTAssertEqual(e?.docs, "https://sdk.quranlab.ai/docs/errors#runtime_unsupported")
                XCTAssertTrue(e?.fix.hasSuffix(SDKInfo.minimum + ".") ?? false, e?.fix ?? "")
                XCTAssertFalse(e?.message.contains("{") ?? true)
                XCTAssertFalse(e?.fix.contains("{") ?? true)
            }
        }
        XCTAssertTrue(RuntimeSupport.problem(architecture: "x86_64")?.contains("Intel") ?? false)
    }

    /// `{minimum}` comes from one constant, whoever raises the error, and it says what the README says.
    func testTheMinimumIsOneConstant() throws {
        let e = TajweedError(.runtimeUnsupported, ["detail": "anything"])
        XCTAssertEqual(e.fix, "Run the app where the SDK is supported: \(SDKInfo.minimum).")
        XCTAssertEqual(e.message, "The SDK cannot run here: anything.")
        for word in ["iOS 15", "macOS 12", "Apple silicon"] { XCTAssertTrue(SDKInfo.minimum.contains(word), word) }
        let readme = try String(contentsOf: QuickStartTests.root.appendingPathComponent("README.md"), encoding: .utf8)
        for word in ["iOS 15 and macOS 12 or later", "Apple silicon only"] { XCTAssertTrue(readme.contains(word), "README.md: \(word)") }
    }
}
