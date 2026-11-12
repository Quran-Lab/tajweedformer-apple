import Foundation
import XCTest
@testable import TajweedFormer

/// The privacy manifest ships inside the package (a resource of the target) and inside the xcframework, and says what
/// the SDK does: no tracking, anonymous telemetry, audio only with the learner's consent, and the two required-reason
/// APIs the SDK calls.
final class PrivacyManifestTests: XCTestCase {
    func manifest(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func reasons(_ m: [String: Any]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for e in (m["NSPrivacyAccessedAPITypes"] as? [[String: Any]]) ?? [] {
            if let t = e["NSPrivacyAccessedAPIType"] as? String { out[t] = (e["NSPrivacyAccessedAPITypeReasons"] as? [String]) ?? [] }
        }
        return out
    }

    func testThePackagesManifest() throws {
        let url = try XCTUnwrap(SDKResources.bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"), "PrivacyInfo.xcprivacy is not in the bundle")
        let m = try manifest(url)
        XCTAssertEqual(m["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((m["NSPrivacyTrackingDomains"] as? [String])?.count, 0)
        // disk space before a model download, file metadata of the model files in the app's container
        XCTAssertEqual(reasons(m), ["NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"], "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"]])
        let collected = (m["NSPrivacyCollectedDataTypes"] as? [[String: Any]]) ?? []
        let types = Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        XCTAssertEqual(types, ["NSPrivacyCollectedDataTypeProductInteraction", "NSPrivacyCollectedDataTypePerformanceData",
                               "NSPrivacyCollectedDataTypeOtherDiagnosticData", "NSPrivacyCollectedDataTypeAudioData"])
        for c in collected {
            XCTAssertEqual(c["NSPrivacyCollectedDataTypeLinked"] as? Bool, false)
            XCTAssertEqual(c["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertFalse(((c["NSPrivacyCollectedDataTypePurposes"] as? [String]) ?? []).isEmpty)
        }
    }

    func testTheXcframeworksManifest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for slice in ["ios-arm64", "ios-arm64-simulator", "macos-arm64"] {
            let url = root.appendingPathComponent("TajweedFormerCore.xcframework/\(slice)/PrivacyInfo.xcprivacy")
            let m = try manifest(url)
            XCTAssertEqual(m["NSPrivacyTracking"] as? Bool, false, slice)
            XCTAssertEqual(reasons(m), ["NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"]], slice)
            XCTAssertEqual((m["NSPrivacyCollectedDataTypes"] as? [[String: Any]])?.count, 0, slice)
        }
    }

    /// The APIs behind the declared reasons are the ones the sources call: a new use of a required-reason API has to
    /// come with its reason.
    func testTheDeclaredAPIsAreTheOnesCalled() throws {
        let sources = PublicSurfaceTests.sources
        let e = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var text = ""
        for case let url as URL in e where url.pathExtension == "swift" { text += try String(contentsOf: url, encoding: .utf8) }
        XCTAssertTrue(text.contains("volumeAvailableCapacity"), "the disk space reason is declared for the installer's free-space check")
        for api in ["UserDefaults", "systemUptime", "mach_absolute_time", "activeInputModes"] {
            XCTAssertFalse(text.contains(api), "\(api) is a required-reason API without a declared reason")
        }
        for api in ["creationDate", "modificationDate", "contentModificationDateKey", "creationDateKey"] {
            XCTAssertFalse(text.contains(api), "\(api): the declared file-metadata reason covers the model files only")
        }
    }
}
