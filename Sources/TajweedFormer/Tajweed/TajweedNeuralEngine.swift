import CoreML
import CoreVideo
import Foundation
import TajweedFormerCore

/// The two kinds of V4 CoreML package (SPEC 5.4). They are told apart by the inputs of the package's own functions
/// when it is loaded: no version, no metadata of the package and no field of the manifest decides the kind.
enum CoreMLPackageKind: Sendable, Hashable {
    /// The keep-table kind (every build before 3.0.2 knew only this one): front takes `zf_keepf`, back takes
    /// `zf_keepb`, and the host feeds them the rows of the context's keep table (`coreml/<context>/keeps.bin`).
    case keepTable
    /// The one-file kind: the keep table is inside the package, and front and back both take `keep_sel` in place of
    /// those two: float16, shape [1, rows], one-hot, 1.0 at `row(chunk:rows:)`. `rows` is read from the input's
    /// shape and differs by context.
    case keepSel(rows: Int)

    static let selector = "keep_sel"

    /// The kind of a package whose front and back functions take these inputs (name to shape). Refused, as a
    /// package the host cannot run: one kind in front and the other in back, both kinds in one function, neither,
    /// a `keep_sel` that is not [1, R] with R of at least 1, and an R that differs between front and back.
    static func tell(front: [String: [Int]], back: [String: [Int]]) throws(RecognizerError) -> CoreMLPackageKind {
        let table = (front["zf_keepf"] != nil, back["zf_keepb"] != nil)
        switch (table.0, table.1, front[selector], back[selector]) {
        case (true, true, nil, nil):
            return .keepTable
        case (false, false, let f?, let b?):
            guard f.count == 2, f[0] == 1, f[1] >= 1 else {
                throw .neuralEngineUnavailable("the package does not follow the V4 host contract: keep_sel is \(f) in front, not [1, R]")
            }
            guard b == f else {
                throw .neuralEngineUnavailable("the package does not follow the V4 host contract: keep_sel is \(f) in front and \(b) in back")
            }
            return .keepSel(rows: f[1])
        default:
            func has(_ d: [String: [Int]]) -> String { ["zf_keepf", "zf_keepb", selector].filter { d[$0] != nil }.joined(separator: " and ") }
            throw .neuralEngineUnavailable("the package does not follow the V4 host contract: front and back must both take their keep rows "
                                           + "(zf_keepf, zf_keepb) or both take keep_sel; front takes \(has(front).isEmpty ? "neither" : has(front)), "
                                           + "back takes \(has(back).isEmpty ? "neither" : has(back))")
        }
    }

    /// The keep row of chunk `chunk` in a table of `rows` rows: min(chunk, rows - 1). Chunk 0 is a stream's first
    /// call.
    static func row(chunk: Int, rows: Int) -> Int { min(max(chunk, 0), rows - 1) }

    /// The selector of `row`: `rows` values, 1.0 at `row` and 0.0 elsewhere.
    static func oneHot(row: Int, rows: Int) -> [Float] {
        var v = [Float](repeating: 0, count: rows)
        if v.indices.contains(row) { v[row] = 1 }
        return v
    }
}

