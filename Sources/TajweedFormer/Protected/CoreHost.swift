import CryptoKit
import Foundation
import QuranLabCore

/// A refusal of the Core: its status (qlcore.h `QLC_E_*`) and the reader's or the lease's own code (`qlc_detail`,
/// named `QLC_D_*` since quranlab-core cd24aa3).
struct CoreFailure: Error, Equatable, Sendable {
    /// A `QLC_E_*` value (qlcore.h's anonymous enum, which Swift imports as Int).
    let status: Int
    /// A `QLC_D_*` value: the lease's refusal after `QLC_E_LEASE`, the container's after `QLC_E_FILE`, the accelerator's
    /// after `QLC_E_ENGINE` from `qlc_accel_prepare`.
    let detail: Int
    let call: String

    init(status: Int, detail: Int, call: String) {
        self.status = status
        self.detail = detail
        self.call = call
    }

    init(_ status: Int32, detail: Int32 = 0, call: String) {
        self.init(status: Int(status), detail: Int(detail), call: call)
    }

    /// The SDK's error for it. The Core names no file, format or key in a failure (18.6.5); neither does this.
    var recognizerError: RecognizerError {
        switch status {
        case QLC_E_NEEDS_CONNECTION: return .offline("needs_connection: no valid lease for this model on the device")
        case QLC_E_LEASE where detail == QLC_D_LEASE_NO_ACCEL:
            return .neuralEngineUnavailable("the lease in force does not allow accelerator programs (\(call))")
        case QLC_E_LEASE where detail == QLC_D_LEASE_EXPIRED:
            return .offline("needs_connection: the lease has expired (\(call))")
        case QLC_E_LEASE: return .offline("the lease was refused by the Core (\(call), detail \(detail)); a new one is needed")
        case QLC_E_FILE: return .checksumMismatch(file: "a model file (\(call), detail \(detail))")
        case QLC_E_MANIFEST: return .manifestInvalid("the Core refused the manifest (\(call), detail \(detail))")
        case QLC_E_STOPPED: return .serverRejected(status: 401, code: "invalid_key", message: "a verified stop removed the model")
        case QLC_E_KEYSTORE: return .storageFailed("the install key store failed (\(call))")
        case QLC_E_STORAGE: return .storageFailed("the model's storage failed (\(call), detail \(detail))")
        case QLC_E_BUSY: return .engineFailed(code: status, message: "\(call): a model of this Core is open")
        case QLC_E_ENGINE where call == "qlc_accel_prepare":
            return .neuralEngineUnavailable("the accelerator program was not prepared (\(Self.accelName(detail)))")
        default: return .engineFailed(code: status, message: "\(call) failed (\(status), detail \(detail))")
        }
    }

    /// The container check that refused the plaintext at install (18.2.4, `plain_sha256`): the issue the SDK reports.
    var isPlaintextMismatch: Bool { status == QLC_E_FILE && detail == QLC_D_FILE_PLAIN_SHA256 }

    /// `qlc_install` or `qlc_model_open` while a model of this Core is open.
    var isBusy: Bool { status == QLC_E_BUSY }

    /// Why `qlc_accel_prepare` left the device on the CPU engine (`QLC_D_ACCEL_*`), as the promotion reports it.
    static func accelName(_ detail: Int) -> String {
        switch detail {
        case QLC_D_ACCEL_RUNTIME: return "accel_runtime"
        case QLC_D_ACCEL_HOOKED: return "accel_hooked"
        case QLC_D_ACCEL_PROGRAM: return "accel_program"
        case QLC_D_ACCEL_CONTRACT: return "accel_contract"
        case QLC_D_ACCEL_PLATFORM: return "accel_platform"
        case QLC_D_ACCEL_FILES: return "accel_files"
        default: return "accel_\(detail)"
        }
    }
}

/// Where the Core stands with its lease, read on the background timer (`qlc_tick`; never the audio thread).
struct CoreLeaseStatus: Sendable, Equatable {
    var hasLease = false
    var valid = false
    var refreshDue = false
    var stopped = false
    /// The Core's clock (18.4.7), and the lease's times, unix seconds.
    var now: Int64 = 0
    var expiresAt: Int64 = 0
    var refreshAfter: Int64 = 0
}

/// The recited range the Core's detector counted for a take (SDK 3.2 in the Core; R5 since quranlab-core cd24aa3).
struct CoreRecited: Sendable, Equatable {
    let surah: Int
    let first: Int
    let last: Int
    let score: Int
    /// The take's UTC day (days since 1970-01-01, the Core's clock), the day it was counted into; -1 when unknown.
    var day: Int64 = -1
    /// The session context (the last counted take) decided this take (17.6 `recited_takes.context`).
    var context = false
    /// Equally good ranges the raw search found besides the one it chose.
    var ties = 0
    /// A wrapper marked the take reported (`qlc_recited_reported`, Android's; the Apple SDK keeps its own pending set).
    var reported = false
}

