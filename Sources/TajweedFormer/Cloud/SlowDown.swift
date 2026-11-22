import Foundation

/// SDK 4.0.2, contract 28.11 (dd76474; the Ramadan capacity model, 2026-11-21): what the SDK does after the API asks
/// it to wait.
///
/// Item 2, every route: a `Retry-After` on a 429, and on a 503 that carries one (read as 1 to 21600 s, as 18.4.7;
/// anything else is none), holds that route on that host until it has passed, whatever the route's own schedule. A 429
/// is never taken to another host (28.3), so a 429's hold is the route's on every host: a request of it is answered at
/// once, as the route's last answer was, and asks no host. A 503's hold is the host's: the request goes to the route's
/// next host. Item 3: the holds are kept in `cloud/retry-after.json` and read back at the next start; one that ends more
/// than 21600 s after the clock at start (a clock that moved back) ends then. Tried before (to 4.0.1): only the lease
/// read `Retry-After`, and every process forgot it at a restart.
final class RetryAfterHolds: Sendable {
    struct Holds: Codable, Equatable {
        /// The route on every host, until (a 429).
        var routes: [String: Date] = [:]
        /// One host of a route, until (a 503 with `Retry-After`), by "<route> <origin>".
        var hosts: [String: Date] = [:]
        /// The `Retry-After` of the last 429 of each route, seconds (0: it named none).
        var last429: [String: Int] = [:]
        /// The `error` of the last answer that made a hold, by "429 <route>" and "503 <route>".
        var lastCode: [String: String] = [:]

        /// As a start reads them back: past holds go, and one more than 21600 s ahead ends now.
        func readBack(now: Date) -> Holds {
            let live = { (t: Date) -> Bool in t > now && t <= now.addingTimeInterval(21_600) }
            var h = self
            h.routes = routes.filter { live($0.value) }
            h.hosts = hosts.filter { live($0.value) }
            return h
        }
    }
    private let state: Locked<Holds>
    private let file: JSONFile<Holds>?

    /// `file`: where the holds are kept across restarts (nil: in the process only).
    init(file: URL? = nil, now: Date = Date()) {
        let f = file.map { JSONFile<Holds>(url: $0) }
        self.file = f
        // unreadable is taken as none: a request may then go sooner, as before 4.0.2
        state = Locked((f?.read().takingUnreadableAsMissing ?? Holds()).readBack(now: now))
    }

    /// The route of a request, as its holds and rows go: `models:<path>` for a model file or manifest (contract
    /// e330c08: on the `models` role a hold is per file path and host, so a standby's 503 with `Retry-After` for an
    /// accelerator file, which it does not hold, leaves the CPU files there to be asked), else the API's route
    /// (`config`, `register`, `attest/challenge`, `attest`, `attest/assert`, `model-key`, `events`, `issues`,
    /// `uploads` with its `urls` and `takes`, `contributions`, ...).
    static func route(of url: URL, role: EndpointRole) -> String {
        if role == .models { return "models:" + url.path }
        let parts = url.path.split(separator: "/").map(String.init)
        if let v = parts.firstIndex(of: "v1"), v + 1 < parts.count {
            // the three attest routes are each their own
            if parts[v + 1] == "attest", v + 2 < parts.count { return "attest/" + parts[v + 2] }
            return parts[v + 1]
        }
        return parts.last ?? url.path
    }

    /// The hold on `route` at `host` now: until when, and whether it is the route's on every host (a 429's).
    func hold(_ route: String, host: URL, now: Date) -> (until: Date, wholeRoute: Bool)? {
        state.withLock { s -> (until: Date, wholeRoute: Bool)? in
            if let t = s.routes[route], t > now { return (t, true) }
            if let t = s.hosts[route + " " + host.absoluteString], t > now { return (t, false) }
            return nil
        }
    }

    /// An answer of `host` for `route` (`body`: its body, for a 429's `error`).
    func note(_ route: String, host: URL, status: Int, retryAfter header: String?, body: Data = Data(), now: Date) {
        guard status == 429 || (status == 503 && LeaseRetry.retryAfter(header) > 0) else { return }
        let ra = LeaseRetry.retryAfter(header)
        let code = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? String
        state.withLock { s in
            s.lastCode["\(status) \(route)"] = code
            if status == 429 {
                s.last429[route] = ra
                if ra > 0 { s.routes[route] = max(s.routes[route] ?? now, now.addingTimeInterval(TimeInterval(ra))) }
            } else {
                let key = route + " " + host.absoluteString
                s.hosts[key] = max(s.hosts[key] ?? now, now.addingTimeInterval(TimeInterval(ra)))
            }
            // kept for the next process (item 3), in the lock so the last answer is the one on disk
            file?.write(s.readBack(now: now))
        }
    }

