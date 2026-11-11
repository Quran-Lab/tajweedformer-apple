import Foundation
import XCTest
@testable import TajweedFormer

/// A CPU engine that plays a script: one chunk of given greedy ids (`log_probs` and the timing head) for every 320 ms
/// of audio pushed, and what is left of the script with the flush. It gives both heads whatever was selected, as the
/// real engine does for the heads a take keeps.
final class ScriptedCPUEngine: CPUStreamEngine {
    let chunkMs = 320
    static let advance = 5120
    private let chunks: [HeadsBuffer]
    private var samples = 0
    private var produced = 0

    init(_ chunks: [HeadsBuffer]) { self.chunks = chunks }

    /// The chunks of a take: `frames` are the ids of `log_probs`, `timing` those of the timing head (two per frame),
    /// `size` frames a chunk (the last may be shorter).
    static func chunks(frames: [Int], timing: [Int], size: Int) -> [HeadsBuffer] {
        var out: [HeadsBuffer] = []
        var at = 0
        while at < frames.count {
            let end = min(frames.count, at + size)
            var tm = Array(timing[min(timing.count, 2 * at)..<min(timing.count, 2 * end)])
            tm += [Int](repeating: 0, count: 2 * (end - at) - tm.count)
            out.append(HeadsBuffer(chunk: ["log_probs": Vectors30.logProbs(Array(frames[at..<end])), "timing_log_probs": Vectors30.logProbs(tm)]))
            at = end
        }
        return out
    }

    func reset() {
        samples = 0
        produced = 0
    }

    func push(_ s: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [HeadsBuffer] {
        samples += s.count
        var out: [HeadsBuffer] = []
        while produced < chunks.count, samples >= (produced + 1) * Self.advance {
            out.append(chunks[produced])
            produced += 1
        }
        return out
    }

    func finish() throws(RecognizerError) -> [HeadsBuffer] {
        let rest = Array(chunks[min(produced, chunks.count)...])
        produced = chunks.count
        return rest
    }
}

/// Keeps what each finished take adds to the telemetry.
final class TelemetrySink: AnalyticsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [SessionTelemetry] = []

    func record(_ event: AnalyticsEvent) {
        guard case .sessionFinished(let t) = event else { return }
        lock.lock()
        kept.append(t)
        lock.unlock()
    }

    var takes: [SessionTelemetry] {
        lock.lock()
        defer { lock.unlock() }
        return kept
    }
}

/// The speech rule through a Session (SDK 3.0.0, SPEECH.md): the shared vector's cases as takes over a scripted engine,
/// with what the public API shows of them (the events, `chunk.speech`, the take's end and its Heads) and what the
/// telemetry counts.
final class SpeechSessionTests: XCTestCase {
    let sink = TelemetrySink()

    override func setUp() {
        QuranLab.configure(options: .init(modelSource: [], analytics: .on, analyticsSink: sink, storageDirectory: Fixtures.storage(), cloud: nil))
    }

