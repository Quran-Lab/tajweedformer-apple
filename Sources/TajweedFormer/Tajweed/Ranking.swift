import Foundation
import TajweedFormerCore

/// Any head with a distribution, ranked per frame to any depth (zf_tajweed.h top-K): the token heads (log_probs,
/// inter1, inter4, id, timing: 38 entries, k 1 to 38, 38 being the whole ranked list) and the class heads (gem 2,
/// attr_tafkheem 3, attr_ghunna 5, attr_qalqalah 3, attr_face 4). Highest value first, equal values by the lower id
/// (a stable argsort), as the engine ranks them; the numbers come from the engine for heads of either backend.
public struct TajweedRanking: Sendable, Hashable {
    /// One ranked entry of a frame.
    public struct Entry: Sendable, Hashable {
        /// Token id (token heads) or class index (class heads).
        public let id: Int
        /// Its name: the tokens.txt unit, or the class name.
        public let name: String
        /// The head's value: a log-prob for token heads, a probability for class heads.
        public let value: Float
        /// Its value minus the next-ranked entry's (also when that one is beyond k); 0 for the last entry of the row.
        public let margin: Float
    }

    public let head: TajweedHead
    public let k: Int
    /// Frames at the head's rate (40 ms for the CTC heads, 20 ms for the others).
    public let frames: Int
    let ids: [Int32]
    let values: [Float]
    let margins: [Float]
    let names: [String]

    /// Frame `t`'s k entries, best first.
    public func entries(frame t: Int) -> [Entry] {
        guard t >= 0, t < frames else { return [] }
        return (0..<k).map { j in
            let i = t * k + j, id = Int(ids[i])
            return Entry(id: id, name: id >= 0 && id < names.count ? names[id] : "?", value: values[i], margin: margins[i])
        }
    }

    /// Every frame's entries.
    public var all: [[Entry]] { (0..<frames).map { entries(frame: $0) } }

    /// Whether `head` can be ranked (boundary and conf are single logits).
    public static func isRanked(_ head: TajweedHead) -> Bool { head != .boundary && head != .conf }

    static func check(_ head: TajweedHead, k: Int) throws(RecognizerError) {
        guard isRanked(head) else { throw .invalidArgument("\(head.rawValue) is a single logit: it has no ranking") }
        guard (1...head.width).contains(k) else { throw .invalidArgument("k \(k) is outside 1...\(head.width) for \(head.rawValue)") }
    }

    /// The model-free ranking of `values` ([frames, head.width] row major, from any backend): `zf_tajweed_topk`.
    static func rank(_ values: [Float], head: TajweedHead, k: Int, names: [String]) throws(RecognizerError) -> TajweedRanking {
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
                        zf_tajweed_topk(v.baseAddress, Int32(frames), Int32(cols), Int32(k), i.baseAddress, o.baseAddress, m.baseAddress)
                    }
                }
            }
        }
        guard n == frames else { throw .engineFailed(code: -1, message: "zf_tajweed_topk(\(head.rawValue), k \(k)) failed") }
        return TajweedRanking(head: head, k: k, frames: frames, ids: ids, values: out, margins: margins, names: names)
    }
}

extension TajweedExactEngine {
    /// The stream's ranking of a head it keeps, over the take so far (`zf_tajweed_stream_topk`); nil when the stream
    /// does not keep that head.
    func ranking(_ head: TajweedHead, k: Int, frames: Int, names: [String]) throws(RecognizerError) -> TajweedRanking? {
        try TajweedRanking.check(head, k: k)
        guard heads & head.engineBit != 0, frames > 0 else { return nil }
        var ids = [Int32](repeating: 0, count: frames * k)
        var out = [Float](repeating: 0, count: frames * k), margins = [Float](repeating: 0, count: frames * k)
        let n = ids.withUnsafeMutableBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in
                margins.withUnsafeMutableBufferPointer { m in
                    zf_tajweed_stream_topk(stream, head.engineBit, Int32(k), i.baseAddress, o.baseAddress, m.baseAddress, Int32(frames))
                }
            }
        }
        guard n == frames else { return nil }
        return TajweedRanking(head: head, k: k, frames: frames, ids: ids, values: out, margins: margins, names: names)
    }
}