/// The V4 TajweedFormer CoreML build on the Neural Engine: one
/// multifunction package, each context's two functions selected with MLModelConfiguration.functionName:
/// `front` (x [1,1,T,80], st, keep rows -> cross tensor, inter1_log_probs, new_st) then `back` (cross tensor, st,
/// keep rows -> log_probs and every other head, new_st). The keep rows come in one of two ways, which the
/// package's own inputs tell (`CoreMLPackageKind`): `zf_keepf` / `zf_keepb`, fed from the context's keep table, or
/// `keep_sel`, a one-hot selector of the row of a table the package carries inside. The geometry comes from the
/// package itself: the window T from x, the CTC frames per call F from log_probs (8 at chunk 16, 12 at chunk 24),
/// the advance 4F fbank frames, the keep row min(chunk, rows - 1), the rows of a one-file package from the shape
/// of `keep_sel`. Features are the engine's exact fbank (zf_fbank), as the v3.2 backend.
/// Every input and output is an IOSurface-backed array made once; state is ping-ponged through output backings.
@available(iOS 18.0, macOS 15.0, *)
final class TajweedNeuralEngine {
    let window: Int, advance: Int, ctcFrames: Int
    /// Which kind of package this is, from its inputs.
    let kind: CoreMLPackageKind
    private let front: MLModel, back: MLModel
    private var buf: [[String: MLMultiArray]] = [[:], [:]]   // st per function, ping-pong ("st", "b:st")
    private var cross: [String: MLMultiArray] = [:]
    private var heads: [String: MLMultiArray] = [:]          // every head output, by name
    private var frontHeads: [String] = [], backHeads: [String] = []
    private let crossName: String
    private let x: MLMultiArray
    private var keepRows: [[String: MLMultiArray]] = []
    /// The one-file kind: one selector per row of the table inside the package, made once at load.
    private var keepSel: [MLMultiArray] = []
    /// The keep row the last chunk was fed (nil before a stream's first chunk).
    private(set) var lastKeepRow: Int?
    private var parity = 0, step = 0
    private let fbank: OpaquePointer
    private var pending: [Float] = []
    private var feat: [Float] = []
    private var rows: [Float] = []
    private(set) var take = HeadsBuffer()
    /// Seconds spent in predictions, per chunk (for latency reporting).
    private(set) var chunkSeconds: [Double] = []
    /// The error behind the last failed prediction (its domain and code go into incident reports).
    private(set) var lastError: NSError?

