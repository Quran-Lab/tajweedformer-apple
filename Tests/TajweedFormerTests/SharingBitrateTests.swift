import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 2.0.1's adaptive Opus bitrate: the shared ladder vector, a real stream whose segments change bitrate (one valid
/// Ogg Opus stream, every check of the shared spec), recovery keeping a segment's bitrate, and the outbox's uploads
/// driving the bitrate of the next segment of a running capture.
final class SharingBitrateTests: XCTestCase {
    override func tearDown() {
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    static func vector(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: try SharingVectorTests.vectors().appendingPathComponent(name))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tf-br-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: the shared vector

    /// bitrate_ladder.json: every case from a fresh ladder, every step's expected bitrate.
    func testTheSharedLadderVector() throws {
        let v = try Self.vector("bitrate_ladder.json")
        XCTAssertEqual(v["rungs"] as? [Int], BitrateLadder.rungs)
        XCTAssertEqual(v["start"] as? Int, BitrateLadder.rungs[0])
        XCTAssertEqual(BitrateLadder().bitrate, 192_000, "a process starts at the top")
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 9)
        var steps = 0
        for c in cases {
            let name = (c["name"] as? String) ?? "?"
            let ladder = BitrateLadder()
            let list = try XCTUnwrap(c["steps"] as? [[String: Any]], name)
            for (i, s) in list.enumerated() {
                let backlog: Double = (s["backlog_s"] as? NSNumber)?.doubleValue ?? 0
                switch s["event"] as? String {
                case "upload_failed": ladder.uploadFailed()
                case "upload_ok": ladder.uploadOk(backlogSeconds: backlog)
                case "segment_closed": ladder.segmentClosed(backlogSeconds: backlog)
                default: XCTFail("\(name): unknown event \(String(describing: s["event"]))")
                }
                XCTAssertEqual(ladder.bitrate, s["expect"] as? Int, "\(name), step \(i + 1)")
                steps += 1
            }
        }
        print("bitrate ladder vector: \(cases.count) cases, \(steps) steps replayed")
    }

    // MARK: a real stream

    struct Measured {
        let n: Int
        let bitrate: Int
        let bytes: Int
        let seconds: Double
        var kbps: Double { Double(bytes) * 8 / seconds / 1000 }
    }

    /// The serial number of every page (the page parser of SharingTests checks capture patterns and CRCs).
    static func serials(_ d: Data) -> [UInt32] {
        let b = [UInt8](d)
        var at = 0
        var out: [UInt32] = []
        while at + 27 <= b.count {
            let serial: UInt32 = (0..<4).reduce(UInt32(0)) { (v: UInt32, i: Int) -> UInt32 in v | UInt32(b[at + 14 + i]) << (8 * UInt32(i)) }
            out.append(serial)
            let n = Int(b[at + 26])
            var len = 27 + n
            for i in 0..<n { len += Int(b[at + 27 + i]) }
            at += len
        }
        return out
    }

