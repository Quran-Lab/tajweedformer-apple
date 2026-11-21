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
            var f = file(path)
            let h = f.order[f.k % f.order.count]
            f.asked.insert(h)
            files[path] = f
            return h
        }
    }

    /// Whether a file of this build was asked of more than one host (24.2 `fallback`).
    var fellBack: Bool { lock.withLock { files.values.contains { $0.asked.count > 1 } } }

    /// The attempt of `path` was answered (taken, a refusal or a slow down): its host becomes `P`. A file whose first
    /// host was unreachable and that another host answered tells that failover once (28.7: `lastFailover` with the
    /// host that answered, and the silent `download`, `failover` report). The first host answering a later attempt
    /// itself (a list of one host, or the order come round) is no failover: nothing more is told.
    func answered(_ path: String, _ cls: AnswerClass) {
        let now = endpoints.clock()
        let (host, probe, failover) = lock.withLock { () -> (URL, Bool, EndpointSet.Failover?) in
            var f = file(path)
            let h = f.order[f.k % f.order.count]
            var told: EndpointSet.Failover?
            if f.k > 0, let first = f.first, !f.reported, h != f.order[0] {
                f.reported = true
                told = EndpointSet.Failover(role: .models, from: f.order[0].host ?? "", to: h.host, reason: first.reason, status: first.status,
                                            at: Int64(now.timeIntervalSince1970))
            }
            files[path] = f
            return (h, f.probe, told)
        }
        endpoints.settle(.models, host, at: now, probe: probe)
        if let failover { endpoints.failedOver(failover, stage: "download") }
    }

    /// The attempt of `path` failed with `e`. A refusal or a 429 is an answer of its host (`answered`); a failure that
    /// is no answer of a host (the device's store) changes nothing; anything else was unreachable, and the next
    /// attempt goes to the next host. The file's first host found unreachable is `lastFailover` at once, with no host
    /// that answered yet (28.7: `to` null while none did; a list of one host, or no network, leaves it so).
    func failed(_ path: String, _ e: CloudError) {
        switch Self.answerClass(e) {
        case .some(.refused): answered(path, .refused)
        case .some(.slowDown): answered(path, .slowDown)
        case .some:
            let now = endpoints.clock()
            let unanswered = lock.withLock { () -> EndpointSet.Failover? in
                var f = file(path)
                var told: EndpointSet.Failover?
                if f.k == 0, f.first == nil {
                    let first = Endpoints.unreachableReason(.failure(e))
                    f.first = first
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
