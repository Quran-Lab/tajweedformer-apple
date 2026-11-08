import CoreML
import CoreVideo
import Foundation

// IOSurface-backed arrays for the CoreML package: every input and output is made once, and each call writes its next
// state straight into the other half of a ping-pong pair through outputBackings, so nothing is allocated or copied
// per chunk. An output backing is never read through its MLMultiArray accessors (CoreML then refuses it for the next
// prediction); it is read through its pixel buffer.

/// An IOSurface-backed, zeroed array: the pixel buffer is width = last dimension, height = the
/// product of the others.
@available(iOS 18.0, macOS 15.0, *)
func surfaceArray(_ shape: [NSNumber], _ dt: MLMultiArrayDataType) throws(RecognizerError) -> MLMultiArray {
    let dims = shape.map { $0.intValue }
    guard let width = dims.last else { throw .neuralEngineUnavailable("empty shape") }
    let height = max(1, dims.dropLast().reduce(1, *))
    let fmt = dt == .float16 ? kCVPixelFormatType_OneComponent16Half : kCVPixelFormatType_OneComponent32Float
    var pb: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    guard CVPixelBufferCreate(nil, width, height, fmt, attrs, &pb) == kCVReturnSuccess, let pb else {
        throw .neuralEngineUnavailable("cannot allocate a \(width)x\(height) surface")
    }
    CVPixelBufferLockBaseAddress(pb, [])
    memset(CVPixelBufferGetBaseAddress(pb), 0, CVPixelBufferGetDataSize(pb))
    CVPixelBufferUnlockBaseAddress(pb, [])
    return MLMultiArray(pixelBuffer: pb, shape: shape)
}

/// Writes floats into a (possibly row-padded) surface array, row by row along the last dimension.
@available(iOS 18.0, macOS 15.0, *)
func fillRows(_ a: MLMultiArray, _ v: UnsafeBufferPointer<Float>) {
    guard let pb = a.pixelBuffer else { return }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let w = CVPixelBufferGetWidth(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    let rows = min(v.count / w, CVPixelBufferGetHeight(pb))
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
    for r in 0..<rows {
        let row = base.advanced(by: r * bpr)
        if CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent16Half {
            let p = row.assumingMemoryBound(to: Float16.self)
            for c in 0..<w { p[c] = Float16(v[r * w + c]) }
        } else {
            let p = row.assumingMemoryBound(to: Float.self)
            for c in 0..<w { p[c] = v[r * w + c] }
        }
    }
}

/// Reads a surface array's pixel buffer into floats, dropping the row padding.
@available(iOS 18.0, macOS 15.0, *)
func readRows(_ pb: CVPixelBuffer, into out: inout [Float]) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
    if out.count != w * h { out = [Float](repeating: 0, count: w * h) }
    let half = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent16Half
    out.withUnsafeMutableBufferPointer { o in
        for r in 0..<h {
            let row = base.advanced(by: r * bpr)
            if half {
                let p = row.assumingMemoryBound(to: Float16.self)
                for c in 0..<w { o[r * w + c] = Float(p[c]) }
            } else {
                let p = row.assumingMemoryBound(to: Float.self)
                for c in 0..<w { o[r * w + c] = p[c] }
            }
        }
    }
}

@available(iOS 18.0, macOS 15.0, *)
func zero(_ a: MLMultiArray) {
    guard let pb = a.pixelBuffer else { return }
    CVPixelBufferLockBaseAddress(pb, [])
    memset(CVPixelBufferGetBaseAddress(pb), 0, CVPixelBufferGetDataSize(pb))
    CVPixelBufferUnlockBaseAddress(pb, [])
}

/// A keep table (coreml/<context>/keeps.bin, tajweedformer-coreml export/v4_keeps.py), little endian: int32 steps,
/// int32 inputs; per input int32 name length, name, int32 float count; then per step, per input,
/// the floats.
func loadKeepsTable(_ url: URL) throws(RecognizerError) -> [[String: [Float]]] {
    guard let d = try? Data(contentsOf: url) else { throw .modelMissing("cannot read \(url.lastPathComponent)") }
    var table: [[String: [Float]]] = []
    let ok: Bool = d.withUnsafeBytes { r in
        var o = 0
        func i32() -> Int? {
            guard o + 4 <= r.count else { return nil }
            let v = Int32(littleEndian: r.loadUnaligned(fromByteOffset: o, as: Int32.self))
            o += 4
            return Int(v)
        }
        guard let steps = i32(), let inputs = i32(), steps > 0, inputs > 0 else { return false }
        var meta: [(String, Int)] = []
        for _ in 0..<inputs {
            guard let l = i32(), l > 0, o + l <= r.count else { return false }
            let name = String(decoding: r[o..<o + l], as: UTF8.self)
            o += l
            guard let n = i32(), n > 0 else { return false }
            meta.append((name, n))
        }
        for _ in 0..<steps {
            var row: [String: [Float]] = [:]
            for (name, n) in meta {
                guard o + 4 * n <= r.count else { return false }
                row[name] = (0..<n).map { Float(bitPattern: UInt32(littleEndian: r.loadUnaligned(fromByteOffset: o + 4 * $0, as: UInt32.self))) }
                o += 4 * n
            }
            table.append(row)
        }
        return o == r.count
    }
    guard ok else { throw .manifestInvalid("\(url.lastPathComponent) is malformed") }
    return table
}
