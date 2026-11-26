import Foundation

/// The hosts of each role for one Client, and the sticky host of each (28.2, 28.3): `P`, at first the role's first
/// host, and the time it became preferred. In memory for the process; nothing of it is stored.
/// SDK 4.0.5 (SPLIT_40 35.8, 28.3 item 5): the `models` role's P is kept per connection type (`wifi`, `cellular`, `wired`,
/// `other`; never a network's name), and stored with the identity of the config in force (`pFile`): a start reads it back
/// only while that same config is in force, and only for 24 hours. The probe back of 28.3 item 1 (30 minutes) is
/// unchanged, so a stored P that is not the first host is asked after the first host once its 30 minutes are over.
final class EndpointSet: @unchecked Sendable {
    /// The last request of this process that found its first host unreachable (28.7 `lastFailover`).
    struct Failover: Sendable, Equatable {
        let role: EndpointRole
        let from: String
        /// The host that answered; nil when none did.
        let to: String?
        /// The first host's 24.3 reason: `network`, `timeout`, `http`, `redirect` or `invalid_answer`.
        let reason: String
        let status: Int?
        /// Unix seconds.
        let at: Int64
        /// SDK 4.0.5 (ATTEST_40.md 40.5): the check the first host's 2xx failed, when `reason` is `invalid_answer`.
        var check: String? = nil
    }

    private struct State {
        var builtIn: [URL]
        var hosts: [URL]
        var p: URL
        var since: Date?
    }

    private let lock = NSLock()
    private var states: [EndpointRole: State] = [:]
    private var last: Failover?
    let clock: @Sendable () -> Date
    /// The signed config in force when a request starts, and its `endpoints` (28.2: a config's hosts live only while
    /// it is in force). Nil: none is.
    private let config: @Sendable () -> JSONValue??
    /// Told each request that found its first host unreachable, with the 24.3 stage of the request when it has one
    /// (the Client's silent `failover` report, 28.7).
    let onFailover = Locked<(@Sendable (Failover, _ stage: String?) -> Void)?>(nil)
    /// SDK 4.0.2 (28.11 items 2 and 3): the `Retry-After` holds of each route and host, kept across restarts.
    let holds: RetryAfterHolds
    /// SDK 4.0.5: the connection type now, the `models` P of each type and its time, where they are stored, and the
    /// identity of the config in force they are stored with.
    private let connection: @Sendable () -> String
    private var typed: [String: (p: URL, since: Date?)] = [:]
    private var typedRead = false
    private let pFile: URL?
    private let configIdentity: @Sendable () -> String?
    /// How long a stored P is read back at a start (the task of 2026-11-23; 35.8 binds it to the config in force).
    static let pKeptFor: TimeInterval = 24 * 3600

    /// `api` and `models` are the roles' hosts as origins (`https://<host>`; a test build's may name another scheme
    /// or a port), in order. `config` gives the `endpoints` of the config in force (`.some(nil)` for a config that
    /// names none), or nil when no config is in force.
    /// `holdsFile`: where the `Retry-After` holds are kept across restarts (nil: in the process only).
    init(api: [URL], models: [URL], config: @escaping @Sendable () -> JSONValue?? = { nil },
         clock: @escaping @Sendable () -> Date = { Date() }, holdsFile: URL? = nil,
         connection: @escaping @Sendable () -> String = { NetworkType.now }, pFile: URL? = nil,
         configIdentity: @escaping @Sendable () -> String? = { nil }) {
        self.config = config
        self.clock = clock
        self.connection = connection
        self.pFile = pFile
        self.configIdentity = configIdentity
        holds = RetryAfterHolds(file: holdsFile, now: clock())
        for (role, list) in [(EndpointRole.api, api), (.models, models)] {
            let origins = list.compactMap { Endpoints.origin(of: $0) }
            if let first = origins.first { states[role] = State(builtIn: origins, hosts: origins, p: first, since: nil) }
        }
    }

    /// The production hosts of 28.1.
    static func builtInOrigins(_ role: EndpointRole) -> [URL] { (Endpoints.builtIn[role] ?? []).map(Endpoints.origin) }

    /// The role's list now: the config's while one is in force and names one, else the built-in list. A list that
    /// changes starts again at its first host (28.3 item 5). Under the lock.
    private func refreshed(_ role: EndpointRole) -> State? {
        guard var s = states[role] else { return nil }
        var list = s.builtIn
        if case .some(let endpoints) = config() {
            let names = Endpoints.roleList(role, endpoints: endpoints, inForce: true, builtIn: [])
            if !names.isEmpty { list = names.map(Endpoints.origin) }
        }
        if list != s.hosts {
            s.hosts = list
            s.p = list[0]
            s.since = nil
            states[role] = s
            if role == .models, typedRead {
                typed = [:]
                storeTyped()
            }
        }
        // SDK 4.0.5 (35.8): the models P of the connection type now
        if role == .models {
            readTyped()
            if let t = typed[connection()], s.hosts.contains(t.p) {
                s.p = t.p
                s.since = t.since
            } else {
                s.p = s.hosts[0]
                s.since = nil
            }
            states[role] = s
        }
        return s
    }

    private struct StoredP: Codable {
        struct Entry: Codable {
            let p: String
            let since: Double?
            let at: Double
        }
        let config: String
        let types: [String: Entry]
    }

