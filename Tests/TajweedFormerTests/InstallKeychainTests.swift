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
        store.deleteLogin()
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
        let login = first.readLogin()
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
            XCTAssertNotEqual(first.readLogin(), .data(key), "the login keychain is never written")
        }
    }

    /// The login keychain's query asks for no UI: a read answers at once whatever the keychain's state (locked over
    /// SSH: not found or `errSecInteractionNotAllowed`; unlocked: not found), never a wait.
    func testTheLoginKeychainIsReadWithoutUI() {
        let store = Self.store()
        defer { Self.remove(store) }
        XCTAssertNotNil(store.loginQuery[kSecUseAuthenticationContext as String], "an LAContext that does not allow interaction")
        let t0 = Date()
        let answer = store.readLogin()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3, "the read's own limit (2 s) at most")
        XCTAssertTrue(([.notFound, .error(errSecInteractionNotAllowed)] as [KeychainAnswer]).contains(answer), "\(answer)")
    }

    /// SDK 4.0.5 (the developer report of 11-23: a rebuilt ad hoc tool waited on a keychain dialog): an install key in the
    /// real login keychain made by another code signature (`/usr/bin/security`, whose access list names only itself).
    /// This process reads it without UI: at once, never a dialog. It either reads it (a keychain that lets it) and moves
    /// it to the SDK's file, or is refused, and then keeps a new key in the file; either way the next start reads the
    /// file and not the login keychain. Needs an unlocked login keychain: skipped where it is locked (over SSH).
    func testALoginKeychainItemOfAnotherSignatureNeverWaits() throws {
        let store = Self.store()
        defer { Self.remove(store) }
        let app = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let hex = String(repeating: "b2", count: KeychainInstallKeyStore.keyBytes)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        // -T /usr/bin/security: only the security tool is trusted, so this test process is another signature
        p.arguments = ["add-generic-password", "-s", store.service, "-a", store.account + "." + app, "-X", hex, "-T", "/usr/bin/security"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let why = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw XCTSkip("the login keychain did not take a test item here (locked over SSH?): \(why)")
        }
        defer {
            let d = Process()
            d.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            d.arguments = ["delete-generic-password", "-s", store.service, "-a", store.account + "." + app]
            d.standardError = Pipe()
            d.standardOutput = Pipe()
            try? d.run()
            d.waitUntilExit()
        }
        let t0 = Date()
        let first = store.load()
        let key: Data
        switch first {
        case .key(let d):
            key = d
            XCTAssertEqual(d, Data(repeating: 0xB2, count: KeychainInstallKeyStore.keyBytes), "the login keychain's key")
        case .none:
            guard case .key(let d) = store.create() else { return XCTFail("no key kept") }
            key = d
        case .failed(let why):
            return XCTFail("a failure: \(why)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5, "no dialog was waited on")
        print("keychain: an item of another signature read without UI answered \(store.readLogin()); load gave \(first)")
        let next = KeychainInstallKeyStore(service: store.service, account: store.account, file: store.file)
        XCTAssertEqual(next.load(), .key(key), "the next start finds the same key")
        // a process the data protection keychain refuses (this test's, unsigned) keeps the key in the SDK's file
        if Self.measure(store).add == errSecMissingEntitlement {
            XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.file)), key, "the key is in the SDK's file")
        }
    }

    /// SDK 4.0.5: a login keychain read that never answers (on macOS 26 a legacy keychain item of another signature
    /// still waited on its access dialog with nobody there to answer, LAContext or not) is taken as refused once its
    /// limit has passed; the keychain's interaction switch is off while the read runs and as it was afterwards.
    func testALoginReadThatNeverAnswersIsRefusedAfterItsLimit() {
        var before = DarwinBoolean(true)
        _ = SecKeychainGetUserInteractionAllowed(&before)
        let never = DispatchSemaphore(value: 0)
        defer { never.signal() }  // lets the left thread go at the end
        let t0 = Date()
        let answer = KeychainInstallKeyStore.withoutKeychainInteraction(limit: 0.3) {
            never.wait()
            return .notFound
        }
        XCTAssertEqual(answer, .error(errSecInteractionNotAllowed), "refused, as a keychain that would ask")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2, "it did not wait for the read")
        var after = DarwinBoolean(!before.boolValue)
        _ = SecKeychainGetUserInteractionAllowed(&after)
        XCTAssertEqual(after.boolValue, before.boolValue, "the keychain's interaction switch is as it was")
        let during = KeychainInstallKeyStore.withoutKeychainInteraction(limit: 2) {
            var now = DarwinBoolean(true)
            _ = SecKeychainGetUserInteractionAllowed(&now)
            return now.boolValue ? .data(Data([1])) : .notFound
        }
        XCTAssertEqual(during, .notFound, "no user interaction while the read runs")
        // and the decision with such a refusal: no key there, so the file keeps the next one
        let k = InstallKeyDecisionTests.StandIn(.notFound, .error(errSecInteractionNotAllowed), file: .notFound)
        XCTAssertEqual(KeychainInstallKeyStore.load(k, readsLogin: true), .none)
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
        // SDK 4.0.5: a key found in the login keychain is written to the SDK's file at once
        let moved = all + ["write file"]
        // (the data protection keychain's answer, the login keychain's, the file's, macOS, what load gives, the reads)
        let rows: [(KeychainAnswer, KeychainAnswer, KeychainAnswer, Bool, String, [String])] = [
            // macOS
            (.data(Self.a), .data(Self.b), .data(Self.c), true, "key a", first),
            (.notFound, .data(Self.b), .notFound, true, "key b", moved),
            (.notFound, .notFound, .notFound, true, "none", all),
            // a locked login keychain (over SSH) refuses at once: no key there, the file keeps the next one
            (.notFound, Self.locked, .notFound, true, "none", all),
            (.missingEntitlement, .data(Self.b), .notFound, true, "key b", moved),
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
        // a key the login keychain holds (kept there by 3.1.0 to 4.0.1): that key, moved to the SDK's file (4.0.5)
        k = StandIn(.notFound, .data(Self.b))
        k.dataProtectionAdd = errSecMissingEntitlement
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.create(k, readsLogin: true, newKey: Self.fresh)), "key b")
        XCTAssertEqual(k.calls.last, "write file")
        XCTAssertEqual(k.file, .data(Self.b))
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

    /// SDK 4.0.5 (the developer report of 11-23): a key found in the login keychain is moved to the SDK's file at its first
    /// read, so the login keychain is read once per install. Three starts of an upgraded Mac tool: the first reads the
    /// login keychain and writes the file; the next two read the file and never the login keychain. A file that cannot be
    /// written changes nothing (the key is the login keychain's, as before).
    func testAKeyInTheLoginKeychainIsMovedToTheFileAtItsFirstRead() {
        let k = StandIn(.missingEntitlement, .data(Self.b))
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.load(k, readsLogin: true)), "key b")
        XCTAssertEqual(k.calls, ["read data protection", "read file", "read login", "write file"])
        for _ in 0..<2 {
            k.calls = []
            XCTAssertEqual(Self.kind(KeychainInstallKeyStore.load(k, readsLogin: true)), "key b")
            XCTAssertEqual(k.calls, ["read data protection", "read file"], "the login keychain is not read again")
        }
        let w = StandIn(.missingEntitlement, .data(Self.b))
        w.fileWrites = false
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.load(w, readsLogin: true)), "key b")
        XCTAssertEqual(Self.kind(KeychainInstallKeyStore.load(w, readsLogin: true)), "key b", "still the login keychain's key")
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
