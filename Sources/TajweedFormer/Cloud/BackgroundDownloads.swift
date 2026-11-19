import Foundation
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

// The model download as a background transfer (SDK 3.1.5; SPEC 15.4 for its one exception to the redirect rule).
//
// On iOS an app is suspended within seconds of the learner leaving it, and a download that runs in the app's
// process stops there. A background URLSession goes on without the process. What it can carry is narrow: download
// tasks only, each with its request fixed when it is made (no new token later), finished out of process, and
// handed to the app as a file when the app runs again. So the background session here only FETCHES BYTES: one
// download task per range of a model file. Every decision stays with the code that runs in the app: a finished
// range is placed beside the partial file as a range file, and the installer's own loop joins it, in order, and
// hashes the whole file against the signed manifest as it always did.
//
// Two ways to use it (`BackgroundDownloadPolicy`):
// - `whenLeaving`, the default on iOS: the download runs in the foreground as before, and what is left of it is
//   handed to background tasks when the app has entered the background, and taken back when the app returns.
// - `fromFirstByte`: every range is a background task from the start.
// Which of the two is the default is decided by a measurement on a phone; until then `whenLeaving`, because the
// foreground path is the one the tests can run.
//
// Tried and rejected: one resumable download task per file with the system's own resume data. The resume data
// carries the original request, so a resumed task cannot be given a new token, and the validator would be the
// system's and not ours.

/// When a model download uses the background session.
enum BackgroundDownloadPolicy: String, Sendable {
    /// Never: every request runs in the app's process (macOS, tests, a Client with its own URLSession).
    case off
    /// In the foreground as before; what is left goes to background tasks when the app has entered the background
    /// (`didEnterBackground`), and the app's request in flight is ended there.
    case whenLeaving
    /// For the measurement on a phone (the switch of debug builds; never a release build's policy): the background
    /// tasks are made when the app RESIGNS (`willResignActive`), while it still counts as in the foreground, for
    /// every range after the one the app is fetching. The app's own request is not cut. When the app is active
    /// again without having been in the background (Control Center, a banner, an alert), the tasks are cancelled
    /// and what they fetched is dropped; when it has entered the background, the app's request ends with its range
    /// and the rest stays with the tasks. A range belongs to the app or to a task, never to both.
    case whenResigning
    /// Every range is a background task from the first byte.
    case fromFirstByte
}

/// Whether the app is away (in the background), for the download's hand-over. On iOS it follows
/// `didEnterBackground` and `willEnterForeground`, and starts from the application's state, so a process that the
/// system started in the background is away from its first moment. Tests set it themselves.
/// Tried before (the first candidate, never released): `willResignActive` and `didBecomeActive`. An app resigns
/// without entering the background for Control Center, a pulled-down notification, a permission alert or a call
/// screen, and each of those handed the download over and back and threw away what was in flight. And a process
/// started in the background began as if it were in the foreground.
final class DownloadHandOver: Sendable {
    static let shared = DownloadHandOver()

    /// For tests: whether the application is in the background when the hand-over starts to follow the system
    /// (the stand-in for the application's state).
    static let startsAway = Locked<(@Sendable () -> Bool)?>(nil)

    private struct Phase {
        var away = false
        var resigned = false
        var leavings = 0
    }
    private let phase = Locked(Phase())
    private let watchers = Locked<[UUID: @Sendable () -> Void]>([:])
    private let changeWatchers = Locked<[UUID: @Sendable () -> Void]>([:])
    private let observing = Locked(false)

    var isAway: Bool { phase.withLock { $0.away } }
    /// The app is active: neither resigned nor in the background.
    var isActive: Bool { phase.withLock { !$0.away && !$0.resigned } }
    /// How often the app has entered the background since this was made.
    var leavings: Int { phase.withLock { $0.leavings } }

    /// The app is away, or is back. Leaving tells every watcher, once per leaving.
    func set(away now: Bool) {
        let changed = phase.withLock { (p: inout Phase) -> Bool in
            defer { p.away = now }
            guard p.away != now else { return false }
            if now { p.leavings += 1 }
            return true
        }
        guard changed else { return }
        if now { for w in watchers.withLock({ Array($0.values) }) { w() } }
        for w in changeWatchers.withLock({ Array($0.values) }) { w() }
    }

