import Foundation

// Accelerator incidents as issue reports (the platform client doc, section 7.1): `accelerator_failover` (a session
// switched to the CPU engine) and `promotion_failed` (the background pipeline failed at download, compile, warm-up or
// golden). The section 7 body, `code` = `<stage>:<cause>`, the error's message with paths, URLs and long digit runs
// replaced by `_`, and a closed `detail` object. Never audio, transcript or token text, user, install or contributor
// ids, or the app's strings.
//
// Rate: one report per signature (kind, code, revision) per UTC day per install, and only while the signed config's
// `flags.issues` allows, except the FIRST report of each kind per install per model revision, which is always sent:
// it is kept on the device until the server accepts it (a 400 from a server that does not know the kinds yet drops it,
// and the next incident of that kind is again a first).

/// The closed `detail` object of an incident report.
struct IncidentDetail: Codable, Equatable, Sendable {
    var stage: String
    var cause: String
    var errorDomain: String?
    var errorCode: String?
    var chunk: Int?
    var elapsedMs: Double?
    var deadlineMs: Double?
    var clip: String?
    var divergence: Divergence?
    var deviceModel: String?
    var osBuild: String?
    var chip: String?
    var accelerator: String?
    var computeUnits: String?
    var context: String?
    var thermal: String?
    var lowPower: Bool?
    var stallMs: Int?
    var attempt: Int?

    enum CodingKeys: String, CodingKey {
        case stage, cause, chunk, clip, divergence, chip, accelerator, context, thermal, attempt
        case errorDomain = "error_domain", errorCode = "error_code", elapsedMs = "elapsed_ms", deadlineMs = "deadline_ms"
        case deviceModel = "device_model", osBuild = "os_build", computeUnits = "compute_units", lowPower = "low_power"
        case stallMs = "stall_ms"
    }
}

enum IncidentText {
    /// The error's message for a report: URLs, paths and runs of 5 or more digits replaced by `_`, at most 200
    /// characters; nil when nothing is left.
    static func strip(_ s: String?) -> String? {
        guard var t = s else { return nil }
        for pattern in [#"[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>]+"#, #"(?<![A-Za-z0-9_])(?:~|\.{1,2})?/[^\s"'<>]+"#, #"[0-9]{5,}"#] {
            t = t.replacingOccurrences(of: pattern, with: "_", options: .regularExpression)
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return String(t.prefix(200))
    }

    /// Only the characters in `allowed` (ASCII letters and digits, plus `extra`), at most `max`; nil when empty.
    static func token(_ s: String?, extra: String, max: Int) -> String? {
        guard let s else { return nil }
        let t = String(s.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || extra.unicodeScalars.contains($0)) }
            .map(Character.init).prefix(max))
        return t.isEmpty ? nil : t
    }
}

/// The first-per-revision reports waiting for the server, the kinds and revisions it accepted, and the daily dedupe.
final class IncidentLedger: Sendable {
    struct State: Codable {
        /// "kind|revision" the server accepted a report for.
        var accepted: [String] = []
        /// First reports not accepted yet.
        var pending: [IssueReport] = []
        /// Signature -> the UTC day a report with it was queued.
        var queued: [String: String] = [:]
    }

    private let file: JSONFile<State>
    private let state: Locked<State>

    init(storage: URL) {
        file = JSONFile(url: storage.appendingPathComponent("cloud/incidents.json"))
        state = Locked(file.read() ?? State())
    }

    var pending: [IssueReport] { state.withLock { $0.pending } }

    /// Whether a report of `kind` for `revision` would be the first (none accepted, none waiting).
    func isFirst(kind: String, revision: String) -> Bool {
        let k = kind + "|" + revision
        return state.withLock { s in !s.accepted.contains(k) && !s.pending.contains { $0.kind == kind && $0.revision == revision } }
    }

    /// Keeps a first report until the server accepts it.
    func addFirst(_ r: IssueReport) {
        let snapshot = state.withLock { s -> State in
            s.pending.append(r)
            if s.pending.count > 16 { s.pending.removeFirst(s.pending.count - 16) }
            return s
        }
        file.write(snapshot)
    }

