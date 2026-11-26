import Foundation
import XCTest

@testable import TajweedFormer

/// SDK 4.0.5 (ATTEST_40.md 40.2 item 10): the gate on one Core's saves (`CoreStateGate`). Pure: runs on Linux
/// (scripts/linux_logic_tests.sh). `Saved` stands for the folder's state and counter; `ToyCore` follows Core c3's rules
/// for them (state.c): it takes the platform's counter when made, saves with its own plus 1 and then raises the
/// platform's to it, and a state whose counter is below the platform's loads as an older one (no lease).
final class CoreStateGateTests: XCTestCase {
    final class Saved: CoreStateKeeping, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var blob: Data?
        private(set) var count: UInt64 = 0
        private(set) var writes = 0
        func load() -> Data? { lock.lock(); defer { lock.unlock() }; return blob }
        func save(_ b: Data) { lock.lock(); blob = b; writes += 1; lock.unlock() }
        func seal(_ s: Data) -> Data? { s }
        func open(_ s: Data) -> Data? { s }
        func counter() -> UInt64 { lock.lock(); defer { lock.unlock() }; return count }
        func raise(_ v: UInt64) -> Bool { lock.lock(); count = max(count, v); lock.unlock(); return true }
    }

    /// Core c3's counter rules over one install key's lease: the state is "<key> <counter>".
    final class ToyCore {
        let key: String
        let state: any CoreStateKeeping
        private var counter: UInt64
        init(key: String, state: any CoreStateKeeping) {
            self.key = key
            self.state = state
            counter = state.counter()
            if let r = Self.read(state.load()), r.1 > counter { counter = r.1 }
        }

        /// A tick, an accept, a model open: each saves.
        func save() {
            counter += 1
            state.save(Data("\(key) \(counter)".utf8))
            _ = state.raise(counter)
        }

        static func read(_ blob: Data?) -> (String, UInt64)? {
            guard let blob, let t = String(data: blob, encoding: .utf8) else { return nil }
            let p = t.split(separator: " ")
            guard p.count == 2, let c = UInt64(p[1]) else { return nil }
            return (String(p[0]), c)
        }

        /// The key whose lease a restart over `key` finds: nil when the state is another key's or older than the counter.
        static func leaseAfterRestart(_ saved: Saved, key: String) -> String? {
            guard let r = read(saved.load()), r.0 == key, r.1 >= saved.counter() else { return nil }
            return r.0
        }
    }

    func testOpenGatePassesEverythingThrough() {
        let saved = Saved()
        let gate = CoreStateGate(saved)
        gate.save(Data("a".utf8))
        XCTAssertTrue(gate.raise(3))
        XCTAssertEqual(saved.blob, Data("a".utf8))
        XCTAssertEqual(saved.counter(), 3)
        XCTAssertFalse(gate.isHeld)
    }

    func testAHeldGateWritesNothingUntilCommitThenTheLastStateAndTheHighestCounter() {
        let saved = Saved()
        let gate = CoreStateGate(saved, held: true)
        gate.save(Data("one".utf8))
        _ = gate.raise(5)
        gate.save(Data("two".utf8))
        _ = gate.raise(4)
        XCTAssertNil(saved.blob, "nothing written while held")
        XCTAssertEqual(saved.counter(), 0)
        XCTAssertEqual(gate.counter(), 5, "the counter read is the higher of the platform's and the one held back")
        gate.commit()
        XCTAssertEqual(saved.blob, Data("two".utf8))
        XCTAssertEqual(saved.counter(), 5)
        XCTAssertEqual(saved.writes, 1)
        gate.save(Data("three".utf8))
        XCTAssertEqual(saved.blob, Data("three".utf8), "open after the commit")
    }

    func testHoldsNestAndTheLastCommitWrites() {
        let saved = Saved()
        let gate = CoreStateGate(saved)
        gate.hold()
        gate.hold()
        gate.save(Data("x".utf8))
        gate.commit()
        XCTAssertNil(saved.blob, "one hold still on")
        gate.commit()
        XCTAssertEqual(saved.blob, Data("x".utf8))
        gate.commit()
        XCTAssertEqual(saved.writes, 1, "a commit on an open gate writes nothing")
    }

    func testASilencedGateNeverWritesAgainAndDropsWhatItHeld() {
        let saved = Saved()
        let gate = CoreStateGate(saved)
        gate.hold()
        gate.save(Data("held".utf8))
        _ = gate.raise(9)
        gate.silence()
        gate.commit()
        gate.save(Data("later".utf8))
        XCTAssertTrue(gate.raise(10))
        gate.hold()
        XCTAssertNil(saved.blob)
        XCTAssertEqual(saved.counter(), 0)
        XCTAssertTrue(gate.isSilenced)
        XCTAssertFalse(gate.isHeld)
    }

    /// The upgrade as `ProtectedRuntime.upgradeLease` runs it: the Core in force (capped, key A) held, the try's Core
    /// (key B) made after that and held, the old Core saving twice during the request (a tick, a status read); then the
    /// switch: B's saves written, A silenced, A saving again. A restart over B finds B's full lease.
    func testTheSwitchLeavesTheNewKeysLeaseLoadable() {
        let saved = Saved()
        let a = ToyCore(key: "A", state: CoreStateGate(saved))
        a.save()
        let aGate = a.state as! CoreStateGate
        aGate.hold()
        let b = ToyCore(key: "B", state: CoreStateGate(saved, held: true))
        a.save()
        a.save()
        b.save()
        XCTAssertEqual(ToyCore.leaseAfterRestart(saved, key: "A"), "A", "a kill during the try: the capped lease loads")
        (b.state as! CoreStateGate).commit()
        aGate.silence()
        aGate.commit()
        a.save()
        XCTAssertEqual(ToyCore.leaseAfterRestart(saved, key: "B"), "B", "the full lease loads after a restart")
    }

    /// Without the gate on the Core in force (cc6dcc0's Android and 308e25f's Swift): the same two saves raise the counter
    /// past the try's Core, and a restart over B finds an older state: no lease.
    func testWithoutHoldingTheOldCoreTheNewStateLoadsAsOlder() {
        let saved = Saved()
        let a = ToyCore(key: "A", state: saved)
        a.save()
        let bGate = CoreStateGate(saved, held: true)
        let b = ToyCore(key: "B", state: bGate)
        a.save()
        a.save()
        b.save()
        bGate.commit()
        XCTAssertNil(ToyCore.leaseAfterRestart(saved, key: "B"), "older than the counter: the lease part is dropped")
    }

    /// A try that ends without a switch: the try's Core goes unsaved, and the Core in force writes what it held back.
    func testATryWithoutASwitchWritesTheOldCoresHeldSaves() {
        let saved = Saved()
        let a = ToyCore(key: "A", state: CoreStateGate(saved))
        a.save()
        let aGate = a.state as! CoreStateGate
        aGate.hold()
        let b = ToyCore(key: "B", state: CoreStateGate(saved, held: true))
        a.save()
        b.save()
        XCTAssertEqual(saved.counter(), 1)
        aGate.commit()
        XCTAssertEqual(saved.counter(), 2)
        XCTAssertEqual(ToyCore.leaseAfterRestart(saved, key: "A"), "A")
        a.save()
        XCTAssertEqual(ToyCore.leaseAfterRestart(saved, key: "A"), "A", "open again after the try")
    }
}
