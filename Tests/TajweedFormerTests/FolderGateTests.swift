import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5 (`FolderGate`): a call on the open model's folder no longer waits for another call on the same folder.
///
/// Production report (Apple 4.0.2, iPhone 15 Pro Max, iOS 27.2.1, 2026-11-24): SIGKILL, 0x8badf00d "failed to terminate
/// gracefully", 10.3 s into the compile stage of the accelerator's promotion. The crashing thread:
/// `__psynch_mutexwait` <- `CoreModel.reference(surah:ayah:)` <- `ModelReference.units(surah:ayah:)` <- the app. The
/// prepare (`CoreModel.accelPrepare`, the program's decryption and Core ML's compile) held the one lock every call on a
/// build folder took, for its whole length, and `reference.units()` on the main thread waited for it.
///
/// No Core here: the gate alone, with threads. A call that should not wait is given 2 s; one that should wait is
/// checked still waiting after 0.3 s.
final class FolderGateTests: XCTestCase {
    let a = URL(fileURLWithPath: "/tmp/qlab-gate/models/m/b1", isDirectory: true)
    let b = URL(fileURLWithPath: "/tmp/qlab-gate/models/m/b2", isDirectory: true)

    /// Runs `body` on a thread of its own; the semaphore is signalled when it has returned.
    func onThread(_ body: @escaping @Sendable () -> Void) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            body()
            done.signal()
        }
        return done
    }

    /// A long call on a folder (the prepare) and a short one on the same folder (the reference lookup): the short one
    /// runs at once, beside the long one. Until 4.0.4 it waited until the long one ended.
    func testACallOnTheSameFolderDoesNotWaitForALongOne() {
        let gate = FolderGate(), a = self.a
        let pins = Locked<[String?]>([])
        let pin: @Sendable (URL?) -> Void = { u in pins.withLock { $0.append(u?.lastPathComponent) } }
        let inside = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let long = onThread {
            gate.enterShared(a, pin: pin)
            inside.signal()
            release.wait()
            gate.leaveShared(pin: pin)
        }
        XCTAssertEqual(inside.wait(timeout: .now() + 2), .success)
        let short = onThread {
            gate.enterShared(a, pin: pin)
            gate.leaveShared(pin: pin)
        }
        XCTAssertEqual(short.wait(timeout: .now() + 2), .success, "the lookup runs while the prepare runs")
        release.signal()
        XCTAssertEqual(long.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(pins.withLock { $0 }, ["b1", nil], "pinned by the first in, unpinned by the last out")
    }

    /// A call on another folder waits until the folder is free, then pins its own.
    func testACallOnAnotherFolderWaits() {
        let gate = FolderGate(), a = self.a, b = self.b
        let pins = Locked<[String?]>([])
        let pin: @Sendable (URL?) -> Void = { u in pins.withLock { $0.append(u?.lastPathComponent) } }
        let inside = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let first = onThread {
            gate.enterShared(a, pin: pin)
            inside.signal()
            release.wait()
            gate.leaveShared(pin: pin)
        }
        XCTAssertEqual(inside.wait(timeout: .now() + 2), .success)
        let other = onThread {
            gate.enterShared(b, pin: pin)
            gate.leaveShared(pin: pin)
        }
        XCTAssertEqual(other.wait(timeout: .now() + 0.3), .timedOut, "another folder waits")
        release.signal()
        XCTAssertEqual(first.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(other.wait(timeout: .now() + 2), .success, "and runs once the folder is free")
        XCTAssertEqual(pins.withLock { $0 }, ["b1", nil, "b2", nil])
    }

    /// A call alone (an install, an open) waits for the shared calls, and the shared calls wait for it.
    func testACallAloneWaitsForTheSharedOnesAndTheyForIt() {
        let gate = FolderGate(), a = self.a
        let pin: @Sendable (URL?) -> Void = { _ in }
        let inside = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let shared = onThread {
            gate.enterShared(a, pin: pin)
            inside.signal()
            release.wait()
            gate.leaveShared(pin: pin)
        }
        XCTAssertEqual(inside.wait(timeout: .now() + 2), .success)
        let aloneIn = DispatchSemaphore(value: 0), aloneRelease = DispatchSemaphore(value: 0)
        let alone = onThread {
            gate.enterAlone()
            aloneIn.signal()
            aloneRelease.wait()
            gate.leaveAlone()
        }
        XCTAssertEqual(aloneIn.wait(timeout: .now() + 0.3), .timedOut, "the call alone waits for the shared one")
        release.signal()
        XCTAssertEqual(shared.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(aloneIn.wait(timeout: .now() + 2), .success)
        let late = onThread {
            gate.enterShared(a, pin: pin)
            gate.leaveShared(pin: pin)
        }
        XCTAssertEqual(late.wait(timeout: .now() + 0.3), .timedOut, "a shared call waits for the call alone")
        aloneRelease.signal()
        XCTAssertEqual(alone.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(late.wait(timeout: .now() + 2), .success)
    }

    /// The same folder named two ways (a trailing slash, a `.` component) is the same folder.
    func testTheSameFolderNamedTwoWaysIsShared() {
        let gate = FolderGate()
        let pin: @Sendable (URL?) -> Void = { _ in }
        gate.enterShared(URL(fileURLWithPath: "/tmp/qlab-gate/models/m/b1"), pin: pin)
        let other = onThread {
            gate.enterShared(URL(fileURLWithPath: "/tmp/qlab-gate/models/m/./b1/"), pin: pin)
            gate.leaveShared(pin: pin)
        }
        XCTAssertEqual(other.wait(timeout: .now() + 2), .success)
        gate.leaveShared(pin: pin)
    }
}
