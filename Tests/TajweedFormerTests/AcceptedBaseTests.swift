import Foundation
import XCTest
@testable import TajweedFormer

/// Where a build's files may come from (`ProtectedRuntime.acceptedBase`): https and Quran Lab's own hosts only, as the
/// C SDK's `base_ok`. The staging hook (`StagingHooks.baseHosts`) exists in debug builds only: run with
/// `swift test -c release --filter AcceptedBaseTests`, a release build has no hook and refuses the staging host.
final class AcceptedBaseTests: XCTestCase {
    static let staging = URL(string: "https://qlab-cdn-staging.mostafa0333.workers.dev/models/Quran-Lab/m/b/sdk/v4.0/")!

    func testOnlyQuranLabHostsOverHttps() {
        for ok in ["https://cdn.quranlab.ai/models/Quran-Lab/m/b/sdk/v4.0/", "https://quranlab.ai/m/", "https://eu.cdn.quranlab.ai/x/"] {
            XCTAssertNotNil(ProtectedRuntime.acceptedBase(URL(string: ok)), ok)
        }
        for bad in ["http://cdn.quranlab.ai/m/", "https://cdn.quranlab.ai.evil.example/m/", "https://evilquranlab.ai/m/",
                    "https://cdn.quranlab.ai:8443/m/", "https://cdn.quranlab.ai/m", "https://cdn.quranlab.ai/a/../b/",
                    "https://user@cdn.quranlab.ai/m/", "https://cdn.quranlab.ai/m/?x=1", Self.staging.absoluteString] {
            XCTAssertNil(ProtectedRuntime.acceptedBase(URL(string: bad)), bad)
        }
    }

    /// Debug builds only: the hook takes a named staging host over https, and nothing else; without it the host is
    /// refused again.
    func testTheStagingHookIsDebugOnly() {
        #if DEBUG
        StagingHooks.baseHosts.withLock { $0 = ["qlab-cdn-staging.mostafa0333.workers.dev"] }
        defer { StagingHooks.baseHosts.withLock { $0 = [] } }
        XCTAssertNotNil(ProtectedRuntime.acceptedBase(Self.staging))
        XCTAssertNil(ProtectedRuntime.acceptedBase(URL(string: "http://qlab-cdn-staging.mostafa0333.workers.dev/m/")), "https only")
        XCTAssertNil(ProtectedRuntime.acceptedBase(URL(string: "https://other.workers.dev/m/")), "the named host only")
        StagingHooks.baseHosts.withLock { $0 = [] }
        XCTAssertNil(ProtectedRuntime.acceptedBase(Self.staging))
        #else
        XCTAssertNil(ProtectedRuntime.acceptedBase(Self.staging), "a release build has no hook")
        #endif
    }

    /// A compiled accelerator program that a process left in the dispatch folder (it ended during a prepare) is gone at
    /// the next start: the protected runtime empties the folder when it is made (Stage B, the iPhone).
    func testADispatchFolderLeftByAProcessIsEmptiedAtTheStart() throws {
        let storage = Fixtures.storage()
        let left = storage.appendingPathComponent("core/dispatch/0123456789abcdef.mlmodelc/weights")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try Data("plaintext program".utf8).write(to: left.appendingPathComponent("weight.bin"))
        try Data("program".utf8).write(to: left.deletingLastPathComponent().appendingPathComponent("model.mil"))
        _ = ProtectedRuntime(storage: storage, server: nil, keys: InstallKeyring(storage: storage))
        let inside = try FileManager.default.contentsOfDirectory(atPath: storage.appendingPathComponent("core/dispatch").path)
        XCTAssertEqual(inside, [], "nothing a prepare wrote survives the start")
    }
}