    /// The stored P of each connection type, once: only those stored with the config in force now, and for 24 hours.
    /// Under the lock.
    private func readTyped() {
        guard !typedRead else { return }
        typedRead = true
        guard let pFile, let id = configIdentity(), let d = try? Data(contentsOf: pFile),
              let stored = try? JSONDecoder().decode(StoredP.self, from: d), stored.config == id else { return }
        let now = clock().timeIntervalSince1970
        for (type, e) in stored.types where NetworkType.kinds.contains(type) && now - e.at < Self.pKeptFor && e.at <= now + 60 {
            guard let u = URL(string: e.p), let o = Endpoints.origin(of: u) else { continue }
            typed[type] = (o, e.since.map { Date(timeIntervalSince1970: $0) })
        }
    }

    /// Stores the P of each type with the identity of the config in force (none in force: nothing is stored). Under the
    /// lock.
    private func storeTyped() {
        guard let pFile else { return }
        guard let id = configIdentity() else {
            try? FileManager.default.removeItem(at: pFile)
            return
        }
        let at = clock().timeIntervalSince1970
        let types = typed.mapValues { StoredP.Entry(p: $0.p.absoluteString, since: $0.since?.timeIntervalSince1970, at: at) }
        guard let d = try? JSONEncoder().encode(StoredP(config: id, types: types)) else { return }
        try? FileManager.default.createDirectory(at: pFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: pFile, options: StorageProtection.atomic)
    }

    /// The role whose hosts (built in, or in force) include the origin of `url`: a request made on that origin is the
    /// role's, and goes through its order.
    func role(of url: URL?) -> EndpointRole? {
        guard let url, let o = Endpoints.origin(of: url) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        for role in [EndpointRole.api, .models] {
            guard let s = refreshed(role) else { continue }
            if s.builtIn.contains(o) || s.hosts.contains(o) { return role }
        }
        return nil
    }

    /// Whether `origin` is one of the role's hosts in force: the config's list while one is in force and names one,
    /// else the built-in list (a request on it goes through the role's order and is never asked before it). A lease
    /// folder's host that is not, a built-in host the config's list leaves out included, is asked first (28.4,
    /// contract e330c08; web, Android and C read it so). To 4.0.2 a built-in host counted whatever the list said.
    func isRoleHost(_ role: EndpointRole, _ origin: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let s = refreshed(role) else { return false }
        return s.hosts.contains(origin)
    }

    /// The hosts a request of `role` starting at `now` asks, in order, and whether it is the probe back (28.3 item 1):
    /// `P` first, then the others in list order; the list in order when `P` is not the first host and has been
    /// preferred for 30 minutes. `first`: a lease base's host that is not one of the role's, asked before them (28.4).
    func order(_ role: EndpointRole, at now: Date, first: URL? = nil) -> (hosts: [URL], probe: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let s = refreshed(role) else { return (first.map { [$0] } ?? [], false) }
        var hosts: [URL], probe = false
        if s.p != s.hosts[0], let since = s.since, now.timeIntervalSince(since) >= Endpoints.probeAfter {
            hosts = s.hosts
            probe = true
        } else {
            hosts = [s.p] + s.hosts.filter { $0 != s.p }
        }
        if let first, !s.hosts.contains(first) { hosts.insert(first, at: 0) }
        return (hosts, probe)
    }

    /// The host whose answer was taken, refused or a slow down becomes `P` (28.3 item 5); its time is now when it was
    /// not `P` already, or when the request was the probe. A host that is not one of the role's changes nothing.
    func settle(_ role: EndpointRole, _ host: URL, at now: Date, probe: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard var s = refreshed(role), s.hosts.contains(host), host != s.p || probe else { return }
        s.p = host
        s.since = host == s.hosts[0] ? nil : now
        states[role] = s
        // SDK 4.0.5 (35.8): the models P is the connection type's, and is stored with the config in force
        if role == .models {
            typed[connection()] = (s.p, s.since)
            storeTyped()
        }
    }

    /// The host the role's next request goes to first (28.7), its name only.
    func preferred(_ role: EndpointRole) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let s = refreshed(role) else { return nil }
        // the probe back is due: the first host is asked first
        let probe = s.p != s.hosts[0] && s.since.map { clock().timeIntervalSince($0) >= Endpoints.probeAfter } == true
        return (probe ? s.hosts[0] : s.p).host
    }

    /// The role's hosts in force, in order (tests, the diagnosis).
    func hosts(_ role: EndpointRole) -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return refreshed(role)?.hosts ?? []
    }

    /// A request found its first host unreachable: kept for `diagnose()`, and told to the Client.
    func failedOver(_ f: Failover, stage: String?) {
        lock.withLock { last = f }
        onFailover.withLock { $0 }?(f, stage)
    }

    var lastFailover: Failover? { lock.withLock { last } }

    /// `diagnose()`'s `endpoints` (28.7, DIAGNOSIS_40 25.3): the host each role's next request goes to first, and the
    /// last failover of this process. Host names only; `webFrame` is the web's alone.
    var diagnosis: TajweedDiagnosis.Endpoints {
        TajweedDiagnosis.Endpoints(api: preferred(.api), models: preferred(.models),
                                   lastFailover: lastFailover.map {
                                       TajweedDiagnosis.Failover(role: $0.role.rawValue, from: $0.from, to: $0.to, reason: $0.reason,
                                                                 status: $0.status, at: $0.at, check: $0.check)
                                   })
    }
}
