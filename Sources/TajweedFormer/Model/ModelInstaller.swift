import Foundation

/// Where stored files come from: a byte range of a stored file (`layers.zfw.gz`).
protocol ModelFileSource: Sendable {
    /// Bytes `lower...upper` of the stored file `path` (inclusive). May return the whole file when the server
    /// ignores ranges; the installer slices it.
    func bytes(_ path: String, lower: Int64, upper: Int64, size: Int64) async throws(RecognizerError) -> Data
}

/// What one streamed range request did.
struct StreamedRange: Sendable {
    /// The server sent the whole file: it replaced the partial file from its first byte.
    let whole: Bool
    /// The bytes the request wrote to the partial file.
    let written: Int64
}

/// A source that writes a range to the partial file as its bytes arrive (the CDN), so a connection that ends
/// keeps what it delivered. `started` is told the validator of the answer (its strong ETag, when it has one) and
/// whether the answer is the whole file, before the first byte is written; `received` every piece written.
/// `size` is the whole file's size in the signed manifest: an answer is held to it (SPEC 16.1).
protocol StreamingModelFileSource: ModelFileSource {
    func stream(_ path: String, lower: Int64, upper: Int64, size: Int64, validator: String?, into part: URL,
                started: @Sendable (_ validator: String?, _ whole: Bool) -> Void,
                received: @Sendable (Int64) -> Void) async throws(RecognizerError) -> StreamedRange
}

/// What an install did, for analytics (`downloads`) and the host.
struct InstallReport: Sendable, Hashable {
    /// Bytes fetched in this call (a resumed file counts only what was fetched now).
    var downloadedBytes: Int64 = 0
    /// Bytes the profile stores on the server, all files (what a fresh install downloads).
    var profileBytes: Int64 = 0
    /// Decoded bytes the profile keeps on disk.
    var diskBytes: Int64 = 0
    /// At least one file continued a partial download from an earlier launch.
    var resumed = false
    /// Why the accelerator files (CoreML package, keeps, self-test set) are not usable, when they are not; the CPU set
    /// is complete on its own.
    var appleUnavailable: String?
    /// The program was rebuilt on the device from its delta and the CPU weights (QLPD1), not downloaded.
    var programFromDelta = false
    /// Why the delta was not used (the full program was downloaded instead), when it was not.
    var programDeltaFallback: String?
}

/// Counts the bytes of an install for `client.prefetch`'s progress: the stored bytes done (files already on disk, the
/// part of a file kept from an earlier run, every piece as it arrives) and the total of the CPU set.
final class ProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Int64 = 0
    private var total: Int64 = 0
    private let report: @Sendable (Int64, Int64) -> Void

    init(_ report: @escaping @Sendable (Int64, Int64) -> Void) { self.report = report }

    func start(total t: Int64) {
        lock.lock()
        total = t
        done = 0
        lock.unlock()
    }

    func add(_ n: Int64) {
        lock.lock()
        done = max(0, min(total, done + n))
        let d = done, t = total
        lock.unlock()
        report(d, t)
    }
}

/// Hands an install's progress to whoever listens now. An install reports to it from its start; a listener that comes
/// later (`client.prefetch` called while the launch's own update check is already downloading) is told at once where
/// the install stands, and then every step. One listener at a time; the last report is forgotten when the install ends.
final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: (@Sendable (Int64, Int64) -> Void)?
    private var last: (done: Int64, total: Int64)?

    /// Sets (or, with nil, removes) the listener. A running install's last report goes to a new listener at once.
    func listen(_ l: (@Sendable (Int64, Int64) -> Void)?) {
        lock.lock()
        listener = l
        let now = last
        lock.unlock()
        if let l, let now { l(now.done, now.total) }
    }

    func report(_ done: Int64, _ total: Int64) {
        lock.lock()
        last = (done, total)
        let l = listener
        lock.unlock()
        l?(done, total)
    }

    /// The install is over (finished or failed).
    func ended() {
        lock.lock()
        last = nil
        lock.unlock()
    }
}

/// Brings a profile of a model folder onto disk: every file by HTTP Range into `<stored path>.part` (resumable across
/// launches), checked against the stored size and SHA-256, inflated when stored gzip and checked against the decoded
/// size and SHA-256; only the decoded file is kept. Any mismatch deletes both and retries once.
///
/// CPU first: `install` brings the CPU set (the exact engine runs from it alone), then, only when the profile asks for
/// them, the accelerator files. The SDK's own first install asks for the CPU set only; the promotion pipeline fetches
/// the accelerator files later with `installAccelerator`, on an unmetered network, after the first session.
struct ModelInstaller: Sendable {
    let source: any ModelFileSource
    let rangeSize: Int64
    let freeSpace: @Sendable (URL) -> Int64
    /// Told the bytes of the CPU set as they are done, when a caller wants progress.
    var meter: ProgressMeter?
    /// The pauses before a file's download is taken up again after a failure of the network, one per retry.
    let retryPauses: [TimeInterval]
    /// The background transport of this install, when it has one (iOS): see `BackgroundDownloads.swift`.
    var background: BackgroundPlan?

