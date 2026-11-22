import Foundation

/// The body of one error report (24.2): section 7's top level with `kind: "error"` and the closed `error` object.
/// Never a message, frames, a path, a URL or an identifier: every field is a token, a small number or absent.
struct ErrorReportBody: Encodable, Sendable {
    struct Detail: Encodable, Sendable {
        var stage: String
        var reason: String
        var http_status: Int?
        var error_name: String?
        var error_code: String?
        var count: Int?
        var retries: Int?
        var first_launch: Bool?
        var first_report: Bool?
        var build: String?
        var device_model: String?
        var ram_tier: String?
        // no `storage_free` on Apple: the free space of the volume is read under the required reason E174.1, which
        // allows nothing derived from it to leave the device
        var abi: String?
        /// 4.0.1 (24.2, 28.7): `api`, `models` or `web_frame`, never a host name; and whether the request was asked of
        /// more than one host.
        var host_role: String?
        var fallback: Bool?
    }

    var day: String
    var platform: String
    var sdk_version: String
    var app_version: String
    var os_version: String
    var device_class: String
    var revision: String?
    var kind = "error"
    var code: String
    var error: Detail

    /// The report of a queued entry; a field that is not the token its pattern asks for is left out, never cut.
    init(_ e: ErrorReportBook.Entry, app: AppIdentity) {
        day = e.day
        platform = app.platform
        sdk_version = SDKInfo.version
        app_version = app.version
        os_version = DeviceContext.osVersionString
        device_class = DeviceContext.deviceClass
        revision = e.revision.flatMap { Self.token($0, #"^[0-9A-Za-z][0-9A-Za-z.+-]{0,31}$"#) }
        code = e.code
        error = Detail(stage: e.stage, reason: e.reason,
                       http_status: e.httpStatus.flatMap { (100...599).contains($0) ? $0 : nil },
                       error_name: e.errorName.flatMap { Self.token($0, ErrorRules.errorNamePattern) },
                       error_code: e.errorCode.flatMap { Self.token($0, ErrorRules.errorCodePattern) },
                       count: max(1, min(ErrorReportBook.countMax, e.count)),
                       retries: e.retries.map { max(0, min(1000, $0)) },
                       first_launch: e.firstLaunch, first_report: e.firstReport,
                       build: e.build.flatMap { Self.token($0, #"^[0-9a-f]{40}$"#) },
                       device_model: DeviceModel.current.flatMap { Self.token($0, #"^[A-Za-z0-9_.,-]{1,32}$"#) },
                       ram_tier: DeviceContext.ramTier, abi: Self.abi,
                       host_role: e.hostRole.flatMap { EndpointRole(rawValue: $0) }?.rawValue,
                       fallback: e.hostRole == nil ? nil : e.fallback)
    }

    /// `value` when the whole of it matches `pattern`, else nil.
    static func token(_ value: String, _ pattern: String) -> String? { ErrorRules.token(value, pattern) }

    /// The process's ABI (24.2): `arm64`; an Intel Mac `x86_64_mac`; the x86_64 simulator `x86_64`.
    static var abi: String {
        #if arch(arm64)
        return "arm64"
        #elseif os(macOS)
        return "x86_64_mac"
        #else
        return "x86_64"
        #endif
    }
}

/// Error reports: every failure that reaches the app and every silent degradation of 24.1's
/// list becomes one report per install, UTC day and signature, with its count (`ErrorReportBook`). The book is kept in
/// the SDK's folder (`cloud/error-reports.json`); an occurrence is recorded on a utility queue, in order, and never
/// waits on the caller. A store that cannot be read or written leaves the book in memory for the process.
final class ErrorReporter: Sendable {
    private let file: JSONFile<ErrorReportBook>
    private let book: Locked<ErrorReportBook>
    private let saver = DispatchQueue(label: "ai.quranlab.errors", qos: .utility)
    private let sending = Locked(false)
    private let app: AppIdentity
    private let clock: @Sendable () -> Date
    /// The occurrence is in the install's first process (no marker of an earlier start).
    let firstLaunch: Bool
    /// The model version and build in use or being fetched, when known; read on the utility queue.
    private let context: @Sendable () -> (revision: String?, build: String?)
    /// Told when an occurrence made a new report (the 30-second send point, 24.6); set by the Client.
    let onNew = Locked<(@Sendable () -> Void)?>(nil)

    init(storage: URL, app: AppIdentity, firstLaunch: Bool, clock: @escaping @Sendable () -> Date = { Date() },
         context: @escaping @Sendable () -> (revision: String?, build: String?) = { (nil, nil) }) {
        file = JSONFile(url: storage.appendingPathComponent("cloud/error-reports.json"))
        // unreadable is taken as not there here, because these are reports not yet sent: they are lost, and the next
        // failure makes its report again
        book = Locked(file.read().takingUnreadableAsMissing ?? ErrorReportBook())
        self.app = app
        self.firstLaunch = firstLaunch
        self.clock = clock
        self.context = context
    }

    /// An occurrence of `cause`, whose app got `code` (`none` for a silent failure). `enabled`: `flags.issues`.
    func occur(_ cause: ErrorCause, code: String, enabled: Bool) {
        guard enabled, ErrorRules.reported(stage: cause.stage, reason: cause.reason, code: code) else { return }
        let day = Day.string(clock())
        let first = firstLaunch
        let (book, file, context, onNew) = (self.book, self.file, self.context, self.onNew)
        saver.async {
            let c = context()
            let made = book.withLock { (b: inout ErrorReportBook) -> Bool in
                b.occur(day: day, cause: cause, code: code, firstLaunch: first, snapshot: (c.revision, c.build))
            }
            file.write(book.withLock { $0 })
            if made, let wake = onNew.withLock({ $0 }) { wake() }
        }
    }

    /// `flags.issues: false`: the queue goes.
    func dropQueue() {
        let (book, file) = (self.book, self.file)
        saver.async {
            book.withLock { $0.dropQueue() }
            file.write(book.withLock { $0 })
        }
    }

    /// The occurrences recorded so far are in the book (tests).
    func waitForSave() { saver.sync {} }

    var snapshot: ErrorReportBook { book.withLock { $0 } }

    /// A send point (24.6): each queued report, oldest first, one request each, until an answer keeps one. `post`
    /// sends a body and returns the status the server answered, nil for none. One send point at a time.
    @discardableResult
    func send(_ post: (Data) async -> Int?) async -> Int {
        let claimed = sending.withLock { (s: inout Bool) -> Bool in
            defer { s = true }
            return !s
        }
        guard claimed else { return 0 }
        let today = Day.string(clock())
        let due = book.withLock { (b: inout ErrorReportBook) -> [ErrorReportBook.Entry] in b.due(today: today) }
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        var sent = 0
        for e in due {
            guard let body = try? enc.encode(ErrorReportBody(e, app: app)) else { continue }
            let status = await post(body)
            if status == 202 { sent += 1 }
            let goOn = book.withLock { (b: inout ErrorReportBook) -> Bool in b.answered(e, status: status) }
            if !goOn { break }
        }
        let (kept, store) = (self.book, self.file)
        saver.async { store.write(kept.withLock { $0 }) }
        sending.withLock { $0 = false }
        return sent
    }
}

extension ErrorReporter {
    /// A `TajweedError` the SDK made for the app (24.1 item 1): reported by the configured Client, with its cause.
    static func raised(_ code: String, cause: ErrorCause) {
        QuranLab.cloud?.errorOccurred(cause, code: code)
    }
}
