import Foundation

// Downloads that survive the app (SDK 4.0.5, contract section 38, `sdk_4.0.0/CONTINUITY_40.md`): the rules, pure (no
// clock, no I/O, Foundation only), one to one with the contract's reference `tools/continuity40.py`, so the vectors
// (`continuity_40.json`) replay them as they are. The SDK's owed records, the resume at the Client's start, the
// hand-over to the background session and the counts are in OwedDownloads.swift, Cloud.swift and
// BackgroundDownloads.swift; they follow these rules.

enum ContinuityRules {
    static let mib = 1024 * 1024
    /// 38.4: an iOS background task takes at most this (16.7 item 3).
    static let piece = 64 * mib
    /// 38.5: a task the system kept must bring a byte within this of the Client's start.
    static let probeMs = 2000
    /// 16.2: no byte for this long ends a request (a kept task too).
    static let stallMs = 30_000
    static let resumeMsBounds = [250, 500, 1000, 2000, 5000, 10_000, 30_000, 60_000]
    /// 38.5: the order owed downloads resume in.
    static let kinds = ["first_install", "context", "reference", "update", "accelerator"]
    static let restartWhy = ["validator", "too_long", "hash", "map", "other"]
    static let continued = ["start", "call", "system"]
    static let countMax = 10_000_000

    /// A stretch of a file, [lo, hi).
    struct Span: Sendable, Hashable, Codable {
        var lo: Int
        var hi: Int
        init(_ lo: Int, _ hi: Int) {
            self.lo = lo
            self.hi = hi
        }
    }

