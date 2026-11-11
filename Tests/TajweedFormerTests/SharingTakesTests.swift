import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 2.0.3, takes in a row share one recording, through the real capture (libopus), the process's recorder as the
/// recognizer drives it, the outbox and the stub server (with the take list route as the server checks it). The
/// client's clock moves only when a test moves it, and the join window's timer never runs (a test asks for the
/// window's check after moving the clock), so nothing here waits for the window in wall time.
final class SharingTakesTests: XCTestCase {
    /// The client's clock (ms since 1970).
    static let nowMs = Locked<Int64>(0)

    private var seed: UInt64 = 500

    override func setUp() {
        Self.nowMs.withLock { $0 = Int64(Date().timeIntervalSince1970 * 1000) }
        // the window's timer never runs: the test moves the clock and asks for the check
        Contributions.recorder.setTimer(JoinTimer { _, _ in
            return {}
        })
    }

    override func tearDown() {
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
        Contributions.recorder.setTimer(.live)
    }

    // MARK: helpers

    func advance(_ ms: Int64) { Self.nowMs.withLock { $0 += ms } }

    /// A configured cloud (stub network, the test's clock) in `storage`; `consent`: the learner said yes.
    func configure(_ server: SharingTests.Server, consent: Bool = true, storage: URL = CloudFixtures.storage()) async -> QuranLabCloud {
        let options = CloudFixtures.options(contributions: true, storage: storage)
        let cloud = CloudFixtures.cloud(storage: storage, options: options, clock: {
            Date(timeIntervalSince1970: Double(SharingTakesTests.nowMs.withLock { $0 }) / 1000)
        })
        _ = await cloud.refreshConfig()
        QuranLab.configure(key: CloudFixtures.key, options: options, cloud: cloud)
        if consent { Contributions.answer(share: true) }
        return cloud
    }

    func noise(_ seconds: Double, rate: Double = 16_000) -> [Float] {
        seed += 1
        return SharingCodecTests.noise(Int((seconds * rate).rounded()), seed: seed)
    }

    /// A take starts now, as the recognizer starts one.
    func start(revision: String = "test-rev", backend: ActiveBackend = .exact) -> Int {
        Contributions.recorder.takeStarted(.init(revision: revision, backend: backend, weightsSHA256: nil))
    }

    /// Audio into the take in 100 ms pieces; the clock moves on by its length. Returns the pieces as they were given.
    @discardableResult
    func push(_ take: Int, _ x: [Float], rate: Double = 16_000) throws -> [[Float]] {
        var pieces: [[Float]] = []
        let piece = Int(rate / 10)
        var at = 0
        while at < x.count {
            let k = min(piece, x.count - at)
            let p = Array(x[at..<(at + k)])
            try Contributions.recorder.audio(take, p, rate: rate)
            pieces.append(p)
            at += k
        }
        advance(Int64(x.count) * 1000 / Int64(rate))
        return pieces
    }

    func end(_ take: Int, completed: Bool = true) { Contributions.recorder.takeEnded(take, completed: completed) }

    /// One take: started now, its audio, ended when the audio is through.
    @discardableResult
    func take(_ x: [Float], rate: Double = 16_000, completed: Bool = true, revision: String = "test-rev") throws -> [[Float]] {
        let t = start(revision: revision)
        let pieces = try push(t, x, rate: rate)
        end(t, completed: completed)
        return pieces
    }

    /// No take follows: the window passes and its check closes the recording.
    func windowPasses(_ window: Int64 = 3_000) {
        advance(window + 1)
        Contributions.recorder.checkWindow()
    }

    /// The id of the recording that is open.
    func openID(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try XCTUnwrap((Contributions.recorder.current as? ShareCapture)?.id, "no recording is open", file: file, line: line)
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 20, _ done: () async -> Bool) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if await done() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Uploads until recording `id` is up and its take list, if any, is sent or dropped.
    @discardableResult
    func settle(_ cloud: QuranLabCloud, _ id: String, timeout: TimeInterval = 30) async throws -> Contribution {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            await cloud.outbox.drain(ignoringBackoff: true)
            let item = await cloud.outbox.item(id)
            let list = await cloud.outbox.takesState(id)
            if let item, item.status == .uploaded, list != .pending { return item }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let last = await cloud.outbox.item(id)
        XCTFail("the outbox did not settle: \(String(describing: last))")
        return try XCTUnwrap(last)
    }

    /// The process of `cloud` ends, with no recording open; the returned storage is what it left on disk, where the
    /// next launch finds it. The client object lives on in this test process, and its outbox still has its queue and
    /// retries of its own, which the test's clock may have made due: left where it is, it would send the same
    /// recording beside the next client's outbox. A process that has ended sends nothing, so its outbox first ends
    /// what it is in the middle of (nothing writes into the storage while it moves), the storage moves to a new place
    /// in one step, and one more pass lets the old outbox find nothing where it looks: nothing is left for it to
    /// send. Called while the network is as that process last saw it.
    func retire(_ cloud: QuranLabCloud) async throws -> URL {
        await cloud.outbox.drain()
        let storage = CloudFixtures.storage()
        try FileManager.default.removeItem(at: storage)
        try FileManager.default.moveItem(at: cloud.storage, to: storage)
        await cloud.outbox.drain()
        return storage
    }

    func folder(_ cloud: QuranLabCloud, _ id: String) -> URL { cloud.outbox.root.appendingPathComponent(id, isDirectory: true) }

    func takes(_ t: (Int, Int)...) -> [ShareTake] { t.map { ShareTake(start_ms: $0.0, gap_ms: $0.1) } }

    func maps(_ t: (Int, Int)...) -> [[String: Int]] { t.map { ["start_ms": $0.0, "gap_ms": $0.1] } }

    func bodies(_ id: String) -> [String] { SharingTests.takeCalls(id).map { String(decoding: $0.body, as: UTF8.self) } }

    /// Every check of the bitrate stream test on one whole stream: pages in sequence from 0 (their CRCs are checked as
    /// they are read), one serial, BOS only on page 0, OpusHead only there and OpusTags only on page 1, granules
    /// 960 x packets, EOS only on the last page (`ended`) with the encoder's final position, and a libopus decode of
    /// exactly `input48` samples (when given).
    @discardableResult
    func checkStream(_ whole: Data, rate: Double, input48: Int?, ended: Bool = true, _ name: String) throws -> [SharingTests.Page] {
        let pages = try SharingTests.pages(whole)
        XCTAssertEqual(pages.map(\.sequence), (0..<UInt32(pages.count)).map { $0 }, "\(name): page sequence continuous from 0")
        XCTAssertEqual(Set(SharingBitrateTests.serials(whole)).count, 1, "\(name): one serial")
        XCTAssertEqual(pages.indices.filter { pages[$0].flags & 0x02 != 0 }, [0], "\(name): BOS only on page 0")
        let last: [Int] = ended ? [pages.count - 1] : []
        XCTAssertEqual(pages.indices.filter { pages[$0].flags & 0x04 != 0 }, last, "\(name): EOS only on the last page")
        let head = Data("OpusHead".utf8), tags = Data("OpusTags".utf8)
        XCTAssertEqual(pages.indices.filter { i in pages[i].packets.contains { $0.starts(with: head) } }, [0], "\(name): OpusHead only on page 0")
        XCTAssertEqual(pages.indices.filter { i in pages[i].packets.contains { $0.starts(with: tags) } }, [1], "\(name): OpusTags only on page 1")
        let h = pages[0].packets[0]
        XCTAssertEqual(h[12..<16].reversed().reduce(0) { $0 << 8 | Int($1) }, Int(rate), "\(name): OpusHead has the input rate")
        var packets = 0
        for (i, p) in pages.enumerated().dropFirst(2) {
            packets += p.packets.count
            if p.flags & 0x04 == 0 { XCTAssertEqual(p.granule, Int64(960 * packets), "\(name): granule of page \(i)") }
        }
        if ended, let input48 {
            XCTAssertEqual(pages.last?.granule, Int64(312 + input48), "\(name): the last granule is the encoder's final position")
            XCTAssertEqual(try OpusTestDecoder.decode(whole).count, input48, "\(name): libopus decodes exactly the input")
        }
        return pages
    }

