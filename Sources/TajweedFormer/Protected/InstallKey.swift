import CryptoKit
import Foundation

/// The install's key: one P-256 key that agrees (ECDH: a lease is wrapped for it) and signs
/// (`install_sig`, the lease request's signature). In the Secure Enclave where the device has one; a software key in
/// this device's Keychain where it has none (a Mac without a Secure Enclave, the Simulator), reported as `hw 0` and
/// as the Core's risk signal 16. The private key never leaves the key store: the Core gets one lease's shared secret
/// and signatures, never the key.
protocol InstallKey: Sendable {
    /// The public key as SubjectPublicKeyInfo DER (91 bytes).
    var spki: Data { get }
    /// Whether the key is in hardware (the Secure Enclave): the certificate's `hw`.
    var hardware: Bool { get }
    /// The x coordinate of ECDH with a peer's uncompressed point (65 bytes): 32 bytes, or nil.
    func agree(_ peer: Data) -> Data?
    /// ECDSA P-256 with SHA-256 over the message, DER (at most 72 bytes), or nil.
    func sign(_ message: Data) -> Data?
}

extension InstallKey {
    /// SHA-256 of the SPKI, 64 lower-case hex: the install hash every certificate and lease names.
    var installHash: String { Data(SHA256.hash(data: spki)).hex }

    /// `install_sig` of `POST /v1/attest` (18.4.3, `install_cert.json` attest_proof): base64url of the signature over
    /// "quranlab-attest 1\n" <challenge, or "-" without one> "\n" <install hash> "\n".
    func attestProof(challenge: String?) -> String? {
        sign(Self.attestText(challenge: challenge, installHash: installHash))?.base64URL
    }

    static func attestText(challenge: String?, installHash: String) -> Data {
        Data("quranlab-attest 1\n\(challenge ?? "-")\n\(installHash)\n".utf8)
    }
}

enum P256SPKI {
    /// The DER prefix of a P-256 SubjectPublicKeyInfo before the 65-byte uncompressed point.
    static let prefix = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
                              0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00])

    static func wrap(_ point: Data) -> Data? { point.count == 65 && point.first == 0x04 ? prefix + point : nil }
}

/// A key of the Security framework: the Secure Enclave's, or a Keychain software key.
struct SecInstallKey: InstallKey, @unchecked Sendable {
    let privateKey: SecKey
    let spki: Data
    let hardware: Bool
    /// The Keychain application tag the key is kept under.
    let tag: String

    init?(privateKey: SecKey, hardware: Bool, tag: String) {
        guard let pub = SecKeyCopyPublicKey(privateKey), let point = SecKeyCopyExternalRepresentation(pub, nil) as Data?,
              let spki = P256SPKI.wrap(point) else { return nil }
        self.privateKey = privateKey
        self.spki = spki
        self.hardware = hardware
        self.tag = tag
    }

    func agree(_ peer: Data) -> Data? {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits as String: 256]
        guard let pub = SecKeyCreateWithData(peer as CFData, attrs as CFDictionary, nil) else { return nil }
        // the standard ECDH without parameters is the raw shared secret: the x coordinate of the shared point
        let z = SecKeyCopyKeyExchangeResult(privateKey, .ecdhKeyExchangeStandard, pub, [:] as CFDictionary, nil) as Data?
        return z?.count == 32 ? z : nil
    }

    func sign(_ message: Data) -> Data? {
        SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, message as CFData, nil) as Data?
    }
}

/// A key held by CryptoKit in memory: the contract vectors' test keys, and processes the Keychain refuses (a
/// command-line tool, `swift test` without an entitlement), which keep it in a file of the storage folder (`hw 0`).
struct SoftwareInstallKey: InstallKey {
    let agreement: P256.KeyAgreement.PrivateKey
    var hardware: Bool { false }
    var spki: Data { agreement.publicKey.derRepresentation }

    init(_ key: P256.KeyAgreement.PrivateKey) { agreement = key }

    /// A PKCS #8 or SEC 1 DER private key (the vectors' `pkcs8_b64u`).
    init?(der: Data) {
        guard let k = try? P256.KeyAgreement.PrivateKey(derRepresentation: der) else { return nil }
        agreement = k
    }

    func agree(_ peer: Data) -> Data? {
        guard let pub = try? P256.KeyAgreement.PublicKey(x963Representation: peer),
              let s = try? agreement.sharedSecretFromKeyAgreement(with: pub) else { return nil }
        return s.withUnsafeBytes { Data($0) }
    }

    func sign(_ message: Data) -> Data? {
        guard let k = try? P256.Signing.PrivateKey(rawRepresentation: agreement.rawRepresentation) else { return nil }
        return (try? k.signature(for: message))?.derRepresentation
    }
}

