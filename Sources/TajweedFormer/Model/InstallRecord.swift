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

/// The Keychain. On iOS: the data protection keychain, this device only, readable after first unlock, and nothing
/// else. On macOS the same first; a Mac process without an application identifier (an unsigned or ad hoc signed
/// binary, a command-line tool, an app signed without a provisioning profile) is refused by that keychain with
/// `errSecMissingEntitlement`, and only then the Mac's login keychain holds the key, in an item named for the
/// app's bundle id. A login keychain can travel to another Mac with the user's account. There is no file fallback:
/// every other answer of either keychain is a failure (`storage_failed`), and "item not found" is "no key".
struct KeychainInstallKeyStore: InstallKeyStoring {
    static let service = "quranlab.sdk"
    static let account = "quranlab.model.install.key"
    static let keyBytes = 32

    /// The item in the data protection keychain (per app by its access group).
    var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account,
         kSecUseDataProtectionKeychain as String: true]
    }

    /// The item in the Mac's login keychain, named for the app: two apps that use the SDK do not share it.
    var loginQuery: [String: Any] {
        let app = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: Self.account + "." + app]
    }

    private enum Answer {
        case data(Data)
        case notFound
        case missingEntitlement
        case error(OSStatus)
    }

    private static func read(_ query: [String: Any]) -> Answer {
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

    private static func lookup(_ a: Answer) -> InstallKeyLookup {
        switch a {
        // an item of another size is not a key: a new one takes its place
        case .data(let d): return d.count == keyBytes ? .key(d) : .none
        case .notFound: return .none
        case .missingEntitlement: return .failed("the Keychain refuses this process (errSecMissingEntitlement)")
        case .error(let status): return .failed("the Keychain did not answer (status \(status))")
        }
    }

    func load() -> InstallKeyLookup {
        let first = Self.read(query)
        #if os(macOS)
        if case .missingEntitlement = first { return Self.lookup(Self.read(loginQuery)) }
        #endif
        return Self.lookup(first)
    }

    private static func add(_ query: [String: Any], _ key: Data, deviceOnly: Bool) -> OSStatus {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = key
        if deviceOnly {
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            q[kSecAttrSynchronizable as String] = false
        }
        return SecItemAdd(q as CFDictionary, nil)
    }

    func create() -> InstallKeyLookup {
        var bytes = [UInt8](repeating: 0, count: Self.keyBytes)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return .failed("the system gave no random bytes for the install key")
        }
        let key = Data(bytes)
        var status = Self.add(query, key, deviceOnly: true)
        #if os(macOS)
        if status == errSecMissingEntitlement { status = Self.add(loginQuery, key, deviceOnly: false) }
        #endif
        return status == errSecSuccess ? .key(key) : .failed("the Keychain did not keep the install key (status \(status))")
    }
}

/// How a build folder stands to this Client.
enum InstallStanding: Sendable, Equatable {
    /// The folder has a valid record of this device for its build, in this state.
    case own(InstallRecord.State)
    /// Not the Client's, and why: it is not opened, and it is deleted.
    case notOwn(String)
    /// The key store failed: nothing is opened, deleted or downloaded.
    case keyStoreFailed(String)
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

    static func read(_ folder: URL) -> InstallRecord? {
        guard let data = try? Data(contentsOf: url(folder)) else { return nil }
        return try? JSONDecoder().decode(InstallRecord.self, from: data)
    }

    /// The build id of the manifest.json in `folder`: the first 40 hex digits of the SHA-256 of its bytes.
    static func buildOnDisk(_ folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(ModelManifest.fileName)) else { return nil }
        return String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(40))
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
            guard let r = read(folder) else { return .notOwn("the folder has no install record") }
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
            try e.encode(record).write(to: url(folder), options: .atomic)
        } catch {
            throw .storageFailed("cannot write the install record: \(error.localizedDescription)")
        }
    }

    /// The words of a key store failure: nothing was opened, deleted or downloaded, and the next call tries again.
    static func keyStoreMessage(_ why: String) -> String {
        "the device's key store did not answer (\(why)); no model was opened, deleted or downloaded, and the next call tries again"
    }
}