/// The install's learner days as the Core's journal keeps them (R10, `qlc_days`): days since 1970-01-01, UTC days and
/// the learner's local days.
struct CoreDays: Sendable, Equatable {
    var firstDay: Int64 = -1
    var active: [Int64] = []
    var local: [Int64] = []
    /// The last active UTC days and the streak (consecutive active local days up to that day's local day) at each.
    var streaks: [Int64: Int] = [:]
    /// UTC days whose learner facts were sent.
    var sealed: [Int64] = []
    /// Mondays (UTC) with their judged and correct ayahs.
    var weeks: [Int64: (judged: Int, correct: Int)] = [:]
    var trendWeek: Int64 = -1

    static func == (a: CoreDays, b: CoreDays) -> Bool {
        a.firstDay == b.firstDay && a.active == b.active && a.local == b.local && a.streaks == b.streaks && a.sealed == b.sealed
            && a.trendWeek == b.trendWeek && a.weeks.mapValues { [$0.judged, $0.correct] } == b.weeks.mapValues { [$0.judged, $0.correct] }
    }
}

/// One Core (`qlc_core`) over one install key. Every call is serialised here, and each names the build folder it
/// works on so the storage callbacks find the right files. A new install key (a new attest) makes a new host; a model
/// opened by the old one keeps it alive until it closes.
final class CoreHost: @unchecked Sendable {
    let platform: CorePlatform
    private let core: OpaquePointer
    private let calls = NSLock()
    /// Held by every call that names a build folder, and for the whole of a call on the open model's folder that runs
    /// outside `calls` (the reference data at first use, an accelerator program's prepare): the storage callbacks find
    /// one folder at a time.
    private let buildLock = NSLock()

    /// The Core's release and target (`qlc_version`: "4.0.0-c1 ios-arm64"), public.
    static var version: String { String(cString: qlc_version()) }
    /// The notice to people and AI assistants every Core binary carries (core/notice.h).
    static var notice: String { String(cString: qlc_notice()) }

    init(platform: CorePlatform) throws(CoreFailure) {
        self.platform = platform
        var status: Int32 = 0
        let saved = platform.state.load()
        var table = platform.table
        let c: OpaquePointer? = withUnsafePointer(to: &table) { t in
            if let saved, !saved.isEmpty {
                return saved.withUnsafeBytes { qlc_create(t, $0.bindMemory(to: UInt8.self).baseAddress, saved.count, &status) }
            }
            return qlc_create(t, nil, 0, &status)
        }
        guard let c else { throw CoreFailure(status, call: "qlc_create") }
        core = c
    }

    deinit { qlc_destroy(core) }

    var installHash: String { platform.key.installHash }

    private func call<T>(_ build: URL?, _ body: () throws(CoreFailure) -> T) throws(CoreFailure) -> T {
        if build != nil { buildLock.lock() }
        calls.lock()
        defer {
            platform.storage.setBuild(nil)
            calls.unlock()
            if build != nil { buildLock.unlock() }
        }
        platform.storage.setBuild(build)
        return try body()
    }

    /// A call on the open model that reads its build's files and may run long (the reference data at first use, an
    /// accelerator program's decryption and the runtime's compile): the folder is pinned for the storage callbacks, and
    /// the Core's other calls (the timer, the lease) go on meanwhile; a call naming another folder waits.
    func withModelFolder<T>(_ folder: URL, _ body: () -> T) -> T {
        buildLock.lock()
        platform.storage.setPinned(folder)
        defer {
            platform.storage.setPinned(nil)
            buildLock.unlock()
        }
        return body()
    }

    /// The refusal code behind the last negative status (`qlc_detail`).
    var detail: Int32 { qlc_detail(core) }

    private func failure(_ status: Int32, _ name: String) -> CoreFailure {
        CoreFailure(status, detail: qlc_detail(core), call: name)
    }

    private static func ok(_ status: Int32) -> Bool { Int(status) == QLC_OK }

    // MARK: the lease (18.4.4 to 18.4.10)

