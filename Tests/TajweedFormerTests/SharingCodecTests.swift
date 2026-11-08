import COpus
import Foundation
import XCTest
@testable import TajweedFormer

/// Decodes an Ogg Opus stream with libopus (the decoder half of the same COpus build), per RFC 7845:
/// the pre-skip dropped, the end trimmed to the last granule position. Test-only.
enum OpusTestDecoder {
    static func decode(_ ogg: Data) throws -> [Float] {
        let pages = try SharingTests.pages(ogg)
        let head = pages[0].packets[0]
        let preSkip = Int(head[10]) | Int(head[11]) << 8
        var err: Int32 = 0
        let dec = try XCTUnwrap(opus_decoder_create(48_000, 1, &err))
        defer { opus_decoder_destroy(dec) }
        var out: [Float] = []
        var pcm = [Float](repeating: 0, count: 5_760)
        for page in pages.dropFirst(2) {
            for p in page.packets {
                let n = p.withUnsafeBytes { b in
                    opus_decode_float(dec, b.bindMemory(to: UInt8.self).baseAddress, opus_int32(p.count), &pcm, 5_760, 0)
                }
                guard n > 0 else { throw CocoaError(.fileReadCorruptFile) }
                out += pcm[0..<Int(n)]
            }
        }
        let end = Int(pages.last!.granule)
        XCTAssertLessThanOrEqual(end, out.count)
        return Array(out[preSkip..<min(end, out.count)])
    }
}

final class SharingCodecTests: XCTestCase {
    static func temp() -> URL { SharingTests.temp() }

