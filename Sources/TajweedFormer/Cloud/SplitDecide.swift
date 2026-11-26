import CryptoKit
import Foundation

/// SDK 4.0.5, contract section 35 (`sdk_4.0.0/SPLIT_40.md`): two hosts for one model file. `SplitDecide` is the pure
/// decision function of 35.6: events in, actions out, no I/O and no clock of its own. It is the contract's reference
/// (`tools/split40.py`, `Split`) line for line, and `SplitVectorTests` replays `split_40.json` through it. Every number is
/// an integer: times in ms of the process's monotonic clock, sizes in bytes, rates in bytes a second, ratios times 100;
/// division rounds down (every value is at least 0).
enum SplitConstants {
    static let tickMs = 500
    static let warmupMs = 2000
    static let windowMs = 3000
    static let etaMinMs = 12000
    static let leftMin = 4 << 20
    static let stallMs = 2000
    static let floorBps = 64000
    static let gainMinX100 = 130
    static let stealMin = 2 << 20
    static let stealEtaMinMs = 4000
    static let maxSteals = 2
    static let maxHosts = 2
    static let maxHostChanges = 3
    static let align = 65536
    static let phoneBoundMs = 1_800_000
    /// `gain`'s 6 counts (35.9): under each, and the last and over.
    static let gainBucketsX100 = [110, 130, 150, 200, 400]

    static func gainBucket(_ ratio: Int) -> Int {
        for (i, b) in gainBucketsX100.enumerated() where ratio < b { return i }
        return gainBucketsX100.count
    }
}

/// 35.6's events.
enum SplitEvent: Equatable, Sendable {
    /// The file's own request (no Range, or 16.2's `bytes=lo-`) was taken on `host`.
    case main(t: Int, id: String, host: String, lo: Int)
    /// A range the SDK sent for a `resume` action was taken.
    case req(t: Int, id: String, host: String, lo: Int, end: Int)
    /// `host` was unreachable in this download, or is held by 28.11 for this path (`unreachable`, `held`).
    case hostOut(t: Int, host: String, why: String)
    /// A range of `start` got its status: `taken`, `ignored`, `slow_down`, `refusal`, `unreachable`.
    case status(t: Int, id: String, kind: String)
    case bytes(t: Int, id: String, n: Int)
    case lane(t: Int, host: String, n: Int)
    /// `done` (it reached its end or its cut), `broken`, `cancelled`.
    case end(t: Int, id: String, how: String)
    case tick(t: Int)
    case hash(t: Int, ok: Bool)
}

/// 35.6's actions.
enum SplitAction: Equatable, Sendable {
    /// `GET` with `Range: bytes=lo-(end-1)`, no `If-Range`, to `host`; its bytes go to the file at `lo`.
    case start(id: String, host: String, lo: Int, end: Int)
    /// Request `id` writes nothing at or past `at`; reaching it (or having reached it) cancels the request.
    case cut(id: String, at: Int)
    /// 16.2's resume of that remainder (its pause, the next host of the order), told back as `req`.
    case resume(lo: Int, end: Int)
    case verdict(kind: String, ratio: Int)
    /// `P` becomes `host` for the connection type (28.3 item 5).
    case p(host: String)
    /// Adds `n` to the day's `hosts` entry of `host` (35.9).
    case count(field: String, host: String, n: Int)
    case refused
    /// The file starts again from byte 0 without the hosts marked bad (16.1).
    case restart
}

/// What the process remembers between split files (35.6): the last server-bound winner and the phone-bound hold per
/// connection type, and the hosts that served bad bytes. Never a network's name.
final class SplitMemory: @unchecked Sendable {
    /// The process's memory (35.6: kept by the process, never stored).
    static let process = SplitMemory()

    private let lock = NSLock()
    private var winners: [String: String]
    private var holds: [String: Int]
    private var badHosts: [String]