    /// The request's `core` object (release, target, proof, signals, piece) and `install_sig` over
    /// "quranlab-lease-ask 1\n" challenge "\n" build "\n".
    func leaseAsk(challenge: String, build: String) throws(CoreFailure) -> (core: [String: Any], installSig: String) {
        try call(nil) { () throws(CoreFailure) -> ([String: Any], String) in
            var json = [CChar](repeating: 0, count: 512)
            var sig = [CChar](repeating: 0, count: 256)
            let st = qlc_lease_ask(core, challenge, build, &json, json.count, &sig, sig.count)
            guard Self.ok(st) else { throw failure(st, "qlc_lease_ask") }
            let text = String(cString: json)
            guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
                throw CoreFailure(status: QLC_E_ARG, detail: 0, call: "qlc_lease_ask")
            }
            return (o, String(cString: sig))
        }
    }

    /// Accepts the binary lease of an answer for the build and signed manifest it was asked for; `exp` and
    /// `refresh_after` as the Core holds them.
    func leaseAccept(_ lease: Data, manifest: Data, build: String) throws(CoreFailure) -> (expiresAt: Int64, refreshAfter: Int64) {
        try call(nil) { () throws(CoreFailure) -> (Int64, Int64) in
            var exp: Int64 = 0, ra: Int64 = 0
            let st = lease.withUnsafeBytes { l in
                manifest.withUnsafeBytes { m in
                    qlc_lease_accept(core, l.bindMemory(to: UInt8.self).baseAddress, lease.count,
                                     m.bindMemory(to: CChar.self).baseAddress, manifest.count, build, &exp, &ra)
                }
            }
            guard Self.ok(st) else { throw failure(st, "qlc_lease_accept") }
            return (exp, ra)
        }
    }

    /// A refusal body of the lease route. True when it was a verified signed stop: the Core cleared its lease and
    /// removed the model's device forms. Anything else changes nothing but the data piece in force.
    func refusal(_ body: Data, apiKeyID: String) -> Bool {
        (try? call(nil) { () throws(CoreFailure) -> Bool in
            let st = body.withUnsafeBytes { b in qlc_refusal_accept(core, b.bindMemory(to: CChar.self).baseAddress, body.count, apiKeyID) }
            return Int(st) == QLC_E_STOPPED
        }) ?? false
    }

    /// A data piece of a lease answer (18.6.7), handed over right after the accept of the same answer, always. Data
    /// only: the Core verifies its signature and keeps it pending until the next model open (spec fix 16); it becomes
    /// the last good piece only once a lease asked under it was accepted and a model opened after that.
    @discardableResult
    func piece(_ d: Data) -> Bool {
        (try? call(nil) { () throws(CoreFailure) -> Bool in
            Self.ok(d.withUnsafeBytes { qlc_lease_piece(core, $0.bindMemory(to: UInt8.self).baseAddress, d.count) })
        }) ?? false
    }

    /// 18.4.7.1 (quranlab-core f006676, Core c3): a lease attempt that brought no lease, told to the Core by the
    /// answer that ended it (`qlc_lease_attempt`): refused for the API's own refusal, unreachable for anything else.
    /// The Core keeps it with the lease in its saved state; a refusal ends the lease's grace for good.
    @discardableResult
    func leaseAttempt(refused: Bool) -> Int32 {
        (try? call(nil) { () throws(CoreFailure) -> Int32 in
            qlc_lease_attempt(core, Int32(refused ? QLC_ATTEMPT_REFUSED : QLC_ATTEMPT_UNREACHABLE))
        }) ?? Int32(QLC_E_ARG)
    }

    /// 18.4.7.1: whether the lease in force is past its `exp` and in its grace (`qlc_lease_grace`: up to 24 hours more
    /// while Quran Lab cannot be reached, never after a refusal), and until when (unix seconds, the Core's clock).
    func leaseGrace() -> (inGrace: Bool, until: Int64) {
        (try? call(nil) { () throws(CoreFailure) -> (Bool, Int64) in
            var until: Int64 = 0
            let r = qlc_lease_grace(core, &until)
            return (r == 1, until)
        }) ?? (false, 0)
    }

    func tick() -> CoreLeaseStatus {
        (try? call(nil) { () throws(CoreFailure) -> CoreLeaseStatus in
            var s = qlc_lease_status()
            _ = qlc_tick(core, &s)
            return CoreLeaseStatus(hasLease: s.has_lease != 0, valid: s.valid != 0, refreshDue: s.refresh_due != 0, stopped: s.stopped != 0,
                                   now: s.now, expiresAt: s.exp, refreshAfter: s.refresh_after)
        }) ?? CoreLeaseStatus()
    }

    /// Audio seconds the streams processed, per UTC day of the Core's clock: today and the day before.
    func usage() -> (day: Int64, seconds: Double, previousDay: Int64, previousSeconds: Double) {
        (try? call(nil) { () throws(CoreFailure) -> (Int64, Double, Int64, Double) in
            var d: Int64 = 0, pd: Int64 = 0
            var s = 0.0, ps = 0.0
            _ = qlc_usage(core, &d, &s, &pd, &ps)
            return (d, s, pd, ps)
        }) ?? (0, 0, 0, 0)
    }

    /// Whether the lease the Core holds allows accelerator programs (flags bit 3), asked before the accelerator build's
    /// 110 to 167 MB are downloaded: 1 or 0, else the Core's status (no lease, a verified stop). Nil with a Core that
    /// does not export the call.
    func accelAllowed() -> Int32? {
        guard let f = CoreOptional.accelAllowed else { return nil }
        return try? call(nil) { () throws(CoreFailure) -> Int32 in f(core) }
    }

    // MARK: install and open

    /// CDN form to device form for one file of `build` (18.2.1): read from `<path>.qle`, written to `<path>.qld`, the
    /// plaintext SHA-256 checked against the signed manifest once, the mark applied. No plaintext reaches the disk.
    /// Beside an open model (quranlab-core d128af8): refused (`QLC_E_BUSY`) only for a file that model reads (its build's
    /// files of context "*" or its context). The call names `build`, so the storage reads and writes that folder only;
    /// the open model's own later reads (the reference data, an accelerator program) pin its folder and wait for it.
    func install(manifest: Data, path: String, in build: URL) throws(CoreFailure) {
        try call(build) { () throws(CoreFailure) -> Void in
            let st = manifest.withUnsafeBytes { m in qlc_install(core, m.bindMemory(to: CChar.self).baseAddress, manifest.count, path) }
            guard Self.ok(st) else { throw failure(st, "qlc_install") }
        }
    }

    /// The model of `build` for one context, decrypted into the Core's memory from the device forms and the lease.
    func open(manifest: Data, in build: URL, context: String, threads: Int) throws(CoreFailure) -> CoreModel {
        try call(build) { () throws(CoreFailure) -> CoreModel in
            var o = qlc_open_default_options()
            o.threads = Int32(threads)
            var status: Int32 = 0
            let m: OpaquePointer? = context.withCString { ctx in
                o.context = ctx
                return manifest.withUnsafeBytes { b in qlc_model_open(core, b.bindMemory(to: CChar.self).baseAddress, manifest.count, &o, &status) }
            }
            guard let m else { throw failure(status, "qlc_model_open") }
            return CoreModel(host: self, handle: m, context: context, folder: build)
        }
    }

    // MARK: the recited range (SDK 3.2, contract 17.5, 17.6)

    /// The prebuilt index of `build` (its manifest's `recited` entry, checked against its signed SHA-256).
    func recitedIndex(manifest: Data, in build: URL) throws(CoreFailure) {
        try call(build) { () throws(CoreFailure) -> Void in
            let st = manifest.withUnsafeBytes { m in qlc_recited_index(core, m.bindMemory(to: CChar.self).baseAddress, manifest.count) }
            guard Self.ok(st) else { throw failure(st, "qlc_recited_index") }
        }
    }

    /// Opens a take in the journal; false when that take id was finished already.
    func recitedBegin(_ take: UInt64) -> Bool {
        (try? call(nil) { () throws(CoreFailure) -> Bool in qlc_recited_begin(core, take) == 0 }) ?? false
    }

    /// The take a killed process left open, when there is one.
    func recitedOpen() -> UInt64? {
        (try? call(nil) { () throws(CoreFailure) -> UInt64? in
            var id: UInt64 = 0
            return qlc_recited_open(core, &id) == 1 ? id : nil
        }) ?? nil
    }

    /// The take's units so far are the stream's greedy transcript (after a push or at the end).
    func recitedFeed(_ stream: OpaquePointer) {
        _ = try? call(nil) { () throws(CoreFailure) -> Int32 in qlc_recited_feed_stream(core, stream) }
    }

    private static func recited(_ r: qlc_recited_result) -> CoreRecited? {
        guard r.found != 0 else { return nil }
        return CoreRecited(surah: Int(r.surah), first: Int(r.first), last: Int(r.last), score: Int(r.score), day: r.day,
                           context: r.context != 0, ties: Int(r.ties), reported: r.reported != 0)
    }

    /// Finishes a take: the range it counted, or nil. The same take id again gives the stored result.
    func recitedFinish(_ take: UInt64, flags: UInt32) -> CoreRecited? {
        (try? call(nil) { () throws(CoreFailure) -> CoreRecited? in
            var r = qlc_recited_result()
            guard Self.ok(qlc_recited_finish(core, take, flags, &r)) else { return nil }
            return Self.recited(r)
        }) ?? nil
    }

    /// The finished takes the journal remembers (the last 64), oldest first, with their results (R5): a take whose
    /// result a killed process lost is found again here.
    func recitedDone() -> [(take: UInt64, range: CoreRecited?)] {
        (try? call(nil) { () throws(CoreFailure) -> [(take: UInt64, range: CoreRecited?)] in
            // the count (i below 0); with i below the count, that take's id and result (and the count again)
            var id: UInt64 = 0
            let n = qlc_recited_done(core, -1, nil, nil)
            guard n > 0 else { return [] }
            var out: [(take: UInt64, range: CoreRecited?)] = []
            for i in 0..<n {
                var rr = qlc_recited_result()
                guard qlc_recited_done(core, i, &id, &rr) >= 0 else { continue }
                out.append((id, Self.recited(rr)))
            }
            return out
        }) ?? []
    }

    // MARK: the learner's days (R10: 17.6, 17.8, 17.9; in the recited journal)

    /// A take with audio on this UTC day and this local day (days since 1970-01-01).
    @discardableResult
    func daysMark(utc: Int64, local: Int64) -> Bool {
        (try? call(nil) { () throws(CoreFailure) -> Bool in Self.ok(qlc_days_mark(core, utc, local)) }) ?? false
    }

    /// Judged and correct ayahs into the week of `utc`.
    @discardableResult
    func daysJudged(utc: Int64, judged: Int, correct: Int) -> Bool {
        (try? call(nil) { () throws(CoreFailure) -> Bool in Self.ok(qlc_days_judged(core, utc, Int32(judged), Int32(correct))) }) ?? false
    }

    /// The day's learner facts were sent (once).
    @discardableResult
    func daysSeal(utc: Int64) -> Bool {
        (try? call(nil) { () throws(CoreFailure) -> Bool in Self.ok(qlc_days_seal(core, utc)) }) ?? false
    }

    /// The week's trend was sent (once).
    @discardableResult
    func daysTrendSent(week: Int64) -> Bool {
        (try? call(nil) { () throws(CoreFailure) -> Bool in Self.ok(qlc_days_trend_sent(core, week)) }) ?? false
    }

    func daysRead() -> CoreDays? {
        (try? call(nil) { () throws(CoreFailure) -> CoreDays? in
            var d = qlc_days()
            guard Self.ok(qlc_days_read(core, &d)) else { return nil }
            func ints<T>(_ tuple: inout T, _ n: Int32) -> [Int64] {
                withUnsafeBytes(of: &tuple) { Array($0.bindMemory(to: Int64.self).prefix(max(0, Int(n)))) }
            }
            func int32s<T>(_ tuple: inout T, _ n: Int32) -> [Int] {
                withUnsafeBytes(of: &tuple) { $0.bindMemory(to: Int32.self).prefix(max(0, Int(n))).map(Int.init) }
            }
            var out = CoreDays()
            out.firstDay = d.first_day
            out.active = ints(&d.active, d.n_active)
            out.local = ints(&d.local, d.n_local)
            let sd = ints(&d.streak_day, d.n_streak), sv = int32s(&d.streak, d.n_streak)
            for (k, v) in zip(sd, sv) { out.streaks[k] = v }
            out.sealed = ints(&d.sealed, d.n_sealed)
            let wk = ints(&d.week, d.n_weeks), j = int32s(&d.judged, d.n_weeks), c = int32s(&d.correct, d.n_weeks)
            for i in 0..<min(wk.count, j.count, c.count) { out.weeks[wk[i]] = (j[i], c[i]) }
            out.trendWeek = d.trend_week
            return out
        }) ?? nil
    }
}

