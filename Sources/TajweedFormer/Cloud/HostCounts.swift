import Foundation

/// SDK 4.0.2, STEERING_40 34.6 (contracts 9585201, 0d9f5d7 and ec46782, the download-speed measurement): what one
/// model request to a `models` host did, as `HTTPClient.stream` (a file) or `routed` (the manifest) measured it. An
/// entry exists for every host asked that day, one that only failed too; a cut transfer of 256 KiB or more counts its
/// rate over what arrived; kB is 1000 bytes. Counted per host and UTC day with the telemetry day
/// (`HostCount`); nothing of a learner, no path and no address.
struct ModelHostSample: Sendable, Hashable {
    /// The host the request went to (counted only when it is one of the allow-list, 28.1).
    var host: String
    /// The time from sent to status, in milliseconds; nil when no status came (no answer).
    var ttfbMs: Int?
    /// The body's bytes that arrived.
    var bytes: Int64
    /// The seconds from the status to the body's end.
    var bodySeconds: Double
    /// The request ended unreachable (28.3 item 3: no answer, a 5xx, a cut, a stall, a redirect, an answer that said
    /// success and was not the file, a 4xx that is not the API's).
    var unreachable: Bool
    /// The file's last byte came with this request.
    var lastByte: Bool
    /// SDK 4.0.5 (34.4): the request had no status 1.5 s after it was sent, so a second request of it went out.
    var hedged = false
    /// SDK 4.0.5 (STEERING_40 34.9.1): why the request failed, one of `FailClass.keys`; nil when it did not fail, or ended
    /// in no class (a cancel, a cut of section 35, a write of the device, a hold that sent nothing).
    var fail: String? = nil
    /// The HTTP version of a request that got a status (`h1`, `h2`, `h3`); nil without one, or when the system named none.
    var proto: String? = nil
}

/// SDK 4.0.5 (STEERING_40 34.9.1, the 4.0.4 erratum): why a model request failed, by the first row of the contract's
/// table that fits, and the HTTP version of one that got a status.
enum FailClass {
    /// The classes in the server's order (dlh3's doubles: only ever appended).
    static let keys = ["offline", "dns", "connect", "tls", "timeout", "no_answer", "http_3xx", "http_403", "http_404", "http_429",
                       "http_4xx", "http_503", "http_5xx", "cut", "bad_body"]
    static let protos = ["h1", "h2", "h3"]
    /// STEERING_40 34.9.7: why a model request moved to another host: a class, `slow` (34.5's cut) or `hedge` (34.4).
    static let moveWhy = keys + ["slow", "hedge"]
    /// 34.9.7: the closed keys of `outcome`.
    static let outcomeKeys = ["moved", "failed", "cancelled", "paused", "ready", "not_ready"]

    /// The class of a model request's failure as the installer sees it (no status in hand): a refusal or a 5xx by its
    /// status, an answer that was not the file `bad_body`, no answer by the system's code. Nil for no class.
    static func ofFailure(_ e: CloudError) -> String? {
        switch e {
        case .rejected(let s, _, let m, _):
            if m.hasPrefix(RetryAfterHolds.heldMessage) { return nil }
            return of(e, status: s, cancelled: false)
        case .badAnswer: return "bad_body"
        case .offline(let m):
            if m == HTTPClient.heldNotAsked || m == HTTPClient.hedgeLost { return nil }
            if let s = ErrorCause.status(after: "HTTP ", in: m) { return of(e, status: s, cancelled: false) }
            return of(e, status: nil, cancelled: false)
        default: return of(e, status: nil, cancelled: false)
        }
    }

    /// The class of a request that ended with `failure` (nil: it was taken), `status` when its answer had one. Nil for a
    /// request in no class (34.9.1 item 2): cancelled (the call, the app, a hedge's loser), a write of the device, a hold
    /// of 28.11 (nothing was sent).
    static func of(_ failure: CloudError?, status: Int?, cancelled: Bool) -> String? {
        guard let failure, !cancelled else { return nil }
        switch failure {
        case .storage, .noKey: return nil
        case .offline(let m) where m == HTTPClient.heldNotAsked || m == HTTPClient.hedgeLost: return nil
        case .rejected(_, _, let m, _) where m.hasPrefix(RetryAfterHolds.heldMessage): return nil
        default: break
        }
        if let s = status {
            switch s {
            case 100..<200, 300..<400: return "http_3xx"
            case 403: return "http_403"
            case 404: return "http_404"
            case 429: return "http_429"
            case 400..<500: return "http_4xx"
            case 503: return "http_503"
            case 500..<600: return "http_5xx"
            default:
                // a 2xx: its body ended before its length (a connection that broke, 16.2's silence), or it was not
                // what was asked
                if case .offline = failure { return "cut" }
                return "bad_body"
            }
        }
        // no status: the system's code (ErrorCause.noAnswer's marker), our own silence limit (28.3 item 6)
        switch failure {
        case .rejected(let s, _, _, _): return of(failure, status: s, cancelled: false)
        case .offline(let m):
            if m.hasPrefix(HTTPClient.silentHost) { return "timeout" }
            guard let (domain, code) = ErrorCause.marker(m), domain == NSURLErrorDomain, let c = Int(code) else { return "no_answer" }
            return Self.noStatus(c)
        default: return "no_answer"
        }
    }

