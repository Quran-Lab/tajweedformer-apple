import Foundation
import XCTest
@testable import TajweedFormer

/// A deterministic stand-in for the exact CPU engine, with the streaming engine's shape: a chunk every 320 ms of audio
/// once a 450 ms window is full, a 1.05 s flush at the end, and a state carried from chunk to chunk (so a replay that
/// starts late does not rebuild it exactly, as with the real encoder's caches). Each chunk has 8 frames of log_probs:
/// a token per frame derived from the window's audio and the carried state, blank where the window is silent.
final class FakeCPUEngine: CPUStreamEngine {
    let chunkMs = 320
    static let advance = 5120, window = 7200
    private var audio: [Float] = []
    private var consumed = 0     // chunks run
    private var state = 0.0
    /// Engines opened (cold opens), across instances.
    static let opened = Locked(0)

    init() { Self.opened.withLock { $0 += 1 } }

    func reset() {
        audio = []
        consumed = 0
        state = 0
    }

    func push(_ s: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [TajweedHeads] {
        audio += s
        var out: [TajweedHeads] = []
        while audio.count >= Self.window + consumed * Self.advance {
            out.append(chunk(audio[(consumed * Self.advance)..<(consumed * Self.advance + Self.window)]))
            consumed += 1
        }
        return out
    }

    func finish() throws(RecognizerError) -> [TajweedHeads] {
        let zeros = [Float](repeating: 0, count: 16_800)
        return try zeros.withUnsafeBufferPointer { (p) throws(RecognizerError) in try push(p) }
    }

    private func chunk(_ w: ArraySlice<Float>) -> TajweedHeads {
        let m = Double(w.reduce(Float(0)) { $0 + abs($1) }) / Double(max(1, w.count))
        state = 0.6 * state + m
        var lp = [Float](repeating: -20, count: 8 * 38)
        for f in 0..<8 {
            let t = m > 0.002 ? 1 + Int((state * 997).rounded(.down) + Double(f / 3)) % 37 : 0
            lp[f * 38 + t] = 0
        }
        return TajweedHeads(chunk: ["log_probs": lp])
    }
}

/// An accelerator that runs its own fake CPU engine and fails on demand at one chunk.
final class FakeAccelerator: AcceleratorBackend {
    enum Failure: Equatable {
        case none
        /// The call that completes the chunk throws.
        case exception
        /// The chunk's log_probs carry a NaN.
        case nan
        /// A log-probability far above 0.
        case outOfRange
        /// The call that completes the chunk does not return for this many seconds.
        case hang(Double)
        /// Every chunk from this one on hears nothing.
        case blank
    }

    private let inner = FakeCPUEngine()
    var failAt = -1
    var failure = Failure.none
    private var produced = 0
    private(set) var chunkSeconds: [Double] = []
    /// Seconds each chunk takes (a slower build is still promoted).
    var chunkCost: Double = 0

    init(failAt: Int = -1, failure: Failure = .none) {
        self.failAt = failAt
        self.failure = failure
    }

    func reset() {
        inner.reset()
        produced = 0
        chunkSeconds = []
    }

    func push(_ s: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [TajweedHeads] { try watch(try inner.push(s)) }
    func finish() throws(RecognizerError) -> [TajweedHeads] { try watch(try inner.finish()) }

    private func watch(_ chunks: [TajweedHeads]) throws(RecognizerError) -> [TajweedHeads] {
        var out: [TajweedHeads] = []
        for var c in chunks {
            let i = produced
            produced += 1
            if chunkCost > 0 { Thread.sleep(forTimeInterval: chunkCost) }
            var spent = max(chunkCost, 0.0005)
            if i == failAt {
                switch failure {
                case .exception: throw .neuralEngineUnavailable("prediction failed: injected")
                case .nan: var lp = c.logProbs; lp[3] = .nan; c.logProbs = lp
                case .outOfRange: var lp = c.logProbs; lp[5] = 40; c.logProbs = lp
                case .hang(let s): Thread.sleep(forTimeInterval: s); spent = s
                case .blank, .none: break
                }
            }
            if failure == .blank && failAt >= 0 && i >= failAt { c.logProbs = (0..<c.logProbs.count).map { (k: Int) -> Float in k % 38 == 0 ? 0 : -20 } }
            chunkSeconds.append(spent)
            out.append(c)
        }
        return out
    }
}

/// Audio with energy everywhere (a slow tone with a varying level), 16 kHz.
func fakeRecitation(seconds: Double, seed: Int = 1) -> [Float] {
    let n = Int(seconds * 16_000)
    return (0..<n).map { i in
        let t = Double(i) / 16_000
        return Float(0.2 * sin(2 * .pi * 180 * t) * (0.6 + 0.4 * sin(2 * .pi * (0.7 + 0.1 * Double(seed)) * t)))
    }
}

/// The whole take's greedy tokens through `runner`, fed in pieces of `piece` samples, with the take's own truncation.
struct RunResult {
    var heads = TajweedHeads()
    var frames: [Int] = []
    var handedOut = 0
}

func runTake(_ runner: TakeRunner, _ audio: [Float], accelerator: AcceleratorExecutor?, piece: Int = 5120) throws -> RunResult {
    try runner.start(accelerator: accelerator)
    var r = RunResult()
    func apply(_ o: TakeRunner.Output) {
        if let t = o.truncateTo, t < r.frames.count {
            r.heads.truncate(n40: r.frames.prefix(t).reduce(0, +))
            r.frames.removeLast(r.frames.count - t)
        }
        for c in o.chunks {
            r.heads.append(c)
            r.frames.append(c.n40)
        }
        r.handedOut = max(r.handedOut, r.frames.count)
    }
    var at = 0
    while at < audio.count {
        apply(try runner.push(Array(audio[at..<min(audio.count, at + piece)])))
        at += piece
    }
    apply(try runner.finish())
    return r
}
