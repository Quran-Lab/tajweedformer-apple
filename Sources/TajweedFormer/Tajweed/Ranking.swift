import Foundation
import QuranLabCore

/// Any head with a distribution, ranked per frame to any depth (zf_tajweed.h top-K): the token heads (log_probs,
/// inter1, inter4, id, timing: 38 entries, k 1 to 38, 38 being the whole ranked list) and the class heads (gem 2,
/// attr_tafkheem 3, attr_ghunna 5, attr_qalqalah 3, attr_face 4). Highest value first, equal values by the lower id
/// (a stable argsort), as the engine ranks them; the numbers come from the engine for heads of either backend.
struct TajweedRanking: Sendable, Hashable {
    /// One ranked entry of a frame.
    struct Entry: Sendable, Hashable {
        /// Token id (token heads) or class index (class heads).
        let id: Int
        /// Its name: the tokens.txt unit, or the class name.
        let name: String
        /// The head's value: a log-prob for token heads, a probability for class heads.
        let value: Float
        /// Its value minus the next-ranked entry's (also when that one is beyond k); 0 for the last entry of the row.
        let margin: Float
    }

    let head: HeadID
    let k: Int
    /// Frames at the head's rate (40 ms for the CTC heads, 20 ms for the others).
    let frames: Int
    let ids: [Int32]
    let values: [Float]
    let margins: [Float]
    let names: [String]

    /// Frame `t`'s k entries, best first.
    func entries(frame t: Int) -> [Entry] {
        guard t >= 0, t < frames else { return [] }
        return (0..<k).map { j in
            let i = t * k + j, id = Int(ids[i])
            return Entry(id: id, name: id >= 0 && id < names.count ? names[id] : "?", value: values[i], margin: margins[i])
        }
    }

    /// Every frame's entries.
    var all: [[Entry]] { (0..<frames).map { entries(frame: $0) } }

    /// Whether `head` can be ranked (boundary and conf are single logits).
    static func isRanked(_ head: HeadID) -> Bool { head != .boundary && head != .conf }

    static func check(_ head: HeadID, k: Int) throws(RecognizerError) {
        guard isRanked(head) else { throw .invalidArgument("\(head.rawValue) is a single logit: it has no ranking") }
        guard (1...head.width).contains(k) else { throw .invalidArgument("k \(k) is outside 1...\(head.width) for \(head.rawValue)") }
    }

    /// The model-free ranking of `values` ([frames, head.width] row major, from any backend): the 3.x engine's
    /// top-K, which the Core exports (`qlc_topk`, R8).
    static func rank(_ values: [Float], head: HeadID, k: Int, names: [String]) throws(RecognizerError) -> TajweedRanking {
        try check(head, k: k)
        let cols = head.width
        guard !values.isEmpty else { throw .invalidArgument("\(head.rawValue) was not computed for this take (select it with HeadSelection)") }
        let frames = values.count / cols
        var ids = [Int32](repeating: 0, count: frames * k)
        var out = [Float](repeating: 0, count: frames * k), margins = [Float](repeating: 0, count: frames * k)
        let n = values.withUnsafeBufferPointer { v in
            ids.withUnsafeMutableBufferPointer { i in
                out.withUnsafeMutableBufferPointer { o in
                    margins.withUnsafeMutableBufferPointer { m in
                        qlc_topk(v.baseAddress, Int32(frames), Int32(cols), Int32(k), i.baseAddress, o.baseAddress, m.baseAddress)
                    }
                }
            }
        }
        // the code is a Core status (an error report names it, ErrorCause): the Core's own when qlc_topk returned one,
        // else QLC_E_ENGINE (the engine could not run); never a placeholder that reads as another status
        guard n == frames else {
            throw .engineFailed(code: n < 0 ? Int(n) : Int(QLC_E_ENGINE), message: "qlc_topk(\(head.rawValue), k \(k)) failed")
        }
        return TajweedRanking(head: head, k: k, frames: frames, ids: ids, values: out, margins: margins, names: names)
    }
}
