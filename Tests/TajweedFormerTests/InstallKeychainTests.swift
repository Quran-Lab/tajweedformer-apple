import Foundation
import Security
import XCTest
@testable import TajweedFormer

#if os(macOS)

/// The install key in the real Keychain of the test's Mac. The test process is a command-line tool without an
/// application identifier, as the Mac tools of the report were: a key one start keeps must be the key the next start
/// finds, or every start deletes the model and downloads it again. The item has the test's own names and is deleted
/// afterwards. SDK 4.0.2: such a process keeps its key in the SDK's file, and nothing waits on the login keychain, so
/// this runs over SSH too, where the login keychain is locked (to 4.0.1 it skipped there, and the example run as a
/// command-line program waited 245 s on the keychain's prompt, then failed).
final class InstallKeychainTests: XCTestCase {
    /// A store with names of its own and a file in a storage of its own.
    static func store() -> KeychainInstallKeyStore {
        KeychainInstallKeyStore(service: "quranlab.sdk.test", account: "install.key.test." + UUID().uuidString,
                                file: KeychainInstallKeyStore.fileURL(storage: CloudFixtures.storage()))
    }

    /// Deletes the store's items (the data protection keychain's and the login keychain's; a delete asks nothing) and
    /// its file.
    static func remove(_ store: KeychainInstallKeyStore) {
        SecItemDelete(store.query as CFDictionary)
        SecItemDelete(store.loginQuery as CFDictionary)
        if let f = store.file { try? FileManager.default.removeItem(at: f) }
    }

    /// What this Mac's data protection keychain answers this process: a read of an item that is not there, and an
    /// add (the item it adds, if any, is deleted at once).
    static func measure(_ store: KeychainInstallKeyStore) -> (read: OSStatus, add: OSStatus) {
        var q = store.query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let read = SecItemCopyMatching(q as CFDictionary, &out)
        var a = store.query
        a[kSecValueData as String] = Data(repeating: 7, count: KeychainInstallKeyStore.keyBytes)
        let add = SecItemAdd(a as CFDictionary, nil)
        if add == errSecSuccess { SecItemDelete(store.query as CFDictionary) }
        return (read, add)
    }

    /// One start keeps a key (`create`, after `load` found none); the next start, a new store with the same names,
    /// finds that key (`load`). Neither waits: over SSH the whole of it takes well under a second. The Keychain's own
    /// answers are printed for the record.
    func testTheKeyOneStartKeepsIsTheKeyTheNextStartFinds() throws {
        let first = Self.store()
        defer { Self.remove(first) }
        let answers = Self.measure(first)
        let login = KeychainInstallKeyStore.read(first.loginQuery)
        print("keychain: this test process, the data protection keychain: a read of a missing item answers \(answers.read), an add answers \(answers.add) (errSecItemNotFound \(errSecItemNotFound), errSecMissingEntitlement \(errSecMissingEntitlement)); the login keychain, read without UI: \(login)")
        let t0 = Date()
        XCTAssertEqual(first.load(), .none, "no key yet")
        let created = first.create()
        guard case .key(let key) = created else { return XCTFail("the key store did not keep a key: \(created)") }
        let next = KeychainInstallKeyStore(service: first.service, account: first.account, file: first.file)
        XCTAssertEqual(next.load(), .key(key), "the next start finds the key the first one kept")
        XCTAssertEqual(next.create(), .key(key), "and a create after a read that missed it gives that key, never a new one")
        XCTAssertEqual(next.load(), .key(key))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5, "nothing waited on a keychain's prompt")
        if answers.add == errSecMissingEntitlement {
            // a process the data protection keychain refuses: the key is in the SDK's file, and not in the login keychain
            XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(first.file)), key)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: first.file!.path))[.posixPermissions] as? Int, 0o600)
            XCTAssertNotEqual(KeychainInstallKeyStore.read(first.loginQuery), .data(key), "the login keychain is never written")
        }
    }

    /// The login keychain's query asks for no UI: a read answers at once whatever the keychain's state (locked over
    /// SSH: not found or `errSecInteractionNotAllowed`; unlocked: not found), never a wait.
    func testTheLoginKeychainIsReadWithoutUI() {
        let store = Self.store()
        defer { Self.remove(store) }
        XCTAssertNotNil(store.loginQuery[kSecUseAuthenticationContext as String], "an LAContext that does not allow interaction")
        let t0 = Date()
        let answer = KeychainInstallKeyStore.read(store.loginQuery)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
        XCTAssertTrue(([.notFound, .error(errSecInteractionNotAllowed)] as [KeychainAnswer]).contains(answer), "\(answer)")
    }
}
#endif

