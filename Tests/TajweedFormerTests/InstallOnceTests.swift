import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5 (production, 2026-11-23): a macOS tool on the SDK made 2,338 install certificates from one address in 4.8
/// days, about one per run, with 2 install-days registered: its storage folder survived its runs and its install key did
/// not. Each case starts a "launch" as a process does: a new keyring and a new runtime over the same storage folder, then
/// the certificate a lease needs. Two launches must be one install: one certificate, the same install key.
final class InstallOnceTests: XCTestCase {
    override func tearDown() { InstallKeyring.keychainOverride.withLock { $0 = nil } }

    /// A server that certifies whatever install key it is given (a desktop-style `att none` certificate), and counts.
    final class Certifier: @unchecked Sendable {
        let signer = Curve25519.Signing.PrivateKey()
        let issued = Locked<[String]>([])
        let now: Int64 = 1_800_000_000

        func server() -> LeaseServer {
            let transport = ProtectedCoreTests.FakeTransport { _, _ in ProtectedCoreTests.response(404, ["error": "not_found"]) }
            return LeaseServer(transport: transport, apiURL: URL(string: "https://api.quranlab.ai")!, key: "qlk_v1_apps-one_sig",
                               platform: "macos", token: { (_: Bool) async throws(CloudError) -> String in "qlt_test" },
                               certify: { [self] (key: any InstallKey) async throws(CloudError) -> String in
                                   self.issued.withLock { $0.append(key.installHash) }
                                   guard let c = try? ProtectedCoreTests.certificate(for: key, signer: self.signer, now: self.now) else {
                                       throw .invalid("no certificate")
                                   }
                                   return c
                               },
                               trustedKeys: [signer.publicKey.rawRepresentation])
        }

        /// One launch: a new keyring and runtime over `storage`, and the certificate a lease would carry.
        func launch(_ storage: URL) async throws -> InstallCertificate {
            let runtime = ProtectedRuntime(storage: storage, server: server(), keys: InstallKeyring(storage: storage),
                                           state: ProtectedCoreTests.MemoryState(),
                                           clocks: ProtectedCoreTests.FixedClocks(wall: now * 1000, bootMs: 1, id: Array(repeating: 1, count: 32)))
            return try await runtime.certificate()
        }
    }

    /// The process the report's tool is: the Keychain keeps nothing of it. Three launches, one install.
    func testThreeLaunchesOfAProcessTheKeychainRefusesAreOneInstall() async throws {
        InstallKeyring.keychainOverride.withLock { $0 = false }
        let storage = CloudFixtures.storage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let server = Certifier()
        let first = try await server.launch(storage)
        let second = try await server.launch(storage)
        let third = try await server.launch(storage)
        XCTAssertEqual(server.issued.withLock { $0.count }, 1, "one install certificate for three launches")
        XCTAssertEqual(first.encoded, second.encoded)
        XCTAssertEqual(second.encoded, third.encoded)
        let core = storage.appendingPathComponent("core")
        XCTAssertTrue(FileManager.default.fileExists(atPath: core.appendingPathComponent("install-key-1.der").path), "the key is in the file")
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: core.appendingPathComponent("install-generation.json"))) as? [String: Any]
        XCTAssertEqual(record?["inFile"] as? Bool, true, "and its record says so")
    }

    /// This test process as it is (on the Mac CI: a command-line test runner without an application identifier, the
    /// report's kind of process), with the Keychain's own answers: two launches are one install, wherever the key went.
    func testTwoLaunchesOfThisProcessAreOneInstall() async throws {
        let storage = CloudFixtures.storage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let server = Certifier()
        let first = try await server.launch(storage)
        let second = try await server.launch(storage)
        print("install key: this process keeps Keychain items: \(InstallKeyring.keychainKeepsItems); certificates issued: \(server.issued.withLock { $0.count })")
        XCTAssertEqual(server.issued.withLock { $0.count }, 1, "one install certificate for two launches")
        XCTAssertEqual(first.encoded, second.encoded)
    }

    /// A store an SDK before 4.0.5 left in the bad state (the file's record naming a Keychain key no process finds):
    /// one more install at the next launch, and from then on the same one.
    func testAStoreLeftByTheBugHealsAfterOneLaunch() async throws {
        InstallKeyring.keychainOverride.withLock { $0 = false }
        let storage = CloudFixtures.storage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let core = storage.appendingPathComponent("core")
        try FileManager.default.createDirectory(at: core, withIntermediateDirectories: true)
        try Data(#"{"generation":4,"hardware":true,"inFile":false}"#.utf8).write(to: core.appendingPathComponent("install-generation.json"))
        let server = Certifier()
        let a = try await server.launch(storage)
        let b = try await server.launch(storage)
        XCTAssertEqual(server.issued.withLock { $0.count }, 1)
        XCTAssertEqual(a.encoded, b.encoded)
    }
}
