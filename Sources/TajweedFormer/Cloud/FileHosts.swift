import Foundation

/// A partial file's validator kept with the host that gave it (SDK 4.0.1, 28.4, SPEC 16.2): an ETag is one store's,
/// and each store makes its own, so `If-Range` goes only to that host. Stored as `@<host> <etag>`; a validator stored
/// before 4.0.1 (the ETag alone) is the folder's own host's.
enum HostValidator {
    static func make(_ host: String, _ etag: String?) -> String? { etag.map { "@" + host + " " + $0 } }

    /// The ETag of `stored` when it may go to `host` as `If-Range`; nil for another host's, or none.
    static func etag(_ stored: String?, for host: String, legacyHost: String) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        guard stored.hasPrefix("@") else { return host == legacyHost ? stored : nil }
        guard let space = stored.firstIndex(of: " ") else { return nil }
        let from = String(stored[stored.index(after: stored.startIndex)..<space])
        let etag = String(stored[stored.index(after: space)...])
        return from == host && !etag.isEmpty ? etag : nil
    }
}

/// The `models` hosts the files of one build are asked of (28.4): each file's order is fixed when its first attempt
/// starts (`P` first, the lease folder's host before the role's when it is not one of them, the probe back as 28.3);
/// each attempt asks one host, and an attempt that was unreachable sends the next one (16.2's resume, its pause and
/// its count unchanged) to the next host of the order, cycling. A refusal and a 429 end the file on their host. The
/// host that answered becomes `P`, so the next file starts there.
final class FileHosts: @unchecked Sendable {
    private struct File {
        let order: [URL]
        let probe: Bool
        var k = 0
        var asked: Set<URL> = []
        /// The first host's failure, when its attempt was unreachable: its 24.3 reason and status.
        var first: (reason: String, status: Int?)?
        var reported = false
        /// SDK 4.0.2: the first host was held by a `Retry-After` and not asked in this process: when another host
        /// answers, `lastFailover` is told as before, and no silent report goes out (one goes out only when the first
        /// host was asked and was unreachable).
        var firstHeld = false
    }

    private let lock = NSLock()
    private var files: [String: File] = [:]
    let endpoints: EndpointSet
    /// The origin of the lease answer's folder.
    let base: URL

    init(endpoints: EndpointSet, base: URL) {
        self.endpoints = endpoints
        self.base = base
    }

    private func file(_ path: String) -> File {
        if let f = files[path] { return f }
        let now = endpoints.clock()
        let (order, probe) = endpoints.order(.models, at: now, first: endpoints.isRoleHost(.models, base) ? nil : base)
        return File(order: order.isEmpty ? [base] : order, probe: probe)
    }

    /// The host the next attempt of `path` asks.
    func host(for path: String) -> URL {
        lock.withLock {
            let f = file(path)
            files[path] = f
            return f.order[f.k % f.order.count]
        }
    }

    /// Whether a file of this build was asked of more than one host (24.2 `fallback`). SDK 4.0.2: a host is counted when
    /// its attempt ended with its answer or as unreachable, never when it was skipped for a `Retry-After` hold without a
    /// request (ERRORS_40: asked of more than one host).
    var fellBack: Bool { lock.withLock { files.values.contains { $0.asked.count > 1 } } }

