// A screen for checking the model download on a phone. The app's own file is these lines (put your key in):
//
//     import SwiftUI
//     import DownloadCheck
//
//     @main
//     struct CheckApp: App {
//         @UIApplicationDelegateAdaptor(DownloadCheckDelegate.self) private var delegate
//         init() { DownloadCheck.shared.key = "qlk_v1_..." }
//         var body: some Scene { WindowGroup { DownloadCheckView() } }
//     }
//
// What it shows: a log, one line per event, each with the time of day. The log is kept in a file, so a launch
// shows what the launches before it wrote. The lines: every launch (and whether the system started the app in the
// background), the app going to the background and coming back, a download's start, its end with the seconds it
// took and the bytes it began at, the protocol `diagnose()` reports for it, and the system handing the app a
// background session's events. "Open model" opens the model and keeps it open (the Neural Engine's build is then
// prepared in the background of the app: its compile, warm-up and test, with the SDK's lines about it); "Ask to
// share" shows the SDK's sharing sheet when Quran Lab offers sharing to the key's app; "Diagnose" also says the
// backend in use and the protection class of the SDK's saved sharing answer and config.
import Foundation
import OSLog
import SwiftUI
import TajweedFormer
#if os(iOS)
import UIKit
#endif

/// The files the screen keeps in the app's Application Support folder, beside the SDK's own: the log, the
/// transport chosen, and whether background events are forwarded.
enum CheckStore {
    private static let lock = NSLock()

    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let made = base.appendingPathComponent("DownloadCheck", isDirectory: true)
        try? FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return made
    }()

    static func read(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    static func write(_ name: String, _ text: String) {
        lock.lock()
        defer { lock.unlock() }
        try? Data(text.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    static func append(_ name: String, _ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let url = folder.appendingPathComponent(name)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? Data(text.utf8).write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }
}

/// The state behind the screen: one Client, made at launch as an app makes it, and the log.
@MainActor
public final class DownloadCheck: ObservableObject {
    public static let shared = DownloadCheck()

    /// How a model download is carried. `whenLeaving` is the SDK's default on iOS: the download runs in the app,
    /// and what is left when the app has entered the background goes to a background session. `whenResigning` is
    /// the same with the other hand-over moment: the background tasks are made when the app resigns, and the
    /// app's own request is not cut. `fromFirstByte` hands every range to the background session from the start.
    /// `off` keeps the whole download in the app.
    public enum Transport: String, CaseIterable, Sendable {
        case whenLeaving
        case whenResigning
        case fromFirstByte
        case off

        public var title: String {
            switch self {
            case .whenLeaving: return "at background"
            case .whenResigning: return "at resign"
            case .fromFirstByte: return "first byte"
            case .off: return "off"
            }
        }
    }

    /// The app's key (`qlk_v1_...`, from sdk.quranlab.ai, for the app's bundle id). Set it in the App's `init`.
    public var key = ""
    @Published public private(set) var lines: [String] = []
    @Published public private(set) var busy = false
    @Published public private(set) var transport: Transport
    @Published public private(set) var forwards: Bool
    /// Off at every launch, so the launch the system makes afterwards stays.
    @Published public private(set) var endsInBackground = false

    /// The first and the last progress report of one download.
    private final class ProgressSeen: @unchecked Sendable {
        private let lock = NSLock()
        private var first: Int64?
        private var last: Int64 = 0
        private var total: Int64 = 0

        func report(_ done: Int64, _ of: Int64) {
            lock.lock()
            if first == nil { first = done }
            last = done
            total = of
            lock.unlock()
        }

        var summary: String {
            lock.lock()
            defer { lock.unlock() }
            guard let first else { return "no bytes reported (the model was on the device)" }
            return "bytes at the first report \(first), at the last \(last), of \(total)"
        }
    }

    private var client: TajweedClient?
    private var launched = false
    private let clock: DateFormatter

    private init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        clock = formatter
        let chosen = CheckStore.read("transport.txt")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        transport = Transport(rawValue: chosen) ?? .whenLeaving
        forwards = CheckStore.read("forward.txt")?.trimmingCharacters(in: .whitespacesAndNewlines) != "no"
        lines = (CheckStore.read("log.txt") ?? "").split(separator: "\n").map { String($0) }
    }

    /// The SDK's own lines of this process (a debug build of the SDK writes them to the system's log, subsystem
    /// `ai.quranlab.sdk`: when ranges were handed to the background session, when each of them was asked for and
    /// ended, what was given up or dropped). They are read from the log and added to the screen, each once, with
    /// the time the SDK wrote them, so that they can be copied with the rest.
    private var sdkLinesSeen = Date.distantPast

    public func pullSDKLines() {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(matching: NSPredicate(format: "subsystem == %@", "ai.quranlab.sdk")) else { return }
        var latest = sdkLinesSeen
        for entry in entries {
            guard let line = entry as? OSLogEntryLog, line.date > sdkLinesSeen else { continue }
            let text = clock.string(from: line.date) + "  SDK: " + line.composedMessage
            lines.append(text)
            CheckStore.append("log.txt", text + "\n")
            latest = max(latest, line.date)
        }
        sdkLinesSeen = latest
    }

    /// One line of the log, with the time of day.
    public func note(_ text: String) {
        let line = clock.string(from: Date()) + "  " + text
        lines.append(line)
        CheckStore.append("log.txt", line + "\n")
        print("DownloadCheck: " + line)
    }

    /// The app has started, in the foreground or by the system in the background: the Client is made now.
    public func launch() {
        guard !launched else { return }
        launched = true
        #if os(iOS)
        let how = UIApplication.shared.applicationState == .background ? "in the background (the system started the app)" : "in the foreground"
        #else
        let how = "on a Mac"
        #endif
        note("LAUNCH " + how)
        makeClient()
    }

    /// The transport is a switch for measuring, read by the SDK from the environment when a Client is made, in a
    /// DEBUG build only (an app run from Xcode): in a release build the SDK uses its default whatever is set here.
    private func makeClient() {
        guard client == nil else { return }
        guard !key.isEmpty else {
            note("no key: set DownloadCheck.shared.key in the App's init")
            return
        }
        setenv("QURANLAB_BACKGROUND_DOWNLOADS", transport.rawValue, 1)
        do {
            client = try TajweedClient(key: key)
            note("Client made; transport: " + transport.title + "; background events are " + (forwards ? "forwarded" : "NOT forwarded"))
        } catch {
            note("the Client could not be made: \(error)")
        }
    }

    /// Another transport: the Client is closed and made again, so the next download uses it.
    public func choose(_ new: Transport) {
        guard new != transport, !busy else { return }
        transport = new
        CheckStore.write("transport.txt", new.rawValue)
        client?.close()
        client = nil
        makeClient()
    }

    public func forward(_ on: Bool) {
        guard on != forwards else { return }
        forwards = on
        CheckStore.write("forward.txt", on ? "yes" : "no")
        note("background events are now " + (on ? "forwarded to the SDK" : "NOT forwarded"))
    }

    private func seconds(since start: Date) -> String { String(format: "%.1f", Date().timeIntervalSince(start)) }

    /// `client.prefetch()`: the download and its verification, without opening the model. The seconds are wall
    /// time from the tap to the end, the time the app was suspended included. The bytes at the first report say
    /// where the download began: near zero for a first install, far above it when it went on from what was on the
    /// device.
    public func download() async {
        guard !busy else { return }
        makeClient()
        guard let client else { return }
        busy = true
        defer { busy = false }
        let start = Date()
        note("DOWNLOAD started; transport: " + transport.title)
        let progress = ProgressSeen()
        do {
            try await client.prefetch(onProgress: { done, total in progress.report(done, total) })
            pullSDKLines()
            note("DOWNLOAD done after " + seconds(since: start) + " s; " + progress.summary)
        } catch {
            pullSDKLines()
            note("DOWNLOAD failed after " + seconds(since: start) + " s: \(error); " + progress.summary)
        }
        await diagnose()
    }

    /// What `diagnose()` says about the model, the connection and the last download's protocol; the backend; and
    /// the protection class of two of the SDK's files in its default storage folder.
    public func diagnose() async {
        guard let client else { return }
        pullSDKLines()
        let d = await client.diagnose()
        let model = d.model.map { String($0.build.prefix(12)) } ?? "none on the device"
        note("diagnose: protocol " + (d.downloadProtocol ?? "none recorded") + "; connection " + d.connection + "; model " + model
            + "; SDK " + d.sdkVersion + "; backend " + (d.backend.map { "\($0)" } ?? "none"))
        note("protection: sharing-state.json " + Self.protection("cloud/sharing-state.json") + "; config.json " + Self.protection("cloud/config.json"))
    }

    /// The protection class of a file in the SDK's default storage folder (`Application Support/QuranLab`).
    static func protection(_ path: String) -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("QuranLab").appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return "not there yet" }
        guard let p = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.protectionKey] as? FileProtectionType else { return "no class" }
        return p.rawValue
    }

    /// The model, opened and kept open: the Neural Engine's build is prepared while it is open.
    private var model: TajweedModel?

    /// Opens the model (downloading it first when it is not on the device) and keeps it open.
    public func open() async {
        guard !busy else { return }
        makeClient()
        guard let client else { return }
        busy = true
        defer { busy = false }
        let start = Date()
        note("OPEN started")
        do {
            model = try await client.model()
            pullSDKLines()
            note("OPEN done after " + seconds(since: start) + " s; the model stays open")
        } catch {
            pullSDKLines()
            note("OPEN failed after " + seconds(since: start) + " s: \(error)")
        }
        await diagnose()
    }

    /// The SDK's sharing sheet, now, when an ask is allowed.
    public func ask() {
        guard let client else { return }
        note(client.sharing.isAvailable ? (client.sharing.ask() ? "the sharing sheet is shown" : "no ask is allowed now")
                                        : "sharing is not offered to this app's key")
    }

    /// Removes the model files, so the next download is a first install again.
    public func remove() {
        guard let client, !busy else { return }
        do {
            try client.removeModels()
            note("model files removed: the next download is a first install")
        } catch {
            note("the model files could not be removed: \(error)")
        }
    }

    public func clear() {
        lines = []
        CheckStore.write("log.txt", "")
    }

    public func endInBackground(_ on: Bool) {
        guard on != endsInBackground else { return }
        endsInBackground = on
        note("the app " + (on ? "ENDS ITSELF 3 s after it next goes to the background" : "stays when it goes to the background"))
    }

    /// With the switch on, the app ends itself three seconds after it went to the background. That is how to see
    /// the system start the app again when a background session is done: an app the system ended, or that ended
    /// itself, is started again; an app the user quit from the app switcher is not, and its transfers are cancelled.
    public func phase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            pullSDKLines()
            note("the app is ACTIVE (in the foreground)")
        case .background:
            note("the app is in the BACKGROUND")
            guard endsInBackground else { return }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.pullSDKLines()
                self.note("the app ENDS ITSELF now")
                exit(0)
            }
        case .inactive: break
        @unknown default: break
        }
    }

    /// The app delegate's `application(_:handleEventsForBackgroundURLSession:completionHandler:)`: forwarded to the
    /// SDK, or answered by the app itself when forwarding is switched off (as an app that does not forward).
    public func backgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        launch()
        guard forwards else {
            note("EVENTS of " + identifier + " handed over by the system; NOT forwarded")
            completionHandler()
            return
        }
        let start = Date()
        let taken = TajweedClient.handleBackgroundEvents(identifier: identifier) {
            // the SDK calls this on the main queue, when its session has delivered everything
            self.note("the SDK answered the system " + self.seconds(since: start) + " s after the events were handed over")
            completionHandler()
        }
        note("EVENTS of " + identifier + " handed over by the system; forwarded to the SDK: " + (taken ? "yes" : "no, not the SDK's session"))
        if !taken { completionHandler() }
    }
}

