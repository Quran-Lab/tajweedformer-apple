import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// The cross-SDK byte-level vector of the shared-session codec: a fixed PCM input through the SDK's own writer
/// (libopus 1.6.1 with the shipped settings, the Ogg pages, the 10/20/40/60 s segment plan, a fixed serial) and the
/// exact segment bytes it gives. Every SDK that shares sessions must produce the same Ogg bytes from the same Opus
/// packets (packets.bin), and, with the same libopus build and settings, the same packets from input.f32.
///
/// With SHARING_VECTORS_OUT set, the vector is written there (CI uploads it as the artifact `sharing-codec-vector`).
final class SharingVectorTests: XCTestCase {
    static let serial: UInt32 = 0x5141_4C31   // "QAL1"
    static let rate = 48_000.0
    static let seconds = 75.0                  // segments of 10, 20, 40 and 5 s

    /// The input: a 220 Hz tone with a slow tremolo plus a little noise from a 32-bit LCG; reproducible in any
    /// language from the formula, and shipped as input.f32 anyway.
    static func input() -> [Float] {
        let n = Int(rate * seconds)
        var state: UInt32 = 0x1234_5678
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: state)) / 2_147_483_648.0
            let t = Double(i) / rate
            out[i] = Float(0.4 * sin(2 * .pi * 220 * t) * (0.6 + 0.4 * sin(2 * .pi * 0.5 * t)) + 0.02 * noise)
        }
        return out
    }

    /// libopus, recording every call's packets.
    final class Recorder: OpusEncoding {
        let inner: LibOpusEncoder
        var calls: [[Data]] = []
        init(sampleRate: Int, channels: Int, settings: OpusSettings) throws(RecognizerError) {
            inner = try LibOpusEncoder(sampleRate: sampleRate, channels: channels, settings: settings)
        }
        var preSkip: Int { inner.preSkip }
        func encode(_ pcm: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [Data] {
            let p = try inner.encode(pcm)
            calls.append(p)
            return p
        }
        func flush() throws(RecognizerError) -> [Data] {
            let p = try inner.flush()
            calls.append(p)
            return p
        }
        var finalGranulePosition: Int64 { inner.finalGranulePosition }
    }

    /// Hands back recorded packets, call by call: the Ogg layer alone.
    final class Replay: OpusEncoding {
        var calls: [[Data]] = []
        var at = 0
        var pre = 0
        var granule: Int64 = 0
        init(sampleRate: Int, channels: Int, settings: OpusSettings) throws(RecognizerError) {}
        var preSkip: Int { pre }
        func encode(_ pcm: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [Data] { next() }
        /// When set, what flush() returns (the muxer vector: every packet but the last from the first encode call).
        var flushPackets: [Data]?
        func flush() throws(RecognizerError) -> [Data] { flushPackets ?? next() }
        private func next() -> [Data] {
            defer { at += 1 }
            return at < calls.count ? calls[at] : []
        }
        var finalGranulePosition: Int64 { granule }
    }

    struct Run {
        var segments: [Data]
        var encoder: any OpusEncoding
    }

    static func run(_ input: [Float], encoder: any OpusEncoding) throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tf-vec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var closed: [Int] = []
        let w = try OggOpusWriter(segmentURL: { dir.appendingPathComponent(String(format: "seg-%05d.opus", $0)) },
                                  plan: SegmentPlan.seconds, inputRate: rate, serial: serial, encoder: encoder) { closed.append($0.n) }
        var i = 0
        while i < input.count {   // 20 ms pieces, as a microphone delivers them
            let n = min(960, input.count - i)
            try w.append(Array(input[i..<i + n]))
            i += n
        }
        _ = try w.finish()
        let segs = try closed.sorted().map { try Data(contentsOf: dir.appendingPathComponent(String(format: "seg-%05d.opus", $0))) }
        return Run(segments: segs, encoder: encoder)
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    func testCodecVector() throws {
        let x = Self.input()
        let rec = try Recorder(sampleRate: OpusSettings.codedRate, channels: 1, settings: .shared)
        let a = try Self.run(x, encoder: rec)
        XCTAssertEqual(a.segments.count, 4, "10, 20, 40 and the last 5 s")
        // the same input gives the same bytes
        let b = try Self.run(x, encoder: try LibOpusEncoder(sampleRate: OpusSettings.codedRate, channels: 1, settings: .shared))
        XCTAssertEqual(a.segments, b.segments, "the writer is deterministic")
        // the Ogg layer is a function of the packets alone
        let replay = try Replay(sampleRate: OpusSettings.codedRate, channels: 1, settings: .shared)
        replay.calls = rec.calls
        replay.pre = rec.preSkip
        replay.granule = rec.finalGranulePosition
        let c = try Self.run(x, encoder: replay)
        XCTAssertEqual(a.segments, c.segments, "the same packets give the same Ogg bytes")

        guard let out = ProcessInfo.processInfo.environment["SHARING_VECTORS_OUT"] else { return }
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pcm = x.withUnsafeBufferPointer { Data(buffer: $0) }
        try pcm.write(to: dir.appendingPathComponent("input.f32"))
        var packets = Data()
        var count = 0
        for call in rec.calls {
            for p in call {
                var n = UInt32(p.count).littleEndian
                packets.append(Data(bytes: &n, count: 4))
                packets.append(p)
                count += 1
            }
        }
        try packets.write(to: dir.appendingPathComponent("packets.bin"))
        var sums = "\(Self.sha(pcm))  input.f32\n\(Self.sha(packets))  packets.bin\n"
        var segs: [[String: Any]] = []
        for (i, s) in a.segments.enumerated() {
            let name = String(format: "seg-%05d.opus", i + 1)
            try s.write(to: dir.appendingPathComponent(name))
            sums += "\(Self.sha(s))  \(name)\n"
            segs.append(["file": name, "bytes": s.count, "sha256": Self.sha(s)])
        }
        try Data(sums.utf8).write(to: dir.appendingPathComponent("SHA256SUMS"))
        let s = OpusSettings.shared
        let meta: [String: Any] = [
            "format": "quranlab.sharing-codec-vector/1", "sdk": "tajweedformer-sdk-swift \(SDKInfo.version)",
            "input": ["file": "input.f32", "encoding": "float32 little endian, mono", "sample_rate": Int(Self.rate),
                      "seconds": Self.seconds, "formula": "x[i] = 0.4 sin(2 pi 220 t) (0.6 + 0.4 sin(2 pi 0.5 t)) + 0.02 noise, "
                        + "t = i / 48000, noise = int32(state) / 2^31 after state = state * 1664525 + 1013904223 (uint32, start 0x12345678)"],
            "fed_in_pieces_of": 960,
            "ogg": ["serial": Int(Self.serial), "segment_plan_seconds": SegmentPlan.seconds, "pre_skip": rec.preSkip,
                    "final_granule": rec.finalGranulePosition],
            "opus": ["library": "libopus 1.6.1 (float build)", "coded_rate": OpusSettings.codedRate, "bitrate": s.bitrate,
                     "complexity": s.complexity, "vbr": s.vbr, "constrained_vbr": s.constrainedVBR,
                     "packets": count, "packets_file": "packets.bin (per packet: uint32 little endian length, then the bytes)"],
            "segments": segs,
        ]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("vector.json"))
        let readme = """
        # Shared-session codec vector (tajweedformer-sdk-swift \(SDKInfo.version))

        A fixed PCM input (input.f32: float32 little endian, mono, 48 kHz, 75 s; the formula is in vector.json) through
        the Swift SDK's sharing writer, fed in 20 ms pieces: Ogg Opus, mono, 48 kHz coded, serial 0x51414C31, segments
        cut at Ogg page boundaries after 10, 20 and 40 s (then 60 s each; this input ends in a 5 s fourth segment).
        Segment 1 starts with the OpusHead and OpusTags pages; the last page carries the end-of-stream flag.

        Two levels of conformance for every SDK that shares sessions:

        1. The Ogg layer: feed the Opus packets of packets.bin (each a uint32 little endian length and the bytes, in
           order) with pre_skip and final_granule from vector.json into your page writer and segment plan: the four
           seg-0000N.opus files must come out byte for byte (SHA256SUMS). This level does not depend on libopus.
        2. The codec: with libopus 1.6.1 and the settings in vector.json, input.f32 must give the same packets. Opus
           builds can differ in the last bits across CPU architectures and compile options; if level 2 differs while
           level 1 matches, the container is right and the difference is the encoder build.

        Produced by Tests/TajweedFormerTests/SharingVectorTests.swift on the macOS CI (Apple silicon), artifact
        `sharing-codec-vector`.
        """
        try Data(readme.utf8).write(to: dir.appendingPathComponent("README.md"))
    }

    // MARK: the cross-SDK vectors from quranlab-local

    static func vectors() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "sharing_vectors", withExtension: nil, subdirectory: "Fixtures"))
    }

    /// The muxer vector: the deterministic packets of ogg/expected.json through the SDK's page writer and segment
    /// plan give the four segment files byte for byte.
    func testMuxerVector() throws {
        let dir = try Self.vectors().appendingPathComponent("ogg")
        let exp = try XCTUnwrap(JSONValue(data: Data(contentsOf: dir.appendingPathComponent("expected.json"))))
        let input = try XCTUnwrap(exp["input"])
        let n = Int(try XCTUnwrap(input["packets"]?.number))
        let packets: [Data] = (0..<n).map { i in
            Data((0..<(3 + (i * 37) % 290)).map { j in UInt8((i * 31 + j * 7 + 1) & 255) })
        }
        let replay = try Replay(sampleRate: OpusSettings.codedRate, channels: 1, settings: .shared)
        replay.calls = [Array(packets.dropLast())]
        replay.flushPackets = [packets.last!]
        replay.pre = Int(try XCTUnwrap(input["pre_skip"]?.number))
        replay.granule = Int64(try XCTUnwrap(input["final_granule"]?.number))
        let rate = try XCTUnwrap(input["input_rate"]?.number)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tf-mux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var closed: [Int] = []
        let w = try OggOpusWriter(segmentURL: { out.appendingPathComponent(String(format: "seg-%05d.opus", $0)) },
                                  plan: SegmentPlan.seconds, inputRate: rate, serial: UInt32(try XCTUnwrap(input["serial"]?.number)),
                                  encoder: replay, vendor: try XCTUnwrap(input["vendor"]?.string)) { closed.append($0.n) }
        try w.append([Float](repeating: 0, count: Int(rate)))
        _ = try w.finish()
        let segs = try XCTUnwrap(exp["segments"]?.array)
        XCTAssertEqual(closed.sorted(), segs.indices.map { $0 + 1 })
        var same = 0
        for s in segs {
            let file = try XCTUnwrap(s["file"]?.string)
            let mine = try Data(contentsOf: out.appendingPathComponent(file))
            let want = try Data(contentsOf: dir.appendingPathComponent(file))
            if mine == want { same += 1 } else { XCTFail("\(file): \(mine.count) bytes, want \(want.count)") }
        }
        print("opus muxer vector: \(same)/\(segs.count) segments byte for byte")
    }

    /// The web encoder vector: 3 s of the tests' noise through libopus at the shipped settings, one file, serial 42.
    /// Whether Apple's NEON build gives the wasm build's packets is reported, not required (encoder builds may differ in
    /// the last bits; the muxer vector is the requirement).
    func testWebEncodeVectorComparison() throws {
        let want = try Data(contentsOf: Self.vectors().appendingPathComponent("web_noise48k_3s.ogg"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tf-web-\(UUID().uuidString).opus")
        let w = try OggOpusWriter(url: url, inputRate: 48_000, serial: 42)
        try w.append(SharingCodecTests.noise(144_000))
        _ = try w.finish()
        let mine = try Data(contentsOf: url)
        print("opus web vector: \(mine == want ? "identical" : "differs") (\(mine.count) bytes here, \(want.count) from the wasm build)")
        XCTAssertGreaterThan(mine.count, 0)
    }

    /// Deletion signing: the SDK's message bytes are the vector's, the vector signatures verify with its key, and the
    /// SDK's own signature with that key verifies; the contributor key is the 65-byte point, base64url.
    func testDeletionSigningVectors() throws {
        let v = try XCTUnwrap(JSONValue(data: Data(contentsOf: Self.vectors().appendingPathComponent("signing.json"))))
        let pubData = try XCTUnwrap(Data(base64URL: try XCTUnwrap(v["public_key_uncompressed_b64url"]?.string)))
        let pub = try P256.Signing.PublicKey(x963Representation: pubData)
        let d = try XCTUnwrap(Data(base64URL: try XCTUnwrap(v["private_key_jwk"]?["d"]?.string)))
        let key = ContributorKey.Key.software(try P256.Signing.PrivateKey(rawRepresentation: d))
        XCTAssertEqual(key.contributorKey, v["contributor_key"]?.string)
        for c in try XCTUnwrap(v["cases"]?.array) {
            let f = try XCTUnwrap(c["fields"])
            let msg = ContributorKey.deletionMessage(app: try XCTUnwrap(f["app"]?.string), contributor: try XCTUnwrap(f["contributor"]?.string),
                                                     nonce: try XCTUnwrap(f["nonce"]?.string), timestamp: Int(try XCTUnwrap(f["timestamp"]?.number)))
            XCTAssertEqual(String(decoding: msg, as: UTF8.self), c["message"]?.string)
            let raw = try P256.Signing.ECDSASignature(rawRepresentation: try XCTUnwrap(Data(base64URL: try XCTUnwrap(c["signature_p1363_b64url"]?.string))))
            XCTAssertTrue(pub.isValidSignature(raw, for: msg))
            let der = try P256.Signing.ECDSASignature(derRepresentation: try XCTUnwrap(Data(base64URL: try XCTUnwrap(c["signature_der_b64url"]?.string))))
            XCTAssertTrue(pub.isValidSignature(der, for: msg))
            let mine = try key.sign(msg)
            XCTAssertEqual(mine.count, 64)
            XCTAssertTrue(pub.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: mine), for: msg))
        }
    }

    /// Recovery codes: Crockford base32 of 16 bytes in groups of 4, the normalised form, its hash, and typed forms.
    func testRecoveryCodeVectors() throws {
        let v = try XCTUnwrap(JSONValue(data: Data(contentsOf: Self.vectors().appendingPathComponent("recovery.json"))))
        for c in try XCTUnwrap(v["cases"]?.array) {
            let hex = try XCTUnwrap(c["bytes_hex"]?.string)
            var bytes: [UInt8] = []
            var i = hex.startIndex
            while i < hex.endIndex {
                let j = hex.index(i, offsetBy: 2)
                bytes.append(UInt8(hex[i..<j], radix: 16)!)
                i = j
            }
            let code = RecoveryCode.encode(bytes)
            XCTAssertEqual(code, c["code"]?.string)
            XCTAssertEqual(RecoveryCode.normalise(code), c["normalised"]?.string)
            XCTAssertEqual(RecoveryCode.hash(code), c["recovery_hash"]?.string)
        }
        for t in try XCTUnwrap(v["typed"]?.array) {
            XCTAssertEqual(RecoveryCode.normalise(try XCTUnwrap(t["typed"]?.string)), t["normalised"]?.string)
        }
    }
}