    /// For tests: the smallest range an install asks for. A range is never smaller than 64 KiB in an app; the test
    /// folder's files are a few hundred bytes, and a test that needs several ranges of one file sets it lower.
    static let smallestRange = Locked<Int64>(64 << 10)

    /// The rule of every TajweedFormer SDK (3.1.5): at most five retries per file in one call, after 1, 2, 4, 8 and
    /// 16 seconds.
    static let standardRetryPauses: [TimeInterval] = [1, 2, 4, 8, 16]

    init(source: any ModelFileSource, rangeSize: Int64 = 8 << 20,
                freeSpace: @escaping @Sendable (URL) -> Int64 = { ModelInstaller.defaultFreeSpace($0) },
                retryPauses: [TimeInterval] = ModelInstaller.standardRetryPauses) {
        self.source = source
        self.rangeSize = max(Self.smallestRange.withLock { $0 }, rangeSize)
        self.freeSpace = freeSpace
        self.retryPauses = retryPauses
    }

    /// The longest a round of `fromFirstByte` waits for its tasks, in seconds (a round while the app is away has no
    /// limit of its own: the app is suspended, and the round ends with the tasks or with the app's return).
    static let roundLimit = Locked<TimeInterval>(15 * 60)

    /// Starts a task for every range of `file` from `first` on that is neither kept beside its partial file nor on
    /// its way already (`pending`: the names of the tasks that have not ended); how many, or nil when no request
    /// can be made now (no token).
    private func hand(_ plan: BackgroundPlan, _ file: ModelManifest.File, _ filePart: URL, from first: Int64, validator: String?,
                      pending: Set<String>) async -> Int? {
        let held = BackgroundRange.kept(beside: filePart)
        let onTheirWay = pending.compactMap { BackgroundRange(key: $0) }.filter { $0.folder == plan.folder && $0.path == file.path }
        var lower = first
        var started = 0
        while lower < file.size {
            if let range = held.first(where: { $0.lower == lower }) {
                lower += max(1, Self.sizeOnDisk(range.file))
                continue
            }
            if let task = onTheirWay.first(where: { $0.lower <= lower && lower <= $0.upper }) {
                lower = task.upper + 1
                continue
            }
            let nextKept = held.first(where: { $0.lower > lower })?.lower ?? file.size
            let nextTask = onTheirWay.filter { $0.lower > lower }.map { $0.lower }.min() ?? file.size
            let upper = min(nextKept, nextTask, lower + rangeSize) - 1
            guard let request = await plan.request(file.path, lower, upper, validator) else { return nil }
            plan.transport.start(request, key: BackgroundRange(folder: plan.folder, path: file.path, lower: lower, upper: upper, size: file.size).key)
            started += 1
            lower = upper + 1
        }
        return started
    }

    /// Hands what is left of an install to the background transport: every range of `f` from `first` on, and every
    /// range of the files that come after it and have not begun (one that has begun is left to its turn), each as
    /// one task. How many tasks were started.
    private func handOver(_ plan: BackgroundPlan, _ f: ModelManifest.File, part: URL, from first: Int64, in folder: URL) async -> Int {
        let pending = await plan.transport.pending(prefix: BackgroundRange.prefix(folder: plan.folder))
        // unreadable is taken as not there here, because a range without a validator is asked for with the range
        // alone (SPEC 16.2), and an answer that is not the same file costs at most the bytes of this download
        let validator = first > 0 ? (try? String(contentsOf: Self.validatorFile(part), encoding: .utf8)) : nil
        guard var started = await hand(plan, f, part, from: first, validator: validator, pending: pending) else { return 0 }
        for other in plan.later.withLock({ $0 }) where !Self.present(other, in: folder) {
            let otherPart = BackgroundRange.part(folder, other.path)
            guard Self.sizeOnDisk(otherPart) == 0 else { continue }
            guard let more = await hand(plan, other, otherPart, from: 0, validator: nil, pending: pending) else { break }
            started += more
        }
        return started
    }

