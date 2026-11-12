import Foundation
import TajweedFormer

// The proof a person runs on a Mac with a real key: `scripts/prove-on-mac.sh <key> [<clips folder>]`, which runs
// `ProveOnMacTests.testProveOnMac`. It takes the whole path an app takes, against Quran Lab's servers: the Client,
// the signed config, the download with its progress, the verified model, every sample clip in every context on the
// CPU engine and on the Neural Engine, the promotion pipeline to its end, and `diagnose()`.
//
// This file imports TajweedFormer as an app does (no `@testable`): everything in it is the public API. The few
// things the public API has no door for (the expected tokens of the folder's self-test set, the golden stage's
// measures, the name the run registers under, the release key's id) come through `ProveDoors` and the Client the
// test makes, which ProveOnMacDoors.swift fills from the SDK's internals. Which CoreML build runs is the public
// API's: a Session's `backend` is `auto` (the fp16 build, which a device gets by default) or names `coremlCompact`
// (the compact build). On CI the same code runs against a stub server and stand-in engines
// (`ProveOnMacTests.testARehearsalAgainstTheStubServer`), so it is compiled and exercised on every push.

// MARK: what the doors hand over

/// What the golden stage measured for one build and context: the accelerator's raw outputs against the CPU engine's.
struct ProveMeasures: Sendable, Equatable {
    struct CTC: Sendable, Equatable {
        var tokenEdits: Int
        var lpMean: Double
        var lpP99: Double
        var frames: Int
    }

    /// Per compared CTC head (`log_probs`, `inter1_log_probs`, `timing_log_probs`).
    var ctc: [String: CTC] = [:]
    /// The mean probability difference of the attribute heads, and how many values it is over.
    var pMean: Double?
    var values = 0
    /// The CPU engine's greedy tokens over the clean clips.
    var tokensExpected: Int?

    /// What a signed manifest allows a build in the golden stage (`golden_raw_tolerance`): per CTC head the token
    /// edits and the distances (`frames` is not part of it), and the attribute heads' probability difference.
    struct Tolerance: Sendable, Equatable {
        var ctc: [String: CTC] = [:]
        var pMean: Double?
    }

    /// The tolerance the golden stage judged this build by, as the promotion's record keeps it. Nil: the signed
    /// manifest gives the build none, and it was judged on identical tokens.
    var tolerance: Tolerance?

    /// The measures outside what the golden stage allows the build, each `<head>.<measure>`: outside its
    /// tolerance, or, for a head the tolerance does not name and for a build without one, any token edit.
    var outside: [String] {
        var out: [String] = []
        for (head, m) in ctc.sorted(by: { $0.key < $1.key }) {
            if let t = tolerance?.ctc[head] {
                if m.tokenEdits > t.tokenEdits { out.append("\(head).token_edits") }
                if m.lpMean > t.lpMean { out.append("\(head).lp_mean") }
                if m.lpP99 > t.lpP99 { out.append("\(head).lp_p99") }
            } else if m.tokenEdits != 0 {
                out.append("\(head).token_edits")
            }
        }
        if let p = pMean, let t = tolerance?.pMean, p > t { out.append("attr.p_mean") }
        return out
    }
}

/// What the SDK keeps about one promotion (a model build, a context, a CoreML build, this OS and Mac).
struct ProvePromotion: Sendable, Equatable {
    /// `pending`, `retry`, `ready` or `failed`.
    var status: String
    var stage: String?
    var reason: String?
    var detail: String?
    var compileMs: Double?
    var acceleratorMedianMs: Double?
    var cpuMedianMs: Double?
    var measures: ProveMeasures?
}

/// The server's refusal of the key: the error the SDK raises for it (its message and its fix are the error
/// catalogue's), and the server's own code and status.
struct ProveRefusal: Sendable {
    var error: TajweedError
    var serverCode: String
    var status: Int
}

/// The folder checked again, file by file, against a manifest that must verify with the release key.
struct ProveVerified: Sendable, Equatable {
    var ok: Bool
    /// Files of the manifest that are on this Mac and match their size and SHA-256, and the files the manifest lists.
    var files: Int
    var listed: Int
    var bytes: Int64
    var problem: String?
}

/// The doors into the SDK for what its public API does not show. Every value is a plain one.
struct ProveDoors: Sendable {
    /// The id of the key model manifests must be signed with.
    var releaseKeyID: String
    /// Whether this OS runs the Neural Engine's build (macOS 15).
    var osRunsCoreML: Bool
    /// The Mac's model and OS, for the summary (no name, no serial).
    var device: String
    /// The device fields that go with an accelerator incident, in order: `platform`, `os_version`, `os_build`,
    /// `device_model`, `chip` (when known), `sdk_version`. Nothing that names the install, the app or the account.
    var deviceFields: [(name: String, value: String)]
    /// Why the promotion pipeline would wait now (Low Power Mode, the battery, heat, a metered network), or nil.
    var blocker: @Sendable () async -> String?
    /// The model version and build the signed config names for this key.
    var configModel: @Sendable () -> (version: String?, build: String?)
    /// The server's refusal of the key, when there was one.
    var refusal: @Sendable () -> ProveRefusal?
    /// Opens the model's folder again with the release key alone and checks every file on disk.
    var verify: @Sendable (_ model: TajweedModel, _ version: String?, _ build: String?) -> ProveVerified
    /// Downloads the folder's self-test set (the clips and the expected tokens of every context); the files fetched.
    var fetchSelfTest: @Sendable (_ model: TajweedModel) async throws -> Int
    /// `selftest/expected_<context>.json` of the folder: the expected tokens by clip.
    var expectedTokens: @Sendable (_ model: TajweedModel, _ context: String) -> [String: [Int]]?
    /// Whether the model lists a CoreML build (`coreml`, `coreml-compact`) this Mac can run for a context.
    var hasBuild: @Sendable (_ model: TajweedModel, _ build: String, _ context: String) -> Bool
    /// The promotion's record for a build and context of the model.
    var promotion: @Sendable (_ model: TajweedModel, _ build: String, _ context: String) -> ProvePromotion?
    /// Sends the day's telemetry now: deltas the server accepted, and deltas still waiting. Nil when telemetry is off.
    var flushTelemetry: @Sendable () async -> (sent: Int, waiting: Int)?
    /// Strings that must never be printed (the key, this install's ids, the app's id, paths under the home folder).
    var secrets: @Sendable () -> [String]
}

// MARK: the run's settings

struct ProveConfig: Sendable {
    var key: String
    /// The app id the key was made for, when the key is bound to one.
    var appId: String?
    /// The name the run registers its app under, so that the key's page on sdk.quranlab.ai shows what it was (a test
    /// process has no app name of its own).
    var appName = "SDK proof (Mac)"
    /// Where this run keeps the model and the SDK's state (its own folder: never an app's).
    var storage: URL
    /// The 35 conformance clips (`audio/<clip>.pcm`, 16 kHz float32), for step 5; nil skips it.
    var clips: URL?
    /// The engine's expected rows (`v4_<context>_audio_expected.jsonl`).
    var expectedRows: URL?
    /// What the config and the model must be; nil accepts whatever the config names.
    var expectVersion: String?
    var expectBuild: String?
    /// The contexts to prove; nil is every context of the model.
    var contexts: [String]?
    /// The CoreML builds to take through the pipeline, in order: the fp16 one (`coreml`), which an Apple device gets
    /// by default (a Session with `backend: .auto`); `coreml-compact` (`backend: .coremlCompact`) as well only when
    /// the run names it.
    var builds = ["coreml"]
    /// A line says a stage is still going on when this many seconds passed without one.
    var stillEvery = 20.0
    /// The longest a promotion may take (the download, the compile, the golden test), seconds.
    var promotionTimeout = 45.0 * 60
    /// The longest one take may run, seconds.
    var takeTimeout = 180.0
    /// The longest the signed config may take to arrive, seconds.
    var configTimeout = 40.0
}

// MARK: output

