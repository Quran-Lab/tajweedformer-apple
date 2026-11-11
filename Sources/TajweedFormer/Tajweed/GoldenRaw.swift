import Foundation

/// The promotion golden test on raw outputs (SDK 3.0.0): the accelerator's heads against the CPU engine's on every
/// self-test clip, with the measures and the pass rule the four SDKs share (the vectors of `golden_raw.json`).
///
/// - Greedy tokens of a head: per frame the id with the largest value (the lowest id on ties), runs collapsed, blank
///   removed. The word bar is a token.
/// - Compared heads: the CTC heads `log_probs`, `inter1_log_probs`, `timing_log_probs` and the attribute heads `gem`,
///   `attr_tafkheem`, `attr_ghunna`, `attr_qalqalah`, `attr_face`, each when the accelerator run returns it.
/// - `token_edits` of a CTC head: the Levenshtein distance between the two runs' greedy tokens, summed over the clean
///   clips. `d(f)`: the largest `|clip(a) - clip(c)|` of a frame, values clipped to [-30, 0]. `lp_mean`: the mean of
///   `d` over every frame of every clip. `lp_p99`: the `d` values sorted, the one at index `(99 n + 99) / 100 - 1`.
/// - `p_mean`: the mean `|a - c|` over every value of the compared attribute heads, pooled.
/// - `cpu_mismatch`: the CPU's greedy tokens of `log_probs` differ from a clip's expected tokens. It wins.
/// - A compared head whose shape differs between the runs fails (`<head>.shape`) and has no measures.
/// - Pass: no `cpu_mismatch`, no shape failure, and per CTC head: within its tolerance entry when the build has one,
///   else no token edit (the distances are recorded only); `p_mean` within the `attr` entry when there is one.
/// Values are float32; every difference, sum and mean is computed in Double.
enum GoldenRaw {
    static let ctcHeads = ["log_probs", "inter1_log_probs", "timing_log_probs"]
    static let attrHeads = ["gem", "attr_tafkheem", "attr_ghunna", "attr_qalqalah", "attr_face"]

    /// One head of one run: `rows` frames of `cols` values, frames first.
    struct Matrix: Sendable, Equatable {
        let rows: Int
        let cols: Int
        let values: [Float]

        init(rows: Int, cols: Int, values: [Float]) {
            self.rows = rows
            self.cols = cols
            self.values = values
        }

        /// A head's values with its width.
        init(_ values: [Float], cols: Int) {
            self.init(rows: cols > 0 ? values.count / cols : 0, cols: cols, values: values)
        }

        func sameShape(_ o: Matrix) -> Bool { rows == o.rows && cols == o.cols }

        func top(_ r: Int) -> Int {
            var best = 0
            for k in 1..<max(1, cols) where values[r * cols + k] > values[r * cols + best] { best = k }
            return best
        }

        /// Greedy CTC: repeats merged, blank (0) removed.
        var greedy: [Int] {
            var out: [Int] = []
            var previous = -1
            for r in 0..<rows {
                let a = top(r)
                if a != previous && a != 0 { out.append(a) }
                previous = a
            }
            return out
        }
    }

    struct Clip: Sendable {
        var id: String
        /// A clean clip (not one with a planted mistake): its tokens count in `token_edits`.
        var clean: Bool
        /// The `tokens` of the self-test set's expected file; nil for the SDK's own clips, which have none.
        var expectedTokens: [Int]?
        var cpu: [String: Matrix]
        var accelerator: [String: Matrix]
    }

    struct Measure: Sendable, Equatable {
        var tokenEdits = 0
        var lpMean = 0.0
        var lpP99 = 0.0
        var frames = 0
    }

    struct Verdict: Sendable {
        /// Per compared CTC head; nil for a head that failed on shape.
        var ctc: [String: Measure?] = [:]
        /// Whether attribute heads were compared, and their pooled measure (nil when one failed on shape).
        var attrCompared = false
        var pMean: Double?
        var attrValues = 0
        /// The measures out of tolerance, shape failures first.
        var failed: [String] = []
        var cpuMismatch = false
        /// The clip whose CPU tokens differ from the expected ones, when one does.
        var cpuMismatchClip: String?
        /// The CPU run's greedy tokens of `log_probs` over the clean clips.
        var tokensExpected = 0

        var reason: PromotionReason? { cpuMismatch ? .cpuMismatch : failed.isEmpty ? nil : .goldenMismatch }
        var pass: Bool { reason == nil }