    /// The app has resigned (it is no longer active, and may or may not enter the background), or is active again.
    func set(resigned now: Bool) {
        let changed = phase.withLock { (p: inout Phase) -> Bool in
            defer { p.resigned = now }
            return p.resigned != now
        }
        guard changed else { return }
        for w in changeWatchers.withLock({ Array($0.values) }) { w() }
    }

    /// Calls `f` at every change of the app's state (resigned, active, away, back). Returns what removes it.
    func onChange(_ f: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        changeWatchers.withLock { $0[id] = f }
        return id
    }

    /// Calls `f` when the app leaves (at once when it is away already). Returns what removes it.
    func onAway(_ f: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        watchers.withLock { $0[id] = f }
        if isAway { f() }
        return id
    }

    func remove(_ id: UUID) {
        watchers.withLock { $0[id] = nil }
        changeWatchers.withLock { $0[id] = nil }
    }

    /// Follows the system from here on (iOS; nothing elsewhere), starting from the application's state now.
    func observeSystem() {
        let first = observing.withLock { (o: inout Bool) -> Bool in
            defer { o = true }
            return !o
        }
        guard first else { return }
        if let stand = Self.startsAway.withLock({ $0 }) {
            set(away: stand())
            return
        }
        #if canImport(UIKit) && os(iOS)
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.set(away: true)
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.set(away: false)
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.set(resigned: true)
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.set(resigned: false)
        }
        // a process the system started in the background (for a session's events) is away from its first moment
        if Thread.isMainThread {
            let state = MainActor.assumeIsolated { UIApplication.shared.applicationState }
            set(resigned: state != .active)
            set(away: state == .background)
        } else {
            Task { @MainActor [weak self] in
                let state = UIApplication.shared.applicationState
                self?.set(resigned: state != .active)
                self?.set(away: state == .background)
            }
        }
        #endif
    }
}

/// One range of a model file that a background task fetches, named so that a task that finishes after the app was
/// relaunched still says where its bytes belong and what they must be.
struct BackgroundRange: Sendable, Hashable {
    /// The build's download folder, relative to the SDK's storage (`models/v4.0/.download-<build>`).
    let folder: String
    /// The stored file's path in the model folder (`layers.zfw.gz`).
    let path: String
    let lower: Int64
    let upper: Int64
    /// The whole file's size in the signed manifest: the total a 206 for this range must name (SPEC 16.1).
    let size: Int64

    init(folder: String, path: String, lower: Int64, upper: Int64, size: Int64) {
        self.folder = folder
        self.path = path
        self.lower = lower
        self.upper = upper
        self.size = size
    }

    /// The task's name: `<folder>|<path>|<lower>|<upper>|<size>`.
    var key: String { [folder, path, String(lower), String(upper), String(size)].joined(separator: "|") }

    init?(key: String) {
        let parts = key.components(separatedBy: "|")
        guard parts.count == 5, let lower = Int64(parts[2]), let upper = Int64(parts[3]), let size = Int64(parts[4]),
              lower >= 0, upper >= lower, upper < size,
              !parts[0].isEmpty, !parts[1].isEmpty, !parts[0].contains(".."), !parts[1].contains("..") else { return nil }
        self.init(folder: parts[0], path: parts[1], lower: lower, upper: upper, size: size)
    }

    /// What the names of every task of one download folder start with.
    static func prefix(folder: String) -> String { folder + "|" }

    /// The partial file of the stored file in a download folder.
    static func part(_ folder: URL, _ path: String) -> URL { folder.appendingPathComponent(path + ".part") }

    /// Where a finished range is kept until the installer joins it: beside the partial file, named for its first byte.
    static func file(part: URL, lower: Int64) -> URL { URL(fileURLWithPath: part.path + ".r\(lower)") }

    /// The finished ranges kept beside a partial file, by their first byte, in order.
    static func kept(beside part: URL) -> [(lower: Int64, file: URL)] {
        let dir = part.deletingLastPathComponent()
        let stem = part.lastPathComponent + ".r"
        var out: [(lower: Int64, file: URL)] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(stem) {
            guard let lower = Int64(name.dropFirst(stem.count)) else { continue }
            out.append((lower, dir.appendingPathComponent(name)))
        }
        return out.sorted { $0.lower < $1.lower }
    }
}

