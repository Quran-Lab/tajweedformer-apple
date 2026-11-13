import CryptoKit
import Foundation
import Security

// The install record (SDK 3.1.0, SPEC 15.2): the Client opens only a build it downloaded itself.
//
// When the Client starts downloading a build it writes a record for that build with the state `downloading`, before
// the first file is asked for; when every file of the download profile is verified it rewrites it with the state
// `installed`. The record is bound to the device: its MAC is made with a key that lives in the Keychain, where an
// app's files cannot carry it. A build folder without a valid record is not the Client's: it is never opened, none
// of its files is reused or resumed, it is deleted, and the build is downloaded from Quran Lab's server.
//
// Tried before (to 3.0.1): the Client opened whatever verified model folder it found in its storage (and in the app
// bundle), so a model shipped inside an app, or copied from another device, ran without ever being downloaded.

/// What the device's key store answered.
enum InstallKeyLookup: Sendable, Equatable {
    case key(Data)
    /// There is no key: no record on this device can be valid.
    case none
    /// The store failed in another way (locked, unavailable): nothing is opened, deleted or downloaded.
    case failed(String)
}

/// Where the device key of the install record lives. Tests use a stand-in; an app cannot set one.
protocol InstallKeyStoring: Sendable {
    func load() -> InstallKeyLookup
    /// Makes a key (32 random bytes) and keeps it: `.key`, or `.failed`.
    func create() -> InstallKeyLookup
}

/// What one keychain answered a read of the install key.
enum KeychainAnswer: Equatable, Sendable {
    case data(Data)
    case notFound
    case missingEntitlement
    case error(OSStatus)
}

/// The two keychains the key store uses: the system's, or a test's stand-in.
protocol InstallKeychains {
    func readDataProtection() -> KeychainAnswer
    func readLogin() -> KeychainAnswer
    /// Puts `key` in place of the item: the add's status.
    func writeDataProtection(_ key: Data) -> OSStatus
    func writeLogin(_ key: Data) -> OSStatus
}

/// The Keychain. On iOS: the data protection keychain, this device only, readable after first unlock, and nothing
/// else. On macOS the same first. A Mac process without an application identifier (an unsigned or ad hoc signed
/// binary, a command-line tool, an app signed without a provisioning profile) cannot keep an item there: that
/// keychain answers its read with `errSecItemNotFound` (-25300), as if there were no item, and only its add with
/// `errSecMissingEntitlement` (-34018) (measured on the CI's Mac runner, whose test process is such a process). So on
/// macOS, when the data protection keychain finds nothing or refuses the process, the Mac's login keychain is read
/// before the answer is "no key"; a key is written there only when the data protection keychain refuses the add; the
/// item there is named for the app's bundle id. A login keychain can travel to another Mac with the user's account.
/// There is no file fallback: every other answer of either keychain is a failure (`storage_failed`).
///
/// Until 3.1.0 the login keychain was read only after a read refused with `errSecMissingEntitlement`, which such a
/// process never gets: every start found no key, wrote a new one, and deleted and downloaded the model again.
struct KeychainInstallKeyStore: InstallKeyStoring {
    static let defaultService = "quranlab.sdk"
    static let defaultAccount = "quranlab.model.install.key"
    static let keyBytes = 32
    /// The item's names (a test uses names of its own).
    var service = KeychainInstallKeyStore.defaultService
    var account = KeychainInstallKeyStore.defaultAccount

    /// macOS has a second place for the key, the login keychain; iOS has none.
    #if os(macOS)
    static let readsLogin = true
    #else
    static let readsLogin = false
    #endif