/// One open model of the Core (`qlc_model`): the plaintext lives only in the Core's memory, and is wiped when this
/// closes. The Core has one open model at a time.
///
/// Its streams (a CPU stream, and since R2 a stream on the prepared accelerator program) may run on different threads
/// at once; each stream belongs to one thread at a time. Every call on the model or a stream is counted while it runs,
/// and the model is closed only when none runs: a close waits for them a little, and otherwise the last one to end
/// closes it. A stream never outlives its model.
final class CoreModel: @unchecked Sendable {
    let host: CoreHost
    let context: String
    /// The build folder it was opened from (the Core reads the reference data and accelerator programs from it later).
    let folder: URL
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var closing = false
    private var inFlight = 0
    private var slots: [StreamSlot] = []

    init(host: CoreHost, handle: OpaquePointer, context: String, folder: URL) {
        self.host = host
        self.handle = handle
        self.context = context
        self.folder = folder
    }

    deinit { close(wait: 0) }

    /// The handle for one call, counted until `leave`; nil once the model is closing.
    private func enter() -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle, !closing else { return nil }
        inFlight += 1
        return h
    }

    private func leave() {
        lock.lock()
        inFlight -= 1
        let owed = closing && inFlight == 0 ? takeForClose() : nil
        lock.unlock()
        if let owed { Self.release(owed) }
    }

    /// With `lock` held: the handle and the streams, once nothing runs.
    private func takeForClose() -> (OpaquePointer, [StreamSlot])? {
        guard let h = handle, inFlight == 0 else { return nil }
        handle = nil
        let s = slots
        slots = []
        return (h, s)
    }

    /// Every stream destroyed, then the model closed (its plaintext and any accelerator program wiped).
    private static func release(_ x: (OpaquePointer, [StreamSlot])) {
        for slot in x.1 {
            slot.calls.lock()
            if let s = slot.stream { qlc_stream_destroy(s) }
            slot.stream = nil
            slot.calls.unlock()
        }
        qlc_model_close(x.0)
    }

    var chunkMs: Int {
        guard let h = enter() else { return 0 }
        defer { leave() }
        return Int(qlc_model_chunk_ms(h))
    }

    /// calibration.json's bytes (public data, SPEC 4).
    var calibration: Data? {
        guard let h = enter() else { return nil }
        defer { leave() }
        var n = 0
        guard let p = qlc_calibration(h, &n), n > 0 else { return nil }
        return Data(bytes: p, count: n)
    }

    /// The open model's vocabulary (R4: its build's tokens.txt, public), in id order.
    var tokens: [String]? {
        guard let h = enter() else { return nil }
        defer { leave() }
        let n = Int(qlc_model_token_count(h))
        guard n > 0 else { return nil }
        var out: [String] = []
        for i in 0..<n {
            guard let p = qlc_model_token_name(h, Int32(i)) else { return nil }
            out.append(String(cString: p))
        }
        return out
    }

    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return handle != nil && !closing }

    /// A call on the open model's handle (nil once it is closing), counted while it runs.
    func withHandle<T>(_ body: (OpaquePointer) -> T?) -> T? {
        guard let h = enter() else { return nil }
        defer { leave() }
        return body(h)
    }

    // MARK: R3, the reference data

    /// One ayah's expected units and word starts (SPEC 13.7). The Core reads the build's reference data at the first
    /// call (it needs the lease then, as an open does: `needs_connection` and the like, tried again at the next call).
    func reference(surah: Int, ayah: Int) -> Result<(units: [Int], wordStarts: [Int]), CoreFailure> {
        guard let h = enter() else { return .failure(CoreFailure(status: QLC_E_ENGINE, detail: 0, call: "qlc_reference_expected")) }
        defer { leave() }
        var units = [Int32](repeating: 0, count: 4096)
        var words = [Int32](repeating: 0, count: 1024)
        var nWords: Int32 = 0
        let (n, detail) = host.withModelFolder(folder) { () -> (Int32, Int32) in
            let n = units.withUnsafeMutableBufferPointer { u in
                words.withUnsafeMutableBufferPointer { w in
                    qlc_reference_expected(h, Int32(surah), Int32(ayah), u.baseAddress, Int32(u.count), w.baseAddress, Int32(w.count), &nWords)
                }
            }
            return (n, n < 0 ? host.detail : 0)
        }
        guard n >= 0 else { return .failure(CoreFailure(n, detail: detail, call: "qlc_reference_expected")) }
        return .success((units: units.prefix(Int(n)).map(Int.init), wordStarts: words.prefix(Int(max(0, nWords))).map(Int.init)))
    }

    // MARK: R2, the accelerator program

    /// The build's accelerator program of `kind` ("coreml", "coreml-compact") decrypted into the Core's memory and
    /// handed to the runtime by the Core (`qlc_accel_prepare`): from memory where the build ships the specification,
    /// else through a short-lived compiled package in `dispatchDir` that the Core deletes before it returns. Seconds
    /// long; never on the audio thread. The backend's name ("coreml:memory", "coreml:file"), or why not.
    func accelPrepare(kind: String, dispatchDir: URL) -> Result<String, CoreFailure> {
        guard let prepare = CoreOptional.accelPrepare else {
            return .failure(CoreFailure(status: QLC_E_ENGINE, detail: QLC_D_ACCEL_RUNTIME, call: "qlc_accel_prepare"))
        }
        guard let h = enter() else { return .failure(CoreFailure(status: QLC_E_ENGINE, detail: 0, call: "qlc_accel_prepare")) }
        defer { leave() }
        var name = [CChar](repeating: 0, count: 64)
        let (st, detail) = host.withModelFolder(folder) { () -> (Int32, Int32) in
            let st = name.withUnsafeMutableBufferPointer { b in prepare(h, kind, dispatchDir.path, b.baseAddress, b.count) }
            return (st, Int(st) == QLC_OK ? 0 : host.detail)
        }
        guard Int(st) == QLC_OK else { return .failure(CoreFailure(st, detail: detail, call: "qlc_accel_prepare")) }
        return .success(String(cString: name))
    }

    /// The prepared program wiped and released (the model's close does the same).
    func accelRelease() {
        guard let f = CoreOptional.accelRelease, let h = enter() else { return }
        defer { leave() }
        _ = f(h)
    }

    // MARK: streams

    /// A stream on this model: the stream itself, its own lock (one thread at a time), and whether a take runs on it.
    final class StreamSlot: @unchecked Sendable {
        var stream: OpaquePointer?
        /// `QLC_BACKEND_CPU` or `QLC_BACKEND_ACCEL`.
        let backend: Int32
        /// A take runs on it: from its first push after a reset until its finish or the next reset.
        var inTake = false
        let calls = NSLock()
        init(_ s: OpaquePointer, backend: Int32) {
            stream = s
            self.backend = backend
        }
    }

    /// A new stream on the open model, on the CPU engine or on the prepared accelerator program, or the Core's status.
    func makeStream(backend: Int32 = Int32(QLC_BACKEND_CPU)) -> Result<StreamSlot, CoreFailure> {
        let name = backend == Int32(QLC_BACKEND_CPU) ? "qlc_stream_create" : "qlc_stream_create_on"
        guard let h = enter() else { return .failure(CoreFailure(status: QLC_E_ENGINE, detail: 0, call: name)) }
        defer { leave() }
        var status: Int32 = 0
        let made: OpaquePointer?
        if backend == Int32(QLC_BACKEND_CPU) {
            made = qlc_stream_create(h, &status)
        } else if let on = CoreOptional.streamCreateOn {
            made = on(h, backend, &status)
        } else {
            return .failure(CoreFailure(status: QLC_E_ENGINE, detail: QLC_D_ACCEL_RUNTIME, call: name))
        }
        guard let s = made else {
            return .failure(CoreFailure(status: status == 0 ? QLC_E_ENGINE : Int(status), detail: Int(host.detail), call: name))
        }
        let slot = StreamSlot(s, backend: backend)
        lock.lock()
        slots.append(slot)
        lock.unlock()
        return .success(slot)
    }

    /// Runs a stream call while the model is open; nil once it is closing.
    func withStream<T>(_ slot: StreamSlot, _ body: (OpaquePointer) -> T) -> T? {
        guard enter() != nil else { return nil }
        defer { leave() }
        slot.calls.lock()
        defer { slot.calls.unlock() }
        guard let s = slot.stream else { return nil }
        return body(s)
    }

    /// Whether a take runs on the stream (a close for an install waits for none).
    func setInTake(_ slot: StreamSlot, _ v: Bool) {
        lock.lock()
        slot.inTake = v
        lock.unlock()
    }

    /// The stream's end: destroyed now, unless the model's close destroyed it already.
    func destroy(_ slot: StreamSlot) {
        guard enter() != nil else { return }
        defer { leave() }
        slot.calls.lock()
        if let s = slot.stream { qlc_stream_destroy(s) }
        slot.stream = nil
        slot.calls.unlock()
        lock.lock()
        slots.removeAll { $0 === slot }
        lock.unlock()
    }

    /// Closes the model at once when no call runs and no take is open on any of its streams (an install needs the
    /// Core without an open model). False when something runs: nothing changed.
    func closeIfIdle() -> Bool {
        lock.lock()
        guard handle != nil else {
            lock.unlock()
            return true
        }
        guard inFlight == 0, !closing, !slots.contains(where: { $0.inTake }) else {
            lock.unlock()
            return false
        }
        closing = true
        let x = takeForClose()
        lock.unlock()
        if let x { Self.release(x) }
        return true
    }

    /// Closes the model: no new call starts; the calls running are waited for up to `wait` seconds, and when one still
    /// runs then (an accelerator program's compile), the last one to end closes it.
    func close(wait: TimeInterval = 5) {
        lock.lock()
        guard handle != nil else {
            lock.unlock()
            return
        }
        closing = true
        var x = takeForClose()
        lock.unlock()
        let until = Date().addingTimeInterval(wait)
        while x == nil, Date() < until {
            Thread.sleep(forTimeInterval: 0.01)
            lock.lock()
            if handle == nil {
                lock.unlock()
                return
            }
            x = takeForClose()
            lock.unlock()
        }
        if let x { Self.release(x) }
    }
}

