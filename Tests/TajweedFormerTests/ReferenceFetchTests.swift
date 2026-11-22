import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.2: `reference.fetch()` says why it failed. A download or lease failure is its own error by contract 24.4
/// (`needs_connection` when no request got an answer, `download_failed` when a server answered), with its cause; 4.0.1
/// said `reference_missing` with no cause, reported as verify/missing. Each `reference_missing` names where it came
/// from in its cause's `errorCode`. (The model opening again after the table's install needs the Core and a real
/// model: the self-test app's run on the Mac checks it, model(), fetch() and units() with no take in between.)
final class ReferenceFetchTests: XCTestCase {
    typealias Download = @Sendable (ModelFolder, ModelManifest.File) async throws -> Void

    static func reference(download: Download?) throws -> ModelReference {
        let m = OneRequestPerFileTests.manifest()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reference-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let folder = ModelFolder(id: ModelID("v4.0", repository: "Quran-Lab/test"), directory: dir, manifest: m,
                                 vocabulary: Vocabulary(symbols: (0..<38).map { "t\($0)" }, blank: 0), verifiedFiles: [],
                                 coreMLProblem: "test")
        let file = try XCTUnwrap(folder.referenceFile)
        return ModelReference(folder: folder, file: file, download: download)
    }

    func testAFetchWithNoNetworkIsNeedsConnectionWithItsCause() async throws {
        let r = try Self.reference { (_: ModelFolder, _: ModelManifest.File) async throws -> Void in
            throw RecognizerError.offline("the download did not start: the connection is offline [NSURLErrorDomain -1009]")
        }
        do {
            try await r.fetch()
            XCTFail("no network: the fetch fails")
        } catch {
            XCTAssertEqual(error.code, "needs_connection", "\(error)")
            XCTAssertEqual(error.cause?.stage, "download")
            XCTAssertEqual(error.cause?.reason, "network")
        }
    }

    func testAFetchAServerRefusedIsDownloadFailed() async throws {
        let r = try Self.reference { (_: ModelFolder, _: ModelManifest.File) async throws -> Void in
            throw RecognizerError.offline("the download failed: HTTP 503")
        }
        do {
            try await r.fetch()
            XCTFail("a 503: the fetch fails")
        } catch {
            XCTAssertEqual(error.code, "download_failed", "\(error)")
            XCTAssertEqual(error.cause?.stage, "download")
            XCTAssertEqual(error.cause?.httpStatus, 503)
        }
    }

    func testEachReferenceMissingNamesWhereItCameFrom() async throws {
        let r = try Self.reference(download: nil)
        do {
            _ = try r.units(surah: 1, ayah: 1)
            XCTFail("not fetched")
        } catch {
            XCTAssertEqual(error.code, "reference_missing")
            XCTAssertEqual(error.cause?.errorCode, "not_fetched")
        }
        do {
            try await r.fetch()
            XCTFail("no Client to fetch it through")
        } catch {
            XCTAssertEqual(error.code, "reference_missing")
            XCTAssertEqual(error.cause?.errorCode, "download")
        }
    }
}
