import Foundation
import Network

/// The device's connection, as `diagnose()` reports it (SDK 3.0.0; the same four values in the four SDKs). SDK 4.0.2
/// (section 33): a report only; no request of the SDK waits on it, and nothing else reads it.
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

/// SDK 4.0.5: the device's network path, watched once
/// per process. A wait inside a call is until the network is back when it is down (else the timer), and the network
/// coming back is a try of an owed attestation and of a lease renewal that is due. Any usable network: nothing here
/// reads whether the network is metered (section 33).
final class NetworkWatch: @unchecked Sendable {
    static let shared = NetworkWatch()

    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    /// nil until the system said.
    private var up: Bool?
    private var waiters: [UUID: @Sendable () -> Void] = [:]
    private final class Observer { weak var owner: AnyObject?; let tell: @Sendable () -> Void
        init(_ owner: AnyObject, _ tell: @escaping @Sendable () -> Void) { self.owner = owner; self.tell = tell }
    }
    private var observers: [Observer] = []

    /// Tests only: the path's state in place of the system's (nil: the system's).
    static let override = Locked<Bool?>(nil)

    /// Starts the watch (once).
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in self?.update(path.status == .satisfied) }
        m.start(queue: DispatchQueue(label: "ai.quranlab.network-watch", qos: .utility))
        monitor = m
    }

    /// The system says there is no usable network now.
    var isDown: Bool {
        if let o = Self.override.withLock({ $0 }) { return !o }
        lock.lock()
        defer { lock.unlock() }
        return up == false
    }

    /// The path changed: waiters go on when it is up, and observers are told when it came up from down.
    func update(_ satisfied: Bool) {
        lock.lock()
        let was = up
        up = satisfied
        let wake = satisfied ? Array(waiters.values) : []
        if satisfied { waiters = [:] }
        observers.removeAll { $0.owner == nil }
        let tell = satisfied && was == false ? observers.map(\.tell) : []
        lock.unlock()
        wake.forEach { $0() }
        tell.forEach { $0() }
    }

    /// `tell` each time the network comes back, while `owner` lives.
    func observe(_ owner: AnyObject, _ tell: @escaping @Sendable () -> Void) {
        start()
        lock.lock()
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner, tell))
        lock.unlock()
    }

    /// 40.2 item 3: `seconds` of waiting, or, when the network is down, until it is back; never longer than `upTo`.
    func pause(_ seconds: Double, upTo: Double) async {
        start()
        let limit = max(0, upTo)
        guard isDown else {
            try? await Task.sleep(nanoseconds: UInt64(min(max(0, seconds), limit) * 1_000_000_000))
            return
        }
        let id = UUID()
        let once = Locked(false)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resume: @Sendable () -> Void = {
                if once.withLock({ (d: inout Bool) -> Bool in defer { d = true }; return !d }) { c.resume() }
            }
            lock.lock()
            waiters[id] = resume
            lock.unlock()
            Task {
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                self.forget(id)
                resume()
            }
        }
    }

    /// The waiter of `pause` whose time ran out leaves the list. A synchronous call: Swift 6 refuses `NSLock.lock()`
    /// inside the async task itself.
    private func forget(_ id: UUID) {
        lock.lock()
        waiters[id] = nil
        lock.unlock()
    }
}