    /// Hands what is left of an install to the background transport and waits (`handOver`). It waits until every
    /// task has ended. It ends sooner when the app is back (`whenLeaving`; for `fromFirstByte` when the app left
    /// during the round and is back), when a round of `fromFirstByte` has taken `roundLimit`, and when a refusal
    /// that stops the model has arrived; then the tasks that have not ended are cancelled, each abandoned whole (a
    /// background task's bytes are the system's until it ends), and counted. What ended well is kept beside the
    /// partial files, and the installer's loop joins it.
    /// When the CALL is cancelled the round ends at once and cancels nothing: what was handed to the system runs
    /// on, and the next call joins what it brought.
    private func backgroundRound(_ plan: BackgroundPlan, _ f: ModelManifest.File, part: URL, from have: Int64, in folder: URL) async {
        let started = await handOver(plan, f, part: part, from: have, in: folder)
        guard started > 0 else { return }
        SDKLatest.debugOnly("model download: \(started) ranges handed to the background session (\(plan.policy.rawValue)), from byte \(have) of \(f.path)")
        let prefix = BackgroundRange.prefix(folder: plan.folder)
        let began = Date()
        let limit = Self.roundLimit.withLock { $0 }
        var wasAway = plan.handOver.isAway
        var why = "every task ended"
        while true {
            // the call was cancelled: the foreground part ends here, and what was handed to the system runs on
            if Task.isCancelled { return }
            if plan.stopped() != nil {
                why = "a refusal stopped the model"
                break
            }
            if await plan.transport.pending(prefix: prefix).isEmpty { break }
            let away = plan.handOver.isAway
            if plan.policy == .whenLeaving, !away {
                why = "the app is back"
                break
            }
            if plan.policy == .fromFirstByte {
                if wasAway, !away {
                    why = "the app is back"
                    break
                }
                if Date().timeIntervalSince(began) > limit {
                    why = "the round's time is up"
                    break
                }
            }
            wasAway = away
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let left = await plan.transport.cancel(prefix: prefix)
        if !left.isEmpty { plan.abandoned(left.count) }
        SDKLatest.debugOnly("model download: back from the background session (\(why)), \(left.count) of \(started) ranges had not ended and were given up")
    }

    // MARK: the hand-over when the app resigns (`whenResigning`, for the measurement)

    /// The range files kept beside the partial files of `f` and of the files after it.
    private func keptFiles(_ plan: BackgroundPlan, _ f: ModelManifest.File, in folder: URL) -> [URL] {
        ([f] + plan.later.withLock { $0 }).flatMap { BackgroundRange.kept(beside: BackgroundRange.part(folder, $0.path)).map { $0.file } }
    }

    /// The app has resigned (or is away): the ranges of `f` from `first` on, and of the files after it, become the
    /// background's. The first time since the app was last active, what marks the tasks as out is noted.
    private func handResigned(_ plan: BackgroundPlan, _ f: ModelManifest.File, part: URL, from first: Int64, in folder: URL) async {
        let since = plan.handOver.leavings - (plan.handOver.isAway ? 1 : 0)
        let before = Set(keptFiles(plan, f, in: folder).map { $0.path })
        plan.out.withLock { (o: inout BackgroundPlan.Out?) in
            if o == nil { o = BackgroundPlan.Out(since: since, keptBefore: before) }
        }
        let started = await handOver(plan, f, part: part, from: first, in: folder)
        SDKLatest.debugOnly("model download: the app resigned: \(started) ranges handed to the background session (whenResigning), from byte \(first) of \(f.path)")
    }

    /// The app is active again while tasks are out. When it has been in the background meanwhile, this is a
    /// return: the tasks that have not ended are cancelled, each abandoned whole, and what ended is joined by the
    /// loop. When it has not (Control Center, a banner, an alert), the tasks were made for nothing: they are
    /// cancelled, and what they fetched is dropped and counted; the app's own request was never cut, so nothing it
    /// fetched is lost.
    private func takeBack(_ plan: BackgroundPlan, _ f: ModelManifest.File, in folder: URL) async {
        let prefix = BackgroundRange.prefix(folder: plan.folder)
        let out = plan.out.withLock { (o: inout BackgroundPlan.Out?) -> BackgroundPlan.Out? in
            defer { o = nil }
            return o
        }
        guard let out, out.since == plan.handOver.leavings else {
            let left = await plan.transport.cancel(prefix: prefix)
            if !left.isEmpty { plan.abandoned(left.count) }
            SDKLatest.debugOnly("model download: the app is back from the background: \(left.count) ranges had not ended and were given up")
            return
        }
        var bytes = await plan.transport.received(prefix: prefix)
        let left = await plan.transport.cancel(prefix: prefix)
        for file in keptFiles(plan, f, in: folder) where !out.keptBefore.contains(file.path) {
            bytes += Self.sizeOnDisk(file)
            try? FileManager.default.removeItem(at: file)
        }
        plan.dropped(left.count, bytes)
        SDKLatest.debugOnly("model download: the app is active again without having been in the background: \(left.count) background tasks cancelled, "
            + "\(bytes) bytes they had fetched are dropped (fetched twice)")
    }

    /// The bytes from `have` on are the background's: waits until the range that starts there is kept (true), or
    /// until the app is active again, every task has ended, or a refusal has stopped the model (false). A cancelled
    /// call ends the wait at once and cancels no task.
    private func awaitBackground(_ plan: BackgroundPlan, _ part: URL, at have: Int64) async throws(RecognizerError) -> Bool {
        let prefix = BackgroundRange.prefix(folder: plan.folder)
        while true {
            if Task.isCancelled { throw .cancelled }
            if plan.stopped() != nil {
                _ = await plan.transport.cancel(prefix: prefix)
                return false
            }
            if BackgroundRange.kept(beside: part).contains(where: { $0.lower == have }) { return true }
            if plan.handOver.isActive { return false }
            if await plan.transport.pending(prefix: prefix).isEmpty {
                // a task's file is placed before the task counts as ended
                return BackgroundRange.kept(beside: part).contains { $0.lower == have }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Joins the range kept for the byte the partial file ends at, when there is one: its bytes are appended and
    /// the kept file is removed. The bytes joined, or nil when no range is kept for that byte. A kept range that
    /// does not fit (it would pass the file's end) is removed and not joined.
    private func join(_ part: URL, at have: Int64, size: Int64) throws(RecognizerError) -> Int64? {
        guard let range = BackgroundRange.kept(beside: part).first(where: { $0.lower == have }) else { return nil }
        defer { try? FileManager.default.removeItem(at: range.file) }
        let length = Self.sizeOnDisk(range.file)
        guard length > 0, have + length <= size else { return nil }
        do {
            let bytes = try Data(contentsOf: range.file)
            let h = try FileHandle(forWritingTo: part)
            defer { try? h.close() }
            try h.truncate(atOffset: UInt64(have))
            try h.seek(toOffset: UInt64(have))
            try h.write(contentsOf: bytes)
            try h.synchronize()
            SDKLatest.debugOnly("model download: joined \(length) bytes that the background session fetched, at byte \(have) of \(part.lastPathComponent)")
        } catch {
            throw .storageFailed("cannot join a range to \(part.lastPathComponent): \(error.localizedDescription)")
        }
        return length
    }

    /// The validator of a partial file, kept beside it: the strong ETag of the answer that started it.
    static func validatorFile(_ part: URL) -> URL { URL(fileURLWithPath: part.path + ".etag") }

    /// The size of a file on disk now (not a value the URL remembers); 0 when it is not there.
    static func sizeOnDisk(_ file: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// One failed attempt of a file: it counts against the tries the file has in this call, and its pause is waited
    /// before the next (SPEC 16.2: at most `retryPauses.count` times per file and call; an attempt that brought no
    /// new byte counts like any other; progress does not start the count again). When the tries are used up, or
    /// the call is cancelled (which also ends a pause at once), `failure` is thrown.
    private func afterFailedAttempt(_ failure: RecognizerError, _ retries: inout Int) async throws(RecognizerError) {
        guard retries < retryPauses.count, !Task.isCancelled else { throw failure }
        let pause = retryPauses[retries]
        retries += 1
        do {
            try await Task.sleep(nanoseconds: UInt64(max(0, pause) * 1_000_000_000))
        } catch {
            // cancelled while it waited: the wait ends at once
            throw failure
        }
    }

    /// Whether a failure of a file's request is one that the file is resumed after (SPEC 16.2): no answer, a
    /// connection that ends, a stall, a 5xx (`offline`), and an answer that said success and was not the file
    /// (`updateDeferred`, from `CloudError.badAnswer`). Everything else is asked once: a refusal, a redirect, a
    /// storage error.
    static func isResumed(_ failure: RecognizerError) -> Bool {
        switch failure {
        case .offline, .updateDeferred: return true
        default: return false
        }
    }

    /// The rest of a stored file from a source that writes to disk as bytes arrive: range by range, appended to
    /// the one partial file, from what it holds. A failed attempt keeps what it delivered and the file is taken up
    /// again from what is on disk after a pause (`afterFailedAttempt`, `isResumed`). An attempt that ends without
    /// an error and without a new byte is a failed attempt too: nothing here asks again without a count and a
    /// pause.
    /// The partial file's validator: the strong ETag of the answer that started it is kept beside it and sent as
    /// `If-Range` with every later range; when the server then sends the whole file (a 200), it takes the partial
    /// file's place once all of it has arrived. What removes the partial file, and nothing else does (SPEC 16.1):
    /// a 416 (the stored bytes run past the server's file: the file starts again, as one of its tries), a partial
    /// file larger than the manifest's size (`fetch`, before this is called), and a file of the full size whose
    /// SHA-256 is not the manifest's (the caller, after this returns).
    ///
    /// With a background transport (iOS): a range that a background task finished is joined when the partial file
    /// reaches its first byte, and no foreground request asks for bytes a kept range holds. While the app is away
    /// (policy `whenLeaving`) no request is made by the app itself: what is left is handed to the background
    /// session (`backgroundRound`), and handed again when a round ended without the next byte while the app is
    /// still away; such a round is a failed attempt. When the app leaves during a request, the request ends where
    /// it stands (what it wrote stays; the next byte is where the background ranges begin, so no byte is written
    /// twice).
    /// Policy `whenResigning` (the measurement's second hand-over moment): when the app resigns, the ranges after
    /// the one the app is fetching are handed over (`handResigned`), and the app's request goes on to the end of
    /// its range; `theirs` is the first byte that is the background's from then on. The app fetches nothing past
    /// it while the tasks are out: it waits for them (`awaitBackground`), and takes the download back when the app
    /// is active again (`takeBack`).
    /// Tried before (the first candidate, never released): one hand-over per leaving. A range that was missing
    /// after the round was then asked for by the app itself, and each such request was ended at once because the
    /// app was away, until the tries were used up: the call failed on a working network.
    private func stream(_ streaming: any StreamingModelFileSource, _ f: ModelManifest.File, part: URL, from start: Int64,
                        report: inout InstallReport, meter: ProgressMeter?) async throws(RecognizerError) {
        let fm = FileManager.default
        let kept = Self.validatorFile(part)
        let folder = URL(fileURLWithPath: String(part.path.dropLast((f.path + ".part").count)), isDirectory: true)
        var have = start
        var retries = 0
        // `fromFirstByte`: its one round for this file was made
        var handed = false
        // `whenResigning`: the first byte of this file that is the background's while its tasks are out
        var theirs: Int64?
        if let plan = background, plan.policy == .whenResigning, plan.out.withLock({ $0 != nil }) {
            if plan.handOver.isActive {
                // the app became active again between two files
                await takeBack(plan, f, in: folder)
            } else {
                // the tasks are out since an earlier file: what is left of this file is the background's as well
                await handResigned(plan, f, part: part, from: have, in: folder)
                theirs = have
            }
        }
        while have < f.size {
            // a refusal that stops the model has arrived (a background task may have met it): no further request
            if let stop = background?.stopped() { throw stop }
            if background != nil, let joined = try join(part, at: have, size: f.size) {
                have += joined
                report.downloadedBytes += joined
                meter?.add(joined)
                continue
            }
            if let plan = background, plan.policy == .whenResigning {
                if let first = theirs {
                    if plan.handOver.isActive {
                        await takeBack(plan, f, in: folder)
                        theirs = nil
                        continue
                    }
                    if have >= first {
                        let brought = try await awaitBackground(plan, part, at: have)
                        if !brought, plan.stopped() == nil, !plan.handOver.isActive {
                            // every task has ended and the next byte is not there: a failed attempt, and the
                            // range is handed over again
                            try await afterFailedAttempt(.offline("the background transfer of \(f.path) ended without its next byte"), &retries)
                            await handResigned(plan, f, part: part, from: have, in: folder)
                        }
                        continue
                    }
                    // the app's own range is not finished: it goes on below, up to `first`
                } else if plan.handOver.isAway {
                    // away with nothing handed over for this file: everything from here is the background's
                    await handResigned(plan, f, part: part, from: have, in: folder)
                    theirs = have
                    continue
                }
            } else if let plan = background {
                let away = plan.handOver.isAway
                if plan.policy == .whenLeaving ? away : !handed {
                    handed = true
                    await backgroundRound(plan, f, part: part, from: have, in: folder)
                    // the round brought the next byte, or the app is back and fetches it itself: go on
                    let brought = BackgroundRange.kept(beside: part).contains { $0.lower == have }
                    if !brought, plan.policy == .whenLeaving, plan.handOver.isAway {
                        try await afterFailedAttempt(.offline("the background transfer of \(f.path) ended without its next byte"), &retries)
                    }
                    continue
                }
            }
            let before = have
            // not past the first byte of a range that is kept already, nor past the first byte that is the background's
            let nextKept = background == nil ? f.size : (BackgroundRange.kept(beside: part).first(where: { $0.lower > before })?.lower ?? f.size)
            let next = min(nextKept, theirs ?? f.size)
            let upper = min(next, before + rangeSize) - 1
            if before == 0 { try? fm.removeItem(at: kept) }
            // unreadable is taken as not there here, for the same reason
            let validator = before > 0 ? (try? String(contentsOf: kept, encoding: .utf8)) : nil
            var failure: RecognizerError?
            // the server sent the whole file in place of the range: every byte on disk is then this request's
            let restarted = Locked(false)
            let path = f.path
            let size = f.size
            // told when the request has ended, and (for `whenResigning`) when the app's state changes
            let (events, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(8))
            let ended = Locked(false)
            let request = Task { () async -> RecognizerError? in
                defer {
                    ended.withLock { $0 = true }
                    signal.yield()
                }
                do throws(RecognizerError) {
                    _ = try await streaming.stream(path, lower: before, upper: upper, size: size, validator: validator, into: part,
                                                   started: { (answered: String?, whole: Bool) in
                                                       // the answer that starts the partial file, or starts it again
                                                       guard before == 0 || whole else { return }
                                                       if whole, before > 0 { restarted.withLock { $0 = true } }
                                                       if let answered {
                                                           try? Data(answered.utf8).write(to: kept, options: .atomic)
                                                       } else {
                                                           try? FileManager.default.removeItem(at: kept)
                                                       }
                                                   },
                                                   received: { (n: Int64) in meter?.add(n) })
                    return nil
                } catch {
                    return error
                }
            }
            if let plan = background, plan.policy == .whenResigning {
                // the request is not cut when the app resigns or enters the background: it goes on to the end of
                // its range, and meanwhile the state is followed
                let watch = plan.handOver.onChange { signal.yield() }
                signal.yield()
                for await _ in events {
                    if ended.withLock({ $0 }) { break }
                    if theirs == nil, !plan.handOver.isActive {
                        await handResigned(plan, f, part: part, from: upper + 1, in: folder)
                        theirs = upper + 1
                    } else if theirs != nil, plan.handOver.isActive {
                        await takeBack(plan, f, in: folder)
                        theirs = nil
                    }
                }
                plan.handOver.remove(watch)
                // the call was cancelled: the request ends with it
                if Task.isCancelled { request.cancel() }
                failure = await request.value
            } else {
                // the app leaves the foreground: the request ends where it stands
                var leaving: UUID?
                if let plan = background, plan.policy == .whenLeaving { leaving = plan.handOver.onAway { request.cancel() } }
                failure = await withTaskCancellationHandler {
                    await request.value
                } onCancel: {
                    request.cancel()
                }
                if let leaving { background?.handOver.remove(leaving) }
            }
            // what is on disk now is what counts, however the request ended
            let onDisk = Self.sizeOnDisk(part)
            report.downloadedBytes += restarted.withLock { $0 } ? onDisk : max(0, onDisk - before)
            have = onDisk
            if failure == nil {
                if onDisk > before || restarted.withLock({ $0 }) { continue }
                // an answer that brought no new byte is a failed attempt, whatever it said
                failure = .updateDeferred("the download server's answer brought no new byte of \(f.path)")
            }
            guard let failure else { continue }
            // ended because the app left, not by the network: the hand-over follows, and no try is counted
            if let plan = background, plan.policy == .whenLeaving, plan.handOver.isAway, !Task.isCancelled { continue }
            // `whenResigning`: the app's own range failed while the app is in the background, where the app cannot
            // go on with it: what is left of it goes to the background too
            if let plan = background, plan.policy == .whenResigning, plan.handOver.isAway, !Task.isCancelled, Self.isResumed(failure) {
                await handResigned(plan, f, part: part, from: have, in: folder)
                theirs = have
                continue
            }
            if case .serverRejected(status: 416, _, _, _) = failure {
                // the stored bytes run past the server's file: they go, with their validator, and the file starts
                // again as one of its tries
                try? fm.removeItem(at: part)
                try? fm.removeItem(at: kept)
                guard fm.createFile(atPath: part.path, contents: nil) else { throw .storageFailed("cannot create \(f.path).part") }
                meter?.add(-have)
                have = 0
                try await afterFailedAttempt(failure, &retries)
                continue
            }
            guard Self.isResumed(failure) else { throw failure }
            try await afterFailedAttempt(failure, &retries)
        }
        try? fm.removeItem(at: kept)
        try? fm.removeItem(at: HTTPClient.wholeFile(beside: part))
        // a kept range that was never needed (the foreground had its bytes first)
        for range in BackgroundRange.kept(beside: part) { try? fm.removeItem(at: range.file) }
    }

    static func defaultFreeSpace(_ url: URL) -> Int64 {
        var dir = url
        while !FileManager.default.fileExists(atPath: dir.path), dir.pathComponents.count > 1 { dir.deleteLastPathComponent() }
        let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let n = v?.volumeAvailableCapacityForImportantUsage, n > 0 { return n }
        return Int64(v?.volumeAvailableCapacity ?? Int.max)
    }

    /// Installs `profile` of `manifest` into `folder` (which may hold files of an earlier, interrupted install): the
    /// CPU set, then the profile's accelerator files when it has any (a failure there leaves the CPU set working and
    /// is reported in `appleUnavailable`). Writes the manifest there last.
    func install(_ manifest: ModelManifest, profile: DownloadProfile, into folder: URL) async throws(RecognizerError) -> InstallReport {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var report = InstallReport()
        let cpu = profile.cpuFiles(manifest)
        meter?.start(total: DownloadProfile.bytes(cpu))
        try checkSpace(cpu, in: folder)
        for (i, f) in cpu.enumerated() {
            // the files after this one go to the background with it, should the learner leave during it
            background?.later.withLock { $0 = Array(cpu[(i + 1)...]) }
            try await ensure(f, in: folder, report: &report, counted: true)
        }
        background?.later.withLock { $0 = [] }
        try manifest.write(to: folder)
        if !profile.appleFiles(manifest).isEmpty {
            do throws(RecognizerError) {
                let a = try await installAccelerator(manifest, profile: profile, into: folder)
                report.downloadedBytes += a.downloadedBytes
                report.resumed = report.resumed || a.resumed
            } catch {
                if case .offline = error { throw error }
                report.appleUnavailable = "\(error)"
            }
        }
        let kept = cpu + (report.appleUnavailable == nil ? profile.appleFiles(manifest) : [])
        report.profileBytes = DownloadProfile.bytes(kept)
        report.diskBytes = kept.reduce(0) { $0 + $1.localSize }
        return report
    }

    /// The accelerator files of `profile` (package, keep table, self-test set) into a folder that holds the CPU set,
    /// each verified like any download; then any correction left by an earlier SDK is deleted. The other CoreML
    /// build, when the folder holds it, stays. The compiled package is kept out of backups (the device makes it again).
    /// On a failure the files fetched so far stay (the next attempt resumes); a file that does not verify is deleted.
    func installAccelerator(_ manifest: ModelManifest, profile: DownloadProfile,
                                   into folder: URL) async throws(RecognizerError) -> InstallReport {
        var report = InstallReport()
        let apple = profile.appleFiles(manifest)
        guard !apple.isEmpty else { throw .neuralEngineUnavailable("the folder has no \(profile.packageRole) build for \(profile.context)") }
        let pd = profile.programDelta(manifest)
        try checkSpace(apple + (pd.map { [$0.delta, $0.delta] } ?? []), in: folder)
        for f in apple where f.localPath != pd?.program.localPath { try await ensure(f, in: folder, report: &report) }
        if let pd {
            // the delta first: the program rebuilt from the CPU weights already here, checked before CoreML sees it
            if !Self.verified(pd.program, in: folder) {
                do throws(RecognizerError) {
                    try await rebuildFromDelta(manifest, pd.delta, pd.program, profile: profile, in: folder, report: &report)
                    report.programFromDelta = true
                } catch {
                    if case .offline = error { throw error }
                    report.programDeltaFallback = "\(error)"
                }
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(pd.delta.localPath))
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(pd.delta.path + ".part"))
            }
            // the full program: when there was no delta to use, or it did not rebuild the listed bytes
            try await ensure(pd.program, in: folder, report: &report)
        }
        let fm = FileManager.default
        for f in profile.otherBuildFiles(manifest) { try? fm.removeItem(at: folder.appendingPathComponent(f.localPath)) }
        for f in profile.otherBuildFiles(manifest) {
            var dir = folder.appendingPathComponent(f.localPath).deletingLastPathComponent()
            while dir.path.count > folder.path.count, (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                try? fm.removeItem(at: dir)
                dir.deleteLastPathComponent()
            }
        }
        for top in Set(apple.compactMap { $0.localPath.split(separator: "/").first.map(String.init) }) where top != "selftest" {
            var url = folder.appendingPathComponent(top, isDirectory: true)
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            try? url.setResourceValues(v)
        }
        var fetched = apple
        if report.programFromDelta, let pd { fetched = apple.filter { $0.localPath != pd.program.localPath } + [pd.delta] }
        report.profileBytes = DownloadProfile.bytes(fetched)
        report.diskBytes = apple.reduce(0) { $0 + $1.localSize }
        return report
    }

    /// Whether a decoded file is on disk with the manifest's size and SHA-256.
    static func verified(_ f: ModelManifest.File, in folder: URL) -> Bool {
        guard present(f, in: folder), let (_, sha) = try? ModelManifest.digest(folder.appendingPathComponent(f.localPath)) else { return false }
        return sha == f.localSHA256
    }

    /// Downloads the delta (verified like any file) and rebuilds the program from it and the context's CPU files,
    /// into a scratch file outside the package that moves into place only once its SHA-256 is the manifest's.
    func rebuildFromDelta(_ m: ModelManifest, _ delta: ModelManifest.File, _ program: ModelManifest.File, profile: DownloadProfile,
                          in folder: URL, report: inout InstallReport) async throws(RecognizerError) {
        try await ensure(delta, in: folder, report: &report)
        let cpu = ProgramDelta.CPUFiles(folder: folder, context: profile.context,
                                        layersSHA256: m.files(role: "weights").first?.localSHA256,
                                        frontendSHA256: m.files(role: "frontend").first?.localSHA256)
        let scratch = folder.appendingPathComponent(".rebuild", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let built = scratch.appendingPathComponent((program.localPath as NSString).lastPathComponent)
        try ProgramDelta.rebuild(delta: folder.appendingPathComponent(delta.localPath), cpu: cpu, to: built,
                                 expectedSHA256: program.localSHA256, expectedSize: program.localSize)
        let dst = folder.appendingPathComponent(program.localPath)
        try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.moveItem(at: built, to: dst) } catch {
            throw .storageFailed("cannot place \(program.localPath): \(error.localizedDescription)")
        }
    }

    /// Room for `files` not on disk yet (stored and decoded bytes), with 64 MB to spare.
    func checkSpace(_ files: [ModelManifest.File], in folder: URL) throws(RecognizerError) {
        let needed = files.filter { !Self.present($0, in: folder) }
        let want = needed.reduce(Int64(0)) { $0 + $1.size + $1.localSize }
        let free = freeSpace(folder)
        guard free >= want + (64 << 20) else { throw .insufficientStorage(needed: want + (64 << 20), available: free) }
    }

    /// Whether the decoded file is on disk with its size (the hash is checked when the model is opened).
    static func present(_ f: ModelManifest.File, in folder: URL) -> Bool {
        let v = try? folder.appendingPathComponent(f.localPath).resourceValues(forKeys: [.fileSizeKey])
        return v?.fileSize.map(Int64.init) == f.localSize
    }

    /// One file on disk, decoded and verified: kept if already there and matching, else downloaded (resuming a
    /// `.part`), checked, inflated, checked. One retry after a mismatch.
    func ensure(_ f: ModelManifest.File, in folder: URL, report: inout InstallReport, counted: Bool = false) async throws(RecognizerError) {
        let fm = FileManager.default
        let dst = folder.appendingPathComponent(f.localPath)
        let meter = counted ? self.meter : nil
        if Self.present(f, in: folder), let (_, sha) = try? ModelManifest.digest(dst), sha == f.localSHA256 {
            meter?.add(f.size)
            return
        }
        try? fm.removeItem(at: dst)
        var attempt = 0
        while true {
            attempt += 1
            let before = report.downloadedBytes
            var kept: Int64 = 0
            do throws(RecognizerError) {
                try await fetch(f, in: folder, report: &report, meter: meter, kept: &kept)
                return
            } catch {
                guard case .checksumMismatch = error, attempt < 2 else { throw error }
                // the file starts again: what was counted for it goes back
                meter?.add(-(kept + report.downloadedBytes - before))
            }
        }
    }

    private func fetch(_ f: ModelManifest.File, in folder: URL, report: inout InstallReport, meter: ProgressMeter?,
                       kept: inout Int64) async throws(RecognizerError) {
        let fm = FileManager.default
        let part = folder.appendingPathComponent(f.path + ".part")
        let dst = folder.appendingPathComponent(f.localPath)
        try? fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        var have = Int64((try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
        if have > f.size { try? fm.removeItem(at: part); have = -1 }
        if have < 0 {
            guard fm.createFile(atPath: part.path, contents: nil) else { throw .storageFailed("cannot create \(f.path).part") }
            have = 0
        } else if have > 0 {
            report.resumed = true
            kept = have
            meter?.add(have)
        }
        if let streaming = source as? any StreamingModelFileSource {
            try await stream(streaming, f, part: part, from: have, report: &report, meter: meter)
            have = f.size
        }
        guard let h = try? FileHandle(forWritingTo: part) else { throw .storageFailed("cannot open \(f.path).part") }
        do {
            try h.seek(toOffset: UInt64(have))
            while have < f.size {
                let upper = min(f.size, have + rangeSize) - 1
                let piece = try await source.bytes(f.path, lower: have, upper: upper, size: f.size)
                guard Int64(piece.count) == upper - have + 1 else { throw RecognizerError.offline("short range for \(f.path)") }
                try h.write(contentsOf: piece)
                have += Int64(piece.count)
                report.downloadedBytes += Int64(piece.count)
                meter?.add(Int64(piece.count))
            }
            try h.synchronize()
            try h.close()
        } catch let e as RecognizerError {
            try? h.close()
            throw e
        } catch {
            try? h.close()
            throw .storageFailed("cannot write \(f.path).part: \(error.localizedDescription)")
        }
        let (size, sha) = try ModelManifest.digest(part)
        guard size == f.size, sha == f.sha256 else {
            try? fm.removeItem(at: part)
            throw .checksumMismatch(file: f.path)
        }
        if f.isGzip {
            let out: Gzip.Output
            do throws(RecognizerError) { out = try Gzip.inflate(part, to: dst) } catch {
                try? fm.removeItem(at: part)
                try? fm.removeItem(at: dst)
                throw error
            }
            try? fm.removeItem(at: part)
            guard out.size == f.localSize, out.sha256 == f.localSHA256 else {
                try? fm.removeItem(at: dst)
                throw .checksumMismatch(file: f.localPath)
            }
        } else {
            try? fm.removeItem(at: dst)
            do { try fm.moveItem(at: part, to: dst) } catch {
                try? fm.removeItem(at: part)
                throw .storageFailed("cannot place \(f.localPath): \(error.localizedDescription)")
            }
        }
    }
}

/// Stored files from a local folder (a staged copy of the server folder): for tests and offline installs.
struct DirectoryFileSource: ModelFileSource {
    let root: URL
    init(root: URL) { self.root = root }
    func bytes(_ path: String, lower: Int64, upper: Int64, size: Int64) async throws(RecognizerError) -> Data {
        guard let h = try? FileHandle(forReadingFrom: root.appendingPathComponent(path)) else { throw .modelMissing(path) }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: UInt64(lower))
            return try h.read(upToCount: Int(upper - lower + 1)) ?? Data()
        } catch {
            throw .modelMissing(path)
        }
    }
}
