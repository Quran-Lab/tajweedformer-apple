import Foundation
import Security

// What the SDK keeps on the device, and what a read of it gives (3.1.4).
//
// The rule: something that is there and cannot be read is not "not there". While it cannot be read, nothing is
// uploaded, deleted, asked, made anew or written on its account; it is read again at the next need. Only an item
// the system says is not there is "not there".
//
// One read serves every state file (`StorageSeam.read`), and one every Keychain item of the contributor
// (`ContributorKeychain.item`). Both give three results, `StoredRead`: not there, read, cannot be read. Which of
// the first and the third it is, is told by the error of the one read: "no such file" (for the Keychain: "item not
// found") against any other failure. No second call decides it (a look whether the file exists), because that
// could race with the read.
//
// Every caller says what it does with the third result. A caller whose item costs the learner nothing when it is
// lost (a token asked for again, a config fetched again, a model downloaded again) takes it as "not there", by
// `takingUnreadableAsMissing` and a line at the call that says why.
//
// Tried before (to 3.1.3): every read gave two results, a value or nothing, so an answer, an id or a recording
// that the device held and could not read (a file of a protected class in a process that the system started
// while the phone was locked) was taken for one that was not there: the learner was asked again and their stored
// answer written over, unsent recordings were deleted, and a new contributor id and device key were made.

/// What a read of something the SDK keeps on the device gave.
enum StoredRead<Value> {
    /// It is not there: the system said so of the one read.
    case missing
    case value(Value)
    /// It is there and cannot be read now, or what was read is not what the SDK writes there.
    case unreadable(Unreadable)

    /// The value, with "cannot be read" taken as "not there". Only where a lost item costs the learner nothing; the
    /// call says why in a line of its own.
    var takingUnreadableAsMissing: Value? {
        if case .value(let v) = self { return v }
        return nil
    }

    var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }

    func map<T>(_ transform: (Value) -> T) -> StoredRead<T> {
        switch self {
        case .missing: return .missing
        case .value(let v): return .value(transform(v))
        case .unreadable(let why): return .unreadable(why)
        }
    }
}

extension StoredRead: Sendable where Value: Sendable {}

extension StoredRead where Value == Data {
    /// The JSON value in the bytes. Bytes that are not that value are there and cannot be read (`damaged`).
    func decoded<T: Decodable>(_ type: T.Type) -> StoredRead<T> {
        switch self {
        case .missing: return .missing
        case .unreadable(let why): return .unreadable(why)
        case .value(let data):
            guard let v = try? JSONDecoder().decode(type, from: data) else { return .unreadable(.damaged("not the JSON the SDK writes there")) }
            return .value(v)
        }
    }
}

/// Why something that is there could not be read.
enum Unreadable: Sendable, Equatable {
    /// The system did not give it (a file of a protected class while the device is locked, a Keychain that does
    /// not answer). It may read at the next need.
    case refused(String)
    /// It was read, and it is not what the SDK writes there.
    case damaged(String)

    var why: String {
        switch self {
        case .refused(let why): return why
        case .damaged(let why): return why
        }
    }
}

/// The one read of a file the SDK keeps, and, for tests (debug builds only), a storage whose reads the system
/// refuses and a stand-in for the Keychain. A release build has neither: there every read is the system's.
enum StorageSeam {
    #if DEBUG
    /// Whether the read of the file at this address is refused now, as the system refuses the read of a file of a
    /// protected class while the device is locked.
    static let refusesReads = Locked<(@Sendable (URL) -> Bool)?>(nil)
    /// A stand-in for the Keychain items of the contributor (its id, the device key, the recovery code).
    static let keychain = Locked<KeychainStandIn?>(nil)
    #endif

    /// Whether a test refuses the read of this file now.
    static func refuses(_ url: URL) -> Bool {
        #if DEBUG
        if let refuse = refusesReads.withLock({ $0 }) { return refuse(url) }
        #endif
        return false
    }

    /// The bytes of a file the SDK keeps, or the error of the read.
    static func data(_ url: URL) throws -> Data {
        if refuses(url) { throw CocoaError(.fileReadNoPermission) }
        return try Data(contentsOf: url)
    }

    /// The bytes of a file the SDK keeps, in three results. "Not there" is the system's "no such file" for this
    /// one read; every other failure (no permission, a protected file while the device is locked, an I/O error)
    /// is "cannot be read".
    static func read(_ url: URL) -> StoredRead<Data> {
        do {
            return .value(try data(url))
        } catch {
            return isNoSuchFile(error) ? .missing : .unreadable(.refused(describe(error)))
        }
    }

    /// Whether an error of a read or a removal says that the file is not there.
    static func isNoSuchFile(_ error: any Error) -> Bool {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain, e.code == NSFileReadNoSuchFileError || e.code == NSFileNoSuchFileError { return true }
        if e.domain == NSPOSIXErrorDomain, e.code == Int(ENOENT) { return true }
        return false
    }

    /// An error in words that name no path: its domain and its code.
    static func describe(_ error: any Error) -> String {
        let e = error as NSError
        return "the read failed (\(e.domain) \(e.code))"
    }
}