/// The run's lines: each goes to the screen (through the file the script follows) with nothing that names the key,
/// the install, the app or the account.
final class ProveOut: @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String] = []
    private var kept: [String] = []
    private let progress: URL?
    private let echo: Bool

    /// - Parameters:
    ///   - progress: a file each line is appended to as it is said (the script shows it live).
    ///   - echo: also print each line.
    init(progress: URL? = nil, echo: Bool = true) {
        self.progress = progress
        self.echo = echo
        if let progress { FileManager.default.createFile(atPath: progress.path, contents: Data()) }
    }

    /// More strings that are never printed. The proof's own identifier is not one of them: it names no app of the
    /// person who runs it.
    func redact(_ more: [String]) {
        lock.lock()
        secrets += more.filter { $0.count >= 4 && $0 != ProveOnMac.proofIdentifier }
        lock.unlock()
    }

    /// A line as it may be shown: secrets, keys, tokens and home folders replaced.
    func scrub(_ line: String) -> String {
        lock.lock()
        let hide = secrets
        lock.unlock()
        return ProveOut.scrub(line, secrets: hide)
    }

    static func scrub(_ line: String, secrets: [String]) -> String {
        var s = line
        // the longest first, so a secret inside another is not left half shown
        for secret in secrets.sorted(by: { $0.count > $1.count }) where !secret.isEmpty { s = s.replacingOccurrences(of: secret, with: "[redacted]") }
        for pattern in [#"qlk_v1_[A-Za-z0-9_\-]+"#, #"qlt_v1\.[A-Za-z0-9_\-\.]+"#] {
            s = s.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        s = s.replacingOccurrences(of: #"/Users/[^/\s"']+"#, with: "/Users/[redacted]", options: .regularExpression)
        return s
    }

    func say(_ line: String) {
        let shown = scrub(line)
        lock.lock()
        kept.append(shown)
        lock.unlock()
        if echo { print(shown) }
        guard let progress, let h = try? FileHandle(forWritingTo: progress) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data((shown + "\n").utf8))
    }

    /// Every line said so far.
    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return kept
    }
}

/// The download's progress, said at every tenth of the total.
final class ProveProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTenth = -1
    private(set) var calls = 0
    private(set) var last: (done: Int64, total: Int64) = (0, 0)
    private(set) var wentBack = false
    private let out: ProveOut

    init(_ out: ProveOut) { self.out = out }

    func note(_ done: Int64, _ total: Int64) {
        lock.lock()
        calls += 1
        if done < last.done { wentBack = true }
        last = (done, total)
        let tenth = total > 0 ? Int(done * 10 / total) : 0
        let say = tenth > lastTenth
        if say { lastTenth = tenth }
        lock.unlock()
        if say { out.say("        \(ProveOnMac.megabytes(done)) of \(ProveOnMac.megabytes(total)) MB") }
    }

    var snapshot: (calls: Int, done: Int64, total: Int64, wentBack: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (calls, last.done, last.total, wentBack)
    }
}

// MARK: results

/// A step that could not go on, with the sentence to show.
struct ProveFailure: Error, Sendable {
    var what: String
}

enum ProveVerdict: String, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case skipped = "SKIPPED"
    case notRun = "NOT RUN"
}

struct ProveStep: Sendable, Equatable {
    var number: Int
    var title: String
    var verdict: ProveVerdict
    var note: String
}

/// How the promotion of one build ended for one context.
enum ProveOutcome: Sendable, Equatable {
    case promoted
    /// The device stays on the CPU engine for a reason the pipeline names (`golden_mismatch`: the measures are
    /// outside the build's signed tolerance, or the tokens differ from the CPU engine's when it has none). That is
    /// the pipeline's answer, not a failure.
    case demoted(reason: String, detail: String)
    /// A fault of the pipeline itself: a crash, a stage that did not end, a pipeline that did not start.
    case failed(String)
}

/// One build and context the run took through the pipeline, and what the golden stage measured when it got there.
struct ProveEnded: Sendable, Equatable {
    var build: String
    var context: String
    var outcome: ProveOutcome
    var measures: ProveMeasures?
}

/// One measured build and context, for the records of the summary.
struct ProveMeasured: Sendable, Equatable {
    var build: String
    var context: String
    var measures: ProveMeasures
    /// The golden stage's verdict on this run.
    var passed = true
}

/// What goes with every record of measures: the model they belong to, the self-test clips compared, and the device
/// fields of an incident report.
struct ProveFacts: Sendable {
    var modelVersion = ""
    var modelBuild = ""
    var clips = 0
    var cleanClips = 0
    var device: [(name: String, value: String)] = []
}

struct ProveReport: Sendable {
    var steps: [ProveStep]
    /// The summary, its last lines the ones to paste back.
    var summary: [String]
    /// 0 only when every step that ran passed.
    var status: Int32
    var measured: [ProveMeasured]
}

/// One take through a Session, as the proof reads it.
struct ProveTake: Sendable {
    var tokens: [Int] = []
    var chunks = 0
    /// The Backend at the take's end: `cpu` or `accelerator`, and its name.
    var kind = ""
    var name = ""
    /// A `backendChanged` event came during the take (a failover).
    var switched = false
    var ended = ""
    var error: String?
    var logProbs: [Float] = []
    var classes = 0
}

/// One row of the engine's expected file for the conformance clips.
struct ProveRow: Sendable, Equatable {
    var clip: String
    var chunks: Int
    var tokens: [Int]
    var logpFNV: String
    /// Per output name, the FNV-1a 64 of each chunk's values.
    var outFNV: [String: [String]]
}

/// What the conformance clips of one context gave on the CPU engine.
struct ProveConformance: Sendable, Equatable {
    var clips = 0
    var chunks = 0
    /// Chunk outputs hashed and compared, and the values in them.
    var outputs = 0
    var values = 0
    var mismatches = 0
    var failed: [String] = []
}

/// The Neural Engine against the CPU engine on the conformance clips of one build and context.
struct ProveParity: Sendable, Equatable {
    var clips = 0
    var tokenMismatches = 0
    var notOnAccelerator = 0
    /// Takes that ended with an error.
    var errors = 0
    var lpMean = 0.0
    var lpP99 = 0.0
    var frames = 0
    var failed: [String] = []
}

// MARK: the proof

enum ProveOnMac {
    static let titles = [
        "this Mac", "the Client and the signed config", "the download and its verification", "the sample clips in every context",
        "the promotion pipeline", "the conformance clips", "diagnose",
    ]

    // MARK: small pure parts (tested on CI)

