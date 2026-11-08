import Foundation

/// How a shared session is cut into segments: the first ones short, so a short session reaches
/// R2 within seconds and a crash early loses little, then a minute each, so a long session makes
/// one upload a minute (a radio wake-up and a request each) and a failed upload retries at most a
/// minute of audio. Durations are in seconds of audio, cut at Ogg page boundaries (a page is about
/// one second).
enum SegmentPlan {
    static let seconds = [10, 20, 40, 60]

    /// Seconds in segment `n` (1-based): the last entry repeats.
    static func seconds(_ n: Int, _ plan: [Int] = seconds) -> Int { plan[min(n, plan.count) - 1] }
}

/// A closed segment of an `OggOpusWriter`.
struct OggSegment: Sendable {
    let n: Int
    let url: URL
    /// The granule position of its last page.
    let granule: Int64
    /// It holds the end of the stream.
    let last: Bool
}

/// Writes one session's audio as Ogg Opus while the session runs: mono, coded at 48 kHz with
/// `OpusSettings.shared` by libopus, muxed into Ogg per RFC 7845. Input at another rate (a 44.1 kHz
/// route, say) is resampled to 48 kHz first (`ShareResampler`), and OpusHead records the true input
/// rate. Non-finite samples are written as silence.
///
/// Pages carry about a second of packets (`OpusSettings.pagePackets`, 50 at 20 ms; fewer when 255
/// lacing values would not hold them) and each is written to disk as soon as it is full, so a
/// crash loses at most about a second: the packets not yet on a page, the partial frame and the
/// encoder's 6.5 ms lookahead. The stream is cut into consecutive segment files at page boundaries
/// (`plan`, seconds per segment, counted in packets so a segment is exactly that long; empty: one
/// file): segment 1 starts with OpusHead and OpusTags, the last page of the last segment has the
/// end-of-stream flag and the encoder's final granule position, and granule positions and page
/// sequence numbers run on, so the segments concatenated are exactly the one file.
final class OggOpusWriter {
    static let rate = Double(OpusSettings.codedRate)

    let settings: OpusSettings
    let inputRate: Double
    var packetFrames: Int { settings.packetFrames }
    var pagePackets: Int { settings.pagePackets }
    private let encoder: any OpusEncoding
    private let resampler: ShareResampler?
    private let serial: UInt32
    private let segmentURL: (Int) -> URL
    private let plan: [Int]
    private let onSegment: (OggSegment) -> Void
    private var handle: FileHandle?
    private var segment = 0
    /// Audio packets in the open segment (or the last closed one, until the next page opens one).
    private var segmentPackets = 0
    private var sequence: UInt32 = 0
    var preSkip: Int { encoder.preSkip }
    /// Input frames given to the writer, at the input rate.
    private(set) var inputFrames: Int64 = 0
    /// Non-finite input samples written as silence.
    private(set) var nonFiniteSamples: Int64 = 0
    private var ended = false
    /// Encoded packets not yet on a page.
    private var packets: [Data] = []
    /// Audio packets already on pages.
    private var paged: Int64 = 0
    private(set) var lastGranule: Int64 = 0
    /// The input with non-finite samples zeroed, reused between calls.
    private var clean: [Float] = []