/// The install key store's decision, over a stand-in for its places: for each answer of a read, where `load` looks
/// next and what it gives, and that `create` never replaces a key a second read finds. On macOS the SDK's file and
/// (read only, without UI) the login keychain are the next places; on iOS there is none.
final class InstallKeyDecisionTests: XCTestCase {
    final class StandIn: InstallKeychains {
        var dataProtection: KeychainAnswer
        var login: KeychainAnswer
        var file: KeychainAnswer = .notFound
        var dataProtectionAdd: OSStatus = errSecSuccess
        var fileWrites = true
        var calls: [String] = []

        init(_ dataProtection: KeychainAnswer, _ login: KeychainAnswer, file: KeychainAnswer = .notFound) {
            self.dataProtection = dataProtection
            self.login = login
            self.file = file
        }

        func readDataProtection() -> KeychainAnswer { calls.append("read data protection"); return dataProtection }
        func readLogin() -> KeychainAnswer { calls.append("read login"); return login }
        func writeDataProtection(_ key: Data) -> OSStatus {
            calls.append("write data protection")
            if dataProtectionAdd == errSecSuccess { dataProtection = .data(key) }
            return dataProtectionAdd
        }
        func readFile() -> KeychainAnswer { calls.append("read file"); return file }
        func writeFile(_ key: Data) -> Bool {
            calls.append("write file")
            if fileWrites { file = .data(key) }
            return fileWrites
        }
    }

    static let a = Data(repeating: 0xA1, count: KeychainInstallKeyStore.keyBytes)
    static let b = Data(repeating: 0xB2, count: KeychainInstallKeyStore.keyBytes)
    static let c = Data(repeating: 0xC4, count: KeychainInstallKeyStore.keyBytes)
    static let fresh = Data(repeating: 0xC3, count: KeychainInstallKeyStore.keyBytes)
    static let locked = KeychainAnswer.error(errSecInteractionNotAllowed)

    /// `.key` with which key, `none`, or `failed`.
    static func kind(_ l: InstallKeyLookup) -> String {
        switch l {
        case .key(let d): return d == a ? "key a" : d == b ? "key b" : d == c ? "key c" : d == fresh ? "key fresh" : "key other"
        case .none: return "none"
        case .failed: return "failed"
        }
    }
}

extension InstallKeyDecisionTests {
    func testWhereLoadLooksForEachAnswer() {
        let first = ["read data protection"]
        let toFile = ["read data protection", "read file"]
        let all = ["read data protection", "read file", "read login"]
        // (the data protection keychain's answer, the login keychain's, the file's, macOS, what load gives, the reads)
        let rows: [(KeychainAnswer, KeychainAnswer, KeychainAnswer, Bool, String, [String])] = [
            // macOS
            (.data(Self.a), .data(Self.b), .data(Self.c), true, "key a", first),
            (.notFound, .data(Self.b), .notFound, true, "key b", all),
            (.notFound, .notFound, .notFound, true, "none", all),
            // a locked login keychain (over SSH) refuses at once: no key there, the file keeps the next one
            (.notFound, Self.locked, .notFound, true, "none", all),
            (.missingEntitlement, .data(Self.b), .notFound, true, "key b", all),
            (.missingEntitlement, .notFound, .notFound, true, "none", all),
            (.missingEntitlement, Self.locked, .notFound, true, "none", all),
            (.missingEntitlement, .error(-60006), .notFound, true, "none", all),
            // the file's key first: the key a process kept there, also when the login keychain holds another
            (.missingEntitlement, .data(Self.b), .data(Self.c), true, "key c", toFile),
            (.notFound, Self.locked, .data(Self.c), true, "key c", toFile),
            // a file that is there and cannot be read: nothing is replaced
            (.missingEntitlement, .data(Self.b), .error(errSecIO), true, "failed", toFile),
            // a file of another size is not a key
            (.missingEntitlement, .notFound, .data(Data([1, 2, 3])), true, "none", all),
            (Self.locked, .data(Self.b), .data(Self.c), true, "failed", first),
            (.data(Data([1, 2, 3])), .data(Self.b), .notFound, true, "none", first),
            // iOS: no second place
            (.data(Self.a), .data(Self.b), .data(Self.c), false, "key a", first),
            (.notFound, .data(Self.b), .data(Self.c), false, "none", first),
            (.missingEntitlement, .data(Self.b), .data(Self.c), false, "failed", first),
            (Self.locked, .data(Self.b), .data(Self.c), false, "failed", first),
        ]
        for (dp, login, file, mac, wanted, reads) in rows {
            let k = StandIn(dp, login, file: file)
            let got = KeychainInstallKeyStore.load(k, readsLogin: mac)
            let at = "\(mac ? "macOS" : "iOS"): data protection \(dp), login \(login), file \(file)"
            XCTAssertEqual(Self.kind(got), wanted, at)
            XCTAssertEqual(k.calls, reads, at)
        }
    }