    init(winner: [String: String] = [:], phoneBoundUntil: [String: Int] = [:], bad: [String] = []) {
        winners = winner
        holds = phoneBoundUntil
        badHosts = bad
    }

    func winner(_ conn: String) -> String? { lock.withLock { winners[conn] } }
    func setWinner(_ conn: String, _ host: String) { lock.withLock { winners[conn] = host } }
    func phoneBoundUntil(_ conn: String) -> Int { lock.withLock { holds[conn] ?? 0 } }
    func setPhoneBoundUntil(_ conn: String, _ t: Int) { lock.withLock { holds[conn] = t } }
    func isBad(_ host: String) -> Bool { lock.withLock { badHosts.contains(host) } }
    func markBad(_ host: String) { lock.withLock { if !badHosts.contains(host) { badHosts.append(host) } } }
    var snapshot: (winner: [String: String], phoneBoundUntil: [String: Int], bad: [String]) {
        lock.withLock { (winners, holds, badHosts) }
    }
}

final class SplitDecide {
    private final class Req {
        let id: String
        let host: String
        let lo: Int
        var stop: Int
        var pos: Int
        var statusT: Int?
        var lastT: Int
        var state = "running"
        var kind: String
        var samples: [(t: Int, pos: Int)] = []
        /// When it ended done.
        var endT: Int?

        init(_ id: String, _ host: String, lo: Int, stop: Int, kind: String, t: Int, statusT: Int? = nil) {
            self.id = id
            self.host = host
            self.lo = lo
            self.stop = stop
            self.pos = lo
            self.kind = kind
            self.statusT = statusT
            self.lastT = statusT ?? t
        }
    }

    typealias C = SplitConstants
    let size: Int
    let order: [String]
    let noHelper: Set<String>
    let shareOn: Bool
    let memory: SplitMemory
    let conn: String

    private var reqs: [String: Req] = [:]
    /// The requests in the order they were made (the reference's dict order).
    private var made: [String] = []
    private var mainID: String?
    private var probeID: String?
    /// single, split, verify, done, over
    private(set) var phase = "single"
    private var hostCum: [String: Int] = [:]
    private var hostSamples: [String: [(t: Int, cum: Int)]] = [:]
    /// host -> why it may not help this file
    private var out: [String: String] = [:]
    private var changes = 0
    private var steals = 0
    /// nil, server_bound, phone_bound, none
    private(set) var verdict: String?
    private var aBefore = 0
    private var would = false
    private var pending: [(lo: Int, end: Int)] = []
    private var pieces: [(lo: Int, end: Int, host: String)] = []
    private var verifyQ: [(lo: Int, end: Int)] = []
    private var verifyHost: String?
    private var verifyBad: Set<String> = []
    /// The id of a finished range whose host waits to steal (35.5 item 6, contract 0db5587).
    private var waiting: String?
    private var n = 0

    init(size: Int, order: [String], noHelper: [String], shareOn: Bool, memory: SplitMemory, conn: String) {
        self.size = size
        self.order = order
        self.noHelper = Set(noHelper)
        self.shareOn = shareOn
        self.memory = memory
        self.conn = conn
    }

    // MARK: helpers

    private func newID() -> String {
        n += 1
        return "s\(n)"
    }

    private func running() -> [Req] { made.compactMap { reqs[$0] }.filter { $0.state == "running" } }

    private static func alignDown(_ x: Int) -> Int { x - x % C.align }
    private static func alignUp(_ x: Int) -> Int {
        let r = x % C.align
        return r == 0 ? x : x + C.align - r
    }

    private func rateHost(_ host: String, _ t: Int, since: Int) -> Int? {
        var best: (t: Int, cum: Int)?
        for s in hostSamples[host] ?? [] where since <= s.t && s.t <= t - C.windowMs { best = s }
        guard let best else { return nil }
        return ((hostCum[host] ?? 0) - best.cum) * 1000 / max(1, t - best.t)
    }

