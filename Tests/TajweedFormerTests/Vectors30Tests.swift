import Foundation
import XCTest
@testable import TajweedFormer

/// The cross-SDK vectors of SDK 3.0.0 (Fixtures/vectors30, byte copies of the shared files): every SDK reads the same
/// files and must give the same answers.
enum Vectors30 {
    static func url(_ name: String) throws -> URL {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "vectors30", withExtension: nil, subdirectory: "Fixtures"))
        return dir.appendingPathComponent(name)
    }

    static func json(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url(name))) as? [String: Any])
    }

    /// The vocabulary of the bundled test folder (tj3: 38 tokens, blank 0, the word bar 1).
    static func vocabulary() throws -> Vocabulary {
        try Vocabulary(tokensFile: Fixtures.v4mini().appendingPathComponent("decoded/tokens.txt"))
    }

    /// log_probs whose top token per frame is `ids` (0 for it, -20 for the others).
    static func logProbs(_ ids: [Int]) -> [Float] {
        var lp = [Float](repeating: -20, count: ids.count * 38)
        for (f, id) in ids.enumerated() { lp[f * 38 + id] = 0 }
        return lp
    }

    /// An event as one line, `<name> <fields> in chunk <n>`, for comparing with a vector's entry.
    static func line(_ e: TajweedEvent, chunk: Int) -> String {
        switch e {
        case .speechStarted(let at): return "speechStarted atMs=\(at) in chunk \(chunk)"
        case .speechEnded(let at, let silence): return "speechEnded atMs=\(at) silenceMs=\(silence) in chunk \(chunk)"
        case .ended(let reason): return "ended reason=\(Self.name(reason)) in chunk \(chunk)"
        default: return "other in chunk \(chunk)"
        }
    }

    /// The same line for a vector's event object.
    static func line(_ o: [String: Any]) -> String {
        let chunk = o["chunk"] as? Int ?? -1
        switch o["event"] as? String {
        case "speechStarted": return "speechStarted atMs=\(o["atMs"] as? Int ?? -1) in chunk \(chunk)"
        case "speechEnded": return "speechEnded atMs=\(o["atMs"] as? Int ?? -1) silenceMs=\(o["silenceMs"] as? Int ?? -1) in chunk \(chunk)"
        case "ended": return "ended reason=\(o["reason"] as? String ?? "?") in chunk \(chunk)"
        default: return "other in chunk \(chunk)"
        }
    }

    static func name(_ r: TajweedEvent.EndReason) -> String {
        switch r {
        case .silence: return "silence"
        case .background: return "background"
        case .hidden: return "hidden"
        case .interrupted: return "interrupted"
        case .sourceEnd: return "sourceEnd"
        case .limit: return "limit"
        case .error: return "error"
        }
    }
}

final class SpeechVectorTests: XCTestCase {
    /// What one case of speech.json gives when its frames go through the rule chunk by chunk, as a Session feeds them.
    struct Replay {
        var used = 0
        var chunkSpeech: [Bool] = []
        var events: [String] = []
        /// Whether each frame used is active.
        var active: [Bool] = []
    }

    static func cases() throws -> [[String: Any]] {
        try XCTUnwrap(try Vectors30.json("speech.json")["cases"] as? [[String: Any]])
    }

    /// The case whose name starts with `prefix` (the names are the vector's).
    static func named(_ prefix: String) throws -> [String: Any] {
        try XCTUnwrap(try cases().first { ($0["name"] as? String ?? "").hasPrefix(prefix) }, prefix)
    }

    /// The window of a case: `endOnSilenceMs` when it is on.
    static func window(_ c: [String: Any]) -> Int? { (c["endOnSilenceMs"] as? Int).flatMap { $0 > 0 ? $0 : nil } }

    static func replay(_ c: [String: Any]) throws -> Replay {
        let name = c["name"] as? String ?? "?"
        let frames = try XCTUnwrap(c["frames"] as? [Int], name)
        let timing = try XCTUnwrap(c["timing"] as? [Int], name)
        let size = try XCTUnwrap(c["chunk_frames"] as? Int, name)
        let window = Self.window(c)
        var tracker = SpeechTracker(windowMs: window ?? SpeechTracker.defaultWindowMs)
        var r = Replay()
        var chunk = 0
        take: while r.used < frames.count {
            let end = min(frames.count, r.used + size)
            let active = SpeechTracker.active(logProbs: Array(frames[r.used..<end]),
                                              timing: Array(timing[min(timing.count, 2 * r.used)..<min(timing.count, 2 * end)]))
            let heard = tracker.feed(active, firstFrame: r.used)
            r.chunkSpeech.append(heard.speech)
            r.active += active
            r.used = end
            for e in heard.events {
                r.events.append(Vectors30.line(e, chunk: chunk))
                if case .speechEnded = e, window != nil {
                    // the chunk that carries the frame is the take's last, and no event follows
                    r.events.append(Vectors30.line(.ended(.silence), chunk: chunk))
                    break take
                }
            }
            chunk += 1
        }
        return r
    }

