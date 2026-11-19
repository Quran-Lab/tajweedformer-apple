import CryptoKit
import Foundation
import QuranLabCore
import XCTest
@testable import TajweedFormer

/// The production pins (integration): a build linked against the release's xcframework
/// (`scripts/build_core_xcframework.py --from-release`) is Core 4.0.0-c3, its slice's binary is the pinned one, every
/// function of qlcore.h is there, and the Core pins Quran Lab's manifest signing key: the production V4 manifest stops
/// at "no lease", a test-signed one is refused. Skips with the test release linked (the unit tests' Core).
final class CoreReleasePinTests: XCTestCase {
    func requireProductionCore() throws {
        guard CoreHost.version.hasPrefix(CoreRelease.release + " ") else {
            throw XCTSkip("the linked Core is \(CoreHost.version), not the production release \(CoreRelease.release) "
                + "(build the xcframework with --from-release)")
        }
    }

    func testTheReleaseAndTheSlice() throws {
        try requireProductionCore()
        let target = String(CoreHost.version.dropFirst(CoreRelease.release.count + 1))
        let pin = try XCTUnwrap(CoreRelease.slices[target], "\(target) is not a slice of the pinned release")
        var info = Dl_info()
        XCTAssertNotEqual(dladdr(unsafeBitCast(qlc_version as @convention(c) () -> UnsafePointer<CChar>?, to: UnsafeRawPointer.self), &info), 0)
        let path = String(cString: try XCTUnwrap(info.dli_fname))
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        // a host that signs the framework again (an app's code signing) changes only the signature; the test process
        // loads the xcframework's binary as built
        XCTAssertEqual(sha, pin.framework, "\(path): the binary of the pinned \(target) slice")
    }

    func testEveryFunctionOfTheHeaderIsThere() throws {
        try requireProductionCore()
        XCTAssertEqual(CoreRelease.functions.count, 63)
        let all = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        for f in CoreRelease.functions { XCTAssertNotNil(dlsym(all, f), f) }
    }

    /// Quran Lab's production V4 manifest (key ad6879dd) passes the Core's signature check and stops at the lease
    /// (QLC_E_NEEDS_CONNECTION, -5); one changed byte, or a manifest signed by the contract's test key, is refused
    /// (QLC_E_MANIFEST, -4). As the archive's pin_check on Windows and the Mac.
    func testTheCorePinsTheProductionSigningKey() throws {
        try requireProductionCore()
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "pins", withExtension: nil, subdirectory: "Fixtures/production"))
        let prod = try Data(contentsOf: dir.appendingPathComponent("prod_v4_manifest.json"))
        let changed = try Data(contentsOf: dir.appendingPathComponent("prod_v4_manifest_changed.json"))
        let test = try Data(contentsOf: dir.appendingPathComponent("test_signed_manifest.json"))
        let lv = try V40.json("lease.json")
        let ecdh = try XCTUnwrap(lv["install_ecdh"] as? [String: Any])
        let key = try XCTUnwrap(SoftwareInstallKey(der: try XCTUnwrap(Data(base64URL: try XCTUnwrap(ecdh["pkcs8_b64u"] as? String)))))
        let storage = Fixtures.storage()
        let platform = CorePlatform(storage: CoreStorage(root: storage), key: key, state: ProtectedCoreTests.MemoryState(), clocks: SystemClocks())
        let host = try CoreHost(platform: platform)
        let folder = storage.appendingPathComponent("models/pin")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (data, want) in [(prod, Int(QLC_E_NEEDS_CONNECTION)), (changed, Int(QLC_E_MANIFEST)), (test, Int(QLC_E_MANIFEST))] {
            do {
                _ = try host.open(manifest: data, in: folder, context: "c16_l64", threads: 1)
                XCTFail("a model opened with no lease")
            } catch {
                XCTAssertEqual(Int(error.status), want)
            }
        }
    }
}
