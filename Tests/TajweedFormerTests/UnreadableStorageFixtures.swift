import CryptoKit
import Foundation
import Security
import XCTest
@testable import TajweedFormer

/// The test's switch for a storage whose reads the system refuses: from `refuse` on, every read the SDK makes of a
/// file whose path ends with one of the given endings fails as the read of a file of a protected class fails while
/// the device is locked; the file itself is not touched, and writes go through. `open()` ends it. This is a switch
/// of the test: no test here locks a device.
enum StorageLock {
    static func refuse(_ endings: [String]) {
        StorageSeam.refusesReads.withLock { $0 = { (url: URL) -> Bool in endings.contains { url.path.hasSuffix($0) } } }
    }

    static func open() { StorageSeam.refusesReads.withLock { $0 = nil } }

    /// Between tests: no read is refused, and the Keychain is the system's.
    static func reset() {
        open()
        StorageSeam.keychain.withLock { $0 = nil }
    }
}

/// The Keychain's stand-in for the contributor's items (its id, the device key, the recovery code), kept in
/// memory. `absent`: a process without a Keychain, as the CI's test process is (a read finds nothing, an add is
/// refused), which keeps the three in files. `setLocked(true)`: a Keychain that cannot be read; every call is
/// answered with `errSecInteractionNotAllowed`, the status of a read before the first unlock. What the real
/// Keychain answers to an add or a delete then was not measured: here both are refused.
final class MemoryKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var isLocked = false
    let absent: Bool

    init(absent: Bool = false) { self.absent = absent }

    func setLocked(_ on: Bool) {
        lock.lock()
        isLocked = on
        lock.unlock()
    }

    /// What it holds, by account.
    var stored: [String: Data] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    private func read(_ account: String) -> (status: OSStatus, data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        if absent { return (errSecItemNotFound, nil) }
        if isLocked { return (errSecInteractionNotAllowed, nil) }
        guard let d = items[account] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, d)
    }

    private func add(_ account: String, _ data: Data) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        if absent { return errSecMissingEntitlement }
        if isLocked { return errSecInteractionNotAllowed }
        if items[account] != nil { return errSecDuplicateItem }
        items[account] = data
        return errSecSuccess
    }

    private func delete(_ account: String) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        if absent { return errSecItemNotFound }
        if isLocked { return errSecInteractionNotAllowed }
        return items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
    }

    /// From here the SDK's calls for the contributor's Keychain items come to this stand-in.
    func install() {
        let standIn = KeychainStandIn(read: { [self] (account: String) in read(account) },
                                      add: { [self] (account: String, data: Data) in add(account, data) },
                                      delete: { [self] (account: String) in delete(account) })
        StorageSeam.keychain.withLock { $0 = standIn }
    }
}

/// What the tests of the unreadable storage share: a launch on a storage, a recording, the first process that
/// leaves a queue, and what was sent.
class UnreadableStorageTestCase: XCTestCase {
    override func tearDown() {
        StorageLock.reset()
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// A launch: a new server client and upload queue on `storage`, with what the device says there.
    func launch(storage: URL) async -> QuranLabCloud {
        let options = CloudFixtures.options(contributions: true, storage: storage)
        let cloud = CloudFixtures.cloud(storage: storage, options: options)
        _ = await cloud.refreshConfig()
        QuranLab.configure(key: CloudFixtures.key, options: options, cloud: cloud)
        return cloud
    }

    /// A recording of `seconds` that has ended; its id, nil when no recording could begin.
    func record(seconds: Int = 1) throws -> String? {
        guard let capture = Contributions.capture(revision: "test-rev", backend: .exact, weightsSHA256: nil) else { return nil }
        for i in 0..<(10 * seconds) { try capture.append(SharingTests.audio(4800, seed: i + 1), rate: 48_000) }
        capture.finish(completed: true)
        return capture.id
    }

    func until(_ seconds: TimeInterval, _ done: @Sendable () async -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if await done() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await done()
    }

    /// A process in which the learner said yes and made one recording. With `uploads` the recording is uploaded;
    /// without, the upload routes are down and it waits unsent after its first try.
    func share(_ server: SharingTests.Server, _ storage: URL, seconds: Int = 1, uploads: Bool = false) async throws -> (cloud: QuranLabCloud, id: String) {
        server.down.withLock { $0 = !uploads }
        let cloud = await launch(storage: storage)
        Contributions.answer(share: true)
        let id = try XCTUnwrap(try record(seconds: seconds), "sharing is on in the first process")
        let queue = cloud.outbox
        if uploads {
            let up = await until(20) { await queue.item(id)?.status == .uploaded }
            XCTAssertTrue(up, "the first process uploaded its recording")
        } else {
            let waiting = await until(20) { await queue.item(id)?.lastError != nil }
            XCTAssertTrue(waiting, "the recording waits unsent after its first try")
        }
        return (cloud, id)
    }

    /// The end of a process: its upload queue is at rest (the pass has left) and does nothing more.
    func end(_ cloud: QuranLabCloud) async {
        await cloud.outbox.hold()
        cloud.outbox.shutdown()
    }

    /// The first process (`share`), ended; the recording's id and the queue's folder.
    func firstProcess(_ server: SharingTests.Server, _ storage: URL, seconds: Int = 1, uploads: Bool = false) async throws -> (id: String, root: URL) {
        let made = try await share(server, storage, seconds: seconds, uploads: uploads)
        await end(made.cloud)
        return (made.id, made.cloud.outbox.root)
    }

    /// The kinds of the upload requests (start, urls, put, takes) that reached the stub after its request number
    /// `mark`, answered or not.
    static func uploads(after mark: Int) -> [String] {
        StubProtocol.seen.dropFirst(mark).compactMap { SharingOffTests.kind($0) }
    }

    /// What a folder holds: every file with its size and the start of its hash, sorted.
    static func listing(_ folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().map { (name: String) -> String in
            guard let d = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return "\(name) (not a file)" }
            let hash = SHA256.hash(data: d).prefix(6).map { String(format: "%02x", $0) }.joined()
            return "\(name) \(d.count) \(hash)"
        }
    }

    /// Checks a deletion request the stub saw: it names `contributor`, it is signed by `key` over the deletion
    /// message of its own fields, and it carries neither the developer key nor a token.
    static func checkDeletion(_ seen: StubProtocol.Seen, contributor: String, signedBy key: P256.Signing.PublicKey,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let body = try XCTUnwrap(seen.json, file: file, line: line)
        XCTAssertEqual(body["contributor"] as? String, contributor, "the contributor the recordings were shared under", file: file, line: line)
        XCTAssertEqual(body["action"] as? String, "delete-all", file: file, line: line)
        let message = ContributorKey.deletionMessage(app: "ios:com.example.quran", contributor: contributor,
                                                     nonce: body["nonce"] as? String ?? "",
                                                     timestamp: try XCTUnwrap(body["timestamp"] as? Int, file: file, line: line))
        let raw = try XCTUnwrap(Data(base64URL: try XCTUnwrap(body["signature"] as? String, file: file, line: line)), file: file, line: line)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        XCTAssertTrue(key.isValidSignature(signature, for: message), "signed with the device key that was there before", file: file, line: line)
        XCTAssertNil(seen.headers["authorization"], "no token on a deletion", file: file, line: line)
        XCTAssertNil(seen.headers["x-qlab-key"], "no developer key on a deletion", file: file, line: line)
    }
}