    /// The longest run of blank `log_probs` frames between the first and the last token of a take: (frames, first frame).
    static func longestBlankRun(_ frames: [Int]) -> (count: Int, from: Int) {
        guard let first = frames.firstIndex(where: { $0 != 0 }), let last = frames.lastIndex(where: { $0 != 0 }) else { return (0, 0) }
        var best = (count: 0, from: 0), run = 0, start = 0
        for f in first...last {
            if frames[f] == 0 {
                if run == 0 { start = f }
                run += 1
                if run > best.count { best = (run, start) }
            } else {
                run = 0
            }
        }
        return best
    }

    /// speech.json: the active frames and the totals, the tokens per head, `chunk.speech` and the events, case by case.
    func testSpeechVectors() throws {
        let v = try Vectors30.json("speech.json")
        XCTAssertEqual(v["frame_ms"] as? Int, SpeechTracker.frameMs)
        XCTAssertEqual(v["timing_frame_ms"] as? Int, SpeechTracker.frameMs / SpeechTracker.timingFramesPerFrame)
        XCTAssertEqual(v["default_window_ms"] as? Int, SpeechTracker.defaultWindowMs)
        XCTAssertEqual(v["default_window_frames"] as? Int, SpeechTracker().windowFrames)
        XCTAssertEqual(SpeechTracker().windowFrames, 38)
        let cases = try Self.cases()
        XCTAssertEqual(cases.count, 32)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let frames = try XCTUnwrap(c["frames"] as? [Int], name)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            let r = try Self.replay(c)
            XCTAssertEqual(r.used, expect["frames_used"] as? Int, name)
            XCTAssertEqual(r.chunkSpeech, expect["chunk_speech"] as? [Bool], name)
            XCTAssertEqual(r.events, (try XCTUnwrap(expect["events"] as? [[String: Any]], name)).map { Vectors30.line($0) }, name)
            XCTAssertEqual(r.active.map { $0 ? 1 : 0 }, expect["speech"] as? [Int], "\(name): the active frames, one by one")
            let speech = SpeechTracker.speechFrames(r.active)
            XCTAssertEqual(speech, expect["speech_frames"] as? Int, name)
            XCTAssertEqual(r.used - speech, expect["silence_frames"] as? Int, name)
            XCTAssertEqual(Double(speech * 40) / 1000, try XCTUnwrap(expect["speech_s"] as? Double, name), accuracy: 1e-9, name)
            XCTAssertEqual(Double((r.used - speech) * 40) / 1000, try XCTUnwrap(expect["silence_s"] as? Double, name), accuracy: 1e-9, name)
            var tokens = ["log_probs": SpeechTracker.tokens(Array(frames.prefix(r.used)))]
            for (head, ids) in (c["other_heads"] as? [String: [Int]]) ?? [:] {
                // a 20 ms head counts on its own frames
                let per = HeadID(rawValue: head)?.frameMs == 20 ? 2 : 1
                tokens[head] = SpeechTracker.tokens(Array(ids.prefix(r.used * per)))
            }
            XCTAssertEqual(tokens, expect["tokens"] as? [String: Int], name)
        }
    }

    /// A frame is active by either head, and by nothing around it.
    func testAFrameIsActiveByLogProbsOrByTheTimingHead() {
        XCTAssertEqual(SpeechTracker.active(logProbs: [0, 5, 0, 0], timing: [0, 0, 0, 0, 0, 0, 0, 0]), [false, true, false, false], "no padding")
        XCTAssertEqual(SpeechTracker.active(logProbs: [0, 0, 0, 0], timing: [0, 0, 7, 0, 0, 7, 0, 0]), [false, true, true, false],
                       "either 20 ms frame of a frame makes it active")
        XCTAssertEqual(SpeechTracker.active(logProbs: [0, 1, 0], timing: []), [false, true, false], "the word bar is a token; no timing frames count as blank")
        XCTAssertEqual(SpeechTracker.active(logProbs: [0, 0, 0], timing: [0, 0, 0, 3]), [false, true, false], "a timing head shorter than the take")
        XCTAssertEqual(SpeechTracker.active(logProbs: [], timing: [3, 3]), [])
        XCTAssertEqual(SpeechTracker.speechFrames([true, false, true]), 2)
    }

    /// SPEECH.md point 6, first result: the longest held vowel of the fixture does not end the take at the default
    /// window. `log_probs` is blank for 39 frames (1.56 s) inside the take; the timing head holds the vowel.
    func testTheLongestHeldVowelOfTheFixtureDoesNotEndTheTake() throws {
        let c = try Self.named("fixture take 20: the longest held vowel of the fixture does not end the take")
        let frames = try XCTUnwrap(c["frames"] as? [Int])
        XCTAssertNil(Self.window(c), "the default window")
        let held = Self.longestBlankRun(frames)
        let r = try Self.replay(c)
        print("speech, held vowel: \(frames.count) frames, log_probs blank for \(held.count) frames = \(held.count * 40) ms from frame \(held.from); "
            + "events \(r.events); frames used \(r.used)")
        XCTAssertEqual(frames.count, 128)
        XCTAssertEqual(held.count, 39, "longer than the 38 frames of the default window")
        XCTAssertEqual(held.count * 40, 1560)
        XCTAssertEqual(held.from, 57)
        XCTAssertEqual(r.events, ["speechStarted atMs=280 in chunk 0"], "one speechStarted, no speechEnded")
        XCTAssertEqual(r.used, 128, "the whole take")
        // every frame of that stretch is active by the timing head
        XCTAssertTrue(r.active[held.from..<(held.from + held.count)].allSatisfy { $0 })
        // and log_probs alone would have ended the speech inside it
        var alone = SpeechTracker()
        let ended = alone.feed(frames.map { $0 != 0 }, firstFrame: 0).events.contains { if case .speechEnded = $0 { return true }; return false }
        XCTAssertTrue(ended, "the rule this replaces ended speech inside the vowel")
    }

    /// SPEECH.md point 6, second result: real silence ends the take 1500 ms after the last active frame, within one
    /// chunk.
    func testRealSilenceEndsTheTake1500msAfterTheLastActiveFrame() throws {
        let c = try Self.named("fixture take 20 followed by silence")
        XCTAssertEqual(Self.window(c), 1500)
        XCTAssertEqual(c["chunk_frames"] as? Int, 8)
        let r = try Self.replay(c)
        print("speech, real silence: events \(r.events); frames used \(r.used) of \((c["frames"] as? [Int])?.count ?? -1)")
        XCTAssertEqual(r.events, ["speechStarted atMs=280 in chunk 0", "speechEnded atMs=4000 silenceMs=1520 in chunk 17", "ended reason=silence in chunk 17"])
        XCTAssertEqual(r.used, 144, "chunk 17 is the last: 18 chunks of 8 frames")
        // the last active frame is frame 99 (4000 / 40 - 1); the event comes with frame 99 + 38 = 137, in chunk 17
        let last = try XCTUnwrap(r.active.lastIndex(of: true))
        XCTAssertEqual(last, 99)
        XCTAssertEqual((last + 38) / 8, 17, "the window after the last active frame, and at most one chunk more")
    }

    /// SPEECH.md point 6, third result: a clip that ends on a held vowel followed by silence ends once.
    func testAClipCutAtAHeldVowelThenSilenceEndsOnce() throws {
        let c = try Self.named("fixture take 20 cut at the end of its held vowel, then silence")
        XCTAssertEqual(Self.window(c), 1500)
        let r = try Self.replay(c)
        print("speech, cut at a held vowel: events \(r.events); frames used \(r.used) of \((c["frames"] as? [Int])?.count ?? -1)")
        XCTAssertEqual(r.events, ["speechStarted atMs=280 in chunk 0", "speechEnded atMs=3560 silenceMs=1520 in chunk 15", "ended reason=silence in chunk 15"],
                       "one speechStarted, one speechEnded, one ended")
        XCTAssertEqual(r.used, 128)
    }

    func testTheOptionsValuesOfEndOnSilence() async throws {
        let v = try XCTUnwrap(try Vectors30.json("speech.json")["endOnSilenceMs"] as? [String: Any])
        XCTAssertEqual((v["valid"] as? [Int]), [500, 600, 1000, 1010, 1500, 60000])
        XCTAssertEqual(SpeechTracker.windowRangeMs, 500...60_000)
        // the integers of `invalid_argument` (the other entries are not an Int in Swift's API)
        let invalid = try XCTUnwrap(v["invalid_argument"] as? [Any]).compactMap { e -> Int? in
            guard let n = e as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), Double(n.intValue) == n.doubleValue else { return nil }
            return n.intValue
        }
        XCTAssertEqual(invalid, [-1, 1, 100, 499, 60001])
        for bad in invalid {
            XCTAssertThrowsError(try TajweedModel.check(endOnSilenceMs: bad), "\(bad)") { XCTAssertEqual(($0 as? TajweedError)?.code, "invalid_argument") }
        }
        for ok in [nil, 0, 500, 600, 1000, 1010, 1500, 60000] as [Int?] { XCTAssertNoThrow(try TajweedModel.check(endOnSilenceMs: ok)) }
        // the window rounds up to whole frames
        XCTAssertEqual(SpeechTracker(windowMs: 500).windowFrames, 13)
        XCTAssertEqual(SpeechTracker(windowMs: 1010).windowFrames, 26)
        XCTAssertEqual(SpeechTracker(windowMs: 60_000).windowFrames, 1500)
    }
}

