import CryptoKit
import Darwin
import Foundation
import QuranLabCore

// The services the Core asks of the SDK (qlcore.h `qlc_platform`, contract 18.5.2): the Core does no networking and
// no file I/O of its own. Everything it reads or writes is opaque bytes named by a form and a decoded path, and every
// key operation goes to the install's key store. Nothing here sees a plaintext model file: the CDN form and the
// device form are ciphertext, the plain form holds only what the manifest keeps plain (calibration, self-test clips).

/// Where each form lives, under the SDK's storage folder:
///
///     models/<model>/<build folder>/<path>          plain files (the manifest's plain rule: calibration.json, selftest/)
///     models/<model>/<build folder>/<path>.qle      the CDN form, as downloaded (deleted once installed)
///     models/<model>/<build folder>/<path>.qld      the device form the Core wrote at install
///     core/<path>.qlc                               the Core's own small files (the recited journal)
///
/// The build folder is the one the current Core call works on (`CoreHost` sets it around each call), else the open
/// model's folder while a long call on it runs (the reference data at first use, an accelerator program's prepare).
/// Paths from a manifest are refused when they climb out of their folder.
final class CoreStorage: @unchecked Sendable {
    enum Form: Int32 {
        case plain = 0, cdn = 1, device = 2, core = 3
    }

    let root: URL
    private let lock = NSLock()
    private var buildFolder: URL?
    /// The open model's folder during a long call on it (`CoreHost.withModelFolder`).
    private var pinnedFolder: URL?
    /// The part file being written, kept open between writes (closed at commit, remove and a write to another file).
    private var writing: (url: URL, handle: FileHandle)?
    /// Read-only mappings handed to the Core (the recited index; the device forms at an open, R3 and R2), by address:
    /// always a mapping of the file itself (`mmap`), as qlcore.h requires, never a copy.
    private var mappings: [UInt: Int] = [:]

    init(root: URL) { self.root = root }

    /// The build folder of the calls that follow.
    func setBuild(_ folder: URL?) {
        lock.lock()
        buildFolder = folder
        lock.unlock()
    }

    /// The open model's folder for a call that runs outside the Core host's call lock.
    func setPinned(_ folder: URL?) {
        lock.lock()
        pinnedFolder = folder
        lock.unlock()
    }

    static func safe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    func url(_ form: Form, _ path: String) -> URL? {
        guard Self.safe(path) else { return nil }
        if form == .core { return root.appendingPathComponent("core").appendingPathComponent(path + ".qlc") }
        lock.lock()
        let b = buildFolder ?? pinnedFolder
        lock.unlock()
        guard let b else { return nil }
        switch form {
        case .plain: return b.appendingPathComponent(path)
        case .cdn: return b.appendingPathComponent(path + ".qle")
        case .device: return b.appendingPathComponent(path + ".qld")
        case .core: return nil
        }
    }

    func size(_ form: Form, _ path: String) -> Int64 {
        guard let u = url(form, path), let n = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber else { return -1 }
        return n.int64Value
    }

