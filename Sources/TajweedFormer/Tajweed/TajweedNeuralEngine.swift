import CoreML
import CoreVideo
import Foundation
import TajweedFormerCore

/// The V4 TajweedFormer CoreML build on the Neural Engine: one
/// multifunction package, each context's two functions selected with MLModelConfiguration.functionName:
/// `front` (x [1,1,T,80], st, zf_keepf -> cross tensor, inter1_log_probs, new_st) then `back` (cross tensor, st,
/// zf_keepb -> log_probs and every other head, new_st). The geometry comes from the package itself: the window T
/// from x, the CTC frames per call F from log_probs (8 at chunk 16, 12 at chunk 24), the advance 4F fbank frames,
/// the keeps row min(chunk, rows - 1). Features are the engine's exact fbank (zf_fbank), as the v3.2 backend.
/// Every input and output is an IOSurface-backed array made once; state is ping-ponged through output backings.
@available(iOS 18.0, macOS 15.0, *)
final class TajweedNeuralEngine {
    let window: Int, advance: Int, ctcFrames: Int
    private let front: MLModel, back: MLModel
    private var buf: [[String: MLMultiArray]] = [[:], [:]]   // st per function, ping-pong ("st", "b:st")
    private var cross: [String: MLMultiArray] = [:]
    private var heads: [String: MLMultiArray] = [:]          // every head output, by name
    private var frontHeads: [String] = [], backHeads: [String] = []
    private let crossName: String
    private let x: MLMultiArray
    private var keepRows: [[String: MLMultiArray]] = []
    private var parity = 0, step = 0
    private let fbank: OpaquePointer
    private var pending: [Float] = []
    private var feat: [Float] = []
    private var rows: [Float] = []
    private(set) var take = TajweedHeads()
    /// Seconds spent in predictions, per chunk (for latency reporting).
    private(set) var chunkSeconds: [Double] = []
    /// The error behind the last failed prediction (its domain and code go into incident reports).
    private(set) var lastError: NSError?