    /// Segmented: `segmentURL(n)` names segment n's file, `onSegment` hears each one closed.
    /// `encoder` replaces libopus (tests); it is given 48 kHz input.
    init(segmentURL: @escaping (Int) -> URL, plan: [Int], inputRate: Double, settings: OpusSettings = .shared,
         serial: UInt32 = .random(in: 0...UInt32.max), encoder: (any OpusEncoding)? = nil, vendor: String? = nil,
         onSegment: @escaping (OggSegment) -> Void = { _ in }) throws(RecognizerError) {
        guard inputRate >= 8_000, inputRate <= 384_000, inputRate == inputRate.rounded() else {
            throw .unsupportedAudioFormat("\(inputRate) Hz")
        }
        self.segmentURL = segmentURL
        self.plan = plan
        self.inputRate = inputRate
        self.settings = settings
        self.serial = serial
        self.onSegment = onSegment
        resampler = inputRate == Self.rate ? nil : try ShareResampler(inputRate: inputRate)
        if let encoder {
            self.encoder = encoder
        } else {
            self.encoder = try LibOpusEncoder(sampleRate: OpusSettings.codedRate, channels: 1, settings: settings)
        }
        try page([Self.opusHead(preSkip: self.encoder.preSkip, inputRate: Int(inputRate))], granule: 0, flags: 0x02, audio: false)
        try page([Self.opusTags(vendor: vendor)], granule: 0, flags: 0, audio: false)
    }

    /// One file.
    convenience init(url: URL, inputRate: Double, settings: OpusSettings = .shared, serial: UInt32 = .random(in: 0...UInt32.max),
                     encoder: (any OpusEncoding)? = nil) throws(RecognizerError) {
        try self.init(segmentURL: { _ in url }, plan: [], inputRate: inputRate, settings: settings, serial: serial, encoder: encoder)
    }

    deinit {
        try? handle?.close()
    }

    /// Audio seconds written so far (at the input rate).
    var duration: TimeInterval { Double(inputFrames) / inputRate }

    /// Encodes mono samples at the input rate.
    func append(_ samples: [Float]) throws(RecognizerError) {
        guard !samples.isEmpty, !ended else { return }
        inputFrames += Int64(samples.count)
        if clean.count < samples.count { clean = [Float](repeating: 0, count: samples.count) }
        var bad = 0
        clean.withUnsafeMutableBufferPointer { c in
            samples.withUnsafeBufferPointer { s in
                for i in 0..<s.count {
                    let v = s[i]
                    if v.isFinite { c[i] = v } else { c[i] = 0; bad += 1 }
                }
            }
        }
        nonFiniteSamples += Int64(bad)
        let n = samples.count
        try clean.withUnsafeBufferPointer { (c) throws(RecognizerError) in
            let input = UnsafeBufferPointer(rebasing: c[0..<n])
            if let resampler {
                try resampler.process(input) { (x) throws(RecognizerError) in packets += try encoder.encode(x) }
            } else {
                packets += try encoder.encode(input)
            }
        }
        try writePages(final: false)
    }

    /// Flushes the resampler and the encoder, writes the last pages and closes the last segment.
    /// Returns the duration in milliseconds.
    @discardableResult
    func finish() throws(RecognizerError) -> Int {
        if !ended {
            ended = true
            try resampler?.flush { (x) throws(RecognizerError) in packets += try encoder.encode(x) }
            packets += try encoder.flush()
            try writePages(final: true)
            close(last: true)
        }
        return Int((duration * 1000).rounded())
    }

    /// Stops without finishing (the caller removes the files).
    func abandon() {
        ended = true
        try? handle?.close()
        handle = nil
    }

    /// Packets in segment `n` (nil: no limit).
    private func segmentLimit(_ n: Int) -> Int? {
        plan.isEmpty ? nil : Int((Double(SegmentPlan.seconds(n, plan)) * 1000 / settings.frameMs).rounded())
    }

    /// Writes every full page; with `final`, also the rest, the last page ending the stream.
    private func writePages(final: Bool) throws(RecognizerError) {
        while !packets.isEmpty {
            // the segment the next page goes into, and the packets it still takes
            let next = handle == nil ? segment + 1 : segment
            let used = handle == nil ? 0 : segmentPackets
            let room = segmentLimit(next).map { $0 - used } ?? Int.max
            let want = min(pagePackets, room)
            // as many as fit in 255 lacing values
            var take = 0, lacing = 0
            while take < min(want, packets.count) {
                let l = packets[take].count / 255 + 1
                if lacing + l > 255 { break }
                lacing += l
                take += 1
            }
            let full = take == want || take < packets.count
            guard full || final else { return }
            let last = final && take == packets.count
            let chunk = Array(packets.prefix(take))
            packets.removeFirst(take)
            var granule = (paged + Int64(take)) * Int64(packetFrames)
            if last {
                // RFC 7845: the last page's granule position trims the encoder's end padding
                granule = max(min(encoder.finalGranulePosition, granule), paged * Int64(packetFrames))
            }
            try page(chunk, granule: granule, flags: last ? 0x04 : 0)
        }
    }

