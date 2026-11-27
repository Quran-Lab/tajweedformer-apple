import CryptoKit
import Foundation

// SDK 4.0.5: the install certificate and the lease answer apart from LeaseProtocol.swift, with the checks of
// ATTEST_40.md 40.5 they fail (AnswerCheck), so they build and are tested on Linux too (scripts/linux_logic_tests.sh).

/// The install certificate: base64url of its text, a dot, base64url of the Ed25519 signature by
/// Quran Lab's signing key over the text. Issued by `POST /v1/attest`, carried again (renewed) by every lease answer.
/// The SDK keeps it, sends it back in every lease request, and reads `exp` (attest again when it is over) and `key`
/// (the API key id a signed refusal names).
struct InstallCertificate: Sendable, Equatable, Codable {
    let encoded: String
    let fields: [String: String]

    var app: String { fields["app"] ?? "" }
    var platform: String { fields["platform"] ?? "" }
    var key: String { fields["key"] ?? "" }
    var install: String { fields["install"] ?? "" }
    var sign: String { fields["sign"] ?? "" }
    var att: String { fields["att"] ?? "" }
    var hardware: Bool { fields["hw"] == "1" }
    var issuedAt: Int64 { Int64(fields["iat"] ?? "") ?? 0 }
    var expiresAt: Int64 { Int64(fields["exp"] ?? "") ?? 0 }
    var recheck: Bool { fields["recheck"] == "1" }

    /// The lines of the text, in order (18.4.3).
    static let lines = ["app", "platform", "key", "install", "sign", "att", "hw", "iat", "exp", "recheck", "batch", "digest"]

    /// A certificate whose text has the form of 18.4.3 and whose signature verifies with one of `trustedKeys`; nil
    /// otherwise.
    static func parse(_ encoded: String, trustedKeys: [Data]) -> InstallCertificate? {
        read(encoded, trustedKeys: trustedKeys).certificate
    }

    /// The certificate, or the first check of 40.5 it fails: its form (two base64url parts, a 64-byte signature, the
    /// 13 lines of 18.4.3), then its signature (`cert_format`, `cert_signature`). SDK 4.0.5: the form is read before the
    /// signature is verified (until 4.0.5 the lines were read after it; the same certificates pass).
    static func read(_ encoded: String, trustedKeys: [Data]) -> (certificate: InstallCertificate?, check: String?) {
        let parts = encoded.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let text = Data(base64URL: String(parts[0])), let sig = Data(base64URL: String(parts[1])), sig.count == 64,
              let s = String(data: text, encoding: .utf8), s.hasPrefix("quranlab-install-cert 1\n"), s.hasSuffix("\n") else {
            return (nil, AnswerCheck.certFormat)
        }
        var fields: [String: String] = [:]
        let body = s.dropFirst("quranlab-install-cert 1\n".count).dropLast().split(separator: "\n", omittingEmptySubsequences: false)
        guard body.count == lines.count else { return (nil, AnswerCheck.certFormat) }
        for (name, line) in zip(lines, body) {
            guard line.hasPrefix(name + " ") else { return (nil, AnswerCheck.certFormat) }
            fields[name] = String(line.dropFirst(name.count + 1))
        }
        let keys = trustedKeys.compactMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        guard keys.contains(where: { $0.isValidSignature(sig, for: text) }) else { return (nil, AnswerCheck.certSignature) }
        return (InstallCertificate(encoded: encoded, fields: fields), nil)
    }

    /// Whether the certificate is this install key's: its `install` is the key's hash.
    func isFor(installHash: String) -> Bool { install == installHash }

    /// The check a certificate given for the install key of `installHash` fails (40.5), nil when it is that key's.
    static func check(_ encoded: String, trustedKeys: [Data], installHash: String) -> String? {
        let r = read(encoded, trustedKeys: trustedKeys)
        guard let c = r.certificate else { return r.check }
        return c.isFor(installHash: installHash) ? nil : AnswerCheck.certInstall
    }
}

