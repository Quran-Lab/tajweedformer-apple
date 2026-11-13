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

    private static func file(_ storage: URL, _ account: String) -> URL { storage.appendingPathComponent("cloud/\(account)") }

    // 3.1.4: a key or a code that is there and cannot be read is not "none". No new one is made then and the stored
    // one is neither replaced nor deleted (`storedKey`, `storedCode`, and `key` and `recoveryCode`, which make one
    // only when the device has none). Until 3.1.3 a key that could not be read was deleted and replaced by a new
    // one, and a deletion signed with the new key was answered 202 by the server and deleted nothing.

    /// One of the two items as the device has it, in three results: read, never made.
    static func stored(_ account: String, storage: URL) -> StoredRead<Data> {
        ContributorKeychain.item(account, file: file(storage, account))
    }

    static func delete(_ account: String, storage: URL) {
        ContributorKeychain.delete(account)
        try? FileManager.default.removeItem(at: file(storage, account))
    }

    /// The device key as the device has it, in three results: read, never made. Stored form: 1 byte kind (1 =
    /// Secure Enclave blob, 2 = software raw) then the bytes. Bytes that are not a key, and a Secure Enclave key
    /// that the enclave does not give now, are there and cannot be read.
    static func storedKey(storage: URL) -> StoredRead<Key> {
        switch stored(keyAccount, storage: storage) {
        case .missing: return .missing
        case .unreadable(let why): return .unreadable(why)
        case .value(let d):
            guard let kind = d.first else { return .unreadable(.damaged("an empty device key")) }
            let body = Data(d.dropFirst())
            if kind == 1 {
                guard SecureEnclave.isAvailable, let k = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body) else {
                    return .unreadable(.refused("the Secure Enclave did not give the device key"))
                }
                return .value(.enclave(k))
            }
            if kind == 2, let k = try? P256.Signing.PrivateKey(rawRepresentation: body) { return .value(.software(k)) }
            return .unreadable(.damaged("not a device key"))
        }
    }

    /// The key, made now when the device has none (the first share). Nil while the one it has cannot be read: none
    /// is made then, and the stored one stays.
    static func key(storage: URL) -> Key? {
        switch storedKey(storage: storage) {
        case .value(let k): return k
        case .unreadable: return nil
        case .missing:
            let made: Key
            let bytes: Data
            if SecureEnclave.isAvailable, let k = try? SecureEnclave.P256.Signing.PrivateKey() {
                made = .enclave(k)
                bytes = Data([1]) + k.dataRepresentation
            } else {
                let k = P256.Signing.PrivateKey()
                made = .software(k)
                bytes = Data([2]) + k.rawRepresentation
            }
            ContributorKeychain.keep(keyAccount, bytes, file: file(storage, keyAccount))
            // the key the device has now (another caller may have kept one a moment before)
            if case .value(let kept) = storedKey(storage: storage) { return kept }
            return made
        }
    }

    /// The recovery code as the device has it, in three results: read, never made. An item that is not a recovery
    /// code is there and cannot be read.
    static func storedCode(storage: URL) -> StoredRead<String> {
        switch stored(codeAccount, storage: storage) {
        case .missing: return .missing
        case .unreadable(let why): return .unreadable(why)
        case .value(let d):
            guard let s = String(data: d, encoding: .utf8), RecoveryCode.normalise(s) != nil else {
                return .unreadable(.damaged("not a recovery code"))
            }
            return .value(s)
        }
    }

    /// The recovery code, made with the key when the device has none. Nil while the one it has cannot be read.
    static func recoveryCode(storage: URL) -> String? {
        switch storedCode(storage: storage) {
        case .value(let s): return s
        case .unreadable: return nil
        case .missing:
            var bytes = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            let code = RecoveryCode.encode(bytes)
            ContributorKeychain.keep(codeAccount, Data(code.utf8), file: file(storage, codeAccount))
            if case .value(let kept) = storedCode(storage: storage) { return kept }
            return code
        }
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