/// One stream of the Core over an open model, and the chunks its callback hands back (the CPU engine's and the
/// accelerator's: the same calls and the same heads in the same layout).
final class CoreStream: @unchecked Sendable {
    let model: CoreModel
    let slot: CoreModel.StreamSlot
    let chunkMs: Int
    private final class Box { var chunks: [HeadsBuffer] = [] }
    private let box = Box()
    /// The heads the stream computes (set again at every reset, the start of a take).
    private(set) var heads: UInt32

    init(model: CoreModel, backend: Int32, heads: UInt32) throws(RecognizerError) {
        let slot: CoreModel.StreamSlot
        switch model.makeStream(backend: backend) {
        case .success(let s): slot = s
        case .failure(let e): throw e.recognizerError
        }
        self.model = model
        self.slot = slot
        self.heads = heads
        chunkMs = model.chunkMs
        let user = Unmanaged.passUnretained(box).toOpaque()
        _ = model.withStream(slot) { (s: OpaquePointer) -> Int32 in
            qlc_stream_set_callback(s, { user, chunk in
                guard let user, let chunk else { return }
                Unmanaged<Box>.fromOpaque(user).takeUnretainedValue().chunks.append(HeadsBuffer(copying: chunk.pointee))
            }, user)
            return qlc_stream_set_heads(s, heads)
        }
    }

