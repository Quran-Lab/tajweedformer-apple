import Foundation

/// The writer of one shared recording's segments: Ogg Opus (section 10) or, from 4.0, Ogg FLAC (SHARING_40.md 19.4).
/// The capture drives either the same way.
protocol ShareSegmentWriter: AnyObject {
    /// The capture rate the writer was made for.
    var inputRate: Double { get }
    /// Audio seconds written so far, at the input rate.
    var duration: TimeInterval { get }
    /// Mono samples at the input rate.
    func append(_ samples: [Float]) throws(RecognizerError)
    /// Ends the stream and closes the last segment; the duration in milliseconds.
    @discardableResult func finish() throws(RecognizerError) -> Int
    /// Stops without finishing (the caller removes the files).
    func abandon()
}

extension OggOpusWriter: ShareSegmentWriter {}

/// Which form a shared recording takes (SHARING_40.md 19.3, 19.8 item 1), decided once, at its first audio, for the
/// whole recording: Ogg FLAC at the capture rate when the rate is not 48000 and the signed config's
/// `flags.share_flac` is true; otherwise Ogg Opus exactly as section 10 (a 48 kHz capture always).
enum ShareCodec {
    /// The capture rate as the FLAC form carries it (19.5: a whole number 8000 to 192000, not 48000, with a frame
    /// header code, 19.4.3); nil for any other rate, which goes as Opus.
    static func flacRate(_ rate: Double) -> Int? {
        guard rate.isFinite, rate == rate.rounded(), rate >= 8_000, rate <= 192_000 else { return nil }
        let r = Int(rate)
        guard r != 48_000, FlacFrame.rateCode(r) != nil else { return nil }
        return r
    }

    /// Whether a recording captured at `rate` is FLAC under the switch `shareFlac`.
    static func flac(rate: Double, shareFlac: Bool) -> Bool { shareFlac && flacRate(rate) != nil }

    /// The switch in force now: the signed config's `flags.share_flac` (absent, or anything but true: off).
    static var shareFlac: Bool { QuranLab.cloud?.currentConfig?.flags.share_flac == true }

    /// 19.3: a float sample to the 16-bit integer FLAC codes. v = x * 32768 (exact); NaN gives 0; v at or above 32767
    /// gives 32767, at or below -32768 gives -32768; otherwise v rounded to the nearest integer, a tie to the even one.
    /// No gain, no dither, no filter.
    static func pcm16(_ x: Float) -> Int16 {
        if x.isNaN { return 0 }
        let v = x * 32768
        if v >= 32767 { return 32767 }
        if v <= -32768 { return -32768 }
        return Int16(v.rounded(.toNearestOrEven))
    }
}

/// The FLAC frame of SHARING_40.md 19.4.3: one mono block of 16-bit samples, fixed predictors only, integer arithmetic
/// only (what libFLAC 1.5.0 writes with block size 4096, LPC off, Rice partition orders 0 to 4, escape codes off and no
/// exhaustive search; `tools/sharing40.py` `encode_frame` is the reference). Every SDK writes the same bytes for the
/// same samples.
enum FlacFrame {
    /// 19.4: samples a frame holds (the last one of a stream holds 1 to 4096).
    static let block = 4096
    static let maxPartitionOrder = 4
    /// libFLAC's ceiling on a bit estimate.
    private static let estimateCap = 0xFFFF_FFFF

    /// RFC 9639 block size codes (19.4.3 step 1).
    private static let blockCodes: [Int: Int] = [192: 1, 576: 2, 1152: 3, 2304: 4, 4608: 5, 256: 8, 512: 9, 1024: 10, 2048: 11,
                                                 4096: 12]
    /// RFC 9639 sample rate codes (19.4.3 step 1).
    private static let rateCodes: [Int: Int] = [88_200: 1, 176_400: 2, 192_000: 3, 8_000: 4, 16_000: 5, 22_050: 6, 24_000: 7,
                                                32_000: 8, 44_100: 9, 48_000: 10, 96_000: 11]

    /// The frame header's 4-bit sample rate code and the field after the frame number (its value and bits), as
    /// libFLAC chooses them; nil for a rate no header can carry.
    static func rateCode(_ rate: Int) -> (code: Int, field: (value: Int, bits: Int)?)? {
        if let c = rateCodes[rate] { return (c, nil) }
        if rate > 0, rate <= 255_000, rate % 1000 == 0 { return (12, (rate / 1000, 8)) }
        if rate > 0, rate <= 655_350, rate % 10 == 0 { return (14, (rate / 10, 16)) }
        if rate > 0, rate <= 0xFFFF { return (13, (rate, 16)) }
        return nil
    }