    func read(_ form: Form, _ path: String, offset: UInt64, into buf: UnsafeMutableRawPointer, count: Int) -> Bool {
        guard let u = url(form, path) else { return false }
        let fd = open(u.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var done = 0
        while done < count {
            let n = pread(fd, buf + done, count - done, off_t(offset) + off_t(done))
            if n <= 0 { return false }
            done += n
        }
        return true
    }

    func write(_ form: Form, _ path: String, offset: UInt64, bytes: UnsafeRawPointer, count: Int) -> Bool {
        guard form == .device || form == .core, let final = url(form, path) else { return false }
        let part = final.appendingPathExtension("part")
        lock.lock()
        defer { lock.unlock() }
        if offset == 0 || writing?.url != part {
            closeWriting()
            let fm = FileManager.default
            do {
                try StorageProtection.makeFolder(part.deletingLastPathComponent())
            } catch {
                return false
            }
            if offset == 0 || !fm.fileExists(atPath: part.path) {
                try? fm.removeItem(at: part)
                guard fm.createFile(atPath: part.path, contents: nil, attributes: StorageProtection.attributes) else { return false }
            }
            guard let h = try? FileHandle(forWritingTo: part) else { return false }
            writing = (part, h)
        }
        guard let h = writing?.handle else { return false }
        do {
            try h.seek(toOffset: offset)
            try h.write(contentsOf: Data(bytes: bytes, count: count))
            return true
        } catch {
            closeWriting()
            return false
        }
    }

    /// The part file is whole: it replaces the file in one step (rename), never removed first.
    func commit(_ form: Form, _ path: String) -> Bool {
        guard form == .device || form == .core, let final = url(form, path) else { return false }
        let part = final.appendingPathExtension("part")
        lock.lock()
        if writing?.url == part {
            try? writing?.handle.synchronize()
            closeWriting()
        }
        lock.unlock()
        return rename(part.path, final.path) == 0
    }

    /// One file and its part, or (form device, no path) every device form of every build: a verified stop (SPEC
    /// 15.3) leaves nothing the Core wrote.
    func remove(_ form: Form, _ path: String?) -> Bool {
        lock.lock()
        closeWriting()
        lock.unlock()
        let fm = FileManager.default
        if let path {
            guard let u = url(form, path) else { return false }
            try? fm.removeItem(at: u)
            try? fm.removeItem(at: u.appendingPathExtension("part"))
            return true
        }
        guard form == .device else { return false }
        let models = root.appendingPathComponent("models")
        guard let e = fm.enumerator(at: models, includingPropertiesForKeys: nil) else { return true }
        var gone: [URL] = []
        for case let u as URL in e where u.path.hasSuffix(".qld") || u.path.hasSuffix(".qld.part") || u.path.hasSuffix(".qle")
            || u.path.hasSuffix(".qle.part") {
            gone.append(u)
        }
        var ok = true
        for u in gone where (try? fm.removeItem(at: u)) == nil { ok = false }
        return ok
    }

    func map(_ form: Form, _ path: String) -> (UnsafeRawPointer, Int)? {
        guard let u = url(form, path) else { return nil }
        let fd = open(u.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { return nil }
        let n = Int(st.st_size)
        guard let p = mmap(nil, n, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else { return nil }
        lock.lock()
        mappings[UInt(bitPattern: p)] = n
        lock.unlock()
        return (UnsafeRawPointer(p), n)
    }

    func unmap(_ p: UnsafeRawPointer, _ n: Int) {
        lock.lock()
        mappings[UInt(bitPattern: p)] = nil
        lock.unlock()
        munmap(UnsafeMutableRawPointer(mutating: p), n)
    }

    private func closeWriting() {
        try? writing?.handle.close()
        writing = nil
    }
}

/// The clocks the Core judges a lease by (18.4.7): the wall clock, and the boot clock with the boot's id.
protocol CoreClocks: Sendable {
    func wallMs() -> Int64
    /// Milliseconds since this boot, counting sleep (`mach_continuous_time`), and a 32-byte id of the boot. Core c3 reads
    /// the id (a changed id is a new boot to it); a Core of spec fix 17 reads only the milliseconds.
    func boot() -> (ms: Int64, id: [UInt8])
}

struct SystemClocks: CoreClocks {
    /// Where this install keeps the boot id it hands the Core between launches (`StickyBootID`); nil: the id derived in
    /// this process (tests).
    var bootIDFile: URL? = nil

    func wallMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

    func boot() -> (ms: Int64, id: [UInt8]) {
        let ms = Self.continuousMs()
        return (ms, bootIDFile.map { StickyBootID.process(file: $0, nowMs: ms) } ?? Self.bootID)
    }

    /// `mach_continuous_time` in milliseconds: the time since this boot, sleep counted.
    static func continuousMs() -> Int64 {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ns = Double(mach_continuous_time()) * Double(tb.numer) / Double(max(1, tb.denom))
        return Int64(ns / 1_000_000)
    }

    /// The boot session's UUID (`kern.bootsessionuuid`, new at every boot), else the boot time; hashed to 32 bytes. On
    /// iOS 18 the first is refused to apps and the second moves at every calendar correction, without a reboot: kept
    /// across launches by `StickyBootID`.
    static let bootID: [UInt8] = {
        var size = 0
        var text = ""
        if sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 { text = String(cString: buf) }
        }
        if text.isEmpty {
            var tv = timeval()
            var n = MemoryLayout<timeval>.size
            if sysctlbyname("kern.boottime", &tv, &n, nil, 0) == 0 { text = "boottime \(tv.tv_sec)" }
        }
        return Array(SHA256.hash(data: Data(("quranlab boot " + text).utf8)))
    }()
}

/// SDK 4.0.5 (spec fix 17, 11-25): the boot id handed to the Core stays the one the last launch handed it while the
/// boot clock has not gone back since. On iOS 18 `kern.bootsessionuuid` is refused, so the id came from
/// `kern.boottime`'s seconds, which move at every calendar correction; Core c3 took each change for a reboot and added
/// the whole uptime to its clock: a held lease expired and fresh leases came refused as expired. With the id kept, c3
/// sees a new boot only when the boot clock went back (a real reboot), and the first launch after the update keeps the
/// id c3 stored. A clock that already ran ahead stays ahead under c3 (it never moves its clock back); a Core of spec fix
/// 17 reads no boot id and is set back by the server's signed time at its next lease.
enum StickyBootID {
    struct Stored: Codable, Equatable, Sendable {
        /// The id, base64url of 32 bytes.
        var id: String
        /// The boot clock (`mach_continuous_time`, ms) when it was stored.
        var ms: Int64
    }

    /// The id for this process, and what to store: the stored id while the boot clock is not below its stored reading
    /// (the same boot by the counter), else `derive()`'s (a reboot, the first launch, or a stored pair that is not one).
    static func choose(stored: Stored?, nowMs: Int64, derive: () -> [UInt8]) -> (id: [UInt8], store: Stored) {
        if let s = stored, nowMs >= s.ms, let d = Data(base64URL: s.id), d.count == 32 {
            return ([UInt8](d), Stored(id: s.id, ms: nowMs))
        }
        let id = derive()
        return (id, Stored(id: Data(id).base64URL, ms: nowMs))
    }

    /// The ids chosen in this process, by file: one per process, so every call of the Core sees one id.
    private static let chosen = Locked<[String: [UInt8]]>([:])

    /// Once per process and file: the stored pair read, the id chosen, the pair stored again with this reading.
    static func process(file: URL, nowMs: Int64, derive: () -> [UInt8] = { SystemClocks.bootID }) -> [UInt8] {
        chosen.withLock { (m: inout [String: [UInt8]]) -> [UInt8] in
            if let id = m[file.path] { return id }
            let f = JSONFile<Stored>(url: file)
            let c = choose(stored: f.read().takingUnreadableAsMissing, nowMs: nowMs, derive: derive)
            f.write(c.store)
            m[file.path] = c.id
            return c.id
        }
    }

    /// Tests: forget the ids this process chose.
    static func reset() { chosen.withLock { $0 = [:] } }
}

/// `CoreStateKeeping` and the gate on one Core's saves (`CoreStateGate`) are in CoreStateGate.swift.

/// The state file in the storage folder, its key and counter in the Keychain (this device only, after first unlock).
struct KeychainCoreState: CoreStateKeeping {
    let file: URL
    var stateKey = KeychainItem(account: "quranlab.core.state-key")
    var counterItem = KeychainItem(account: "quranlab.core.counter")

    init(storage: URL) { file = storage.appendingPathComponent("core/state.bin") }

    func load() -> Data? { try? Data(contentsOf: file) }

    func save(_ blob: Data) {
        try? StorageProtection.makeFolder(file.deletingLastPathComponent())
        try? blob.write(to: file, options: StorageProtection.atomic)
    }

    var sealAvailable: Bool { key() != nil }

    private func key() -> SymmetricKey? {
        if let d = stateKey.read(), d.count == 32 { return SymmetricKey(data: d) }
        var b = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &b) == errSecSuccess, stateKey.write(Data(b)) else { return nil }
        return SymmetricKey(data: b)
    }

    func seal(_ secret: Data) -> Data? {
        guard let k = key() else { return nil }
        return (try? AES.GCM.seal(secret, using: k))?.combined
    }

    func open(_ sealed: Data) -> Data? {
        guard let k = key(), let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: k)
    }