    static func megabytes(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1_000_000) }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func describe(_ error: any Error) -> String {
        if let e = error as? TajweedError { return "\(e.code): \(e.message) \(e.fix)" }
        if let e = error as? ProveFailure { return e.what }
        return "\(error)"
    }

    /// An error the run stops on: what happened and, on the line under it, what to do. For an SDK error both are
    /// the error's own (the `message` and the `fix` of the error catalogue), whatever the error is. Returns the same
    /// in one line, for the step's line of the summary.
    @discardableResult
    static func stop(_ out: ProveOut, _ error: any Error, what: String = "") -> String {
        guard let e = error as? TajweedError else {
            let line = what + describe(error)
            out.say("    " + line)
            return line
        }
        let line = what + "\(e.code): \(e.message)"
        out.say("    " + line)
        guard !e.fix.isEmpty else { return line }
        out.say("    what to do: \(e.fix)")
        return line + " " + e.fix
    }

    /// `client.prefetch` with its byte progress; nil when it finished, else the error it threw.
    static func prefetch(_ client: TajweedClient, _ progress: ProveProgress) async -> TajweedError? {
        do throws(TajweedError) {
            try await client.prefetch(unmeteredOnly: false, onProgress: { done, total in progress.note(done, total) })
            return nil
        } catch {
            return error
        }
    }

    static func name(_ reason: TajweedEvent.EndReason) -> String {
        switch reason {
        case .silence: return "silence"
        case .background: return "background"
        case .hidden: return "hidden"
        case .interrupted: return "interrupted"
        case .sourceEnd: return "sourceEnd"
        case .limit: return "limit"
        case .error(let e): return "error (\(e.code))"
        }
    }

    /// What to do about a reason the pipeline waits for.
    static func fix(blocker: String) -> String {
        if blocker.contains("Low Power") { return "Turn Low Power Mode off (System Settings, Battery) and run the script again." }
        if blocker.contains("battery") { return "Connect the charger and run the script again." }
        if blocker.contains("thermal") { return "Let the Mac cool down and run the script again." }
        if blocker.contains("metered") { return "Use Wi-Fi or Ethernet that is not a personal hotspot and not in Low Data Mode, and run the script again." }
        return "Run the script again when that has passed."
    }

    /// The server's codes of a refusal that is about the app id, the one thing this run can change about itself.
    static let appIdRefusals = ["app_not_allowed", "app_blocked", "app_owned_elsewhere"]

    /// The identifier the run registers as unless another is given. It is the proof's own and no secret: a key works
    /// for the first app identifier that used it, so the key a run is given will belong to this identifier.
    static let proofIdentifier = "ai.quranlab.sdk.prove"

    /// What to do when the key is refused for the app identifier.
    static let identifierAdvice = "for this script: a key works for the first app identifier that used it, and this run registers as "
        + proofIdentifier + " (or as QURANLAB_APP_ID when it is set). Use a key made for the proof, or allow that identifier on the "
        + "key's page at https://sdk.quranlab.ai/keys, and run the script again"

    static let fnv0: UInt64 = 1_469_598_103_934_665_603

    /// FNV-1a 64 over the bytes of the values, continued from `h` (the engine's conformance hash).
    static func fnv(_ h: UInt64, _ values: [Float]) -> UInt64 {
        var h = h
        values.withUnsafeBytes { bytes in
            for b in bytes { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
        }
        return h
    }

    static func hex(_ h: UInt64) -> String { String(format: "%016llx", h) }

    /// The rows of an expected file (JSON lines); nil when the file is not there or a line is not a row.
    static func rows(_ url: URL) -> [ProveRow]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var out: [ProveRow] = []
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let clip = o["clip"] as? String,
                  let chunks = o["chunks"] as? Int, let tokens = o["tokens"] as? [Int], let logp = o["logp_fnv"] as? String else { return nil }
            out.append(ProveRow(clip: clip, chunks: chunks, tokens: tokens, logpFNV: logp, outFNV: (o["out_fnv"] as? [String: [String]]) ?? [:]))
        }
        return out
    }

    /// 16 kHz mono float32 samples of a raw file.
    static func pcm(_ url: URL) -> [Float]? {
        guard let d = try? Data(contentsOf: url), !d.isEmpty, d.count % 4 == 0 else { return nil }
        return d.withUnsafeBytes { raw in (0..<(raw.count / 4)).map { raw.loadUnaligned(fromByteOffset: 4 * $0, as: Float.self) } }
    }

    /// Where a clip's audio is in the clips folder: `audio/<clip>.pcm`, else `<clip>.pcm`.
    static func audio(_ clips: URL, _ clip: String) -> URL? {
        for u in [clips.appendingPathComponent("audio/\(clip).pcm"), clips.appendingPathComponent("\(clip).pcm")]
        where FileManager.default.fileExists(atPath: u.path) {
            return u
        }
        return nil
    }

    /// The take's chunks against one expected row: the chunk count, the tokens, the running hash of `log_probs`, and
    /// the hash of every output of every chunk. Returns what was compared and what differed.
    static func compare(_ row: ProveRow, tokens: [Int], chunks: [[String: [Float]]]) -> (outputs: Int, values: Int, mismatches: Int, why: String?) {
        var outputs = 0, values = 0, mismatches = 0
        var why: String?
        func miss(_ what: String) {
            mismatches += 1
            if why == nil { why = what }
        }
        if chunks.count != row.chunks { miss("\(chunks.count) chunks, expected \(row.chunks)") }
        if tokens != row.tokens { miss("the tokens differ") }
        var logp = fnv0
        for c in chunks { logp = fnv(logp, c["log_probs"] ?? []) }
        if hex(logp) != row.logpFNV { miss("log_probs differ") }
        for (name, expected) in row.outFNV.sorted(by: { $0.key < $1.key }) {
            for (i, want) in expected.enumerated() {
                outputs += 1
                guard i < chunks.count, let v = chunks[i][name] else {
                    miss("\(name) is missing in chunk \(i)")
                    continue
                }
                values += v.count
                if hex(fnv(fnv0, v)) != want { miss("\(name) differs in chunk \(i)") }
            }
        }
        return (outputs, values, mismatches, why)
    }

    /// The Levenshtein distance between two token lists.
    static func edits(_ a: [Int], _ b: [Int]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let keep = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = keep
            }
        }
        return row[b.count]
    }

    /// Per frame, the largest difference between two runs' log-probabilities, each clipped to [-30, 0] (the golden
    /// test's distance). Nil when the two have another shape.
    static func distances(_ a: [Float], _ c: [Float], classes: Int) -> [Double]? {
        guard classes > 0, a.count == c.count, a.count % classes == 0 else { return nil }
        func clip(_ x: Float) -> Double { Double(min(0, max(-30, x))) }
        var out: [Double] = []
        out.reserveCapacity(a.count / classes)
        for f in 0..<(a.count / classes) {
            var d = 0.0
            for k in 0..<classes { d = max(d, abs(clip(a[f * classes + k]) - clip(c[f * classes + k]))) }
            out.append(d)
        }
        return out
    }

    /// The mean and the 99th percentile (nearest rank) of the distances.
    static func spread(_ d: [Double]) -> (mean: Double, p99: Double) {
        guard !d.isEmpty else { return (0, 0) }
        let s = d.sorted()
        return (d.reduce(0, +) / Double(d.count), s[(99 * s.count + 99) / 100 - 1])
    }

    /// A measure as a manifest writes it: at most 6 digits after the dot, rounded up so that the measured value is
    /// inside a tolerance of this number.
    static func number(_ x: Double) -> String {
        let v = max(0, x)
        func text(_ millionths: Double) -> String { String(format: "%.6f", millionths / 1_000_000) }
        // the nearest sixth decimal, and the next one up when that reads back below the value
        var millionths = (v * 1_000_000).rounded()
        if (Double(text(millionths)) ?? 0) < v { millionths += 1 }
        var s = text(millionths)
        while s.hasSuffix("0") && !s.hasSuffix(".0") { s.removeLast() }
        return s
    }

    /// A string as JSON writes it.
    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// One record of the golden stage's measures, with the field names and units Quran Lab's server notes give them:
    /// the build and the context, the model, the self-test clips compared, `heads` (per CTC head `token_edits` in
    /// tokens, `lp_mean` and `lp_p99` in nats, `frames`; `attr` with `p_mean`, a probability, and `values`; the shape
    /// of an incident report's `detail.divergence.heads`), the stage's verdict, and the device fields of an incident
    /// report. Numbers have a dot, no exponent and at most 6 decimals.
    static func record(_ m: ProveMeasured, facts: ProveFacts) -> String {
        let order = ["log_probs", "inter1_log_probs", "timing_log_probs"]
        var names: [String] = order.filter { m.measures.ctc[$0] != nil }
        names += m.measures.ctc.keys.filter { !order.contains($0) }.sorted()
        var heads: [String] = []
        for name in names {
            guard let c = m.measures.ctc[name] else { continue }
            var head = "\(quoted(name)): {\"token_edits\": \(c.tokenEdits), \"lp_mean\": \(number(c.lpMean)), "
            head += "\"lp_p99\": \(number(c.lpP99)), \"frames\": \(c.frames)}"
            heads.append(head)
        }
        if let p = m.measures.pMean { heads.append("\"attr\": {\"p_mean\": \(number(p)), \"values\": \(m.measures.values)}") }
        var parts: [String] = []
        parts.append("\"build\": \(quoted(m.build))")
        parts.append("\"context\": \(quoted(m.context))")
        parts.append("\"model_version\": \(quoted(facts.modelVersion))")
        parts.append("\"model_build\": \(quoted(facts.modelBuild))")
        parts.append("\"clips\": \(facts.clips)")
        parts.append("\"clean_clips\": \(facts.cleanClips)")
        parts.append("\"tokens_expected\": \(m.measures.tokensExpected ?? 0)")
        parts.append("\"heads\": {" + heads.joined(separator: ", ") + "}")
        parts.append("\"passed\": " + (m.passed ? "true" : "false"))
        for field in facts.device { parts.append("\(quoted(field.name)): \(quoted(field.value))") }
        return "{" + parts.joined(separator: ", ") + "}"
    }

    /// The golden stage's judgement of one build, as lines of the run: per head what was measured next to the bound
    /// the signed manifest gives the build, and whether it is inside or which measure is outside. When the manifest
    /// gives the build no tolerance the first line says so, and that identical tokens decided.
    static func judgement(_ m: ProveMeasures, build: String) -> [String] {
        let order = ["log_probs", "inter1_log_probs", "timing_log_probs"]
        var names: [String] = order.filter { m.ctc[$0] != nil }
        names += m.ctc.keys.filter { !order.contains($0) }.sorted()
        let outside = m.outside
        var out: [String] = []
        guard let bounds = m.tolerance else {
            out.append("golden stage, the signed manifest gives \(build) no tolerance: identical tokens decided")
            for name in names {
                guard let c = m.ctc[name] else { continue }
                var line = "\(name): token_edits \(c.tokenEdits) (must be 0)" + (c.tokenEdits == 0 ? "" : ": OUTSIDE")
                line += "; lp_mean \(number(c.lpMean)), lp_p99 \(number(c.lpP99)) measured, not judged"
                out.append(line)
            }
            if let p = m.pMean { out.append("attr: p_mean \(number(p)) measured, not judged") }
            return out
        }
        out.append("golden stage, judged by the tolerance the signed manifest gives \(build) (measured / bound):")
        for name in names {
            guard let c = m.ctc[name] else { continue }
            guard let b = bounds.ctc[name] else {
                // a head the tolerance does not name is held to identical tokens
                var line = "\(name): token_edits \(c.tokenEdits) (no bound for this head: must be 0)" + (c.tokenEdits == 0 ? "" : ": OUTSIDE")
                line += "; lp_mean \(number(c.lpMean)), lp_p99 \(number(c.lpP99)) measured, not judged"
                out.append(line)
                continue
            }
            var line = "\(name): token_edits \(c.tokenEdits) / \(b.tokenEdits), lp_mean \(number(c.lpMean)) / \(number(b.lpMean)), "
            line += "lp_p99 \(number(c.lpP99)) / \(number(b.lpP99)): "
            let bad = outside.filter { $0.hasPrefix(name + ".") }.map { String($0.dropFirst(name.count + 1)) }
            line += bad.isEmpty ? "inside" : "OUTSIDE (" + bad.joined(separator: ", ") + ")"
            out.append(line)
        }
        if let p = m.pMean {
            if let b = bounds.pMean {
                out.append("attr: p_mean \(number(p)) / \(number(b)): " + (p > b ? "OUTSIDE (p_mean)" : "inside"))
            } else {
                out.append("attr: p_mean \(number(p)) measured, not judged (no bound)")
            }
        }
        return out
    }

    /// One build's entry of a `golden_raw_tolerance`, from measures: `attr`, then the CTC heads in name order.
    static func entry(_ m: ProveMeasures) -> String {
        var parts: [String] = []
        if let p = m.pMean { parts.append("\"attr\": {\"p_mean\": \(number(p))}") }
        for (head, c) in m.ctc.sorted(by: { $0.key < $1.key }) {
            parts.append("\"\(head)\": {\"token_edits\": \(c.tokenEdits), \"lp_mean\": \(number(c.lpMean)), \"lp_p99\": \(number(c.lpP99))}")
        }
        return "{" + parts.joined(separator: ", ") + "}"
    }

    /// The largest value of each measure over several records of one build.
    static func largest(_ all: [ProveMeasures]) -> ProveMeasures {
        var out = ProveMeasures()
        for m in all {
            for (head, c) in m.ctc {
                let o = out.ctc[head] ?? ProveMeasures.CTC(tokenEdits: 0, lpMean: 0, lpP99: 0, frames: 0)
                out.ctc[head] = ProveMeasures.CTC(tokenEdits: max(o.tokenEdits, c.tokenEdits), lpMean: max(o.lpMean, c.lpMean),
                                                  lpP99: max(o.lpP99, c.lpP99), frames: o.frames + c.frames)
            }
            if let p = m.pMean { out.pMean = max(out.pMean ?? 0, p) }
            out.values += m.values
        }
        return out
    }

    /// A tolerance made from the measures, as a PROPOSAL for the model side and named as such: per build the largest
    /// value of each measure over its records (the ones the golden stage did not pass included), in the shape of a
    /// manifest's `golden_raw_tolerance`, with no margin added. The margin and the signing are the model side's.
    /// Empty when nothing was measured.
    static func proposalBlock(_ measured: [ProveMeasured]) -> [String] {
        guard !measured.isEmpty else { return [] }
        var out = ["a proposal for the model side, not a tolerance in force: per build the largest value of each measure over the "
            + "records above, no margin added (the margin and the signing are the model side's)"]
        out.append("\"golden_raw_tolerance\": {")
        var builds: [String] = []
        for m in measured where !builds.contains(m.build) { builds.append(m.build) }
        for (i, b) in builds.enumerated() {
            let top = largest(measured.filter { $0.build == b }.map(\.measures))
            out.append(" \"\(b)\": \(entry(top))" + (i + 1 < builds.count ? "," : ""))
        }
        out.append("}")
        return out
    }

    /// The golden stage's measures: one record per build and context that reached the stage (one JSON object a
    /// line), under two lines that say what they are and how the stage judges (SPEC 5.1: by the tolerance the
    /// signed manifest gives the build, on identical tokens when it gives none).
    static func measuresBlock(_ measured: [ProveMeasured], device: String, facts: ProveFacts) -> [String] {
        guard !measured.isEmpty else { return ["measures of the golden stage: none (no build reached its golden stage)"] }
        let passed = measured.filter(\.passed).count
        var out = ["measures of the golden stage on \(device), the Neural Engine against the CPU engine (lp_mean and lp_p99 in nats, "
            + "p_mean a probability): \(measured.count) records, \(passed) passed"]
        out.append("these are measurements: the golden stage judges a build by the tolerance its signed manifest gives it, and on "
            + "identical tokens when the manifest gives it none")
        for m in measured { out.append(record(m, facts: facts)) }
        return out
    }

    /// The summary: the header, the counts, then the lines to paste back (one per step, then the golden stage's
    /// measures and the tolerance proposed from them).
    static func summary(steps: [ProveStep], header: [String], measured: [ProveMeasured], device: String, facts: ProveFacts) -> [String] {
        var out = header
        out.append("----- paste from here -----")
        for s in steps {
            let title = "step \(s.number)  \(s.title)"
            out.append(title.padding(toLength: 44, withPad: " ", startingAt: 0) + s.verdict.rawValue + (s.note.isEmpty ? "" : "  " + s.note))
        }
        out += measuresBlock(measured, device: device, facts: facts)
        out += proposalBlock(measured)
        return out
    }

    /// 0 only when every step that ran passed (a skipped step did not run).
    static func status(_ steps: [ProveStep]) -> Int32 {
        steps.contains { $0.verdict == .fail || $0.verdict == .notRun } ? 1 : 0
    }

    // MARK: takes

    static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// Reads a stream to its end; nil when it has not ended after `seconds`.
    static func drain<T: Sendable>(_ stream: AsyncStream<T>, within seconds: Double) async -> [T]? {
        await withTaskGroup(of: [T]?.self) { group in
            group.addTask {
                var out: [T] = []
                for await x in stream { out.append(x) }
                return out
            }
            group.addTask {
                await ProveOnMac.pause(seconds)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// What a finished Session gave: its events, the take's Heads and the Backend it ran on.
    static func finish(_ session: TajweedSession, chunks: Int) async -> ProveTake {
        var t = ProveTake()
        t.chunks = chunks
        for e in await drain(session.events, within: 10) ?? [] {
            if case .backendChanged = e { t.switched = true }
            if case .ended(let reason) = e { t.ended = name(reason) }
        }
        do {
            let heads = try await session.finish()
            t.tokens = heads.greedy().map(\.id)
            if let lp = heads["log_probs"] {
                t.logProbs = lp.values
                t.classes = lp.classes
            }
        } catch {
            t.error = describe(error)
        }
        let b = session.backend
        t.kind = b.kind.rawValue
        t.name = b.name
        return t
    }

    /// One sample clip through `listen(from:)`, as fast as the engine takes it.
    static func take(_ model: TajweedModel, clip: TajweedClip, options: TajweedSessionOptions, timeout: Double) async -> ProveTake {
        do {
            let session = try await model.listen(from: clip, options: options)
            guard let chunks = await drain(session.chunks, within: timeout) else {
                await session.cancel()
                var t = ProveTake()
                t.error = "the take did not end within \(Int(timeout)) s"
                return t
            }
            return await finish(session, chunks: chunks.count)
        } catch {
            var t = ProveTake()
            t.error = describe(error)
            return t
        }
    }

    /// Samples pushed into a Session in pieces of 20 ms, with every chunk's heads kept by name.
    static func pushed(_ model: TajweedModel, samples: [Float], options: TajweedSessionOptions,
                       timeout: Double) async -> (take: ProveTake, chunks: [[String: [Float]]]) {
        do {
            let session = try await model.session(options: options)
            async let reading = drain(session.chunks, within: timeout)
            var at = 0
            while at < samples.count {
                let n = min(320, samples.count - at)
                try session.push(Array(samples[at..<(at + n)]))
                at += n
            }
            let heads = try await session.finish()
            guard let chunks = await reading else {
                var t = ProveTake()
                t.error = "the take did not end within \(Int(timeout)) s"
                return (t, [])
            }
            var t = ProveTake()
            t.chunks = chunks.count
            t.tokens = heads.greedy().map(\.id)
            if let lp = heads["log_probs"] {
                t.logProbs = lp.values
                t.classes = lp.classes
            }
            for e in await drain(session.events, within: 10) ?? [] {
                if case .backendChanged = e { t.switched = true }
            }
            let b = session.backend
            t.kind = b.kind.rawValue
            t.name = b.name
            var byName: [[String: [Float]]] = []
            for c in chunks {
                var one: [String: [Float]] = [:]
                for name in c.heads.names { one[name] = c.heads[name]?.values ?? [] }
                byName.append(one)
            }
            return (t, byName)
        } catch {
            var t = ProveTake()
            t.error = describe(error)
            return (t, [])
        }
    }

    /// Every sample clip of the model on one engine: how many gave the expected tokens, and what went wrong.
    static func sampleClips(_ model: TajweedModel, clips: [TajweedClip], expected: [String: [Int]], context: String,
                            backend: TajweedSessionOptions.Backend, wantName: String, timeout: Double) async -> (ok: Int, problems: [String]) {
        var ok = 0
        var problems: [String] = []
        for clip in clips {
            let t = await take(model, clip: clip, options: TajweedSessionOptions(context: context, backend: backend, pace: .fast),
                               timeout: timeout)
            // a clip with a deliberate mistake in it is named as one: the golden stage does not count its tokens
            let label = clip.kind == "clean" ? clip.name : "\(clip.name) (a \(clip.kind) clip)"
            if let e = t.error {
                problems.append("\(label): \(e)")
            } else if t.name != wantName || t.switched {
                problems.append("\(label): ran on \(t.name)" + (t.switched ? " after a switch during the take" : "") + ", not on \(wantName)")
            } else if let want = expected[clip.name] {
                if t.tokens == want {
                    ok += 1
                } else {
                    problems.append("\(label): \(edits(t.tokens, want)) token edits from the expected \(want.count) tokens")
                }
            } else {
                problems.append("\(label): the folder has no expected tokens for it")
            }
        }
        return (ok, problems)
    }

    /// The Session backend that asks for a build: `auto` for the fp16 build, `coremlCompact` for the compact one.
    static func backend(for build: String) -> TajweedSessionOptions.Backend { build == "coreml-compact" ? .coremlCompact : .auto }

    /// The promotion of one build for one context, as an app gets it: a take on the build's backend (the pipeline
    /// starts when it ends), then the Model's Backend until it says `promoted` or `demoted`.
    static func promote(_ model: TajweedModel, context: String, build: String, clip: TajweedClip, config: ProveConfig,
                        doors: ProveDoors, out: ProveOut) async -> (outcome: ProveOutcome, seconds: Double) {
        let began = Date()
        func elapsed() -> Double { Date().timeIntervalSince(began) }
        let options = TajweedSessionOptions(context: context, backend: backend(for: build), pace: .fast)
        let first = await take(model, clip: clip, options: options, timeout: config.takeTimeout)
        if let e = first.error { return (.failed("the first take failed: \(e)"), elapsed()) }
        var last = ""
        var idleSince = Date()
        var lastSaid = Date()
        var nudges = 0
        var blockedSince: Date?
        var nextConditions = Date().addingTimeInterval(20)
        while elapsed() < config.promotionTimeout {
            let b = await model.backend
            let stage = b.stage.rawValue + (b.reason.map { " (\($0))" } ?? "")
            if stage != last {
                out.say("        \(build) \(context): \(stage)  [\(clock(elapsed()))]")
                last = stage
                idleSince = Date()
                lastSaid = Date()
            } else if Date().timeIntervalSince(lastSaid) >= config.stillEvery {
                // a compile takes a minute or more: a line now and then says the run is alive
                out.say("        \(build) \(context): \(still(b.stage.rawValue)), \(clock(elapsed()))")
                lastSaid = Date()
            }
            if b.stage == .promoted { return (.promoted, elapsed()) }
            if b.stage == .demoted {
                let reason = b.reason ?? "other"
                let detail = doors.promotion(model, build, context)?.detail ?? ""
                // a crash, a stage that did not end and a reason the pipeline does not name are its faults; any other
                // reason is its answer
                if pipelineFaults.contains(reason) || !demotionReasons.contains(reason) {
                    return (.failed(reason + (detail.isEmpty ? "" : ": \(detail)")), elapsed())
                }
                return (.demoted(reason: reason, detail: detail), elapsed())
            }
            if Date() >= nextConditions {
                nextConditions = Date().addingTimeInterval(30)
                if let why = await doors.blocker() {
                    if blockedSince == nil {
                        blockedSince = Date()
                        out.say("        waiting: \(why)")
                    }
                    if let since = blockedSince, Date().timeIntervalSince(since) > 300 {
                        return (.failed("the pipeline waited 5 minutes for: \(why). \(fix(blocker: why))"), elapsed())
                    }
                } else {
                    blockedSince = nil
                }
            }
            // the pipeline starts when a take ends: when nothing has started after a minute, one more take asks again
            if b.stage == .cpu, Date().timeIntervalSince(idleSince) > 60 {
                guard nudges < 3 else { return (.failed("the pipeline did not start"), elapsed()) }
                nudges += 1
                idleSince = Date()
                _ = await take(model, clip: clip, options: options, timeout: config.takeTimeout)
            }
            await pause(min(0.5, max(0.05, config.stillEvery / 4)))
        }
        return (.failed("a stage did not end: not promoted after \(clock(config.promotionTimeout)) (the last stage was \(last))"), elapsed())
    }

    /// The line that says a stage is still going on.
    static func still(_ stage: String) -> String {
        stage == "cpu" ? "still waiting for the pipeline to start" : "still \(stage)"
    }

    /// The reasons a pipeline names for leaving a device on the CPU engine (the Backend's `reason` codes).
    static let demotionReasons = ["network", "storage", "verify", "compile_error", "compile_timeout", "load_error", "crash", "hang", "non_finite",
                                  "golden_mismatch", "cpu_mismatch", "failover", "denylist", "other"]

    /// Those of them that are a fault of the pipeline itself and not its answer: it crashed, or a stage did not end.
    static let pipelineFaults = ["crash", "hang", "compile_timeout"]

    /// A reason for staying on the CPU engine, in words. `tolerance`: the build was judged by a signed tolerance
    /// (a golden stage that does not pass is then outside it; without one, its tokens differ).
    static func words(reason: String, tolerance: Bool = false) -> String {
        switch reason {
        case "golden_mismatch": return tolerance ? "outside the tolerance" : "tokens differ"
        case "cpu_mismatch": return "the CPU engine's tokens are not the expected ones"
        case "non_finite": return "an output that is not a number"
        case "compile_error": return "the compile failed"
        case "load_error": return "the build did not load"
        case "network": return "the download failed"
        case "storage": return "no room on the disk"
        case "verify": return "a file did not verify"
        case "failover": return "a failover during a take"
        case "denylist": return "switched off by the config"
        default: return "another reason (\(reason))"
        }
    }

    /// Step 4. It passes when every build and context ended promoted, or on the CPU engine for a reason the pipeline
    /// names (a build outside its signed tolerance, or with tokens that differ from the CPU engine's when it has
    /// none, is the pipeline doing its job). It fails only on a fault of the pipeline: a crash, a stage that did not
    /// end, a promotion outside the tolerance (with token edits, for a build that has none). Its line says how many
    /// ended each way.
    static func pipelineVerdict(_ ended: [ProveEnded]) -> (verdict: ProveVerdict, note: String) {
        guard !ended.isEmpty else { return (.fail, "the model lists no CoreML build for this Mac") }
        var promoted = 0
        var stayed: [(words: String, count: Int)] = []
        var faults: [String] = []
        for e in ended {
            let name = e.context.isEmpty ? e.build : "\(e.build) \(e.context)"
            switch e.outcome {
            case .promoted:
                promoted += 1
                if let m = e.measures {
                    // token edits inside a signed tolerance are the tolerance at work; a promotion outside what the
                    // stage allows is the pipeline's fault
                    let outside = m.outside
                    if !outside.isEmpty {
                        faults.append(m.tolerance == nil
                            ? "\(name) was promoted although its tokens differ from the CPU engine's and it has no tolerance "
                                + "(\(outside.joined(separator: ", ")))"
                            : "\(name) was promoted outside its tolerance (\(outside.joined(separator: ", ")))")
                    }
                } else {
                    faults.append("\(name) was promoted and no golden measures are kept for it")
                }
            case .demoted(let reason, _):
                let w = words(reason: reason, tolerance: e.measures?.tolerance != nil)
                if let i = stayed.firstIndex(where: { $0.words == w }) {
                    stayed[i].count += 1
                } else {
                    stayed.append((words: w, count: 1))
                }
            case .failed(let why):
                faults.append("\(name): \(why)")
            }
        }
        var note = "promoted \(promoted) of \(ended.count)"
        var stayedCount = 0
        for s in stayed { stayedCount += s.count }
        if stayedCount > 0 {
            note += "; \(stayedCount) stayed on the CPU engine: "
            note += stayed.count == 1 ? stayed[0].words : stayed.map { "\($0.count) \($0.words)" }.joined(separator: ", ")
        }
        if !faults.isEmpty {
            note += "; \(faults.count) pipeline " + (faults.count == 1 ? "error" : "errors") + ": " + faults[0]
        }
        return (faults.isEmpty ? .pass : .fail, note)
    }

    /// The summary's line about the SDK: its version and, in words, how it stands to the newest release the signed
    /// config names.
    static func sdkLine(version: String, latest: String?) -> String {
        guard let latest else { return "SDK \(version)" }
        let order = compare(version, latest)
        if order == 0 { return "SDK \(version), which is the newest release" }
        if order > 0 { return "this SDK, \(version), is newer than the newest release, \(latest)" }
        return "SDK \(version); a newer release, \(latest), is out"
    }

    /// Two versions x.y.z: negative when `a` is the older, 0 when they are the same, positive when `a` is the newer.
    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0
            let q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }

    /// The conformance clips of one context on the CPU engine, bit for bit against the engine's expected rows, and
    /// each clip's tokens and `log_probs` kept for the parity of the Neural Engine.
    static func conformance(_ model: TajweedModel, context: String, rows: [ProveRow], clips: URL,
                            timeout: Double) async -> (result: ProveConformance, reference: [String: ProveTake]) {
        var r = ProveConformance()
        var reference: [String: ProveTake] = [:]
        let options = TajweedSessionOptions(context: context, sampleRate: 16_000, heads: TajweedSessionOptions.allHeads, backend: .cpu)
        for row in rows {
            guard let url = audio(clips, row.clip), let samples = pcm(url) else {
                r.mismatches += 1
                r.failed.append("\(row.clip): no audio in the clips folder")
                continue
            }
            let (t, chunks) = await pushed(model, samples: samples, options: options, timeout: timeout)
            r.clips += 1
            if let e = t.error {
                r.mismatches += 1
                r.failed.append("\(row.clip): \(e)")
                continue
            }
            let c = compare(row, tokens: t.tokens, chunks: chunks)
            r.chunks += chunks.count
            r.outputs += c.outputs
            r.values += c.values
            r.mismatches += c.mismatches
            if let why = c.why { r.failed.append("\(row.clip): \(why)") }
            reference[row.clip] = t
        }
        return (r, reference)
    }

    /// The names of the clips a folder holds (`audio/<clip>.pcm`, or the files directly in it), sorted.
    static func clipNames(_ clips: URL) -> [String] {
        for dir in [clips.appendingPathComponent("audio"), clips] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            // not the hidden files an archive made on a Mac can leave beside each clip (`._<clip>.pcm`)
            let names = files.filter { $0.hasSuffix(".pcm") && !$0.hasPrefix(".") }.map { String($0.dropLast(4)) }.sorted()
            if !names.isEmpty { return names }
        }
        return []
    }

    /// The conformance clips of a context the engine has no expected rows for, on the CPU engine: nothing to compare
    /// them with, so each clip's tokens and `log_probs` are only kept, for the parity of the Neural Engine.
    static func cpuTakes(_ model: TajweedModel, context: String, names: [String], clips: URL, timeout: Double) async -> [String: ProveTake] {
        var reference: [String: ProveTake] = [:]
        let options = TajweedSessionOptions(context: context, sampleRate: 16_000, backend: .cpu)
        for name in names {
            guard let url = audio(clips, name), let samples = pcm(url) else { continue }
            let (t, _) = await pushed(model, samples: samples, options: options, timeout: timeout)
            if t.error == nil { reference[name] = t }
        }
        return reference
    }

    /// The conformance clips on the Neural Engine against the CPU engine's takes: the tokens must be the same; the
    /// distance of `log_probs` is measured.
    static func parity(_ model: TajweedModel, context: String, build: String, reference: [String: ProveTake], clips: URL,
                       timeout: Double) async -> ProveParity {
        var p = ProveParity()
        var all: [Double] = []
        let options = TajweedSessionOptions(context: context, sampleRate: 16_000, backend: backend(for: build))
        for (clip, cpu) in reference.sorted(by: { $0.key < $1.key }) {
            guard let url = audio(clips, clip), let samples = pcm(url) else { continue }
            let (t, _) = await pushed(model, samples: samples, options: options, timeout: timeout)
            p.clips += 1
            if let e = t.error {
                p.errors += 1
                p.failed.append("\(clip): \(e)")
                continue
            }
            if t.name != build || t.switched {
                p.notOnAccelerator += 1
                p.failed.append("\(clip): ran on \(t.name), not on \(build)")
                continue
            }
            if t.tokens != cpu.tokens {
                p.tokenMismatches += 1
                p.failed.append("\(clip): \(edits(t.tokens, cpu.tokens)) token edits from the CPU engine")
            }
            if let d = distances(t.logProbs, cpu.logProbs, classes: cpu.classes) { all += d }
        }
        let s = spread(all)
        p.lpMean = s.mean
        p.lpP99 = s.p99
        p.frames = all.count
        return p
    }

    // MARK: the run

    /// Runs the proof and returns its report. `makeClient` makes the run's one Client.
    static func run(_ config: ProveConfig, doors: ProveDoors, out: ProveOut,
                    makeClient: @Sendable () throws -> TajweedClient) async -> ProveReport {
        let began = Date()
        out.redact([config.key, config.appId ?? "", config.storage.path, NSHomeDirectory()])
        var steps = titles.enumerated().map { ProveStep(number: $0.offset, title: $0.element, verdict: .notRun, note: "") }
        var measured: [ProveMeasured] = []
        var header: [String] = []
        var counts: [String] = []
        var facts = ProveFacts()
        facts.device = doors.deviceFields

        func report() -> ProveReport {
            var top = ["TajweedFormer for iOS and macOS: the proof on this Mac (\(doors.device))"]
            top += header
            top += counts
            top.append("wall time \(clock(Date().timeIntervalSince(began)))")
            let lines = summary(steps: steps, header: top, measured: measured, device: doors.device, facts: facts).map { out.scrub($0) }
            return ProveReport(steps: steps, summary: lines, status: status(steps), measured: measured)
        }

        // step 0: what the SDK itself needs of this Mac now (the script checked the rest before it built anything)
        out.say("step 0  this Mac: \(doors.device)")
        if !doors.osRunsCoreML {
            steps[0].verdict = .fail
            steps[0].note = "The Neural Engine's build needs macOS 15 or later: update macOS and run the script again."
            out.say("    STOP: \(steps[0].note)")
            return report()
        }
        if let why = await doors.blocker() {
            steps[0].verdict = .fail
            steps[0].note = "The Neural Engine's preparation would wait here: \(why). \(fix(blocker: why))"
            out.say("    STOP: \(steps[0].note)")
            return report()
        }
        steps[0].verdict = .pass

        // step 1: the Client and the signed config
        out.say("step 1  the Client and the signed config")
        let client: TajweedClient
        do {
            client = try makeClient()
        } catch {
            steps[1].verdict = .fail
            steps[1].note = stop(out, error)
            return report()
        }
        out.redact(doors.secrets())
        // the download starts now, as in an app that calls prefetch at launch; step 2 reads how it went
        let progress = ProveProgress(out)
        let launched = client
        let fetching = Task { await ProveOnMac.prefetch(launched, progress) }
        var d = await client.diagnose()
        let asked = Date()
        // until the server has answered the key and a verified config is in force; a refusal ends the wait at once
        while d.key.accepted != false, d.key.accepted == nil || d.config != "fresh", Date().timeIntervalSince(asked) < config.configTimeout {
            await pause(0.5)
            d = await client.diagnose()
        }
        // the summary's line about the SDK: from this diagnosis for now, from the last one when the run gets there
        // (the newest release the signed config names can change while the run goes on)
        let sdkAt = header.count
        header.append(sdkLine(version: d.sdkVersion, latest: d.sdkLatest))
        if d.key.accepted != true || d.config != "fresh" {
            steps[1].verdict = .fail
            if d.key.accepted == false, let refused = doors.refusal() {
                // the SDK's own error for the refusal: its message, and under it its fix
                steps[1].note = stop(out, refused.error, what: "the server refused the key: ")
                if appIdRefusals.contains(refused.serverCode) { out.say("    " + identifierAdvice) }
            } else if d.key.accepted == false {
                steps[1].note = "The server refused the key (\(d.key.reason ?? "it gave no reason"))."
                out.say("    \(steps[1].note)")
            } else {
                steps[1].note = "No signed config came within \(Int(config.configTimeout)) s (config \(d.config)): check the network and run the script again."
                out.say("    \(steps[1].note)")
            }
            fetching.cancel()
            client.close()
            return report()
        }
        let named = doors.configModel()
        out.say("    the key is accepted; the signed config names model \(named.version ?? "none"), build \(named.build ?? "none")")
        if named.build == nil {
            steps[1].verdict = .fail
            steps[1].note = "The signed config names no model build for this SDK and key (model_unavailable)."
        } else if let v = config.expectVersion, named.version != v {
            steps[1].verdict = .fail
            steps[1].note = "The config names version \(named.version ?? "none"), expected \(v)."
        } else if let b = config.expectBuild, named.build != b {
            steps[1].verdict = .fail
            steps[1].note = "The config names build \(named.build ?? "none"), expected \(b)."
        } else {
            steps[1].verdict = .pass
            steps[1].note = "model \(named.version ?? "?"), build \(named.build ?? "?")"
        }

        // step 2: the download with its progress, then the model, verified
        out.say("step 2  the download and its verification")
        var model: TajweedModel
        do {
            if let failed = await fetching.value { throw failed }
            model = try await client.model()
        } catch {
            steps[2].verdict = .fail
            steps[2].note = stop(out, error)
            client.close()
            return report()
        }
        let p = progress.snapshot
        let checked = doors.verify(model, config.expectVersion, config.expectBuild)
        out.say("    model \(model.version), build \(model.build); the manifest verifies with the release key \(doors.releaseKeyID): "
            + (checked.ok ? "yes" : "NO"))
        out.say("    \(checked.files) of the \(checked.listed) listed files are on this Mac, each checked by size and SHA-256 "
            + "(\(megabytes(checked.bytes)) MB); progress was reported \(p.calls) times, up to \(megabytes(p.done)) of \(megabytes(p.total)) MB")
        header.append("model \(model.version), build \(model.build), contexts \(model.contexts.joined(separator: " "))")
        facts.modelVersion = model.version
        facts.modelBuild = model.build
        if !checked.ok {
            steps[2].verdict = .fail
            steps[2].note = checked.problem ?? "the folder does not verify"
        } else if let v = config.expectVersion, model.version != v {
            steps[2].verdict = .fail
            steps[2].note = "the model is version \(model.version), expected \(v)"
        } else if let b = config.expectBuild, model.build != b {
            steps[2].verdict = .fail
            steps[2].note = "the model is build \(model.build), expected \(b)"
        } else if p.wentBack || (p.calls > 0 && p.done != p.total) {
            steps[2].verdict = .fail
            steps[2].note = "the progress ended at \(p.done) of \(p.total) bytes" + (p.wentBack ? " and went back" : "")
        } else {
            steps[2].verdict = .pass
            steps[2].note = "\(checked.files) files, \(megabytes(checked.bytes)) MB"
        }

        // the folder's self-test set: its clips are the Model's sample clips, its expected tokens what step 3 compares
        var clips: [TajweedClip] = []
        do {
            let fetched = try await doors.fetchSelfTest(model)
            await model.close()
            model = try await client.model()
            clips = model.sampleClips
            facts.clips = clips.count
            facts.cleanClips = clips.filter { $0.kind == "clean" }.count
            out.say("    the self-test set is on this Mac (\(fetched) files): \(clips.count) sample clips")
        } catch {
            steps[3].verdict = .fail
            steps[3].note = stop(out, error, what: "the self-test set could not be fetched: ")
        }

        let contexts = model.contexts.filter { config.contexts?.contains($0) ?? true }
        var takes = 0, matched = 0
        var clipProblems: [String] = []
        var ended: [ProveEnded] = []
        var engines: [String: (ok: Int, of: Int)] = [:]
        var conformances: [String: ProveConformance] = [:]
        var references: [String: [String: ProveTake]] = [:]
        var parities: [String: ProveParity] = [:]
        var rowsMissing: [String] = []

        func count(_ engine: String, _ ok: Int, _ of: Int) {
            let e = engines[engine] ?? (0, 0)
            engines[engine] = (e.ok + ok, e.of + of)
            takes += of
            matched += ok
        }

        /// One build's promotion and, when it is promoted, its takes on the Neural Engine, for one context.
        func accelerator(_ model: TajweedModel, _ ctx: String, _ build: String, _ expected: [String: [Int]]) async {
            guard let first = clips.first else { return }
            let r = await promote(model, context: ctx, build: build, clip: first, config: config, doors: doors, out: out)
            let record = doors.promotion(model, build, ctx)
            var end = ProveEnded(build: build, context: ctx, outcome: r.outcome, measures: nil)
            /// What the golden stage measured against what it was judged by, as lines of the run: per head the
            /// measure next to the signed bound, so a line shows why the build passed or which measure was outside.
            func golden(_ m: ProveMeasures) {
                for (i, line) in judgement(m, build: build).enumerated() {
                    out.say((i == 0 ? "        " : "          ") + line)
                }
            }
            switch r.outcome {
            case .promoted:
                end.measures = record?.measures
                if let m = record?.measures {
                    measured.append(ProveMeasured(build: build, context: ctx, measures: m))
                    golden(m)
                    var timing: [String] = []
                    if let ms = record?.compileMs { timing.append(String(format: "compile %.1f s", ms / 1000)) }
                    if let a = record?.acceleratorMedianMs, let c = record?.cpuMedianMs {
                        timing.append(String(format: "chunk median %.2f ms against the CPU engine's %.2f ms", a, c))
                    }
                    if !timing.isEmpty { out.say("          " + timing.joined(separator: "; ")) }
                }
            case .demoted(let reason, let detail):
                // the pipeline's answer, not a failure: this build is not used here, and the CPU engine runs
                let judged = record?.measures?.tolerance != nil
                out.say("        \(build) \(ctx): stays on the CPU engine: \(words(reason: reason, tolerance: judged))"
                    + (detail.isEmpty ? "" : " (\(detail))"))
                // a golden stage that did not pass measured something too: its record goes with the others, as not passed
                if record?.stage == "golden", let m = record?.measures {
                    end.measures = m
                    measured.append(ProveMeasured(build: build, context: ctx, measures: m, passed: false))
                    golden(m)
                }
            case .failed(let why):
                out.say("        \(build) \(ctx): the pipeline failed: \(why)")
            }
            ended.append(end)
            guard r.outcome == .promoted else { return }
            let got = await sampleClips(model, clips: clips, expected: expected, context: ctx, backend: backend(for: build), wantName: build,
                                        timeout: config.takeTimeout)
            count(build, got.ok, clips.count)
            clipProblems += got.problems.map { "\(ctx) \(build): \($0)" }
            out.say("    \(ctx) on \(build): \(got.ok) of \(clips.count) sample clips give the expected tokens")
            if let folder = config.clips, let reference = references[ctx], !reference.isEmpty {
                let par = await parity(model, context: ctx, build: build, reference: reference, clips: folder, timeout: config.takeTimeout)
                parities["\(build) \(ctx)"] = par
                out.say("    \(ctx) on \(build), the conformance clips: \(par.clips - par.tokenMismatches - par.notOnAccelerator - par.errors) of \(par.clips) "
                    + "give the CPU engine's tokens; log_probs lp_mean \(number(par.lpMean)), lp_p99 \(number(par.lpP99)) over \(par.frames) frames")
            }
        }

        if steps[3].verdict != .fail {
            out.say("steps 3 to 5  context by context: the sample clips on the CPU engine, the conformance clips, each build's "
                + "promotion, then the same clips on the Neural Engine")
            // the CPU engine, then each CoreML build of the run, context by context
            for ctx in contexts {
                guard let expected = doors.expectedTokens(model, ctx) else {
                    clipProblems.append("\(ctx): the folder has no selftest/expected_\(ctx).json")
                    continue
                }
                let got = await sampleClips(model, clips: clips, expected: expected, context: ctx, backend: .cpu, wantName: "cpu",
                                            timeout: config.takeTimeout)
                count("cpu", got.ok, clips.count)
                clipProblems += got.problems.map { "\(ctx) cpu: \($0)" }
                out.say("    \(ctx) on the CPU engine: \(got.ok) of \(clips.count) sample clips give the expected tokens")
                if let folder = config.clips {
                    let file = config.expectedRows?.appendingPathComponent("v4_\(ctx)_audio_expected.jsonl")
                    if let file, let wanted = Self.rows(file), !wanted.isEmpty {
                        let c = await conformance(model, context: ctx, rows: wanted, clips: folder, timeout: config.takeTimeout)
                        conformances[ctx] = c.result
                        references[ctx] = c.reference
                        out.say("    \(ctx), the conformance clips on the CPU engine: \(c.result.clips) clips, \(c.result.chunks) chunks, "
                            + "\(c.result.outputs) chunk outputs (\(c.result.values) values), \(c.result.mismatches) mismatches")
                    } else {
                        rowsMissing.append(ctx)
                        // the engine has audio rows for some contexts only: here the CPU engine's own takes are still
                        // what the Neural Engine's are compared with
                        let hasBuild = config.builds.contains { doors.hasBuild(model, $0, ctx) }
                        if hasBuild {
                            let kept = await cpuTakes(model, context: ctx, names: clipNames(folder), clips: folder, timeout: config.takeTimeout)
                            references[ctx] = kept
                            out.say("    \(ctx), the conformance clips: the engine has no expected rows for this context; "
                                + "\(kept.count) clips taken on the CPU engine for the Neural Engine's comparison")
                        }
                    }
                }
                // a build is asked for through the Session's backend, so one Client and one Model serve them all
                for build in config.builds where doors.hasBuild(model, build, ctx) {
                    await accelerator(model, ctx, build, expected)
                }
            }

            var engineNotes: [String] = []
            for name in engines.keys.sorted() {
                if let e = engines[name] { engineNotes.append("\(name) \(e.ok) of \(e.of)") }
            }
            steps[3].verdict = takes > 0 && matched == takes && clipProblems.isEmpty ? .pass : .fail
            steps[3].note = engineNotes.joined(separator: ", ")
            // step 4: a build that ended on the CPU engine for a reason the pipeline names is the pipeline's answer
            let pipeline = pipelineVerdict(ended)
            steps[4].verdict = pipeline.verdict
            steps[4].note = pipeline.note
            for line in clipProblems.prefix(12) { out.say("    problem: \(line)") }
            if let firstProblem = clipProblems.first, steps[3].verdict == .fail { steps[3].note += "; " + firstProblem }
        }

        // step 5: optional
        if config.clips == nil {
            steps[5].verdict = .skipped
            steps[5].note = "no clips folder was given (the second argument); the run is complete without it"
        } else if conformances.isEmpty {
            steps[5].verdict = .fail
            steps[5].note = "no expected rows were found (v4_<context>_audio_expected.jsonl in the engine's conformance folder)"
        } else {
            var clipTakes = 0, chunkCount = 0, valueCount = 0, mismatches = 0
            for c in conformances.values {
                clipTakes += c.clips
                chunkCount += c.chunks
                valueCount += c.values
                mismatches += c.mismatches
            }
            var parityTakes = 0, parityBad = 0
            for q in parities.values {
                parityTakes += q.clips
                parityBad += q.tokenMismatches + q.notOnAccelerator + q.errors
            }
            steps[5].verdict = mismatches == 0 && parityBad == 0 ? .pass : .fail
            var note = "CPU: \(clipTakes) clip takes, \(chunkCount) chunks, \(valueCount) values, \(mismatches) mismatches"
            if !parities.isEmpty { note += "; Neural Engine: \(parityTakes) clip takes, \(parityBad) with other tokens" }
            if !rowsMissing.isEmpty { note += "; no expected rows for " + rowsMissing.joined(separator: " ") }
            steps[5].note = note
            for c in conformances.sorted(by: { $0.key < $1.key }) { for f in c.value.failed.prefix(3) { out.say("    problem: \(c.key): \(f)") } }
            for q in parities.sorted(by: { $0.key < $1.key }) { for f in q.value.failed.prefix(3) { out.say("    problem: \(q.key): \(f)") } }
        }
        var promotedCount = 0
        for e in ended where e.outcome == .promoted { promotedCount += 1 }
        counts.append("takes \(takes) (\(matched) with the expected tokens), builds through the pipeline \(ended.count) (\(promotedCount) promoted)")
        for q in parities.sorted(by: { $0.key < $1.key }) {
            counts.append("conformance clips on \(q.key): lp_mean \(number(q.value.lpMean)), lp_p99 \(number(q.value.lpP99)), "
                + "\(q.value.frames) frames, \(q.value.tokenMismatches) of \(q.value.clips) clips with other tokens")
        }

        // step 6: diagnose
        out.say("step 6  diagnose")
        let last = await client.diagnose()
        for line in last.json.split(separator: "\n") { out.say("    " + String(line)) }
        // the summary says about the SDK what the report printed here says
        header[sdkAt] = sdkLine(version: last.sdkVersion, latest: last.sdkLatest)
        let parsed = ((try? JSONSerialization.jsonObject(with: Data(last.json.utf8))) as? [String: Any]) != nil
        var telemetry = ""
        if let t = await doors.flushTelemetry() {
            telemetry = "telemetry: \(t.sent) sent, \(t.waiting) waiting"
            out.say("    \(telemetry)")
        }
        if !parsed {
            steps[6].verdict = .fail
            steps[6].note = "the report is not JSON"
        } else if last.key.accepted != true || last.model?.version != model.version || last.model?.build != model.build {
            steps[6].verdict = .fail
            steps[6].note = "the report does not name the accepted key and the model in use"
        } else {
            steps[6].verdict = .pass
            steps[6].note = "config \(last.config), last error \(last.lastError ?? "none")" + (telemetry.isEmpty ? "" : ", " + telemetry)
        }
        await model.close()
        client.close()
        return report()
    }
}