    private enum Choice {
        case verbatim
        case constant
        case fixed(order: Int, residual: [Int], partitionOrder: Int, parameters: [Int])
    }

    /// The frame of `samples` (1 to 4096) as frame number `number` of a stream at `rate`, and the kind of its
    /// subframe: `constant`, `verbatim` or `fixed0` to `fixed4`. `rate` must have a code (`rateCode`).
    static func encode(_ samples: [Int16], number: Int, rate: Int) -> (bytes: [UInt8], kind: String) {
        let n = samples.count
        // step 2: the wasted bits, and the samples shifted right by them
        let w = wastedBits(samples)
        let x: [Int] = samples.map { (v: Int16) -> Int in Int(v) >> w }
        let sbps = 16 - w
        let limit = min(min(n.trailingZeroBitCount, 15), maxPartitionOrder)
        // step 3: verbatim first; a later kind wins only with a strictly smaller estimate
        var choice = Choice.verbatim
        var best = 8 + w + n * sbps
        if n > 4 {
            let guess = fixedOrder(x)
            if guess.t1 == 0, x.allSatisfy({ $0 == x[0] }) {
                let bits = 8 + w + sbps
                if bits < best {
                    choice = .constant
                    best = bits
                }
            } else {
                let res = residual(x, order: guess.order)
                let p = partition(res, n: n, order: guess.order, limit: limit)
                var est = 8 + w + guess.order * sbps
                est = p.bits < estimateCap - est ? est + p.bits : estimateCap
                if est < best {
                    choice = .fixed(order: guess.order, residual: res, partitionOrder: p.order, parameters: p.parameters)
                    best = est
                }
            }
        }
        // step 4: the subframe
        var b = FlacBits(capacity: 2 * n + 16)
        let flag = w > 0 ? 1 : 0
        let kind: String
        switch choice {
        case .constant:
            kind = "constant"
            b.put(0x00 | flag, 8)
            if w > 0 { b.unary(w - 1) }
            b.put(x[0], sbps)
        case .verbatim:
            kind = "verbatim"
            b.put(0x02 | flag, 8)
            if w > 0 { b.unary(w - 1) }
            for v in x { b.put(v, sbps) }
        case .fixed(let order, let res, let po, let params):
            kind = "fixed\(order)"
            b.put(0x10 | (order << 1) | flag, 8)
            if w > 0 { b.unary(w - 1) }
            for v in x[0..<order] { b.put(v, sbps) }
            // Rice coding with 4-bit parameters, then the partition order
            b.put(0, 2)
            b.put(po, 4)
            let base = n >> po
            var at = 0
            for (p, k) in params.enumerated() {
                let count = p == 0 ? base - order : base
                b.put(k, 4)
                for r in res[at..<(at + count)] {
                    let u = r >= 0 ? r << 1 : ((-r) << 1) - 1
                    b.unary(u >> k)
                    b.put(u & ((1 << k) - 1), k)
                }
                at += count
            }
        }
        // step 5: zero bits to the byte, then the CRC-16 of the whole frame
        b.pad()
        var frame = header(n: n, number: number, rate: rate)
        frame.append(contentsOf: b.bytes)
        let crc = crc16(frame)
        frame.append(UInt8(truncatingIfNeeded: crc >> 8))
        frame.append(UInt8(truncatingIfNeeded: crc))
        return (frame, kind)
    }

    /// Step 1: sync, fixed block size, the block size and rate codes, mono, 16 bits, the frame number coded like
    /// UTF-8, the block size and rate fields, and the CRC-8 of the header's bytes.
    static func header(n: Int, number: Int, rate: Int) -> [UInt8] {
        var b = FlacBits(capacity: 16)
        b.put(0x3FFE, 14)
        b.put(0, 1)
        // fixed block size: the header carries the frame number
        b.put(0, 1)
        let code: Int
        var size: (value: Int, bits: Int)?
        if let c = blockCodes[n] {
            code = c
        } else {
            // the block size in the header: n - 1 in 8 bits (code 6) or 16 bits (code 7)
            code = n <= 256 ? 6 : 7
            size = (n - 1, n <= 256 ? 8 : 16)
        }
        b.put(code, 4)
        let r = rateCode(rate)
        b.put(r?.code ?? 0, 4)
        // one channel, 16 bits a sample, a reserved 0
        b.put(0, 4)
        b.put(4, 3)
        b.put(0, 1)
        var head = b.bytes
        head.append(contentsOf: utf8Number(number))
        var tail = FlacBits(capacity: 4)
        if let size { tail.put(size.value, size.bits) }
        if let f = r?.field { tail.put(f.value, f.bits) }
        head.append(contentsOf: tail.bytes)
        head.append(crc8(head))
        return head
    }

