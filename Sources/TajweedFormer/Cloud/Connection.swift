import Foundation
import Network

/// The device's connection, as `diagnose()` reports it and `prefetch(unmeteredOnly:)` follows it (SDK 3.0.0; the same
/// four values in the four SDKs).
enum ConnectionKind: String, Sendable, CaseIterable {
    /// Wi-Fi or Ethernet.
    case unmetered
    /// Cellular, a personal hotspot, or a network in Low Data Mode.
    case metered
    /// No usable network.
    case none
    /// The system gave no answer.
    case unknown

    /// How long the system has to say what the connection is before it counts as `unknown`, seconds.
    static let answerWithin = 2.0

    /// Whether `prefetch(unmeteredOnly: true)` downloads on this connection: on `unmetered`, and on `unknown`, where
    /// nothing says the connection is metered. It waits on `metered` and on `none`.
    var downloadsWhenUnmeteredOnly: Bool { self == .unmetered || self == .unknown }

    /// Tests only: the connection in place of the system's.
    static let override = Locked<(@Sendable () async -> ConnectionKind)?>(nil)

    /// The connection now, from the system's current network path.
    static func current() async -> ConnectionKind {
        if let fake = override.withLock({ $0 }) { return await fake() }
        return await withCheckedContinuation { (c: CheckedContinuation<ConnectionKind, Never>) in
            let monitor = NWPathMonitor()
            let once = Locked(false)
            let answer: @Sendable (ConnectionKind) -> Void = { kind in
                let first = once.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard first else { return }
                monitor.cancel()
                c.resume(returning: kind)
            }
            monitor.pathUpdateHandler = { path in
                if path.status != .satisfied {
                    answer(.none)
                } else if path.isExpensive || path.isConstrained {
                    answer(.metered)
                } else {
                    answer(.unmetered)
                }
            }
            let queue = DispatchQueue(label: "ai.quranlab.connection", qos: .utility)
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + answerWithin) { answer(.unknown) }
        }
    }
}