final class SettledVectorTests: XCTestCase {
    /// settled.json: the decoded tokens with their times and `settled` after every chunk, with failover replacements.
    func testSettledVectors() throws {
        let v = try Vectors30.json("settled.json")
        let vocabulary = try Vectors30.vocabulary()
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 11)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            var chunks: [[Int]] = []
            var floor = 0
            for (n, step) in try XCTUnwrap(c["steps"] as? [[String: Any]], name).enumerated() {
                var isFinal = false
                var replaced = false
                if let ids = step["chunk"] as? [Int] {
                    chunks.append(ids)
                    isFinal = (step["final"] as? Bool) ?? false
                } else {
                    let change = try XCTUnwrap(step["backendChanged"] as? [String: Any], name)
                    let from = try XCTUnwrap(change["fromChunk"] as? Int, name)
                    chunks = Array(chunks.prefix(from)) + (try XCTUnwrap(change["chunks"] as? [[Int]], name))
                    replaced = true
                }
                let frames = chunks.flatMap { $0 }
                let heads = HeadsBuffer(chunk: ["log_probs": Vectors30.logProbs(frames)])
                let d = TajweedDecoded(DecodedTake(heads: heads, vocabulary: vocabulary), isFinal: isFinal, topK: 0)
                let expect = try XCTUnwrap(step["expect"] as? [String: Any], name)
                let label = "\(name), step \(n)"
                XCTAssertEqual(d.frames.count, expect["frames"] as? Int, label)
                XCTAssertEqual(d.frames.map(\.top1), frames, label)
                let want = try XCTUnwrap(expect["tokens"] as? [[String: Int]], label)
                XCTAssertEqual(d.tokens.map(\.id), want.map { $0["id"]! }, label)
                XCTAssertEqual(d.tokens.map(\.firstMs), want.map { $0["firstMs"]! }, label)
                XCTAssertEqual(d.tokens.map(\.lastMs), want.map { $0["lastMs"]! }, label)
                XCTAssertEqual(d.tokens.map { $0.firstMs / 40 }, want.map { $0["firstFrame"]! }, label)
                XCTAssertEqual(d.tokens.map { $0.lastMs / 40 }, want.map { $0["lastFrame"]! }, label)
                XCTAssertEqual(d.settled, expect["settled"] as? Int, label)
                XCTAssertEqual(d.isFinal, expect["isFinal"] as? Bool, label)
                // settled never decreases, except once after a replacement
                if !replaced { XCTAssertGreaterThanOrEqual(d.settled, floor, label) }
                floor = d.settled
                XCTAssertEqual(d.text, d.tokens.map(\.name).joined(separator: " "), label)
            }
        }
    }
}

