import Foundation

// SDK 4.0.5, contract section 37 (`sdk_4.0.0/API_40.md`): every API request an install makes, counted per host and
// route (`api`), and the seconds from the app's first ask for a model to a model ready to take (`ready`). The reference is
// `tools/api40.py`; `ApiVectorTests` replays `vectors/api_40.json` through this file and the telemetry store.

/// 37.2: what an API request is for.
enum ApiRoute {
    static let all = ["config", "challenge", "attest", "assert", "register", "lease", "events", "issues", "sharing"]
    private static let exact: [(method: String, path: String, route: String)] = [
        ("GET", "/v1/config", "config"), ("GET", "/v1/attest/challenge", "challenge"), ("POST", "/v1/attest", "attest"),
        ("POST", "/v1/attest/assert", "assert"), ("POST", "/v1/register", "register"), ("POST", "/v1/model-key", "lease"),
        ("POST", "/v1/events", "events"), ("POST", "/v1/issues", "issues"),
    ]
    private static let sharing = ["/v1/uploads", "/v1/contributions"]

    /// The route of a request, or nil for one not counted (`/v1/origin-check`, `/v1/sdk/latest`, `/v1/health`, any other).
    static func of(method: String, path: String) -> String? {
        let p = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        let m = method.uppercased()
        if let hit = exact.first(where: { $0.method == m && $0.path == p }) { return hit.route }
        if sharing.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { return "sharing" }
        return nil
    }
}

/// 37.3 item 2: how an API answer is read (28.3 item 3) and classed (34.9.1's classes, read on the `api` role).
enum ApiClass {
    /// An answer as the class reads it: its status (nil: none came), whether a 2xx (or a conditional 304) is the route's
    /// answer (`taken`), whether a 4xx's body is the API's JSON `error`, whether a 2xx's body ended before its length
    /// (`cut`); for no status, the class of why (one of 34.9.1's first six).
    struct Answer: Sendable, Equatable {
        var status: Int?
        var taken = true
        var apiError = false
        var cut = false
        var noStatus: String = "no_answer"
    }

    /// (the reading of 28.3 item 3, the class or nil when it was taken).
    static func of(route: String, _ a: Answer) -> (reading: AnswerClass, fail: String?) {
        guard let s = a.status else {
            let c = FailClass.keys.prefix(6).contains(a.noStatus) ? a.noStatus : "no_answer"
            return (.unreachable, c)
        }
        if (200..<300).contains(s) {
            if a.cut { return (.unreachable, "cut") }
            return a.taken ? (.taken, nil) : (.unreachable, "bad_body")
        }
        if s == 304, route == "config", a.taken { return (.taken, nil) }
        if s < 200 || (300..<400).contains(s) { return (.unreachable, "http_3xx") }
        let cls: String
        switch s {
        case 403: cls = "http_403"
        case 404: cls = "http_404"
        case 429: cls = "http_429"
        case 503: cls = "http_503"
        default: cls = s < 500 ? "http_4xx" : "http_5xx"
        }
        if s == 429 { return (.slowDown, cls) }
        if (400..<500).contains(s), a.apiError { return (.refused, cls) }
        return (.unreachable, cls)
    }
}

/// What the platform measured of one request (URLSessionTaskMetrics, 37.3's Apple row): from sent to the whole answer,
/// whether its connection was reused, a new connection's time (DNS, TCP and TLS together), the HTTP version.
struct ApiMeasure: Sendable, Equatable {
    var totalMs: Double?
    /// nil: the platform does not say.
    var reused: Bool?
    var connectMs: Double?
    var proto: String?

    init(totalMs: Double? = nil, reused: Bool? = nil, connectMs: Double? = nil, proto: String? = nil) {
        self.totalMs = totalMs
        self.reused = reused
        self.connectMs = connectMs
        self.proto = proto
    }

    init(_ m: URLSessionTaskMetrics) {
        totalMs = m.taskInterval.duration * 1000
        let t = m.transactionMetrics.last(where: { $0.resourceFetchType == .networkLoad }) ?? m.transactionMetrics.last
        proto = t?.networkProtocolName
        guard let t, t.resourceFetchType == .networkLoad, t.connectStartDate != nil || t.isReusedConnection else { return }
        reused = t.isReusedConnection
        if !t.isReusedConnection, let end = t.secureConnectionEndDate ?? t.connectEndDate,
           let start = t.domainLookupStartDate ?? t.connectStartDate {
            connectMs = max(0, end.timeIntervalSince(start) * 1000)
        }
    }
}

/// One API request that ended (37.3).
struct ApiSample: Sendable, Equatable, Hashable {
    var host: String
    var route: String
    /// 34.9.1's class; nil: taken or cancelled.
    var fail: String?
    /// From sent to the whole answer read; nil for no status, a cut, a cancel.
    var totalMs: Double?
    /// `new_conn` (false) or `reused` (true); nil: neither (no connection, or the platform cannot tell).
    var reused: Bool?
    var connectMs: Double?
    /// 34.9.1 item 4's version of a request that got a status.
    var proto: String?

    /// The sample of a request whose answer the platform read: what `ApiClass` says of it, and what was measured.
    static func of(host: String, route: String, answer a: ApiClass.Answer, cancelled: Bool, measure m: ApiMeasure?,
                   ownMs: Double?) -> ApiSample {
        let fail = cancelled ? nil : ApiClass.of(route: route, a).fail
        var s = ApiSample(host: host, route: route, fail: fail)
        guard a.status != nil else { return s }
        if !cancelled, !a.cut { s.totalMs = m?.totalMs ?? ownMs }
        s.reused = m?.reused
        if m?.reused == false { s.connectMs = m?.connectMs }
        s.proto = FailClass.proto(m?.proto)
        return s
    }
}

