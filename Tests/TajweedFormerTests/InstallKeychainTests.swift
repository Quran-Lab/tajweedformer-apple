import Foundation
import Security
import XCTest
@testable import TajweedFormer

#if os(macOS)

/// The install key in the real Keychain of the test's Mac. The test process is a command-line tool without an
/// application identifier, as the Mac tools of the report were: a key one start keeps must be the key the next start
/// finds, or every start deletes the model and downloads it again. The item has the test's own names and is deleted
/// afterwards.
final class InstallKeychainTests: XCTestCase {
    /// A store with names of its own.
    static func store() -> KeychainInstallKeyStore {
        KeychainInstallKeyStore(service: "quranlab.sdk.test", account: "install.key.test." + UUID().uuidString)
    }

    /// Deletes both of the store's items (the data protection keychain's and the login keychain's).
    static func remove(_ store: KeychainInstallKeyStore) {
        SecItemDelete(store.query as CFDictionary)
        SecItemDelete(store.loginQuery as CFDictionary)
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
    /// finds that key (`load`). The Keychain's own answers are printed for the record.
    func testTheKeyOneStartKeepsIsTheKeyTheNextStartFinds() throws {
        let first = Self.store()
        defer { Self.remove(first) }
        let answers = Self.measure(first)
        print("keychain: this test process, the data protection keychain: a read of a missing item answers \(answers.read), an add answers \(answers.add) (errSecItemNotFound \(errSecItemNotFound), errSecMissingEntitlement \(errSecMissingEntitlement))")
        XCTAssertEqual(first.load(), .none, "no key yet")
        let created = first.create()
        guard case .key(let key) = created else { return XCTFail("the key store did not keep a key: \(created)") }
        let next = KeychainInstallKeyStore(service: first.service, account: first.account)
        XCTAssertEqual(next.load(), .key(key), "the next start finds the key the first one kept")
        XCTAssertEqual(next.create(), .key(key), "and a create after a read that missed it gives that key, never a new one")
        XCTAssertEqual(next.load(), .key(key))
    }
}
#endif

/// The install key store's decision, over a stand-in for the two keychains: for each answer of a read, where `load`
/// looks next and what it gives, and that `create` never replaces a key a second read finds. On macOS the login
/// keychain is the second place; on iOS there is none.
final class InstallKeyDecisionTests: XCTestCase {
    final class StandIn: InstallKeychains {
        var dataProtection: KeychainAnswer
        var login: KeychainAnswer
        var dataProtectionAdd: OSStatus = errSecSuccess
        var loginAdd: OSStatus = errSecSuccess
        var calls: [String] = []

        init(_ dataProtection: KeychainAnswer, _ login: KeychainAnswer) {
            self.dataProtection = dataProtection
            self.login = login
        }

        func readDataProtection() -> KeychainAnswer { calls.append("read data protection"); return dataProtection }
        func readLogin() -> KeychainAnswer { calls.append("read login"); return login }
        func writeDataProtection(_ key: Data) -> OSStatus {
            calls.append("write data protection")
            if dataProtectionAdd == errSecSuccess { dataProtection = .data(key) }
            return dataProtectionAdd
        }
        func writeLogin(_ key: Data) -> OSStatus {
            calls.append("write login")
            if loginAdd == errSecSuccess { login = .data(key) }
            return loginAdd
        }
    }

    static let a = Data(repeating: 0xA1, count: KeychainInstallKeyStore.keyBytes)
    static let b = Data(repeating: 0xB2, count: KeychainInstallKeyStore.keyBytes)
    static let fresh = Data(repeating: 0xC3, count: KeychainInstallKeyStore.keyBytes)
    static let locked = KeychainAnswer.error(errSecInteractionNotAllowed)

    /// `.key` with which key, `none`, or `failed`.
    static func kind(_ l: InstallKeyLookup) -> String {
        switch l {
        case .key(let d): return d == a ? "key a" : (d == b ? "key b" : (d == fresh ? "key fresh" : "key other"))
        case .none: return "none"
        case .failed: return "failed"
        }
    }

