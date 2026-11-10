import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// An accelerator program rebuilt on the device from the CPU engine's int8 weights plus a small delta (QLPD1, the
/// shared format of Quran Lab's release tools, `progdelta.py`): the CoreML build's `weights/weight.bin` arrives as
/// `weight.bin.qlpd` (roles `coreml-delta`, `coreml-compact-delta`), a fraction of its size, because the weights it
/// stands on are already on the device. The rebuilt file must be byte-identical to the program verified on hardware:
/// its SHA-256 is checked against the delta's header and the manifest before CoreML ever sees it.
///
/// Format (little endian): `QLPD1\n`, u32 header length, header JSON, scales (f32), body. The body is the target file
/// with every predicted byte range replaced by its residual against the prediction:
/// - int8 (compact linears, NPU codes): p = clamp(rint(((sign * c) * s_t) / s_ch), -127, 127) in double arithmetic,
///   round half even; byte = (uint8)p ^ (flip ? 0x80 : 0); target = residual + byte (mod 256); the predicted bytes in
///   the stored layout (rowmajor, transposed, colblockB, TcolblockB, unitsHxB).
/// - fp16 (default linears): w = fp16((float)c * s_t), round to nearest even, as u16; with o(u) = u < 0x8000 ? u :
///   -1 - (u & 0x7fff), target = unordered(o(w) + residual) (16-bit wrap), the residual stored as n low bytes then n
///   high bytes.
///
/// Streaming: the delta and the CPU files are memory-mapped, the body is copied to the output file in pieces and the
/// predicted ranges are patched in a shared mapping of that file, one tensor at a time (memory: one tensor's
/// prediction, a few MB at most, plus the page cache).
enum ProgramDelta {
    static let magic: [UInt8] = Array("QLPD1\n".utf8)

    struct Tensor: Sendable {
        var src: String
        var transposed: Bool
        var kind: String          // int8 | fp16
        var sign: Int
        var flip: Bool
        var layout: String
        var scalesFirst: Int
        var scalesCount: Int
        /// [target offset, layout offset, length] or [target offset, layout offset, unit, count, stride].
        var regions: [[Int]]
    }

    struct Header: Sendable {
        var targetName: String
        var targetSize: Int
        var targetSHA256: String
        /// file name -> SHA-256 of the CPU files the delta was made against.
        var cpu: [String: String]
        var scalesBytes: Int
        var tensors: [Tensor]
    }

    /// The CPU files a delta stands on (decoded, verified): `layers.zfw`, `frontend.zfw`, and the context's
    /// `model_engine2.onnx.zfg` and `.zfg.bin`; with their SHA-256 when the caller knows them (the manifest's).
    struct CPUFiles: Sendable {
        var layers: URL
        var frontend: URL
        var zfg: URL
        var zfgBin: URL
        var layersSHA256: String?
        var frontendSHA256: String?

        /// A model folder: the shared files at the root, the context's graph under `<context>/`; or a flat folder.
        init(folder: URL, context: String, layersSHA256: String? = nil, frontendSHA256: String? = nil) {
            func path(_ name: String) -> URL {
                let flat = folder.appendingPathComponent(name)
                return FileManager.default.fileExists(atPath: flat.path) ? flat : folder.appendingPathComponent(context).appendingPathComponent(name)
            }
            layers = path("layers.zfw")
            frontend = path("frontend.zfw")
            zfg = path("model_engine2.onnx.zfg")
            zfgBin = path("model_engine2.onnx.zfg.bin")
            self.layersSHA256 = layersSHA256
            self.frontendSHA256 = frontendSHA256
        }
    }

    static func fail(_ why: String) -> RecognizerError { .checksumMismatch(file: "program delta: " + why) }

    // MARK: header