    /// RFC 9639 9.1.5: the frame number in 1 to 6 bytes, coded like UTF-8.
    static func utf8Number(_ v: Int) -> [UInt8] {
        if v < 0x80 { return [UInt8(v)] }
        let forms: [(bytes: Int, lead: Int, limit: Int)] = [(2, 0xC0, 0x800), (3, 0xE0, 0x10000), (4, 0xF0, 0x20_0000),
                                                            (5, 0xF8, 0x400_0000), (6, 0xFC, 0x8000_0000)]
        for f in forms where v < f.limit {
            var out = [UInt8(f.lead | (v >> (6 * (f.bytes - 1))))]
            for i in stride(from: f.bytes - 2, through: 0, by: -1) { out.append(UInt8(0x80 | ((v >> (6 * i)) & 0x3F))) }
            return out
        }
        // a recording holds at most 20 minutes (`TakeJoin.capMs`): far below 2^31 frames
        preconditionFailure("a FLAC frame number above 2^31 - 1")
    }

    /// Step 2: the trailing zero bits every sample shares (libFLAC `get_wasted_bits_`): 0 for an all-zero block.
    static func wastedBits(_ samples: [Int16]) -> Int {
        var acc = 0
        for v in samples {
            acc |= Int(v)
            if acc & 1 != 0 { break }
        }
        return acc == 0 ? 0 : min(acc.trailingZeroBitCount, 16)
    }

    /// Step 3 (libFLAC `FLAC__fixed_compute_best_predictor`): the sums t0 to t4 of |error| of the five fixed
    /// predictors over samples 4 to n - 1 pick the order, a tie going to the lower order. Needs more than 4 samples.
    static func fixedOrder(_ x: [Int]) -> (order: Int, t1: Int) {
        var t0 = 0, t1 = 0, t2 = 0, t3 = 0, t4 = 0
        for i in 4..<x.count {
            let a = x[i], b = x[i - 1], c = x[i - 2], d = x[i - 3], e = x[i - 4]
            t0 += abs(a)
            t1 += abs(a - b)
            t2 += abs(a - 2 * b + c)
            t3 += abs(a - 3 * b + 3 * c - d)
            let e4 = a - 4 * b + 6 * c - 4 * d + e
            t4 += abs(e4)
        }
        let order: Int
        if t0 <= min(t1, t2, t3, t4) {
            order = 0
        } else if t1 <= min(t2, t3, t4) {
            order = 1
        } else if t2 <= min(t3, t4) {
            order = 2
        } else if t3 <= t4 {
            order = 3
        } else {
            order = 4
        }
        return (order, t1)
    }

    /// The fixed predictor's residual of `order`: e_order[i] for i = order to n - 1.
    static func residual(_ x: [Int], order: Int) -> [Int] {
        var r: [Int] = []
        r.reserveCapacity(x.count - order)
        for i in order..<x.count {
            switch order {
            case 0: r.append(x[i])
            case 1: r.append(x[i] - x[i - 1])
            case 2: r.append(x[i] - 2 * x[i - 1] + x[i - 2])
            case 3: r.append(x[i] - 3 * x[i - 1] + 3 * x[i - 2] - x[i - 3])
            default: r.append(x[i] - 4 * x[i - 1] + 6 * x[i - 2] - 4 * x[i - 3] + x[i - 4])
            }
        }
        return r
    }