    /// The self-test clips (real recitation, 16 kHz) repeated to 160 s, through the sharing writer with the segment
    /// plan, each segment at another rung (192, 96, 32, 64, 192 kbit/s): one Ogg stream with continuous pages and
    /// granules, headers once, the end once, decoding to exactly the input, and each segment's bytes following its rung.
    func testAStreamWithBitrateChangesIsOneValidOggOpusStream() throws {
        let clips = try SelfTestClips.load().clips
        var one: [Float] = []
        for c in clips { one += c.samples }
        let rate = 16_000.0
        var input: [Float] = []
        while Double(input.count) < 160 * rate { input += one }
        let rungs = [192_000, 96_000, 32_000, 64_000, 192_000]
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var closed: [OggSegment] = []
        let w = try OggOpusWriter(segmentURL: { (n: Int) -> URL in dir.appendingPathComponent(ShareFiles.name(n)).appendingPathExtension("opus") },
                                  plan: SegmentPlan.seconds, inputRate: rate) { (s: OggSegment) in
            try? ShareFiles.mark(dir, n: s.n, granule: s.granule, bitrate: s.bitrate)
            closed.append(s)
        }
        var opened: [Int] = []
        w.bitrateForSegment = { (n: Int) -> Int in rungs[min(n, rungs.count) - 1] }
        w.onSegmentOpen = { (n: Int, _: Int) in opened.append(n) }
        let preSkip = w.preSkip
        var at = 0
        while at < input.count {
            let k = min(1_600, input.count - at)   // 100 ms pieces, as a microphone delivers them
            try w.append(Array(input[at..<(at + k)]))
            at += k
        }
        _ = try w.finish()

        XCTAssertEqual(closed.map(\.n), [1, 2, 3, 4, 5], "10, 20, 40, 60 s and the rest")
        XCTAssertEqual(opened, [1, 2, 3, 4, 5])
        XCTAssertEqual(closed.map(\.bitrate), rungs, "each segment closes with the bitrate it opened with")
        XCTAssertEqual(ShareFiles.markers(dir).map { (m: ShareFiles.Marker) -> Int in m.bitrate ?? 0 }, rungs, "each marker has its bitrate")

        let parts: [Data] = try closed.map { (s: OggSegment) -> Data in try Data(contentsOf: s.url) }
        let whole = parts.reduce(Data(), +)
        let pages = try SharingTests.pages(whole)   // capture patterns and every CRC
        XCTAssertEqual(pages.map(\.sequence), (0..<UInt32(pages.count)).map { $0 }, "page sequence continuous from 0")
        XCTAssertEqual(Set(Self.serials(whole)).count, 1, "one serial")
        XCTAssertEqual(Self.serials(whole).count, pages.count)
        XCTAssertEqual(pages.indices.filter { pages[$0].flags & 0x02 != 0 }, [0], "BOS only on page 0")
        XCTAssertEqual(pages.indices.filter { pages[$0].flags & 0x04 != 0 }, [pages.count - 1], "EOS only on the last page")
        let head = Data("OpusHead".utf8), tags = Data("OpusTags".utf8)
        XCTAssertEqual(pages.indices.filter { i in pages[i].packets.contains { $0.starts(with: head) } }, [0], "OpusHead only on page 0")
        XCTAssertEqual(pages.indices.filter { i in pages[i].packets.contains { $0.starts(with: tags) } }, [1], "OpusTags only on page 1")
        XCTAssertEqual(pages[0].packets.count, 1)
        XCTAssertEqual(pages[1].packets.count, 1)
        var packets = 0
        for (i, p) in pages.enumerated().dropFirst(2) {
            packets += p.packets.count
            if i < pages.count - 1 { XCTAssertEqual(p.granule, Int64(960 * packets), "granule of page \(i)") }
        }
        let samples48 = input.count * 3
        let finalGranule = Int64(preSkip + samples48)
        XCTAssertEqual(pages.last?.granule, finalGranule, "the last granule is the encoder's final position")
        XCTAssertGreaterThanOrEqual(Int64(960 * packets), finalGranule)
        let decoded = try OpusTestDecoder.decode(whole).count
        XCTAssertEqual(decoded, samples48, "libopus decodes exactly the input length")

        // bytes per second of each segment follow its rung
        var measured: [Measured] = []
        var previous: Int64 = 0
        for (s, data) in zip(closed, parts) {
            measured.append(Measured(n: s.n, bitrate: s.bitrate, bytes: data.count, seconds: Double(s.granule - previous) / 48_000))
            previous = s.granule
        }
        for m in measured {
            print(String(format: "opus bitrate stream: segment %d at %d kbit/s: %d bytes, %.2f s, %.1f kbit/s measured", m.n, m.bitrate / 1000,
                         m.bytes, m.seconds, m.kbps))
        }
        print("opus bitrate stream: \(pages.count) pages, \(packets) audio packets, \(input.count) input samples at 16 kHz, "
              + "\(decoded) decoded at 48 kHz, last granule \(pages.last?.granule ?? -1) (pre-skip \(preSkip)), \(whole.count) bytes")
        func kbps(_ rung: Int) -> [Double] { measured.filter { $0.bitrate == rung }.map(\.kbps) }
        let top = try XCTUnwrap(kbps(192_000).min())
        XCTAssertLessThan(try XCTUnwrap(kbps(32_000).first), try XCTUnwrap(kbps(64_000).first))
        XCTAssertLessThan(try XCTUnwrap(kbps(64_000).first), try XCTUnwrap(kbps(96_000).first))
        XCTAssertLessThan(try XCTUnwrap(kbps(96_000).first), top)
        XCTAssertLessThan(try XCTUnwrap(kbps(32_000).first), 0.5 * top, "a 32k segment is clearly smaller than a 192k one")
        XCTAssertLessThan(try XCTUnwrap(kbps(32_000).first), 64, "VBR overshoots a little on speech, never to the next rung")

        // independent decoders, where ffmpeg is installed
        let file = dir.appendingPathComponent("whole.opus")
        try whole.write(to: file)
        let seconds = Double(input.count) / rate
        if let probe = Self.tool("ffprobe") {
            let out = try Self.runTool(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", file.path])
            let d = try XCTUnwrap(Double(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            print(String(format: "opus bitrate stream: ffprobe duration %.6f s, input %.6f s, difference %.1f ms", d, seconds, abs(d - seconds) * 1000))
            XCTAssertEqual(d, seconds, accuracy: 0.020, "ffprobe duration within 20 ms")
        } else {
            print("opus bitrate stream: ffprobe is not installed here (the libopus decode above carries the check)")
        }
        if let ffmpeg = Self.tool("ffmpeg") {
            for decoder in ["opus", "libopus"] {
                guard let pcm = try? Self.runTool(ffmpeg, ["-v", "error", "-c:a", decoder, "-i", file.path, "-f", "f32le", "-ac", "1", "-"]) else {
                    print("opus bitrate stream: ffmpeg has no \(decoder) decoder")
                    continue
                }
                print("opus bitrate stream: ffmpeg \(decoder) decoder: \(pcm.count / 4) samples, input \(samples48)")
                XCTAssertEqual(pcm.count / 4, samples48, "ffmpeg's \(decoder) decoder gives exactly the input sample count")
            }
        } else {
            print("opus bitrate stream: ffmpeg is not installed here")
        }
    }

    /// An executable named `name` on PATH or in Homebrew's folders.
    static func tool(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        for d in dirs {
            let u = URL(fileURLWithPath: d).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        return nil
    }

    /// Runs a tool; its standard output, or a throw when it fails.
    static func runTool(_ tool: URL, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    // MARK: recovery

    /// A capture killed in its second segment: recovery closes that segment with the bitrate it opened with (from the
    /// capture file), not the first segment's.
    func testRecoveryKeepsTheBitrateOfTheSegmentItCloses() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = try OggOpusWriter(segmentURL: { (n: Int) -> URL in dir.appendingPathComponent(ShareFiles.name(n)).appendingPathExtension("opus") },
                                  plan: [1, 2], inputRate: 48_000) { (s: OggSegment) in
            try? ShareFiles.mark(dir, n: s.n, granule: s.granule, bitrate: s.bitrate)
        }
        let preSkip = w.preSkip
        var bitrates: [Int] = []
        w.bitrateForSegment = { (n: Int) -> Int in n == 1 ? 192_000 : 64_000 }
        w.onSegmentOpen = { (_: Int, bps: Int) in
            bitrates.append(bps)
            try? ShareFiles.write(ShareFiles.Capture(preSkip: preSkip, bitrates: bitrates), dir.appendingPathComponent(ShareFiles.capture))
        }
        try w.append(SharingCodecTests.noise(48_000 * 5 / 2))
        w.abandon()
        XCTAssertEqual(ShareFiles.markers(dir).map(\.n), [1], "segment 2 was open when the app died")
        XCTAssertTrue(ShareFiles.recover(dir))
        XCTAssertEqual(ShareFiles.markers(dir).map { (m: ShareFiles.Marker) -> Int in m.bitrate ?? 0 }, [192_000, 64_000])
    }

    // MARK: the outbox drives the capture

    func waitUntil(_ what: String, timeout: TimeInterval = 15, _ done: () async -> Bool) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if await done() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Through the real capture and outbox with the stub server: a PUT answered 503 lowers the bitrate of the next
    /// segment of the running session (192 -> 96 kbit/s); three PUTs that go through with little waiting raise it again
    /// for the segment after (96 -> 192). The session JSON does not change.
    func testUploadsDriveTheBitrateOfTheNextSegment() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        server.put.withLock { $0 = { n in n == 1 ? StubProtocol.Reply(status: 503, headers: [:]) : nil } }
        let storage = CloudFixtures.storage()
        let options = CloudFixtures.options(contributions: true, storage: storage)
        let cloud = CloudFixtures.cloud(storage: storage, options: options)
        _ = await cloud.refreshConfig()
        QuranLab.configure(key: CloudFixtures.key, options: options, cloud: cloud)
        Contributions.answer(share: true)
        let ladder = cloud.outbox.ladder
        XCTAssertEqual(ladder.bitrate, 192_000)
        let capture = try XCTUnwrap(Contributions.capture(revision: "test-rev", backend: .exact, weightsSHA256: nil))
        var fed = 0
        func feed(_ seconds: Double) throws {
            let n = Int(48_000 * seconds)
            var at = 0
            while at < n {
                let k = min(4_800, n - at)
                try capture.append(SharingTests.audio(k, seed: fed + at + 1), rate: 48_000)
                at += k
            }
            fed += n
        }
        func bitrates() -> [Int] { ShareFiles.markers(capture.folder).map { (m: ShareFiles.Marker) -> Int in m.bitrate ?? 0 } }

        try feed(10)   // segment 1 closes; segment 2 opens with the next packet
        XCTAssertEqual(bitrates(), [192_000])
        try await waitUntil("the failed PUT") { await cloud.outbox.item(capture.id)?.lastError?.contains("503") == true }
        XCTAssertEqual(ladder.bitrate, 96_000, "a 5xx on a segment PUT is a network failure: one rung down")

        try feed(20)   // segment 2 at the new rung
        XCTAssertEqual(bitrates(), [192_000, 96_000], "the failure lowered the next segment")

        await cloud.outbox.drain(ignoringBackoff: true)
        XCTAssertEqual(server.segments(capture.id).count, 2)
        XCTAssertEqual(ladder.bitrate, 96_000, "two successes: not yet")

        try feed(40)   // segment 3 still at 96k; its upload is the third success in a row
        XCTAssertEqual(bitrates(), [192_000, 96_000, 96_000])
        await cloud.outbox.drain(ignoringBackoff: true)
        try await waitUntil("segment 3 in R2") { server.segments(capture.id).count == 3 }
        XCTAssertEqual(ladder.bitrate, 192_000, "three successes with nothing waiting: one rung up")

        try feed(1)
        capture.finish(completed: true)
        XCTAssertEqual(bitrates(), [192_000, 96_000, 96_000, 192_000], "the success raised the next segment")
        await cloud.outbox.drain(ignoringBackoff: true)
        try await waitUntil("the session uploaded") { await cloud.outbox.item(capture.id)?.status == .uploaded }
        let uploaded = await cloud.outbox.item(capture.id)
        let item = try XCTUnwrap(uploaded)
        XCTAssertEqual(item.segmentBitrates, [192_000, 96_000, 96_000, 192_000], "the outbox item lists each segment's bitrate")
        let markers = ShareFiles.markers(capture.folder)
        var kbps: [Double] = []
        var from: Int64 = 0
        for m in markers {
            kbps.append(Double(m.bytes) * 8 / (Double(m.granule - from) / 48_000) / 1000)
            from = m.granule
        }
        print("bitrate wiring: segments \(item.segmentBitrates.map { $0 / 1000 }) kbit/s, measured \(kbps.map { Int($0.rounded()) }) kbit/s")
        XCTAssertLessThan(kbps[1], kbps[0], "the 96k segment is smaller per second than the 192k one")
        let start = try XCTUnwrap(SharingTests.starts.first?.json)
        XCTAssertNil(start["bitrate"], "the session JSON does not change for the bitrate")
        XCTAssertEqual(Set(start.keys), ["format", "audio", "decode", "consent_version", "contributor", "day", "device_class", "os_major",
                                         "contributor_key", "recovery_hash"])
    }
}
