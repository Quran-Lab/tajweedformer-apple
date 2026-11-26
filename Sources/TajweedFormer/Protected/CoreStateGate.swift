import Foundation

/// The Core's saved state (18.4.7, spec fix 10): the sealed blob it hands the SDK to keep, the device-bound key that
/// wraps its state secret, and a monotonic counter, so an older state handed back is seen.
protocol CoreStateKeeping: Sendable {
    func load() -> Data?
    func save(_ blob: Data)
    /// AES-256-GCM under a key of this device's Keychain that is not the install key: nonce, ciphertext, tag.
    func seal(_ secret: Data) -> Data?
    func open(_ sealed: Data) -> Data?
    func counter() -> UInt64
    func raise(_ v: UInt64) -> Bool
    /// Whether the device-bound key can be made or read now. When it cannot (a process the Keychain refuses), the SDK
    /// gives the Core no seal and no counter, and the Core seals its state under its release key (qlcore.h): the state
    /// then opens only in the release that saved it, but the lease survives a restart, offline included.
    var sealAvailable: Bool { get }
}

extension CoreStateKeeping {
    var sealAvailable: Bool { true }
}

/// SDK 4.0.5 (ATTEST_40.md 40.2 item 10): one Core's saves of the folder's state, which an upgrade holds back or ends.
/// Every Core the runtime makes saves through a gate of its own.
///
/// Why (Core c3, state.c): the saved state holds one install key's lease; a Core takes the platform's counter when it is
/// made, saves its state with its own counter plus 1 and then raises the platform's counter to it, and a state whose
/// counter is below the platform's loads as an older one (its lease dropped, signal 64). So while an upgrade's Core
/// (over the next key) asks the full lease, the Core in force must not save: two of its saves (a tick, a status read)
/// would leave the new Core's state older than the counter, and a restart would lose the full lease. And once the switch
/// is made, the old Core (a model or another Client may still hold it) must never save again: its state would replace
/// the new key's lease.
///
/// - Open: every save and raise goes through.
/// - Held (`hold`, or made held): the last state and the highest raise are kept back, in memory; the counter read is
///   the higher of the platform's and the one kept back. `commit` writes them (the state, then the counter, as the Core
///   does) and opens the gate. Holds nest: the last `commit` of a hold writes.
/// - Silenced (`silence`): nothing is written again; what was held is dropped.
///
/// A process that ends while a gate holds leaves the state and counter as they were before the hold: they agree, and
/// the state loads with its lease.
final class CoreStateGate: CoreStateKeeping, @unchecked Sendable {
    let inner: any CoreStateKeeping
    private let lock = NSLock()
    private var holds: Int
    private var silenced = false
    private var blob: Data?
    private var raised: UInt64?

    init(_ inner: any CoreStateKeeping, held: Bool = false) {
        self.inner = inner
        holds = held ? 1 : 0
    }

    func load() -> Data? { inner.load() }
    func seal(_ secret: Data) -> Data? { inner.seal(secret) }
    func open(_ sealed: Data) -> Data? { inner.open(sealed) }
    var sealAvailable: Bool { inner.sealAvailable }

    func save(_ b: Data) {
        lock.lock()
        defer { lock.unlock() }
        if silenced { return }
        if holds > 0 {
            blob = b
            return
        }
        inner.save(b)
    }

    func counter() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let c = inner.counter()
        return holds > 0 ? max(c, raised ?? 0) : c
    }

    func raise(_ v: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if silenced { return true }
        if holds > 0 {
            raised = max(raised ?? v, v)
            return true
        }
        return inner.raise(v)
    }

    /// Whether saves are held back now.
    var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return holds > 0 && !silenced }
    /// Whether this gate writes nothing again.
    var isSilenced: Bool { lock.lock(); defer { lock.unlock() }; return silenced }

    /// Saves from now on are held back until the matching `commit`.
    func hold() {
        lock.lock()
        defer { lock.unlock() }
        if !silenced { holds += 1 }
    }

    /// Ends one hold; the last one writes what was held back (the state, then the counter raised after it, the Core's
    /// order) and opens the gate. Nothing on a gate that is open or silenced.
    func commit() {
        lock.lock()
        defer { lock.unlock() }
        guard !silenced, holds > 0 else { return }
        holds -= 1
        guard holds == 0 else { return }
        if let b = blob { inner.save(b) }
        if let v = raised { _ = inner.raise(v) }
        blob = nil
        raised = nil
    }

    /// Nothing is written again, and what was held back is dropped.
    func silence() {
        lock.lock()
        defer { lock.unlock() }
        silenced = true
        holds = 0
        blob = nil
        raised = nil
    }
}
