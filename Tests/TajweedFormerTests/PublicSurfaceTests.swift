import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 3.0.0: the public surface is the naming table's and nothing else, and the error catalogue in the package is the
/// one shared by the four SDKs.
final class PublicSurfaceTests: XCTestCase {
    /// The 22 public types of the naming table (section 8), plus the sharing UI components.
    static let named: Set<String> = [
        "TajweedClient", "TajweedModel", "TajweedSession", "TajweedHeads", "TajweedBackend",
        "TajweedClientOptions", "TajweedSessionOptions",
        "TajweedChunk", "TajweedDecoded", "TajweedToken", "TajweedWord", "TajweedFrame", "TajweedHead", "TajweedEvent",
        "TajweedTokens", "TajweedCalibration", "TajweedReference", "TajweedClip",
        "TajweedSharing", "TajweedAnalytics", "TajweedDiagnosis",
        "TajweedError", "Microphone",
    ]
    static let sharingUI: Set<String> = [
        "SharingTheme", "SharingConsentView", "SharingThanksView", "SharingSettingsView",
        "SharingConsentViewController", "SharingSettingsViewController",
        "SharingConsentViewControllerMac", "SharingSettingsViewControllerMac",
    ]
    /// The value sets and records nested in those types (each is a member of a listed type, never a new concept).
    static let nested: Set<String> = [
        "TajweedBackend.Kind", "TajweedBackend.Stage", "TajweedHead.Kind", "TajweedEvent.Cause", "TajweedEvent.EndReason",
        "TajweedSessionOptions.Backend", "TajweedSessionOptions.Pace", "TajweedClientOptions.Analytics",
        "TajweedClientOptions.Audience", "TajweedDiagnosis.Key", "TajweedDiagnosis.Model", "TajweedDiagnosis.StoredModel",
        "TajweedDiagnosis.Storage", "TajweedSharing.Item", "TajweedSharing.Summary",
    ]

    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/TajweedFormer")