    private func rateReq(_ r: Req, _ t: Int) -> Int {
        let st = r.statusT ?? 0
        var best: (t: Int, pos: Int)?
        for s in r.samples where st + C.warmupMs <= s.t && s.t <= t - C.windowMs { best = s }
        if let best { return (r.pos - best.pos) * 1000 / max(1, t - best.t) }
        return (r.pos - r.lo) * 1000 / max(1, t - st)
    }

    private func pick(avoid: Set<String>) -> String? {
        var cands: [String] = []
        if let w = memory.winner(conn), order.contains(w) { cands.append(w) }
        cands += order.filter { !cands.contains($0) }
        let busy = Set(running().map(\.host))
        for h in cands where !avoid.contains(h) && !busy.contains(h) && !noHelper.contains(h) && out[h] == nil && !memory.isBad(h) {
            return h
        }
        return nil
    }

    @discardableResult
    private func start(_ acts: inout [SplitAction], _ t: Int, _ host: String, _ lo: Int, _ end: Int, _ kind: String) -> String {
        let id = newID()
        reqs[id] = Req(id, host, lo: lo, stop: end, kind: kind, t: t)
        made.append(id)
        acts.append(.start(id: id, host: host, lo: lo, end: end))
        return id
    }

    private func cut(_ acts: inout [SplitAction], _ r: Req, _ at: Int) {
        r.stop = at
        acts.append(.cut(id: r.id, at: at))
    }

    private func count(_ acts: inout [SplitAction], _ field: String, _ host: String, _ n: Int = 1) {
        acts.append(.count(field: field, host: host, n: n))
    }

    private func add(_ id: String, _ r: Req) {
        if reqs[id] == nil { made.append(id) }
        reqs[id] = r
    }

    // MARK: the events

    func event(_ e: SplitEvent) -> [SplitAction] {
        var acts: [SplitAction] = []
        if phase == "done" || phase == "over" {
            guard case .hash = e else { return acts }
        }
        switch e {
        case .main(let t, let id, let host, let lo):
            add(id, Req(id, host, lo: lo, stop: size, kind: "main", t: t, statusT: t))
            mainID = id
            phase = "single"
        case .req(let t, let id, let host, let lo, let end):
            add(id, Req(id, host, lo: lo, stop: end, kind: "resume", t: t, statusT: t))
            if running().filter({ $0.id != id }).isEmpty {
                mainID = id
                phase = "single"
            }
        case .hostOut(_, let host, let why):
            if out[host] == nil { out[host] = why }
        case .lane(_, let host, let n):
            hostCum[host, default: 0] += n
        case .bytes(let t, let id, let n):
            guard let r = reqs[id] else { break }
            r.pos += n
            r.lastT = t
            hostCum[r.host, default: 0] += n
        case .status(let t, let id, let kind):
            guard let r = reqs[id] else { break }
            if kind == "taken" {
                r.statusT = t
                r.lastT = t
                break
            }
            r.state = "failed"
            if kind == "refusal" {
                acts.append(.refused)
                phase = "over"
                break
            }
            if out[r.host] == nil { out[r.host] = ["ignored": "ignored", "slow_down": "held"][kind] ?? "unreachable" }
            lost(&acts, t, r, from: r.lo)
        case .end(let t, let id, let how):
            endEvent(&acts, t, id, how)
        case .tick(let t):
            tick(&acts, t)
        case .hash(let t, let ok):
            hash(&acts, t, ok)
        }
        return acts
    }

    private func drop(_ acts: inout [SplitAction], _ t: Int, _ r: Req) {
        if out[r.host] == nil { out[r.host] = "slow" }
        count(&acts, "slow_switches", r.host)
        r.state = "dropped"
        let end = r.stop
        cut(&acts, r, r.pos)
        lost(&acts, t, r, from: r.pos, end: end)
    }

