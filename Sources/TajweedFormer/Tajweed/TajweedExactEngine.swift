import Foundation
import TajweedFormerCore

/// The V4 exact engine (zf_tajweed.h streams over zf_stream, tajweedformer-sdk at the pinned commit): bit for bit
/// what ONNX Runtime's ARM int8 reference gives on the same graph, every head of every chunk (the engine's V4
/// conformance, 35/35 at every context). One context per model handle; one live stream per process (the engine's
/// rule). The heads it produces are int8 heads. A stream computes only the heads in `heads` (zf_tajweed.h API 3,
/// `zf_tajweed_stream_set_heads`); a head it does not compute comes back empty, never stale.
final class TajweedExactEngine {
    let model: OpaquePointer      // ZfTajweedModel*, opened with the engine for one context
    let stream: OpaquePointer     // ZfTajweedStream*
    let context: String
    let chunkMs: Int
    private final class Box { var chunks: [TajweedHeads] = [] }
    private let box = Box()
    /// The engine's head bits this stream computes (set again at every reset, the start of a take).
    private(set) var heads: UInt32 = HeadSelection.default.engineMask

    init(directory: URL, context: String, threads: Int = 0) throws(RecognizerError) {
        var o = zf_tajweed_open_default_options()
        o.load_engine = 1
        o.threads = Int32(threads)
        var err: UnsafePointer<CChar>?
        let m: OpaquePointer? = context.withCString { c in
            o.context = c
            return directory.path.withCString { zf_tajweed_model_open($0, &o, &err) }
        }
        guard let m else {
            throw .engineFailed(code: -1, message: "zf_tajweed_model_open(\(context)): \(err.map { String(cString: $0) } ?? "failed")")
        }
        guard let s = zf_tajweed_stream_create(m, &err) else {
            zf_tajweed_model_close(m)
            throw .engineFailed(code: -1, message: "zf_tajweed_stream_create: \(err.map { String(cString: $0) } ?? "failed")")
        }
        model = m
        stream = s
        self.context = context
        chunkMs = Int(zf_tajweed_model_chunk_ms(m))
        zf_tajweed_stream_set_callback(s, { user, chunk in
            guard let user, let chunk else { return }
            let box = Unmanaged<Box>.fromOpaque(user).takeUnretainedValue()
            box.chunks.append(TajweedHeads(copying: chunk.pointee))
        }, Unmanaged.passUnretained(box).toOpaque())
        _ = zf_tajweed_stream_set_heads(s, heads)
    }

    /// The heads to compute from the next take on (applied now when no chunk has run since the last reset).
    func setHeads(_ mask: UInt32) {
        heads = mask
        _ = zf_tajweed_stream_set_heads(stream, mask)
    }

    /// The decoded layer's per-frame top-1 and runner-up of the take so far, from the engine
    /// (`zf_tajweed_stream_top2`).
    func top2() -> [DecodedTake.Frame] {
        var p: UnsafePointer<ZfTajweedTop2>?
        let n = Int(zf_tajweed_stream_top2(stream, &p))
        guard n > 0, let p else { return [] }
        return (0..<n).map { DecodedTake.Frame(p[$0]) }
    }

    deinit {
        zf_tajweed_stream_destroy(stream)
        zf_tajweed_model_close(model)
    }

    func reset() {
        zf_tajweed_stream_reset(stream)
        _ = zf_tajweed_stream_set_heads(stream, heads)
        box.chunks.removeAll()
    }

    private func error(_ what: String) -> RecognizerError {
        .engineFailed(code: -1, message: "\(what): \(zf_tajweed_stream_last_error(stream).map { String(cString: $0) } ?? "failed")")
    }

    /// 16 kHz mono samples in; each completed chunk's heads out.
    func push(_ s: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [TajweedHeads] {
        box.chunks.removeAll(keepingCapacity: true)
        guard let base = s.baseAddress, s.count > 0 else { return [] }
        guard zf_tajweed_stream_push_audio(stream, base, Int32(s.count)) >= 0 else { throw error("zf_tajweed_stream_push_audio") }
        return box.chunks
    }

    /// The end of the take: the 1.05 s flush and every chunk it completes.
    func finish() throws(RecognizerError) -> [TajweedHeads] {
        box.chunks.removeAll(keepingCapacity: true)
        guard zf_tajweed_stream_finish(stream) >= 0 else { throw error("zf_tajweed_stream_finish") }
        return box.chunks
    }

    /// Every head of the take so far.
    var take: TajweedHeads {
        var h = ZfTajweedHeads()
        guard zf_tajweed_stream_heads(stream, &h) >= 0 else { return TajweedHeads() }
        return TajweedHeads(copying: h)
    }
}

extension TajweedHeads {
    /// A copy of the engine's heads (zf_tajweed.h layout).
    init(copying h: ZfTajweedHeads) {
        let n40 = Int(h.n40), n20 = Int(h.n20)
        func copy(_ p: UnsafePointer<Float>?, _ n: Int) -> [Float] { p.map { Array(UnsafeBufferPointer(start: $0, count: n)) } ?? [] }
        var chunk: [String: [Float]] = [:]
        chunk["log_probs"] = copy(h.log_probs, n40 * 38)
        chunk["inter1_log_probs"] = copy(h.inter1_log_probs, n40 * 38)
        chunk["inter4_log_probs"] = copy(h.inter4_log_probs, n40 * 38)
        chunk["id_log_probs"] = copy(h.id_log_probs, n20 * 38)
        chunk["timing_log_probs"] = copy(h.timing_log_probs, n20 * 38)
        chunk["gem"] = copy(h.gem, n20 * 2)
        chunk["attr_tafkheem"] = copy(h.attr_tafkheem, n20 * 3)
        chunk["attr_ghunna"] = copy(h.attr_ghunna, n20 * 5)
        chunk["attr_qalqalah"] = copy(h.attr_qalqalah, n20 * 3)
        chunk["attr_face"] = copy(h.attr_face, n20 * 4)
        chunk["boundary"] = copy(h.boundary, n20)
        chunk["conf"] = copy(h.conf, n20)
        self.init(chunk: chunk)
    }
}
