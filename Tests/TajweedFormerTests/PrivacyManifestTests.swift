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
        // SDK 4.0: the boot clock (mach_continuous_time, the boot's id) times the protected model's lease (18.4.7)
        XCTAssertEqual(reasons(m), ["NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"], "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
                                    "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"]])
        let collected = (m["NSPrivacyCollectedDataTypes"] as? [[String: Any]]) ?? []
        let types = Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        XCTAssertEqual(types, ["NSPrivacyCollectedDataTypeProductInteraction", "NSPrivacyCollectedDataTypePerformanceData",
                               "NSPrivacyCollectedDataTypeOtherDiagnosticData", "NSPrivacyCollectedDataTypeAudioData",
                               "NSPrivacyCollectedDataTypeCrashData"])
        for c in collected {
            XCTAssertEqual(c["NSPrivacyCollectedDataTypeLinked"] as? Bool, false)
            XCTAssertEqual(c["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertFalse(((c["NSPrivacyCollectedDataTypePurposes"] as? [String]) ?? []).isEmpty)
        }
    }

    /// The Core's xcframework the package builds with: beside Package.swift where the binary target is a path, else
    /// where SwiftPM put the one it fetched by URL and checked (`.build/artifacts`, as in a released package).
    static func coreXcframework() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fm = FileManager.default
        let local = root.appendingPathComponent("QuranLabCore.xcframework")
        if fm.fileExists(atPath: local.path) { return local }
        let artifacts = root.appendingPathComponent(".build/artifacts")
        if let e = fm.enumerator(at: artifacts, includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.lastPathComponent == "QuranLabCore.xcframework" { return url }
        }
        throw XCTSkip("no QuranLabCore.xcframework beside Package.swift or in .build/artifacts")
    }

    /// The Core's required-reason APIs: file metadata of the model files; and from spec fix 17 (a Core of
    /// `QLC_CLOCK_ANCHOR`, which exports `qlc_lease_time`) the boot clock, which the Core reads itself
    /// (`mach_continuous_time` in its port layer) to time the lease. Core c3 reads no clock of its own.
    static func coreReasons(clockAnchor: Bool) -> [String: [String]] {
        var r = ["NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"]]
        if clockAnchor { r["NSPrivacyAccessedAPICategorySystemBootTime"] = ["35F9.1"] }
        return r
    }

    func testTheXcframeworksManifest() throws {
        let xcframework = try Self.coreXcframework()
        // the xcframework the package links: c3's was built before spec fix 17 (its files are pinned byte for byte)
        let want = Self.coreReasons(clockAnchor: CoreOptional.leaseTime != nil)
        for slice in ["ios-arm64", "ios-arm64-simulator", "macos-arm64"] {
            // SDK 4.0: the Core's framework bundle carries it (scripts/build_core_xcframework.py)
            let inside = slice.hasPrefix("macos") ? "QuranLabCore.framework/Versions/A/Resources" : "QuranLabCore.framework"
            let url = xcframework.appendingPathComponent("\(slice)/\(inside)/PrivacyInfo.xcprivacy")
            let m = try manifest(url)
            XCTAssertEqual(m["NSPrivacyTracking"] as? Bool, false, slice)
            XCTAssertEqual(reasons(m), want, slice)
            XCTAssertEqual((m["NSPrivacyCollectedDataTypes"] as? [[String: Any]])?.count, 0, slice)
        }
    }

    /// The manifest the next Core build puts in each framework (scripts/xcframework, `--privacy`'s default): every Core
    /// from spec fix 17 on reads the boot clock itself.
    func testTheManifestTheNextCoreBuildTakes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("scripts/xcframework/PrivacyInfo.xcprivacy")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no scripts/xcframework beside Package.swift") }
        let m = try manifest(url)
        XCTAssertEqual(m["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(reasons(m), Self.coreReasons(clockAnchor: true))
        XCTAssertEqual((m["NSPrivacyCollectedDataTypes"] as? [[String: Any]])?.count, 0)
    }

    /// The APIs behind the declared reasons are the ones the sources call: a new use of a required-reason API has to
    /// come with its reason.
    func testTheDeclaredAPIsAreTheOnesCalled() throws {
        let sources = PublicSurfaceTests.sources
        let e = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var text = ""
        for case let url as URL in e where url.pathExtension == "swift" { text += try String(contentsOf: url, encoding: .utf8) }
        XCTAssertTrue(text.contains("volumeAvailableCapacity"), "the disk space reason is declared for the installer's free-space check")
        for api in ["UserDefaults", "mach_absolute_time", "activeInputModes"] {
            XCTAssertFalse(text.contains(api), "\(api) is a required-reason API without a declared reason")
        }
        // SDK 4.0.5: a stage's time limit counts the process's running time by `systemUptime` (Accelerator.RunClock), an
        // elapsed time inside the app that never leaves the device: the boot time reason declared since 4.0 (35F9.1)
        // covers it, as it covers the lease's boot clock
        let url = try XCTUnwrap(SDKResources.bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let declared = reasons(try manifest(url))
        for api in ["systemUptime", "mach_continuous_time"] where text.contains(api) {
            XCTAssertEqual(declared["NSPrivacyAccessedAPICategorySystemBootTime"], ["35F9.1"], "\(api) needs the boot time reason")
        }
        for api in ["creationDate", "modificationDate", "contentModificationDateKey", "creationDateKey"] {
            XCTAssertFalse(text.contains(api), "\(api): the declared file-metadata reason covers the model files only")
        }
    }
}