    deinit { model.destroy(slot) }

    static let closed = RecognizerError.engineFailed(code: QLC_E_ENGINE, message: "the model was closed")

    /// Whether its model is still open and the stream is live.
    var isOpen: Bool { model.isOpen && model.withStream(slot, { _ in true }) == true }

    /// Where it runs (`qlc_stream_backend`): the CPU, the Neural Engine (Core ML), or an NPU (LiteRT).
    var backend: Int32 { CoreOptional.streamBackend.flatMap { f in model.withStream(slot) { f($0) } } ?? slot.backend }

    func withStream<T>(_ body: (OpaquePointer) -> T) -> T? { model.withStream(slot, body) }

    func setHeads(_ mask: UInt32) {
        heads = mask
        _ = model.withStream(slot) { qlc_stream_set_heads($0, mask) }
    }

    func reset() {
        let mask = heads
        _ = model.withStream(slot) { (s: OpaquePointer) -> Int32 in
            qlc_stream_reset(s)
            return qlc_stream_set_heads(s, mask)
        }
        model.setInTake(slot, false)
        box.chunks.removeAll()
    }

    func push(_ s: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [HeadsBuffer] {
        box.chunks.removeAll(keepingCapacity: true)
        guard let base = s.baseAddress, s.count > 0 else { return [] }
        model.setInTake(slot, true)
        guard let st = model.withStream(slot, { qlc_stream_push($0, base, Int32(s.count)) }) else { throw Self.closed }
        guard st >= 0 else { throw CoreFailure(st, call: "qlc_stream_push").recognizerError }
        return box.chunks
    }

    func finish() throws(RecognizerError) -> [HeadsBuffer] {
        box.chunks.removeAll(keepingCapacity: true)
        defer { model.setInTake(slot, false) }
        guard let st = model.withStream(slot, { qlc_stream_finish($0) }) else { throw Self.closed }
        guard st >= 0 else { throw CoreFailure(st, call: "qlc_stream_finish").recognizerError }
        return box.chunks
    }

    /// Every head of the take so far.
    var take: HeadsBuffer {
        model.withStream(slot) { (s: OpaquePointer) -> HeadsBuffer in
            var h = qlc_heads()
            guard qlc_stream_heads(s, &h) >= 0 else { return HeadsBuffer() }
            return HeadsBuffer(copying: h)
        } ?? HeadsBuffer()
    }
}

/// The exact CPU engine as the Core runs it: one CPU stream over the open model. Pushes and the end of a take run
/// inference and hand back each completed chunk's heads (outputs only).
final class CoreStreamEngine: CPUStreamEngine, @unchecked Sendable {
    let stream: CoreStream
    var model: CoreModel { stream.model }
    var chunkMs: Int { stream.chunkMs }
    var heads: UInt32 { stream.heads }