/// What carries a range request while the app is not running: the background session, or a stand-in in tests.
protocol BackgroundRangeTransport: Sendable {
    /// Starts one download task for `request`, named `key` (a `BackgroundRange.key`).
    func start(_ request: URLRequest, key: String)
    /// The names of the tasks that have not ended, of those whose name starts with `prefix`.
    func pending(prefix: String) async -> Set<String>
    /// Cancels the tasks that have not ended, of those whose name starts with `prefix`; their names.
    func cancel(prefix: String) async -> Set<String>
    /// The bytes the tasks that have not ended have received so far, of those whose name starts with `prefix`.
    func received(prefix: String) async -> Int64
}

extension BackgroundRangeTransport {
    func received(prefix: String) async -> Int64 { 0 }
}

/// What becomes of a range request that a background task finished.
enum RangeDelivery {
    enum Outcome: Sendable, Equatable {
        /// The bytes are kept beside the partial file, for the installer to join.
        case placed
        /// Nothing is kept, and why. The installer fetches the range itself.
        case discarded(String)
        /// The system redirected the request, and this is the host it ended on: the bytes are refused (SPEC 15.4).
        case redirected(String)
        /// The server refused the request (a 4xx): nothing is kept, and the refusal is told to the model gate.
        case refused
    }

    /// Where finished ranges go and who is told what.
    struct Sink: Sendable {
        /// The SDK's storage folder.
        let storage: URL
        /// A refusal of the request, as the model gate takes it (it acts on a refusal that stops the model only).
        let refused: @Sendable (CloudError) -> Void
        /// The host a redirected request ended on: reported as the issue `update_failed`, `model_redirected:<host>`.
        let redirected: @Sendable (_ host: String) -> Void
    }

    /// What a finished task brought, as the session's delegate gathers it.
    struct Arrival: Sendable {
        /// The file the system delivered, moved to a place of the SDK's own; nil when the task brought none.
        var body: URL?
        let key: String
        var status: Int
        /// The URL the task was made to, and the URL of the answer.
        var asked: URL?
        var final: URL?
        /// The redirects the system followed, as its metrics count them.
        var redirects = 0
        /// The answer's `Content-Range`.
        var contentRange: String?
    }

