import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5 (spec fix 17, 11-25): the boot id handed to the Core stays the last launch's while the boot clock has not
/// gone back (`StickyBootID`). iOS 18 refuses `kern.bootsessionuuid`, the derived id then follows `kern.boottime`'s
/// seconds, which move without a reboot, and Core c3 added the whole uptime at each change.
final class StickyBootIDTests: XCTestCase {
    private let a = [UInt8](repeating: 0xA1, count: 32), b = [UInt8](repeating: 0xB2, count: 32)

    func testFirstLaunchDerivesAndStores() {
        var derived = 0
        let c = StickyBootID.choose(stored: nil, nowMs: 5_000) { derived += 1; return a }
        XCTAssertEqual(c.id, a)
        XCTAssertEqual(derived, 1)
        XCTAssertEqual(c.store, .init(id: Data(a).base64URL, ms: 5_000))
    }

    func testSameBootKeepsTheStoredIdWhateverTheDerivedOneSays() {
        // kern.boottime moved (the derived id would change), the boot clock went on: the stored id, the new reading stored
        let stored = StickyBootID.Stored(id: Data(a).base64URL, ms: 864_000_000)
        var derived = 0
        let c = StickyBootID.choose(stored: stored, nowMs: 864_000_000 + 7_200_000) { derived += 1; return b }
        XCTAssertEqual(c.id, a)
        XCTAssertEqual(derived, 0)
        XCTAssertEqual(c.store.ms, 864_000_000 + 7_200_000)
        XCTAssertEqual(StickyBootID.choose(stored: stored, nowMs: 864_000_000) { b }.id, a, "the same reading: the same boot")
    }

    func testABootClockThatWentBackIsANewBoot() {
        let stored = StickyBootID.Stored(id: Data(a).base64URL, ms: 864_000_000)
        let c = StickyBootID.choose(stored: stored, nowMs: 60_000) { b }
        XCTAssertEqual(c.id, b)
        XCTAssertEqual(c.store, .init(id: Data(b).base64URL, ms: 60_000))
    }

    func testAStoredPairThatIsNotOneIsDerivedAgain() {
        for bad in ["", "not base64url!", Data(repeating: 1, count: 31).base64URL] {
            XCTAssertEqual(StickyBootID.choose(stored: .init(id: bad, ms: 1), nowMs: 2) { b }.id, b, bad)
        }
    }

    func testOncePerProcessAndKeptInTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sticky-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cloud/boot-id.json")
        StickyBootID.reset()
        XCTAssertEqual(StickyBootID.process(file: file, nowMs: 10_000) { a }, a)
        // later in the same process the derived id changed (kern.boottime moved): the process keeps its id
        XCTAssertEqual(StickyBootID.process(file: file, nowMs: 20_000) { b }, a)
        let kept = try JSONDecoder().decode(StickyBootID.Stored.self, from: Data(contentsOf: file))
        XCTAssertEqual(kept, .init(id: Data(a).base64URL, ms: 10_000))
        // the next launch on the same boot: the stored id, whatever the derived one says
        StickyBootID.reset()
        XCTAssertEqual(StickyBootID.process(file: file, nowMs: 30_000) { b }, a)
        // the next launch after a reboot (the boot clock below the stored reading): derived again
        StickyBootID.reset()
        XCTAssertEqual(StickyBootID.process(file: file, nowMs: 5_000) { b }, b)
        StickyBootID.reset()
    }

    func testSystemClocksHandTheStickyId() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sticky-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        StickyBootID.reset()
        let clocks = SystemClocks(bootIDFile: dir.appendingPathComponent("cloud/boot-id.json"))
        let first = clocks.boot(), second = clocks.boot()
        XCTAssertEqual(first.id, SystemClocks.bootID, "a first launch: the derived id")
        XCTAssertEqual(second.id, first.id)
        XCTAssertGreaterThanOrEqual(second.ms, first.ms)
        XCTAssertEqual(SystemClocks().boot().id, SystemClocks.bootID, "no file: the derived id (tests)")
        StickyBootID.reset()
    }
}

/// Spec fix 17 (18.4.7.3): a lease answer's signed server time is read and handed to a Core that has `qlc_lease_time`
/// (CoreHost.leaseTime) before the accept; the pinned Core c3 has none, and nothing is called.
final class LeaseAnswerTimeTests: XCTestCase {
    private func answer(_ extra: [String: Any]) throws -> LeaseAnswer? {
        var o: [String: Any] = ["v": 1, "lease": Data(repeating: 7, count: 100).base64URL, "iat": 1_790_000_000,
                                "exp": 1_790_604_800, "refresh_after": 1_790_080_000,
                                "base": "https://cdn.quranlab.ai/models/o/r/b/sdk/v4.0/"]
        for (k, v) in extra { o[k] = v }
        return LeaseAnswer.parse(try JSONSerialization.data(withJSONObject: o))
    }

    func testTheTimeIsRead() throws {
        XCTAssertEqual(try answer(["time": "dGV4dA.c2ln"])?.time, "dGV4dA.c2ln")
        XCTAssertNil(try answer([:])?.time, "a server before spec fix 17 sends none")
        XCTAssertNil(try answer(["time": 5])?.time, "not a string: none")
        XCTAssertNotNil(try answer(["time": 5]), "the answer is still a lease answer")
    }
}