    init(model: CoreModel) throws(RecognizerError) {
        stream = try CoreStream(model: model, backend: Int32(QLC_BACKEND_CPU), heads: HeadSelection.default.engineMask)
    }

    /// False once its model was closed (another context, an install): the take runner opens the engine again.
    var isOpen: Bool { stream.isOpen }

    /// The stream while the model is open, for the recited detector's feed (never on the audio thread).
    func withStream<T>(_ body: (OpaquePointer) -> T) -> T? { stream.withStream(body) }

    func setHeads(_ mask: UInt32) { stream.setHeads(mask) }
    func reset() { stream.reset() }
    func push(_ s: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [HeadsBuffer] { try stream.push(s) }
    func finish() throws(RecognizerError) -> [HeadsBuffer] { try stream.finish() }
    var take: HeadsBuffer { stream.take }
}

/// R2: a take on the accelerator program the Core prepared (`qlc_stream_create_on(m, QLC_BACKEND_ACCEL)`), the same
/// calls and heads as the CPU stream's. Core ML runs inside push and finish, so the take runner feeds it from the
/// accelerator's own queue (`AcceleratorExecutor`), never from the audio callback. The 2.0.2 failover keeps a CPU
/// stream of the same model beside it.
final class CoreAcceleratorStream: AcceleratorBackend, @unchecked Sendable {
    let stream: CoreStream
    /// The prepare's backend name ("coreml:memory" or "coreml:file").
    let name: String
    private var seconds: [Double] = []