    /// A background range request has ended with an answer; its file is moved or removed here. Kept only: a 206
    /// whose Content-Range is the range asked for and names the manifest's size as its total (SPEC 16.1), with
    /// exactly the range's bytes, from the address the request was made to, for a download folder that is still
    /// there.
    /// A redirect: on this one path the operating system follows a redirect without asking the SDK. The request
    /// was redirected when the system counts a redirect for it, or when the answer's scheme, host or port is not
    /// the request's (the same rule as for the background upload, `BackgroundUploader.redirectedHost`). The bytes
    /// are then discarded, nothing is installed or resumed from them, and the host the request ended on (the host
    /// only) is reported.
    /// A refusal: a 401 or a 403. The body of any 4xx is handed to the model gate, which acts on a stop only, and a
    /// stop is read only from a 401 or a 403 (`ModelGate.stops(status:reason:)`); any other 4xx is a failed range.
    /// Tried before (the first candidate, never released): only the host was compared, so a redirect to another
    /// port or scheme of the same host, and a chain that led back to the model host, were taken as served; a 206
    /// was held to its length only; and only a 401 or 403 was read for a stop.
    @discardableResult
    static func deliver(_ arrival: Arrival, sink: Sink) -> Outcome {
        let fm = FileManager.default
        let body = arrival.body
        func drop() { if let body { try? fm.removeItem(at: body) } }
        guard let range = BackgroundRange(key: arrival.key) else {
            drop()
            return .discarded("not a range of a model file")
        }
        if let host = BackgroundUploader.redirectedHost(asked: arrival.asked, final: arrival.final, redirects: arrival.redirects) {
            drop()
            sink.redirected(host)
            return .redirected(host)
        }
        let status = arrival.status
        if (400..<500).contains(status) {
            var answer = Data()
            if let body, let h = try? FileHandle(forReadingFrom: body) {
                answer = (try? h.read(upToCount: 65_536)) ?? Data()
                try? h.close()
            }
            drop()
            // the gate is told, and acts on a stop only (a 401 or a 403 with a reason of the list)
            let failure = HTTPClient.failure(status: status, body: answer)
            sink.refused(failure)
            if status == 401 || status == 403 { return .refused }
            return .discarded("status \(status)")
        }
        guard status == 206, let body else {
            drop()
            return .discarded("status \(status)")
        }
        guard let named = HTTPClient.contentRange(arrival.contentRange), named.lower == range.lower, named.upper == range.upper,
              named.total == range.size else {
            drop()
            return .discarded("a 206 for another range or another file size than the one asked for")
        }
        guard ModelInstaller.sizeOnDisk(body) == range.upper - range.lower + 1 else {
            drop()
            return .discarded("not the length of the range")
        }
        let folder = sink.storage.appendingPathComponent(range.folder, isDirectory: true)
        guard fm.fileExists(atPath: folder.path) else {
            drop()
            return .discarded("the download it belongs to is gone")
        }
        let part = BackgroundRange.part(folder, range.path)
        let kept = BackgroundRange.file(part: part, lower: range.lower)
        // the file's own folders below the download folder, one by one: when the download folder has just gone (a
        // stop removed it), the first of them cannot be made, and nothing is made again in its place
        var dir = folder
        for name in range.path.split(separator: "/").dropLast() {
            dir.appendPathComponent(String(name), isDirectory: true)
            if !fm.fileExists(atPath: dir.path) { try? fm.createDirectory(at: dir, withIntermediateDirectories: false) }
        }
        try? fm.removeItem(at: kept)
        do {
            try fm.moveItem(at: body, to: kept)
        } catch {
            drop()
            return .discarded("the range could not be kept: \(error.localizedDescription)")
        }
        return .placed
    }
}

/// What an install needs to hand ranges to the background transport.
struct BackgroundPlan: Sendable {
    let transport: any BackgroundRangeTransport
    let policy: BackgroundDownloadPolicy
    let handOver: DownloadHandOver
    /// The build's download folder, relative to the SDK's storage (the first part of a task's name).
    let folder: String
    /// The request of one range of a stored file: the token as it is now (and the key, unless the signed config
    /// says a background transfer sends the token alone), the validator, the mark of an update that waits for an
    /// unmetered network. Nil when no token can be had now. A background task keeps the request it was made with:
    /// its token is not renewed, and a range that the server refuses for its token is fetched by the installer
    /// itself, which renews.
    let request: @Sendable (_ path: String, _ lower: Int64, _ upper: Int64, _ validator: String?) async -> URLRequest?
    /// Told how many tasks were cancelled before they ended when the app returned (each abandoned whole).
    let abandoned: @Sendable (Int) -> Void
    /// The refusal that stops the model, when one has arrived (a background task may have met it): the round
    /// ends, its tasks are cancelled, and the installer makes no further request.
    let stopped: @Sendable () -> RecognizerError?
    /// `whenResigning`: told how many tasks were cancelled, and how many bytes they had fetched were dropped, when
    /// the app was active again without having been in the background.
    let dropped: @Sendable (_ tasks: Int, _ bytes: Int64) -> Void
    /// The files of the install that come after the one in hand: handed over with it, so that a download that the
    /// learner left goes on to its end.
    let later = Locked<[ModelManifest.File]>([])

    /// `whenResigning`: the tasks that were made when the app resigned are out.
    struct Out: Sendable {
        /// The hand-over's count of leavings when they were made (one less when the app was away already): when
        /// it differs at the app's return, the app has been in the background meanwhile.
        var since: Int
        /// The range files that were kept before they were made: those are not theirs, and are never dropped.
        var keptBefore: Set<String>
    }
    let out = Locked<Out?>(nil)
}

