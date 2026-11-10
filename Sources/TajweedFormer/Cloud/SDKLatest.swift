import Foundation
import os

/// `sdk_latest` in the signed config (`{"version", "severity", "url"}`, optional): when the running SDK is older, a
/// debug build of the app logs it once per launch, so the developer sees there is a newer SDK. Release builds say
/// nothing. A missing or malformed field is ignored without an error; a version that is not dotted numbers is never
/// newer.
enum SDKLatest {
    struct Notice: Equatable, Sendable {
        let version: String
        let severity: String
        let url: String
    }

    /// The field of a config body, when it is well formed.
    static func parse(_ body: Data) -> Notice? {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let l = o["sdk_latest"] as? [String: Any],
              let v = l["version"] as? String, let s = l["severity"] as? String, let u = l["url"] as? String,
              numbers(v) != nil, !s.isEmpty, s.count <= 32, !u.isEmpty, u.count <= 512 else { return nil }
        return Notice(version: v, severity: s, url: u)
    }

    /// "2.0.1" as [2, 0, 1]; nil unless every part is 1 to 9 ASCII digits.
    static func numbers(_ v: String) -> [Int]? {
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 8 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard (1...9).contains(p.count), p.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }

    /// Whether `a` is a later version than `b` (missing parts count as 0); false when either is not dotted numbers.
    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = numbers(a), let y = numbers(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    static let logged = Locked(false)
    /// Where the line goes (os.Logger at notice level; a test seam).
    static let sink = Locked<@Sendable (String) -> Void>({ line in
        Logger(subsystem: "ai.quranlab.sdk", category: "update").notice("\(line, privacy: .public)")
    })

    /// A debug build's log line (os.Logger, notice); nothing in release builds.
    static func debugOnly(_ line: String) {
        #if DEBUG
        Logger(subsystem: "ai.quranlab.sdk", category: "config").notice("\(line, privacy: .public)")
        #endif
    }

    /// Called with every verified config body: the line once per launch, debug builds only.
    static func note(body: Data, running: String = SDKInfo.version) {
        #if DEBUG
        guard let n = parse(body), isNewer(n.version, than: running) else { return }
        let first = logged.withLock { (done: inout Bool) -> Bool in
            if done { return false }
            done = true
            return true
        }
        guard first else { return }
        let line = "Quran Lab SDK \(n.version) is available (\(n.severity)), you have \(running): \(n.url)"
        sink.withLock { $0 }(line)
        #endif
    }
}