    convenience init(_ build: ModelFolder.CoreMLBuild, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws(RecognizerError) {
        try self.init(model: build.package, keeps: build.keeps, front: build.frontFunction, back: build.backFunction,
                      computeUnits: computeUnits)
    }

    /// `front` / `back`: the package's function names (`front_<ctx>` / `back_<ctx>` in the multifunction package).
    /// `keeps`: the context's keep table, for a package of the keep-table kind; a one-file package needs none and
    /// does not read it. A keep-table package without one is refused here, like any package the host cannot run.
    init(model url: URL, keeps keepsURL: URL?, front frontName: String = "front", back backName: String = "back",
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
        guard fi["st"] != nil, bi["st"] != nil, let crossName = bi.keys.first(where: { fo[$0] != nil }) else {
            throw .neuralEngineUnavailable("the package does not follow the V4 host contract (front/back, st)")
        }
        self.crossName = crossName
        func shapes(_ d: [String: MLFeatureDescription]) -> [String: [Int]] {
            d.compactMapValues { $0.multiArrayConstraint?.shape.map(\.intValue) }
        }
        kind = try CoreMLPackageKind.tell(front: shapes(fi), back: shapes(bi))
        let xs = try c(fi["x"]).shape.map(\.intValue)
        let ls = try c(bo["log_probs"]).shape.map(\.intValue)
        guard xs.count == 4, xs[3] == 80, ls.count == 3, ls[2] == HeadsBuffer.vocab else {
            throw .neuralEngineUnavailable("x is \(xs), log_probs \(ls): not a V4 package")
        }
        window = xs[2]
        ctcFrames = ls[1]
        advance = 4 * ctcFrames
        frontHeads = HeadsBuffer.layout.map(\.name).filter { fo[$0] != nil }
        backHeads = HeadsBuffer.layout.map(\.name).filter { bo[$0] != nil }
        guard Set(frontHeads + backHeads).count == HeadsBuffer.layout.count else {
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
        switch kind {
        case .keepTable:
            guard let keepsURL else {
                throw .neuralEngineUnavailable("the package takes its keep rows from a keep table (zf_keepf, zf_keepb) and the model lists "
                                               + "none for this context")
            }
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
        case .keepSel(let rows):
            // one selector per row, made once: the same array goes to front and back of a chunk
            let shape = try c(fi[CoreMLPackageKind.selector]).shape
            for r in 0..<rows {
                let a = try surfaceArray(shape, .float16)
                CoreMLPackageKind.oneHot(row: r, rows: rows).withUnsafeBufferPointer { fillRows(a, $0) }
                keepSel.append(a)
            }
        }
        guard let f = zf_fbank_create() else { throw .engineFailed(code: -1, message: "zf_fbank_create") }
        fbank = f
    }

    deinit { zf_fbank_destroy(fbank) }

    /// The rows of the keep table: of the context's keeps.bin, or of the table inside a one-file package.
    var keepRowCount: Int {
        if case .keepSel(let rows) = kind { return rows }
        return keepRows.count
    }

    /// The selector a one-file package is fed for chunk `chunk`, read back from the array the engine feeds; nil
    /// for a keep-table package.
    func keepSelValues(chunk: Int) -> [Float]? {
        guard case .keepSel(let rows) = kind, let pb = keepSel[CoreMLPackageKind.row(chunk: chunk, rows: rows)].pixelBuffer else { return nil }
        var out: [Float] = []
        readRows(pb, into: &out)
        return out
    }

    func reset() {
        parity = 0
        step = 0
        lastKeepRow = nil
        for p in 0..<2 { for (_, a) in buf[p] { zero(a) } }
        zf_fbank_reset(fbank)
        pending.removeAll(keepingCapacity: true)
        take = HeadsBuffer()
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
    private func runChunk(_ frames: UnsafeBufferPointer<Float>) throws(RecognizerError) -> HeadsBuffer {
        let t0 = CFAbsoluteTimeGetCurrent()
        fillRows(x, frames)
        let cur = buf[parity], nxt = buf[1 - parity]
        // the keep row of this chunk: min(chunk, rows - 1), chunk 0 a stream's first call
        let row = CoreMLPackageKind.row(chunk: step, rows: keepRowCount)
        var fin: [String: Any] = ["x": x, "st": cur["st"]!]
        var bin: [String: Any] = [crossName: cross[crossName]!, "st": cur["b:st"]!]
        switch kind {
        case .keepTable:
            fin["zf_keepf"] = keepRows[row]["zf_keepf"]!
            bin["zf_keepb"] = keepRows[row]["zf_keepb"]!
        case .keepSel:
            fin[CoreMLPackageKind.selector] = keepSel[row]
            bin[CoreMLPackageKind.selector] = keepSel[row]
        }
        lastKeepRow = row
        let fopt = MLPredictionOptions()
        var fb: [String: Any] = ["new_st": nxt["st"]!, crossName: cross[crossName]!]
        for h in frontHeads { fb[h] = heads[h]! }
        fopt.outputBackings = fb
        let bopt = MLPredictionOptions()
        var bb: [String: Any] = ["new_st": nxt["b:st"]!]
        for h in backHeads { bb[h] = heads[h]! }
        bopt.outputBackings = bb
        do {
            _ = try front.prediction(from: MLDictionaryFeatureProvider(dictionary: fin), options: fopt)
            _ = try back.prediction(from: MLDictionaryFeatureProvider(dictionary: bin), options: bopt)
        } catch {
            lastError = error as NSError
            throw .neuralEngineUnavailable("prediction failed: \(error.localizedDescription)")
        }
        var chunk: [String: [Float]] = [:]
        for (name, _, _) in HeadsBuffer.layout {
            guard let pb = heads[name]?.pixelBuffer else { throw .neuralEngineUnavailable("\(name) has no surface") }
            readRows(pb, into: &rows)
            chunk[name] = rows
        }
        chunkSeconds.append(CFAbsoluteTimeGetCurrent() - t0)
        parity = 1 - parity
        step += 1
        return HeadsBuffer(chunk: chunk)
    }

    /// fbank frames in; every chunk they complete is run.
    private func pushFrames(_ f: UnsafeBufferPointer<Float>, _ n: Int, into out: inout [HeadsBuffer]) throws(RecognizerError) {
        pending.append(contentsOf: UnsafeBufferPointer(start: f.baseAddress, count: n * 80))
        let w = window * 80, a = advance * 80
        var consumed = 0
        while pending.count - consumed >= w {
            let h = try pending.withUnsafeBufferPointer { (p) throws(RecognizerError) -> HeadsBuffer in
                try runChunk(UnsafeBufferPointer(rebasing: p[consumed..<consumed + w]))
            }
            take.append(h)
            out.append(h)
            consumed += a
        }
        if consumed > 0 { pending.removeFirst(consumed) }
    }

    /// 16 kHz mono samples in; the chunks they complete out (each chunk's heads).
    func push(_ s: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [HeadsBuffer] {
        var out: [HeadsBuffer] = []
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
    func finish() throws(RecognizerError) -> [HeadsBuffer] {
        var out: [HeadsBuffer] = []
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
