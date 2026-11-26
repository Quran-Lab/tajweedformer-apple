import Foundation

// SDK 4.0.5: the allow-list rules of section 28 that need nothing but Foundation, apart from Endpoints.swift so the
// checks of ATTEST_40.md 40.5 (AnswerCheck) build and are tested on Linux too (scripts/linux_logic_tests.sh).
extension Endpoints {
    /// 28.1: Quran Lab's own domains. A host is Quran Lab's when it is one of them or ends with a dot and one of them.
    static let suffixes = ["quranlab.ai", "tajweedformer.com", "quran-lab.com"]
    /// ASCII lower case: only A to Z change (a name with another letter is not a host of the allow-list anyway).
    static func asciiLower(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { (65...90).contains($0.value) ? Unicode.Scalar($0.value + 32)! : $0 }))
    }

    /// 28.1, the allow-list: labels of a-z, 0-9 and `-` (1 to 63 characters, not starting or ending with `-`), at most
    /// 253 characters, one of `suffixes` or under one, compared in ASCII lower case. Never an IP literal, a port, user
    /// information, a trailing dot or a name that only contains one of the domains.
    static func hostAllowed(_ host: String) -> Bool {
        guard (1...253).contains(host.utf8.count) else { return false }
        let h = asciiLower(host)
        for label in h.split(separator: ".", omittingEmptySubsequences: false) {
            let bytes = Array(label.utf8)
            guard (1...63).contains(bytes.count), bytes.first != 45, bytes.last != 45,
                  bytes.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { return false }
        }
        return suffixes.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// 28.4: the host and path of a lease answer's `base`, or nil when it is no base: `https://<host><path>` with the
    /// host in the allow-list, the path starting and ending with `/`, printable ASCII, at most 511 characters, and no
    /// port, user information, query, fragment, backslash, space or `..`.
    static func baseParts(_ base: String) -> (host: String, path: String)? {
        let bytes = Array(base.utf8)
        guard (9...511).contains(bytes.count), base.hasPrefix("https://"), base.hasSuffix("/"),
              bytes.allSatisfy({ (0x21...0x7e).contains($0) }), !base.contains(".."),
              !base.contains(where: { "?#@\\".contains($0) }) else { return nil }
        let rest = base.dropFirst(8)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let host = String(rest[..<slash]), path = String(rest[slash...])
        guard !host.contains(":"), hostAllowed(host) else { return nil }
        return (asciiLower(host), path)
    }
}