final class NamesVectorTests: XCTestCase {
    /// names.json: the head names with their kind, rate and width, the default selection, the events and their
    /// values, the Backend's values, the option values and the error codes.
    func testNames() throws {
        let v = try Vectors30.json("names.json")
        let heads = try XCTUnwrap(v["heads"] as? [[String: Any]])
        XCTAssertEqual(heads.compactMap { $0["name"] as? String }, TajweedSessionOptions.allHeads)
        XCTAssertEqual(HeadID.allCases.map(\.rawValue), TajweedSessionOptions.allHeads)
        let vocabulary = try Vectors30.vocabulary()
        for h in heads {
            let name = try XCTUnwrap(h["name"] as? String)
            let id = try XCTUnwrap(HeadID(rawValue: name))
            // one frame of the head, as the public type shows it
            var buffer = HeadsBuffer(chunk: ["log_probs": [Float](repeating: -20, count: 38)])
            buffer.set(name, [Float](repeating: -20, count: (id.frameMs == 40 ? 1 : 2) * id.width))
            let head = try XCTUnwrap(TajweedHeads(buffer, vocabulary: vocabulary, selection: [id])[name], name)
            XCTAssertEqual(head.kind.rawValue, h["kind"] as? String, name)
            XCTAssertEqual(head.frameMs, h["frameMs"] as? Int, name)
            XCTAssertEqual(head.classes, h["classes"] as? Int, name)
            XCTAssertEqual(head.frames, id.frameMs == 40 ? 1 : 2, name)
        }
        XCTAssertEqual(v["default_heads"] as? [String], TajweedSessionOptions.defaultHeads)
        XCTAssertEqual(TajweedSessionOptions().heads, TajweedSessionOptions.defaultHeads)
        let tokens = try XCTUnwrap(v["tokens"] as? [String: Int])
        let t = TajweedTokens(vocabulary: vocabulary)
        XCTAssertEqual(t.blank, tokens["blank"])
        XCTAssertEqual(t.wordBar, tokens["word_bar"])
        XCTAssertEqual(t.count, tokens["count"])

        let reasons: [TajweedEvent.EndReason] = [.silence, .background, .hidden, .interrupted, .sourceEnd, .limit, .error(TajweedError(.engineFailed))]
        XCTAssertEqual(v["ended_reasons"] as? [String], reasons.map { Vectors30.name($0) })
        XCTAssertEqual(v["interrupted_causes"] as? [String], [TajweedEvent.Cause.interruption, .routeChange].map(\.rawValue))
        let backend = try XCTUnwrap(v["backend"] as? [String: Any])
        XCTAssertEqual(backend["kind"] as? [String], [TajweedBackend.Kind.cpu, .accelerator].map(\.rawValue))
        XCTAssertEqual(backend["stage"] as? [String], [TajweedBackend.Stage.cpu, .downloading, .compiling, .testing, .promoted, .demoted].map(\.rawValue))
        XCTAssertEqual(backend["reason"] as? [String], PromotionReason.allCases.map(\.rawValue))
        let pattern = try XCTUnwrap(backend["name_pattern"] as? String)
        for name in ["cpu", "coreml", "coreml-compact"] { XCTAssertNotNil(name.range(of: pattern, options: .regularExpression), name) }
        let options = try XCTUnwrap(v["session_options"] as? [String: Any])
        XCTAssertEqual(options["backend"] as? [String], [TajweedSessionOptions.Backend.auto, .cpu].map(\.rawValue))
        // on Apple the option also takes `coreml-compact`: the compact build, by name
        XCTAssertEqual(options["backend_apple"] as? [String], [TajweedSessionOptions.Backend.auto, .cpu, .coremlCompact].map(\.rawValue))
        XCTAssertEqual(options["backend_apple"] as? [String], ["auto", "cpu", "coreml-compact"])
        XCTAssertEqual(options["pace"] as? [String], [TajweedSessionOptions.Pace.realTime, .fast].map(\.rawValue))
        XCTAssertEqual(options["sampleRate_default"] as? Double, TajweedSessionOptions().sampleRate)
        XCTAssertEqual(options["topK_default"] as? Int, TajweedSessionOptions().topK)
        XCTAssertNil(TajweedSessionOptions().endOnSilenceMs)
        let client = try XCTUnwrap(v["client_options"] as? [String: [String]])
        XCTAssertEqual(client["analytics"], [TajweedClientOptions.Analytics.on, .off].map(\.rawValue))
        XCTAssertEqual(client["audience"], [TajweedClientOptions.Audience.general, .children].map(\.rawValue))
        XCTAssertEqual(v["error_docs_base"] as? String, ErrorCatalogue.shared.docsBase)
        XCTAssertEqual(v["error_codes"] as? [String], ErrorCode.allCases.map(\.rawValue))
        XCTAssertEqual((v["error_codes"] as? [String])?.count, 26)
        let diagnosis = try XCTUnwrap(v["diagnosis"] as? [String: Any])
        XCTAssertEqual(diagnosis["connection"] as? [String], ConnectionKind.allCases.map(\.rawValue))
    }

    /// ayah_counts.json: the table `reportRecited` validates against.
    func testAyahCounts() throws {
        let v = try Vectors30.json("ayah_counts.json")
        XCTAssertEqual(v["counts"] as? [Int], QuranIndex.ayahs)
        XCTAssertEqual(QuranIndex.ayahs.count, 114)
        XCTAssertEqual(QuranIndex.ayahs.reduce(0, +), v["total"] as? Int)
    }
}
