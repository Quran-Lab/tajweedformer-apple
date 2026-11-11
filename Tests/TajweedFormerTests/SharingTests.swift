import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

final class SharingTests: XCTestCase {
    /// A stub qlab-api and R2 for sharing: the start and URL routes, and the PUTs to presigned URLs,
    /// whose bodies it keeps. Each batch's URLs carry `X-Amz-Signature=b<batch>-<n>`, so a test can
    /// tell which batch a PUT used. `batch` is the URLs per answer; `put` can refuse a PUT (per
    /// attempt, 1-based). Since 2.0.3 it has the take list route (`POST /v1/uploads/{id}/takes`) as the server checks
    /// it, and can put `flags.share_join_ms` into the signed config.
    final class Server: @unchecked Sendable {
        let token: StubProtocol.Reply
        let flags: [String: Any]
        let start = Locked<(Int) -> StubProtocol.Reply?>({ _ in nil })
        let put = Locked<(Int) -> StubProtocol.Reply?>({ _ in nil })
        let down = Locked(false)
        let objects = Locked<[String: Data]>([:])
        let batches = Locked(0)
        let batch: Int
        /// The take list route. Off: a server without it (404 `not_found`).
        let takesRoute = Locked(true)
        /// An answer that replaces the take list route's, per call (1-based, counted over every upload).
        let takesReply = Locked<(Int) -> StubProtocol.Reply?>({ _ in nil })
        /// The take list the server holds per upload id (the last one sent replaces the earlier).
        let takes = Locked<[String: [[String: Int]]]>([:])
        /// The contributor of each upload the server has a session JSON for.
        let started = Locked<[String: String]>([:])
        /// `flags.share_join_ms` of the signed config (any JSON value); nil leaves the flag out.
        let joinWindow = Locked<Any?>(nil)

        init(token: StubProtocol.Reply = CloudFixtures.attestedToken, flags: [String: Any] = [:], batch: Int = 20) {
            self.token = token
            self.flags = flags
            self.batch = batch
        }

        /// Milliseconds of audio the server holds for an upload: its last page's granule position less the pre-skip.
        func receivedMs(_ id: String) -> Int {
            let b = [UInt8](segments(id).reduce(Data(), +))
            var at = 0
            var granule: Int64 = 0
            while at + 27 <= b.count {
                let n = Int(b[at + 26])
                var len = 27 + n
                for i in 0..<n { len += Int(b[at + 27 + i]) }
                var g: Int64 = 0
                for i in 0..<8 { g |= Int64(b[at + 6 + i]) << (8 * Int64(i)) }
                granule = g
                at += len
            }
            return Int(max(0, granule - 312) / 48)
        }

        /// `POST /v1/uploads/{id}/takes` as the server checks it: the token and `x-qlab-contributor`, the upload known
        /// under that contributor (404 `not_found` otherwise), a closed body `{"takes":[{"start_ms","gap_ms"}]}` of 2
        /// to 256 entries, the first `{0, 0}`, `start_ms` strictly increasing and no further than the received audio
        /// plus 1000 ms, `gap_ms` 0 to 10000 in hundreds. The list replaces any earlier one; 204.
        func takeList(_ s: StubProtocol.Seen) -> StubProtocol.Reply {
            func bad(_ why: String) -> StubProtocol.Reply { .json(["error": "invalid_body", "message": why], status: 400) }
            let id = String(s.path.dropFirst("/v1/uploads/".count).prefix(32))
            guard s.headers["authorization"]?.hasPrefix("Bearer qlt_v1.") == true else {
                return .json(["error": "unauthorized", "message": "unauthorized"], status: 401)
            }
            guard let who = s.headers["x-qlab-contributor"], who.count == 32 else { return bad("x-qlab-contributor") }
            guard started.withLock({ $0[id] }) == who else { return .json(["error": "not_found", "message": "not_found"], status: 404) }
            guard let o = s.json, o.count == 1, let list = o["takes"] as? [[String: Any]], (2...256).contains(list.count) else {
                return bad("json.takes")
            }
            let received = receivedMs(id)
            var out: [[String: Int]] = []
            var last = -1
            for (i, t) in list.enumerated() {
                guard t.count == 2, let at = t["start_ms"] as? Int, let gap = t["gap_ms"] as? Int else { return bad("json.takes[\(i)]") }
                if i == 0, at != 0 || gap != 0 { return bad("json.takes[0]: 0, 0") }
                if i > 0, at <= last { return bad("json.takes[\(i)].start_ms: not increasing") }
                if at > received + 1000 { return bad("json.takes[\(i)].start_ms: past the received audio (\(received) ms)") }
                if gap < 0 || gap > 10_000 || gap % 100 != 0 { return bad("json.takes[\(i)].gap_ms") }
                last = at
                out.append(["start_ms": at, "gap_ms": gap])
            }
            takes.withLock { $0[id] = out }
            return StubProtocol.Reply(status: 204, headers: [:])
        }