    private func lost(_ acts: inout [SplitAction], _ t: Int, _ r: Req, from: Int, end: Int? = nil) {
        if r.pos > r.lo { pieces.append((r.lo, r.pos, r.host)) }
        let lo = max(from, r.pos)
        let end = end ?? r.stop
        if lo >= end { return }
        if phase == "split", r.id == probeID {
            let m = mainID.flatMap { reqs[$0] }
            if let m, m.state == "running", lo == m.stop {
                // nothing of the tail was written by the second host: the first goes on to its end
                cut(&acts, m, end)
                phase = "single"
                probeID = nil
                verdict = nil
                return
            }
            if let m, m.state == "running", changes < C.maxHostChanges, let h = pick(avoid: [r.host]) {
                changes += 1
                probeID = start(&acts, t, h, lo, end, "probe")
                count(&acts, "probes", h)
                return
            }
        }
        pending.append((lo, end))
        reassign(&acts, t)
    }

    private func reassign(_ acts: inout [SplitAction], _ t: Int) {
        guard !pending.isEmpty else { return }
        if let w = waiting.flatMap({ reqs[$0] }), !running().contains(where: { $0.host == w.host }) {
            // a host that finished its range and waits to steal takes what went back
            waiting = nil
            let p = pending.removeFirst()
            start(&acts, t, w.host, p.lo, p.end, "move")
            return
        }
        // the host that finishes next takes it (35.5 item 5)
        guard running().isEmpty else { return }
        let p = pending.removeFirst()
        acts.append(.resume(lo: p.lo, end: p.end))
    }

    private func endEvent(_ acts: inout [SplitAction], _ t: Int, _ id: String, _ how: String) {
        guard let r = reqs[id], r.state == "running" else { return }
        if how == "cancelled" {
            r.state = "cancelled"
            phase = "over"
            return
        }
        if how == "broken" {
            r.state = "failed"
            if out[r.host] == nil { out[r.host] = "unreachable" }
            lost(&acts, t, r, from: r.pos)
            return
        }
        if r.pos < r.stop, phase != "verify" {
            // ended short without saying broken: it is broken
            r.state = "failed"
            if out[r.host] == nil { out[r.host] = "unreachable" }
            lost(&acts, t, r, from: r.pos)
            return
        }
        r.state = "done"
        r.endT = t
        if r.pos > r.lo { pieces.append((r.lo, r.pos, r.host)) }
        if phase == "verify" {
            verifyNext(&acts, t)
            return
        }
        if phase == "split", id == probeID, verdict == nil { judge(&acts, t, endOfProbe: true) }
        if r.kind == "move", running().isEmpty, pending.isEmpty { acts.append(.p(host: r.host)) }
        if !pending.isEmpty {
            let p = pending.removeFirst()
            start(&acts, t, r.host, p.lo, p.end, "move")
            return
        }
        steal(&acts, t, r)
    }

    private func steal(_ acts: inout [SplitAction], _ t: Int, _ fin: Req) {
        waiting = nil
        let others = running().filter { $0.host != fin.host }
        guard let o = others.first, verdict != "phone_bound", steals < C.maxSteals else { return }
        let left = o.stop - o.pos
        guard left >= C.stealMin else { return }
        // 35.5 item 6: a range without its status, or still in its warm-up, has no rate that says
        // anything (its bytes may not even be reported yet); the finished host waits, and the steal is decided at the first
        // tick after the warm-up. Until 2026-11-23 such a range read as 0 bytes a second, under the floor, and its whole
        // remainder moved to the host that had just finished, however fast the range was about to be.
        guard let ost = o.statusT, t >= ost + C.warmupMs else {
            waiting = fin.id
            return
        }
        let rs = rateReq(o, t)
        if rs > 0, left * 1000 < C.stealEtaMinMs * rs { return }
        let rf = rateReq(fin, fin.endT ?? t)
        var y: Int
        if rs < C.floorBps {
            y = o.pos
        } else {
            let x = left * rf / (rf + rs)
            y = Self.alignUp(o.stop - x)
            if y <= o.pos { y = o.pos }
            if o.stop - y < C.align { return }
        }
        let end = o.stop
        cut(&acts, o, y)
        if y == o.pos { count(&acts, "slow_switches", o.host) }
        steals += 1
        start(&acts, t, fin.host, y, end, "steal")
    }