/// Download tasks on a background URLSession, one per identifier per process (a background session identifier may
/// be used once). A task that ends hands what it brought to `RangeDelivery.deliver`. A task that ends without an
/// answer leaves nothing: the installer fetches its range.
///
/// The order the system keeps for a download task: the file (`didFinishDownloadingTo`, where the system's
/// temporary file must be moved before the call returns), then the task's metrics, which count its redirects, then
/// its end. So the file is first moved to a place of the SDK's own, and judged when the task ends, with the
/// redirect count in hand.
/// What ends before a sink is attached (the system started the app for the session's events and the Client is not
/// made yet) is KEPT and judged when the sink is attached.
/// Tried before (the first candidate, never released): the file was judged in `didFinishDownloadingTo`, before
/// the redirect count was known, and what arrived before the sink was attached was dropped.
final class BackgroundDownloader: NSObject, URLSessionDownloadDelegate, BackgroundRangeTransport, @unchecked Sendable {
    private static let all = Locked<[String: BackgroundDownloader]>([:])

    static func identifier(for app: AppIdentity) -> String { BackgroundEvents.prefix + "models." + app.bundleID }

    static func existing(_ identifier: String) -> BackgroundDownloader? { all.withLock { $0[identifier] } }

    /// The downloader of `identifier`, made at first need: `parallel` tasks run at a time.
    static func shared(identifier: String, parallel: Int) -> BackgroundDownloader {
        all.withLock { m in
            if let d = m[identifier] { return d }
            let d = BackgroundDownloader(identifier: identifier, parallel: parallel)
            m[identifier] = d
            // the system's completion handler came before the Client was made: it was waiting for this session
            if let waited = BackgroundEvents.take(identifier) { d.setFinishedHandler(waited) }
            return d
        }
    }

    let identifier: String
    private struct State {
        var sink: RangeDelivery.Sink?
        var finished: (@Sendable () -> Void)?
        /// The tasks started in this launch whose end the delegate has not been told yet, by name (a name can be
        /// started again after its first task was cancelled, so they are counted). A task counts as ended only
        /// when the delegate was told so, which is after its file was judged: the session's own list can show a
        /// task as ended a moment before that.
        var inFlight: [String: Int] = [:]
        /// The file a task delivered, held until the task ends (by task identifier).
        var held: [Int: URL] = [:]
        /// The redirects the system followed for a task, as its metrics say (by task identifier).
        var redirects: [Int: Int] = [:]
        /// The protocol a task went by, as its metrics name it (by task identifier).
        var protocols: [Int: String] = [:]
        /// What ended before a sink was attached: judged at `attach`.
        var waiting: [RangeDelivery.Arrival] = []
    }
    private let state = Locked(State())
    private var session: URLSession!

    private init(identifier: String, parallel: Int) {
        self.identifier = identifier
        super.init()
        let c = URLSessionConfiguration.background(withIdentifier: identifier)
        c.sessionSendsLaunchEvents = true
        // a learner waits for this download: it is not left to the system's discretion. (Tasks made while the app
        // is in the background are discretionary whatever this says.)
        c.isDiscretionary = false
        c.httpMaximumConnectionsPerHost = max(1, parallel)
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }

    /// Where finished ranges go. What ended before this was called is judged now.
    func attach(_ sink: RangeDelivery.Sink) {
        let waited = state.withLock { (s: inout State) -> [RangeDelivery.Arrival] in
            s.sink = sink
            defer { s.waiting = [] }
            return s.waiting
        }
        for arrival in waited { RangeDelivery.deliver(arrival, sink: sink) }
    }

    /// The app delegate's completion handler for `handleEventsForBackgroundURLSession`.
    func setFinishedHandler(_ h: @escaping @Sendable () -> Void) { state.withLock { $0.finished = h } }

    func start(_ request: URLRequest, key: String) {
        state.withLock { s in s.inFlight[key, default: 0] += 1 }
        let t = session.downloadTask(with: request)
        t.taskDescription = key
        t.resume()
    }

    /// The names of the tasks of this launch that the delegate has not been told the end of, of those under `prefix`.
    private func inFlight(prefix: String) -> Set<String> {
        state.withLock { s in Set(s.inFlight.keys.filter { name in name.hasPrefix(prefix) }) }
    }