    /// The item in the data protection keychain (per app by its access group).
    var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    /// The item in the Mac's login keychain, named for the app: two apps that use the SDK do not share it.
    var loginQuery: [String: Any] {
        let app = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account + "." + app]
    }

    static func read(_ query: [String: Any]) -> KeychainAnswer {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecSuccess {
            guard let d = out as? Data else { return .error(status) }
            return .data(d)
        }
        if status == errSecItemNotFound { return .notFound }
        if status == errSecMissingEntitlement { return .missingEntitlement }
        return .error(status)
    }

    static func add(_ query: [String: Any], _ key: Data, deviceOnly: Bool) -> OSStatus {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = key
        if deviceOnly {
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            q[kSecAttrSynchronizable as String] = false
        }
        return SecItemAdd(q as CFDictionary, nil)
    }

    private static func lookup(_ a: KeychainAnswer) -> InstallKeyLookup {
        switch a {
        // an item of another size is not a key: a new one takes its place
        case .data(let d): return d.count == keyBytes ? .key(d) : .none
        case .notFound: return .none
        case .missingEntitlement: return .failed("the Keychain refuses this process (errSecMissingEntitlement)")
        case .error(let status): return .failed("the Keychain did not answer (status \(status))")
        }
    }

    /// The key, as `load` decides it: the data protection keychain's; on macOS (`readsLogin`), when that keychain
    /// finds nothing or refuses the process, the login keychain's. Every other answer is a failure.
    static func load(_ keychains: any InstallKeychains, readsLogin: Bool) -> InstallKeyLookup {
        let first = keychains.readDataProtection()
        if readsLogin {
            switch first {
            case .notFound, .missingEntitlement: return lookup(keychains.readLogin())
            case .data, .error: break
            }
        }
        return lookup(first)
    }

    /// A new key kept, as `create` decides it. A key that a second read finds is that key, never replaced: the data
    /// protection keychain is read again first, and on macOS the login keychain is read again before anything is
    /// written there. A key goes to the login keychain only when the data protection keychain refuses the add.
    static func create(_ keychains: any InstallKeychains, readsLogin: Bool, newKey: Data?) -> InstallKeyLookup {
        guard let key = newKey else { return .failed("the system gave no random bytes for the install key") }
        if case .data(let d) = keychains.readDataProtection(), d.count == keyBytes { return .key(d) }
        var status = keychains.writeDataProtection(key)
        if readsLogin && status == errSecMissingEntitlement {
            if case .data(let d) = keychains.readLogin(), d.count == keyBytes { return .key(d) }
            status = keychains.writeLogin(key)
        }
        return status == errSecSuccess ? .key(key) : .failed("the Keychain did not keep the install key (status \(status))")
    }

    static func randomKey() -> Data? {
        var bytes = [UInt8](repeating: 0, count: keyBytes)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    func load() -> InstallKeyLookup { Self.load(SystemKeychains(store: self), readsLogin: Self.readsLogin) }

    func create() -> InstallKeyLookup {
        Self.create(SystemKeychains(store: self), readsLogin: Self.readsLogin, newKey: Self.randomKey())
    }
}

/// The system's two keychains for one store's item.
struct SystemKeychains: InstallKeychains {
    let store: KeychainInstallKeyStore
    func readDataProtection() -> KeychainAnswer { KeychainInstallKeyStore.read(store.query) }
    func readLogin() -> KeychainAnswer { KeychainInstallKeyStore.read(store.loginQuery) }
    func writeDataProtection(_ key: Data) -> OSStatus { KeychainInstallKeyStore.add(store.query, key, deviceOnly: true) }
    func writeLogin(_ key: Data) -> OSStatus { KeychainInstallKeyStore.add(store.loginQuery, key, deviceOnly: false) }
}

/// How a build folder stands to this Client.
enum InstallStanding: Sendable, Equatable {
    /// The folder has a valid record of this device for its build, in this state.
    case own(InstallRecord.State)
    /// Not the Client's, and why: it is not opened, and it is deleted.
    case notOwn(String)
    /// The key store failed: nothing is opened, deleted or downloaded.
    case keyStoreFailed(String)
    /// The folder's install record or its manifest is there and cannot be read now (3.1.4): nothing is opened,
    /// deleted or downloaded, and the next call reads again. Until 3.1.3 such a folder was "not the Client's": it
    /// was deleted and the build downloaded again.
    case unreadable(String)
}