    /// libFLAC `find_best_partition_order_`: every partition order from the highest allowed down to 0; the smallest
    /// estimate wins, a tie keeping the higher order (tried first).
    static func partition(_ res: [Int], n: Int, order: Int, limit: Int) -> (bits: Int, order: Int, parameters: [Int]) {
        var top = limit
        while top > 0, (n >> top) <= order { top -= 1 }
        let size = n >> top
        var sums: [Int] = []
        var at = 0
        for p in 0..<(1 << top) {
            let count = p == 0 ? size - order : size
            var s = 0
            for i in at..<(at + count) { s += abs(res[i]) }
            sums.append(s)
            at += count
        }
        var levels = [[Int]](repeating: [], count: top + 1)
        levels[top] = sums
        var po = top - 1
        while po >= 0 {
            let up = levels[po + 1]
            levels[po] = (0..<(1 << po)).map { (i: Int) -> Int in up[2 * i] + up[2 * i + 1] }
            po -= 1
        }
        var best = (bits: Int.max, order: top, parameters: [Int]())
        for p in stride(from: top, through: 0, by: -1) {
            let e = rice(levels[p], n: n, order: order, partitionOrder: p)
            if e.bits < best.bits { best = (e.bits, p, e.parameters) }
        }
        return best
    }

    /// libFLAC `set_partitioned_rice_` without parameter search or escapes: each partition's Rice parameter from its
    /// sum of |residual|, in integers, and the estimated bits of the whole residual.
    static func rice(_ sums: [Int], n: Int, order: Int, partitionOrder po: Int) -> (bits: Int, parameters: [Int]) {
        var bits = 2 + 4
        let base = n >> po
        let divBase = 0x40000 / base
        var params: [Int] = []
        for (p, s) in sums.enumerated() {
            let count = p == 0 ? base - order : base
            let div = p == 0 ? 0x40000 / count : divBase
            let q = s >= 2 ? ((s - 1) * div) >> 18 : 0
            // the bit length of q
            var k = q == 0 ? 0 : Int.bitWidth - q.leadingZeroBitCount
            if k >= 15 { k = 14 }
            var pb = 4 + (1 + k) * count + (k > 0 ? s >> (k - 1) : s << 1) - (count >> 1)
            pb = min(pb, estimateCap)
            bits = pb < estimateCap - bits ? bits + pb : estimateCap
            params.append(k)
        }
        return (bits, params)
    }

    private static let crc8Table: [UInt8] = (0..<256).map { (i: Int) -> UInt8 in
        var r = UInt8(i)
        for _ in 0..<8 { r = r & 0x80 != 0 ? (r << 1) ^ 0x07 : r << 1 }
        return r
    }

    private static let crc16Table: [UInt16] = (0..<256).map { (i: Int) -> UInt16 in
        var r = UInt16(i) << 8
        for _ in 0..<8 { r = r & 0x8000 != 0 ? (r << 1) ^ 0x8005 : r << 1 }
        return r
    }

    /// RFC 9639 9.1.8: polynomial 0x07, initial 0.
    static func crc8(_ b: [UInt8]) -> UInt8 {
        var c: UInt8 = 0
        for x in b { c = crc8Table[Int(c ^ x)] }
        return c
    }

    /// RFC 9639 9.3: polynomial 0x8005, initial 0.
    static func crc16(_ b: [UInt8]) -> UInt16 {
        var c: UInt16 = 0
        for x in b { c = (c << 8) ^ crc16Table[Int((c >> 8) ^ UInt16(x))] }
        return c
    }
}

/// An MSB-first bit writer.
struct FlacBits {
    private(set) var bytes: [UInt8] = []
    private var acc: UInt64 = 0
    /// Bits in `acc` not yet in `bytes` (fewer than 8 between calls).
    private var count = 0

    init(capacity: Int) { bytes.reserveCapacity(capacity) }

    /// The low `n` bits of `v` (two's complement for a negative value), n at most 32.
    mutating func put(_ v: Int, _ n: Int) {
        guard n > 0 else { return }
        acc = (acc << UInt64(n)) | (UInt64(truncatingIfNeeded: v) & ((UInt64(1) << UInt64(n)) - 1))
        count += n
        while count >= 8 {
            count -= 8
            bytes.append(UInt8(truncatingIfNeeded: acc >> UInt64(count)))
        }
        acc &= (UInt64(1) << UInt64(count)) - 1
    }

    /// `q` zero bits, then a one.
    mutating func unary(_ q: Int) {
        var q = q
        while q >= 32 {
            put(0, 32)
            q -= 32
        }
        put(1, q + 1)
    }

    /// Zero bits up to the byte boundary.
    mutating func pad() {
        if count > 0 { put(0, 8 - count) }
    }
}

