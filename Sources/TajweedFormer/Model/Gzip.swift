import Compression
import CryptoKit
import Foundation

/// gzip (RFC 1952, one member) decoded into a file, with the Compression framework's raw DEFLATE decoder.
/// The input is memory mapped and the output written in 1 MB pieces, hashed as it goes, so memory stays small
/// whatever the file size. The trailer's ISIZE and CRC-32 are checked; the caller checks the size and SHA-256 the
/// manifest gives for the decoded file.
enum Gzip {
    struct Output: Sendable {
        let size: Int64
        let sha256: String
    }

    static func inflate(_ src: URL, to dst: URL) throws(RecognizerError) -> Output {
        let data: Data
        do { data = try Data(contentsOf: src, options: .alwaysMapped) } catch {
            throw .modelMissing("cannot read \(src.lastPathComponent)")
        }
        let bad = RecognizerError.checksumMismatch(file: src.lastPathComponent + " (not a gzip file)")
        guard data.count >= 18, data[0] == 0x1f, data[1] == 0x8b, data[2] == 8 else { throw bad }
        let flags = data[3]
        var at = 10
        if flags & 0x04 != 0 {
            guard at + 2 <= data.count else { throw bad }
            at += 2 + (Int(data[at]) | (Int(data[at + 1]) << 8))
        }
        for bit in [UInt8(0x08), 0x10] where flags & bit != 0 {   // file name, comment: NUL-terminated
            while at < data.count, data[at] != 0 { at += 1 }
            at += 1
        }
        if flags & 0x02 != 0 { at += 2 }
        guard at < data.count - 8 else { throw bad }
        let trailer = data.count - 8
        let isize = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[trailer + 4 + $1]) << (8 * $1) }
        let crcWant = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[trailer + $1]) << (8 * $1) }

        let fm = FileManager.default
        try? fm.removeItem(at: dst)
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: dst.path, contents: nil), let out = try? FileHandle(forWritingTo: dst) else {
            throw .storageFailed("cannot create \(dst.lastPathComponent)")
        }
        defer { try? out.close() }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw .storageFailed("cannot start the DEFLATE decoder")
        }
        defer { compression_stream_destroy(stream) }
        let cap = 1 << 20
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { buf.deallocate() }
        var hasher = SHA256()
        var crc = CRC32()
        var total: Int64 = 0
        var failure: RecognizerError?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            stream.pointee.src_ptr = base + at
            stream.pointee.src_size = trailer - at
            while true {
                stream.pointee.dst_ptr = buf
                stream.pointee.dst_size = cap
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let n = cap - stream.pointee.dst_size
                if n > 0 {
                    let piece = Data(bytes: buf, count: n)
                    hasher.update(data: piece)
                    crc.update(piece)
                    total += Int64(n)
                    do { try out.write(contentsOf: piece) } catch {
                        failure = .storageFailed("cannot write \(dst.lastPathComponent): \(error.localizedDescription)")
                        return
                    }
                }
                if status == COMPRESSION_STATUS_END { return }
                if status != COMPRESSION_STATUS_OK || (n == 0 && stream.pointee.src_size == 0) {
                    failure = .checksumMismatch(file: src.lastPathComponent + " (corrupt DEFLATE data)")
                    return
                }
            }
        }
        if let failure {
            try? fm.removeItem(at: dst)
            throw failure
        }
        guard UInt32(truncatingIfNeeded: total) == isize, crc.value == crcWant else {
            try? fm.removeItem(at: dst)
            throw .checksumMismatch(file: src.lastPathComponent + " (gzip trailer)")
        }
        return Output(size: total, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

/// CRC-32 (IEEE 802.3, reflected, as gzip uses).
struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    private var c: UInt32 = 0xFFFF_FFFF
    mutating func update(_ d: Data) {
        var v = c
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for b in p { v = Self.table[Int((v ^ UInt32(b)) & 0xFF)] ^ (v >> 8) }
        }
        c = v
    }
    var value: UInt32 { c ^ 0xFFFF_FFFF }
}