    static func merge(_ ranges: [Span]) -> [Span] {
        var out: [Span] = []
        for r in ranges.filter({ $0.hi > $0.lo }).sorted(by: { ($0.lo, $0.hi) < ($1.lo, $1.hi) }) {
            if let last = out.last, r.lo <= last.hi {
                out[out.count - 1].hi = max(last.hi, r.hi)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// [0, size) less the spans in `have`, in byte order.
    static func missing(size: Int, have: [Span]) -> [Span] {
        var out: [Span] = []
        var at = 0
        for r in merge(have) {
            if r.lo > at { out.append(Span(at, r.lo)) }
            at = max(at, r.hi)
        }
        if at < size { out.append(Span(at, size)) }
        return out
    }

    static func total(_ ranges: [Span]) -> Int { merge(ranges).reduce(0) { $0 + $1.hi - $1.lo } }

    /// 38.4: a stretch cut into pieces of at most `piece` bytes.
    static func pieces(_ lo: Int, _ hi: Int, piece: Int = piece) -> [Span] {
        var out: [Span] = []
        var at = lo
        while at < hi {
            out.append(Span(at, min(hi, at + piece)))
            at = out[out.count - 1].hi
        }
        return out
    }

    /// What a partial file's kept bytes were validated by: the ETag, the host that gave it, and the byte it ends at.
    struct Validator: Sendable, Hashable, Codable {
        var etag: String
        var host: String
        var end: Int
    }

    /// One model request of 16.2 and 16.7.
    struct Request: Sendable, Hashable {
        var path: String
        var host: String
        /// nil: the whole file, no Range.
        var range: String?
        var ifRange: String?
    }

    /// An open-ended Range when it runs to the end, else a bounded one; none for the whole file. If-Range with the
    /// validator only for the open-ended resume of a single partial file (it goes on from the bytes the validator
    /// names, to the end), and only to the host that gave it; stored ranges and bounded stretches send the Range alone
    /// (16.2: the size and the SHA-256 decide).
    static func request(path: String, lo: Int, hi: Int, size: Int, host: String, validator: Validator?) -> Request {
        var range: String? = hi == size ? "bytes=\(lo)-" : "bytes=\(lo)-\(hi - 1)"
        if lo == 0 && hi == size { range = nil }
        var ifRange: String?
        if let v = validator, v.host == host, range != nil, lo == v.end, hi == size { ifRange = v.etag }
        return Request(path: path, host: host, range: range, ifRange: ifRange)
    }

    // MARK: 38.4

    struct LeaveFile: Sendable, Equatable {
        var path: String
        var size: Int
        var have: [Span] = []
        var validator: Validator?
        /// The app's request in flight: its host and the byte it is at.
        var running: (host: String, at: Int)?

        static func == (a: LeaveFile, b: LeaveFile) -> Bool {
            a.path == b.path && a.size == b.size && a.have == b.have && a.validator == b.validator
                && a.running?.host == b.running?.host && a.running?.at == b.running?.at
        }
    }

    enum LeaveAction: Sendable, Equatable {
        case cancelRequest(path: String, at: Int)
        /// A background task (iOS).
        case task(Request)
        /// Android's work: KEEP, expedited, the network it needs.
        case work(policy: String, expedited: Bool, network: String)
        /// The web frame writes an unfinished block.
        case flush(path: String, at: Int)
        case count(String, Int)
    }

    /// 38.4: the app leaves with downloads in flight, `downloads` each a kind's files. `p`: the host of the order's
    /// first place.
    static func leave(platform: String, apiLevel: Int = 0, p: String, downloads: [(kind: String, files: [LeaveFile])]) -> [LeaveAction] {
        var out: [LeaveAction] = []
        switch platform {
        case "apple":
            for d in downloads {
                var handed = false
                for f in d.files {
                    if let run = f.running { out.append(.cancelRequest(path: f.path, at: run.at)) }
                    for gap in missing(size: f.size, have: f.have) {
                        for s in pieces(gap.lo, gap.hi) {
                            out.append(.task(request(path: f.path, lo: s.lo, hi: s.hi, size: f.size, host: p, validator: f.validator)))
                            handed = true
                        }
                    }
                }
                if handed { out.append(.count("handed", 1)) }
            }
        case "android":
            if downloads.contains(where: { $0.files.contains { !missing(size: $0.size, have: $0.have).isEmpty } }) {
                out.append(.work(policy: "keep", expedited: apiLevel >= 31, network: "connected"))
                out.append(.count("handed", 1))
            }
        case "web":
            for d in downloads {
                for f in d.files { if let run = f.running { out.append(.flush(path: f.path, at: run.at)) } }
            }
        default:
            break
        }
        return out
    }

    // MARK: 38.5

    /// A task of the background session for a stretch of a file.
    struct KeptTask: Sendable, Hashable {
        var lo: Int
        var hi: Int
        /// `running`, `done`, `failed` or `cancelled`.
        var state: String
        /// done: its file is exactly its range.
        var exact = true
        /// running: it brought a byte within `probeMs`.
        var delivered = false
    }

    struct RelaunchFile: Sendable, Hashable {
        var path: String
        var size: Int
        var have: [Span] = []
        var validator: Validator?
        /// A whole file arriving beside the partial file for a changed validator: its bytes, ETag and host.
        var beside: Validator?
        /// Stored ranges' map readable.
        var mapOK = true
        /// A file at full size: its SHA-256 once checked, `ok` or `bad`; nil when not checked.
        var full: String?
        var tasks: [KeptTask] = []
    }

    struct Owed: Sendable, Hashable {
        var build: String
        var context: String
        var kind: String
        /// `app` or `sdk`.
        var by: String
        /// `record`, or `left_by_404` (a download an earlier SDK left).
        var source = "record"
        var files: [RelaunchFile]
    }

    struct RelaunchState: Sendable {
        var platform = "apple"
        /// 15.3: a removal owed or a refusal held.
        var stop = false
        /// `valid`, `stale` or `none`.
        var token = "valid"
        /// `up` or `none`.
        var network = "up"
        /// `held` when a lease in force names the build's folder.
        var lease = "held"
        /// The config in force (from disk): the build of each context, and P.
        var builds: [String: String] = [:]
        var p: String
        var owed: [Owed] = []
    }

    enum Action: Sendable, Hashable {
        case removeModels
        case dropOwed(String, why: String?)
        case waitNetwork
        case token(String)
        case lease(String)
        case owe(build: String, kind: String)
        case manifest(String)
        case takeBeside(String)
        case restart(String, why: String)
        case adopt(String, lo: Int, hi: Int)
        case keepTask(String, lo: Int, hi: Int)
        case cancelTask(String, lo: Int, hi: Int)
        case hash(String)
        case place(String)
        case request(Request)
        case count(String, Int)
    }

    /// 38.5: the Client's start, with what an earlier process left: the actions in order.
    static func relaunch(_ st: RelaunchState) -> [Action] {
        var out: [Action] = []
        if st.stop { return [.removeModels, .dropOwed("all", why: nil)] }
        let owed = st.owed.enumerated().sorted {
            let a = ($0.element.by == "app" ? 0 : 1, kinds.firstIndex(of: $0.element.kind) ?? kinds.count, $0.offset)
            let b = ($1.element.by == "app" ? 0 : 1, kinds.firstIndex(of: $1.element.kind) ?? kinds.count, $1.offset)
            return a < b
        }.map { $0.element }
        if owed.isEmpty { return out }
        if st.network == "none" { out.append(.waitNetwork) }
        out.append(.token(st.token == "valid" ? "stored" : "attest"))
        if st.lease != "held" { out.append(.lease("beside")) }
        let p = st.p
        for d in owed {
            if d.kind != "accelerator", let want = st.builds[d.context], want != d.build {
                out.append(.dropOwed(d.build, why: "superseded"))
                if d.by == "app" {
                    out.append(.owe(build: want, kind: d.kind))
                    out.append(.manifest(want))
                }
                continue
            }
            var kept = 0
            var restarted: [String: Int] = [:]
            for f in d.files {
                var have = f.have
                var val = f.validator
                if let b = f.beside {
                    // a whole file was arriving for a changed validator: the old bytes are of a file that changed; the
                    // arriving ones are kept with their own validator and go on
                    out.append(.takeBeside(f.path))
                    have = [Span(0, b.end)]
                    val = Validator(etag: b.etag, host: b.host, end: b.end)
                    restarted["validator", default: 0] += 1
                }
                if !f.mapOK {
                    out.append(.restart(f.path, why: "map"))
                    restarted["map", default: 0] += 1
                    have = []
                    val = nil
                } else if let last = merge(have).last, last.hi > f.size {
                    out.append(.restart(f.path, why: "too_long"))
                    restarted["too_long", default: 0] += 1
                    have = []
                    val = nil
                }
                var keep: [Span] = []
                for t in f.tasks {
                    if t.state == "done" && t.exact {
                        out.append(.adopt(f.path, lo: t.lo, hi: t.hi))
                        have.append(Span(t.lo, t.hi))
                    } else if t.state == "running" && t.delivered {
                        out.append(.keepTask(f.path, lo: t.lo, hi: t.hi))
                        keep.append(Span(t.lo, t.hi))
                    } else if t.state == "running" {
                        out.append(.cancelTask(f.path, lo: t.lo, hi: t.hi))
                    }
                }
                kept += total(have)
                let gaps = missing(size: f.size, have: have + keep)
                if gaps.isEmpty && keep.isEmpty {
                    if f.full == "bad" {
                        out.append(.hash(f.path))
                        out.append(.restart(f.path, why: "hash"))
                        restarted["hash", default: 0] += 1
                        kept -= total(have)
                        out.append(.request(request(path: f.path, lo: 0, hi: f.size, size: f.size, host: p, validator: nil)))
                    } else if f.full == "ok" {
                        out.append(.place(f.path))
                    } else {
                        out.append(.hash(f.path))
                    }
                    continue
                }
                for g in gaps { out.append(.request(request(path: f.path, lo: g.lo, hi: g.hi, size: f.size, host: p, validator: val))) }
            }
            if kept > 0 {
                out.append(.count("continued.start", 1))
                out.append(.count("resumed_kb", kept / 1000))
            }
            for why in restartWhy { if let n = restarted[why], n > 0 { out.append(.count("restarted." + why, n)) } }
        }
        return out
    }

    // MARK: 38.6

    /// The first answer of a resumed request: `go_on`, `failed_attempt`, `beside` or `restart`, and when kept bytes
    /// are dropped, why. `from`: the byte the request starts at; `ifRange`: it sent If-Range; `single`: one partial
    /// file appended to (not stored ranges). `start`, `end`, `total`, `length`: a 206's Content-Range and
    /// Content-Length, a 200's Content-Length.
    static func firstAnswer(size: Int, from: Int, ifRange: Bool, single: Bool,
                            status: Int, start: Int? = nil, end: Int? = nil, total: Int? = nil, length: Int? = nil) -> (action: String, restarted: String?) {
        switch status {
        case 206:
            if start == from && total == size && end == size - 1 && length == size - from { return ("go_on", nil) }
            // 16.1: not the range; the kept bytes stay, the next host
            return ("failed_attempt", nil)
        case 200:
            if let l = length, l != size { return ("failed_attempt", nil) }
            // the whole file, written beside the kept bytes; it takes their place only when all of it has arrived
            return ("beside", ifRange ? "validator" : "other")
        case 416:
            // 16.1: the kept bytes run past the server's file; stored ranges: a 416 says nothing about the others
            return single ? ("restart", "too_long") : ("failed_attempt", nil)
        default:
            return ("failed_attempt", nil)
        }
    }

    /// 38.6 and 18.4.1 step 4 (amended for SDK 4.0.5): what a lease answer does to kept bytes fetched from the owed
    /// record's folder before an answer named it (`confirmed` false), or after one did. `answer`: `same_folder`,
    /// `other_folder`, `no_folder`, `refused`, `stop`, `unreachable`.
    static func leaseAnswer(confirmed: Bool, answer: String) -> [String] {
        if answer == "stop" { return ["remove_models"] }
        if answer == "same_folder" { return ["confirm"] }
        // from 4.0.5: kept, still unconfirmed, asked again
        if answer == "unreachable" { return ["keep"] }
        // a folder an answer already named stays named
        if confirmed { return ["keep"] }
        if answer == "other_folder" { return ["drop_unconfirmed", "refetch_from_answer"] }
        return ["drop_unconfirmed"]
    }

    /// 38.3: whether the owed record stays when a download stops this way: removed only by the download's end ready,
    /// the app's removal of the model files, and a refusal that stops the model.
    static func recordAfter(_ how: String) -> String { ["ready", "remove_models", "stop"].contains(how) ? "remove" : "keep" }

    // MARK: 38.8

    /// The first continuity field of a `downloads` entry the server refuses, or nil (`e` as JSONSerialization reads it).
    static func downloadsProblem(_ e: [String: Any]) -> String? {
        for k in ["resumed_kb", "handed"] { if let v = e[k], count(v) == nil { return k } }
        var resume: [Int] = []
        if let v = e["resume_ms"] {
            guard let a = v as? [Any], a.count == resumeMsBounds.count + 1 else { return "resume_ms" }
            for x in a {
                guard let n = count(x) else { return "resume_ms" }
                resume.append(n)
            }
        }
        var maps: [String: [String: Int]] = [:]
        for (field, keys) in [("continued", continued), ("restarted", restartWhy)] {
            guard let v = e[field] else { continue }
            guard let o = v as? [String: Any] else { return field }
            var m: [String: Int] = [:]
            for k in o.keys.sorted() {
                guard keys.contains(k), let n = count(o[k]!) else { return "\(field).\(k)" }
                m[k] = n
            }
            maps[field] = m
        }
        if resume.reduce(0, +) > (maps["continued"]?["start"] ?? 0) { return "resume_ms" }
        if let kb = e["resumed_kb"].flatMap(count), kb > 0, (maps["continued"]?.values.reduce(0, +) ?? 0) == 0 { return "resumed_kb" }
        return nil
    }

    /// 38.8: the bucket of `resume_ms` a time falls in (9 counts).
    static func resumeBucket(ms: Int) -> Int {
        for (i, b) in resumeMsBounds.enumerated() where ms < b { return i }
        return resumeMsBounds.count
    }

    /// A JSON integer from 0 to `countMax` (not a boolean).
    static func count(_ v: Any) -> Int? {
        guard let d = LiveRules.number(v), d.isFinite, d == d.rounded(), d >= 0, d <= Double(countMax) else { return nil }
        return Int(d)
    }
}