    /// True when no report with `signature` was queued today (and notes this one).
    func allowToday(_ signature: String, day: String) -> Bool {
        let (ok, snapshot) = state.withLock { s -> (Bool, State) in
            s.queued = s.queued.filter { $0.value == day }
            if s.queued[signature] != nil { return (false, s) }
            s.queued[signature] = day
            return (true, s)
        }
        if ok { file.write(snapshot) }
        return ok
    }

    /// Sends the waiting first reports: accepted ones are noted, refused ones (4xx) dropped, the rest kept.
    func flush(send: (Data) async throws(CloudError) -> Void) async -> Int {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        var sent = 0
        for r in pending {
            guard let d = try? enc.encode(r) else { continue }
            var accepted = false
            do throws(CloudError) {
                try await send(d)
                accepted = true
            } catch {
                // kept for later; a refusal drops it (not accepted: the next incident of the kind is again a first)
                if error.retryable { break }
            }
            if accepted { sent += 1 }
            let snapshot = state.withLock { s -> State in
                s.pending.removeAll { $0 == r }
                if accepted, let rev = r.revision, !s.accepted.contains(r.kind + "|" + rev) { s.accepted.append(r.kind + "|" + rev) }
                if s.accepted.count > 64 { s.accepted.removeFirst(s.accepted.count - 64) }
                return s
            }
            file.write(snapshot)
        }
        return sent
    }
}

extension QuranLabCloud {
    /// The issue report of an incident: the section 7 body without `backend`, with `message` and `detail`.
    static func incidentReport(_ i: AcceleratorIncident, app: AppIdentity, chip: String? = DeviceContext.soc,
                               deviceModel: String = DeviceInfo.model, osBuild: String = DeviceInfo.osBuild) -> IssueReport {
        var r = issue(kind: i.kind.rawValue, code: i.code, app: app, backend: nil, revision: i.revision)
        r.message = IncidentText.strip(i.message)
        func ms(_ v: Double?) -> Double? { v.map { (max(0, min(600_000, $0)) * 10).rounded() / 10 } }
        var div = i.divergence
        if var d = div {
            d.tokensExpected = max(0, min(100_000, d.tokensExpected))
            d.tokensDiffer = max(0, min(100_000, d.tokensDiffer))
            d.sitesDiffer = max(0, min(100_000, d.sitesDiffer))
            d.wordsDiffer = max(0, min(100_000, d.wordsDiffer))
            div = d
        }
        r.detail = IncidentDetail(
            stage: i.stage, cause: i.cause,
            errorDomain: IncidentText.token(i.errorDomain, extra: "_.:-", max: 64),
            errorCode: IncidentText.token(i.errorCode, extra: "_.:-", max: 32),
            chunk: i.chunk.map { max(0, min(1_000_000, $0)) },
            elapsedMs: ms(i.elapsedMs), deadlineMs: ms(i.deadlineMs),
            clip: IncidentText.token(i.clip, extra: "_.-", max: 32),
            divergence: div,
            deviceModel: IncidentText.token(deviceModel, extra: "_.,-", max: 32),
            osBuild: IncidentText.token(osBuild, extra: "_.:/-", max: 64),
            chip: IncidentText.token(chip, extra: "_", max: 24),
            accelerator: "ane", computeUnits: "cpuAndNeuralEngine", context: i.context,
            thermal: i.thermal, lowPower: i.lowPower,
            stallMs: i.stallMs.map { Int(max(0, min(600_000, $0)).rounded()) },
            attempt: i.attempt.map { max(1, min(100, $0)) })
        return r
    }

    /// Queues an accelerator incident: the first of its kind for the revision always, later ones once a day per
    /// signature while `flags.issues` allows. Sent off the caller's path.
    func reportIncident(_ i: AcceleratorIncident) {
        guard options.issueReports else { return }
        let r = Self.incidentReport(i, app: app)
        if incidents.isFirst(kind: r.kind, revision: r.revision ?? "") {
            incidents.addFirst(r)
        } else {
            guard config.current?.flags.issues ?? true else { return }
            guard incidents.allowToday("\(r.kind)|\(r.code)|\(r.revision ?? "")", day: r.day) else { return }
            issues.add(r)
        }
        guard key != nil else { return }
        Task.detached(priority: .utility) { [self] in _ = await sendIssues() }
    }
}