    static func header(_ d: Data) throws(RecognizerError) -> (Header, scalesAt: Int, bodyAt: Int) {
        guard d.count >= 10, Array(d.prefix(6)) == magic else { throw fail("not a QLPD1 file") }
        let hl = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt32.self) }.littleEndian)
        guard hl > 0, 10 + hl <= d.count, let j = JSONValue(data: d.subdata(in: 10..<(10 + hl))) else { throw fail("bad header") }
        guard let t = j["target"], let size = t["size"]?.number, let sha = t["sha256"]?.string, sha.count == 64,
              let sb = j["scales_bytes"]?.number, sb >= 0, Int(sb) % 4 == 0 else { throw fail("header lacks target or scales") }
        var cpu: [String: String] = [:]
        for (k, v) in j["cpu"]?.object ?? [:] { if let s = v.string { cpu[k] = s.lowercased() } }
        var tensors: [Tensor] = []
        for x in j["tensors"]?.array ?? [] {
            guard let src = x["src"]?.string, let kind = x["kind"]?.string, kind == "int8" || kind == "fp16" else { throw fail("bad tensor") }
            var regions: [[Int]] = []
            for r in x["regions"]?.array ?? [] {
                let v = (r.array ?? []).compactMap { $0.number.map { Int($0) } }
                guard v.count == 3 || v.count == 5 else { throw fail("bad region in \(src)") }
                regions.append(v)
            }
            let sc = (x["scales"]?.array ?? []).compactMap { $0.number.map { Int($0) } }
            tensors.append(Tensor(src: src, transposed: x["transposed"]?.bool ?? false, kind: kind,
                                  sign: Int(x["sign"]?.number ?? 1), flip: x["flip"]?.bool ?? false,
                                  layout: x["layout"]?.string ?? "rowmajor", scalesFirst: sc.first ?? 0,
                                  scalesCount: sc.count > 1 ? sc[1] : 0, regions: regions))
        }
        let h = Header(targetName: t["name"]?.string ?? "", targetSize: Int(size), targetSHA256: sha.lowercased(), cpu: cpu,
                       scalesBytes: Int(sb), tensors: tensors)
        let scalesAt = 10 + hl, bodyAt = scalesAt + h.scalesBytes
        guard bodyAt + h.targetSize <= d.count else { throw fail("truncated body") }
        return (h, scalesAt, bodyAt)
    }

    // MARK: CPU tensors

    /// A ZFW1 file's table: name -> (dtype, offset, bytes).
    struct ZFW {
        let data: Data
        let table: [String: (dtype: UInt32, offset: Int, bytes: Int)]

        init(_ url: URL) throws(RecognizerError) {
            guard let d = try? Data(contentsOf: url, options: .alwaysMapped), d.count >= 12, Array(d.prefix(4)) == Array("ZFW1".utf8) else {
                throw ProgramDelta.fail("\(url.lastPathComponent) is not a zfw file")
            }
            let count = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }.littleEndian)
            var t: [String: (UInt32, Int, Int)] = [:]
            // (Data.withUnsafeBytes rethrows untyped errors: the closure returns what went wrong instead)
            let problem: String? = d.withUnsafeBytes { (r: UnsafeRawBufferPointer) -> String? in
                for i in 0..<count {
                    let p = 12 + i * 68
                    guard p + 68 <= r.count else { return "zfw table runs past the end" }
                    let nameBytes = UnsafeRawBufferPointer(rebasing: r[p..<(p + 40)]).prefix { $0 != 0 }
                    let name = String(decoding: nameBytes, as: UTF8.self)
                    let dt = r.loadUnaligned(fromByteOffset: p + 40, as: UInt32.self).littleEndian
                    let off = Int(r.loadUnaligned(fromByteOffset: p + 44, as: UInt32.self).littleEndian)
                    let nb = Int(r.loadUnaligned(fromByteOffset: p + 48, as: UInt32.self).littleEndian)
                    guard off + nb <= r.count else { return "zfw tensor outside the file" }
                    t[name] = (dt, off, nb)
                }
                return nil
            }
            if let problem { throw ProgramDelta.fail(problem) }
            data = d
            table = t.mapValues { (dtype: $0.0, offset: $0.1, bytes: $0.2) }
        }

        func int32s(_ name: String) -> [Int32]? {
            guard let e = table[name], e.dtype == 2 else { return nil }
            return data.withUnsafeBytes { r in (0..<(e.bytes / 4)).map { Int32(littleEndian: r.loadUnaligned(fromByteOffset: e.offset + 4 * $0, as: Int32.self)) } }
        }

        func float(_ name: String) -> Float? {
            guard let e = table[name], e.dtype == 0, e.bytes >= 4 else { return nil }
            return data.withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: e.offset, as: UInt32.self))) }
        }
    }

    /// The engine's [n, k] codes of one int8 linear and its per-tensor scale.
    struct Codes {
        let n: Int, k: Int
        let codes: [Int8]   // [n, k] row major
        let scale: Float
    }

    /// The engine's pairing layout (16-wide k groups, 4-row n tiles) back to [n, k] row major.
    static func unpack(_ packed: UnsafeRawBufferPointer, k: Int, n: Int) -> [Int8] {
        let kp = (k + 15) / 16 * 16
        var out = [Int8](repeating: 0, count: n * k)
        for r in 0..<n {
            let a = r / 4, b = r % 4
            for j in 0..<k {
                let g = j / 16, e = j % 16
                let idx = ((a * (kp / 16) + g) * 4 + b) * 16 + e
                out[r * k + j] = Int8(bitPattern: packed[idx])
            }
        }
        return out
    }

    /// The CPU files, opened once for a rebuild.
    final class CPU {
        let layers: ZFW, frontend: ZFW
        let zfgBin: Data
        /// packed init name -> (k, n, packed offset/bytes, scale offset)
        var linears: [String: (k: Int, n: Int, off: Int, bytes: Int, scaleOff: Int)] = [:]

        init(_ f: CPUFiles) throws(RecognizerError) {
            layers = try ZFW(f.layers)
            frontend = try ZFW(f.frontend)
            guard let bin = try? Data(contentsOf: f.zfgBin, options: .alwaysMapped),
                  let text = try? String(contentsOf: f.zfg, encoding: .utf8) else { throw ProgramDelta.fail("the context's graph files") }
            zfgBin = bin
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var inits: [String: (Int, Int)] = [:]
            for l in lines where l.hasPrefix("init ") {
                let p = l.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard p.count >= 4, let o = Int(p[p.count - 2]), let nb = Int(p[p.count - 1]) else { continue }
                inits[p[1]] = (o, nb)
            }
            for (i, l) in lines.enumerated() where l.contains(" ZfLinearS8 ") && i + 2 < lines.count {
                let p = l.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard p.count > 8, let k = lines[i + 1].split(separator: " ").last.flatMap({ Int($0) }),
                      let n = lines[i + 2].split(separator: " ").last.flatMap({ Int($0) }),
                      let pk = inits[p[6]], let sc = inits[p[8]] else { continue }
                linears[p[6]] = (k, n, pk.0, pk.1, sc.0)
            }
        }

        func codes(_ src: String) throws(RecognizerError) -> Codes {
            if src.hasPrefix("zfg:") {
                let name = String(src.dropFirst(4))
                guard let e = linears[name], e.off + e.bytes <= zfgBin.count, e.scaleOff + 4 <= zfgBin.count else {
                    throw ProgramDelta.fail("no linear \(name) in the graph")
                }
                let codes = zfgBin.withUnsafeBytes { ProgramDelta.unpack(UnsafeRawBufferPointer(rebasing: $0[e.off..<(e.off + e.bytes)]), k: e.k, n: e.n) }
                let s = zfgBin.withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: e.scaleOff, as: UInt32.self))) }
                return Codes(n: e.n, k: e.k, codes: codes, scale: s)
            }
            let parts = src.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw ProgramDelta.fail("bad source \(src)") }
            let z: ZFW
            switch parts[0] {
            case "layers.zfw": z = layers
            case "frontend.zfw": z = frontend
            default: throw ProgramDelta.fail("bad source \(src)")
            }
            let pre = parts[1]
            guard let sh = z.int32s(pre + ".shape"), sh.count == 2, let pk = z.table[pre + ".packed"], pk.dtype == 1,
                  let s = z.float(pre + ".scale") else { throw ProgramDelta.fail("no int8 linear \(src)") }
            let k = Int(sh[0]), n = Int(sh[1])
            guard (n + 3) / 4 * 4 * ((k + 15) / 16 * 16) <= pk.bytes else { throw ProgramDelta.fail("\(src) is short") }
            let codes = z.data.withUnsafeBytes { ProgramDelta.unpack(UnsafeRawBufferPointer(rebasing: $0[pk.offset..<(pk.offset + pk.bytes)]), k: k, n: n) }
            return Codes(n: n, k: k, codes: codes, scale: s)
        }
    }

    // MARK: predictions

    /// The stored matrix [R, C] (the codes, or their transpose) as row-major values via `value(r, c)`.
    static func stored(_ c: Codes, transposed: Bool) -> (rows: Int, cols: Int, at: (Int, Int) -> Int8) {
        transposed ? (c.k, c.n, { r, col in c.codes[col * c.k + r] }) : (c.n, c.k, { r, col in c.codes[r * c.k + col] })
    }

    /// The row-major stored matrix's bytes in `layout` order.
    static func arrange(_ m: [UInt8], rows R: Int, cols C: Int, layout: String) throws(RecognizerError) -> [UInt8] {
        if layout == "rowmajor" { return m }
        var out = [UInt8](repeating: 0, count: m.count)
        if layout == "transposed" {
            for r in 0..<R { for c in 0..<C { out[c * R + r] = m[r * C + c] } }
            return out
        }
        if layout.hasPrefix("Tcolblock") {
            // colblock<B> of the transpose [C, R]
            guard let b = Int(layout.dropFirst(9)), b > 0, R % b == 0 else { throw fail("bad layout \(layout)") }
            var t = [UInt8](repeating: 0, count: m.count)
            for r in 0..<R { for c in 0..<C { t[c * R + r] = m[r * C + c] } }
            return try arrange(t, rows: C, cols: R, layout: "colblock\(b)")
        }
        if layout.hasPrefix("units") {
            let hb = layout.dropFirst(5).split(separator: "x").compactMap { Int($0) }
            guard hb.count == 2, hb[0] > 0, hb[1] > 0, R % hb[0] == 0, C % hb[1] == 0 else { throw fail("bad layout \(layout)") }
            let h = hb[0], b = hb[1], gc = C / b
            var i = 0
            for a in 0..<(R / h) { for g in 0..<gc { for y in 0..<h { for x in 0..<b {
                out[i] = m[(a * h + y) * C + g * b + x]
                i += 1
            } } } }
            return out
        }
        guard layout.hasPrefix("colblock"), let b = Int(layout.dropFirst(8)), b > 0, C % b == 0 else { throw fail("bad layout \(layout)") }
        var i = 0
        for blk in 0..<(C / b) { for r in 0..<R { for x in 0..<b {
            out[i] = m[r * C + blk * b + x]
            i += 1
        } } }
        return out
    }

    static func predictInt8(_ c: Codes, _ t: Tensor, scales: [Float]) throws(RecognizerError) -> [UInt8] {
        let s = stored(c, transposed: t.transposed)
        guard t.scalesFirst >= 0, t.scalesFirst + max(1, t.scalesCount) <= scales.count else { throw fail("scales out of range") }
        let perRow = t.scalesCount == s.rows && t.scalesCount > 1
        let perCol = !perRow && t.scalesCount > 1
        if perCol && t.scalesCount != s.cols { throw fail("scales do not fit \(t.src)") }
        var m = [UInt8](repeating: 0, count: s.rows * s.cols)
        let st = Double(c.scale), sign = Double(t.sign)
        for r in 0..<s.rows {
            for col in 0..<s.cols {
                let sch = Double(scales[t.scalesFirst + (perRow ? r : perCol ? col : 0)])
                let x = (sign * Double(s.at(r, col))) * st
                let p = min(127, max(-127, (x / sch).rounded(.toNearestOrEven)))
                var u = UInt8(bitPattern: Int8(p))
                if t.flip { u ^= 0x80 }
                m[r * s.cols + col] = u
            }
        }
        return try arrange(m, rows: s.rows, cols: s.cols, layout: t.layout)
    }

    /// f32 to IEEE half bits, round to nearest even (what numpy's astype(float16) does).
    static func half(_ f: Float) -> UInt16 {
        let x = f.bitPattern
        let sign = UInt16((x >> 16) & 0x8000)
        let exp = Int((x >> 23) & 0xff), mant = x & 0x7f_ffff
        if exp == 0xff { return sign | 0x7c00 | (mant != 0 ? 0x200 : 0) }
        let e = exp - 127 + 15
        if e >= 0x1f { return sign | 0x7c00 }
        if e <= 0 {
            if e < -10 { return sign }
            let m = mant | 0x80_0000
            let shift = UInt32(14 - e)
            var h = m >> shift
            let rem = m & ((1 << shift) - 1), halfway = UInt32(1) << (shift - 1)
            if rem > halfway || (rem == halfway && (h & 1) == 1) { h += 1 }
            return sign | UInt16(h)
        }
        var h = UInt32(e) << 10 | (mant >> 13)
        let rem = mant & 0x1fff
        if rem > 0x1000 || (rem == 0x1000 && (h & 1) == 1) { h += 1 }
        return sign | UInt16(truncatingIfNeeded: h)
    }

    static func predictFP16(_ c: Codes, _ t: Tensor) -> [UInt16] {
        let s = stored(c, transposed: t.transposed)
        var out = [UInt16](repeating: 0, count: s.rows * s.cols)
        for r in 0..<s.rows { for col in 0..<s.cols { out[r * s.cols + col] = half(Float(s.at(r, col)) * c.scale) } }
        return out
    }

    static func ordered(_ u: UInt16) -> Int32 { u < 0x8000 ? Int32(u) : -1 - Int32(u & 0x7fff) }
    static func unordered(_ o: Int32) -> UInt16 { o >= 0 ? UInt16(o) : 0x8000 | UInt16(-1 - o) }

    // MARK: rebuild

    /// Rebuilds the program of `delta` (the decoded .qlpd) from `cpu` into `out` (written as `<out>.part`, checked,
    /// renamed). Refuses CPU files other than the delta's, and any result whose size or SHA-256 is not the header's
    /// and `expectedSHA256` (the manifest's entry for the program) when given. Returns the SHA-256.
    @discardableResult
    static func rebuild(delta: URL, cpu files: CPUFiles, to out: URL, expectedSHA256: String? = nil,
                        expectedSize: Int64? = nil) throws(RecognizerError) -> String {
        guard let d = try? Data(contentsOf: delta, options: .alwaysMapped) else { throw fail("cannot read \(delta.lastPathComponent)") }
        let (h, scalesAt, bodyAt) = try header(d)
        if let e = expectedSHA256, e.lowercased() != h.targetSHA256 { throw fail("rebuilds another program than the manifest lists") }
        if let s = expectedSize, Int(s) != h.targetSize { throw fail("rebuilds a program of another size") }
        // the CPU files must be the ones the delta was made against (the graph data is checked through the target hash)
        for (name, sha) in h.cpu where name != "model_engine2.onnx.zfg.bin" {
            var have: String?
            switch name {
            case "layers.zfw":
                have = files.layersSHA256
                if have == nil { have = try ModelManifest.digest(files.layers).1 }
            case "frontend.zfw":
                have = files.frontendSHA256
                if have == nil { have = try ModelManifest.digest(files.frontend).1 }
            default:
                have = nil
            }
            guard have?.lowercased() == sha else { throw fail("CPU file \(name) is not the one this delta was made against") }
        }
        let scales: [Float] = d.withUnsafeBytes { r in
            (0..<(h.scalesBytes / 4)).map { Float(bitPattern: UInt32(littleEndian: r.loadUnaligned(fromByteOffset: scalesAt + 4 * $0, as: UInt32.self))) }
        }
        let fm = FileManager.default
        let part = out.appendingPathExtension("part")
        try? fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: part)
        // the body, copied in pieces
        guard fm.createFile(atPath: part.path, contents: nil), let w = try? FileHandle(forWritingTo: part) else {
            throw .storageFailed("cannot create \(part.lastPathComponent)")
        }
        do {
            var at = 0
            while at < h.targetSize {
                let n = min(8 << 20, h.targetSize - at)
                try w.write(contentsOf: d.subdata(in: (bodyAt + at)..<(bodyAt + at + n)))
                at += n
            }
            try w.close()
        } catch {
            try? w.close()
            try? fm.removeItem(at: part)
            throw .storageFailed("cannot write \(part.lastPathComponent): \(error.localizedDescription)")
        }
        do throws(RecognizerError) {
            try patch(part, size: h.targetSize, header: h, scales: scales, cpu: try CPU(files))
            let (size, sha) = try ModelManifest.digest(part)
            guard size == Int64(h.targetSize), sha == h.targetSHA256 else { throw fail("the rebuilt program's SHA-256 differs from the delta's") }
            if let e = expectedSHA256, e.lowercased() != sha { throw fail("the rebuilt program's SHA-256 differs from the manifest's") }
            try? fm.removeItem(at: out)
            do { try fm.moveItem(at: part, to: out) } catch { throw RecognizerError.storageFailed("cannot place \(out.lastPathComponent)") }
            return sha
        } catch {
            try? fm.removeItem(at: part)
            throw error
        }
    }

    /// Adds the predictions to the residuals in place, in a shared mapping of the output file.
    static func patch(_ url: URL, size: Int, header h: Header, scales: [Float], cpu: CPU) throws(RecognizerError) {
        guard size > 0, !h.tensors.isEmpty else { return }
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { throw .storageFailed("cannot open \(url.lastPathComponent)") }
        defer { close(fd) }
        guard let base = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), base != MAP_FAILED else {
            throw .storageFailed("cannot map \(url.lastPathComponent)")
        }
        defer { munmap(base, size) }
        let out = base.assumingMemoryBound(to: UInt8.self)
        func inRange(_ off: Int, _ n: Int) -> Bool { off >= 0 && n >= 0 && off + n <= size }
        for t in h.tensors {
            let c = try cpu.codes(t.src)
            if t.kind == "int8" {
                let p = try predictInt8(c, t, scales: scales)
                for g in t.regions {
                    if g.count == 3 {
                        let (off, lo, n) = (g[0], g[1], g[2])
                        guard inRange(off, n), lo >= 0, lo + n <= p.count else { throw fail("region outside \(t.src)") }
                        for i in 0..<n { out[off + i] = out[off + i] &+ p[lo + i] }
                    } else {
                        let (off, lo, u, cnt, st) = (g[0], g[1], g[2], g[3], g[4])
                        guard u >= 0, cnt >= 0, lo >= 0, lo + u * cnt <= p.count else { throw fail("run outside \(t.src)") }
                        for i in 0..<cnt {
                            let at = off + st * i
                            guard inRange(at, u) else { throw fail("run outside the program") }
                            for b in 0..<u { out[at + b] = out[at + b] &+ p[lo + i * u + b] }
                        }
                    }
                }
            } else {
                let p = predictFP16(c, t)
                for g in t.regions {
                    guard g.count == 3 else { throw fail("bad fp16 region") }
                    let (off, lo, n) = (g[0], g[1], g[2])
                    guard inRange(off, 2 * n), lo >= 0, lo + n <= p.count else { throw fail("region outside \(t.src)") }
                    // n low bytes then n high bytes in, n little-endian values out: read all residuals first
                    var res = [Int32](repeating: 0, count: n)
                    for i in 0..<n { res[i] = Int32(out[off + i]) | (Int32(out[off + n + i]) << 8) }
                    for i in 0..<n {
                        var o = ordered(p[lo + i]) + res[i]
                        o = ((o + 32768) % 65536 + 65536) % 65536 - 32768
                        let v = unordered(o)
                        out[off + 2 * i] = UInt8(v & 0xff)
                        out[off + 2 * i + 1] = UInt8(v >> 8)
                    }
                }
            }
        }
        msync(base, size, MS_SYNC)
    }
}