#if os(iOS)
/// The app delegate: the launch, and the events of background sessions.
public final class DownloadCheckDelegate: NSObject, UIApplicationDelegate {
    public func application(_ application: UIApplication,
                            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DownloadCheck.shared.launch()
        return true
    }

    public func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                            completionHandler: @escaping () -> Void) {
        DownloadCheck.shared.backgroundEvents(identifier: identifier, completionHandler: completionHandler)
    }
}
#endif

/// The screen: the transport, the two switches, four buttons and the log.
@MainActor
public struct DownloadCheckView: View {
    @ObservedObject private var check = DownloadCheck.shared
    @Environment(\.scenePhase) private var phase
    @State private var transport = DownloadCheck.shared.transport
    @State private var forwards = DownloadCheck.shared.forwards
    @State private var endsInBackground = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Transport", selection: $transport) {
                ForEach(DownloadCheck.Transport.allCases, id: \.self) { one in
                    Text(one.title).tag(one)
                }
            }
            .pickerStyle(.segmented)
            .disabled(check.busy)
            Toggle("Forward background events", isOn: $forwards)
            Toggle("End the app 3 s after it goes to the background", isOn: $endsInBackground)
            HStack(spacing: 16) {
                Button("Download") { Task { await check.download() } }
                Button("Diagnose") { Task { await check.diagnose() } }
                Button("Remove") { check.remove() }
                Button("Clear log") { check.clear() }
            }
            HStack(spacing: 16) {
                Button("Open model") { Task { await check.open() } }
                Button("Ask to share") { check.ask() }
            }
            if check.busy { ProgressView() }
            ScrollView {
                Text(check.lines.joined(separator: "\n"))
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .onAppear { check.launch() }
        .onChange(of: phase) { new in check.phase(new) }
        .onChange(of: transport) { new in check.choose(new) }
        .onChange(of: forwards) { new in check.forward(new) }
        .onChange(of: endsInBackground) { new in check.endInBackground(new) }
    }
}