    private func judge(_ acts: inout [SplitAction], _ t: Int, endOfProbe: Bool) {
        guard let p = probeID.flatMap({ reqs[$0] }), let a = mainID.flatMap({ reqs[$0] }) else { return }
        let ra: Int, rb: Int
        if endOfProbe {
            let pst = p.statusT ?? t
            rb = (p.pos - p.lo) * 1000 / max(1, t - pst)
            let ast = a.statusT ?? t
            ra = rateHost(a.host, t, since: ast + C.warmupMs) ?? ((a.pos - a.lo) * 1000 / max(1, t - ast))
        } else {
            let since = (p.statusT ?? t) + C.warmupMs
            ra = rateHost(a.host, t, since: since) ?? 0
            rb = rateHost(p.host, t, since: since) ?? 0
        }
        let ratio = min(9999, (ra + rb) * 100 / max(1, aBefore))
        count(&acts, "gain", a.host, C.gainBucket(ratio))
        if ratio >= C.gainMinX100 {
            verdict = "server_bound"
            let faster = rb > ra ? p.host : a.host
            memory.setWinner(conn, faster)
            acts.append(.verdict(kind: "server_bound", ratio: ratio))
            acts.append(.p(host: faster))
        } else {
            verdict = "phone_bound"
            memory.setPhoneBoundUntil(conn, t + C.phoneBoundMs)
            acts.append(.verdict(kind: "phone_bound", ratio: ratio))
        }
    }

    private func tick(_ acts: inout [SplitAction], _ t: Int) {
        for (h, cum) in hostCum {
            var s = hostSamples[h] ?? []
            s.append((t, cum))
            while s.count > 2, s[1].t <= t - C.windowMs - C.tickMs { s.removeFirst() }
            hostSamples[h] = s
        }
        for r in running() where r.statusT != nil {
            r.samples.append((t, r.pos))
            while r.samples.count > 2, r.samples[1].t <= t - C.windowMs - C.tickMs { r.samples.removeFirst() }
        }
        if phase == "single" {
            trigger(&acts, t)
        } else if phase == "split" {
            for r in running().sorted(by: { $0.id < $1.id }) {
                if let st = r.statusT, t >= st + C.warmupMs, t - r.lastT >= C.stallMs, r.pos < r.stop,
                   !running().filter({ $0.id != r.id }).isEmpty {
                    drop(&acts, t, r)
                }
            }
            if phase == "split", let p = probeID.flatMap({ reqs[$0] }), p.state == "running", let st = p.statusT, verdict == nil,
               t >= st + C.warmupMs + C.windowMs {
                judge(&acts, t, endOfProbe: false)
            }
            reassign(&acts, t)
            if phase == "split", let w = waiting.flatMap({ reqs[$0] }), !running().contains(where: { $0.host == w.host }) {
                steal(&acts, t, w)
            }
        }
    }

    private func trigger(_ acts: inout [SplitAction], _ t: Int) {
        guard let m = mainID.flatMap({ reqs[$0] }), m.state == "running", let st = m.statusT else { return }
        let left = size - m.pos
        if left < C.leftMin || t < st + C.warmupMs { return }
        var why: String?
        var r = 0
        if t - m.lastT >= C.stallMs {
            why = "stall"
        } else if t >= st + C.warmupMs + C.windowMs {
            guard let rate = rateHost(m.host, t, since: st + C.warmupMs) else { return }
            r = rate
            if rate < C.floorBps {
                why = "floor"
            } else if left * 1000 >= C.etaMinMs * rate {
                why = "eta"
            }
        }
        guard let why else { return }
        if !would {
            would = true
            count(&acts, "would_probe", m.host)
        }
        guard shareOn, memory.phoneBoundUntil(conn) <= t, changes < C.maxHostChanges, let b = pick(avoid: [m.host]) else { return }
        changes += 1
        if why == "eta" {
            let mid = Self.alignDown(m.pos + left / 2)
            aBefore = r
            cut(&acts, m, mid)
            probeID = start(&acts, t, b, mid, size, "probe")
            count(&acts, "probes", b)
            phase = "split"
        } else {
            // 34.5's cut: this host is left for slowness, the file goes on from its byte on the next
            if out[m.host] == nil { out[m.host] = "slow" }
            count(&acts, "slow_switches", m.host)
            let at = m.pos
            cut(&acts, m, at)
            mainID = start(&acts, t, b, at, size, "move")
        }
    }

