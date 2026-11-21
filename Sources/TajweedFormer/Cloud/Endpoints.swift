import Foundation

/// The kinds of Quran Lab host (SDK 4.0.1, contract section 28, `sdk_4.0.0/ENDPOINTS_40.md` 28.1). Each is an ordered
/// set of hosts that serve the same paths and the same answers; a request that cannot reach one host goes to the next.
enum EndpointRole: String, Sendable, CaseIterable {
    /// qlab-api: every request of PLATFORM_CLIENT and the 4.0 routes of 18.4.
    case api
    /// The model files: a build's `manifest.json`, its files and their ranges (15.4).
    case models
    /// The web SDK's frame and loader. Never asked by this SDK; named so a report can say it (28.7).
    case webFrame = "web_frame"
}

/// The rules of section 28 that hold no state, ported from its reference `tools/endpoints40.py` and replayed on
/// `vectors/endpoints_40.json` (`EndpointsVectorTests`).
enum Endpoints {
    /// 28.1: the hosts built into every SDK, per role, in order.
    static let builtIn: [EndpointRole: [String]] = [
        .api: ["api.quranlab.ai", "api-b.tajweedformer.com", "api-g.tajweedformer.com", "api-a.tajweedformer.com"],
        .models: ["cdn.quranlab.ai", "cdn-b.tajweedformer.com", "cdn-g.tajweedformer.com", "cdn-a.tajweedformer.com"],
        .webFrame: ["web.quranlab.ai", "web2.quranlab.ai", "web-b.tajweedformer.com", "web-g.tajweedformer.com",
                    "web-a.tajweedformer.com"],
    ]
    /// The roles a signed config may change (28.2): never `web_frame`.
    static let configRoles: [EndpointRole] = [.api, .models]
    /// 28.1: Quran Lab's own domains. A host is Quran Lab's when it is one of them or ends with a dot and one of them.
    static let suffixes = ["quranlab.ai", "tajweedformer.com", "quran-lab.com"]
    /// 28.2: a config's list of more entries than this, for a role, is refused whole.
    static let maxConfigHosts = 8
    /// 28.3 item 1: after the sticky host became preferred, the first host is asked first again (the probe back).
    static let probeAfter: TimeInterval = 1800
    /// 28.3 item 6: URLSession bounds no connect alone, so a host has 10 seconds without a byte before the answer's
    /// status; after that the limits of before hold (the session's 30 seconds of silence).
    static let silenceLimit: TimeInterval = 10

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

    /// 28.2: a role's hosts while a config is in force (`inForce`): the config's `endpoints` list for the role, each
    /// entry a host of the allow-list (others, and repeats after the first, dropped; it may reorder, disable and add
    /// hosts), else `builtIn`. More than `maxConfigHosts` entries, something that is not an array, or nothing left is
    /// `builtIn`; `web_frame` never comes from a config.
    static func roleList(_ role: EndpointRole, endpoints: JSONValue?, inForce: Bool, builtIn: [String]) -> [String] {
        guard inForce, configRoles.contains(role), let entries = endpoints?.object?[role.rawValue]?.array,
              entries.count <= maxConfigHosts else { return builtIn }
        var out: [String] = []
        for e in entries {
            guard let s = e.string, hostAllowed(s) else { continue }
            let h = asciiLower(s)
            if !out.contains(h) { out.append(h) }
        }
        return out.isEmpty ? builtIn : out
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

    /// `https://<host>`: where a host of a role is asked (every host over https on port 443, 28.2).
    static func origin(_ host: String) -> URL {
        #if DEBUG
        // debug builds only (StagingHooks): a test's loopback server for the name
        if let mapped = StagingHooks.hostOrigins.withLock({ $0[asciiLower(host)] }) { return mapped }
        #endif
        return URL(string: "https://" + host)!
    }

    /// The scheme, host and port of `url`, as an origin to compare and to put another host in.
    static func origin(of url: URL) -> URL? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = c.scheme, let host = c.host else { return nil }
        #if DEBUG
        // debug builds only (StagingHooks): a URL on a host name a test stands a loopback server in for (a lease's base)
        if let mapped = StagingHooks.hostOrigins.withLock({ $0[asciiLower(host)] }) { return mapped }
        #endif
        var o = URLComponents()
        o.scheme = scheme.lowercased()
        o.host = asciiLower(host)
        o.port = c.port
        return o.url
    }

    /// `url` asked of `origin` instead: the same path, query and everything else, another scheme, host and port.
    static func rehost(_ url: URL, to origin: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let o = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return url }
        c.scheme = o.scheme
        c.host = o.host
        c.port = o.port
        return c.url ?? url
    }
}
