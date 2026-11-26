import Foundation

/// SDK 4.0.5 (STEERING_40 34.9.7, the 4.0.4 erratum): where one build's model requests went, and how its files and its
/// download ended, for the `moves` and `outcome` of the `hosts` entries. Kept per build by `FileHosts` (one per source),
/// told to the telemetry through `tell` (the Client's, nothing with telemetry off). No path, file name or build leaves
/// it: only host names, classes and counts.
final class DownloadTrace: @unchecked Sendable {
    private struct File {
        /// The host this file's order left and why, until the next attempt asks another host (a move is counted then).
        var leaving: (host: String, why: String)?
        /// The file moved at least once in this download.
        var moved = false
        /// The host its last request was sent to, and that request's class when it failed.
        var lastAsked: String?
        var lastClass: String?
        /// The host that brought its last byte.
        var lastByte: String?
    }

    private let lock = NSLock()
    private var files: [String: File] = [:]
    /// The host of the download's last request, and of its last file finished.
    private var lastRequest: String?
    private var lastFile: String?
    /// Told each move and each end (`.modelMove`, `.modelOutcome`).
    let tell = Locked<(@Sendable (AnalyticsEvent) -> Void)?>(nil)

    private func emit(_ e: AnalyticsEvent) { tell.withLock { $0 }?(e) }

    /// An attempt of `path` is sent to `host`: a move when the file's order left another host for it (34.9.7 item 1).
    func asking(_ path: String, _ host: String) {
        let move = lock.withLock { () -> (String, String)? in
            var f = files[path] ?? File()
            var m: (String, String)?
            if let l = f.leaving {
                if l.host != host {
                    m = (l.host, l.why)
                    f.moved = true
                }
                f.leaving = nil
            }
            f.lastAsked = host
            files[path] = f
            lastRequest = host
            return m
        }
        if let (from, why) = move { emit(.modelMove(host: from, to: host, why: why)) }
    }

    /// The attempt of `path` on `host` ended unreachable with `cls`: the next attempt that asks another host is a move.
    func left(_ path: String, _ host: String, cls: String?) {
        lock.withLock {
            var f = files[path] ?? File()
            f.lastClass = cls
            if let cls { f.leaving = (host, cls) }
            files[path] = f
        }
    }

    /// The attempt of `path` ended with a class that is no move (a refusal, a 429: the request ends on its host).
    func failed(_ path: String, cls: String?) {
        lock.withLock {
            var f = files[path] ?? File()
            f.lastClass = cls
            files[path] = f
        }
    }

    /// A move counted at once: 34.4's second request decided (`hedge`, or the first's class when it was unreachable),
    /// 34.5's cut (`slow`).
    func moved(_ path: String, from: String, to: String, why: String) {
        guard from != to else { return }
        lock.withLock {
            var f = files[path] ?? File()
            f.moved = true
            f.leaving = nil
            f.lastAsked = to
            files[path] = f
            lastRequest = to
        }
        emit(.modelMove(host: from, to: to, why: why))
    }

    /// `host` brought the last byte of `path`.
    func lastByte(_ path: String, _ host: String) {
        lock.withLock {
            var f = files[path] ?? File()
            f.lastByte = host
            files[path] = f
        }
    }

    /// How a file's download ended (34.9.7 item 2).
    enum FileEnd: Sendable { case done, failed, cancelled, paused }

    /// The file's end, counted once: `moved` on the host of its last byte when it moved, `failed` with its last request's
    /// class on the last host asked, `cancelled` and `paused` on the host of the request in flight. A file finished on
    /// its first host is in `files` only.
    func fileEnded(_ path: String, _ how: FileEnd) {
        let e = lock.withLock { () -> AnalyticsEvent? in
            guard let f = files.removeValue(forKey: path) else { return nil }
            switch how {
            case .done:
                let h = f.lastByte ?? f.lastAsked
                if let h { lastFile = h }
                guard f.moved, let h else { return nil }
                return .modelOutcome(host: h, field: "moved", cls: nil)
            case .failed:
                guard let h = f.lastAsked, let c = f.lastClass else { return nil }
                return .modelOutcome(host: h, field: "failed", cls: c)
            case .cancelled:
                return f.lastAsked.map { .modelOutcome(host: $0, field: "cancelled", cls: nil) }
            case .paused:
                return f.lastAsked.map { .modelOutcome(host: $0, field: "paused", cls: nil) }
            }
        }
        if let e { emit(e) }
    }

    /// The download ended (34.9.7 item 3): `ready` on the host of its last file, or `not_ready` on the host of its last
    /// request.
    func downloadEnded(ready: Bool) {
        let host = lock.withLock { ready ? (lastFile ?? lastRequest) : lastRequest }
        guard let host else { return }
        emit(.modelOutcome(host: host, field: ready ? "ready" : "not_ready", cls: nil))
    }

    /// How a file's failure reads (34.9.7 item 2): the app's cancel, a device with no network (`paused`), else failed.
    static func end(of e: RecognizerError, cancelled: Bool) -> FileEnd {
        if cancelled { return .cancelled }
        switch e {
        case .cancelled: return .cancelled
        case .offline(let why):
            if let (domain, code) = ErrorCause.marker(why), domain == NSURLErrorDomain, let c = Int(code),
               FailClass.noStatus(c) == "offline" { return .paused }
            return .failed
        default: return .failed
        }
    }
}