/// The record of one build folder: `.quranlab-install` inside it (it moves with the folder when a finished download
/// is put in place, and goes when the folder is deleted). Never a file a manifest lists.
struct InstallRecord: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case downloading
        case installed
    }

    var v = 1
    /// The build id: the first 40 hex digits of the SHA-256 of the build's manifest.json.
    var build: String
    var state: State
    /// HMAC-SHA256(device key, "quranlab-model-install 1\n" + build + "\n" + state + "\n"), hex.
    var mac: String

    static let fileName = ".quranlab-install"

    static func message(build: String, state: State) -> Data { Data("quranlab-model-install 1\n\(build)\n\(state.rawValue)\n".utf8) }

    static func mac(key: Data, build: String, state: State) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: message(build: build, state: state), using: SymmetricKey(data: key))).hex
    }

    static func url(_ folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    /// The record of a folder in three results (3.1.4). Bytes that were read and are not a record are `unreadable`
    /// with `damaged`: `standing` takes those for "not the Client's", as a record with another MAC.
    static func stored(_ folder: URL) -> StoredRead<InstallRecord> {
        StorageSeam.read(url(folder)).decoded(InstallRecord.self)
    }

    static func read(_ folder: URL) -> InstallRecord? {
        // unreadable is taken as not there here: this is a look at the record for the tests; what decides whether
        // a folder is opened or deleted is `standing`
        stored(folder).takingUnreadableAsMissing
    }

    /// The build id of the manifest.json in `folder`, in three results: the first 40 hex digits of the SHA-256 of
    /// its bytes.
    static func storedBuild(_ folder: URL) -> StoredRead<String> {
        StorageSeam.read(folder.appendingPathComponent(ModelManifest.fileName)).map { (data: Data) -> String in
            String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(40))
        }
    }

    /// The build id of the manifest.json in `folder`: the first 40 hex digits of the SHA-256 of its bytes.
    static func buildOnDisk(_ folder: URL) -> String? {
        // unreadable is taken as not there here: this is a look at the build for the tests (see `storedBuild`)
        storedBuild(folder).takingUnreadableAsMissing
    }

    /// How `folder` stands for the build `build`. The key store is asked first: when it fails, that is the answer,
    /// whatever the folder holds. Then: no key, no record, a record of another build, or a MAC that this device's
    /// key did not make, are all "not the Client's".
    static func standing(of folder: URL, build: String, keys: any InstallKeyStoring) -> InstallStanding {
        switch keys.load() {
        case .failed(let why):
            return .keyStoreFailed(why)
        case .none:
            return .notOwn("this device has no install key")
        case .key(let key):
            let r: InstallRecord
            switch stored(folder) {
            case .value(let read): r = read
            case .missing: return .notOwn("the folder has no install record")
            // damaged is taken as no record here (bytes that were read and are not a record), as before 3.1.4:
            // the folder is not the Client's, as with a record of another MAC, and as with a record that was deleted
            case .unreadable(.damaged): return .notOwn("the folder has no install record")
            // refused is held: the system does not give the record now, so the folder is neither the Client's nor
            // not the Client's, and nothing is opened, deleted or downloaded
            case .unreadable(.refused(let why)): return .unreadable(why)
            }
            guard r.v == 1, r.build == build else { return .notOwn("the install record is of another build") }
            let want = Array(mac(key: key, build: build, state: r.state).utf8), got = Array(r.mac.utf8)
            var differ = UInt8(want.count == got.count ? 0 : 1)
            for i in 0..<min(want.count, got.count) { differ |= want[i] ^ got[i] }
            guard differ == 0 else { return .notOwn("the install record was not made on this device") }
            return .own(r.state)
        }
    }

    /// Writes the record of `build` in `state` into `folder` (made when it is not there), with this device's key,
    /// which is made now when the device has none. A key store that fails, or a record that cannot be written, is
    /// `storageFailed`.
    static func write(_ state: State, build: String, in folder: URL, keys: any InstallKeyStoring) throws(RecognizerError) {
        var found = keys.load()
        if case .none = found { found = keys.create() }
        guard case .key(let key) = found else {
            if case .failed(let why) = found { throw .storageFailed(keyStoreMessage(why)) }
            throw .storageFailed(keyStoreMessage("no install key could be made"))
        }
        let record = InstallRecord(build: build, state: state, mac: mac(key: key, build: build, state: state))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys]
            try e.encode(record).write(to: url(folder), options: StorageProtection.atomic)
        } catch {
            throw .storageFailed("cannot write the install record: \(error.localizedDescription)")
        }
    }

    /// The words of an install record or a manifest that cannot be read: nothing was opened, deleted or downloaded.
    static func unreadableMessage(_ why: String) -> String {
        "the model on this device cannot be read now (\(why)); no model was opened, deleted or downloaded, and the next call tries again"
    }

    /// The words of a key store failure: nothing was opened, deleted or downloaded, and the next call tries again.
    static func keyStoreMessage(_ why: String) -> String {
        "the device's key store did not answer (\(why)); no model was opened, deleted or downloaded, and the next call tries again"
    }
}