/// Writes one shared recording as Ogg FLAC while it runs (SDK 4.0, SHARING_40.md 19.4): mono, 16-bit, at the capture
/// rate (no resampling: `ShareCodec.pcm16` of each sample), block size 4096, one FLAC frame per Ogg page (section 10's
/// page writer, `OggPage`), a random serial. Segment 1 starts with the two header pages (19.4.1); the granule of each
/// audio page is the samples through its frame; the last page of a finished stream ends it (0x04).
///
/// The one-frame hold (19.4.4): the page of the newest frame waits until the next frame is encoded (then it goes out as
/// a plain page) or the stream ends (then it is the end-of-stream page, after the samples left over are encoded as a
/// last frame of 1 to 4096). Segment k is closed once it has its ceil(T(k) * rate / 4096) frames (`plan`, seconds:
/// 10, 20, 40, then 60) and the frame after them exists, so no segment is empty and only the last page of a stream
/// holds a short frame. A crash loses at most the held frame and the samples not yet in a frame (8191 samples).
/// A stream with no sample writes no file.
final class OggFlacWriter: ShareSegmentWriter {
    let inputRate: Double
    let rate: Int
    private let serial: UInt32
    private let vendor: String
    private let segmentURL: (Int) -> URL
    private let plan: [Int]
    private let onSegment: (OggSegment) -> Void
    private var handle: FileHandle?
    private var segment = 0
    /// Audio pages in the open segment.
    private var segmentFrames = 0
    private var sequence: UInt32 = 0
    /// Samples given to the writer.
    private(set) var inputFrames: Int64 = 0
    /// Samples not yet in a frame (fewer than a block).
    private var pending: [Int16] = []
    /// The newest frame and its samples, held until the next frame exists or the stream ends.
    private var held: (frame: [UInt8], samples: Int)?
    /// Frames encoded: the next frame's number.
    private var frames = 0
    /// Samples through the last page written.
    private(set) var lastGranule: Int64 = 0
    private var ended = false

    /// `segmentURL(n)` names segment n's file, `onSegment` hears each one closed. `serial` and `vendor` are the
    /// tests' seam (19.8 item 4); the vendor is `QuranLab SDK <version>` otherwise.
    init(segmentURL: @escaping (Int) -> URL, plan: [Int], inputRate: Double, serial: UInt32 = .random(in: 0...UInt32.max),
         vendor: String? = nil, onSegment: @escaping (OggSegment) -> Void = { _ in }) throws(RecognizerError) {
        guard let rate = ShareCodec.flacRate(inputRate) else { throw .unsupportedAudioFormat("\(inputRate) Hz for FLAC") }
        self.inputRate = inputRate
        self.rate = rate
        self.serial = serial
        self.vendor = vendor ?? "QuranLab SDK \(SDKInfo.version)"
        self.segmentURL = segmentURL
        self.plan = plan
        self.onSegment = onSegment
        pending.reserveCapacity(FlacFrame.block)
    }

    deinit {
        try? handle?.close()
    }

    var duration: TimeInterval { Double(inputFrames) / inputRate }

    /// Float samples at the input rate, as 16-bit integers (19.3).
    func append(_ samples: [Float]) throws(RecognizerError) {
        guard !samples.isEmpty, !ended else { return }
        try append(pcm16: samples.map(ShareCodec.pcm16))
    }

    /// 16-bit samples as they are.
    func append(pcm16 samples: [Int16]) throws(RecognizerError) {
        guard !samples.isEmpty, !ended else { return }
        inputFrames += Int64(samples.count)
        var at = 0
        while at < samples.count {
            let k = min(FlacFrame.block - pending.count, samples.count - at)
            pending.append(contentsOf: samples[at..<(at + k)])
            at += k
            if pending.count == FlacFrame.block { try encodePending() }
        }
    }

    /// The pending samples become the next frame; the frame held before it is not the last, and its page goes out.
    private func encodePending() throws(RecognizerError) {
        let f = FlacFrame.encode(pending, number: frames, rate: rate).bytes
        let n = pending.count
        frames += 1
        pending.removeAll(keepingCapacity: true)
        if let h = held { try page(h.frame, samples: h.samples, last: false) }
        held = (f, n)
    }

    /// Encodes the samples left over as the last frame, writes the held page as the end of the stream and closes the
    /// last segment. Returns the duration in milliseconds.
    @discardableResult
    func finish() throws(RecognizerError) -> Int {
        if !ended {
            ended = true
            if !pending.isEmpty { try encodePending() }
            if let h = held {
                held = nil
                try page(h.frame, samples: h.samples, last: true)
            }
            close(last: true)
        }
        return Int((duration * 1000).rounded())
    }