/// A lease answer (18.4.5).
struct LeaseAnswer: Sendable, Equatable {
    let lease: Data
    let issuedAt: Int64
    let expiresAt: Int64
    let refreshAfter: Int64
    /// The model folder the build's files are under (`<base>manifest.json`, `<base>layers.zfw.qle`).
    let base: URL?
    let certificate: String?
    /// An optional data piece for the Core (spec fix 12): data, never code.
    let piece: Data?
    /// The server's signed time (spec fix 17, 18.4.7.3), for a Core that reads it (`CoreHost.leaseTime`); nil from a
    /// server before it.
    var time: String? = nil

    static func parse(_ body: Data) -> LeaseAnswer? { read(body).answer }

    /// The answer, and the first check of 40.5 it fails before the Core sees its lease, in the contract's order: JSON,
    /// `v`, `lease`, `iat`, `exp`, `refresh_after`, `base`. The answer is given back whenever its lease and times read (a
    /// `base` that is not one leaves it nil, as before 4.0.5, and is the check `schema:base`); `base_host` is the
    /// caller's (`ProtectedRuntime.acceptedBase`, which also takes a test's staging host).
    static func read(_ body: Data) -> (answer: LeaseAnswer?, check: String?) {
        guard let any = AnswerCheck.json(body) else { return (nil, AnswerCheck.notJSON) }
        guard let o = any as? [String: Any], (o["v"] as? Int) == 1 else { return (nil, AnswerCheck.leaseV) }
        // SDK 4.0.5: base64url's own alphabet only (a padded or standard base64 string decoded before)
        guard let l = o["lease"] as? String, l.utf8.allSatisfy({ Self.base64URLByte($0) }), let lease = Data(base64URL: l),
              !lease.isEmpty, lease.count <= 4096 else { return (nil, AnswerCheck.leaseBytes) }
        guard let iat = whole(o["iat"]) else { return (nil, AnswerCheck.leaseIat) }
        guard let exp = whole(o["exp"]) else { return (nil, AnswerCheck.leaseExp) }
        guard let ra = whole(o["refresh_after"]) else { return (nil, AnswerCheck.leaseRefresh) }
        var base: URL?
        // 28.4 (4.0.1): the base as the answer wrote it is held to printable ASCII without a backslash before it is
        // made a URL (Foundation's URL(string:) percent-encodes a space or a backslash it would otherwise refuse, and
        // the encoded form would pass `ProtectedRuntime.acceptedBase`)
        if let b = o["base"] as? String, b.utf8.allSatisfy({ (0x21...0x7e).contains($0) && $0 != 0x5c }),
           let u = URL(string: b), u.scheme == "https", let host = u.host, !host.isEmpty, b.hasSuffix("/") { base = u }
        let piece = (o["piece"] as? String).flatMap { Data(base64URL: $0) }
        let answer = LeaseAnswer(lease: lease, issuedAt: iat, expiresAt: exp, refreshAfter: ra, base: base,
                                 certificate: o["install_cert"] as? String, piece: piece, time: o["time"] as? String)
        return (answer, base == nil ? AnswerCheck.leaseBase : nil)
    }

    /// The first check of 40.5 the answer fails, `base_host` included (the allow-list of 28.4 alone, no staging host).
    static func check(_ body: Data) -> String? {
        let r = read(body)
        if let c = r.check { return c }
        guard let b = r.answer?.base, Endpoints.baseParts(b.absoluteString) != nil else { return AnswerCheck.baseHost }
        return nil
    }

    /// An integer of the answer: a JSON number with no fraction (SDK 4.0.5: 1795080000.5 is no time).
    private static func whole(_ v: Any?) -> Int64? {
        guard let n = v as? NSNumber, let i = Int64(exactly: n.doubleValue), Double(i) == n.doubleValue else { return nil }
        return n.int64Value == i ? i : nil
    }

    private static func base64URLByte(_ b: UInt8) -> Bool {
        (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b) || b == 45 || b == 95
    }
}
