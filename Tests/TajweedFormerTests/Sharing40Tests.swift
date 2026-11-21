import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0 shared recordings (SHARING_40.md section 19) against the contract's vectors (quranlab-contract
/// sdk_4.0.0/vectors/sharing40 at c7f6e9b, copied into Fixtures/sharing40): the Ogg FLAC encoder and muxer byte for byte
/// (flac16k/, flac_cases.json), the float conversion (pcm16.json), the device model (device_model.json) and the start
/// body (upload_start.json); then the form a recording takes through the real capture, the outbox and the stub server,
/// and the recovery of a FLAC recording the app was killed in.
final class Sharing40Tests: XCTestCase {
    /// The server's pattern for `device_model` (19.2).
    static let modelPattern = "^[A-Za-z0-9][A-Za-z0-9 _.,+()/-]{0,63}$"

    override func tearDown() {
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    // MARK: helpers

    static func dir() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "sharing40", withExtension: nil, subdirectory: "Fixtures"))
    }

    static func json(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: dir().appendingPathComponent(name))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// SHA-256 of the samples as 16-bit little endian (the vectors' `pcm_sha256`).
    static func pcmSHA(_ pcm: [Int16]) -> String {
        var d = Data(capacity: pcm.count * 2)
        for v in pcm { d.append(le: UInt16(bitPattern: v)) }
        return sha(d)
    }

    /// `tools/sharing40.py` `test_signal`: integer-only test audio, the same in every language (the rate does not
    /// change it).
    static func testSignal(_ n: Int, seed: Int) -> [Int16] {
        var out: [Int16] = []
        out.reserveCapacity(n)
        var s = UInt32(truncatingIfNeeded: seed)
        var walk = 0, a = 20_000, b = 0, c = 30_000, d = 0
        for i in 0..<n {
            s = s &* 1_664_525 &+ 1_013_904_223
            let noise = Int(s >> 16) - 32_768
            walk = max(-30_000, min(30_000, walk + (noise >> 11)))
            a -= (b * 1029) >> 16
            b += (a * 1029) >> 16
            c -= (d * 6863) >> 16
            d += (c * 6863) >> 16
            let t = i % 160
            let tri = 150 * (t < 40 ? t : (t < 120 ? 80 - t : t - 160))
            let v: Int
            switch (i / FlacFrame.block + seed) % 16 {
            case 0: v = 0
            case 1: v = -1234
            case 2: v = noise
            case 3: v = noise >> 9
            case 4: v = walk
            case 5, 9: v = tri + (noise >> 13)
            case 6, 10: v = a
            case 7, 11: v = c
            case 8: v = (i / 32) % 2 == 0 ? 8192 : -8192
            default: v = noise >> 14
            }
            out.append(Int16(max(-32_768, min(32_767, v))))
        }
        return out
    }

    /// `tools/sharing40.py` `case_pcm`: the two cases given by a formula, else `test_signal`.
    static func casePCM(_ name: String, n: Int, seed: Int?) throws -> [Int16] {
        if name == "r88200_wasted" {
            return (0..<n).map { (i: Int) -> Int16 in Int16(i < 6000 ? ((i * 12) % 4000 - 2000) * 4 : -4096) }
        }
        if name == "r24000_extremes" {
            return (0..<n).map { (i: Int) -> Int16 in
                if i < 2000 { return (i / 50) % 2 == 1 ? 32_767 : -32_768 }
                if i < 3000 { return i % 2 == 1 ? 32_767 : -32_768 }
                return Int16((i % 7) * 9000 - 27_000)
            }
        }
        return testSignal(n, seed: try XCTUnwrap(seed, name))
    }

    struct Written {
        var segments: [Data]
        var closed: [OggSegment]
    }

    /// A session through the SDK's FLAC writer (the segment plan of 10, 20, 40, then 60 s) with the serial and vendor
    /// given, fed by `feed`; the segment files in order.
    static func write(rate: Int, serial: UInt32, vendor: String, _ feed: (OggFlacWriter) throws -> Void) throws -> Written {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tf-flac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var closed: [OggSegment] = []
        let w = try OggFlacWriter(segmentURL: { (n: Int) -> URL in dir.appendingPathComponent(ShareFiles.audioName(n, flac: true)) },
                                  plan: SegmentPlan.seconds, inputRate: Double(rate), serial: serial, vendor: vendor) { closed.append($0) }
        try feed(w)
        _ = try w.finish()
        let segments = try closed.map { (s: OggSegment) -> Data in try Data(contentsOf: s.url) }
        return Written(segments: segments, closed: closed)
    }

    /// 16-bit samples in pieces of the sizes given, in turn.
    static func pieces(_ pcm: [Int16], _ sizes: [Int]) -> (OggFlacWriter) throws -> Void {
        { (w: OggFlacWriter) throws -> Void in
            var at = 0, k = 0
            while at < pcm.count {
                let n = min(sizes[k % sizes.count], pcm.count - at)
                try w.append(pcm16: Array(pcm[at..<(at + n)]))
                at += n
                k += 1
            }
        }
    }

    /// Where two segment files first differ, and the page of the vector's description that holds that byte.
    static func firstDifference(_ mine: Data, _ want: Data, pages: Any?) -> String {
        let a = [UInt8](mine), b = [UInt8](want)
        let at = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
        let list = (pages as? [[String: Any]]) ?? []
        let page = list.last(where: { ($0["offset"] as? Int ?? 0) <= at })
        return "first difference at byte \(at), in the page of sequence \(String(describing: page?["seq"])), "
            + "kind \(String(describing: page?["kind"]))"
    }

    /// The subframe kind of every frame of `pcm`, as the encoder chooses it.
    static func kinds(_ pcm: [Int16], rate: Int) -> [String] {
        let block = FlacFrame.block
        let frames = (pcm.count + block - 1) / block
        return (0..<frames).map { (f: Int) -> String in
            FlacFrame.encode(Array(pcm[(f * block)..<min((f + 1) * block, pcm.count)]), number: f, rate: rate).kind
        }
    }

    // MARK: the encoder and the muxer (19.4)

    /// flac16k/: test_signal(1200000, 16000, 1) through the encoder and muxer (serial and vendor of the vector) gives
    /// the four segment files byte for byte, whatever pieces the samples come in.
    func testTheFlac16kSessionByteForByte() throws {
        let base = try Self.dir().appendingPathComponent("flac16k")
        let exp = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("expected.json"))) as? [String: Any])
        let input = try XCTUnwrap(exp["input"] as? [String: Any])
        let rate = try XCTUnwrap(input["rate"] as? Int)
        let n = try XCTUnwrap(input["samples"] as? Int)
        let pcm = Self.testSignal(n, seed: try XCTUnwrap(input["seed"] as? Int))
        XCTAssertEqual(Self.pcmSHA(pcm), input["pcm_sha256"] as? String, "test_signal as the reference makes it")
        let serial = UInt32(try XCTUnwrap(input["serial"] as? Int))
        let vendor = try XCTUnwrap(input["vendor"] as? String)
        let plan = (1...4).map { (k: Int) -> Int in (SegmentPlan.seconds(k) * rate + FlacFrame.block - 1) / FlacFrame.block }
        XCTAssertEqual(plan, input["frames_per_segment"] as? [Int], "19.4.4: 40, 79, 157, then 235 frames at 16 kHz")
        let segs = try XCTUnwrap(exp["segments"] as? [[String: Any]])
        XCTAssertEqual(segs.count, 4)
        // 20 ms pieces as a microphone gives them, and uneven ones across the block boundaries: the same bytes
        for sizes in [[320], [1, 4095, 4096, 4097, 9000, 77]] {
            let out = try Self.write(rate: rate, serial: serial, vendor: vendor, Self.pieces(pcm, sizes))
            XCTAssertEqual(out.closed.map(\.n), [1, 2, 3, 4])
            XCTAssertEqual(out.closed.map(\.last), [false, false, false, true])
            XCTAssertEqual(out.closed.map { $0.rate ?? 0 }, [rate, rate, rate, rate])
            XCTAssertEqual(out.closed.last?.granule, Int64(n))
            var same = 0
            for (i, s) in segs.enumerated() {
                let file = try XCTUnwrap(s["file"] as? String)
                let want = try Data(contentsOf: base.appendingPathComponent(file))
                XCTAssertEqual(Self.sha(want), s["sha256"] as? String, "the fixture is the vector's")
                guard i < out.segments.count else {
                    XCTFail("\(file) was not written")
                    continue
                }
                let mine = out.segments[i]
                // every page's sequence, granule and flags as the vector describes them
                let got = try SharingTests.pages(mine).map { (p: SharingTests.Page) -> [Int] in [Int(p.sequence), Int(p.granule), Int(p.flags)] }
                let described = ((s["pages"] as? [[String: Any]]) ?? []).map { (p: [String: Any]) -> [Int] in
                    [p["seq"] as? Int ?? -1, p["granule"] as? Int ?? -1, p["flags"] as? Int ?? -1]
                }
                XCTAssertEqual(got, described, "\(file): sequence, granule and flags of every page")
                if mine == want {
                    same += 1
                } else {
                    XCTFail("\(file) (pieces \(sizes)): \(mine.count) bytes, want \(want.count); "
                            + Self.firstDifference(mine, want, pages: s["pages"]))
                }
            }
            XCTAssertEqual(Self.sha(out.segments.reduce(Data(), +)), exp["whole_sha256"] as? String)
            print("flac16k vector (pieces \(sizes)): \(same)/\(segs.count) segments byte for byte")
        }
        // every frame's kind: constant, verbatim, fixed of orders 0 to 4 (with wasted bits among them)
        let kinds = Self.kinds(pcm, rate: rate)
        let described = segs.flatMap { (s: [String: Any]) -> [String] in
            ((s["pages"] as? [[String: Any]]) ?? []).compactMap { $0["kind"] as? String }.filter { $0 != "mapping" && $0 != "comment" }
        }
        XCTAssertEqual(kinds, described)
        let counted = Dictionary(kinds.map { ($0, 1) }, uniquingKeysWith: +)
        XCTAssertEqual(counted, (exp["frames"] as? [String: Any])?["kinds"] as? [String: Int])
    }

    /// flac_cases.json: ten short sessions at other rates (every rate code, block size codes 6, 7 and 12, a last
    /// frame of 3 samples, the end of the stream on a full frame, wasted bits, the 16-bit limits): the whole output's
    /// size and SHA-256, its bytes when given, the frames of each segment and each frame's kind.
    func testTheFlacCases() throws {
        let cases = try XCTUnwrap(Self.json("flac_cases.json")["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 10)
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            let rate = try XCTUnwrap(c["rate"] as? Int)
            let n = try XCTUnwrap(c["samples"] as? Int)
            let seed = ((c["input"] as? [String: Any])?["test_signal"] as? [String: Any])?["seed"] as? Int
            let pcm = try Self.casePCM(name, n: n, seed: seed)
            XCTAssertEqual(Self.pcmSHA(pcm), c["pcm_sha256"] as? String, "\(name): the input")
            let serial = UInt32(try XCTUnwrap(c["serial"] as? Int))
            let vendor = try XCTUnwrap(c["vendor"] as? String)
            let out = try Self.write(rate: rate, serial: serial, vendor: vendor, Self.pieces(pcm, [max(1, rate / 50), 333]))
            let whole = out.segments.reduce(Data(), +)
            XCTAssertEqual(whole.count, c["bytes"] as? Int, name)
            XCTAssertEqual(Self.sha(whole), c["sha256"] as? String, name)
            if let b64 = c["ogg_flac_base64"] as? String {
                let want = try XCTUnwrap(Data(base64Encoded: b64))
                if whole != want { XCTFail("\(name): " + Self.firstDifference(whole, want, pages: nil)) }
            }
            var frames: [Int] = []
            for (k, d) in out.segments.enumerated() { frames.append(try SharingTests.pages(d).count - (k == 0 ? 2 : 0)) }
            XCTAssertEqual(frames, c["segments"] as? [Int], "\(name): frames per segment")
            XCTAssertEqual(Self.kinds(pcm, rate: rate), c["frame_kinds"] as? [String], name)
            XCTAssertEqual(out.closed.last?.last, true, name)
        }
    }

    /// pcm16.json: float samples to the 16-bit integers the encoder takes (19.3), and the writer's float path is that
    /// conversion.
    func testFloatTo16Bit() throws {
        let cases = try XCTUnwrap(Self.json("pcm16.json")["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let hex = try XCTUnwrap(c["f32"] as? String)
            let x = Float(bitPattern: try XCTUnwrap(UInt32(hex, radix: 16)))
            XCTAssertEqual(Int(ShareCodec.pcm16(x)), c["int16"] as? Int, hex)
        }
        // floats that are exactly 16-bit values go through the writer to the same bytes as the integers
        let pcm = Self.testSignal(10_000, seed: 9)
        let floats = pcm.map { (v: Int16) -> Float in Float(v) / 32768 }
        let ints = try Self.write(rate: 22_050, serial: 1, vendor: "v", Self.pieces(pcm, [441]))
        let viaFloat = try Self.write(rate: 22_050, serial: 1, vendor: "v") { (w: OggFlacWriter) throws -> Void in
            try w.append(Array(floats[0..<5_000]))
            try w.append(Array(floats[5_000...]))
        }
        XCTAssertEqual(ints.segments, viaFloat.segments)
    }

    // MARK: the device model (19.2) and the start body (19.5)

    /// device_model.json through the SDK's normalisation; this device's model matches the server's pattern.
    func testTheDeviceModel() throws {
        let v = try Self.json("device_model.json")
        XCTAssertEqual(v["pattern"] as? String, Self.modelPattern)
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 17)
        for c in cases {
            let parts = try XCTUnwrap(c["parts"] as? [String])
            let got = DeviceModel.normalize(parts.map { (p: String) -> String? in p })
            XCTAssertEqual(got, c["device_model"] as? String, "\(parts)")
            if let got { XCTAssertNotNil(got.range(of: Self.modelPattern, options: .regularExpression), got) }
        }
        XCTAssertNil(DeviceModel.normalize([nil]))
        // this device's, as the start body sends it
        let mine = DeviceModel.current
        if let mine { XCTAssertNotNil(mine.range(of: Self.modelPattern, options: .regularExpression), mine) }
        XCTAssertEqual(mine, DeviceModel.normalize([DeviceModel.raw]))
        #if os(macOS) && !targetEnvironment(simulator)
        XCTAssertNotNil(mine, "sysctl hw.model gives the Mac's model")
        XCTAssertNotEqual(mine, "arm64", "hw.model on a Mac, not hw.machine")
        #endif
        print("device_model here: \(mine ?? "none")")
    }

    /// 19.5 as the server checks the fields the SDK decides (the test's own reading of the contract): the form of
    /// `audio`, the SDK version of a FLAC body, and `device_model`.
    static func acceptable(_ b: [String: Any]) -> Bool {
        guard let a = b["audio"] as? [String: Any], let codec = a["codec"] as? String, let rate = a["sample_rate"] as? Int else {
            return false
        }
        if let m = b["device_model"] {
            guard let s = m as? String, s.range(of: modelPattern, options: .regularExpression) != nil else { return false }
        }
        if codec == "flac" {
            let sdk = ((b["decode"] as? [String: Any])?["sdk_version"] as? String) ?? ""
            let major = Int(sdk.split(separator: ".").first ?? "") ?? 0
            let input = a["input_sample_rate"]
            return (8_000...192_000).contains(rate) && rate != 48_000 && a["bits_per_sample"] as? Int == 16
                && (input == nil || input as? Int == rate) && major >= 4
        }
        return codec == "opus" && rate == 48_000 && a["bits_per_sample"] == nil
    }

    /// The start body the SDK sends for the capture a vector body describes (its capture rate, route, model and
    /// decode fields), in the form `ShareCodec` picks with the switch on.
    static func body(for b: [String: Any]) throws -> [String: Any] {
        let audio = try XCTUnwrap(b["audio"] as? [String: Any])
        let decode = try XCTUnwrap(b["decode"] as? [String: Any])
        let rate = try XCTUnwrap((audio["input_sample_rate"] ?? audio["sample_rate"]) as? Int)
        let d = ContributionClient.session(modelRevision: decode["model_revision"] as? String, backend: try XCTUnwrap(decode["backend"] as? String),
                                           weightsSHA256: decode["weights_sha256"] as? String, consentVersion: b["consent_version"] as? String,
                                           contributor: try XCTUnwrap(b["contributor"] as? String), day: try XCTUnwrap(b["day"] as? String),
                                           inputSampleRate: rate, inputRoute: try XCTUnwrap(audio["input_route"] as? String),
                                           flac: ShareCodec.flac(rate: Double(rate), shareFlac: true),
                                           deviceModel: (b["device_model"] as? String).flatMap { (m: String) -> String? in DeviceModel.normalize([m]) })
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    /// upload_start.json: every accepted body is a shape the SDK sends (the same fields; the same `audio`, `decode`
    /// and `device_model` for the same capture), and for every refused one the SDK sends another body, one the server
    /// takes.
    func testTheStartBodies() throws {
        let v = try Self.json("upload_start.json")
        let accepted = try XCTUnwrap(v["accepted"] as? [[String: Any]])
        let refused = try XCTUnwrap(v["refused"] as? [[String: Any]])
        XCTAssertEqual(accepted.count, 5)
        XCTAssertEqual(refused.count, 11)
        for entry in accepted {
            let name = try XCTUnwrap(entry["name"] as? String)
            let want = try XCTUnwrap(entry["body"] as? [String: Any])
            XCTAssertTrue(Self.acceptable(want), "the test's reading of 19.5 takes \(name)")
            let mine = try Self.body(for: want)
            XCTAssertTrue(Self.acceptable(mine), name)
            XCTAssertEqual(Set(mine.keys), Set(want.keys), name)
            // the SDK always names the input rate; for FLAC it is the rate
            var audio = try XCTUnwrap(want["audio"] as? [String: Any])
            if audio["input_sample_rate"] == nil { audio["input_sample_rate"] = audio["sample_rate"] }
            XCTAssertEqual(mine["audio"] as? NSDictionary, NSDictionary(dictionary: audio), name)
            // the vector's bodies were made by a 4.0.0 SDK: the SDK names its own version (4.0.1 from this branch)
            var decode = try XCTUnwrap(want["decode"] as? [String: Any])
            if decode["sdk_version"] != nil { decode["sdk_version"] = SDKInfo.version }
            XCTAssertEqual(mine["decode"] as? NSDictionary, NSDictionary(dictionary: decode), name)
            XCTAssertEqual(mine["device_model"] as? String, want["device_model"] as? String, name)
            for key in ["contributor", "day", "consent_version"] { XCTAssertEqual(mine[key] as? String, want[key] as? String, "\(name): \(key)") }
            XCTAssertEqual(mine["format"] as? Int, 1)
        }
        for entry in refused {
            let name = try XCTUnwrap(entry["name"] as? String)
            let bad = try XCTUnwrap(entry["body"] as? [String: Any])
            XCTAssertFalse(Self.acceptable(bad), "the test's reading of 19.5 refuses \(name)")
            let mine = try Self.body(for: bad)
            XCTAssertTrue(Self.acceptable(mine), "\(name): the SDK's body for that capture is taken")
            let sent = NSDictionary(dictionary: ["audio": mine["audio"] ?? NSNull(), "decode": mine["decode"] ?? NSNull(),
                                                 "device_model": mine["device_model"] ?? NSNull()])
            let theirs = NSDictionary(dictionary: ["audio": bad["audio"] ?? NSNull(), "decode": bad["decode"] ?? NSNull(),
                                                   "device_model": bad["device_model"] ?? NSNull()])
            XCTAssertNotEqual(sent, theirs, "\(name): the SDK never sends it")
        }
    }

    // MARK: which form a recording takes (19.3)

    func testWhichFormARecordingTakes() throws {
        XCTAssertTrue(ShareCodec.flac(rate: 16_000, shareFlac: true))
        XCTAssertTrue(ShareCodec.flac(rate: 44_100, shareFlac: true))
        XCTAssertTrue(ShareCodec.flac(rate: 8_000, shareFlac: true))
        XCTAssertTrue(ShareCodec.flac(rate: 11_025, shareFlac: true))
        XCTAssertTrue(ShareCodec.flac(rate: 192_000, shareFlac: true))
        XCTAssertFalse(ShareCodec.flac(rate: 48_000, shareFlac: true), "a 48 kHz capture is always Opus")
        XCTAssertFalse(ShareCodec.flac(rate: 16_000, shareFlac: false), "the switch off: Opus as in 3.x")
        XCTAssertFalse(ShareCodec.flac(rate: 7_999, shareFlac: true))
        XCTAssertFalse(ShareCodec.flac(rate: 384_000, shareFlac: true))
        XCTAssertFalse(ShareCodec.flac(rate: 16_000.5, shareFlac: true))
        XCTAssertFalse(ShareCodec.flac(rate: 88_201, shareFlac: true), "no frame header carries it")
        XCTAssertThrowsError(try OggFlacWriter(segmentURL: { _ in FileManager.default.temporaryDirectory }, plan: [], inputRate: 48_000))
        // the switch: only a literal true turns it on
        let flags: [(String, Bool)] = [("{}", false), ("{\"share_flac\":true}", true), ("{\"share_flac\":false}", false),
                                       ("{\"share_flac\":\"true\"}", false), ("{\"share_flac\":null}", false)]
        for (json, on) in flags {
            XCTAssertEqual(try JSONDecoder().decode(RemoteConfig.Flags.self, from: Data(json.utf8)).share_flac, on, json)
        }
        XCTAssertFalse(RemoteConfig.Flags().share_flac)
    }

    /// A configured cloud (stub network) in a new storage; the learner said yes.
    func configure(_ server: SharingTests.Server) async -> QuranLabCloud {
        let storage = CloudFixtures.storage()
        let options = CloudFixtures.options(contributions: true, storage: storage)
        let cloud = CloudFixtures.cloud(storage: storage, options: options)
        _ = await cloud.refreshConfig()
        QuranLab.configure(key: CloudFixtures.key, options: options, cloud: cloud)
        Contributions.answer(share: true)
        return cloud
    }

    /// A recording of `seconds` at `rate` through the real capture, in 100 ms pieces, finished.
    func share(seconds: Int, rate: Int) throws {
        let capture = try XCTUnwrap(Contributions.capture(revision: "test-rev", backend: .exact, weightsSHA256: nil))
        let n = seconds * rate
        var at = 0
        while at < n {
            let k = min(rate / 10, n - at)
            try capture.append(SharingTests.audio(k, seed: at + 1), rate: Double(rate))
            at += k
        }
        capture.finish(completed: true)
    }

    /// Waits until the outbox holds one uploaded item.
    func uploaded(_ outbox: ContributionOutbox, timeout: TimeInterval = 15) async throws -> Contribution {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let items = await outbox.items
            if items.count == 1, items[0].status == .uploaded { return items[0] }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let items = await outbox.items
        XCTFail("outbox did not settle: \(items)")
        return try XCTUnwrap(items.first)
    }

    /// 25 s at 16 kHz with `flags.share_flac` on: the start body says FLAC at 16 kHz with the device model, the two
    /// segments go as `audio/ogg`, and they are the Ogg FLAC stream of 19.4 (98 frames: 40, then 58, the last of 2688
    /// samples, ending the stream).
    func testA16kHzRecordingGoesAsFlacWithTheSwitchOn() async throws {
        let server = SharingTests.Server(flags: ["share_flac": true])
        StubProtocol.reset(server.handler)
        let cloud = await configure(server)
        try share(seconds: 25, rate: 16_000)
        let item = try await uploaded(cloud.outbox)
        XCTAssertEqual(item.durationMs, 25_000)
        XCTAssertEqual(item.segments, 2)
        XCTAssertEqual(item.segmentBitrates, [0, 0], "lossless: no bitrate")
        let start = try XCTUnwrap(SharingTests.starts.first?.json)
        XCTAssertEqual(start["audio"] as? [String: AnyHashable], ["codec": "flac", "container": "ogg", "sample_rate": 16_000, "channels": 1,
                                                                  "bits_per_sample": 16, "input_sample_rate": 16_000,
                                                                  "input_route": AnyHashable(AudioRoute.current())])
        XCTAssertEqual(start["device_model"] as? String, DeviceModel.current)
        let puts = SharingTests.puts
        XCTAssertEqual(puts.count, 2)
        for p in puts { XCTAssertEqual(p.headers["content-type"], "audio/ogg") }
        let segs = server.segments(item.id)
        let pages = try segs.map { try SharingTests.pages($0) }
        XCTAssertEqual(pages.map(\.count), [42, 58], "the two header pages and 40 frames, then the other 58")
        XCTAssertEqual(pages.first?.first?.packets.first, OggFlacWriter.mappingPacket(rate: 16_000))
        XCTAssertEqual(pages.first?.dropFirst().first?.packets.first, OggFlacWriter.commentPacket(vendor: "QuranLab SDK \(SDKInfo.version)"))
        XCTAssertEqual(pages.flatMap { $0 }.map(\.sequence), (0..<100).map { UInt32($0) })
        XCTAssertEqual(pages.last?.last?.flags, 0x04, "the last page ends the stream")
        XCTAssertEqual(pages.last?.last?.granule, 25 * 16_000)
        XCTAssertEqual(pages.flatMap { $0 }.dropLast().filter { $0.flags != 0 && $0.flags != 0x02 }.count, 0)
        let left = try FileManager.default.contentsOfDirectory(atPath: cloud.outbox.root.appendingPathComponent(item.id).path)
        XCTAssertFalse(left.contains { $0.hasSuffix(".oga") || $0.hasSuffix(".opus") }, "the audio goes once uploaded")
    }

    /// The switch off (absent from the config), a 16 kHz recording is Opus as in 3.x; with it on, a 48 kHz one is
    /// Opus too. Both bodies carry the device model.
    func testOpusWithTheSwitchOffAndAt48kHz() async throws {
        let runs: [(flags: [String: Any], rate: Int)] = [([:], 16_000), (["share_flac": true], 48_000)]
        for (flags, rate) in runs {
            let server = SharingTests.Server(flags: flags)
            StubProtocol.reset(server.handler)
            let cloud = await configure(server)
            try share(seconds: 3, rate: rate)
            let item = try await uploaded(cloud.outbox)
            let start = try XCTUnwrap(SharingTests.starts.first?.json)
            let audio = try XCTUnwrap(start["audio"] as? [String: AnyHashable])
            XCTAssertEqual(audio["codec"], AnyHashable("opus"), "\(rate) Hz")
            XCTAssertEqual(audio["sample_rate"], AnyHashable(48_000))
            XCTAssertEqual(audio["input_sample_rate"], AnyHashable(rate))
            XCTAssertNil(audio["bits_per_sample"])
            XCTAssertEqual(start["device_model"] as? String, DeviceModel.current)
            let head = try SharingTests.pages(try XCTUnwrap(server.segments(item.id).first))[0].packets[0]
            XCTAssertEqual(head.prefix(8), Data("OpusHead".utf8))
            QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
        }
    }

    /// A FLAC recording the app was killed in: segment 2 is cut back to its last whole page and closed, the duration
    /// counts at the capture rate, no page ends the stream (every frame on a page holds 4096 samples: the held frame
    /// and the samples not yet in a frame are what is lost), and the backlog counts its seconds at its rate.
    func testAKilledFlacRecordingIsRecoveredAtItsRate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tf-flac-root-\(UUID().uuidString)")
        let folder = root.appendingPathComponent(String(repeating: "ab", count: 16), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ShareFiles.write(ShareFiles.Capture(preSkip: 0, bitrates: nil, rate: 16_000), folder.appendingPathComponent(ShareFiles.capture))
        let w = try OggFlacWriter(segmentURL: { (n: Int) -> URL in folder.appendingPathComponent(ShareFiles.audioName(n, flac: true)) },
                                  plan: SegmentPlan.seconds, inputRate: 16_000) { (seg: OggSegment) -> Void in
            _ = try? ShareFiles.mark(folder, n: seg.n, granule: seg.granule, bitrate: seg.bitrate, rate: seg.rate)
        }
        // 15 s: 58 whole frames encoded, 57 of them on pages (40 in segment 1, 17 in segment 2), one held
        try w.append(pcm16: Self.testSignal(15 * 16_000, seed: 3))
        w.abandon()
        // the app is killed while a page is being written
        let open = folder.appendingPathComponent("seg-00002.oga")
        let h = try FileHandle(forWritingTo: open)
        try h.seekToEnd()
        try h.write(contentsOf: Data([0x4F, 0x67, 0x67, 0x53, 0x00, 0x00, 0x01]))
        try h.close()
        XCTAssertEqual(ShareFiles.recovery(folder), .recovered)
        let markers = ShareFiles.markers(folder)
        XCTAssertEqual(markers.map(\.n), [1, 2])
        XCTAssertEqual(markers.map(\.rate), [16_000, 16_000])
        XCTAssertEqual(markers.map(\.granule), [40 * 4096, 57 * 4096] as [Int64])
        XCTAssertEqual(markers.map(\.bitrate), [0, 0])
        XCTAssertEqual(markers.map(\.audioFile), ["seg-00001.oga", "seg-00002.oga"])
        let end = try XCTUnwrap(ShareFiles.read(ShareFiles.End.self, folder.appendingPathComponent(ShareFiles.end)))
        XCTAssertEqual(end.durationMs, 57 * 4096 * 1000 / 16_000)
        XCTAssertFalse(end.completed)
        let pages = try SharingTests.pages(try Data(contentsOf: open))
        XCTAssertEqual(pages.count, 17)
        XCTAssertTrue(pages.allSatisfy { $0.flags == 0 })
        XCTAssertEqual(markers.last?.bytes, Int64(try Data(contentsOf: open).count))
        XCTAssertEqual(ShareFiles.backlogSeconds(root: root), Double(57 * 4096) / 16_000, accuracy: 1e-9)
    }
}