    func counter() -> UInt64 {
        guard let d = counterItem.read(), d.count == 8 else { return 0 }
        return d.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }

    func raise(_ v: UInt64) -> Bool {
        guard v > counter() else { return true }
        return counterItem.write(Data((0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) }))
    }
}

/// One generic-password item of the SDK in the data protection Keychain, this device only.
struct KeychainItem: Sendable {
    let account: String
    var service = "quranlab.sdk"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true]
    }

    func read() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    func write(_ d: Data) -> Bool {
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: d] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = query
        add[kSecValueData as String] = d
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func delete() { SecItemDelete(query as CFDictionary) }
}

/// Everything the Core is handed, and the C table that points at it. The table and the SPKI bytes live as long as
/// this object; `CoreHost` keeps it.
final class CorePlatform: @unchecked Sendable {
    let storage: CoreStorage
    let key: any InstallKey
    let state: any CoreStateKeeping
    let clocks: any CoreClocks
    private(set) var table = qlc_platform()
    private let spki: UnsafeMutablePointer<UInt8>
    private let spkiCount: Int

    init(storage: CoreStorage, key: any InstallKey, state: any CoreStateKeeping, clocks: any CoreClocks = SystemClocks()) {
        self.storage = storage
        self.key = key
        self.state = state
        self.clocks = clocks
        let s = [UInt8](key.spki)
        spkiCount = s.count
        spki = .allocate(capacity: max(1, s.count))
        spki.initialize(from: s, count: s.count)
        table = Self.makeTable(spki: spki, count: s.count, hardware: key.hardware, sealed: state.sealAvailable)
        table.user = Unmanaged.passUnretained(self).toOpaque()
    }