        func urls(_ id: String, from: Int, status: Int) -> StubProtocol.Reply {
            let b = batches.withLock { $0 += 1; return $0 }
            let exp = Int(Date().timeIntervalSince1970) + 604_800
            let list: [[String: Any]] = (from..<(from + batch)).map { n in
                ["n": n, "expires_at": exp,
                 "url": "https://r2.test/qlab-contributions/v1/\(id)/\(ShareFiles.name(n)).opus?X-Amz-Algorithm=AWS4-HMAC-SHA256"
                     + "&X-Amz-Expires=604800&X-Amz-SignedHeaders=content-type%3Bhost&X-Amz-Signature=b\(b)-\(n)"]
            }
            return .json(["id": id, "urls": list], status: status)
        }

        var handler: @Sendable (StubProtocol.Seen) -> StubProtocol.Reply {
            CloudFixtures.server(config: CloudFixtures.config(flags: flags), token: token, extra: { [self] s in
                if down.withLock({ $0 }), s.url.host == "r2.test" || s.path.hasPrefix("/v1/uploads") { return .down }
                if s.path == "/v1/config", let w = joinWindow.withLock({ $0 }) {
                    return CloudFixtures.config(flags: flags.merging(["share_join_ms": w]) { _, b in b })
                }
                if s.method == "POST", s.path.hasPrefix("/v1/uploads/"), s.path.hasSuffix("/takes") {
                    let n = StubProtocol.seen.filter { $0.path.hasSuffix("/takes") }.count
                    if let r = takesReply.withLock({ $0(n) }) { return r }
                    guard takesRoute.withLock({ $0 }) else { return .json(["error": "not_found", "message": "not_found"], status: 404) }
                    return takeList(s)
                }
                if s.url.host == "r2.test", s.method == "PUT" {
                    let n = SharingTests.puts.count
                    if let r = put.withLock({ $0(n) }) { return r }
                    objects.withLock { $0[String(s.path.dropFirst("/qlab-contributions/".count))] = s.body }
                    return StubProtocol.Reply(status: 200, headers: [:])
                }
                if s.method == "POST", s.path == "/v1/uploads" {
                    let n = StubProtocol.seen("/v1/uploads").count
                    if let r = start.withLock({ $0(n) }) { return r }
                    if let id = s.headers["x-qlab-id"], let who = s.json?["contributor"] as? String { started.withLock { $0[id] = who } }
                    return urls(s.headers["x-qlab-id"] ?? "", from: 1, status: 201)
                }
                if s.method == "POST", s.path.hasPrefix("/v1/uploads/"), s.path.hasSuffix("/urls") {
                    let from = URLComponents(url: s.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "from" }?.value
                    return urls(String(s.path.dropFirst("/v1/uploads/".count).prefix(32)), from: Int(from ?? "") ?? 0, status: 200)
                }
                return nil
            })
        }

        /// The segments of upload `id` in R2, in order.
        func segments(_ id: String) -> [Data] {
            objects.withLock { o in o.keys.filter { $0.hasPrefix("v1/\(id)/seg-") }.sorted().map { o[$0]! } }
        }
    }

