import Foundation
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

/// The events of the SDK's background URLSessions (3.1.5). The system finishes a background transfer while the app
/// is suspended or not running, starts the app in the background, and hands the app delegate a completion handler
/// (`application(_:handleEventsForBackgroundURLSession:completionHandler:)`; in SwiftUI the scene's
/// `.backgroundTask(.urlSession(...))`). The app forwards it with `TajweedClient.handleBackgroundEvents` or
/// `TajweedClient.backgroundEvents`; the SDK calls the handler when its session has delivered everything.
/// An app that forwards nothing loses nothing: the transfers finish all the same, and the SDK collects their
/// results when the Client is next made.
///
/// Tried before (to 3.1.2): the forwarding call was internal (`QuranLab.handleBackgroundEvents`), so no app could
/// reach it, and it refused a session whose Client was not made yet.
enum BackgroundEvents {
    /// The identifier of every background session of the SDK starts with this (the upload queue's is
    /// `ai.quranlab.contributions.<bundle id>`, the model download's `ai.quranlab.models.<bundle id>`).
    static let prefix = "ai.quranlab."

    static func owns(_ identifier: String) -> Bool { identifier.hasPrefix(prefix) }

    /// The system's completion handler as the app delegate gets it: UIKit does not mark it as safe to pass
    /// between threads. The SDK keeps it and calls it once, on the main queue (`Completion`).
    struct SystemHandler: @unchecked Sendable {
        let call: () -> Void
    }

    /// A completion handler that is called once, on the main queue, whoever calls it first.
    final class Completion: Sendable {
        private let handler: Locked<(@Sendable () -> Void)?>

        init(_ handler: @escaping @Sendable () -> Void) { self.handler = Locked(handler) }

        func call() {
            let h = handler.withLock { (h: inout (@Sendable () -> Void)?) -> (@Sendable () -> Void)? in
                defer { h = nil }
                return h
            }
            if let h { DispatchQueue.main.async { h() } }
        }
    }

    /// The handlers of sessions that are not made yet (the system's call came before the app made its Client).
    private static let waiting = Locked<[String: Completion]>([:])

    /// How long a handler waits for its session's last event before the SDK calls it anyway, in seconds: the system
    /// is always answered, also when the app makes no Client in this launch.
    static let patience = Locked<TimeInterval>(20)

    /// The app delegate's completion handler for the background session `identifier`. False, and the handler is
    /// not called, when the session is not the SDK's.
    static func handle(identifier: String, completionHandler: @escaping @Sendable () -> Void) -> Bool {
        guard owns(identifier) else { return false }
        let done = Completion(completionHandler)
        if let uploader = BackgroundUploader.existing(identifier) {
            uploader.setFinishedHandler { done.call() }
        } else if let downloader = BackgroundDownloader.existing(identifier) {
            downloader.setFinishedHandler { done.call() }
        } else {
            // its session is made with the Client: the handler waits for it
            waiting.withLock { $0[identifier] = done }
        }
        let wait = patience.withLock { $0 }
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            waiting.withLock { (w: inout [String: Completion]) in
                if w[identifier] === done { w[identifier] = nil }
            }
            done.call()
        }
        return true
    }

    /// The session `identifier` was made: the handler that waited for it, to be called when the session has
    /// delivered its events.
    static func take(_ identifier: String) -> (@Sendable () -> Void)? {
        guard let done = waiting.withLock({ $0.removeValue(forKey: identifier) }) else { return nil }
        return { done.call() }
    }
}

/// The time the system gives a download that is under way when the learner leaves the app (3.1.5). On iOS an
/// install asks for it when it starts (`UIApplication.beginBackgroundTask`), so a download that has seconds left
/// finishes instead of being cut when the app is suspended; it is given back in every way the install can end, and
/// when the system says the time is up. On macOS an app is not suspended and nothing is asked for.
/// Tried before (to 3.1.2): nothing was asked for, and a download stopped within seconds of the learner leaving.
enum InstallGrace {
    /// For tests: the stand-in for the system's assertion. Called when an install begins, with the name; what it
    /// returns is called when the install ends.
    static let override = Locked<(@Sendable (String) -> (@Sendable () -> Void))?>(nil)

    /// The name the system's tools show for it.
    static let name = "ai.quranlab.model-download"

    /// Begins; what it returns ends it, and may be called more than once.
    static func begin(_ name: String = InstallGrace.name) async -> @Sendable () -> Void {
        if let stand = override.withLock({ $0 }) { return stand(name) }
        #if canImport(UIKit) && os(iOS)
        return await MainActor.run { () -> (@Sendable () -> Void) in
            let invalid = UIBackgroundTaskIdentifier.invalid.rawValue
            let held = Locked(invalid)
            // the task's number, taken once: whoever comes first ends it
            let take: @Sendable () -> Int = {
                held.withLock { (raw: inout Int) -> Int in
                    defer { raw = invalid }
                    return raw
                }
            }
            let task = UIApplication.shared.beginBackgroundTask(withName: name) {
                // the system's time is up: given back at once, on the main thread, where this is called
                let raw = take()
                if raw != invalid { UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw)) }
            }
            held.withLock { $0 = task.rawValue }
            return {
                let raw = take()
                guard raw != invalid else { return }
                Task { @MainActor in UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw)) }
            }
        }
        #else
        return {}
        #endif
    }
}