    func testCreateNeverReplacesAKeyASecondReadFinds() {
        // a Mac process without an application identifier, first start: the data protection keychain finds nothing
        // and refuses the add; the file and the login keychain have nothing: the new key goes to the file (4.0.1: to
        // the login keychain, whose add waited on its unlock prompt over SSH)
        var k = StandIn(.notFound, .notFound)
        k.dataProtectionAdd = errSecMissingEntitlement
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: true, newKey: Self.fresh)), "key fresh")
        XCTAssertEqual(k.calls, ["read data protection", "write data protection", "read file", "read login", "write file"])
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.load(k, readsLogin: true)), "key fresh", "the next start finds it")
        // the same with the login keychain locked (the report's case): at once, into the file
        k = StandIn(.notFound, Self.locked)
        k.dataProtectionAdd = errSecMissingEntitlement
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: true, newKey: Self.fresh)), "key fresh")
        XCTAssertEqual(k.calls.last, "write file")
        // a key the login keychain holds (kept there by 3.1.0 to 4.0.1): that key, nothing written
        k = StandIn(.notFound, .data(Self.b))
        k.dataProtectionAdd = errSecMissingEntitlement
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: true, newKey: Self.fresh)), "key b")
        XCTAssertFalse(k.calls.contains("write file"))
        // a key the file holds: that key, nothing written
        k = StandIn(.notFound, .notFound, file: .data(Self.c))
        k.dataProtectionAdd = errSecMissingEntitlement
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: true, newKey: Self.fresh)), "key c")
        XCTAssertFalse(k.calls.contains("write file"))
        // a key the data protection keychain holds after all: that key, nothing written
        k = StandIn(.data(Self.a), .notFound)
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: true, newKey: Self.fresh)), "key a")
        XCTAssertEqual(k.calls, ["read data protection"])
        // an app with an application identifier, first start: the data protection keychain keeps it, nothing else is
        // touched
        k = StandIn(.notFound, .data(Self.b))
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: true, newKey: Self.fresh)), "key fresh")
        XCTAssertEqual(k.calls, ["read data protection", "write data protection"])
        // iOS: a refused add is a failure, there is no second place
        k = StandIn(.notFound, .notFound)
        k.dataProtectionAdd = errSecMissingEntitlement
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: false, newKey: Self.fresh)), "failed")
        XCTAssertFalse(k.calls.contains("read login") || k.calls.contains("read file") || k.calls.contains("write file"))
        // any other refusal of the add is a failure, also on macOS
        k = StandIn(.notFound, .notFound)
        k.dataProtectionAdd = errSecInteractionNotAllowed
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: true, newKey: Self.fresh)), "failed")
        XCTAssertFalse(k.calls.contains("write file"))
        // a file that cannot be read, or written: a failure, never a key that could not be kept
        k = StandIn(.notFound, .notFound, file: .error(errSecIO))
        k.dataProtectionAdd = errSecMissingEntitlement
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: true, newKey: Self.fresh)), "failed")
        XCTAssertFalse(k.calls.contains("write file"))
        k = StandIn(.notFound, .notFound)
        k.dataProtectionAdd = errSecMissingEntitlement
        k.fileWrites = false
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: true, newKey: Self.fresh)), "failed")
        // no random bytes: a failure, nothing written
        k = StandIn(.notFound, .notFound)
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: true, newKey: nil)), "failed")
        XCTAssertEqual(k.calls, [])
    }

    /// A signed app (one with an application identifier) kept its key in the data protection keychain under these
    /// attributes from 3.1.0 to 4.0.1: 4.0.2's query is the same item, so it finds that key, reads nothing else, and
    /// the model the app downloaded stays (a key that changed would delete it and download it again).
    func testTheKeyASigned401AppKeptIsTheKeyFound() {
        let q = KeychainInstallKeyStore().query as NSDictionary
        let of401: NSDictionary = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "quranlab.sdk",
                                   kSecAttrAccount as String: "quranlab.model.install.key", kSecUseDataProtectionKeychain as String: true]
        XCTAssertEqual(q, of401)
        let k = StandIn(.data(Self.a), .data(Self.b), file: .data(Self.c))
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.load(k, readsLogin: true)), "key a")
        XCTAssertEqual(k.calls, ["read data protection"])
    }
}
