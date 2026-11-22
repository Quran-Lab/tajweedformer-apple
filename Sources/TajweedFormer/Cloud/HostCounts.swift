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
}

/// One `models` host's counts of one UTC day (34.6): `files` whose last byte came from it, `bytes`, `requests`
/// (resumes included), `unreachable`, `hedged` and `slow_switches` (both always 0 in 4.0.2: the hedge and the slow
/// switch are 4.0.3's, 34.4 and 34.5), the time to status in 9 buckets and the rate of each transfer of at least
/// 256 KiB over its body in 10 buckets of kB/s.
struct HostCount: Codable, Equatable, Sendable {
    var files = 0
    var bytes: Int64 = 0
    var requests = 0
    var unreachable = 0
    var hedged = 0
    var slowSwitches = 0
    var ttfb = [Int](repeating: 0, count: 9)
    var kbps = [Int](repeating: 0, count: 10)

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
        if let ms = s.ttfbMs { ttfb[Self.bucket(Double(max(0, ms)), Self.ttfbBounds)] += 1 }
        if s.bytes >= Self.rateFloor { kbps[Self.bucket(Self.kilobytesPerSecond(s.bytes, s.bodySeconds), Self.kbpsBounds)] += 1 }
    }

    /// The entry of `hosts` for `host`: these fields and no other, every count at least 0, the buckets of their
    /// lengths.
    func entry(host: String) -> [String: Any] {
        func n(_ v: Int) -> Int { min(1_000_000_000, max(0, v)) }
        func fixed(_ a: [Int], _ count: Int) -> [Int] { (a + Array(repeating: 0, count: count)).prefix(count).map(n) }
        return ["role": "models", "host": host, "files": n(files), "bytes": Int(clamping: max(0, bytes)), "requests": n(requests),
                "unreachable": n(unreachable), "hedged": n(hedged), "slow_switches": n(slowSwitches),
                "ttfb_ms": fixed(ttfb, 9), "kbps": fixed(kbps, 10)]
    }

    /// A day's `hosts` (34.6): hosts of the allow-list only, each once, at most 8 (the most bytes first, then by name).
    static func body(_ counts: [String: HostCount]) -> [[String: Any]] {
        counts.filter { Endpoints.hostAllowed($0.key) }
            .sorted { $0.value.bytes != $1.value.bytes ? $0.value.bytes > $1.value.bytes : $0.key < $1.key }
            .prefix(perDay)
            .map { $0.value.entry(host: Endpoints.asciiLower($0.key)) }
    }
}