        /// The report of an incident: what was measured, the tolerance it was judged against, and what failed.
        func divergence(tolerance: GoldenRawTolerance?) -> Divergence {
            var d = Divergence()
            d.tokensExpected = tokensExpected
            var heads: [String: Divergence.Head?] = [:]
            for (name, m) in ctc {
                heads[name] = .some(m.map { Divergence.Head(tokenEdits: $0.tokenEdits, lpMean: $0.lpMean, lpP99: $0.lpP99, frames: $0.frames) })
            }
            if attrCompared { heads["attr"] = .some(pMean.map { Divergence.Head(pMean: $0, values: attrValues) }) }
            d.heads = heads
            if let t = tolerance {
                var tol: [String: Divergence.Head] = [:]
                for (name, h) in t.heads { tol[name] = Divergence.Head(tokenEdits: h.tokenEdits, lpMean: h.lpMean, lpP99: h.lpP99) }
                if let p = t.pMean { tol["attr"] = Divergence.Head(pMean: p) }
                if !tol.isEmpty { d.tolerance = tol }
            }
            // always there, empty for a `cpu_mismatch` with nothing out of tolerance
            d.failed = failed
            return d
        }
    }

    static func clip(_ x: Float) -> Double { Double(min(0, max(-30, x))) }

    static func p99(_ values: [Double]) -> Double {
        let s = values.sorted()
        return s[(99 * s.count + 99) / 100 - 1]
    }

    /// The heads of a run as the test compares them: every compared head the buffer holds.
    static func heads(_ b: HeadsBuffer) -> [String: Matrix] {
        var out: [String: Matrix] = [:]
        for name in ctcHeads + attrHeads {
            guard let id = HeadID(rawValue: name) else { continue }
            let v = b[id]
            if !v.isEmpty { out[name] = Matrix(v, cols: id.width) }
        }
        return out
    }

    static func evaluate(_ clips: [Clip], tolerance: GoldenRawTolerance?) -> Verdict {
        var v = Verdict()
        for c in clips {
            let cpu = c.cpu["log_probs"]?.greedy ?? []
            if c.clean { v.tokensExpected += cpu.count }
            if let e = c.expectedTokens, cpu != e, !v.cpuMismatch {
                v.cpuMismatch = true
                v.cpuMismatchClip = c.id
            }
        }
        var returned = Set<String>()
        for c in clips { returned.formUnion(c.accelerator.keys) }
        func shapesDiffer(_ h: String) -> Bool {
            clips.contains { c in
                guard let a = c.accelerator[h], let k = c.cpu[h] else { return true }
                return !a.sameShape(k)
            }
        }
        var shape: [String] = []
        for h in ctcHeads where returned.contains(h) {
            if shapesDiffer(h) {
                shape.append(h + ".shape")
                v.ctc[h] = .some(nil)
                continue
            }
            var m = Measure()
            var distances: [Double] = []
            for c in clips {
                let a = c.accelerator[h]!, k = c.cpu[h]!
                if c.clean { m.tokenEdits += Divergence.edits(a.greedy, k.greedy) }
                for r in 0..<a.rows {
                    var d = 0.0
                    for j in 0..<a.cols { d = max(d, abs(clip(a.values[r * a.cols + j]) - clip(k.values[r * a.cols + j]))) }
                    distances.append(d)
                }
            }
            guard !distances.isEmpty else {
                v.ctc[h] = .some(m)
                continue
            }
            var total = 0.0
            for d in distances { total += d }
            m.lpMean = total / Double(distances.count)
            m.lpP99 = p99(distances)
            m.frames = distances.count
            v.ctc[h] = .some(m)
        }
        let attr = attrHeads.filter { returned.contains($0) }
        if !attr.isEmpty {
            v.attrCompared = true
            let bad = attr.filter { shapesDiffer($0) }
            if !bad.isEmpty {
                shape += bad.map { $0 + ".shape" }
            } else {
                var total = 0.0
                var n = 0
                for c in clips {
                    for h in attr {
                        let a = c.accelerator[h]!.values, k = c.cpu[h]!.values
                        for i in a.indices { total += abs(Double(a[i]) - Double(k[i])) }
                        n += a.count
                    }
                }
                if n > 0 { v.pMean = total / Double(n) }
                v.attrValues = n
            }
        }
        var failed = shape
        for h in ctcHeads {
            guard let entry = v.ctc[h], let m = entry else { continue }
            if let t = tolerance?.heads[h] {
                if m.tokenEdits > t.tokenEdits { failed.append("\(h).token_edits") }
                if m.lpMean > t.lpMean { failed.append("\(h).lp_mean") }
                if m.lpP99 > t.lpP99 { failed.append("\(h).lp_p99") }
            } else if m.tokenEdits != 0 {
                failed.append("\(h).token_edits")
            }
        }
        if let p = v.pMean, let t = tolerance?.pMean, p > t { failed.append("attr.p_mean") }
        v.failed = failed
        return v
    }
}