    /// The `Retry-After` of the last 429 `route` got, seconds; nil when it named none (or there was none).
    func lastRetryAfter(_ route: String) -> Int? {
        state.withLock { s -> Int? in s.last429[route].flatMap { $0 > 0 ? $0 : nil } }
    }

    /// The `error` of the last 429 (or 503 with a `Retry-After`) of `route`: its held requests answer with it.
    func lastCode(_ route: String, status: Int = 429) -> String {
        state.withLock { $0.lastCode["\(status) \(route)"] } ?? (status == 429 ? "rate_limited" : "unavailable")
    }

    /// The message of an answer the SDK made for a held request, without asking (`heldAnswer`, and a model file's
    /// held 429 in `HTTPClient.stream`).
    static let heldMessage = "waiting for the server's Retry-After"

    /// The holds as they are now (tests).
    var snapshot: Holds { state.withLock { $0 } }

    /// The answer a held request gets without asking: the hold's status (429 for a route's hold, 503 for a host's) with
    /// the `error` of the route's last answer of that status and the seconds left as its `Retry-After`.
    static func heldAnswer(until: Date, now: Date, wholeRoute: Bool, code: String = "rate_limited") -> HTTPClient.Response {
        let left = max(1, Int(until.timeIntervalSince(now).rounded(.up)))
        let body = (try? JSONSerialization.data(withJSONObject: ["error": code, "message": heldMessage])) ?? Data()
        return HTTPClient.Response(status: wholeRoute ? 429 : 503,
                                   headers: ["Retry-After": String(left), "content-type": "application/json"], body: body)
    }
}

/// Contract 28.11 item 4: optional traffic, the routes that can wait (`events`, telemetry; `issues`, error reports and
/// issues; `uploads`, shared recordings and their PUTs). After a 429 on one of them what it was sending is kept and its
/// next attempt waits the larger of the answer's `Retry-After` (300 s when it named none) and its own next send point;
/// the wait doubles at each 429 in a row on that route, up to 3600 s (never shorter than a `Retry-After`). An accepted
/// answer ends the row. Nothing is dropped for it: the queues keep their own limits. Item 3: the rows are kept in
/// `cloud/slow-down.json` and read back at the next start (a wait more than 21600 s ahead ends then). Tried before (to
/// 4.0.1): telemetry retried after 1 and 10 minutes, then at its next send point; error reports and issues at their next
/// send point; uploads after the outbox's 30 s doubling.
final class SlowDownRows: Sendable {
    struct Row: Sendable, Equatable, Codable {
        var count = 0
        var wait: TimeInterval = 0
        var until: Date?
    }
    static let routes: Set<String> = ["events", "issues", "uploads"]
    private let rows: Locked<[String: Row]>
    private let file: JSONFile<[String: Row]>?

    /// `file`: where the rows are kept across restarts (nil: in the process only).
    init(file: URL? = nil, now: Date = Date()) {
        let f = file.map { JSONFile<[String: Row]>(url: $0) }
        self.file = f
        var kept = f?.read().takingUnreadableAsMissing ?? [:]
        for (k, r) in kept { if let t = r.until, t > now.addingTimeInterval(21_600) { kept[k]?.until = now } }
        rows = Locked(kept)
    }

    /// Whether `route` may send now.
    func allows(_ route: String, now: Date) -> Bool {
        rows.withLock { r in r[route]?.until.map { now >= $0 } ?? true }
    }

    /// A 429 on `route` (`retryAfter` its seconds, nil none): the wait of this one in the row.
    @discardableResult
    func slowed(_ route: String, retryAfter: Int?, now: Date) -> TimeInterval {
        rows.withLock { (r: inout [String: Row]) -> TimeInterval in
            var row = r[route] ?? Row()
            row.count += 1
            let named = retryAfter.map { TimeInterval($0) }
            let base = named ?? 300
            let doubled = row.count == 1 ? base : max(base, row.wait * 2)
            row.wait = max(named ?? 0, min(3600, doubled))
            row.until = now.addingTimeInterval(row.wait)
            r[route] = row
            file?.write(r)
            return row.wait
        }
    }

    /// An accepted answer on `route`: its row ends.
    func accepted(_ route: String) {
        rows.withLock { r in
            guard r.removeValue(forKey: route) != nil else { return }
            if r.isEmpty { file?.delete() } else { file?.write(r) }
        }
    }

    func row(_ route: String) -> Row? { rows.withLock { $0[route] } }
}