    /// The attempt of `path` was answered (taken, a refusal or a slow down): its host becomes `P`. A file whose first
    /// host was unreachable and that another host answered tells that failover once (28.7: `lastFailover` with the
    /// host that answered, and the silent `download`, `failover` report). The first host answering a later attempt
    /// itself (a list of one host, or the order come round) is no failover: nothing more is told.
    func answered(_ path: String, _ cls: AnswerClass) {
        let now = endpoints.clock()
        let (host, probe, failover, held) = lock.withLock { () -> (URL, Bool, EndpointSet.Failover?, Bool) in
            var f = file(path)
            let h = f.order[f.k % f.order.count]
            f.asked.insert(h)
            var told: EndpointSet.Failover?
            if f.k > 0, let first = f.first, !f.reported, h != f.order[0] {
                f.reported = true
                told = EndpointSet.Failover(role: .models, from: f.order[0].host ?? "", to: h.host, reason: first.reason, status: first.status,
                                            at: Int64(now.timeIntervalSince1970))
            }
            files[path] = f
            return (h, f.probe, told, f.firstHeld)
        }
        endpoints.settle(.models, host, at: now, probe: probe)
        // a first host held and not asked: `lastFailover` as before, and no report (its stage is the report's switch)
        if let failover { endpoints.failedOver(failover, stage: held ? nil : "download") }
    }

    /// The attempt of `path` failed with `e`. A refusal or a 429 is an answer of its host (`answered`); a failure that
    /// is no answer of a host (the device's store) changes nothing; anything else was unreachable, and the next
    /// attempt goes to the next host. The file's first host found unreachable is `lastFailover` at once, with no host
    /// that answered yet (28.7: `to` null while none did; a list of one host, or no network, leaves it so).
    func failed(_ path: String, _ e: CloudError) {
        switch Self.answerClass(e) {
        case .some(.refused): answered(path, .refused)
        case .some(.slowDown):
            // SDK 4.0.2 (28.7, contract 7cdb1ee): a 429 the SDK held without a request is the call's answer, and no
            // host answered it: no host of `fallback`, no failover, and `P` stays where it was
            if case .rejected(_, _, let message, _) = e, message.hasPrefix(RetryAfterHolds.heldMessage) { return }
            answered(path, .slowDown)
        case .some:
            let now = endpoints.clock()
            let notAsked: Bool
            if case .offline(let why) = e { notAsked = why == HTTPClient.heldNotAsked } else { notAsked = false }
            let unanswered = lock.withLock { () -> EndpointSet.Failover? in
                var f = file(path)
                // a host skipped for a hold was not asked: it is no host of `fallback`
                if !notAsked { f.asked.insert(f.order[f.k % f.order.count]) }
                var told: EndpointSet.Failover?
                if f.k == 0, f.first == nil {
                    let first = Endpoints.unreachableReason(.failure(e))
                    f.first = first
                    f.firstHeld = notAsked
                    told = EndpointSet.Failover(role: .models, from: f.order[0].host ?? "", to: nil, reason: first.reason,
                                                status: first.status, at: Int64(now.timeIntervalSince1970))
                }
                f.k += 1
                files[path] = f
                return told
            }
            // kept for diagnose() only: the silent report is told when another host answers (`answered`)
            if let unanswered { endpoints.failedOver(unanswered, stage: "download") }
        case .none: break
        }
    }

    /// The class of a failed attempt (28.3); nil for a failure of the device itself.
    static func answerClass(_ e: CloudError) -> AnswerClass? {
        switch e {
        case .rejected(429, _, _, _): return .slowDown
        // the bytes on the device run past that host's file: its own answer, the file starts again there (16.1)
        case .rejected(416, _, _, _): return .refused
        case .rejected(let s, let code, _, _):
            return (400..<500).contains(s) && !code.hasPrefix("http_") && code != HTTPClient.redirectCode ? .refused : .unreachable
        case .offline, .badAnswer, .invalid: return .unreachable
        case .storage, .noKey: return nil
        }
    }

    /// What an unreachable answer is to 16.2's resume: a failure the file is taken up again after (on the next host).
    /// A redirect and a 4xx that is not the API's are unreachable (28.3), so they are resumed like no answer.
    static func resumable(_ e: CloudError) -> CloudError {
        guard case .rejected(let s, let code, _, _) = e, answerClass(e) == .unreachable else { return e }
        return code == HTTPClient.redirectCode ? HTTPClient.redirectRefused(s) : .offline("HTTP \(s)")
    }
}