    /// The class of a URL-loading error before any status (34.9.1's Apple codes).
    static func noStatus(_ code: Int) -> String {
        switch code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff: return "offline"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "dns"
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost: return "connect"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired: return "tls"
        case NSURLErrorTimedOut: return "timeout"
        default: return "no_answer"
        }
    }

    /// 34.9.1 item 4: `networkProtocolName` of the task's last transaction as a version; nil for none or another.
    static func proto(_ name: String?) -> String? {
        guard let n = name?.lowercased() else { return nil }
        if n == "http/1.0" || n == "http/1.1" { return "h1" }
        if n == "h2" { return "h2" }
        if n == "h3" || n.hasPrefix("h3-") { return "h3" }
        return nil
    }
}

/// One `models` host's counts of one UTC day (34.6): `files` whose last byte came from it, `bytes`, `requests`
/// (resumes included), `unreachable`, `hedged` (34.4) and `slow_switches` (section 35), the time to status in 9 buckets
/// and the rate of each transfer of at least 256 KiB over its body in 10 buckets of kB/s. SDK 4.0.5: and 34.9.1's
/// `fail` and `proto` (the 4.0.4 erratum, which Apple did not ship before 4.0.5), and section 35's five fields.
struct HostCount: Codable, Equatable, Sendable {
    var files = 0
    var bytes: Int64 = 0
    var requests = 0
    var unreachable = 0
    var hedged = 0
    var slowSwitches = 0
    var ttfb = [Int](repeating: 0, count: 9)
    var kbps = [Int](repeating: 0, count: 10)
    /// SDK 4.0.5 (SPLIT_40 35.9): ranges this host served as the second host (the first range of a split, a new one).
    var probes = 0
    /// Split files whose transfer on this host met 35.5 item 2 or 3, once per file, in the share or not.
    var wouldProbe = 0
    /// The verdicts on this host as the first host, by the two hosts' rate over the first's alone (times 100): under 110,
    /// 130, 150, 200, 400, and 400 or over.
    var gain = [Int](repeating: 0, count: 6)
    /// Bytes this host sent that a cut discarded (sent in kB).
    var wastedBytes: Int64 = 0
    /// CPU-set downloads that ended (`[0]`) or failed (`[1]`) with this host as P: outside the switch's share (`armCount`)
    /// and inside it (`armActed`).
    var armCount = [0, 0]
    var armActed = [0, 0]
    /// SDK 4.0.5 (STEERING_40 34.9.1): the requests that failed, by class (`FailClass.keys`; 35.7's `bad_body` of a file
    /// counts here too), and the requests that got a status, by HTTP version.
    var fail: [String: Int] = [:]
    var proto: [String: Int] = [:]
    /// SDK 4.0.5 (STEERING_40 34.9.7, the 4.0.4 erratum): the model requests that left this host for another, by (to, why),
    /// and how the files and downloads ended here.
    var moves: [ApiCount.Move] = []
    var outcome = Outcome()

    /// 34.9.7's `outcome`.
    struct Outcome: Codable, Equatable, Sendable {
        var moved = 0
        var failed: [String: Int] = [:]
        var cancelled = 0
        var paused = 0
        var ready = 0
        var notReady = 0

        var isEmpty: Bool { moved == 0 && failed.values.allSatisfy { $0 <= 0 } && cancelled == 0 && paused == 0 && ready == 0 && notReady == 0 }

        /// The closed object: a key left out is 0, so only the counts above 0.
        func body() -> [String: Any] {
            func m(_ v: Int) -> Int { min(HostCount.most, max(0, v)) }
            var o: [String: Any] = [:]
            if moved > 0 { o["moved"] = m(moved) }
            let f = failed.filter { FailClass.keys.contains($0.key) && $0.value > 0 }.mapValues(m)
            if !f.isEmpty { o["failed"] = f }
            if cancelled > 0 { o["cancelled"] = m(cancelled) }
            if paused > 0 { o["paused"] = m(paused) }
            if ready > 0 { o["ready"] = m(ready) }
            if notReady > 0 { o["not_ready"] = m(notReady) }
            return o
        }
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case files, bytes, requests, unreachable, hedged, slowSwitches, ttfb, kbps
        case probes, wouldProbe, gain, wastedBytes, armCount, armActed, fail, proto, moves, outcome
    }

