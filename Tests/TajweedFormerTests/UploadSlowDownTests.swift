import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.2, contract 28.11 item 4 on uploads: three 429s in a row without a Retry-After on the uploads route give
/// waits of 300, 600 and 1200 seconds; a pass of the outbox inside the wait sends nothing (the recording's own backoff,
/// 30 s, has passed by then), and nothing is dropped. The row outlives a restart (28.11 item 3): a new Client on the
/// same storage, its outbox draining at launch inside the wait, sends nothing until the wait is over. Through the
/// recorder, the capture, the outbox and the stub server, on the client's clock (SharingTakesTests).
extension SharingTakesTests {
    func testUploadsWaitAfter429s() async throws {
        let server = SharingTests.Server()
        server.start.withLock { $0 = { (_: Int) -> StubProtocol.Reply? in .json(["error": "rate_limited"], status: 429) } }
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        let cloud = await configure(server, storage: storage)
        defer { Contributions.recorder.stop() }
        try take(noise(12))
        windowPasses()
        var waits: [TimeInterval] = []
        for n in 1...3 {
            try await waitUntil("upload start \(n)") { SharingTests.starts.count >= n && cloud.outbox.slowDown.row("uploads")?.count == n }
            let row = try XCTUnwrap(cloud.outbox.slowDown.row("uploads"))
            waits.append(row.wait)
            let until = Int64(try XCTUnwrap(row.until).timeIntervalSince1970 * 1000)
            // a second before the wait is over: a pass sends nothing
            Self.nowMs.withLock { $0 = until - 1000 }
            await cloud.outbox.drain()
            XCTAssertEqual(SharingTests.starts.count, n, "nothing goes up inside the wait")
            Self.nowMs.withLock { $0 = until + 1000 }
            await cloud.outbox.drain()
        }
        XCTAssertEqual(waits, [300, 600, 1200])
        let items = await cloud.outbox.items
        XCTAssertEqual(items.count, 1, "nothing is dropped")
        XCTAssertEqual(items.first?.status, .queued)
        // the fourth 429 (the pass after the third wait), then a restart inside its wait
        try await waitUntil("upload start 4") { SharingTests.starts.count >= 4 && cloud.outbox.slowDown.row("uploads")?.count == 4 }
        let row = try XCTUnwrap(cloud.outbox.slowDown.row("uploads"))
        XCTAssertEqual(row.wait, 2400)
        let until = Int64(try XCTUnwrap(row.until).timeIntervalSince1970 * 1000)
        Self.nowMs.withLock { $0 = until - 1000 }
        let again = await configure(server, storage: storage)
        XCTAssertEqual(again.outbox.slowDown.row("uploads"), row, "the new process reads the row back")
        await again.outbox.drain()
        XCTAssertEqual(SharingTests.starts.count, 4, "the new process sends nothing inside the wait")
        Self.nowMs.withLock { $0 = until + 1000 }
        await again.outbox.drain()
        try await waitUntil("upload start 5") { SharingTests.starts.count >= 5 && again.outbox.slowDown.row("uploads")?.count == 5 }
        XCTAssertEqual(again.outbox.slowDown.row("uploads")?.wait, 3600, "the row goes on, up to an hour")
        let kept = await again.outbox.items
        XCTAssertEqual(kept.count, 1, "nothing is dropped")
    }
}