    deinit { spki.deallocate() }

    // MARK: the C table

    private static func me(_ u: UnsafeMutableRawPointer?) -> CorePlatform? {
        guard let u else { return nil }
        return Unmanaged<CorePlatform>.fromOpaque(u).takeUnretainedValue()
    }

    private static func form(_ f: Int32) -> CoreStorage.Form? { CoreStorage.Form(rawValue: f) }

    private static func makeTable(spki: UnsafeMutablePointer<UInt8>, count: Int, hardware: Bool, sealed: Bool) -> qlc_platform {
        var t = qlc_platform()
        t.struct_size = UInt32(MemoryLayout<qlc_platform>.size)
        t.size = { u, f, p in
            guard let me = CorePlatform.me(u), let form = CorePlatform.form(f), let p else { return -1 }
            return me.storage.size(form, String(cString: p))
        }
        t.read = { u, f, p, off, buf, n in
            guard let me = CorePlatform.me(u), let form = CorePlatform.form(f), let p, let buf else { return -1 }
            return me.storage.read(form, String(cString: p), offset: off, into: buf, count: n) ? 0 : -1
        }
        t.write = { u, f, p, off, buf, n in
            guard let me = CorePlatform.me(u), let form = CorePlatform.form(f), let p, let buf else { return -1 }
            return me.storage.write(form, String(cString: p), offset: off, bytes: buf, count: n) ? 0 : -1
        }
        t.commit = { u, f, p in
            guard let me = CorePlatform.me(u), let form = CorePlatform.form(f), let p else { return -1 }
            return me.storage.commit(form, String(cString: p)) ? 0 : -1
        }
        t.remove = { u, f, p in
            guard let me = CorePlatform.me(u), let form = CorePlatform.form(f) else { return -1 }
            return me.storage.remove(form, p.map { String(cString: $0) }) ? 0 : -1
        }
        t.wall_ms = { u in CorePlatform.me(u)?.clocks.wallMs() ?? 0 }
        t.boot_ms = { u, id in
            guard let me = CorePlatform.me(u) else { return 0 }
            let b = me.clocks.boot()
            if let id { for i in 0..<32 { id[i] = i < b.id.count ? b.id[i] : 0 } }
            return b.ms
        }
        t.random = { _, buf, n in
            guard let buf else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, n, buf) == errSecSuccess ? 0 : -1
        }
        t.agree = { u, eph, n, z in
            guard let me = CorePlatform.me(u), let eph, let z, let shared = me.key.agree(Data(bytes: eph, count: n)), shared.count == 32 else { return -1 }
            shared.withUnsafeBytes { (b: UnsafeRawBufferPointer) in for i in 0..<32 { z[i] = b[i] } }
            return 0
        }
        t.decrypt_rsa = nil
        t.sign = { u, msg, n, sig, sigLen in
            guard let me = CorePlatform.me(u), let msg, let sig, let sigLen,
                  let s = me.key.sign(Data(bytes: msg, count: n)), s.count <= sigLen.pointee else { return -1 }
            s.withUnsafeBytes { (b: UnsafeRawBufferPointer) in for i in 0..<s.count { sig[i] = b[i] } }
            sigLen.pointee = s.count
            return 0
        }
        t.save_state = { u, blob, n in
            guard let me = CorePlatform.me(u), let blob else { return }
            me.state.save(Data(bytes: blob, count: n))
        }
        t.install_key_spki = UnsafePointer(spki)
        t.install_key_spki_len = count
        t.map = { u, f, p, data, len in
            guard let me = CorePlatform.me(u), let form = CorePlatform.form(f), let p, let data, let len,
                  let m = me.storage.map(form, String(cString: p)) else { return -1 }
            data.pointee = m.0
            len.pointee = m.1
            return 0
        }
        t.unmap = { u, p, n in
            guard let me = CorePlatform.me(u), let p else { return }
            me.storage.unmap(p, n)
        }
        // 16: a software key store (a Mac without a Secure Enclave, the Simulator). Reported, never acted on (18.6.4).
        t.signals = hardware ? 0 : 16
        // 18.4.7: the device-bound seal and counter only where the Keychain keeps them; else none, and the Core seals
        // under its release key (as the C SDK where a container has no machine id). Before, a refused Keychain made every
        // save fail: no state at all, a new lease at every start, and no open offline (the first Mac run, 11-18)
        guard sealed else { return t }
        t.state_seal = { u, input, n, out, outN in
            guard let me = CorePlatform.me(u), let input, let out, let outN,
                  let s = me.state.seal(Data(bytes: input, count: n)), s.count <= outN.pointee else { return -1 }
            s.withUnsafeBytes { (b: UnsafeRawBufferPointer) in for i in 0..<s.count { out[i] = b[i] } }
            outN.pointee = s.count
            return 0
        }
        t.state_open = { u, input, n, out, outN in
            guard let me = CorePlatform.me(u), let input, let out, let outN,
                  let s = me.state.open(Data(bytes: input, count: n)), s.count <= outN.pointee else { return -1 }
            s.withUnsafeBytes { (b: UnsafeRawBufferPointer) in for i in 0..<s.count { out[i] = b[i] } }
            outN.pointee = s.count
            return 0
        }
        t.counter_get = { u, v in
            guard let me = CorePlatform.me(u), let v else { return -1 }
            v.pointee = me.state.counter()
            return 0
        }
        t.counter_raise = { u, v in
            guard let me = CorePlatform.me(u) else { return -1 }
            return me.state.raise(v) ? 0 : -1
        }
        return t
    }
}