    /// Stops without finishing (the caller removes the files).
    func abandon() {
        ended = true
        held = nil
        pending = []
        try? handle?.close()
        handle = nil
    }

    /// Frames in segment `n` (nil: no limit): ceil(T * rate / 4096) in integers.
    private func segmentLimit(_ n: Int) -> Int? {
        plan.isEmpty ? nil : (SegmentPlan.seconds(n, plan) * rate + FlacFrame.block - 1) / FlacFrame.block
    }

    /// One frame's page (the two header pages first, before the first one).
    private func page(_ frame: [UInt8], samples: Int, last: Bool) throws(RecognizerError) {
        if sequence == 0 {
            try write(OggPage.make([Self.mappingPacket(rate: rate)], granule: 0, serial: serial, sequence: 0, flags: 0x02))
            try write(OggPage.make([Self.commentPacket(vendor: vendor)], granule: 0, serial: serial, sequence: 1, flags: 0))
        }
        let granule = lastGranule + Int64(samples)
        try write(OggPage.make([Data(frame)], granule: granule, serial: serial, sequence: sequence, flags: last ? 0x04 : 0))
        lastGranule = granule
        segmentFrames += 1
        if !last, let limit = segmentLimit(segment), segmentFrames >= limit { close(last: false) }
    }

    private func write(_ d: Data) throws(RecognizerError) {
        // tests: a full disk (section 29)
        guard !ShareFiles.refusesWrites.withLock({ $0 }) else { throw .storageFailed("cannot write a page: the disk is full") }
        if handle == nil {
            segment += 1
            segmentFrames = 0
            let url = segmentURL(segment)
            guard FileManager.default.createFile(atPath: url.path, contents: nil), let h = try? FileHandle(forWritingTo: url) else {
                throw .storageFailed("cannot create \(url.lastPathComponent)")
            }
            handle = h
            // the segment's file gets the protection class of the SDK's storage by name (3.1.4)
            StorageProtection.set(url)
        }
        do {
            try handle!.write(contentsOf: d)
        } catch {
            throw .storageFailed("cannot write \(segmentURL(segment).lastPathComponent): \(error.localizedDescription)")
        }
        sequence += 1
    }

    private func close(last: Bool) {
        guard let h = handle else { return }
        try? h.close()
        handle = nil
        onSegment(OggSegment(n: segment, url: segmentURL(segment), granule: lastGranule, last: last, bitrate: 0, rate: rate))
    }

    /// 19.4.1, page 0's packet (51 bytes): 0x7F "FLAC", mapping 1.0, one header packet follows, "fLaC", and STREAMINFO
    /// (not the last block): block size 4096 both ways, frame sizes unknown (0), the rate, mono, 16 bits, total
    /// samples and MD5 unknown (0).
    static func mappingPacket(rate: Int) -> Data {
        var d = Data([0x7F, 0x46, 0x4C, 0x41, 0x43, 0x01, 0x00, 0x00, 0x01])
        d.append(contentsOf: Array("fLaC".utf8))
        d.append(contentsOf: [0x00, 0x00, 0x00, 0x22])
        let block = UInt16(FlacFrame.block)
        for _ in 0..<2 { d.append(contentsOf: [UInt8(block >> 8), UInt8(block & 0xFF)]) }
        d.append(contentsOf: [UInt8](repeating: 0, count: 6))
        // the rate (20 bits), channels - 1 = 0 (3 bits), bits per sample - 1 = 15 (5 bits), total samples 0 (36 bits)
        let packed = UInt64(rate) << 44 | UInt64(15) << 36
        for s in stride(from: 56, through: 0, by: -8) { d.append(UInt8(truncatingIfNeeded: packed >> UInt64(s))) }
        d.append(contentsOf: [UInt8](repeating: 0, count: 16))
        return d
    }

    /// 19.4.1, page 1's packet: the last metadata block, VORBIS_COMMENT (0x84, its length in 24 bits big endian), the
    /// vendor and no comments.
    static func commentPacket(vendor: String) -> Data {
        let v = Data(vendor.utf8)
        var body = Data()
        body.append(le: UInt32(v.count))
        body.append(v)
        body.append(le: UInt32(0))
        var d = Data([0x84, UInt8(truncatingIfNeeded: body.count >> 16), UInt8(truncatingIfNeeded: body.count >> 8),
                      UInt8(truncatingIfNeeded: body.count)])
        d.append(body)
        return d
    }
}
