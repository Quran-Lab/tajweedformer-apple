import Foundation

/// One install's error reports (24.5): the queue, the signatures of each day, and the signatures it has reported.
/// A value, so the rules run the same in the SDK and in the replay of `vectors/errors_40.json` `queue`; errors40.py's
/// `Reporter`. Kept as JSON in the SDK's folder (`ErrorReporter`).
struct ErrorReportBook: Codable, Equatable, Sendable {
    /// A report waiting to be sent: its signature's fields, its count, and the last occurrence's snapshot.
    struct Entry: Codable, Equatable, Sendable {
        var day: String
        var sig: String
        var stage: String
        var reason: String
        var code: String
        var httpStatus: Int?
        var count: Int
        var firstReport: Bool
        var firstLaunch: Bool
        var errorName: String?
        var errorCode: String?
        var retries: Int?
        /// The model version and the build in use or being fetched, when known.
        var revision: String?
        var build: String?
        /// 4.0.1 (24.2, 28.7): the role of the request the cause is, and whether it was asked of more than one host.
        var hostRole: String? = nil
        var fallback: Bool? = nil
        /// SDK 4.0.5 (ATTEST_40.md 40.6): the occurrence's cause chain, the last 8 hops.
        var chain: [CauseHop]? = nil
    }

    /// A signature the install has reported, with the last day one was accepted.
    struct Reported: Codable, Equatable, Sendable {
        var sig: String
        var day: String
    }

    static let dailySignatures = 16
    static let queueMax = 32
    static let reportedMax = 64
    static let firstAgainDays = 90
    static let keepDays = 7
    static let countMax = 100_000

    var queue: [Entry] = []
    /// day -> signature -> `queued` or `sent`.
    var days: [String: [String: String]] = [:]
    /// Oldest first.
    var reported: [Reported] = []

    /// An occurrence of `cause` whose app got `code` (`none`: a silent failure) on UTC `day`; true when it made a new
    /// report. `enabled`: the signed config's `flags.issues` (false: nothing is recorded).
    @discardableResult
    mutating func occur(day: String, cause: ErrorCause, code: String, firstLaunch: Bool, enabled: Bool = true,
                        snapshot: (revision: String?, build: String?) = (nil, nil)) -> Bool {
        guard enabled, ErrorRules.reported(stage: cause.stage, reason: cause.reason, code: code) else { return false }
        let sig = ErrorRules.signature(stage: cause.stage, reason: cause.reason, code: code, status: cause.httpStatus)
        for d in days.keys where (ErrorRules.days(from: d, to: day) ?? 0) > Self.keepDays { days[d] = nil }
        var today = days[day] ?? [:]
        defer { days[day] = today }
        switch today[sig] {
        case "sent":
            return false
        case "queued":
            if let i = queue.firstIndex(where: { $0.day == day && $0.sig == sig }) {
                queue[i].count = min(Self.countMax, queue[i].count + 1)
                queue[i].firstLaunch = queue[i].firstLaunch || firstLaunch
                // the occurrence's own fields are the last one's
                queue[i].errorName = cause.errorName
                queue[i].errorCode = cause.errorCode
                queue[i].retries = cause.retries
                queue[i].hostRole = cause.hostRole
                queue[i].fallback = cause.fallback
                queue[i].chain = cause.chain.flatMap { CauseChain.last($0) }
                if let r = snapshot.revision { queue[i].revision = r }
                if let b = snapshot.build { queue[i].build = b }
            }
            return false
        default:
            break
        }
        if today.count >= Self.dailySignatures { return false }
        let last = reported.first { $0.sig == sig }?.day
        let again = last.map { (ErrorRules.days(from: $0, to: day) ?? 0) > Self.firstAgainDays } ?? true
        let first = again && !queue.contains { $0.sig == sig }
        queue.append(Entry(day: day, sig: sig, stage: cause.stage, reason: cause.reason, code: code, httpStatus: cause.httpStatus,
                           count: 1, firstReport: first, firstLaunch: firstLaunch, errorName: cause.errorName,
                           errorCode: cause.errorCode, retries: cause.retries, revision: snapshot.revision, build: snapshot.build,
                           hostRole: cause.hostRole, fallback: cause.fallback, chain: cause.chain.flatMap { CauseChain.last($0) }))
        today[sig] = "queued"
        while queue.count > Self.queueMax {
            let old = queue.removeFirst()
            if old.day == day {
                today[old.sig] = nil
            } else {
                days[old.day]?[old.sig] = nil
            }
        }
        return true
    }

    /// `flags.issues: false`: the queue is dropped.
    mutating func dropQueue() { queue = [] }

    /// A send point on UTC `today`: reports more than 7 days old go, and the rest are what to send, oldest first.
    mutating func due(today: String) -> [Entry] {
        queue.removeAll { (ErrorRules.days(from: $0.day, to: today) ?? 0) > Self.keepDays }
        return queue
    }

    /// The server's answer to a report (24.6): 202 sent, its signature on the reported list; 400 or 413 dropped; any
    /// other answer (429, a 5xx, none) keeps it and ends the send point. Returns whether the send point goes on.
    mutating func answered(_ e: Entry, status: Int?) -> Bool {
        guard status == 202 || status == 400 || status == 413 else { return false }
        queue.removeAll { $0.day == e.day && $0.sig == e.sig }
        days[e.day, default: [:]][e.sig] = "sent"
        if status == 202 {
            reported.removeAll { $0.sig == e.sig }
            reported.append(Reported(sig: e.sig, day: e.day))
            if reported.count > Self.reportedMax { reported.removeFirst(reported.count - Self.reportedMax) }
        }
        return true
    }
}