    private func hash(_ acts: inout [SplitAction], _ t: Int, _ ok: Bool) {
        if ok {
            if phase == "verify" {
                for h in verifyBad.sorted() {
                    count(&acts, "bad_body", h)
                    memory.markBad(h)
                }
            }
            phase = "done"
            return
        }
        // per host, in the order the pieces were written (the reference's dict order)
        var hostOrder: [String] = []
        var bytes: [String: Int] = [:]
        for p in pieces {
            if bytes[p.host] == nil { hostOrder.append(p.host) }
            bytes[p.host, default: 0] += p.end - p.lo
        }
        if phase == "verify" || hostOrder.count < 2 {
            let bad = phase == "verify" ? verifyHost : hostOrder.first
            if let bad {
                count(&acts, "bad_body", bad)
                memory.markBad(bad)
            }
            acts.append(.restart)
            phase = "over"
            return
        }
        // 35.7 item 3: ask the host that brought the most bytes for the others' ranges
        let first = pieces[0].host
        var maj = hostOrder[0]
        for h in hostOrder.dropFirst() {
            let a = (bytes[h] ?? 0, h == first ? 1 : 0), b = (bytes[maj] ?? 0, maj == first ? 1 : 0)
            if a > b { maj = h }
        }
        verifyHost = maj
        verifyBad = Set(hostOrder).subtracting([maj])
        verifyQ = pieces.filter { $0.host != maj }.map { ($0.lo, $0.end) }.sorted { ($0.lo, $0.end) < ($1.lo, $1.end) }
        phase = "verify"
        verifyNext(&acts, t)
    }

    private func verifyNext(_ acts: inout [SplitAction], _ t: Int) {
        guard !verifyQ.isEmpty, let h = verifyHost else { return }
        let q = verifyQ.removeFirst()
        start(&acts, t, h, q.lo, q.end, "refetch")
    }
}

/// SDK 4.0.5: the signed config's `flags.download_split`. `share`: 0 to 100, the share of downloads that
/// act (every other download only counts its triggers); anything else 0. `noHelper`: hosts never used as the second host
/// (the providers billed per byte), allow-listed (28.1), lower case, each once; an entry off the allow-list is dropped.
struct DownloadSplit: Codable, Sendable, Equatable {
    var share = 0
    var no_helper: [String] = []

    init() {}

    init(_ v: JSONValue) {
        guard let o = v.object else { return }
        if let n = o["share"]?.number, n == n.rounded(), n >= 0, n <= 100 { share = Int(n) }
        var seen: [String] = []
        if case .array(let a)? = o["no_helper"] {
            for case .string(let h) in a where Endpoints.hostAllowed(h) {
                let l = h.lowercased()
                if !seen.contains(l) { seen.append(l) }
            }
        }
        no_helper = seen
    }

    /// Whether a download of this install on `day` (UTC, `YYYY-MM-DD`) is in the share: the first byte of SHA-256 of the
    /// install's random value (16 bytes, kept on the device, never sent) and the day, under `share * 256 / 100`.
    func inShare(seed: Data, day: String) -> Bool {
        guard share > 0 else { return false }
        let digest = SHA256.hash(data: seed + Data(day.utf8))
        return Int(Array(digest)[0]) < share * 256 / 100
    }
}
