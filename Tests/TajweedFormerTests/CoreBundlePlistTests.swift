import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.2: App Store Connect refuses an app whose embedded framework has a `CFBundleVersion` that is not up to three
/// period-separated non-negative integers. The Core framework of 4.0.0 and 4.0.1 had "4.0.0-c3", so no app with the SDK
/// could be uploaded. Each slice of the release Core's xcframework at the package root now has the build number, the
/// release in `QLCoreRelease`, and the rest of a framework's Info.plist as App Store Connect reads it. Runs where the
/// package root holds the release Core (the c3 tier); the public package fetches the zip instead, and the test release
/// (4.0.0-c1) is not the release Core.
final class CoreBundlePlistTests: XCTestCase {
    static let plists = [
        ("ios-arm64", "ios-arm64/QuranLabCore.framework/Info.plist", "iPhoneOS", "MinimumOSVersion"),
        ("ios-arm64-simulator", "ios-arm64-simulator/QuranLabCore.framework/Info.plist", "iPhoneSimulator",
         "MinimumOSVersion"),
        ("macos-arm64", "macos-arm64/QuranLabCore.framework/Versions/A/Resources/Info.plist", "MacOSX",
         "LSMinimumSystemVersion"),
    ]

    func testTheCoreFrameworksInfoPlistIsOneAppStoreConnectTakes() throws {
        guard CoreHost.version.hasPrefix(CoreRelease.release + " ") else {
            throw XCTSkip("the linked Core is \(CoreHost.version), not the release \(CoreRelease.release)")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let xcf = root.appendingPathComponent("QuranLabCore.xcframework")
        guard FileManager.default.fileExists(atPath: xcf.path) else {
            throw XCTSkip("no QuranLabCore.xcframework at the package root (the public package fetches the zip)")
        }
        for (slice, path, platform, minKey) in Self.plists {
            let d = try XCTUnwrap(NSDictionary(contentsOf: xcf.appendingPathComponent(path)) as? [String: Any], path)
            let v = try XCTUnwrap(d["CFBundleVersion"] as? String, "\(slice): CFBundleVersion")
            XCTAssertNotNil(v.range(of: #"^[0-9]+(\.[0-9]+){0,2}$"#, options: .regularExpression),
                            "\(slice): CFBundleVersion \(v) is not up to three period-separated integers")
            XCTAssertEqual(v, CoreRelease.bundleVersion, slice)
            XCTAssertEqual(d["QLCoreRelease"] as? String, CoreRelease.release, slice)
            XCTAssertEqual(d["CFBundleShortVersionString"] as? String, "4.0.0", slice)
            XCTAssertEqual(d["CFBundleIdentifier"] as? String, "ai.quranlab.core", slice)
            XCTAssertEqual(d["CFBundlePackageType"] as? String, "FMWK", slice)
            XCTAssertEqual(d["CFBundleExecutable"] as? String, "QuranLabCore", slice)
            XCTAssertEqual(d["CFBundleSupportedPlatforms"] as? [String], [platform], slice)
            XCTAssertNotNil(d[minKey] as? String, "\(slice): \(minKey)")
        }
    }
}