    override func tearDown() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = nil }
        Fixtures.configure()
    }

    /// The bundled test folder's CPU set.
    func folder() async throws -> ModelFolder {
        let server = try Fixtures.v4mini().appendingPathComponent("server")
        let m = try ModelManifest.read(server)
        let dir = Fixtures.storage().appendingPathComponent("model")
        _ = try await ModelInstaller(source: DirectoryFileSource(root: server))
            .install(m, profile: DownloadProfile(context: "c16_l64", coreML: false), into: dir)
        return try ModelFolder.open(directory: dir, verifier: ManifestVerifier(trustedKeys: [try Fixtures.v4miniKey()], requireSignature: true))
    }

    struct Taken {
        var chunks: [TajweedChunk] = []
        var events: [TajweedEvent] = []
        var heads: TajweedHeads
        var telemetry: SessionTelemetry?
    }

    /// One take through a Session over the scripted engine. Every chunk but the script's last arrives while audio is
    /// pushed and the last with the flush, as with the real engine; a take that ended on silence takes no more audio.
    func take(_ folder: ModelFolder, frames: [Int], timing: [Int], size: Int, options: TajweedSessionOptions) async throws -> Taken {
        let script = ScriptedCPUEngine.chunks(frames: frames, timing: timing, size: size)
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { _ in ScriptedCPUEngine(script) } }
        let before = sink.takes.count
        let model = TajweedModel(folder, client: nil)
        let session = try await model.session(options: options)
        let piece = [Float](repeating: 0, count: ScriptedCPUEngine.advance)
        for _ in 0..<max(0, script.count - 1) {
            guard (try? session.push(piece)) != nil else { break }
        }
        var t = Taken(heads: try await session.finish())
        for await c in session.chunks { t.chunks.append(c) }
        for await e in session.events { t.events.append(e) }
        await model.close()
        let recorded = sink.takes
        if recorded.count > before { t.telemetry = recorded[before] }
        return t
    }

    /// The speech events of a take as the vector writes them. The chunk an event came with is the chunk of the frame
    /// that raised it: the frame of `speechStarted`, the last active frame plus the window for `speechEnded`, the
    /// take's last chunk for `ended`.
    static func lines(_ t: Taken, size: Int) -> [String] {
        var out: [String] = []
        for e in t.events {
            switch e {
            case .speechStarted(let at): out.append(Vectors30.line(e, chunk: at / 40 / size))
            case .speechEnded(let at, let silence): out.append(Vectors30.line(e, chunk: (at / 40 - 1 + silence / 40) / size))
            case .ended: out.append(Vectors30.line(e, chunk: t.chunks.count - 1))
            default: break
            }
        }
        return out
    }

    /// Every case of speech.json as a take: the events in order, `chunk.speech`, the chunks delivered, the frames the
    /// take holds, the tokens of `log_probs`, and the speech and silence frames the telemetry counts for it.
    func testTheSpeechVectorsThroughASession() async throws {
        let folder = try await folder()
        let cases = try SpeechVectorTests.cases()
        XCTAssertEqual(cases.count, 32)
        var takes = 0, endedOnSilence = 0
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let frames = try XCTUnwrap(c["frames"] as? [Int], name)
            let timing = try XCTUnwrap(c["timing"] as? [Int], name)
            let size = try XCTUnwrap(c["chunk_frames"] as? Int, name)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            let used = try XCTUnwrap(expect["frames_used"] as? Int, name)
            let t = try await take(folder, frames: frames, timing: timing, size: size,
                                   options: .init(backend: .cpu, endOnSilenceMs: SpeechVectorTests.window(c)))
            takes += 1
            XCTAssertEqual(Self.lines(t, size: size), (try XCTUnwrap(expect["events"] as? [[String: Any]], name)).map { Vectors30.line($0) }, name)
            XCTAssertEqual(t.chunks.map(\.speech), expect["chunk_speech"] as? [Bool], "\(name): chunk.speech")
            XCTAssertEqual(t.chunks.count, (used + size - 1) / size, "\(name): the chunks delivered")
            XCTAssertEqual(t.chunks.map(\.index), Array(0..<t.chunks.count), name)
            XCTAssertEqual(t.chunks.filter { $0.decoded.isFinal }.map(\.index), t.chunks.isEmpty ? [] : [t.chunks.count - 1], "\(name): the last chunk is final")
            XCTAssertEqual(t.heads["log_probs"]?.frames ?? 0, used, "\(name): the frames of the take")
            let tokens = try XCTUnwrap(expect["tokens"] as? [String: Int], name)
            XCTAssertEqual(t.heads.greedy().count, tokens["log_probs"], "\(name): tokens")
            if case .ended(.silence)? = t.events.last { endedOnSilence += 1 }
            // the telemetry of the take: the same frames
            let counted = try XCTUnwrap(t.telemetry, name)
            XCTAssertTrue(counted.counts, name)
            XCTAssertEqual(counted.speechFrames, expect["speech_frames"] as? Int, "\(name): speech frames in the telemetry")
            XCTAssertEqual(counted.silenceFrames, expect["silence_frames"] as? Int, "\(name): silence frames in the telemetry")
            XCTAssertEqual(counted.tokens["log_probs"] ?? 0, tokens["log_probs"], "\(name): tokens in the telemetry")
        }
        print("speech vector through a Session: \(takes) takes, \(endedOnSilence) ended on silence")
        XCTAssertEqual(endedOnSilence, 11)
    }

    /// SPEECH.md point 6, the three results, as takes through a Session.
    func testTheThreeFixtureResultsThroughASession() async throws {
        let folder = try await folder()
        func run(_ prefix: String) async throws -> (taken: Taken, size: Int) {
            let c = try SpeechVectorTests.named(prefix)
            let size = try XCTUnwrap(c["chunk_frames"] as? Int)
            let t = try await take(folder, frames: try XCTUnwrap(c["frames"] as? [Int]), timing: try XCTUnwrap(c["timing"] as? [Int]), size: size,
                                   options: .init(backend: .cpu, endOnSilenceMs: SpeechVectorTests.window(c)))
            return (t, size)
        }
        // the longest held vowel of the fixture, the default window: the take goes on to its end
        let held = try await run("fixture take 20: the longest held vowel of the fixture does not end the take")
        XCTAssertEqual(Self.lines(held.taken, size: held.size), ["speechStarted atMs=280 in chunk 0"])
        XCTAssertEqual(held.taken.heads["log_probs"]?.frames, 128)
        XCTAssertEqual(held.taken.chunks.count, 16)
        // the same take followed by silence: it ends 1500 ms after its last active frame, with chunk 17
        let silence = try await run("fixture take 20 followed by silence")
        XCTAssertEqual(Self.lines(silence.taken, size: silence.size),
                       ["speechStarted atMs=280 in chunk 0", "speechEnded atMs=4000 silenceMs=1520 in chunk 17", "ended reason=silence in chunk 17"])
        XCTAssertEqual(silence.taken.events.last, .ended(.silence))
        XCTAssertEqual(silence.taken.chunks.count, 18)
        XCTAssertEqual(silence.taken.heads["log_probs"]?.frames, 144)
        // cut at the end of the held vowel, then silence: one start, one end, one `ended`
        let cut = try await run("fixture take 20 cut at the end of its held vowel, then silence")
        XCTAssertEqual(Self.lines(cut.taken, size: cut.size),
                       ["speechStarted atMs=280 in chunk 0", "speechEnded atMs=3560 silenceMs=1520 in chunk 15", "ended reason=silence in chunk 15"])
        XCTAssertEqual(cut.taken.events.filter { if case .ended = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(cut.taken.heads["log_probs"]?.frames, 128)
    }

    /// Every take computes and keeps the timing head for speech and silence, whatever the app selected; the head is
    /// handed to the app, and its tokens counted, only when selected.
    func testTheTimingHeadIsComputedForEveryTakeAndHandedOutOnlyWhenSelected() async throws {
        XCTAssertTrue(HeadID.kept.contains(.timingLogProbs))
        let mask = HeadSelection(Set([HeadID.logProbs]).union(HeadID.kept)).engineMask
        XCTAssertNotEqual(mask & HeadID.timingLogProbs.engineBit, 0, "the engine is asked for the timing head when only log_probs is selected")
        XCTAssertEqual(mask & HeadID.gem.engineBit, 0, "and for nothing nobody reads")

        let folder = try await folder()
        // a sound held for a second that log_probs shows on one frame only: frames 5 to 29 are active by the timing head
        let frames = [0, 0, 0, 0, 0, 7] + [Int](repeating: 0, count: 26)
        let timing = [Int](repeating: 0, count: 10) + [Int](repeating: 7, count: 50) + [Int](repeating: 0, count: 4)
        let only = try await take(folder, frames: frames, timing: timing, size: 8, options: .init(heads: ["log_probs"], backend: .cpu))
        XCTAssertEqual(only.heads.names, ["log_probs"])
        XCTAssertNil(only.heads["timing_log_probs"], "not selected: not in the take's Heads")
        XCTAssertTrue(only.chunks.allSatisfy { $0.heads.names == ["log_probs"] }, "nor in a chunk's")
        XCTAssertEqual(only.chunks.map(\.speech), [true, true, true, true], "chunks 1 to 3 hold speech by the timing head alone")
        XCTAssertEqual(Self.lines(only, size: 8), ["speechStarted atMs=200 in chunk 0"])
        let counted = try XCTUnwrap(only.telemetry)
        XCTAssertEqual(counted.speechFrames, 25)
        XCTAssertEqual(counted.silenceFrames, 7)
        XCTAssertEqual(counted.tokens, ["log_probs": 1], "the timing head's tokens are counted only when it is selected")

        // the same take with the default heads: the head is there, and its tokens are counted
        let both = try await take(folder, frames: frames, timing: timing, size: 8, options: .init(backend: .cpu))
        XCTAssertEqual(both.heads["timing_log_probs"]?.frames, 64)
        XCTAssertEqual(both.heads.greedy("timing_log_probs").count, 1)
        XCTAssertEqual(both.chunks.map(\.speech), only.chunks.map(\.speech))
        XCTAssertEqual(both.events, only.events)
        let withTiming = try XCTUnwrap(both.telemetry)
        XCTAssertEqual(withTiming.speechFrames, 25)
        XCTAssertEqual(withTiming.tokens, ["log_probs": 1, "timing_log_probs": 1])
    }

    /// With `endOnSilenceMs`, the chunk that carries the frame is the take's last and no event follows it, also when
    /// speech starts again inside that chunk.
    func testNoEventFollowsTheEndOnSilence() async throws {
        let folder = try await folder()
        // one token at frame 0, silence, and a token again at frame 14: the window of 500 ms (13 frames) has passed with
        // frame 13, in chunk 1 (frames 8 to 15), which also holds frame 14. The take ended at frame 13
        var frames = [Int](repeating: 0, count: 48)
        frames[0] = 5
        frames[14] = 6
        let timing = frames.flatMap { [$0, $0] }
        let t = try await take(folder, frames: frames, timing: timing, size: 8, options: .init(backend: .cpu, endOnSilenceMs: 500))
        XCTAssertEqual(Self.lines(t, size: 8), ["speechStarted atMs=0 in chunk 0", "speechEnded atMs=40 silenceMs=520 in chunk 1", "ended reason=silence in chunk 1"])
        XCTAssertEqual(t.events.count, 3, "no speechStarted for the sound later in the last chunk")
        XCTAssertEqual(t.events.last, .ended(.silence))
        XCTAssertEqual(t.chunks.count, 2, "the chunk is delivered whole and is the last")
        XCTAssertEqual(t.chunks.map(\.speech), [true, true], "its own frames count for chunk.speech")
        XCTAssertEqual(t.heads["log_probs"]?.frames, 16)
        XCTAssertEqual(t.heads.greedy().map(\.id), [5, 6], "the frames of the last chunk are part of the take")
    }
}