    init(model: CoreModel, name: String) throws(RecognizerError) {
        stream = try CoreStream(model: model, backend: Int32(QLC_BACKEND_ACCEL), heads: HeadSelection.all.engineMask)
        self.name = name
    }

    var chunkSeconds: [Double] { seconds }
    var isUsable: Bool { stream.isOpen }

    /// The stream ended and the program wiped (`qlc_accel_release`; the model's CPU stream goes on).
    func release() {
        stream.model.destroy(stream.slot)
        stream.model.accelRelease()
    }

    func reset() {
        stream.reset()
        seconds.removeAll()
    }

    private func timed(_ body: () throws(RecognizerError) -> [HeadsBuffer]) throws(RecognizerError) -> [HeadsBuffer] {
        let t0 = CFAbsoluteTimeGetCurrent()
        let out = try body()
        if !out.isEmpty {
            let per = (CFAbsoluteTimeGetCurrent() - t0) / Double(out.count)
            seconds.append(contentsOf: [Double](repeating: per, count: out.count))
        }
        return out
    }

    func push(_ s: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [HeadsBuffer] {
        try timed { () throws(RecognizerError) in try stream.push(s) }
    }

    func finish() throws(RecognizerError) -> [HeadsBuffer] {
        try timed { () throws(RecognizerError) in try stream.finish() }
    }

    /// One second of silence through the program, then a reset: no state stays behind.
    func warmUp() throws(RecognizerError) {
        stream.reset()
        defer { reset() }
        _ = try [Float](repeating: 0, count: 16_000).withUnsafeBufferPointer { (p) throws(RecognizerError) in try stream.push(p) }
    }
}

extension HeadsBuffer {
    /// A copy of the Core's heads (qlcore.h `qlc_heads`, the layout of zf_tajweed.h's ZfTajweedHeads).
    init(copying h: qlc_heads) {
        let n40 = Int(h.n40), n20 = Int(h.n20)
        func copy(_ p: UnsafePointer<Float>?, _ n: Int) -> [Float] { p.map { Array(UnsafeBufferPointer(start: $0, count: n)) } ?? [] }
        var chunk: [String: [Float]] = [:]
        chunk["log_probs"] = copy(h.log_probs, n40 * 38)
        chunk["inter1_log_probs"] = copy(h.inter1_log_probs, n40 * 38)
        chunk["inter4_log_probs"] = copy(h.inter4_log_probs, n40 * 38)
        chunk["id_log_probs"] = copy(h.id_log_probs, n20 * 38)
        chunk["timing_log_probs"] = copy(h.timing_log_probs, n20 * 38)
        chunk["gem"] = copy(h.gem, n20 * 2)
        chunk["attr_tafkheem"] = copy(h.attr_tafkheem, n20 * 3)
        chunk["attr_ghunna"] = copy(h.attr_ghunna, n20 * 5)
        chunk["attr_qalqalah"] = copy(h.attr_qalqalah, n20 * 3)
        chunk["attr_face"] = copy(h.attr_face, n20 * 4)
        chunk["boundary"] = copy(h.boundary, n20)
        chunk["conf"] = copy(h.conf, n20)
        self.init(chunk: chunk)
    }
}