/// The protection class of what the SDK keeps: "complete until first user authentication", by name. A file of
/// that class can be read from the first unlock after a restart on, also while the phone is locked: a process the
/// system starts in the background (to hand over finished uploads) can read the learner's answer and the queue.
/// A file of the class "complete" cannot be read while the phone is locked, and an app may make that class its
/// default; until 3.1.3 the SDK named no class, so its files had the app's.
///
/// Named at the write (so that the class does not depend on what a replaced file had): the saved answer and the
/// two marks beside it, the other JSON state files of the `cloud` folder (the remembered refusal, the config, the
/// token and the queues among them), the contributor's files, the registration day and the rollout bucket, every
/// file of a queued recording, the install record, the manifest and the model's pointer files. Every folder the
/// SDK makes for these gets the class when it is made. Getting the class only at a start (`adopt`): the model
/// files as they are downloaded, the accelerator's files, the first-launch marker, and whatever an earlier
/// release wrote. A file that cannot be changed at that moment (the phone is locked) is left for the next start.
///
/// The walk at a start visits the SDK's own four folders in the storage folder and what is in them (`own`,
/// `walk`), never the storage folder itself and nothing else in it: the folder is the app's choice, and files of
/// the app's own that lie there keep the class the app gave them.
enum StorageProtection {
    /// For a write that replaces the file in one step.
    static let atomic: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    /// For a write in place.
    static let inPlace: Data.WritingOptions = [.completeFileProtectionUntilFirstUserAuthentication]
    /// For a folder or a file as it is made.
    static var attributes: [FileAttributeKey: Any] { [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication] }

    /// Gives one file or folder the class; whether the system then reports it.
    @discardableResult
    static func set(_ url: URL) -> Bool {
        let fm = FileManager.default
        try? fm.setAttributes(attributes, ofItemAtPath: url.path)
        let now = (try? fm.attributesOfItem(atPath: url.path))?[.protectionKey] as? FileProtectionType
        return now == FileProtectionType.completeUntilFirstUserAuthentication
    }

    /// Makes a folder (and the folders above it that are not there) and gives it the class. The class is set
    /// after the folder is made, and a system that keeps no class for it is not an error.
    static func makeFolder(_ url: URL) throws {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue { return }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try? fm.setAttributes(attributes, ofItemAtPath: url.path)
    }

    /// The SDK's own folders in a storage folder.
    static let own = ["cloud", "models", "outbox", "accelerator"]

    /// Every path the walk of a start visits: the SDK's own folders that are there, and every file and folder in
    /// them. Not the storage folder itself, and nothing else that lies in it.
    static func walk(_ storage: URL, _ visit: (URL) -> Void) {
        let fm = FileManager.default
        for name in own {
            let folder = storage.appendingPathComponent(name, isDirectory: true)
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else { continue }
            visit(folder)
            guard let all = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
            while let url = all.nextObject() as? URL { visit(url) }
        }
    }

    /// At a start: the SDK's own folders and everything in them get the class, in the background.
    static func adopt(_ storage: URL) {
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            walk(storage) { (url: URL) in
                let now = (try? fm.attributesOfItem(atPath: url.path))?[.protectionKey] as? FileProtectionType
                if now != FileProtectionType.completeUntilFirstUserAuthentication { try? fm.setAttributes(attributes, ofItemAtPath: url.path) }
            }
        }
    }
}

/// What the Keychain answers for one item of the contributor, in tests.
struct KeychainStandIn: Sendable {
    var read: @Sendable (_ account: String) -> (status: OSStatus, data: Data?)
    var add: @Sendable (_ account: String, _ data: Data) -> OSStatus
    var delete: @Sendable (_ account: String) -> OSStatus
}

/// The Keychain items of the contributor (its id, the device key, the recovery code): one generic password per
/// account under the service `quranlab.sdk`, in the data protection keychain, this device only, never synced,
/// readable after the first unlock.
enum ContributorKeychain {
    static let service = "quranlab.sdk"

    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true]
    }

    private static var standIn: KeychainStandIn? {
        #if DEBUG
        if let s = StorageSeam.keychain.withLock({ $0 }) { return s }
        #endif
        return nil
    }

    /// The item's bytes, with the status of the read.
    static func read(_ account: String) -> (status: OSStatus, data: Data?) {
        if let s = standIn { return s.read(account) }
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        return (status, status == errSecSuccess ? out as? Data : nil)
    }

    /// Adds the item; the add's status.
    static func add(_ account: String, _ data: Data) -> OSStatus {
        if let s = standIn { return s.add(account, data) }
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false
        return SecItemAdd(q as CFDictionary, nil)
    }

    @discardableResult
    static func delete(_ account: String) -> OSStatus {
        if let s = standIn { return s.delete(account) }
        return SecItemDelete(query(account) as CFDictionary)
    }

    /// One item of the contributor in three results: the Keychain's, or, for a process without a Keychain, the
    /// file's in the SDK's storage. "Not there" is only this: the Keychain says "item not found" (or refuses this
    /// process for good, `errSecMissingEntitlement`: such a process keeps the item in the file), and the file is
    /// not there. Every other status of the Keychain, the one of a read before the first unlock included, is
    /// "cannot be read": the file is not looked at then, because the Keychain may hold another item.
    static func item(_ account: String, file: URL) -> StoredRead<Data> {
        let (status, data) = read(account)
        if status == errSecSuccess {
            guard let data else { return .unreadable(.damaged("the Keychain item holds no bytes")) }
            return .value(data)
        }
        guard status == errSecItemNotFound || status == errSecMissingEntitlement else {
            return .unreadable(.refused("the Keychain did not give the item (status \(status))"))
        }
        return StorageSeam.read(file)
    }

    /// Keeps a new item: in the Keychain, or, when the Keychain does not take it, in the file. Called only when
    /// the item is not there: nothing is deleted or replaced. An add the Keychain answers with "duplicate item"
    /// writes nothing: the item that is there stays.
    static func keep(_ account: String, _ data: Data, file: URL) {
        let status = add(account, data)
        if status == errSecSuccess || status == errSecDuplicateItem { return }
        try? StorageProtection.makeFolder(file.deletingLastPathComponent())
        try? data.write(to: file, options: StorageProtection.atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
