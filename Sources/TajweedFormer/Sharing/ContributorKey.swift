import CryptoKit
import Foundation
import Security

/// The learner's deletion credential (the platform's deletion design): a P-256 key made on this device at the
/// first shared session, in the Secure Enclave where the device has one (else the Keychain, else, for a process
/// without Keychain access, a file in the SDK's storage), and a recovery code. The public key is bound to the
/// contributor code by the server on first sight; only a signature by this key (or the recovery code, on Quran Lab's
/// web page) deletes what the learner shared. The SDK never hands the private key or the recovery code to the app:
/// the code is shown to the learner by the SDK's own sharing settings view.
enum ContributorKey {
    static let service = "quranlab.sdk"
    static let keyAccount = "contributor-key"
    static let codeAccount = "contributor-recovery"

    enum Key {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)

        var publicKey: P256.Signing.PublicKey {
            switch self {
            case .enclave(let k): return k.publicKey
            case .software(let k): return k.publicKey
            }
        }

        /// ECDSA P-256 with SHA-256 over the bytes; r||s (64 bytes).
        func sign(_ message: Data) throws -> Data {
            switch self {
            case .enclave(let k): return try k.signature(for: message).rawRepresentation
            case .software(let k): return try k.signature(for: message).rawRepresentation
            }
        }

        /// What the session start sends: base64url (no padding) of the 65-byte point 04 || X || Y.
        var contributorKey: String { publicKey.x963Representation.base64URL }
    }

    // MARK: storage (Keychain, this device only; a file when the process has no Keychain)

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true]
    }

    private static func file(_ storage: URL, _ account: String) -> URL { storage.appendingPathComponent("cloud/\(account)") }

    static func read(_ account: String, storage: URL) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return d }
        return try? Data(contentsOf: file(storage, account))
    }

    static func write(_ account: String, _ data: Data, storage: URL) {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false
        if SecItemAdd(q as CFDictionary, nil) == errSecSuccess { return }
        let f = file(storage, account)
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
    }

    static func delete(_ account: String, storage: URL) {
        SecItemDelete(query(account) as CFDictionary)
        try? FileManager.default.removeItem(at: file(storage, account))
    }

    /// The key, made on first use. Stored form: 1 byte kind (1 = Secure Enclave blob, 2 = software raw) then the bytes.
    static func key(storage: URL) -> Key? {
        if let d = read(keyAccount, storage: storage), let kind = d.first {
            let body = d.dropFirst()
            if kind == 1, SecureEnclave.isAvailable, let k = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: Data(body)) {
                return .enclave(k)
            }
            if kind == 2, let k = try? P256.Signing.PrivateKey(rawRepresentation: Data(body)) { return .software(k) }
        }
        if SecureEnclave.isAvailable, let k = try? SecureEnclave.P256.Signing.PrivateKey() {
            write(keyAccount, Data([1]) + k.dataRepresentation, storage: storage)
            return .enclave(k)
        }
        let k = P256.Signing.PrivateKey()
        write(keyAccount, Data([2]) + k.rawRepresentation, storage: storage)
        return .software(k)
    }

    /// The recovery code, made with the key.
    static func recoveryCode(storage: URL) -> String {
        if let d = read(codeAccount, storage: storage), let s = String(data: d, encoding: .utf8), RecoveryCode.normalise(s) != nil { return s }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let code = RecoveryCode.encode(bytes)
        write(codeAccount, Data(code.utf8), storage: storage)
        return code
    }

    /// Forgets the key and the code (after a deletion, a revocation or a key mismatch: the next share makes new ones).
    static func reset(storage: URL) {
        delete(keyAccount, storage: storage)
        delete(codeAccount, storage: storage)
    }

    /// The deletion message (byte exact, LF line ends, final LF).
    static func deletionMessage(app: String, contributor: String, nonce: String, timestamp: Int) -> Data {
        Data("quranlab-contribution-delete 1\napp \(app)\ncontributor \(contributor)\nnonce \(nonce)\ntimestamp \(timestamp)\naction delete-all\n".utf8)
    }
}

/// Recovery codes: 16 random bytes as 26 Crockford base32 characters (most significant bit first; the last character
/// carries 3 bits and two zero bits), in groups of 4 joined by "-". Only the hash of the normalised code leaves the
/// device.
enum RecoveryCode {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func encode(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == 16)
        var bits = 0, acc = 0
        var chars: [Character] = []
        for b in bytes {
            acc = (acc << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                chars.append(alphabet[(acc >> (bits - 5)) & 31])
                bits -= 5
            }
            acc &= (1 << bits) - 1
        }
        if bits > 0 { chars.append(alphabet[(acc << (5 - bits)) & 31]) }
        var out = ""
        for (i, c) in chars.enumerated() {
            if i > 0 && i % 4 == 0 { out.append("-") }
            out.append(c)
        }
        return out
    }

    /// Upper case, spaces and "-" removed, O read as 0, I and L as 1; nil unless 26 characters of the alphabet.
    static func normalise(_ typed: String) -> String? {
        var out = ""
        for c in typed.uppercased() where c != " " && c != "-" {
            switch c {
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default:
                guard alphabet.contains(c) else { return nil }
                out.append(c)
            }
        }
        return out.count == 26 ? out : nil
    }

    /// Lower-case hex SHA-256 of the normalised code (ASCII).
    static func hash(_ code: String) -> String? {
        guard let n = normalise(code) else { return nil }
        return SHA256.hash(data: Data(n.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