    /// ffprobe and ffmpeg (its native and libopus decoders) on the stream, where they are installed.
    func checkWithFFmpeg(_ name: String, _ whole: Data, samples48: Int) throws {
        let file = SharingTests.temp()
        defer { try? FileManager.default.removeItem(at: file) }
        try whole.write(to: file)
        if let probe = SharingBitrateTests.tool("ffprobe") {
            let out = try SharingBitrateTests.runTool(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", file.path])
            let d = try XCTUnwrap(Double(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            print(String(format: "%@: ffprobe duration %.6f s, input %.6f s", name, d, Double(samples48) / 48_000))
            XCTAssertEqual(d, Double(samples48) / 48_000, accuracy: 0.020, "\(name): ffprobe duration within 20 ms")
        } else {
            print("\(name): ffprobe is not installed here (the libopus decode carries the check)")
        }
        if let ffmpeg = SharingBitrateTests.tool("ffmpeg") {
            for decoder in ["opus", "libopus"] {
                guard let pcm = try? SharingBitrateTests.runTool(ffmpeg, ["-v", "error", "-c:a", decoder, "-i", file.path, "-f", "f32le", "-ac", "1", "-"]) else {
                    print("\(name): ffmpeg has no \(decoder) decoder")
                    continue
                }
                print("\(name): ffmpeg \(decoder) decoder: \(pcm.count / 4) samples, input \(samples48)")
                XCTAssertEqual(pcm.count / 4, samples48, "\(name): ffmpeg's \(decoder) decoder gives exactly the input sample count")
            }
        }
    }

    /// ONE continuous encode of the same audio, fed in the pieces the takes were fed in (so the resampler sees the
    /// same calls), with the same serial, segment plan and per-segment bitrates and no takes: its segments' bytes.
    static func continuous(_ pieces: [[Float]], rate: Double, serial: UInt32, bitrates: [Int]) throws -> [Data] {
        let dir = try SharingBitrateTests.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var closed: [OggSegment] = []
        let w = try OggOpusWriter(segmentURL: { (n: Int) -> URL in dir.appendingPathComponent(ShareFiles.name(n)).appendingPathExtension("opus") },
                                  plan: SegmentPlan.seconds, inputRate: rate, serial: serial) { (s: OggSegment) in closed.append(s) }
        w.bitrateForSegment = { (n: Int) -> Int in bitrates[min(n, bitrates.count) - 1] }
        for p in pieces { try w.append(p) }
        _ = try w.finish()
        return try closed.map { (s: OggSegment) -> Data in try Data(contentsOf: s.url) }
    }

    /// The self-test clips (real recitation, 16 kHz), one after the other.
    static func clips() throws -> [Float] {
        var one: [Float] = []
        for c in try SelfTestClips.load().clips { one += c.samples }
        return one
    }

    // MARK: one stream

    /// The self-test clips cut into three takes, 1.2 s and 0.8 s apart, at 16, 48 and 44.1 kHz input: ONE recording
    /// (one session JSON, one upload id), a valid stream by every check of the bitrate stream test, a decode of exactly
    /// the takes' samples at 48 kHz, and bytes and decoded PCM identical to one continuous encode of the same audio.
    /// The cuts fall inside a 20 ms Opus frame, so the frame one take leaves is completed by the next take's first
    /// samples. The take list follows the last segment with the exact body.
    func testThreeTakesInARowAreOneRecordingByteForByteTheContinuousEncode() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        let clip = try Self.clips()
        let n = clip.count
        let cuts = [0, n / 3 + 17, 2 * n / 3 + 233, n]
        for rate in [16_000.0, 48_000.0, 44_100.0] {
            let name = "three takes at \(Int(rate)) Hz"
            let before = SharingTests.starts.count
            var pieces: [[Float]] = []
            for i in 0..<3 {
                if i == 1 { advance(1_200) }
                if i == 2 { advance(800) }
                pieces += try take(Array(clip[cuts[i]..<cuts[i + 1]]), rate: rate)
                XCTAssertNotNil(Contributions.recorder.current, "\(name): the recording waits for the next take")
            }
            let id = try openID()
            windowPasses()
            XCTAssertNil(Contributions.recorder.current, name)
            let item = try await settle(cloud, id)
            XCTAssertEqual(item.takes, 3, name)
            XCTAssertEqual(item.completed, true, name)
            XCTAssertEqual(item.durationMs, Int((Double(n) / rate * 1000).rounded()), name)
            XCTAssertEqual(SharingTests.starts.count, before + 1, "\(name): the session JSON once, with the first take")
            XCTAssertEqual(SharingTests.starts.last?.headers["x-qlab-id"], id, name)

            let segs = server.segments(id)
            XCTAssertEqual(segs.count, item.segments, name)
            let whole = segs.reduce(Data(), +)
            // 16 and 48 kHz: the takes' samples at 48 kHz, exactly; 44.1 kHz: the converter's own rounding at the end
            let exact: Int? = rate == 48_000 ? n : rate == 16_000 ? 3 * n : nil
            try checkStream(whole, rate: rate, input48: exact, name)
            let decoded = try OpusTestDecoder.decode(whole)
            if exact == nil { XCTAssertEqual(Double(decoded.count), Double(n) * 48_000 / rate, accuracy: 2, "\(name): the input's length at 48 kHz") }

            let serial = try XCTUnwrap(SharingBitrateTests.serials(whole).first, name)
            let ref = try Self.continuous(pieces, rate: rate, serial: serial, bitrates: item.segmentBitrates)
            XCTAssertEqual(ref.count, segs.count, name)
            XCTAssertEqual(ref, segs, "\(name): byte for byte the continuous encode")
            XCTAssertEqual(try OpusTestDecoder.decode(ref.reduce(Data(), +)), decoded, "\(name): the decoded PCM is the continuous encode's")

            let want = takes((0, 0), (cuts[1] * 1000 / Int(rate), 1_200), (cuts[2] * 1000 / Int(rate), 800))
            XCTAssertEqual(ShareFiles.takes(folder(cloud, id)), want, name)
            let calls = SharingTests.takeCalls(id)
            XCTAssertEqual(calls.count, 1, name)
            XCTAssertEqual(calls.first?.body, ShareFiles.takesBody(want), name)
            XCTAssertEqual(calls.first?.headers["content-type"], "application/json", name)
            XCTAssertEqual(calls.first?.headers["authorization"], "Bearer qlt_v1.eyJ2IjoxfQ.att", name)
            XCTAssertEqual(calls.first?.headers["x-qlab-contributor"], QuranLab.contributorID, name)
            XCTAssertEqual(server.takes.withLock { $0[id] }, want.map { (t: ShareTake) -> [String: Int] in ["start_ms": t.start_ms, "gap_ms": t.gap_ms] }, name)
            let seen = StubProtocol.seen
            let lastPut = try XCTUnwrap(seen.lastIndex { $0.url.host == "r2.test" && $0.path.contains(id) }, name)
            let call = try XCTUnwrap(seen.firstIndex { $0.path == "/v1/uploads/\(id)/takes" }, name)
            XCTAssertLessThan(lastPut, call, "\(name): after the last segment")
            let state = await cloud.outbox.takesState(id)
            XCTAssertEqual(state, .sent, name)
            print("\(name): \(segs.count) segments, \(whole.count) bytes, \(decoded.count) samples decoded, takes "
                  + "\(String(decoding: ShareFiles.takesBody(want), as: UTF8.self)), identical to the continuous encode")
            try checkWithFFmpeg(name, whole, samples48: decoded.count)
        }
        XCTAssertEqual(SharingTests.starts.count, 3, "three recordings in all, each sent once")
    }

    /// A recording of three takes over 75 s (the clips repeated, 16 kHz): segments are cut by the same plan counted
    /// across the takes (10, 20, 40 s, then the rest), one boundary exactly at a take boundary and the others inside a
    /// take, and the bitrate changes between them. The stream is byte for byte one continuous encode with those
    /// bitrates; every segment's marker has its bitrate.
    func testARecordingOfTakesIsCutBySegmentsAndBitratesLikeOneStream() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        let one = try Self.clips()
        let rate = 16_000.0
        var input: [Float] = []
        while input.count < 75 * 16_000 { input += one }
        input = Array(input[0..<(75 * 16_000)])
        let cuts = [0, 10 * 16_000, 41 * 16_000 + 11_200, input.count]   // 10 s, 31.7 s, 33.3 s
        let ladder = cloud.outbox.ladder
        var pieces: [[Float]] = []

        pieces += try take(Array(input[cuts[0]..<cuts[1]]))
        let id = try openID()
        ladder.uploadFailed()   // the second segment opens one rung down, with the second take's first packets
        advance(1_200)
        let second = start()
        pieces += try push(second, Array(input[cuts[1]..<(cuts[1] + 15 * 16_000)]))
        XCTAssertEqual(ShareFiles.markers(folder(cloud, id)).count, 1)
        ladder.uploadFailed()   // the third segment opens lower again, 20 s into the second take
        ladder.uploadFailed()
        pieces += try push(second, Array(input[(cuts[1] + 15 * 16_000)..<cuts[2]]))
        end(second)
        advance(800)
        pieces += try take(Array(input[cuts[2]..<cuts[3]]))
        XCTAssertEqual(try openID(), id)
        windowPasses()
        let item = try await settle(cloud, id)

        let bitrates = item.segmentBitrates
        XCTAssertEqual(bitrates.count, 4)
        XCTAssertEqual(bitrates.first, 192_000)
        XCTAssertGreaterThanOrEqual(Set(bitrates).count, 2, "the bitrate changed between segments: \(bitrates)")
        XCTAssertLessThan(bitrates[2], 192_000, "two failures before the third segment opened: \(bitrates)")
        XCTAssertEqual(ShareFiles.markers(folder(cloud, id)).map { (m: ShareFiles.Marker) -> Int in m.bitrate ?? 0 }, bitrates, "each marker has its bitrate")
        XCTAssertEqual(item.segments, 4)
        XCTAssertEqual(item.takes, 3)
        XCTAssertEqual(item.durationMs, 75_000)
        XCTAssertEqual(SharingTests.starts.count, 1, "one session start for the three takes")
        XCTAssertEqual(SharingTests.puts.map(\.path), (1...4).map { "/qlab-contributions/v1/\(id)/seg-0000\($0).opus" })
        XCTAssertEqual(server.takes.withLock { $0[id] }, maps((0, 0), (10_000, 1_200), (41_700, 800)))
        XCTAssertEqual(SharingTests.takeCalls(id).count, 1)

        let segs = server.segments(id)
        let whole = segs.reduce(Data(), +)
        try checkStream(whole, rate: rate, input48: 75 * 48_000, "takes over segments")
        let head = Data("Opus".utf8)
        let audio: [Int] = try segs.map { (s: Data) -> Int in
            try SharingTests.pages(s).filter { $0.packets.first?.starts(with: head) != true }.reduce(0) { $0 + $1.packets.count }
        }
        XCTAssertEqual(audio, [500, 1_000, 2_000, 251], "10, 20 and 40 s of packets, then the rest")
        let serial = try XCTUnwrap(SharingBitrateTests.serials(whole).first)
        let ref = try Self.continuous(pieces, rate: rate, serial: serial, bitrates: bitrates)
        XCTAssertEqual(ref.count, 4)
        XCTAssertEqual(ref, segs, "byte for byte the continuous encode")
        XCTAssertEqual(try OpusTestDecoder.decode(ref.reduce(Data(), +)), try OpusTestDecoder.decode(whole), "the decoded PCM is the continuous encode's")
        print("takes over segments: \(whole.count) bytes, segments \(bitrates.map { $0 / 1000 }) kbit/s, "
              + "bytes \(segs.map(\.count)), takes \(bodies(id)), identical to the continuous encode")
        try checkWithFFmpeg("takes over segments", whole, samples48: 75 * 48_000)
    }

    /// A gap over the window: two recordings, each a valid stream of its own with its own session JSON; no take list.
    func testAGapOverTheWindowGivesTwoRecordings() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        let a = try take(noise(3))
        let first = try openID()
        advance(3_001)
        let b = try take(noise(2.5))
        let second = try openID()
        XCTAssertNotEqual(first, second)
        windowPasses()
        for (id, pieces, samples) in [(first, a, 48_000), (second, b, 40_000)] {
            let item = try await settle(cloud, id)
            XCTAssertEqual(item.takes, 1)
            XCTAssertEqual(item.completed, true)
            let whole = server.segments(id).reduce(Data(), +)
            try checkStream(whole, rate: 16_000, input48: samples * 3, id)
            let serial = try XCTUnwrap(SharingBitrateTests.serials(whole).first)
            XCTAssertEqual(try Self.continuous(pieces, rate: 16_000, serial: serial, bitrates: item.segmentBitrates).reduce(Data(), +), whole)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder(cloud, id).appendingPathComponent(ShareFiles.takesFile).path))
            let state = await cloud.outbox.takesState(id)
            XCTAssertNil(state)
        }
        XCTAssertEqual(Set(SharingTests.starts.compactMap { $0.headers["x-qlab-id"] }), [first, second], "a session JSON each")
        XCTAssertTrue(StubProtocol.seen.allSatisfy { !$0.path.hasSuffix("/takes") }, "one take each: no take list")

        // exactly the window apart joins
        try take(noise(3))
        advance(3_000)
        try take(noise(2.5))
        let id = try openID()
        windowPasses()
        let joined = try await settle(cloud, id)
        XCTAssertEqual(joined.takes, 2)
        XCTAssertEqual(server.takes.withLock { $0[id] }, maps((0, 0), (3_000, 3_000)))
        try checkStream(server.segments(id).reduce(Data(), +), rate: 16_000, input48: 88_000 * 3, "joined at the edge")
    }

    // MARK: recovery

    /// Records with `body` while nothing can be uploaded, then leaves the disk as a kill at that moment would: a copy
    /// of the storage and the id of the recording that was open. The request log starts again: what the killed
    /// process asked of the server is not the next launch's.
    func killed(_ server: SharingTests.Server, _ body: () throws -> Void) async throws -> (storage: URL, id: String) {
        server.down.withLock { $0 = true }
        let cloud = await configure(server)
        try body()
        let id = try openID()
        // the outbox has tried and is waiting for its retry: nothing writes into the folder while it is copied
        try await waitUntil("the first try of the upload") { await cloud.outbox.item(id)?.lastError != nil }
        let storage = CloudFixtures.storage()
        try FileManager.default.removeItem(at: storage)
        try FileManager.default.copyItem(at: cloud.storage, to: storage)
        // that process is gone: its recording never ends (here it is dropped, with its own folder), its outbox forgets
        // it in one more pass, and its requests (a start that found no network) leave the log
        Contributions.recorder.stop()
        ShareCapture.active.withLock { _ = $0.remove(id) }
        await cloud.outbox.drain()
        StubProtocol.reset(server.handler)
        server.down.withLock { $0 = false }
        return (storage, id)
    }

    /// The process killed between takes and inside the second take: the next launch closes the recording at its last
    /// whole page (as 2.0.1), keeps the takes that start inside what is left, uploads it and sends the take list.
    func testAKilledRecordingOfTakesIsRecoveredWithItsTakes() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)

        // killed in the window after the second take
        let between = try await killed(server) {
            try self.take(self.noise(12))
            self.advance(1_500)
            try self.take(self.noise(4))
        }
        let folder = between.storage.appendingPathComponent("outbox").appendingPathComponent(between.id)
        XCTAssertEqual(ShareFiles.takes(folder), takes((0, 0), (12_000, 1_500)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ShareFiles.end).path))
        let open = folder.appendingPathComponent("seg-00002.opus")
        let wholePages = try Data(contentsOf: open)
        XCTAssertGreaterThan(wholePages.count, 0)
        let h = try FileHandle(forWritingTo: open)
        try h.seekToEnd()
        try h.write(contentsOf: Data("OggS".utf8) + Data(repeating: 5, count: 90))
        try h.close()
        var relaunched = await configure(server, storage: between.storage)
        var item = try await settle(relaunched, between.id)
        XCTAssertEqual(item.completed, false)
        XCTAssertEqual(item.segments, 2)
        XCTAssertEqual(item.takes, 2)
        var segs = server.segments(between.id)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs.last, wholePages, "the torn page is cut off")
        var pages = try checkStream(segs.reduce(Data(), +), rate: 16_000, input48: nil, ended: false, "killed between takes")
        XCTAssertEqual(item.durationMs, Int((pages.last!.granule - 312) / 48))
        XCTAssertTrue((14_000..<16_000).contains(item.durationMs), "16 s were recited; what is on whole pages is kept: \(item.durationMs)")
        XCTAssertEqual(server.takes.withLock { $0[between.id] }, maps((0, 0), (12_000, 1_500)))
        XCTAssertEqual(bodies(between.id), ["{\"takes\":[{\"start_ms\":0,\"gap_ms\":0},{\"start_ms\":12000,\"gap_ms\":1500}]}"])
        var state = await relaunched.outbox.takesState(between.id)
        XCTAssertEqual(state, .sent)
        XCTAssertEqual(SharingTests.starts.filter { $0.headers["x-qlab-id"] == between.id }.count, 1)

        // killed inside the second take, 5.3 s in
        let inside = try await killed(server) {
            try self.take(self.noise(12))
            self.advance(700)
            let t = self.start()
            try self.push(t, self.noise(5.3))
        }
        relaunched = await configure(server, storage: inside.storage)
        item = try await settle(relaunched, inside.id)
        XCTAssertEqual(item.completed, false)
        XCTAssertEqual(item.takes, 2)
        XCTAssertTrue((16_000..<17_300).contains(item.durationMs), "17.3 s were recited: \(item.durationMs)")
        XCTAssertEqual(server.takes.withLock { $0[inside.id] }, maps((0, 0), (12_000, 700)))
        segs = server.segments(inside.id)
        pages = try checkStream(segs.reduce(Data(), +), rate: 16_000, input48: nil, ended: false, "killed inside the second take")
        XCTAssertEqual(item.durationMs, Int((pages.last!.granule - 312) / 48))

        // killed 0.4 s into the second take: none of it is on a whole page, so the recording has one take and no list
        let early = try await killed(server) {
            try self.take(self.noise(12))
            self.advance(700)
            let t = self.start()
            try self.push(t, self.noise(0.4))
        }
        let earlyFolder = early.storage.appendingPathComponent("outbox").appendingPathComponent(early.id)
        XCTAssertEqual(ShareFiles.takes(earlyFolder), takes((0, 0), (12_000, 700)), "the list was on disk when it was killed")
        relaunched = await configure(server, storage: early.storage)
        item = try await settle(relaunched, early.id)
        XCTAssertEqual(item.takes, 1)
        XCTAssertTrue((11_000..<12_000).contains(item.durationMs), "\(item.durationMs)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: earlyFolder.appendingPathComponent(ShareFiles.takesFile).path))
        XCTAssertTrue(SharingTests.takeCalls(early.id).isEmpty)
        state = await relaunched.outbox.takesState(early.id)
        XCTAssertNil(state)
    }

    // MARK: the take list call

    /// Two takes in a row (1.5 s each, 500 ms apart) and no third: the closed recording's id.
    func joined() throws -> String {
        try take(noise(1.5))
        advance(500)
        try take(noise(1.5))
        let id = try openID()
        windowPasses()
        return id
    }

    static let twoTakes = "{\"takes\":[{\"start_ms\":0,\"gap_ms\":0},{\"start_ms\":1500,\"gap_ms\":500}]}"

    /// The take list: sent once, after the last segment, with the exact body; a recording of one take sends none.
    func testTheTakeListIsSentOnceAfterTheLastSegment() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        let id = try joined()
        let item = try await settle(cloud, id)
        XCTAssertEqual(item.status, .uploaded)
        XCTAssertEqual(item.takes, 2)
        XCTAssertEqual(item.durationMs, 3_000)
        XCTAssertEqual(bodies(id), [Self.twoTakes])
        let order = StubProtocol.seen.filter { $0.path.hasPrefix("/v1/uploads") || $0.method == "PUT" }
            .map { "\($0.method) \($0.url.lastPathComponent)" }
        XCTAssertEqual(order, ["POST uploads", "PUT seg-00001.opus", "POST takes"], "the session, the segment, then the take list")
        XCTAssertEqual(server.takes.withLock { $0[id] }, maps((0, 0), (1_500, 500)))
        var state = await cloud.outbox.takesState(id)
        XCTAssertEqual(state, .sent)
        for _ in 0..<3 { await cloud.outbox.drain(ignoringBackoff: true) }
        XCTAssertEqual(SharingTests.takeCalls(id).count, 1, "never again")
        // a new process reads the item: sent, and the count stays
        let disk = try await retire(cloud)
        let again = await configure(server, storage: disk)
        await again.outbox.drain(ignoringBackoff: true)
        XCTAssertEqual(SharingTests.takeCalls(id).count, 1)
        let kept = await again.outbox.item(id)
        XCTAssertEqual(kept?.takes, 2)
        state = await again.outbox.takesState(id)
        XCTAssertEqual(state, .sent)

        // one take: no list, no call
        try take(noise(1.5))
        let one = try openID()
        windowPasses()
        let single = try await settle(again, one)
        XCTAssertEqual(single.takes, 1)
        XCTAssertTrue(SharingTests.takeCalls(one).isEmpty)
        state = await again.outbox.takesState(one)
        XCTAssertNil(state)
    }

    /// A server without the route answers 404: the list is dropped, the session stays uploaded.
    func testA404DropsTheTakeListWithoutFailingTheSession() async throws {
        let server = SharingTests.Server()
        server.takesRoute.withLock { $0 = false }
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        let a = try joined()
        let b = try joined()
        for id in [a, b] {
            let item = try await settle(cloud, id)
            XCTAssertEqual(item.status, .uploaded)
            XCTAssertNil(item.lastError)
            XCTAssertEqual(item.takes, 2, "the count is the recording's, sent or not")
            let state = await cloud.outbox.takesState(id)
            XCTAssertEqual(state, .dropped)
            XCTAssertEqual(bodies(id), [Self.twoTakes])
        }
        for _ in 0..<3 { await cloud.outbox.drain(ignoringBackoff: true) }
        XCTAssertEqual(StubProtocol.seen.filter { $0.path.hasSuffix("/takes") }.count, 2, "a dropped list is not sent again")
        let notes = await cloud.outbox.takesRouteNotes
        XCTAssertEqual(notes, 2, "both answers were 404 (the line for the developer is written at the first)")
        XCTAssertTrue(cloud.issues.pending.isEmpty)
    }

    /// No answer to the take list call: the session is uploaded all the same, the list waits with the outbox's backoff
    /// and the retry sends the same body, in this process or the next. The bitrate ladder does not hear of it.
    func testANetworkFailureKeepsTheTakeListAndTheRetrySendsTheSameBody() async throws {
        let server = SharingTests.Server()
        server.takesReply.withLock { $0 = { (_: Int) -> StubProtocol.Reply? in StubProtocol.Reply.down } }
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        let id = try joined()
        try await waitUntil("the first try of the take list") { !SharingTests.takeCalls(id).isEmpty }
        try await waitUntil("the wait for the retry") { await cloud.outbox.takesState(id) == .pending }
        var item = await cloud.outbox.item(id)
        XCTAssertEqual(item?.status, .uploaded, "uploaded whatever becomes of the list")
        XCTAssertNil(item?.lastError)
        XCTAssertEqual(cloud.outbox.ladder.bitrate, 192_000, "not audio: the ladder stays")
        // the backoff: nothing before it is due (30 s, with jitter)
        await cloud.outbox.drain()
        XCTAssertEqual(SharingTests.takeCalls(id).count, 1)
        advance(40_000)
        await cloud.outbox.drain()
        XCTAssertEqual(SharingTests.takeCalls(id).count, 2, "tried again when it was due")
        var state = await cloud.outbox.takesState(id)
        XCTAssertEqual(state, .pending)

        // the next launch finds it in the item and sends it
        let disk = try await retire(cloud)
        server.takesReply.withLock { $0 = { (_: Int) -> StubProtocol.Reply? in nil } }
        let again = await configure(server, storage: disk)
        state = await again.outbox.takesState(id)
        XCTAssertEqual(state, .pending)
        item = try await settle(again, id)
        XCTAssertEqual(bodies(id), [Self.twoTakes, Self.twoTakes, Self.twoTakes], "the same body each time")
        XCTAssertEqual(server.takes.withLock { $0[id] }, maps((0, 0), (1_500, 500)))
        state = await again.outbox.takesState(id)
        XCTAssertEqual(state, .sent)
        XCTAssertEqual(SharingTests.puts.count, 1, "one PUT in all: the segment was not sent again")
        XCTAssertEqual(SharingTests.starts.count, 1)
    }

    /// 503 and 429 keep the list for a retry with the same body; 400 keeps it too and reports once (SDK 3.0.0); 401
    /// renews the token; 410 drops it.
    func testTheTakeListCallFollowsItsAnswers() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)

        // 503, then 429, then accepted
        server.takesReply.withLock {
            $0 = { (n: Int) -> StubProtocol.Reply? in
                if n == 1 { return StubProtocol.Reply(status: 503, headers: [:]) }
                if n == 2 { return StubProtocol.Reply.json(["error": "rate_limited", "message": ""], status: 429) }
                return nil
            }
        }
        let a = try joined()
        var item = try await settle(cloud, a)
        XCTAssertEqual(item.status, .uploaded)
        XCTAssertEqual(bodies(a), [Self.twoTakes, Self.twoTakes, Self.twoTakes])
        var state = await cloud.outbox.takesState(a)
        XCTAssertEqual(state, .sent)
        XCTAssertEqual(cloud.outbox.ladder.bitrate, 192_000, "the ladder does not hear of the take list")

        // 400: the list stays and is tried again with the same body; the bad-request issue is reported once
        StubProtocol.reset(server.handler)
        let refuse = Locked(true)
        server.takesReply.withLock {
            $0 = { (_: Int) -> StubProtocol.Reply? in
                refuse.withLock { $0 } ? StubProtocol.Reply.json(["error": "invalid_body", "message": "json.takes[1].gap_ms"], status: 400) : nil
            }
        }
        let b = try joined()
        try await waitUntil("the first answer to the take list") { await cloud.outbox.takesWaits(b) }
        state = await cloud.outbox.takesState(b)
        XCTAssertEqual(state, .pending, "a refused list is not dropped")
        let waiting = await cloud.outbox.item(b)
        XCTAssertEqual(waiting?.status, .uploaded)
        try await waitUntil("the bad_request issue") {
            StubProtocol.seen("/v1/issues").contains { $0.json?["code"] as? String == "bad_request:uploads_takes" }
                || cloud.issues.pending.contains { $0.code == "bad_request:uploads_takes" }
        }
        // nothing before the backoff is due
        await cloud.outbox.drain()
        XCTAssertEqual(SharingTests.takeCalls(b).count, 1)
        await cloud.outbox.drain(ignoringBackoff: true)
        await cloud.outbox.drain(ignoringBackoff: true)
        XCTAssertEqual(SharingTests.takeCalls(b).count, 3)
        var issues = await cloud.outbox.takesIssues
        XCTAssertEqual(issues, 1, "reported once for the list")
        state = await cloud.outbox.takesState(b)
        XCTAssertEqual(state, .pending)
        // the server is fixed: the same list is accepted
        refuse.withLock { $0 = false }
        item = try await settle(cloud, b)
        state = await cloud.outbox.takesState(b)
        XCTAssertEqual(state, .sent)
        XCTAssertEqual(bodies(b), [Self.twoTakes, Self.twoTakes, Self.twoTakes, Self.twoTakes])
        issues = await cloud.outbox.takesIssues
        XCTAssertEqual(issues, 1)

        // 401: a new token, and again
        StubProtocol.reset(server.handler)
        server.takesReply.withLock {
            $0 = { (n: Int) -> StubProtocol.Reply? in
                if n == 1 { return StubProtocol.Reply.json(["error": "invalid_token", "message": ""], status: 401) }
                return nil
            }
        }
        let c = try joined()
        item = try await settle(cloud, c)
        state = await cloud.outbox.takesState(c)
        XCTAssertEqual(state, .sent)
        XCTAssertEqual(bodies(c), [Self.twoTakes, Self.twoTakes])
        let calls = StubProtocol.seen
        let refused = try XCTUnwrap(calls.firstIndex { $0.path.hasSuffix("/takes") })
        let accepted = try XCTUnwrap(calls.lastIndex { $0.path.hasSuffix("/takes") })
        XCTAssertTrue(calls[refused..<accepted].contains { $0.path.hasPrefix("/v1/attest") }, "a token was fetched again between the two")

        // 410: the upload was deleted on the server: dropped
        StubProtocol.reset(server.handler)
        server.takesReply.withLock {
            $0 = { (_: Int) -> StubProtocol.Reply? in StubProtocol.Reply.json(["error": "upload_deleted", "message": ""], status: 410) }
        }
        let d = try joined()
        item = try await settle(cloud, d)
        XCTAssertEqual(item.status, .uploaded)
        state = await cloud.outbox.takesState(d)
        XCTAssertEqual(state, .dropped)
        await cloud.outbox.drain(ignoringBackoff: true)
        XCTAssertEqual(SharingTests.takeCalls(d).count, 1)
        let all = await cloud.outbox.items
        XCTAssertEqual(all.filter { $0.status == .uploaded }.count, 4, "four recordings, all uploaded")
    }

    /// SDK 3.0.0 through the real capture and the outbox: the audio an app feeds around its takes is in the stream (a
    /// second before a take, half a second after it), the take list starts after the pre-roll, and the session JSON
    /// counts the install's recordings.
    func testTheFeedAndTheCountOfRecordingsReachTheServer() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        func feed(_ seconds: Double) -> ShareFeed.Fed {
            var total = ShareFeed.Fed()
            for _ in 0..<Int((seconds * 10).rounded()) {
                advance(100)
                let f = Contributions.recorder.feed(noise(0.1), rate: 16_000)
                total.toTail += f.toTail
                total.toRing += f.toRing
                total.dropped += f.dropped
            }
            return total
        }
        XCTAssertEqual(feed(1.5), ShareFeed.Fed(toTail: 0, toRing: 24_000, dropped: 0))
        try take(noise(2))
        XCTAssertEqual(Contributions.recorder.preRoll, 16_000, "the last second of the feed")
        XCTAssertEqual(feed(1), ShareFeed.Fed(toTail: 8_000, toRing: 8_000, dropped: 0))
        try take(noise(2))   // 1 s after the first: it joins, with the half second the ring holds
        XCTAssertEqual(Contributions.recorder.preRoll, 8_000)
        let first = try openID()
        advance(4_000)
        try take(noise(2))   // over the window: the install's second recording
        let second = try openID()
        XCTAssertNotEqual(first, second)
        windowPasses()
        let a = try await settle(cloud, first)
        let b = try await settle(cloud, second)
        XCTAssertEqual(a.durationMs, 6_000, "1 s of pre-roll, 2 s, 0.5 s of tail, 0.5 s of pre-roll, 2 s")
        XCTAssertEqual(a.takes, 2)
        XCTAssertEqual(server.takes.withLock { $0[first] }, maps((1_000, 0), (4_000, 1_000)), "each take starts after its pre-roll")
        XCTAssertEqual(b.durationMs, 2_000)
        func session(_ id: String) -> [String: Any]? { SharingTests.starts.first { $0.headers["x-qlab-id"] == id }?.json }
        XCTAssertEqual(session(first)?["take_seq"] as? Int, 1)
        XCTAssertNil(session(first)?["gap_ms_prev"], "the install's first recording")
        XCTAssertEqual(session(second)?["take_seq"] as? Int, 2)
        XCTAssertEqual(session(second)?["gap_ms_prev"] as? Int, 4_000)
        // nothing fed stays in memory once sharing goes off
        XCTAssertEqual(feed(0.3).toRing, 4_800)
        XCTAssertEqual(Contributions.recorder.ringSamples, 4_800)
        await Contributions.setSharing(false)
        XCTAssertEqual(Contributions.recorder.ringSamples, 0)
        XCTAssertEqual(Contributions.recorder.feed(noise(0.1), rate: 16_000), ShareFeed.Fed(toTail: 0, toRing: 0, dropped: 1_600))
        XCTAssertEqual(Contributions.recorder.ringSamples, 0)
    }

    /// The shared vector's answers to the take list call, in order: where the list stands after each, and the one
    /// answer that reports the bad-request issue.
    func testTheTakeListAnswersOfTheSharedVector() async throws {
        let all = try Vectors30.json("sharing_30.json")
        let cases = try XCTUnwrap((all["take_list_answers"] as? [String: Any])?["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 8)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            // each case starts today: a case that lets seven days pass moved the clock
            Self.nowMs.withLock { (t: inout Int64) in t = Int64(Date().timeIntervalSince1970 * 1000) }
            let steps = try XCTUnwrap(c["steps"] as? [[String: Any]], name)
            let answers = steps.map { $0["answer"] as? String ?? "" }
            // the n-th call's answer; the events between the calls are not calls
            let http = answers.filter { $0 != "sharing off" && $0 != "seven days passed" }
            let server = SharingTests.Server()
            server.takesReply.withLock {
                $0 = { (n: Int) -> StubProtocol.Reply? in
                    switch http[min(max(n, 1), http.count) - 1] {
                    case "204", "200": return nil
                    case "400": return .json(["error": "invalid_body", "message": "json.takes"], status: 400)
                    case "401": return .json(["error": "invalid_token", "message": ""], status: 401)
                    case "429": return .json(["error": "rate_limited", "message": ""], status: 429)
                    case "503": return StubProtocol.Reply(status: 503, headers: [:])
                    case "404 not_found (the route)": return .json(["error": "not_found", "message": "not_found"], status: 404)
                    case "410 upload_deleted": return .json(["error": "upload_deleted", "message": ""], status: 410)
                    default: return .down
                    }
                }
            }
            StubProtocol.reset(server.handler)
            let cloud = await configure(server)
            let id = try joined()
            var calls = 0, issues = 0
            for (k, step) in steps.enumerated() {
                let label = "\(name), step \(k + 1) (\(answers[k]))"
                switch answers[k] {
                case "sharing off":
                    await Contributions.setSharing(false)
                case "seven days passed":
                    advance(8 * 86_400_000)
                    await cloud.outbox.drain(ignoringBackoff: true)
                default:
                    calls += 1
                    let want = calls
                    if k == 0 {
                        // the first call follows the last segment by itself
                        try await waitUntil("\(label): the call") { SharingTests.takeCalls(id).count >= want }
                    } else if SharingTests.takeCalls(id).count < want {
                        await cloud.outbox.drain(ignoringBackoff: true)
                    }
                }
                if (step["issue_reported_now"] as? Bool) == true { issues += 1 }
                let states: [String: ContributionOutbox.Record.Takes] = ["pending": .pending, "done": .sent, "dropped": .dropped]
                let wantState = states[step["state"] as? String ?? ""]
                let wantIssues = issues, wantCalls = calls
                // after a 401 the next try is due at once, and the outbox's own wake may already have sent it
                let renewing = answers[k] == "401"
                try await waitUntil(label) {
                    let state = await cloud.outbox.takesState(id)
                    let seen = await cloud.outbox.takesIssues
                    let waits = await cloud.outbox.takesWaits(id)
                    let sent = SharingTests.takeCalls(id).count
                    if renewing { return sent > wantCalls || (sent == wantCalls && state == .pending && waits) }
                    return state == wantState && seen == wantIssues && sent == wantCalls && (state != .pending || waits)
                }
                let item = await cloud.outbox.item(id)
                XCTAssertEqual(item?.status, .uploaded, "\(label): the recording is uploaded whatever becomes of the list")
            }
            // nothing more is sent once the list is done or dropped
            let before = SharingTests.takeCalls(id).count
            await cloud.outbox.drain(ignoringBackoff: true)
            XCTAssertEqual(SharingTests.takeCalls(id).count, before, name)
            XCTAssertTrue(bodies(id).allSatisfy { $0 == Self.twoTakes }, "\(name): the same body every time")
            _ = try await retire(cloud)
        }
    }

    /// A take list that waits is dropped when sharing goes off, and after 7 days; its recording stays uploaded.
    func testAWaitingTakeListEndsWithSharingOrAfterSevenDays() async throws {
        let server = SharingTests.Server()
        server.takesReply.withLock { $0 = { (_: Int) -> StubProtocol.Reply? in StubProtocol.Reply.down } }
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        let a = try joined()
        try await waitUntil("the list waits") { await cloud.outbox.takesState(a) == .pending && !SharingTests.takeCalls(a).isEmpty }
        await Contributions.setSharing(false)
        var state = await cloud.outbox.takesState(a)
        XCTAssertEqual(state, .dropped)
        var items = await cloud.outbox.items
        XCTAssertEqual(items.map(\.status), [.uploaded])
        let tried = SharingTests.takeCalls(a).count
        await Contributions.setSharing(true)
        await cloud.outbox.drain(ignoringBackoff: true)
        XCTAssertEqual(SharingTests.takeCalls(a).count, tried)

        let b = try joined()
        try await waitUntil("the list waits") { await cloud.outbox.takesState(b) == .pending && !SharingTests.takeCalls(b).isEmpty }
        let before = SharingTests.takeCalls(b).count
        advance(8 * 86_400_000)
        await cloud.outbox.drain(ignoringBackoff: true)
        state = await cloud.outbox.takesState(b)
        XCTAssertEqual(state, .dropped)
        XCTAssertEqual(SharingTests.takeCalls(b).count, before, "dropped without another try")
        items = await cloud.outbox.items
        XCTAssertEqual(items.filter { $0.status == .uploaded }.count, 2)
    }

    // MARK: the rules through the client

    /// Sharing turned off during the join window: the recording ends at once and the unsent queue is deleted (the 2.0.1
    /// rule); a take that follows is not recorded. With segments already up, nothing more is sent.
    func testWithdrawalDuringTheJoinWindowEndsTheRecordingAndDeletesTheQueue() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        server.down.withLock { $0 = true }
        let cloud = await configure(server)
        try take(noise(12))
        let id = try openID()
        // the outbox has made its first try (there is no network) and waits for its retry: no request of it is under
        // way when sharing goes off
        try await waitUntil("the first try of the upload") { await cloud.outbox.item(id)?.lastError != nil }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder(cloud, id).path))
        advance(1_000)
        await Contributions.setSharing(false)
        XCTAssertNil(Contributions.recorder.current, "ended at once")
        var items = await cloud.outbox.items
        XCTAssertTrue(items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder(cloud, id).path), "the queue is deleted")
        XCTAssertFalse(ShareCapture.active.withLock { $0.contains(id) })
        server.down.withLock { $0 = false }
        StubProtocol.reset(server.handler)
        advance(500)
        try take(noise(3))
        XCTAssertNil(Contributions.recorder.current, "a take after sharing went off is not recorded")
        try await Task.sleep(nanoseconds: 200_000_000)
        items = await cloud.outbox.items
        XCTAssertTrue(items.isEmpty && SharingTests.starts.isEmpty && SharingTests.puts.isEmpty)

        // on again from the settings: the next take starts a new recording
        await Contributions.setSharing(true)
        try take(noise(12))
        let second = try openID()
        advance(500)
        let t = start()
        try push(t, noise(1))
        try await waitUntil("the first segment in R2 while the second take runs") { server.segments(second).count == 1 }
        XCTAssertEqual(ShareFiles.takes(folder(cloud, second)), takes((0, 0), (12_000, 500)))
        // off inside the take: the recording ends there, nothing more is sent, the rest of the take is not recorded
        await Contributions.setSharing(false)
        XCTAssertNil(Contributions.recorder.current)
        try push(t, noise(1))
        end(t)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(SharingTests.puts.count, 1)
        XCTAssertTrue(StubProtocol.seen.allSatisfy { !$0.path.hasSuffix("/takes") })
        items = await cloud.outbox.items
        XCTAssertTrue(items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder(cloud, second).path))
        XCTAssertEqual(Contributions.consent, .final)
    }

    /// The app going to the background closes a recording that waits; one in a take closes when the take ends.
    func testTheBackgroundDuringTheWindowClosesTheRecording() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        try take(noise(3))
        let first = try openID()
        advance(1_000)
        cloud.wentToBackground()
        XCTAssertNil(Contributions.recorder.current, "closed in the window")
        let item = try await settle(cloud, first)
        XCTAssertEqual(item.completed, true)
        XCTAssertEqual(item.takes, 1)
        try checkStream(server.segments(first).reduce(Data(), +), rate: 16_000, input48: 144_000, "closed by the background")

        // in the foreground again, inside what was the window: a new recording
        cloud.cameToForeground()
        advance(500)
        try take(noise(3))
        let second = try openID()
        XCTAssertNotEqual(first, second)
        // the background during the next take: the take keeps its recording, which closes when it ends
        advance(600)
        let t = start()
        try push(t, noise(1))
        cloud.wentToBackground()
        XCTAssertEqual(try openID(), second)
        try push(t, noise(1))
        end(t)
        XCTAssertNil(Contributions.recorder.current, "closed with the take")
        let joined = try await settle(cloud, second)
        XCTAssertEqual(joined.takes, 2)
        XCTAssertEqual(joined.durationMs, 5_000)
        XCTAssertEqual(server.takes.withLock { $0[second] }, maps((0, 0), (3_000, 600)))
        try checkStream(server.segments(second).reduce(Data(), +), rate: 16_000, input48: 240_000, "closed with the take")
        XCTAssertEqual(SharingTests.starts.count, 2)
        cloud.cameToForeground()
    }

    /// The signed config's `flags.share_join_ms`: 0 never joins, 8000 joins up to 8 s apart, anything invalid is 3000.
    func testTheConfigSetsTheJoinWindow() async throws {
        let server = SharingTests.Server()
        server.joinWindow.withLock { $0 = 0 }
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        XCTAssertEqual(cloud.currentConfig?.flags.share_join_ms, 0)
        // window 0: every take has its own recording, as in 2.0.2; it stays open only for its tail (SDK 3.0.0)
        try take(noise(2.5))
        windowPasses(ShareFeed.tailWaitMs)
        XCTAssertNil(Contributions.recorder.current, "window 0: no take joins, and no feed came")
        try take(noise(2.5))
        windowPasses(ShareFeed.tailWaitMs)
        XCTAssertNil(Contributions.recorder.current)
        try await waitUntil("two recordings uploaded") {
            let items = await cloud.outbox.items
            return items.count == 2 && items.allSatisfy { $0.status == .uploaded }
        }
        var items = await cloud.outbox.items
        XCTAssertEqual(items.map(\.takes), [1, 1])
        XCTAssertEqual(SharingTests.starts.count, 2)

        server.joinWindow.withLock { $0 = 8_000 }
        _ = await cloud.refreshConfig()
        XCTAssertEqual(cloud.currentConfig?.flags.share_join_ms, 8_000)
        try take(noise(2.5))
        advance(7_000)
        try take(noise(2.5))
        let joined = try openID()
        advance(8_001)
        try take(noise(2.5))
        let apart = try openID()
        XCTAssertNotEqual(joined, apart)
        windowPasses(8_000)
        let two = try await settle(cloud, joined)
        XCTAssertEqual(two.takes, 2)
        XCTAssertEqual(server.takes.withLock { $0[joined] }, maps((0, 0), (2_500, 7_000)))
        let one = try await settle(cloud, apart)
        XCTAssertEqual(one.takes, 1)

        // not a whole number from 0 to 10000: the default, 3000
        let invalid: [Any] = ["5", 20_000, 2.5, true]
        for bad in invalid {
            server.joinWindow.withLock { $0 = bad }
            _ = await cloud.refreshConfig()
            XCTAssertEqual(cloud.currentConfig?.flags.share_join_ms, 3_000, "share_join_ms \(bad)")
        }
        try take(noise(2.5))
        advance(3_000)
        try take(noise(2.5))
        let third = try openID()
        advance(3_001)
        try take(noise(2.5))
        XCTAssertNotEqual(try openID(), third)
        windowPasses()
        let last = try await settle(cloud, third)
        XCTAssertEqual(last.takes, 2)
        XCTAssertEqual(server.takes.withLock { $0[third] }, maps((0, 0), (2_500, 3_000)))
        items = await cloud.outbox.items
        XCTAssertEqual(items.count, 6)
    }

    /// What a recording is bound to, through the client: another input rate, model revision, consent version or
    /// contributor starts a new recording even inside the window; the backend may change.
    func testATakeJoinsOnlyTheSameRateRevisionConsentAndContributor() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        try take(noise(2.5))
        let first = try openID()
        advance(500)
        // another backend: the same recording (the session JSON keeps the first take's)
        let t = start(backend: .neuralEngine)
        try push(t, noise(2.5))
        end(t)
        XCTAssertEqual(try openID(), first)
        advance(500)
        try take(noise(2.5, rate: 48_000), rate: 48_000)
        let rate = try openID()
        XCTAssertNotEqual(first, rate, "another input rate")
        advance(500)
        try take(noise(2.5, rate: 48_000), rate: 48_000, revision: "other-rev")
        let revision = try openID()
        XCTAssertNotEqual(rate, revision, "another model revision")
        advance(500)
        _ = Contributions.update { $0.consentVersion = "share-2026-11-01" }
        try take(noise(2.5, rate: 48_000), rate: 48_000, revision: "other-rev")
        let consent = try openID()
        XCTAssertNotEqual(revision, consent, "another consent version")
        advance(500)
        QuranLab.resetContributor()
        try take(noise(2.5, rate: 48_000), rate: 48_000, revision: "other-rev")
        let contributor = try openID()
        XCTAssertNotEqual(consent, contributor, "another contributor")
        windowPasses()
        var counts: [Int] = []
        for id in [first, rate, revision, consent, contributor] { counts.append(try await settle(cloud, id).takes) }
        XCTAssertEqual(counts, [2, 1, 1, 1, 1])
        var sessions: [String: [String: Any]] = [:]
        for s in SharingTests.starts {
            if let id = s.headers["x-qlab-id"], let json = s.json { sessions[id] = json }
        }
        XCTAssertEqual(sessions.count, 5)
        XCTAssertEqual((sessions[first]?["decode"] as? [String: Any])?["backend"] as? String, "exact", "the first take's backend")
        XCTAssertEqual((sessions[revision]?["decode"] as? [String: Any])?["model_revision"] as? String, "other-rev")
        XCTAssertEqual(sessions[consent]?["consent_version"] as? String, "share-2026-11-01")
        XCTAssertNotEqual(sessions[consent]?["contributor"] as? String, sessions[contributor]?["contributor"] as? String)
        XCTAssertEqual(server.takes.withLock { $0[first] }, maps((0, 0), (2_500, 500)))
        XCTAssertEqual(StubProtocol.seen.filter { $0.path.hasSuffix("/takes") }.count, 1)
    }

    /// The rest keeps working for a recording that spans takes: its segments upload while it waits for the next take
    /// (the next batch of URLs as for a running session), an offline one goes in order after a relaunch, a finished
    /// take's ask moment leaves the recording open, the thank-you comes once.
    func testUploadsAndTheAskMomentAcrossTakes() async throws {
        let server = SharingTests.Server(batch: 6)
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        try take(noise(12))
        let id = try openID()
        try await waitUntil("the first segment in R2 and the next batch of URLs") {
            server.segments(id).count == 1 && !SharingTests.urlCalls(id).isEmpty
        }
        let waiting = await cloud.outbox.item(id)
        XCTAssertEqual(waiting?.status, .queued, "the first segment is up while the recording waits for a take")
        XCTAssertNil(waiting?.completed)
        XCTAssertEqual(SharingTests.urlCalls(id), [7], "segment 1 used, 5 left: the next batch, as for a session that runs")
        XCTAssertTrue(SharingTests.takeCalls(id).isEmpty)
        XCTAssertNil(Contributions.sessionCompleted(feedback: true), "a learner who said yes is not asked")
        XCTAssertEqual(try openID(), id, "the ask moment of a finished take left the recording open")
        advance(2_000)
        try take(noise(13))
        XCTAssertNil(Contributions.sessionCompleted(feedback: true))
        advance(2_900)
        try take(noise(10))
        XCTAssertEqual(try openID(), id)
        windowPasses()
        let item = try await settle(cloud, id)
        XCTAssertEqual(item.takes, 3)
        XCTAssertEqual(item.segments, 3)
        XCTAssertEqual(item.durationMs, 35_000)
        XCTAssertEqual(SharingTests.puts.map(\.path), (1...3).map { "/qlab-contributions/v1/\(id)/seg-0000\($0).opus" })
        XCTAssertEqual(SharingTests.starts.count, 1)
        XCTAssertEqual(server.takes.withLock { $0[id] }, maps((0, 0), (12_000, 2_000), (25_000, 2_900)))
        try checkStream(server.segments(id).reduce(Data(), +), rate: 16_000, input48: 35 * 48_000, "three takes, three segments")
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .thanks, "the thank-you, once the recording was shared")
        XCTAssertNil(Contributions.sessionCompleted(feedback: true), "once")

        // offline through three takes, then a new process: everything is on disk, sent in order, then the take list
        server.down.withLock { $0 = true }
        try take(noise(12))
        advance(1_000)
        try take(noise(13))
        advance(1_000)
        try take(noise(10))
        let off = try openID()
        windowPasses()
        try await waitUntil("the recording waits offline") {
            let i = await cloud.outbox.item(off)
            return i?.completed == true && i?.lastError != nil
        }
        // that process ends while the network is still down; the next launch finds the network back, and the request
        // log from here on is its own
        let disk = try await retire(cloud)
        server.down.withLock { $0 = false }
        StubProtocol.reset(server.handler)
        let next = await configure(server, storage: disk)
        let done = try await settle(next, off)
        XCTAssertEqual(done.takes, 3)
        let sent = StubProtocol.seen.filter { $0.path.contains(off) || $0.headers["x-qlab-id"] == off }.map { "\($0.method) \($0.url.lastPathComponent)" }
        XCTAssertEqual(sent, ["POST uploads", "PUT seg-00001.opus", "PUT seg-00002.opus", "PUT seg-00003.opus", "POST takes"])
        XCTAssertEqual(server.takes.withLock { $0[off] }, maps((0, 0), (12_000, 1_000), (25_000, 1_000)))
    }
}