    private func unfinished(prefix: String) async -> [URLSessionTask] {
        let tasks = await session.allTasks
        return tasks.filter { t in
            (t.state == .running || t.state == .suspended) && (t.taskDescription?.hasPrefix(prefix) ?? false)
        }
    }

    func pending(prefix: String) async -> Set<String> {
        let listed = Set(await unfinished(prefix: prefix).compactMap { $0.taskDescription })
        return listed.union(inFlight(prefix: prefix))
    }

    func cancel(prefix: String) async -> Set<String> {
        let tasks = await unfinished(prefix: prefix)
        for t in tasks { t.cancel() }
        return Set(tasks.compactMap { $0.taskDescription })
    }

    func received(prefix: String) async -> Int64 {
        await unfinished(prefix: prefix).reduce(Int64(0)) { $0 + max(0, $1.countOfBytesReceived) }
    }

    /// For the measurement on a phone (debug builds): when a range's task was made, when its request went out and
    /// when its answer ended, as the system's metrics say. The system keeps these while the app is suspended, so
    /// the line says when a handed-over range really started and finished, whenever the app gets to write it.
    private static func timing(_ task: URLSessionTask, _ metrics: URLSessionTaskMetrics) {
        guard let key = task.taskDescription, let range = BackgroundRange(key: key) else { return }
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        let sent = metrics.transactionMetrics.first?.requestStartDate.map { clock.string(from: $0) } ?? "not sent"
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        SDKLatest.debugOnly("model download: background range \(range.lower)-\(range.upper) of \(range.path): task made \(clock.string(from: metrics.taskInterval.start)), "
            + "request sent \(sent), ended \(clock.string(from: metrics.taskInterval.end)), HTTP \(status)")
    }

    /// Where a task's file waits for the task's end: a file of the SDK's own in the temporary folder.
    private static func holding() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ai.quranlab.range-" + UUID().uuidString)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // the system's file is gone when this returns: it is moved now, and judged when the task ends
        let held = Self.holding()
        guard (try? FileManager.default.moveItem(at: location, to: held)) != nil else { return }
        let earlier = state.withLock { $0.held.updateValue(held, forKey: downloadTask.taskIdentifier) }
        if let earlier { try? FileManager.default.removeItem(at: earlier) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        Self.timing(task, metrics)
        let named = metrics.transactionMetrics.last(where: { $0.networkProtocolName != nil })?.networkProtocolName
        let count = metrics.redirectCount
        state.withLock { (s: inout State) in
            if count > 0 { s.redirects[task.taskIdentifier] = count }
            if let named { s.protocols[task.taskIdentifier] = named }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let id = task.taskIdentifier
        let (held, redirects, named, sink) = state.withLock { (s: inout State) -> (URL?, Int, String?, RangeDelivery.Sink?) in
            (s.held.removeValue(forKey: id), s.redirects.removeValue(forKey: id) ?? 0, s.protocols.removeValue(forKey: id), s.sink)
        }
        defer {
            // the task has ended, and what it brought was judged (or is kept for the sink)
            if let key = task.taskDescription {
                state.withLock { s in
                    guard let count = s.inFlight[key] else { return }
                    s.inFlight[key] = count > 1 ? count - 1 : nil
                }
            }
        }
        guard let key = task.taskDescription, error == nil, let http = task.response as? HTTPURLResponse else {
            // no answer: a range that did not arrive has no range file, and the installer fetches it
            if let held { try? FileManager.default.removeItem(at: held) }
            return
        }
        let arrival = RangeDelivery.Arrival(body: held, key: key, status: http.statusCode, asked: task.originalRequest?.url, final: http.url,
                                            redirects: redirects, contentRange: http.value(forHTTPHeaderField: "Content-Range"))
        if let sink {
            // the protocol of a range the model host served, for `diagnose()` (in memory, this process)
            if RangeDelivery.deliver(arrival, sink: sink) == .placed, let named { ModelDownloadRecord.note(named) }
        } else {
            state.withLock { $0.waiting.append(arrival) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let h = state.withLock { s -> (@Sendable () -> Void)? in
            defer { s.finished = nil }
            return s.finished
        }
        if let h { DispatchQueue.main.async { h() } }
    }
}