    static func noise(_ n: Int, seed: UInt64 = 1, gain: Float = 0.3) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return (Float(s >> 40) / Float(1 << 24) * 2 - 1) * gain
        }
    }

    static func tone(_ n: Int, rate: Double, hz: Double = 440, from: Int = 0) -> [Float] {
        (0..<n).map { Float(sin(Double(from + $0) * 2 * .pi * hz / rate)) * 0.3 }
    }

    /// The defaults are the measured choice, and libopus reads every one of them back.
    func testEncoderSettingsAreApplied() throws {
        let s = OpusSettings.shared
        XCTAssertEqual(s.application, .audio)
        XCTAssertEqual(s.bitrate, 192_000)
        XCTAssertEqual(s.complexity, 10)
        XCTAssertTrue(s.vbr)
        XCTAssertFalse(s.constrainedVBR)
        XCTAssertEqual(s.bandwidth, .fullband)
        XCTAssertEqual(s.signal, .auto)
        XCTAssertEqual(s.frameMs, 20)
        XCTAssertEqual(s.pagePackets, 50)
        XCTAssertEqual(OpusVersion.string, "libopus 1.6.1")

        let e = try LibOpusEncoder(sampleRate: 48_000, channels: 1, settings: s)
        let x = Self.noise(48_000)
        let packets = try x.withUnsafeBufferPointer { (p) throws(RecognizerError) in try e.encode(p) }
        XCTAssertEqual(packets.count, 50)
        XCTAssertEqual(e.get(OPUS_GET_APPLICATION_REQUEST), OPUS_APPLICATION_AUDIO)
        XCTAssertEqual(e.get(OPUS_GET_BITRATE_REQUEST), 192_000)
        XCTAssertEqual(e.get(OPUS_GET_COMPLEXITY_REQUEST), 10)
        XCTAssertEqual(e.get(OPUS_GET_VBR_REQUEST), 1)
        XCTAssertEqual(e.get(OPUS_GET_VBR_CONSTRAINT_REQUEST), 0)
        XCTAssertEqual(e.get(OPUS_GET_BANDWIDTH_REQUEST), OPUS_BANDWIDTH_FULLBAND)
        XCTAssertEqual(e.get(OPUS_GET_SIGNAL_REQUEST), OPUS_AUTO)
        XCTAssertEqual(e.get(OPUS_GET_SAMPLE_RATE_REQUEST), 48_000)
        XCTAssertEqual(e.get(OPUS_GET_LSB_DEPTH_REQUEST), 24)
        XCTAssertEqual(e.get(OPUS_GET_DTX_REQUEST), 0)
        XCTAssertEqual(e.get(OPUS_GET_INBAND_FEC_REQUEST), 0)
        XCTAssertEqual(e.get(OPUS_GET_LOOKAHEAD_REQUEST), 312)
        XCTAssertEqual(e.preSkip, 312, "OpusHead pre-skip from the encoder")
        // every packet: CELT-only, fullband, 20 ms, one frame (TOC config 31, code 0), mono
        for p in packets { XCTAssertEqual(p[0], 31 << 3) }
        let bits = packets.reduce(0) { $0 + $1.count } * 8
        XCTAssertGreaterThan(bits, 150_000, "VBR spends about the target on noise")
    }

    /// Pages hold a second of packets (50 at 20 ms), never more than 255 lacing values, and a
    /// segment is exactly its seconds of packets. With 10 ms frames at 510 kbps on loud noise (about
    /// 640-byte packets, 3 lacing values each) a second of packets does not fit in one page: pages
    /// are cut short and the segment boundaries still fall where the plan puts them.
    func testPagePackingAndSegmentBoundaries() throws {
        for (bitrate, frameMs) in [(192_000, 20.0), (510_000, 10.0)] {
            var settings = OpusSettings.shared
            settings.bitrate = bitrate
            settings.frameMs = frameMs
            let perSecond = Int(1000 / frameMs)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zf-pk-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            var closed: [OggSegment] = []
            let w = try OggOpusWriter(segmentURL: { dir.appendingPathComponent(String(format: "seg-%05d.opus", $0)) },
                                      plan: [3, 5], inputRate: 48_000, settings: settings) { closed.append($0) }
            let x = Self.noise(48_000 * 14, gain: 0.9)
            var at = 0
            while at < x.count {
                let k = min(480 * Int.random(in: 1...9), x.count - at)
                try w.append(Array(x[at..<(at + k)]))
                at += k
            }
            try w.finish()
            XCTAssertEqual(closed.map(\.n), [1, 2, 3, 4])
            let pages = try closed.map { try SharingTests.pages(try Data(contentsOf: $0.url)) }
            let audio = pages.enumerated().map { i, p in i == 0 ? Array(p.dropFirst(2)) : p }
            // 14 s plus the 6.5 ms lookahead: 3 s, 5 s, 5 s (the last entry repeats), the rest
            let total = (14 * 48_000 + 312 + settings.packetFrames - 1) / settings.packetFrames
            XCTAssertEqual(audio.map { $0.reduce(0) { $0 + $1.packets.count } }, [3, 5, 5].map { $0 * perSecond } + [total - 13 * perSecond])
            var lacingMax = 0, perPage: [Int] = []
            for seg in closed {
                let b = [UInt8](try Data(contentsOf: seg.url))
                var o = 0
                while o < b.count {
                    let n = Int(b[o + 26])
                    lacingMax = max(lacingMax, n)
                    o += 27 + n + b[(o + 27)..<(o + 27 + n)].reduce(0) { $0 + Int($1) }
                }
            }
            for seg in audio { perPage += seg.dropLast().map(\.packets.count) }
            XCTAssertLessThanOrEqual(lacingMax, 255)
            if frameMs == 20 {
                XCTAssertEqual(Set(perPage), [50], "one-second pages")
            } else {
                XCTAssertTrue(perPage.allSatisfy { $0 >= 60 && $0 <= 100 }, "\(perPage)")
                XCTAssertTrue(perPage.contains { $0 < 100 }, "the lacing limit cut pages short")
            }
            let whole = try closed.map { try Data(contentsOf: $0.url) }.reduce(Data(), +)
            XCTAssertEqual(try OpusTestDecoder.decode(whole).count, 48_000 * 14)
        }
    }

    /// 44.1 kHz input is resampled to 48 kHz before the encoder: the decoded stream is exactly the
    /// input's length at 48 kHz and in time with it (a 440 Hz tone decodes onto the same tone
    /// generated at 48 kHz, no delay).
    func testA441kHzInputIsResampledTo48kHz() throws {
        for rate in [44_100.0, 16_000.0, 22_050.0] {
            let url = Self.temp()
            defer { try? FileManager.default.removeItem(at: url) }
            let seconds = 4.0
            let n = Int(rate * seconds)
            let w = try OggOpusWriter(url: url, inputRate: rate)
            var at = 0
            while at < n {
                let k = min(Int(rate / 100) * Int.random(in: 1...4), n - at)
                try w.append(Self.tone(k, rate: rate, from: at))
                at += k
            }
            XCTAssertEqual(try w.finish(), 4_000)
            let y = try OpusTestDecoder.decode(try Data(contentsOf: url))
            XCTAssertEqual(y.count, Int(seconds * 48_000), "\(rate)")
            let ref = Self.tone(y.count, rate: 48_000)
            // away from the edges, the decoded tone matches the 48 kHz tone
            var sig = 0.0, err = 0.0
            for i in 4_800..<(y.count - 4_800) {
                sig += Double(ref[i] * ref[i])
                err += Double((y[i] - ref[i]) * (y[i] - ref[i]))
            }
            let snr = 10 * log10(sig / err)
            XCTAssertGreaterThan(snr, 30, "\(rate) Hz: \(snr) dB")
        }
    }

    /// NaN and infinity are coded as silence: the stream is byte for byte the one from the same
    /// input with zeros in their place, through the resampler too.
    func testNonFiniteInputIsSilence() throws {
        for rate in [48_000.0, 44_100.0] {
            var bad = Self.noise(Int(rate * 3))
            var good = bad
            for i in stride(from: 17, to: bad.count, by: 997) {
                bad[i] = [Float.nan, .infinity, -.infinity][i % 3]
                good[i] = 0
            }
            let a = Self.temp(), b = Self.temp()
            defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
            let wa = try OggOpusWriter(url: a, inputRate: rate, serial: 7)
            let wb = try OggOpusWriter(url: b, inputRate: rate, serial: 7)
            for c in stride(from: 0, to: bad.count, by: 4_410) {
                try wa.append(Array(bad[c..<min(c + 4_410, bad.count)]))
                try wb.append(Array(good[c..<min(c + 4_410, good.count)]))
            }
            try wa.finish()
            try wb.finish()
            XCTAssertEqual(wa.nonFiniteSamples, Int64((bad.count - 17 + 996) / 997))
            XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b))
            XCTAssertTrue(try OpusTestDecoder.decode(try Data(contentsOf: a)).allSatisfy(\.isFinite))
        }
    }

    /// A crash at any moment loses at most about a second: what is on disk reaches to within 1.1 s
    /// of the input (at 44.1 kHz, through the resampler), and recovery keeps exactly the whole
    /// pages of a torn file.
    func testCrashLosesAtMostASecondAndRecoveryCutsAtTheLastWholePage() throws {
        let url = Self.temp()
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 44_100.0
        let w = try OggOpusWriter(url: url, inputRate: rate)
        var at = 0
        let x = Self.noise(Int(rate * 9))
        while at < x.count {
            let k = min(441 * Int.random(in: 1...20), x.count - at)
            try w.append(Array(x[at..<(at + k)]))
            at += k
            let input48 = Double(at) * 48_000 / rate
            let onDisk = Double(max(0, w.lastGranule))
            // 49 packets, a partial frame, the lookahead and the resampler's delay (about 45 ms)
            XCTAssertLessThanOrEqual(input48 - onDisk, 1.1 * 48_000, "at \(at)")
        }
        let d = try Data(contentsOf: url)
        let pages = try SharingTests.pages(d)
        var ends: [Int] = [], o = 0
        let b = [UInt8](d)
        while o < b.count {
            let n = Int(b[o + 26])
            o += 27 + n + b[(o + 27)..<(o + 27 + n)].reduce(0) { $0 + Int($1) }
            ends.append(o)
        }
        for cut in Array(stride(from: 1, to: d.count, by: 997)) + ends.map({ $0 - 1 }) {
            let (keep, granule) = ShareFiles.wholePages(d.prefix(cut))
            let whole = ends.filter { $0 <= cut }
            XCTAssertEqual(keep, whole.last ?? 0, "cut at \(cut)")
            XCTAssertEqual(granule, whole.isEmpty ? 0 : pages[whole.count - 1].granule)
        }
        w.abandon()
    }

    /// Memory stays flat over a long session (encoder, resampler and writer reuse their buffers):
    /// 10 minutes by default, 2 hours with ZF_LONG=1.
    func testMemoryIsFlatOverALongSession() throws {
        let minutes = ProcessInfo.processInfo.environment["ZF_LONG"] == "1" ? 120 : 10
        let url = Self.temp()
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 44_100.0
        let w = try OggOpusWriter(url: url, inputRate: rate)
        let chunk = Self.noise(441)
        var marks: [Int] = []
        for m in 0..<minutes {
            try autoreleasepool {
                for _ in 0..<(60 * 100) { try w.append(chunk) }
            }
            if m == 1 || m == minutes - 1 { marks.append(Self.footprint()) }
        }
        try w.finish()
        let growth = marks[1] - marks[0]
        print(String(format: "sharing memory: %d min, footprint %.1f MB after minute 2, growth %.2f MB", minutes,
                     Double(marks[0]) / 1e6, Double(growth) / 1e6))
        XCTAssertLessThan(growth, 2_000_000)
        XCTAssertEqual(try OpusTestDecoder.decode(try Data(contentsOf: url)).count, minutes * 60 * 48_000)
    }

    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