    func testWhereLoadLooksForEachAnswer() {
        let readBoth = ["read data protection", "read login"]
        let readFirst = ["read data protection"]
        // (the data protection keychain's answer, the login keychain's, macOS, what load gives, the reads)
        let rows: [(KeychainAnswer, KeychainAnswer, Bool, String, [String])] = [
            // macOS
            (.data(Self.a), .data(Self.b), true, "key a", readFirst),
            (.notFound, .data(Self.b), true, "key b", readBoth),
            (.notFound, .notFound, true, "none", readBoth),
            (.notFound, Self.locked, true, "failed", readBoth),
            (.missingEntitlement, .data(Self.b), true, "key b", readBoth),
            (.missingEntitlement, .notFound, true, "none", readBoth),
            (.missingEntitlement, Self.locked, true, "failed", readBoth),
            (Self.locked, .data(Self.b), true, "failed", readFirst),
            (.data(Data([1, 2, 3])), .data(Self.b), true, "none", readFirst),
            // iOS: no second place
            (.data(Self.a), .data(Self.b), false, "key a", readFirst),
            (.notFound, .data(Self.b), false, "none", readFirst),
            (.missingEntitlement, .data(Self.b), false, "failed", readFirst),
            (Self.locked, .data(Self.b), false, "failed", readFirst),
        ]
        for (first, second, mac, wanted, reads) in rows {
            let k = StandIn(first, second)
            let got = KeychainInstallKeyStore.load(k, readsLogin: mac)
            let at = "\(mac ? "macOS" : "iOS"): data protection \(first), login \(second)"
            XCTAssertEqual(Self.kind(got), wanted, at)
            XCTAssertEqual(k.calls, reads, at)
        }
    }

    func testCreateNeverReplacesAKeyASecondReadFinds() {
        // a Mac process without an application identifier, first start: the data protection keychain finds nothing
        // and refuses the add; the login keychain has nothing: the new key goes there
        var k = StandIn(.notFound, .notFound)
        k.dataProtectionAdd = errSecMissingEntitlement
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: true, newKey: Self.fresh)), "key fresh")
        XCTAssertEqual(k.calls, ["read data protection", "write data protection", "read login", "write login"])
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.load(k, readsLogin: true)), "key fresh", "the next start finds it")
        // the same process when the login keychain already holds a key a read missed: that key, nothing written
        k = StandIn(.notFound, .data(Self.b))
        k.dataProtectionAdd = errSecMissingEntitlement
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: true, newKey: Self.fresh)), "key b")
        XCTAssertFalse(k.calls.contains("write login"))
        // a key the data protection keychain holds after all: that key, nothing written
        k = StandIn(.data(Self.a), .notFound)
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: true, newKey: Self.fresh)), "key a")
        XCTAssertEqual(k.calls, ["read data protection"])
        // an app with an application identifier, first start: the data protection keychain keeps it, the login
        // keychain is never touched
        k = StandIn(.notFound, .data(Self.b))
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: true, newKey: Self.fresh)), "key fresh")
        XCTAssertEqual(k.calls, ["read data protection", "write data protection"])
        // iOS: a refused add is a failure, there is no second place
        k = StandIn(.notFound, .notFound)
        k.dataProtectionAdd = errSecMissingEntitlement
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: false, newKey: Self.fresh)), "failed")
        XCTAssertFalse(k.calls.contains("read login"))
        // any other refusal of the add is a failure, also on macOS
        k = StandIn(.notFound, .notFound)
        k.dataProtectionAdd = errSecInteractionNotAllowed
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: true, newKey: Self.fresh)), "failed")
        XCTAssertFalse(k.calls.contains("write login"))
        // no random bytes: a failure, nothing written
        k = StandIn(.notFound, .notFound)
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: true, newKey: nil)), "failed")
        XCTAssertEqual(k.calls, [])
    }
}
