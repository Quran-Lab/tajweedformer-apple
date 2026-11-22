import Foundation
import XCTest
@testable import TajweedFormer

/// Contract section 29 (`sdk_4.0.0/SHARE_WRITE_40.md`, SDK 4.0.2): a write of a shared recording that fails ends it at
/// once, as a crash would, and the 2.0.1 recovery closes it (`ShareCapture.abandon`): the closed segments and the open
/// one's whole pages stay when a segment had closed and sharing is on; nothing is kept otherwise. `share_write_40.json`
/// replayed through the process's recorder, the real capture, the outbox and the stub server of SharingTakesTests, with
/// the tests' full disk (`ShareFiles.refusesWrites`: every write of the recording fails, the recovery's own too). The
/// server answers nothing while the events run (so what goes up is what was kept when they are through), then the
/// uploader finishes. `take_ms` is not checked: Apple's takes return no shared milliseconds.
extension SharingTakesTests {
    func testTheShareWriteVector() async throws {
        let v = try V40.json("share_write_40.json")
        XCTAssertEqual(v["plan_s"] as? [Int], SegmentPlan.seconds, "the standard segment plan")
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 6)
        for c in cases { try await replayWrite(c) }
    }

    /// Audio into the take in 20 ms buffers (as the capture feeds it); the clock moves on by its length.
    private func feed20(_ take: Int, seconds: Double, rate: Double) throws {
        let x = noise(seconds, rate: rate)
        let piece = Int(rate / 50)
        var at = 0
        while at < x.count {
            let k = min(piece, x.count - at)
            try Contributions.recorder.audio(take, Array(x[at..<(at + k)]), rate: rate)
            at += k
        }
        advance(Int64(x.count) * 1000 / Int64(rate))
    }

    /// The audio of a kept stream, ms: the last granule (Opus: less the pre-skip, at 48 kHz; FLAC: at its rate).
    private func audioMs(_ pages: [SharingTests.Page], flac: Bool, rate: Int) -> Int {
        let g = pages.last?.granule ?? 0
        return flac ? Int(g * 1000 / Int64(rate)) : Int(max(0, g - 312) / 48)
    }

    private func replayWrite(_ c: [String: Any]) async throws {
        let name = try XCTUnwrap(c["name"] as? String)
        let flac = c["form"] as? String == "flac"
        let rate = try XCTUnwrap(c["rate"] as? Int)
        let flags = c["flags"] as? [String: Any] ?? [:]
        let expect = try XCTUnwrap(c["expect"] as? [String: Any])
        let server = SharingTests.Server(flags: flags.filter { $0.key != "share_join_ms" })
        if let w = flags["share_join_ms"] { server.joinWindow.withLock { $0 = w } }
        server.down.withLock { $0 = true }
        StubProtocol.reset(server.handler)
        var cloud = await configure(server)
        defer {
            ShareFiles.refusesWrites.withLock { $0 = false }
            Contributions.recorder.stop()
        }
        var take: Int?
        var ids: [String] = []
        for e in try XCTUnwrap(c["events"] as? [[String: Any]]) {
            switch e["event"] as? String {
            case "take_start":
                take = start()
            case "audio":
                try feed20(try XCTUnwrap(take), seconds: try XCTUnwrap((e["s"] as? NSNumber)?.doubleValue), rate: Double(rate))
                if let id = (Contributions.recorder.current as? ShareCapture)?.id, !ids.contains(id) { ids.append(id) }
            case "write_fails":
                ShareFiles.refusesWrites.withLock { $0 = true }
            case "disk_ok":
                ShareFiles.refusesWrites.withLock { $0 = false }
            case "take_end":
                end(try XCTUnwrap(take), completed: e["completed"] as? Bool ?? true)
            case "sharing_off":
                await Contributions.setSharing(false)
            case "relaunch":
                // the process ends with the files as they are; a new client on the same storage starts its uploads
                Contributions.recorder.stop()
                for id in ids { ShareCapture.active.withLock { _ = $0.remove(id) } }
                let storage = try await retire(cloud)
                StubProtocol.reset(server.handler)
                cloud = await configure(server, consent: false, storage: storage)
            default:
                XCTFail("\(name): an event this replay does not know: \(e)")
            }
        }
        ShareFiles.refusesWrites.withLock { $0 = false }
        server.down.withLock { $0 = false }
        let kept = try XCTUnwrap(expect["kept"] as? Bool)
        XCTAssertEqual(Set(ids).count, 1, "\(name): one recording")
        let id = try XCTUnwrap(ids.first, name)
        guard kept else {
            for _ in 0..<5 {
                await cloud.outbox.drain(ignoringBackoff: true)
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(server.segments(id), [], "\(name): nothing reaches the server")
            let left = await cloud.outbox.items
            XCTAssertEqual(left.map(\.id), [], "\(name): the outbox is empty")
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder(cloud, id).path), "\(name): nothing of the recording is on the device")
            return
        }
        let item = try await settle(cloud, id)
        XCTAssertEqual(item.completed, false, "\(name): the session is not completed")
        let segs = server.segments(id)
        let lo = try XCTUnwrap(expect["segments_min"] as? Int), hi = try XCTUnwrap(expect["segments_max"] as? Int)
        XCTAssertTrue((lo...hi).contains(segs.count), "\(name): \(segs.count) segments")
        let pages = try SharingTests.pages(segs.reduce(Data(), +))
        let ms = audioMs(pages, flac: flac, rate: rate)
        let msLo = try XCTUnwrap(expect["audio_ms_min"] as? Int), msHi = try XCTUnwrap(expect["audio_ms_max"] as? Int)
        XCTAssertTrue((msLo...msHi).contains(ms), "\(name): \(ms) ms of audio")
        XCTAssertFalse(pages.contains { $0.flags & 0x04 != 0 }, "\(name): no page ends the stream (eos false)")
        let wantTakes = expect["takes"] as? Int
        XCTAssertEqual(server.takes.withLock { $0[id] }?.count, wantTakes, "\(name): the take list")
    }
}