    convenience init(_ build: TajweedModel.CoreMLBuild, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws(RecognizerError) {
        try self.init(model: build.package, keeps: build.keeps, front: build.frontFunction, back: build.backFunction,
                      computeUnits: computeUnits)
    }

    /// `front` / `back`: the package's function names (`front_<ctx>` / `back_<ctx>` in the multifunction package).
    init(model url: URL, keeps keepsURL: URL, front frontName: String = "front", back backName: String = "back",
         computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws(RecognizerError) {
        func load(_ fn: String) throws(RecognizerError) -> MLModel {
            let c = MLModelConfiguration()
            c.computeUnits = computeUnits
            c.functionName = fn
            do { return try MLModel(contentsOf: url, configuration: c) } catch {
                throw .neuralEngineUnavailable("cannot load \(fn): \(error.localizedDescription)")
            }
        }
        front = try load(frontName)
        back = try load(backName)
        let fi = front.modelDescription.inputDescriptionsByName, fo = front.modelDescription.outputDescriptionsByName
        let bi = back.modelDescription.inputDescriptionsByName, bo = back.modelDescription.outputDescriptionsByName
        func c(_ d: MLFeatureDescription?) throws(RecognizerError) -> MLMultiArrayConstraint {
            guard let k = d?.multiArrayConstraint else { throw .neuralEngineUnavailable("the package does not follow the V4 host contract") }
            return k
        }
        guard fi["st"] != nil, fi["zf_keepf"] != nil, bi["st"] != nil, bi["zf_keepb"] != nil,
              let crossName = bi.keys.first(where: { fo[$0] != nil }) else {
            throw .neuralEngineUnavailable("the package does not follow the V4 host contract (front/back, st, keeps)")
        }
        self.crossName = crossName
        let xs = try c(fi["x"]).shape.map(\.intValue)
        let ls = try c(bo["log_probs"]).shape.map(\.intValue)
        guard xs.count == 4, xs[3] == 80, ls.count == 3, ls[2] == TajweedHeads.vocab else {
            throw .neuralEngineUnavailable("x is \(xs), log_probs \(ls): not a V4 package")
        }
        window = xs[2]
        ctcFrames = ls[1]
        advance = 4 * ctcFrames
        frontHeads = TajweedHeads.layout.map(\.name).filter { fo[$0] != nil }
        backHeads = TajweedHeads.layout.map(\.name).filter { bo[$0] != nil }
        guard Set(frontHeads + backHeads).count == TajweedHeads.layout.count else {
            throw .neuralEngineUnavailable("the package lacks heads: has \(frontHeads + backHeads)")
        }
        for p in 0..<2 {
            buf[p]["st"] = try surfaceArray(try c(fi["st"]).shape, .float16)
            buf[p]["b:st"] = try surfaceArray(try c(bi["st"]).shape, .float16)
        }
        cross[crossName] = try surfaceArray(try c(bi[crossName]).shape, .float16)
        for h in frontHeads { heads[h] = try surfaceArray(try c(fo[h]).shape, .float16) }
        for h in backHeads { heads[h] = try surfaceArray(try c(bo[h]).shape, .float16) }
        x = try surfaceArray(try c(fi["x"]).shape, .float16)
        let table = try loadKeepsTable(keepsURL)
        for row in table {
            var m: [String: MLMultiArray] = [:]
            for (k, d) in [("zf_keepf", fi["zf_keepf"]), ("zf_keepb", bi["zf_keepb"])] {
                let shape = try c(d).shape
                guard let v = row[k], v.count == shape.map(\.intValue).reduce(1, *) else {
                    throw .manifestInvalid("\(keepsURL.lastPathComponent) has no row for \(k) of the right size")
                }
                let a = try surfaceArray(shape, .float16)
                v.withUnsafeBufferPointer { fillRows(a, $0) }
                m[k] = a
            }
            keepRows.append(m)
        }
        guard !keepRows.isEmpty else { throw .manifestInvalid("empty keeps table") }
        guard let f = zf_fbank_create() else { throw .engineFailed(code: -1, message: "zf_fbank_create") }
        fbank = f
    }

    deinit { zf_fbank_destroy(fbank) }

    func reset() {
        parity = 0
        step = 0
        for p in 0..<2 { for (_, a) in buf[p] { zero(a) } }
        zf_fbank_reset(fbank)
        pending.removeAll(keepingCapacity: true)
        take = TajweedHeads()
        chunkSeconds.removeAll()
        lastError = nil
    }

    /// One chunk of silent features through both functions (the Neural Engine powers up for it), then a reset: no
    /// state, heads or chunk time is left behind.
    func warmUp() throws(RecognizerError) {
        let zeros = [Float](repeating: 0, count: window * 80)
        defer { reset() }
        _ = try zeros.withUnsafeBufferPointer { (p) throws(RecognizerError) in try runChunk(p) }
    }

    /// One chunk of `window` fbank frames: both functions, every head read out.
    private func runChunk(_ frames: UnsafeBufferPointer<Float>) throws(RecognizerError) -> TajweedHeads {
        let t0 = CFAbsoluteTimeGetCurrent()
        fillRows(x, frames)
        let cur = buf[parity], nxt = buf[1 - parity]
        let keeps = keepRows[min(step, keepRows.count - 1)]
        let fopt = MLPredictionOptions()
        var fb: [String: Any] = ["new_st": nxt["st"]!, crossName: cross[crossName]!]
        for h in frontHeads { fb[h] = heads[h]! }
        fopt.outputBackings = fb
        let bopt = MLPredictionOptions()
        var bb: [String: Any] = ["new_st": nxt["b:st"]!]
        for h in backHeads { bb[h] = heads[h]! }
        bopt.outputBackings = bb
        do {
            _ = try front.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x": x, "st": cur["st"]!, "zf_keepf": keeps["zf_keepf"]!]),
                                     options: fopt)
            _ = try back.prediction(from: MLDictionaryFeatureProvider(dictionary: [crossName: cross[crossName]!, "st": cur["b:st"]!,
                                                                                   "zf_keepb": keeps["zf_keepb"]!]), options: bopt)
        } catch {
            lastError = error as NSError
            throw .neuralEngineUnavailable("prediction failed: \(error.localizedDescription)")
        }
        var chunk: [String: [Float]] = [:]
        for (name, _, _) in TajweedHeads.layout {
            guard let pb = heads[name]?.pixelBuffer else { throw .neuralEngineUnavailable("\(name) has no surface") }
            readRows(pb, into: &rows)
            chunk[name] = rows
        }
        chunkSeconds.append(CFAbsoluteTimeGetCurrent() - t0)
        parity = 1 - parity
        step += 1
        return TajweedHeads(chunk: chunk)
    }

    /// fbank frames in; every chunk they complete is run.
    private func pushFrames(_ f: UnsafeBufferPointer<Float>, _ n: Int, into out: inout [TajweedHeads]) throws(RecognizerError) {
        pending.append(contentsOf: UnsafeBufferPointer(start: f.baseAddress, count: n * 80))
        let w = window * 80, a = advance * 80
        var consumed = 0
        while pending.count - consumed >= w {
            let h = try pending.withUnsafeBufferPointer { (p) throws(RecognizerError) -> TajweedHeads in
                try runChunk(UnsafeBufferPointer(rebasing: p[consumed..<consumed + w]))
            }
            take.append(h)
            out.append(h)
            consumed += a
        }
        if consumed > 0 { pending.removeFirst(consumed) }
    }

    /// 16 kHz mono samples in; the chunks they complete out (each chunk's heads).
    func push(_ s: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [TajweedHeads] {
        var out: [TajweedHeads] = []
        var at = 0
        while at < s.count {
            let n = min(16_000, s.count - at)
            let cap = Int(zf_fbank_max_frames(Int32(n)))
            if feat.count < cap * 80 { feat = [Float](repeating: 0, count: cap * 80) }
            let frames = feat.withUnsafeMutableBufferPointer { zf_fbank_accept(fbank, s.baseAddress! + at, Int32(n), $0.baseAddress, Int32(cap)) }
            guard frames >= 0 else { throw .engineFailed(code: Int(frames), message: "zf_fbank_accept") }
            try feat.withUnsafeBufferPointer { (p) throws(RecognizerError) in try pushFrames(p, Int(frames), into: &out) }
            at += n
        }
        return out
    }

    /// The end of the take: 1.05 s of zeros (16,800 samples), the fbank's last frames, every chunk they complete.
    func finish() throws(RecognizerError) -> [TajweedHeads] {
        var out: [TajweedHeads] = []
        let zeros = [Float](repeating: 0, count: 16_800)
        out += try zeros.withUnsafeBufferPointer { (p) throws(RecognizerError) in try push(p) }
        let cap = Int(zf_fbank_max_frames(0))
        if feat.count < cap * 80 { feat = [Float](repeating: 0, count: cap * 80) }
        let frames = feat.withUnsafeMutableBufferPointer { zf_fbank_finish(fbank, $0.baseAddress, Int32(cap)) }
        guard frames >= 0 else { throw .engineFailed(code: Int(frames), message: "zf_fbank_finish") }
        try feat.withUnsafeBufferPointer { (p) throws(RecognizerError) in try pushFrames(p, Int(frames), into: &out) }
        pending.removeAll(keepingCapacity: true)
        return out
    }
}