/// The install's keys over time: the current one, and at every attest a NEW one (18.4.3: a new agreement key at every
/// attest), which becomes current only when the server accepted it; a new key the server refused is deleted and the
/// old one kept. Keys are numbered by generation; the current generation and whether it is in hardware are a Keychain
/// item of their own.
final class InstallKeyring: @unchecked Sendable {
    private let record = KeychainItem(account: "quranlab.install.generation")
    /// Where a process the Keychain refuses keeps its software key (mode 0600).
    private let fallbackFolder: URL
    private let lock = NSLock()

    init(storage: URL) { fallbackFolder = storage.appendingPathComponent("core") }

    static func tag(_ generation: Int) -> String { "ai.quranlab.install.\(generation)" }

    private struct Current: Codable {
        var generation: Int
        var hardware: Bool
        var inFile: Bool
    }

    private func readCurrent() -> Current? {
        if let d = record.read() { return try? JSONDecoder().decode(Current.self, from: d) }
        if let d = try? Data(contentsOf: fallbackFolder.appendingPathComponent("install-generation.json")) {
            return try? JSONDecoder().decode(Current.self, from: d)
        }
        return nil
    }

    private func writeCurrent(_ c: Current) {
        guard let d = try? JSONEncoder().encode(c) else { return }
        if !record.write(d) {
            try? StorageProtection.makeFolder(fallbackFolder)
            try? d.write(to: fallbackFolder.appendingPathComponent("install-generation.json"), options: StorageProtection.atomic)
        }
    }

    /// The current key, when the install has one.
    func current() -> (any InstallKey)? {
        lock.lock()
        defer { lock.unlock() }
        guard let c = readCurrent() else { return nil }
        return load(c.generation, hardware: c.hardware, inFile: c.inFile)
    }

    /// The generation of the current key (0 without one).
    var generation: Int { lock.lock(); defer { lock.unlock() }; return readCurrent()?.generation ?? 0 }

    /// A new key, not current yet: in the Secure Enclave where possible, else a Keychain software key, else (a process
    /// the Keychain refuses) a key in a file of the storage folder.
    func makeNext() -> (key: any InstallKey, generation: Int)? {
        lock.lock()
        defer { lock.unlock() }
        let next = (readCurrent()?.generation ?? 0) + 1
        let tag = Self.tag(next)
        deleteKey(tag)
        #if !targetEnvironment(simulator)
        if let k = create(tag: tag, enclave: true) { return (k, next) }
        #endif
        if let k = create(tag: tag, enclave: false) { return (k, next) }
        let soft = P256.KeyAgreement.PrivateKey()
        try? StorageProtection.makeFolder(fallbackFolder)
        let f = fallbackFolder.appendingPathComponent("install-key-\(next).der")
        guard (try? soft.derRepresentation.write(to: f, options: StorageProtection.atomic)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
        return (SoftwareInstallKey(soft), next)
    }

    /// The server accepted the new key: it is current, and every older key is deleted.
    func promote(_ key: any InstallKey, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        let old = readCurrent()
        let inFile = (key as? SoftwareInstallKey) != nil
        writeCurrent(Current(generation: generation, hardware: key.hardware, inFile: inFile))
        if let old, old.generation != generation {
            deleteKey(Self.tag(old.generation))
            try? FileManager.default.removeItem(at: fallbackFolder.appendingPathComponent("install-key-\(old.generation).der"))
        }
    }

    /// The server refused the new key: it goes, the current one stays.
    func discard(generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard readCurrent()?.generation != generation else { return }
        deleteKey(Self.tag(generation))
        try? FileManager.default.removeItem(at: fallbackFolder.appendingPathComponent("install-key-\(generation).der"))
    }

    private func load(_ generation: Int, hardware: Bool, inFile: Bool) -> (any InstallKey)? {
        if inFile {
            guard let d = try? Data(contentsOf: fallbackFolder.appendingPathComponent("install-key-\(generation).der")) else { return nil }
            return SoftwareInstallKey(der: d)
        }
        let tag = Self.tag(generation)
        var q = keyQuery(tag)
        q[kSecReturnRef as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let ref = out, CFGetTypeID(ref) == SecKeyGetTypeID() else { return nil }
        return SecInstallKey(privateKey: ref as! SecKey, hardware: hardware, tag: tag)
    }

    private func keyQuery(_ tag: String) -> [String: Any] {
        [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: Data(tag.utf8),
         kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecUseDataProtectionKeychain as String: true]
    }

    private func deleteKey(_ tag: String) { SecItemDelete(keyQuery(tag) as CFDictionary) }

    private func create(tag: String, enclave: Bool) -> (any InstallKey)? {
        var priv: [String: Any] = [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: Data(tag.utf8)]
        var attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256,
                                    kSecUseDataProtectionKeychain as String: true]
        if enclave {
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil) else {
                return nil
            }
            priv[kSecAttrAccessControl as String] = access
            attrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        } else {
            priv[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            priv[kSecAttrIsExtractable as String] = false
        }
        attrs[kSecPrivateKeyAttrs as String] = priv
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, nil) else { return nil }
        return SecInstallKey(privateKey: key, hardware: enclave, tag: tag)
    }
}