    private func close(last: Bool) {
        guard let h = handle else { return }
        try? h.close()
        handle = nil
        onSegment(OggSegment(n: segment, url: segmentURL(segment), granule: lastGranule, last: last))
    }

    // MARK: Ogg

    private func page(_ packets: [Data], granule: Int64, flags: UInt8, audio: Bool = true) throws(RecognizerError) {
        var segments: [UInt8] = []
        for p in packets {
            var n = p.count
            while n >= 255 {
                segments.append(255)
                n -= 255
            }
            segments.append(UInt8(n))
        }
        precondition(segments.count <= 255, "an Ogg page holds at most 255 segments")
        var d = Data("OggS".utf8)
        d.append(0)
        d.append(flags)
        d.append(le: UInt64(bitPattern: granule))
        d.append(le: serial)
        d.append(le: sequence)
        d.append(le: UInt32(0))
        d.append(UInt8(segments.count))
        d.append(contentsOf: segments)
        for p in packets { d.append(p) }
        let crc = Self.crc(d)
        d.replaceSubrange(22..<26, with: withUnsafeBytes(of: crc.littleEndian) { Data($0) })
        if handle == nil {
            segment += 1
            segmentPackets = 0
            let url = segmentURL(segment)
            guard FileManager.default.createFile(atPath: url.path, contents: nil), let h = try? FileHandle(forWritingTo: url) else {
                throw .storageFailed("cannot create \(url.lastPathComponent)")
            }
            handle = h
        }
        do {
            try handle!.write(contentsOf: d)
        } catch {
            throw .storageFailed("cannot write \(segmentURL(segment).lastPathComponent): \(error.localizedDescription)")
        }
        sequence += 1
        lastGranule = granule
        if audio {
            paged += Int64(packets.count)
            segmentPackets += packets.count
            if flags & 0x04 == 0, let limit = segmentLimit(segment), segmentPackets >= limit {
                close(last: false)
            }
        }
    }

    /// RFC 7845 identification header; `inputRate` is the original capture rate (informational:
    /// Opus always decodes at 48 kHz), so the corpus knows when a session was resampled.
    static func opusHead(preSkip: Int, inputRate: Int) -> Data {
        var d = Data("OpusHead".utf8)
        d.append(1)
        d.append(1)
        d.append(le: UInt16(preSkip))
        d.append(le: UInt32(inputRate))
        d.append(le: UInt16(0))
        d.append(0)
        return d
    }

    /// RFC 7845 comment header: the vendor string (the SDK and libopus versions; tests may set another) and no tags.
    static func opusTags(vendor name: String? = nil) -> Data {
        let vendor = Data((name ?? "QuranLab SDK \(SDKInfo.version) \(OpusVersion.string)").utf8)
        var d = Data("OpusTags".utf8)
        d.append(le: UInt32(vendor.count))
        d.append(vendor)
        d.append(le: UInt32(0))
        return d
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var r = UInt32(i) << 24
        for _ in 0..<8 { r = r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04c1_1db7 : r << 1 }
        return r
    }

    /// The Ogg CRC-32: polynomial 0x04c11db7, no reflection, initial value 0.
    static func crc(_ d: Data) -> UInt32 {
        var c: UInt32 = 0
        for b in d { c = (c << 8) ^ table[Int(((c >> 24) & 0xff) ^ UInt32(b))] }
        return c
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(le v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}