    /// Every Swift source of the library with its text.
    func sourceFiles() throws -> [(name: String, text: String)] {
        let e = try XCTUnwrap(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var out: [(name: String, text: String)] = []
        for case let url as URL in e where url.pathExtension == "swift" {
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")))
        }
        XCTAssertGreaterThan(out.count, 40, "the library's sources are at \(Self.sources.path)")
        return out
    }

    /// The public type declarations of a file: top-level names, and nested ones as `Outer.Inner` (by indentation: the
    /// sources indent a nested declaration by four spaces under its type).
    func publicTypes(_ text: String) -> (top: [String], nested: [String]) {
        let decl = try! NSRegularExpression(pattern: #"^( *)(?:@\w+(?:\([^)]*\))? +)*(public|open) +(?:final +|indirect +)*(struct|class|enum|actor|protocol|typealias) +(\w+)"#)
        let anyType = try! NSRegularExpression(pattern: #"^(?:@\w+(?:\([^)]*\))? +)*(?:public +|open +)?(?:final +|indirect +)*(?:struct|class|enum|actor|protocol|extension) +([\w.]+)"#)
        var top: [String] = [], nested: [String] = []
        var outer = ""
        for line in text.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            if let m = anyType.firstMatch(in: line, range: range), let r = Range(m.range(at: 1), in: line) { outer = String(line[r]) }
            guard let m = decl.firstMatch(in: line, range: range), let indent = Range(m.range(at: 1), in: line),
                  let name = Range(m.range(at: 4), in: line) else { continue }
            if line[indent].isEmpty { top.append(String(line[name])) } else { nested.append(outer + "." + String(line[name])) }
        }
        return (top, nested)
    }

    func testThePublicTypesAreTheNamingTables() throws {
        var top = Set<String>(), nested = Set<String>()
        for f in try sourceFiles() {
            let t = publicTypes(f.text)
            top.formUnion(t.top)
            nested.formUnion(t.nested)
        }
        XCTAssertEqual(top.subtracting(Self.sharingUI), Self.named, "a public type outside NAMING.md section 8 (or one of it missing)")
        XCTAssertEqual(top.intersection(Self.sharingUI), Self.sharingUI)
        XCTAssertEqual(nested, Self.nested, "a nested public type that is not on the list")
    }

    func testNoPublicDeclarationOutsideThePublicTypes() throws {
        // a public member can only sit in a file that declares a public type, or in the sharing UI's View extension
        for f in try sourceFiles() {
            let hasPublic = f.text.components(separatedBy: "\n").contains { $0.range(of: #"^\s*(@\w+(\([^)]*\))?\s+)*public\s"#, options: .regularExpression) != nil }
            let types = publicTypes(f.text)
            if hasPublic { XCTAssertFalse(types.top.isEmpty, "\(f.name) has public members but no public type") }
        }
    }

    func testNoneOfThe2xEntryPointsIsPublic() throws {
        let gone = ["TajweedRecognizer", "QuranLab", "QuranLabCloud", "Contributions", "CloudOptions", "TajweedFormer", "TajweedStream",
                    "ModelStore", "ModelManifest", "ContributionOutbox", "RecognizerError", "HeadSelection", "DecodedTake"]
        var top = Set<String>()
        for f in try sourceFiles() { top.formUnion(publicTypes(f.text).top) }
        for name in gone { XCTAssertFalse(top.contains(name), "\(name) is public") }
    }

    /// SDK 3.0.0 is inference only: nothing in the library scores a take, holds tajweed settings, or calls an engine
    /// function that did (the engine's API 4 has none).
    func testNoScorerIsLeftInTheLibrary() throws {
        let gone = ["zf_tajweed_config_", "zf_tajweed_result_", "zf_tajweed_score", "zf_tajweed_expected", "TajweedSettings", "ScorerCalibration",
                    "EngineTajweedScorer", "TajweedScoreRequest", "ScoreTelemetry", "RemoteTajweedBlock", "GoldenJudge", "flaggedSites", "wordScores"]
        for f in try sourceFiles() {
            for name in gone { XCTAssertFalse(f.text.contains(name), "\(f.name) still has \(name)") }
        }
    }

    /// docs/api.md is generated from the sources (scripts/make_api_doc.py): every public declaration is in it, by its
    /// first line as written (up to its body).
    func testTheAPIDocListsEveryPublicDeclaration() throws {
        let url = Self.sources.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/api.md")
        guard let api = try? String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n") else {
            throw XCTSkip("no docs/api.md at \(url.path)")
        }
        var listed = 0
        for f in try sourceFiles() {
            for line in f.text.components(separatedBy: "\n") {
                var s = line.trimmingCharacters(in: .whitespaces)
                guard s.range(of: #"^(@\w+(\([^)]*\))? +)*public "#, options: .regularExpression) != nil else { continue }
                if let body = s.range(of: " {") { s = String(s[..<body.lowerBound]) }
                while s.hasSuffix("{") || s.hasSuffix(" ") { s.removeLast() }
                XCTAssertTrue(api.contains(s), "docs/api.md lacks `\(s)` of \(f.name): run python scripts/make_api_doc.py")
                listed += 1
            }
        }
        XCTAssertGreaterThan(listed, 150)
        for name in Self.named { XCTAssertTrue(api.contains("\n## \(name)\n"), "docs/api.md has no section for \(name)") }
    }

    // MARK: the error catalogue

    /// The SHA-256 of the contract's errors.json this package embeds (sdk_3.0.0/errors.json, version 1.3.9 of the
    /// shared files: 26 codes, the reasons of `server_rejected`, docs on sdk.quranlab.ai). Recorded when the copy was
    /// made; the copy is never edited.
    static let catalogueSHA256 = "9d692efed682a65f5b1d2fb0afbe0df37aad790884a0cb9cf5479ca77889e631"

    func embedded() throws -> Data { try Data(contentsOf: try XCTUnwrap(ErrorCatalogue.resource)) }

    func testTheEmbeddedCatalogueHasTheRecordedHash() throws {
        let sha = SHA256.hash(data: try embedded()).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sha, Self.catalogueSHA256)
    }

    /// Byte for byte the contract's file, where the contract is on this machine (TAJWEED_CONTRACT names its folder);
    /// elsewhere the hash above stands for it.
    func testTheEmbeddedCatalogueIsTheContractsFile() throws {
        let dir = ProcessInfo.processInfo.environment["TAJWEED_CONTRACT"] ?? ""
        let url = URL(fileURLWithPath: dir).appendingPathComponent("errors.json")
        guard let contract = try? Data(contentsOf: url) else { throw XCTSkip("no contract folder at \(dir)") }
        XCTAssertEqual(try embedded(), contract)
    }

    func testEveryCodeHasItsEntry() {
        let c = ErrorCatalogue.shared
        XCTAssertEqual(c.codes, ErrorCode.allCases.map(\.rawValue), "the SDK's codes are the catalogue's, in its order")
        XCTAssertEqual(c.codes.count, 26)
        XCTAssertTrue(c.codes.contains("model_unavailable"))
        XCTAssertTrue(c.codes.contains("runtime_unsupported"))
        XCTAssertTrue(c.codes.contains("network_not_permitted"))
        XCTAssertEqual(c.docsBase, "https://sdk.quranlab.ai/docs/errors#")
        for code in ErrorCode.allCases {
            let e = TajweedError(code, ["detail": "d", "version": "3.1.0", "needed": "10", "available": "5", "file": "f"])
            XCTAssertEqual(e.code, code.rawValue)
            XCTAssertFalse(e.message.isEmpty)
            XCTAssertFalse(e.fix.isEmpty)
            XCTAssertFalse(e.message.contains("{"), "\(code.rawValue): \(e.message)")
            XCTAssertFalse(e.fix.contains("{"), "\(code.rawValue): \(e.fix)")
            XCTAssertEqual(e.docs, "https://sdk.quranlab.ai/docs/errors#" + code.rawValue)
        }
    }

    func testPlaceholdersAreFilled() {
        XCTAssertEqual(TajweedError(.storageFull, ["needed": "100", "available": "7"]).message,
                       "Not enough free space for the model: 100 bytes needed, 7 free.")
        let old = TajweedError(from: .serverRejected(status: 403, code: "sdk_too_old", message: "this key needs SDK 3.1.0"))
        XCTAssertEqual(old.code, "sdk_too_old")
        XCTAssertEqual(old.message, "This key needs SDK 3.1.0 or later; this is \(SDKInfo.version).")
        XCTAssertTrue(old.fix.contains("3.1.0"))
        // the server's 403 body names the version in `min_sdk`: that one is the version the error names
        let body: [String: Any] = ["error": "sdk_too_old", "message": "SDK 2.0.3 is no longer served", "min_sdk": "3.2.0"]
        let named = TajweedError(from: .serverRejected(status: 403, code: "sdk_too_old", message: HTTPClient.message(body)))
        XCTAssertEqual(named.message, "This key needs SDK 3.2.0 or later; this is \(SDKInfo.version).")
        XCTAssertTrue(named.fix.contains("3.2.0"))
        XCTAssertEqual(HTTPClient.message(["message": "x", "min_sdk": "soon"]), "x", "a min_sdk that is not a version is not used")
        // a message without its detail still reads as a sentence
        XCTAssertEqual(TajweedError(.engineFailed).message, "The engine failed.")
    }

    /// Every internal failure has one of the 26 codes.
    func testEveryInternalFailureMapsToACode() {
        let cases: [(RecognizerError, String)] = [
            (.modelMissing("x"), "model_missing"), (.checksumMismatch(file: "layers.zfw"), "checksum_mismatch"),
            (.signatureInvalid, "signature_invalid"), (.manifestInvalid("no format"), "model_invalid"),
            (.modelIncompatible("v4.0 4.0.0 needs SDK 9.0.0 or newer (this is 3.0.0)"), "model_incompatible"),
            (.unsupportedAudioFormat("12345 Hz"), "invalid_argument"), (.microphoneUnavailable("no audio input device"), "microphone_unavailable"),
            (.microphoneUnavailable(TajweedError.deniedMark), "microphone_denied"),
            (.neuralEngineUnavailable("x"), "engine_failed"), (.engineFailed(code: 3, message: "x"), "engine_failed"),
            (.sessionActive, "session_open"), (.sessionClosed, "session_closed"), (.cancelled, "cancelled"),
            (.serviceUnavailable("x"), "sharing_unavailable"), (.offline("timeout"), "download_failed"),
            (.serverRejected(status: 401, code: "invalid_key", message: ""), "invalid_key"),
            (.serverRejected(status: 403, code: "app_blocked", message: ""), "server_rejected"),
            (.insufficientStorage(needed: 10, available: 1), "storage_full"), (.updateDeferred("no Wi-Fi"), "download_failed"),
            (.storageFailed("x"), "storage_failed"), (.contributionUnavailable("x"), "sharing_unavailable"),
            (.invalidArgument("x"), "invalid_argument"),
        ]
        let codes = Set(ErrorCode.allCases.map(\.rawValue))
        for (e, want) in cases {
            let t = TajweedError(from: e)
            XCTAssertEqual(t.code, want, "\(e)")
            XCTAssertTrue(codes.contains(t.code))
        }
    }

    /// A catalogue entry may carry `reasons`, keyed by the server's code of a refusal, each with its own message and
    /// fix. A refusal with one of those codes says that reason's message and fix; any other says the entry's own.
    /// The error's code and docs link stay the entry's.
    func testARefusalSaysItsReasonsMessageAndFixWhenTheCatalogueHasThem() throws {
        let file = #"""
        {"format": 1, "docs_base": "https://sdk.quranlab.ai/docs/errors#", "errors": [
          {"code": "server_rejected", "message": "Quran Lab refused the request: {detail}.", "fix": "Read the reason and act on it.",
           "reasons": {
             "developer_not_approved": {"message": "The account behind this key has no access yet.", "fix": "Open https://sdk.quranlab.ai/start."},
             "half_written": {"message": "a reason needs a fix too"}}},
          {"code": "invalid_key", "message": "The key is not valid.", "fix": "Copy the key again."}]}
        """#
        let c = try XCTUnwrap(ErrorCatalogue.parse(Data(file.utf8)))
        XCTAssertEqual(c.codes, ["server_rejected", "invalid_key"])
        XCTAssertEqual(c.texts("server_rejected", reason: "developer_not_approved"),
                       ErrorCatalogue.Texts(message: "The account behind this key has no access yet.", fix: "Open https://sdk.quranlab.ai/start."))
        XCTAssertEqual(c.texts("server_rejected", reason: "app_blocked")?.fix, "Read the reason and act on it.", "a reason the catalogue does not have")
        XCTAssertEqual(c.texts("server_rejected", reason: "half_written")?.fix, "Read the reason and act on it.", "a reason without both texts is not one")
        XCTAssertEqual(c.texts("server_rejected")?.message, "Quran Lab refused the request: {detail}.")
        XCTAssertEqual(c.texts("invalid_key", reason: "developer_not_approved")?.fix, "Copy the key again.", "an entry without reasons")
        XCTAssertNil(c.texts("no_such_code", reason: "developer_not_approved"))
        XCTAssertNil(ErrorCatalogue.parse(Data("[]".utf8)))

        let known = TajweedError(.serverRejected, ["detail": "developer_not_approved (403)"], reason: "developer_not_approved", catalogue: c)
        XCTAssertEqual(known.code, "server_rejected")
        XCTAssertEqual(known.message, "The account behind this key has no access yet.")
        XCTAssertEqual(known.fix, "Open https://sdk.quranlab.ai/start.")
        XCTAssertEqual(known.docs, "https://sdk.quranlab.ai/docs/errors#server_rejected")
        let other = TajweedError(.serverRejected, ["detail": "app_blocked (403)"], reason: "app_blocked", catalogue: c)
        XCTAssertEqual(other.message, "Quran Lab refused the request: app_blocked (403).")
        XCTAssertEqual(other.fix, "Read the reason and act on it.")

        // the catalogue in the package: a refusal is `server_rejected`, it has a fix, and it names the server's code
        // unless the catalogue has that reason's own words
        let embedded = TajweedError(from: .serverRejected(status: 403, code: "developer_not_approved", message: "not approved"))
        XCTAssertEqual(embedded.code, "server_rejected")
        XCTAssertFalse(embedded.fix.isEmpty)
        let own = ErrorCatalogue.shared.entries["server_rejected"]?.reasons["developer_not_approved"]
        if let own {
            XCTAssertEqual(embedded.message, own.message)
            XCTAssertEqual(embedded.fix, own.fix)
        } else {
            XCTAssertTrue(embedded.message.contains("developer_not_approved"), embedded.message)
        }
    }
}