/// One (host, route)'s counts of a day (37.4).
struct ApiCount: Codable, Equatable, Sendable {
    struct Move: Codable, Equatable, Sendable {
        var to: String
        var why: String
        var n: Int
    }

    var host: String
    var route: String
    var requests = 0
    var fail: [String: Int] = [:]
    var totalMs = [Int](repeating: 0, count: 9)
    var newConn = 0
    var reused = 0
    var connectMs = [Int](repeating: 0, count: 9)
    var proto: [String: Int] = [:]
    var moves: [Move] = []

    init(host: String, route: String) {
        self.host = host
        self.route = route
    }

    /// 37.3 item 3: 50, 100, 200, 300, 500, 1000, 2000, 5000 ms; a time equal to a bound goes in the bucket above it.
    static let msBounds: [Double] = [50, 100, 200, 300, 500, 1000, 2000, 5000]
    /// 37.4: at most 12 (host, route) pairs a day, 4 (to, why) per entry a day.
    static let pairsPerDay = 12
    static let movesPerEntry = 4

    mutating func add(_ s: ApiSample) {
        requests += 1
        if let f = s.fail, FailClass.keys.contains(f) { fail[f, default: 0] += 1 }
        if let ms = s.totalMs { totalMs[HostCount.bucket(max(0, ms), Self.msBounds)] += 1 }
        switch s.reused {
        case false?:
            newConn += 1
            if let ms = s.connectMs { connectMs[HostCount.bucket(max(0, ms), Self.msBounds)] += 1 }
        case true?: reused += 1
        case nil: break
        }
        if let p = s.proto, FailClass.protos.contains(p) { proto[p, default: 0] += 1 }
    }

    mutating func move(to: String, why: String) {
        if let i = moves.firstIndex(where: { $0.to == to && $0.why == why }) {
            moves[i].n += 1
        } else {
            moves.append(Move(to: to, why: why, n: 1))
        }
    }

    /// The entry of `api` (37.4): every field, every count from 0 to 10,000,000.
    func entry(dayFirst: Bool) -> [String: Any] {
        func m(_ v: Int) -> Int { min(HostCount.most, max(0, v)) }
        return ["host": host, "route": route, "requests": m(requests),
                "fail": fail.filter { FailClass.keys.contains($0.key) && $0.value > 0 }.mapValues(m),
                "total_ms": totalMs.map(m), "new_conn": m(newConn), "reused": m(reused), "connect_ms": connectMs.map(m),
                "proto": proto.filter { FailClass.protos.contains($0.key) && $0.value > 0 }.mapValues(m),
                "moves": moves.filter { $0.n > 0 }.prefix(Self.movesPerEntry).map { ["to": $0.to, "why": $0.why, "n": m($0.n)] as [String: Any] },
                "day_first": dayFirst ? 1 : 0]
    }

    /// The key a day keeps it under.
    static func key(_ host: String, _ route: String) -> String { host + " " + route }
}

/// 37.5: the first ask of a process for a model, ready (`first` in the install's first launch, `later` otherwise) or not.
struct ReadySample: Sendable, Equatable, Hashable {
    enum Kind: String, Sendable, Hashable { case first, later, notReady }
    var kind: Kind
    var seconds: Double = 0
}

/// 37.5: a day's `ready`.
struct ReadyCount: Codable, Equatable, Sendable {
    var first = [Int](repeating: 0, count: 9)
    var later = [Int](repeating: 0, count: 9)
    var notReady = 0

    /// 1, 2, 5, 10, 30, 60, 120, 300 s, read as `total_ms`'s bounds.
    static let sBounds: [Double] = [1, 2, 5, 10, 30, 60, 120, 300]

    mutating func add(_ r: ReadySample) {
        switch r.kind {
        case .first: first[HostCount.bucket(max(0, r.seconds), Self.sBounds)] += 1
        case .later: later[HostCount.bucket(max(0, r.seconds), Self.sBounds)] += 1
        case .notReady: notReady += 1
        }
    }

    func body(dayFirst: Bool) -> [String: Any] {
        func m(_ v: Int) -> Int { min(HostCount.most, max(0, v)) }
        return ["first": first.map(m), "later": later.map(m), "not_ready": m(notReady), "day_first": dayFirst ? 1 : 0]
    }
}

/// 37.5 item 1: the clock of the app's first ask for a model in this process (`client.model()`, `prefetch()`), from the ask
/// to a model ready to take, or to the ask's failure or cancel. One count per process.
enum ReadyClock {
    /// The first ask was made in this process.
    private static let asked = Locked(false)
    /// Seconds of a monotonic clock. Tests replace it.
    static let now = Locked<@Sendable () -> Double>({ Double(DispatchTime.now().uptimeNanoseconds) / 1e9 })

    /// The first ask's clock, for the ask that is it.
    struct Ask: Sendable {
        let start: Double

        /// The ask ended: with a model ready, or without one (failed or cancelled). Told to the configured Client.
        func ended(ready: Bool) {
            guard let cloud = QuranLab.cloud else { return }
            let s = ReadyClock.now.withLock { $0 }() - start
            cloud.recordReady(ready ? ReadySample(kind: cloud.firstLaunch ? .first : .later, seconds: s) : ReadySample(kind: .notReady))
        }
    }

    /// The clock when this is the process's first ask, else nil.
    static func begin() -> Ask? {
        let first = asked.withLock { (a: inout Bool) -> Bool in
            defer { a = true }
            return !a
        }
        return first ? Ask(start: now.withLock { $0 }()) : nil
    }

    /// Tests only: as if no ask was made in this process.
    static func forgetForTests() { asked.withLock { $0 = false } }
}