    static var puts: [StubProtocol.Seen] { StubProtocol.seen.filter { $0.url.host == "r2.test" && $0.method == "PUT" } }
    /// The batch and segment a PUT's URL came from ("b1-2").
    static func signature(_ p: StubProtocol.Seen) -> String? {
        URLComponents(url: p.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "X-Amz-Signature" }?.value
    }
    /// The `from` of each /urls call for upload `id`.
    static func urlCalls(_ id: String) -> [Int] {
        StubProtocol.seen("/v1/uploads/\(id)/urls").compactMap {
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "from" }?.value.flatMap(Int.init)
        }
    }
    static var starts: [StubProtocol.Seen] { StubProtocol.seen("/v1/uploads") }
    /// Every take list call for upload `id`, in order (2.0.3).
    static func takeCalls(_ id: String) -> [StubProtocol.Seen] { StubProtocol.seen("/v1/uploads/\(id)/takes") }

    override func tearDown() {
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// A configured cloud (stub network) in `storage`: the developer's `contributions` option, and the learner's
    /// answer on the consent sheet (`consent`).
    func configure(_ server: Server, sharing: Bool = true, consent: Bool = true, storage: URL = CloudFixtures.storage()) async -> QuranLabCloud {
        let options = CloudFixtures.options(contributions: sharing, storage: storage)
        let cloud = CloudFixtures.cloud(storage: storage, options: options)
        _ = await cloud.refreshConfig()
        QuranLab.configure(key: CloudFixtures.key, options: options, cloud: cloud)
        if consent { Contributions.answer(share: true) }
        return cloud
    }

    /// Audio with a few awkward samples (out of range, NaN, infinite) among a tone and noise.
    static func audio(_ n: Int, seed: Int = 1) -> [Float] {
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { i in
            switch (i + seed) % 997 {
            case 0: return 1.7
            case 1: return -3
            case 2: return -0.0
            case 3: return 1e-9
            case 4: return .nan
            case 5: return -.infinity
            default: return Float(sin(Double(i) * 0.011 * Double(seed))) * 0.6 + Float.random(in: -0.2...0.2, using: &g)
            }
        }
    }

    /// One session's sharing as a take drives it: the capture the SDK makes at `startTake`, fed as audio arrives.
    final class Take {
        let capture: ShareCapture?
        init(_ c: ShareCapture?) { capture = c }
        func finish() async { capture?.finish(completed: true) }
        func cancel() async { capture?.finish(completed: false) }
    }

    /// A session over `seconds` of audio at `rate`, ended by `end` ("finish", "cancel", or "open": left running; the
    /// caller ends it).
    @discardableResult
    func session(seconds: Double, rate: Double = 48_000, end: String = "finish") async throws -> Take {
        let t = Take(Contributions.capture(revision: "test-rev", backend: .exact, weightsSHA256: nil))
        let n = Int(rate * seconds)
        var at = 0
        while at < n {
            let k = min(Int(rate / 10), n - at)
            try t.capture?.append(Self.audio(k, seed: at + 1), rate: rate)
            at += k
        }
        switch end {
        case "cancel": await t.cancel()
        case "open": break
        default: await t.finish()
        }
        return t
    }

    /// Waits until the outbox holds `count` items that satisfy `done`.
    @discardableResult
    func settle(_ outbox: ContributionOutbox, count: Int = 1, _ done: @escaping (Contribution) -> Bool = { $0.status == .uploaded },
                timeout: TimeInterval = 15) async throws -> [Contribution] {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let items = await outbox.items
            if items.count == count, items.allSatisfy(done) { return items }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let items = await outbox.items
        XCTFail("outbox did not settle: \(items)")
        return items
    }

    static func temp(_ ext: String = "opus") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("zf-\(UUID().uuidString).\(ext)")
    }

    // MARK: Ogg Opus


    struct Page {
        let flags: UInt8
        let granule: Int64
        let sequence: UInt32
        let packets: [Data]
    }

    /// Reads every Ogg page, checking the capture pattern and each page's CRC.
    static func pages(_ d: Data) throws -> [Page] {
        let b = [UInt8](d)
        var at = 0, out: [Page] = []
        func le<T: FixedWidthInteger>(_ o: Int, _: T.Type) -> T {
            (0..<MemoryLayout<T>.size).reduce(T(0)) { $0 | T(b[o + $1]) << (8 * $1) }
        }
        while at < b.count {
            XCTAssertEqual(Array(b[at..<at + 4]), Array("OggS".utf8))
            let n = Int(b[at + 26])
            let lacing = b[(at + 27)..<(at + 27 + n)]
            var len = 27 + n + lacing.reduce(0) { $0 + Int($1) }
            var page = Data(b[at..<(at + len)])
            let crc: UInt32 = le(at + 22, UInt32.self)
            page.replaceSubrange(22..<26, with: [0, 0, 0, 0])
            XCTAssertEqual(OggOpusWriter.crc(page), crc, "page CRC")
            var packets: [Data] = [], cur = Data(), o = at + 27 + n
            for l in lacing {
                cur.append(contentsOf: b[o..<(o + Int(l))])
                o += Int(l)
                if l < 255 { packets.append(cur); cur = Data() }
            }
            out.append(Page(flags: b[at + 5], granule: le(at + 6, Int64.self), sequence: le(at + 18, UInt32.self), packets: packets))
            len = o - at
            at += len
        }
        return out
    }

    func testOggOpusFollowsRFC7845() throws {
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("zf-\(UUID().uuidString).opus")
            defer { try? FileManager.default.removeItem(at: url) }
            let w = try OggOpusWriter(url: url, inputRate: rate)
            let n = Int(rate * 3.37)
            var at = 0
            while at < n {
                let k = min(Int.random(in: 1...5_000), n - at)
                try w.append((0..<k).map { Float(sin(Double(at + $0) * 2 * .pi * 440 / rate)) * 0.3 })
                at += k
            }
            let ms = try w.finish()
            XCTAssertEqual(ms, 3370)
            let pages = try Self.pages(try Data(contentsOf: url))
            XCTAssertEqual(pages.map(\.sequence), (0..<UInt32(pages.count)).map { $0 })
            XCTAssertEqual(pages[0].flags, 0x02)
            let head = pages[0].packets[0]
            XCTAssertEqual(head.prefix(8), Data("OpusHead".utf8))
            XCTAssertEqual(head[9], 1, "mono")
            let preSkip = Int(head[10]) | Int(head[11]) << 8
            XCTAssertEqual(preSkip, 312)
            XCTAssertEqual(head[12..<16].reversed().reduce(0) { $0 << 8 | Int($1) }, Int(rate), "OpusHead: the true input rate")
            XCTAssertEqual(pages[1].packets[0].prefix(8), Data("OpusTags".utf8))
            XCTAssertEqual(pages.last?.flags, 0x04)
            let audio = pages.dropFirst(2)
            var packets = 0
            var last: Int64 = 0
            for p in audio {
                packets += p.packets.count
                XCTAssertGreaterThanOrEqual(p.granule, last)
                last = p.granule
                if p.flags != 0x04 {
                    XCTAssertEqual(p.granule, Int64(packets * 960))
                    XCTAssertEqual(p.packets.count, 50, "a page is a second of packets")
                }
            }
            XCTAssertEqual(try OpusTestDecoder.decode(try Data(contentsOf: url)).count, Int(3.37 * 48_000), "decoded length")
            XCTAssertEqual(pages.last!.granule - Int64(preSkip), Int64(3.37 * 48_000), "the last granule trims to the input length")
            XCTAssertGreaterThanOrEqual(packets * 960, preSkip + Int(3.37 * 48_000))
            // an independent decoder agrees, when ffmpeg is installed
            if let d = try? Self.ffprobeDuration(url) { XCTAssertEqual(d, 3.37, accuracy: 0.001) }
        }
    }

    /// The duration an independent decoder (ffmpeg, when installed) gets: the decoded 48 kHz
    /// samples, after pre-skip and end trimming.
    static func ffprobeDuration(_ url: URL) throws -> Double {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        p.arguments = ["-v", "error", "-i", url.path, "-f", "f32le", "-ac", "1", "-ar", "48000", "-"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return Double(data.count / 4) / 48_000
    }

    /// Opus size per minute on the parity clips (16 kHz), and one upsampled to 48 kHz first.
    func testOpusSizePerMinuteOnTheParityClips() throws {
        guard let dir = try? Fixtures.audioDirectory() else { throw XCTSkip("no parity clips") }
        let clips = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".pcm") }.sorted()
        var bytes = 0, seconds = 0.0
        for c in clips {
            let x = try Fixtures.samples(String(c.dropLast(4)))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("zf-\(UUID().uuidString).opus")
            defer { try? FileManager.default.removeItem(at: url) }
            let w = try OggOpusWriter(url: url, inputRate: 16_000)
            try w.append(x)
            try w.finish()
            bytes += try Data(contentsOf: url).count
            seconds += Double(x.count) / 16_000
        }
        print(String(format: "opus: %d clips, %.1f s, %d bytes, %.0f kB per minute, %.1f kbps", clips.count, seconds, bytes,
                     Double(bytes) / seconds * 60 / 1000, Double(bytes) * 8 / seconds / 1000))
        // one clip upsampled to 48 kHz (linear interpolation) before the encoder
        let x = try Fixtures.samples(String(clips[0].dropLast(4)))
        let up = (0..<(x.count * 3)).map { i -> Float in
            let j = i / 3, f = Float(i % 3) / 3
            return x[j] * (1 - f) + (j + 1 < x.count ? x[j + 1] : 0) * f
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zf-\(UUID().uuidString).opus")
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try OggOpusWriter(url: url, inputRate: 48_000)
        try w.append(up)
        try w.finish()
        let n = try Data(contentsOf: url).count, s = Double(up.count) / 48_000
        print(String(format: "opus 48 kHz input (%@): %.1f s, %d bytes, %.0f kB per minute, %.1f kbps", clips[0], s, n,
                     Double(n) / s * 60 / 1000, Double(n) * 8 / s / 1000))
        XCTAssertLessThan(Double(bytes) * 8 / seconds, 260_000)
    }


    /// Segments of 10, 20, 40, then 60 s, cut at page boundaries: concatenated they are byte for
    /// byte the one-file encode of the same input, and a valid stream.
    func testSegmentsConcatenateToTheOneFileByteForByte() throws {
        let rate = 16_000.0
        let input = (0..<Int(rate * 157.3)).map { (i: Int) -> Float in
            let tone = Float(sin(Double(i) * 0.013)) * 0.4
            let noise = Float((i * 7919) % 97) / 970
            return tone + noise - 0.05
        }
        let one = Self.temp()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zf-seg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: one); try? FileManager.default.removeItem(at: dir) }
        let a = try OggOpusWriter(url: one, inputRate: rate, serial: 42)
        var closed: [OggSegment] = []
        let b = try OggOpusWriter(segmentURL: { dir.appendingPathComponent(String(format: "seg-%05d.opus", $0)) },
                                  plan: SegmentPlan.seconds, inputRate: rate, serial: 42) { closed.append($0) }
        var at = 0
        while at < input.count {
            let k = min(Int.random(in: 100...4_000), input.count - at)
            try a.append(Array(input[at..<(at + k)]))
            try b.append(Array(input[at..<(at + k)]))
            at += k
        }
        XCTAssertEqual(try a.finish(), try b.finish())
        // 10 + 20 + 40 + 60 s, then the rest (27.3 s) with the end of the stream
        XCTAssertEqual(closed.map(\.n), [1, 2, 3, 4, 5])
        XCTAssertEqual(closed.map(\.last), [false, false, false, false, true])
        let parts = try closed.map { try Data(contentsOf: $0.url) }
        XCTAssertEqual(parts.reduce(Data(), +), try Data(contentsOf: one), "the segments are the one file, byte for byte")
        let pages = try parts.map { try Self.pages($0) }
        let audio = pages.map { $0.filter { $0.packets.first?.starts(with: Data("Opus".utf8)) != true } }
        XCTAssertEqual(audio.map { $0.reduce(0) { $0 + $1.packets.count } }, [500, 1_000, 2_000, 3_000, 1_366],
                       "10, 20, 40, 60 s of packets, then the rest (27.3 s and the lookahead)")
        XCTAssertEqual(audio.map(\.count), [10, 20, 40, 60, 28], "one-second pages")
        XCTAssertEqual(pages[0][0].packets[0].prefix(8), Data("OpusHead".utf8))
        for p in pages.dropFirst() { XCTAssertFalse(p[0].packets[0].starts(with: Data("OpusHead".utf8))) }
        XCTAssertEqual(pages.last?.last?.flags, 0x04)
        XCTAssertEqual(closed.last?.granule, 312 + Int64(157.3 * 48_000))
        if let d = try? Self.ffprobeDuration(one) { XCTAssertEqual(d, 157.3, accuracy: 0.001) }
    }

    // MARK: sharing

    func testNothingIsCapturedBeforeTheLearnerSaysShare() async throws {
        // 2.0.1: the config offers sharing (the app's option is ignored); the learner has not answered
        let server = Server()
        StubProtocol.reset(server.handler)
        let cloud = await configure(server, sharing: false, consent: false)
        try await session(seconds: 12)
        try await Task.sleep(nanoseconds: 200_000_000)
        let n = await cloud.outbox.items.count
        XCTAssertEqual(n, 0)
        XCTAssertTrue(Self.starts.isEmpty && Self.puts.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.outbox.root.path), [])
    }

    /// A 25 s session at 48 kHz: the start (the session JSON, answered with URLs), two segments PUT
    /// straight to R2, each to its own presigned URL, while and after it runs, nothing else; the
    /// segments are the session's whole audio, ending the stream.
    func testASharedSessionStreamsItsSegmentsToR2() async throws {
        let server = Server()
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        try await session(seconds: 25)
        let item = try await settle(cloud.outbox)[0]
        XCTAssertEqual(item.segments, 2)
        XCTAssertEqual(item.durationMs, 25_000)
        XCTAssertEqual(item.completed, true)

        XCTAssertEqual(Self.starts.count, 1)
        let start = try XCTUnwrap(Self.starts.first)
        XCTAssertEqual(start.headers["authorization"], "Bearer qlt_v1.eyJ2IjoxfQ.att")
        XCTAssertEqual(start.headers["x-qlab-id"], item.id)
        let meta = try XCTUnwrap(start.json)
        XCTAssertEqual(Set(meta.keys), ["format", "audio", "decode", "consent_version", "contributor", "day", "device_class", "os_major",
                                        "contributor_key", "recovery_hash"])
        XCTAssertEqual((meta["contributor_key"] as? String).flatMap { Data(base64URL: $0) }?.count, 65, "the device key's 65-byte point")
        XCTAssertEqual((meta["recovery_hash"] as? String)?.count, 64)
        XCTAssertEqual(meta["consent_version"] as? String, Contributions.copy.consentVersion)
        XCTAssertEqual(meta["contributor"] as? String, QuranLab.contributorID)
        XCTAssertEqual(meta["day"] as? String, Day.string())
        XCTAssertEqual(meta["os_major"] as? Int, DeviceContext.osMajor)
        XCTAssertEqual(meta["audio"] as? [String: AnyHashable], ["codec": "opus", "container": "ogg", "sample_rate": 48_000, "channels": 1,
                                                                 "input_sample_rate": 48_000, "input_route": AnyHashable(AudioRoute.current())])
        let decode = try XCTUnwrap(meta["decode"] as? [String: Any])
        XCTAssertEqual(Set(decode.keys), ["model_revision", "backend", "weights_sha256", "sdk_version"])
        XCTAssertEqual(decode["backend"] as? String, "exact")
        XCTAssertEqual(decode["model_revision"] as? String, "test-rev")

        let puts = Self.puts
        XCTAssertEqual(puts.map(\.path), ["/qlab-contributions/v1/\(item.id)/seg-00001.opus", "/qlab-contributions/v1/\(item.id)/seg-00002.opus"])
        XCTAssertEqual(puts.map { Self.signature($0) }, ["b1-1", "b1-2"], "each segment on its own URL from the start's batch")
        for p in puts {
            XCTAssertEqual(p.headers["content-type"], "audio/ogg")
            XCTAssertNil(p.headers["authorization"], "a plain PUT: the URL carries the signature")
            XCTAssertFalse(p.headers.keys.contains { $0.lowercased().hasPrefix("x-amz-") })
        }
        XCTAssertEqual(StubProtocol.seen.filter { $0.path.hasPrefix("/v1/uploads") }.count, 1, "the Worker is called once")
        let segs = server.segments(item.id)
        let pages = try segs.map { try Self.pages($0) }
        XCTAssertEqual(pages[0].filter { $0.flags & 0x02 == 0 && $0.packets.first?.starts(with: Data("OpusTags".utf8)) != true }.count, 10)
        XCTAssertEqual(pages.last?.last?.flags, 0x04, "the last page ends the stream")
        let url = Self.temp()
        defer { try? FileManager.default.removeItem(at: url) }
        try segs.reduce(Data(), +).write(to: url)
        XCTAssertEqual(pages.last!.last!.granule - 312, 25 * 48_000)
        if let d = try? Self.ffprobeDuration(url) { XCTAssertEqual(d, 25, accuracy: 0.001) }
        let left = try FileManager.default.contentsOfDirectory(atPath: cloud.outbox.root.appendingPathComponent(item.id).path)
        XCTAssertFalse(left.contains { $0.hasSuffix(".opus") }, "the audio goes once uploaded")
    }

    /// A session from a 44.1 kHz input: coded at 48 kHz, and the header and OpusHead both say the
    /// audio was captured at 44.1 kHz.
    func testA441kHzSessionRecordsItsInputRate() async throws {
        let server = Server()
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        try await session(seconds: 12, rate: 44_100)
        let item = try await settle(cloud.outbox)[0]
        XCTAssertEqual(item.durationMs, 12_000)
        let audio = try XCTUnwrap(try XCTUnwrap(Self.starts.first?.json)["audio"] as? [String: AnyHashable])
        XCTAssertEqual(audio["sample_rate"], 48_000)
        XCTAssertEqual(audio["input_sample_rate"], 44_100)
        // the audio session's input on iOS, the default input device's transport on the Mac
        XCTAssertEqual(audio["input_route"], AnyHashable(AudioRoute.current()))
        let segs = server.segments(item.id)
        let head = try Self.pages(segs[0])[0].packets[0]
        XCTAssertEqual(head[12..<16].reversed().reduce(0) { $0 << 8 | Int($1) }, 44_100)
        let whole = segs.reduce(Data(), +)
        XCTAssertEqual(try OpusTestDecoder.decode(whole).count, 12 * 48_000)
    }

    /// A cancelled session under two seconds never reaches the server; a longer one is shared.
    func testShortCancelledSessionsStayLocal() async throws {
        let server = Server()
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        try await session(seconds: 1.5, end: "cancel")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(Self.starts.isEmpty && Self.puts.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.outbox.root.path), [])
        try await session(seconds: 2.5, rate: 16_000, end: "cancel")
        let item = try await settle(cloud.outbox)[0]
        XCTAssertEqual(item.completed, false)
        XCTAssertEqual(item.durationMs, 2500)
        XCTAssertEqual(Self.puts.count, 1)
    }

    func testTheConfigFlagSwitchesSharingOff() async throws {
        let server = Server(flags: ["contributions": false])
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        try await session(seconds: 3)
        try await Task.sleep(nanoseconds: 200_000_000)
        let n = await cloud.outbox.items.count
        XCTAssertEqual(n, 0)
    }

    /// A URL that R2 refuses (expired: 403 "Request has expired") is replaced by fresh URLs from
    /// the same segment, and the PUT is sent again on the new one.
    func testAnExpiredURLIsRenewed() async throws {
        let server = Server()
        StubProtocol.reset(server.handler)
        let expired = "<Error><Code>AccessDenied</Code><Message>Request has expired</Message></Error>"
        server.put.withLock { $0 = { n in n == 1 ? StubProtocol.Reply(status: 403, headers: [:], body: Data(expired.utf8)) : nil } }
        let cloud = await configure(server)
        try await session(seconds: 1)
        let item = try await settle(cloud.outbox)[0]
        XCTAssertEqual(Self.urlCalls(item.id), [1], "fresh URLs from the refused segment")
        XCTAssertEqual(StubProtocol.seen("/v1/uploads/\(item.id)/urls").first?.headers["x-qlab-contributor"], QuranLab.contributorID)
        XCTAssertEqual(Self.puts.map { Self.signature($0) }, ["b1-1", "b2-1"])
        XCTAssertEqual(server.segments(item.id).count, 1)
    }

    /// A URL the outbox holds as expired is never tried: fresh ones first.
    func testAURLPastItsExpiryIsNotUsed() async throws {
        let server = Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        server.down.withLock { $0 = true }
        let first = await configure(server, storage: storage)
        try await session(seconds: 1)
        let waiting = try await settle(first.outbox) { $0.lastError != nil }[0]
        // the start went through before the network dropped, with URLs that have since expired
        let folder = first.outbox.root.appendingPathComponent(waiting.id)
        let itemURL = folder.appendingPathComponent(ContributionOutbox.itemName)
        var o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: itemURL)) as? [String: Any])
        o["started"] = true
        o["urls"] = [["n": 1, "url": "https://r2.test/qlab-contributions/v1/\(waiting.id)/seg-00001.opus?X-Amz-Signature=old",
                      "expiresAt": Date().addingTimeInterval(-60).timeIntervalSinceReferenceDate]]
        try JSONSerialization.data(withJSONObject: o).write(to: itemURL)
        server.down.withLock { $0 = false }
        StubProtocol.reset(server.handler)
        let second = await configure(server, storage: storage)
        await second.outbox.drain(ignoringBackoff: true)
        let done = await second.outbox.item(waiting.id)
        XCTAssertEqual(done?.status, .uploaded)
        XCTAssertTrue(Self.starts.isEmpty, "the server has it: no second start")
        XCTAssertEqual(Self.urlCalls(waiting.id), [1])
        XCTAssertEqual(Self.puts.map { Self.signature($0) }, ["b1-1"])
    }

    /// While a session runs the outbox asks for the next batch once 5 unused URLs remain, so the
    /// following segments never wait for a Worker call; a finished session asks for nothing more.
    func testTheNextBatchComesWhenFiveRemain() async throws {
        let server = Server(batch: 6)
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        let running = try await session(seconds: 12, end: "open")
        let item = try await settle(cloud.outbox) { !SharingTests.urlCalls($0.id).isEmpty && SharingTests.puts.count == 1 }[0]
        XCTAssertEqual(Self.urlCalls(item.id), [7], "segment 1 used, 5 left: the batch from 7")
        await running.finish()
        let done = try await settle(cloud.outbox)[0]
        XCTAssertEqual(done.segments, 2)
        XCTAssertEqual(Self.urlCalls(item.id), [7])
        XCTAssertEqual(Self.puts.map { Self.signature($0) }, ["b1-1", "b1-2"])
        XCTAssertEqual(Self.starts.count, 1)
    }

    /// A segment past the URLs it holds (a small batch, and the session ended while offline so no
    /// next batch came) asks for URLs from that segment's number.
    func testASegmentWithoutAURLAsksFromItsNumber() async throws {
        let server = Server(batch: 1)
        StubProtocol.reset(server.handler)
        server.down.withLock { $0 = true }
        let cloud = await configure(server)
        try await session(seconds: 25)
        _ = try await settle(cloud.outbox) { $0.lastError != nil && $0.completed == true }
        server.down.withLock { $0 = false }
        await cloud.outbox.drain(ignoringBackoff: true)
        let item = try await settle(cloud.outbox)[0]
        XCTAssertEqual(item.segments, 2)
        XCTAssertEqual(Self.urlCalls(item.id), [2])
        XCTAssertEqual(Self.puts.map { Self.signature($0) }, ["b1-1", "b2-2"])
        XCTAssertEqual(server.segments(item.id).count, 2)
    }

    /// Offline for a whole session: the segments wait on disk, in order, and go when the network
    /// returns; a relaunch in between loses nothing.
    func testOfflineSegmentsWaitAndGoInOrder() async throws {
        let server = Server()
        StubProtocol.reset(server.handler)
        server.down.withLock { $0 = true }
        let storage = CloudFixtures.storage()
        let first = await configure(server, storage: storage)
        try await session(seconds: 35)
        let waiting = try await settle(first.outbox) { $0.lastError != nil && $0.completed == true }[0]
        XCTAssertEqual(waiting.status, .queued)
        XCTAssertEqual(waiting.segments, 3)
        server.down.withLock { $0 = false }
        let second = await configure(server, storage: storage)
        await second.outbox.drain(ignoringBackoff: true)
        let done = await second.outbox.item(waiting.id)
        XCTAssertEqual(done?.status, .uploaded)
        XCTAssertEqual(Self.puts.suffix(3).map(\.path),
                       (1...3).map { "/qlab-contributions/v1/\(waiting.id)/seg-0000\($0).opus" })
        XCTAssertEqual(server.segments(waiting.id).count, 3)
        let third = await configure(server, storage: storage)
        let before = Self.puts.count
        await third.outbox.drain(ignoringBackoff: true)
        XCTAssertEqual(Self.puts.count, before, "an uploaded session is never sent again")
    }

    /// The app is killed 13 s into a session (the second segment half written, a page torn): on
    /// the next launch the torn page is cut off, the segments go up, and nothing else is sent.
    /// The stream has no end page; the server marks such a session incomplete.
    func testAKilledSessionIsUploadedOnTheNextLaunch() async throws {
        let server = Server()
        StubProtocol.reset(server.handler)
        server.down.withLock { $0 = true }
        let first = await configure(server)
        let running = try await session(seconds: 13, end: "open")
        // the disk as the app left it when it was killed now
        let storage = CloudFixtures.storage()
        try FileManager.default.removeItem(at: storage)
        try FileManager.default.copyItem(at: first.storage, to: storage)
        await running.cancel()
        let killed = storage.appendingPathComponent("outbox")
        let folder = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: killed, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.count == 32 })
        let open = folder.appendingPathComponent("seg-00002.opus")
        let whole = try Data(contentsOf: open)
        XCTAssertGreaterThan(whole.count, 0)
        let h = try FileHandle(forWritingTo: open)
        try h.seekToEnd()
        try h.write(contentsOf: Data("OggS".utf8) + Data(repeating: 7, count: 100))
        try h.close()

        server.down.withLock { $0 = false }
        StubProtocol.reset(server.handler)
        let relaunched = await configure(server, storage: storage)
        await relaunched.outbox.drain(ignoringBackoff: true)
        let item = try await settle(relaunched.outbox) { $0.id == folder.lastPathComponent && $0.status == .uploaded }[0]
        XCTAssertEqual(item.completed, false)
        XCTAssertEqual(item.segments, 2)
        let segs = server.segments(item.id)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[1], whole, "the torn page is cut off, the whole pages stay")
        let pages = try segs.map { try Self.pages($0) }
        XCTAssertNotEqual(pages.last?.last?.flags, 0x04, "no end of stream: the session did not end")
        XCTAssertEqual(item.durationMs, Int((pages.last!.last!.granule - 312) / 48))
        let url = Self.temp()
        defer { try? FileManager.default.removeItem(at: url) }
        try segs.reduce(Data(), +).write(to: url)
        if let d = try? Self.ffprobeDuration(url) { XCTAssertEqual(d, Double(item.durationMs) / 1000, accuracy: 0.001) }
        XCTAssertEqual(Self.starts.count, 1)
    }

    func testTurningSharingOffCancelsQueuedUploads() async throws {
        let server = Server()
        StubProtocol.reset(server.handler)
        server.down.withLock { $0 = true }
        let cloud = await configure(server)
        try await session(seconds: 1)
        let queued = try await settle(cloud.outbox) { $0.lastError != nil }
        XCTAssertEqual(queued.map(\.status), [.queued])
        await Contributions.setSharing(false)
        XCTAssertEqual(Contributions.consent, .final)
        let left = await cloud.outbox.items
        XCTAssertTrue(left.isEmpty)
        try await session(seconds: 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        let still = await cloud.outbox.items
        XCTAssertTrue(still.isEmpty, "a session after sharing went off is not shared")
    }

    func testRefusalsFailForGood() async throws {
        let server = Server()
        StubProtocol.reset(server.handler)
        server.start.withLock { $0 = { _ in .json(["error": "invalid_body", "message": "body.format: out of range"], status: 400) } }
        let cloud = await configure(server)
        try await session(seconds: 1)
        let item = try await settle(cloud.outbox) { if case .failed = $0.status { return true } else { return false } }[0]
        XCTAssertEqual(item.status, .failed(code: "invalid_body", message: "body.format: out of range"))
        await cloud.outbox.drain(ignoringBackoff: true)
        XCTAssertEqual(Self.starts.count, 1, "a refused item is not retried")
        XCTAssertTrue(Self.puts.isEmpty)

        let unattested = Server(token: CloudFixtures.token)
        StubProtocol.reset(unattested.handler)
        let other = await configure(unattested)
        try await session(seconds: 1)
        let refused = try await settle(other.outbox) { if case .failed = $0.status { return true } else { return false } }[0]
        guard case .failed("attestation_required", _) = refused.status else { return XCTFail("\(refused.status)") }
        XCTAssertTrue(Self.starts.isEmpty)
    }

    func testCancelBeforeTheServerHasIt() async throws {
        let server = Server()
        StubProtocol.reset(server.handler)
        server.down.withLock { $0 = true }
        let cloud = await configure(server, storage: CloudFixtures.storage())
        try await session(seconds: 1)
        let item = try await settle(cloud.outbox) { $0.lastError != nil }[0]
        try await cloud.outbox.cancel(item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.outbox.root.appendingPathComponent(item.id).path))
        do {
            try await cloud.outbox.cancel(item.id)
            XCTFail("cancelled twice")
        } catch {
            guard case .contributionUnavailable = error else { return XCTFail("\(error)") }
        }
    }

    func testContributorIDIsStableUntilReset() async throws {
        let server = Server()
        StubProtocol.reset(server.handler)
        _ = await configure(server)
        let id = QuranLab.contributorID
        XCTAssertTrue(id.count == 32 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(QuranLab.contributorID, id, "stable per install")
        QuranLab.resetContributor()
        XCTAssertNotEqual(QuranLab.contributorID, id)
    }

    /// The session JSON names the revision, the backend (the 1.x enum) and the SDK version.
    func testTheSessionJSONNamesTheDecode() async throws {
        let server = Server()
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        try await session(seconds: 1)
        try await settle(cloud.outbox)
        let decode = try XCTUnwrap(try XCTUnwrap(Self.starts.first?.json)["decode"] as? [String: Any])
        XCTAssertEqual(decode["model_revision"] as? String, "test-rev")
        XCTAssertEqual(decode["backend"] as? String, "exact")
        XCTAssertEqual(decode["sdk_version"] as? String, SDKInfo.version)
    }

    /// Without the learner's consent nothing is captured, even with the developer's option on.
    func testNoConsentNoCapture() async throws {
        let server = Server()
        StubProtocol.reset(server.handler)
        let cloud = await configure(server, consent: false)
        XCTAssertFalse(Contributions.isActive)
        try await session(seconds: 3)
        try await Task.sleep(nanoseconds: 200_000_000)
        let n = await cloud.outbox.items.count
        XCTAssertEqual(n, 0)
    }

    /// Worker calls and R2 PUTs for a session of a given length, from the segment plan.
    func testRequestCountsBySessionLength() {
        func segments(_ seconds: Int) -> Int {
            var n = 0, t = 0
            while t < seconds { n += 1; t += SegmentPlan.seconds(n) }
            return n
        }
        XCTAssertEqual(segments(20), 2)
        XCTAssertEqual(segments(300), 7)
        XCTAssertEqual(segments(7_200), 122)
        // one Worker call starts a session with 20 URLs; each further batch of 20 is one more call
        func calls(_ seconds: Int) -> Int { 1 + max(0, segments(seconds) - 15 + 19) / 20 }
        XCTAssertEqual(calls(20), 1)
        XCTAssertEqual(calls(300), 1)
        XCTAssertEqual(calls(7_200), 7)
        print("Worker calls: 20 s \(calls(20)), 5 min \(calls(300)), 2 h \(calls(7_200)); R2 PUTs: 20 s \(segments(20)), 5 min \(segments(300)), 2 h \(segments(7_200))")
    }
}
