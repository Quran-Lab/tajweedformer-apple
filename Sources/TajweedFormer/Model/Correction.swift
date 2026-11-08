import Foundation
import TajweedFormerCore

/// The correction file (`coreml/engine.zfs`, the engine's ZFS1 sidecar): what the exact CPU engine needs besides the
/// CoreML package's weights. With the package's `weights/weight.bin` it rebuilds the engine's weight files
/// (`layers.zfw`, `frontend.zfw`) byte for byte, each checked by the engine against the SHA-256 the sidecar records
/// (zf/zfs.h `zf_zfs_write_files`). The SDK then checks each rebuilt file against the manifest's decoded SHA-256 too,
/// so a rebuilt file is trusted exactly as a downloaded one.
enum Correction {
    struct Entry: Sendable, Hashable {
        let name: String
        let sha256: String
    }

    /// The files the sidecar rebuilds, with the SHA-256 it records for each; nil when it is not a sidecar.
    static func entries(_ zfs: URL) -> [Entry]? {
        guard let data = try? Data(contentsOf: zfs, options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Entry]? in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let n = Int(zf_zfs_file_count(p, raw.count))
            guard n >= 0 else { return nil }
            var out: [Entry] = []
            var name = [CChar](repeating: 0, count: 1024)
            var sha = [UInt8](repeating: 0, count: 32)
            for i in 0..<n {
                let rc = name.withUnsafeMutableBufferPointer { nb in
                    sha.withUnsafeMutableBufferPointer { sb in
                        zf_zfs_file_name(p, raw.count, Int32(i), nb.baseAddress, nb.count, sb.baseAddress)
                    }
                }
                guard rc == 0 else { return nil }
                let s = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                out.append(Entry(name: s, sha256: sha.map { String(format: "%02x", $0) }.joined()))
            }
            return out
        }
    }

    /// Rebuilds every file the sidecar lists into `folder` (each written as `<name>.part`, checked, renamed). Peak
    /// memory is one file plus the mapped inputs. Returns the names written.
    static func rebuild(weightBin: URL, zfs: URL, into folder: URL) throws(RecognizerError) -> [String] {
        guard let w = try? Data(contentsOf: weightBin, options: .alwaysMapped) else {
            throw .modelMissing("cannot read \(weightBin.lastPathComponent)")
        }
        guard let z = try? Data(contentsOf: zfs, options: .alwaysMapped) else { throw .modelMissing("cannot read \(zfs.lastPathComponent)") }
        var err: UnsafePointer<CChar>?
        let n: Int32 = w.withUnsafeBytes { (wb: UnsafeRawBufferPointer) -> Int32 in
            z.withUnsafeBytes { (zb: UnsafeRawBufferPointer) -> Int32 in
                folder.path.withCString { dir in
                    zf_zfs_write_files(wb.bindMemory(to: UInt8.self).baseAddress, wb.count,
                                       zb.bindMemory(to: UInt8.self).baseAddress, zb.count, dir, &err)
                }
            }
        }
        guard n >= 0 else {
            throw .engineFailed(code: -1, message: "zf_zfs_write_files: \(err.map { String(cString: $0) } ?? "failed")")
        }
        return (entries(zfs) ?? []).map(\.name)
    }
}
