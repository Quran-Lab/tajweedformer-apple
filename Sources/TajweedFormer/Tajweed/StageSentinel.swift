import Foundation
#if canImport(Darwin)
import Darwin
#endif

// How a process that left a promotion sentinel ended (3.1.5), so that only a crash counts as one.
//
// While a compile, load or first inference runs (`PromotionStore.writeSentinel` to `clearSentinel`), this process holds
// an exclusive `flock` on the stage's lock file. The system drops the lock when the process ends, however it ends, so
// another process of the app (or a later launch) can tell a stage under way (lock held: left alone) from one whose
// process is gone (lock free: judged). A pid alone could not tell: pids are reused, and on iOS another app's process
// cannot be asked.
//
// Two marks beside it say how the process ended, written from places that may not allocate (an exit handler, a signal
// handler), so their paths are kept as C strings made when the stage began:
// - `.quit`: a normal exit (`exit`, returning from `main`: `atexit`), the app's willTerminate, and on the Mac SIGINT and
//   SIGTERM when the app left them to the system (the mark is written, then the signal ends the process as before);
// - `.background`: the app went to the background during the stage (iOS: didEnterBackground; the Mac: the app hid or
//   resigned active) and did not come back before it ended.
// No mark is a crash.
//
// Tried before (to 3.1.4): one sentinel file for every process of the app and no mark, so a command-line tool that
// returned from `main` while the build was loading, an app quit or stopped by the system in its first seconds, and a
// second process of the app that started while the first was in a stage were all recorded as a crash, which turns the
// build off for good for the key.

/// The path of a mark of the stage under way, as C text kept for the life of the process.
nonisolated(unsafe) private var quitMarkPath: UnsafeMutablePointer<CChar>?
nonisolated(unsafe) private var backgroundMarkPath: UnsafeMutablePointer<CChar>?

/// Creates the file at `path` (empty). Only calls that are safe in a signal handler.
private func touchMark(_ path: UnsafeMutablePointer<CChar>?) {
    guard let path else { return }
    let fd = open(path, O_CREAT | O_WRONLY, 0o600)
    if fd >= 0 { close(fd) }
}

private func markQuit() { touchMark(quitMarkPath) }

final class StageSentinel: @unchecked Sendable {
    static let shared = StageSentinel()

    private let lock = NSLock()
    private var hooked = false
    private var observers: [any NSObjectProtocol] = []
    /// The lock file's descriptor of each stage under way in this process, by path.
    private var held: [String: Int32] = [:]
    /// C strings of mark paths, made once per path.
    private var cPaths: [String: UnsafeMutablePointer<CChar>] = [:]
    private var inBackground = false

    #if canImport(UIKit) && !os(watchOS)
    static let backgroundNames = ["UIApplicationDidEnterBackgroundNotification"]
    static let foregroundNames = ["UIApplicationWillEnterForegroundNotification", "UIApplicationDidBecomeActiveNotification"]
    static let terminateName = "UIApplicationWillTerminateNotification"
    #else
    static let backgroundNames = ["NSApplicationDidHideNotification"]
    static let foregroundNames = ["NSApplicationDidUnhideNotification", "NSApplicationDidBecomeActiveNotification"]
    static let terminateName = "NSApplicationWillTerminateNotification"
    #endif

    private func cPath(_ url: URL) -> UnsafeMutablePointer<CChar>? {
        if let p = cPaths[url.path] { return p }
        guard let p = strdup(url.path) else { return nil }
        cPaths[url.path] = p
        return p
    }

    /// A stage begins in this process: its lock is taken (held until `end`), its marks are armed and any mark of an
    /// earlier stage of this process is removed.
    func begin(lock lockURL: URL, quit: URL, background: URL) {
        lock.lock()
        defer { lock.unlock() }
        hookOnce()
        try? FileManager.default.removeItem(at: quit)
        try? FileManager.default.removeItem(at: background)
        if held[lockURL.path] == nil {
            let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
            if fd >= 0 {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { held[lockURL.path] = fd } else { close(fd) }
            }
        }
        quitMarkPath = cPath(quit)
        backgroundMarkPath = cPath(background)
        if inBackground { touchMark(backgroundMarkPath) }
    }

    /// The stage is ending in this process: the marks are no longer written (the sentinel and the marks are removed
    /// next, then `end`).
    func disarm() {
        lock.lock()
        defer { lock.unlock() }
        quitMarkPath = nil
        backgroundMarkPath = nil
    }

    /// The stage ended in this process: the lock is released and its file removed. Called after the sentinel is gone,
    /// so no other process ever finds a sentinel of a stage under way without its lock.
    func end(lock lockURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        if let fd = held.removeValue(forKey: lockURL.path) {
            try? FileManager.default.removeItem(at: lockURL)
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
        }
    }

    /// Whether a process holds the lock at `url` now (a stage under way). A lock file that is not there is not held.
    static func isHeld(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    private func setBackground(_ b: Bool) {
        lock.lock()
        defer { lock.unlock() }
        inBackground = b
        if b {
            touchMark(backgroundMarkPath)
        } else if let p = backgroundMarkPath {
            unlink(p)
        }
    }

    private func hookOnce() {
        guard !hooked else { return }
        hooked = true
        let nc = NotificationCenter.default
        for n in Self.backgroundNames {
            observers.append(nc.addObserver(forName: Notification.Name(n), object: nil, queue: nil) { [weak self] _ in self?.setBackground(true) })
        }
        for n in Self.foregroundNames {
            observers.append(nc.addObserver(forName: Notification.Name(n), object: nil, queue: nil) { [weak self] _ in self?.setBackground(false) })
        }
        observers.append(nc.addObserver(forName: Notification.Name(Self.terminateName), object: nil, queue: nil) { _ in markQuit() })
        atexit { markQuit() }
        #if os(macOS)
        // a command-line tool stopped with Ctrl-C or `kill`: the mark, then the signal's own action
        for sig in [SIGINT, SIGTERM] { Self.markOnSignal(sig) }
        #endif
    }

    #if os(macOS)
    /// Writes the quit mark on `sig` when the app left that signal to the system, then ends the process as the system
    /// would have. A handler the app set is never replaced.
    private static func markOnSignal(_ sig: Int32) {
        var old = sigaction()
        guard sigaction(sig, nil, &old) == 0, old.__sigaction_u.__sa_handler == nil, old.sa_flags & SA_SIGINFO == 0 else { return }
        var act = sigaction()
        act.__sigaction_u.__sa_handler = { s in
            markQuit()
            _ = signal(s, SIG_DFL)
            _ = raise(s)
        }
        act.sa_mask = 0
        act.sa_flags = 0
        _ = sigaction(sig, &act, nil)
    }
    #endif
}