    /// A day stored before 4.0.5 has none of the fields of section 35: each is 0 then.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = try c.decodeIfPresent(Int.self, forKey: .files) ?? 0
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        requests = try c.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        unreachable = try c.decodeIfPresent(Int.self, forKey: .unreachable) ?? 0
        hedged = try c.decodeIfPresent(Int.self, forKey: .hedged) ?? 0
        slowSwitches = try c.decodeIfPresent(Int.self, forKey: .slowSwitches) ?? 0
        ttfb = try c.decodeIfPresent([Int].self, forKey: .ttfb) ?? ttfb
        kbps = try c.decodeIfPresent([Int].self, forKey: .kbps) ?? kbps
        probes = try c.decodeIfPresent(Int.self, forKey: .probes) ?? 0
        wouldProbe = try c.decodeIfPresent(Int.self, forKey: .wouldProbe) ?? 0
        gain = try c.decodeIfPresent([Int].self, forKey: .gain) ?? gain
        wastedBytes = try c.decodeIfPresent(Int64.self, forKey: .wastedBytes) ?? 0
        armCount = try c.decodeIfPresent([Int].self, forKey: .armCount) ?? armCount
        armActed = try c.decodeIfPresent([Int].self, forKey: .armActed) ?? armActed
        fail = try c.decodeIfPresent([String: Int].self, forKey: .fail) ?? [:]
        proto = try c.decodeIfPresent([String: Int].self, forKey: .proto) ?? [:]
        moves = try c.decodeIfPresent([ApiCount.Move].self, forKey: .moves) ?? []
        outcome = try c.decodeIfPresent(Outcome.self, forKey: .outcome) ?? Outcome()
    }

    /// 34.9.7 item 1: a request moved from this host to `to` for `why` (each (to, why) once in the entry).
    mutating func move(to: String, why: String) {
        if let i = moves.firstIndex(where: { $0.to == to && $0.why == why }) { moves[i].n += 1 } else { moves.append(.init(to: to, why: why, n: 1)) }
    }

    /// 34.9.7 items 2 and 3: a file's or a download's end on this host (`moved`, `failed` with its class, `cancelled`,
    /// `paused`, `ready`, `not_ready`).
    mutating func ended(_ field: String, cls: String? = nil) {
        switch field {
        case "moved": outcome.moved += 1
        case "failed": if let c = cls, FailClass.keys.contains(c) { outcome.failed[c, default: 0] += 1 }
        case "cancelled": outcome.cancelled += 1
        case "paused": outcome.paused += 1
        case "ready": outcome.ready += 1
        case "not_ready": outcome.notReady += 1
        default: break
        }
    }

    /// 34.9.7 item 4: the most moves a body (and a UTC day) holds.
    static let movesMax = 32

    /// The buckets' upper bounds: `ttfb_ms` under 100, 250, 500, 1000, 1500, 3000, 6000, 10000 ms and over; `kbps`
    /// under 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192 kB/s and over.
    static let ttfbBounds: [Double] = [100, 250, 500, 1000, 1500, 3000, 6000, 10_000]
    static let kbpsBounds: [Double] = [32, 64, 128, 256, 512, 1024, 2048, 4096, 8192]
    /// The smallest transfer whose rate is counted.
    static let rateFloor: Int64 = 256 << 10
    /// The most hosts a day.
    static let perDay = 8

    static func bucket(_ value: Double, _ bounds: [Double]) -> Int { bounds.firstIndex { value < $0 } ?? bounds.count }

    /// The rate of a transfer in kB/s (1000 bytes): its bytes over its body's seconds (none: the fastest bucket).
    static func kilobytesPerSecond(_ bytes: Int64, _ seconds: Double) -> Double {
        seconds > 0 ? Double(bytes) / 1000 / seconds : .infinity
    }

    mutating func add(_ s: ModelHostSample) {
        requests += 1
        bytes += max(0, s.bytes)
        if s.unreachable { unreachable += 1 }
        if s.lastByte { files += 1 }
        if s.hedged { hedged += 1 }
        if let ms = s.ttfbMs { ttfb[Self.bucket(Double(max(0, ms)), Self.ttfbBounds)] += 1 }
        if s.bytes >= Self.rateFloor { kbps[Self.bucket(Self.kilobytesPerSecond(s.bytes, s.bodySeconds), Self.kbpsBounds)] += 1 }
        if let f = s.fail, FailClass.keys.contains(f) { fail[f, default: 0] += 1 }
        if let p = s.proto, FailClass.protos.contains(p) { proto[p, default: 0] += 1 }
    }

    /// SDK 4.0.5 (35.9): one of the decide's counts (`probes`, `would_probe`, `slow_switches`, `bad_body`; `gain`, whose
    /// `n` is the bucket). Anything else is not counted.
    mutating func split(_ field: String, _ n: Int) {
        switch field {
        case "probes": probes += max(0, n)
        case "would_probe": wouldProbe += max(0, n)
        case "slow_switches": slowSwitches += max(0, n)
        case "bad_body": fail["bad_body", default: 0] += max(0, n)
        case "gain": if (0..<gain.count).contains(n) { gain[n] += 1 }
        default: break
        }
    }

    /// The largest count the server takes in a `hosts` entry (qlab-api `HOSTS_SPEC`: 10,000,000).
    static let most = 10_000_000

    /// The entry of `hosts` for `host`: these fields and no other, every count at least 0, the buckets of their
    /// lengths. SDK 4.0.5 (35.9): while `AnalyticsStore.sendsSplitFields` is on, every entry has the five fields of
    /// section 35, 0 when nothing of it happened; and the three of 34.9.1: `fail` and `proto`, closed objects of the
    /// counts that are not 0, and `day_first`.
    func entry(host: String, dayFirst: Bool = true) -> [String: Any] {
        func n(_ v: Int) -> Int { min(1_000_000_000, max(0, v)) }
        func m(_ v: Int) -> Int { min(Self.most, max(0, v)) }
        func fixed(_ a: [Int], _ count: Int) -> [Int] { (a + Array(repeating: 0, count: count)).prefix(count).map(n) }
        func fixedM(_ a: [Int], _ count: Int) -> [Int] { (a + Array(repeating: 0, count: count)).prefix(count).map(m) }
        var e: [String: Any] = ["role": "models", "host": host, "files": n(files), "bytes": Int(clamping: max(0, bytes)), "requests": n(requests),
                                "unreachable": n(unreachable), "hedged": n(hedged), "slow_switches": n(slowSwitches),
                                "ttfb_ms": fixed(ttfb, 9), "kbps": fixed(kbps, 10),
                                "fail": fail.filter { FailClass.keys.contains($0.key) && $0.value > 0 }.mapValues(m),
                                "proto": proto.filter { FailClass.protos.contains($0.key) && $0.value > 0 }.mapValues(m),
                                "day_first": dayFirst ? 1 : 0]
        // 35.9: behind their switch (off until the server takes them)
        if AnalyticsStore.sendsSplitFields.withLock({ $0 }) {
            e["probes"] = m(probes)
            e["would_probe"] = m(wouldProbe)
            e["gain"] = fixedM(gain, 6)
            e["wasted"] = m(Int(clamping: max(0, wastedBytes) / 1000))
            e["arms"] = ["count": fixedM(armCount, 2), "acted": fixedM(armActed, 2)]
        }
        return e.merging(extras(), uniquingKeysWith: { a, _ in a })
    }

    /// 34.9.7: `moves` when this host has one, `outcome` when it counts anything (both optional to the server), while
    /// `AnalyticsStore.sendsDownloadMoves` is on.
    private func extras() -> [String: Any] {
        func m(_ v: Int) -> Int { min(Self.most, max(0, v)) }
        var o: [String: Any] = [:]
        guard AnalyticsStore.sendsDownloadMoves.withLock({ $0 }) else { return o }
        let mv = moves.filter { $0.n > 0 && FailClass.moveWhy.contains($0.why) }
        if !mv.isEmpty { o["moves"] = mv.map { ["to": $0.to, "why": $0.why, "n": m($0.n)] as [String: Any] } }
        if !outcome.isEmpty { o["outcome"] = outcome.body() }
        return o
    }

    /// A day's `hosts` (34.6): hosts of the allow-list only, each once, at most 8 (the most bytes first, then by name).
    /// `sealedBefore` (34.9.4): the hosts an earlier body of the same day already carried; each entry's `day_first` is 1
    /// only for a host not among them.
    static func body(_ counts: [String: HostCount], sealedBefore: Set<String> = []) -> [[String: Any]] {
        // 34.9.7 item 4: at most 32 moves in a body, the entries' first ones kept
        var movesLeft = movesMax
        return counts.filter { Endpoints.hostAllowed($0.key) }
            .sorted { $0.value.bytes != $1.value.bytes ? $0.value.bytes > $1.value.bytes : $0.key < $1.key }
            .prefix(perDay)
            .map { e in
                let h = Endpoints.asciiLower(e.key)
                var c = e.value
                c.moves = c.moves.filter { $0.to != h && Endpoints.hostAllowed($0.to) }
                c.moves = Array(c.moves.prefix(max(0, movesLeft)))
                movesLeft -= c.moves.count
                return c.entry(host: h, dayFirst: !sealedBefore.contains(h))
            }
    }
}
