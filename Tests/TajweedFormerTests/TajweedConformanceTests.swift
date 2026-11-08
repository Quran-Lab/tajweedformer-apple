import Foundation
import XCTest
import TajweedFormerCore
@testable import TajweedFormer

/// The V4 exact engine through the SDK's own stream API (TajweedRecognizer, backend .exact), bit for bit against the
/// engine's conformance (tajweedformer-sdk conformance/v4_<context>_audio_expected.jsonl: tokens, chunk count, and an
/// FNV-1a 64 of every one of the 12 outputs of every chunk). The audio of the 35 parity clips goes in 20 ms pieces.
/// TAJWEED_V4_FOLDER: a V4 folder (calibration.json, tokens.txt, expected_tj3.zfx, the engine files; the test writes
/// an unsigned format 3 manifest for it); TAJWEED_V4_EXPECTED: a folder with the expected .jsonl files.
final class TajweedConformanceTests: XCTestCase {
    static func fnv(_ h: UInt64, _ v: [Float]) -> UInt64 {
        var h = h
        v.withUnsafeBytes { b in for x in b { h = (h ^ UInt64(x)) &* 1_099_511_628_211 } }
        return h
    }
    static let fnv0: UInt64 = 1_469_598_103_934_665_603

    static func folder() throws -> TajweedModel {
        guard let path = ProcessInfo.processInfo.environment["TAJWEED_V4_FOLDER"] else { throw XCTSkip("set TAJWEED_V4_FOLDER") }
        let dir = URL(fileURLWithPath: path)
        try Fixtures.manifest(for: dir).write(to: dir)
        return try TajweedModel.open(directory: dir, verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
    }

    func testV4AudioConformanceThroughTheStreamAPI() async throws {
        let model = try Self.folder()
        guard let exp = ProcessInfo.processInfo.environment["TAJWEED_V4_EXPECTED"] else { throw XCTSkip("set TAJWEED_V4_EXPECTED") }
        for ctx in model.contexts {
            let url = URL(fileURLWithPath: exp).appendingPathComponent("v4_\(ctx)_audio_expected.jsonl")
            guard model.isUsable(context: ctx), let text = try? String(contentsOf: url, encoding: .utf8) else {
                print("v4-exact \(ctx): no audio expectations or engine files, skipped")
                continue
            }
            let r = try TajweedRecognizer(model: model, options: TajweedOptions(context: ctx), backend: .exact, heads: .all)
            var passed = 0, total = 0
            for line in text.split(separator: "\n") where !line.isEmpty {
                let e = try XCTUnwrap(JSONValue(data: Data(line.utf8)))
                let clip = try XCTUnwrap(e["clip"]?.string)
                let samples = try Fixtures.samples(clip)
                try await r.startTake()
                var chunks: [TajweedHeads] = []
                var i = 0
                while i < samples.count {
                    let n = min(320, samples.count - i)
                    chunks += try await r.append(Array(samples[i..<i + n])).map(\.heads)
                    i += n
                }
                let take = try await r.finish()
                chunks += await r.lastChunks
                let backend = await r.activeBackend
                XCTAssertEqual(backend, .exact)
                var why: String?
                let want = Int(e["chunks"]?.number ?? -1)
                if chunks.count != want { why = "chunks \(chunks.count) != \(want)" }
                let tokens = (e["tokens"]?.array ?? []).compactMap { $0.number.map(Int.init) }
                if why == nil && take.greedy != tokens { why = "tokens" }
                var logp = Self.fnv0
                for c in chunks { logp = Self.fnv(logp, c.logProbs) }
                if why == nil && String(format: "%016llx", logp) != e["logp_fnv"]?.string { why = "log_probs" }
                if why == nil, let outs = e["out_fnv"]?.object {
                    for (name, list) in outs.sorted(by: { $0.key < $1.key }) {
                        let got = chunks.map { String(format: "%016llx", Self.fnv(Self.fnv0, $0[name])) }
                        if got != (list.array ?? []).compactMap(\.string) { why = "output \(name)"; break }
                    }
                }
                total += 1
                if why == nil { passed += 1 } else { XCTFail("\(ctx) \(clip): \(why!)") }
            }
            print("v4-exact \(ctx) audio through TajweedRecognizer: \(passed)/\(total)")
            XCTAssertEqual(passed, total)
            XCTAssertEqual(total, 35)
        }
    }

    /// Lazy heads (API 3): a default recognizer's CPU stream computes the scorer's heads and conf only; heads it did
    /// not compute come back empty, never stale; `.all` computes everything. The decoded layer's top-2 from the stream
    /// equals zf_tajweed_top2 on the same log_probs.
    func testLazyHeadsAndTheStreamTop2() async throws {
        let model = try Self.folder()
        let ctx = model.calibration.defaultContext
        let clip = try Fixtures.samples("Husary_001001")
        // one recognizer at a time (the engine keeps one live stream per process): each run releases its own
        func run(_ heads: HeadSelection) async throws -> (TajweedHeads, [TajweedChunk], DecodedTake) {
            let r = try TajweedRecognizer(model: model, options: TajweedOptions(context: ctx), backend: .exact, heads: heads)
            try await r.startTake()
            let chunks = try await r.append(clip)
            let take = try await r.finish()
            return (take, chunks, await r.decoded())
        }
        let (take, chunks, d) = try await run(.default)
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.heads[.inter4LogProbs].isEmpty && $0.heads[.idLogProbs].isEmpty && $0.heads[.face].isEmpty })
        XCTAssertFalse(take.logProbs.isEmpty)
        XCTAssertFalse(take.conf.isEmpty)
        XCTAssertTrue(take.inter4LogProbs.isEmpty, "not computed, not handed out")
        let ref = DecodedTake.top2(take.logProbs, frames: take.n40)
        XCTAssertEqual(d.frames, ref, "the stream's top-2 is zf_tajweed_top2's")
        let (all, _, _) = try await run(.all)
        XCTAssertFalse(all.inter4LogProbs.isEmpty)
        XCTAssertEqual(all.logProbs, take.logProbs, "a head is the same bits whatever else is computed")
        print("v4-exact lazy heads: \(chunks.count) chunks, default mask computes \(TajweedHead.allCases.filter { !take[$0].isEmpty }.count) heads")
    }

    /// Top-K on the V4 folder: the CPU stream's ranking (zf_tajweed_stream_topk) equals the model-free zf_tajweed_topk
    /// on the same take, for log_probs to full depth and for a class head; decoded(topK:) carries it.
    func testStreamTopKEqualsTheModelFreeRanking() async throws {
        let model = try Self.folder()
        let ctx = model.calibration.defaultContext
        let r = try TajweedRecognizer(model: model, options: TajweedOptions(context: ctx), backend: .exact, heads: .all)
        try await r.startTake()
        try await r.append(try Fixtures.samples("Husary_112001"))
        let take = try await r.finish()
        for (head, k) in [(TajweedHead.logProbs, 38), (.inter1LogProbs, 5), (.timingLogProbs, 3), (.gem, 2), (.ghunna, 5), (.face, 4)] {
            let stream = try await r.ranking(head, k: k)
            let free = try TajweedRanking.rank(take[head], head: head, k: k, names: head.classNames(vocabulary: model.vocabulary))
            XCTAssertEqual(stream, free, "\(head.rawValue) k \(k)")
        }
        let d = try await r.decoded(topK: 38)
        XCTAssertEqual(d.ranked?.k, 38)
        XCTAssertEqual(d.ranked?.frames, take.n40)
        XCTAssertEqual(d.ranked?.entries(frame: 0).first?.id, d.frames.first?.top1, "rank 1 is top-1")
        print("v4-exact top-K: stream == zf_tajweed_topk on \(take.n40) frames, 6 heads")
    }

    /// The engine's thread team stays full across takes (tajweedformer-sdk de88490: a pinned caller's mask is restored
    /// when its stream goes, and a team is sized from the process's cores, not its creator's mask). On one thread: 5
    /// takes in a row (create, push a few chunks of a parity clip, finish, destroy), then 2 streams alive at once;
    /// every time zf_stream_threads_active is min(threads asked, the process's active CPUs). Once with the platform
    /// default (pinned on iOS, unpinned on macOS) and once with no_pin 0 (pinned) on the Mac too. zf_tajweed.h does
    /// not hand out its ZfStream, so the test makes raw streams on the folder's engine graph (model_engine2.onnx).
    func testStreamThreadsStayFullAcrossTakes() throws {
        guard let path = ProcessInfo.processInfo.environment["TAJWEED_V4_FOLDER"] else { throw XCTSkip("set TAJWEED_V4_FOLDER") }
        let dir = URL(fileURLWithPath: path)
        let ctx = try XCTUnwrap(["c16_l64", "c24_l72", "c24_l256"].first {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0)/model_engine2.onnx.zfg").path)
        })
        let graph = dir.appendingPathComponent("\(ctx)/model_engine2.onnx").path
        let clip = Array(try Fixtures.samples("Husary_001001").prefix(16_000 * 2))
        let asked: Int32 = 4
        let want = min(Int(asked), ProcessInfo.processInfo.activeProcessorCount)
        var out = [ZfToken](repeating: ZfToken(), count: 512)

        func make(_ noPin: Int32?) throws -> OpaquePointer {
            var o = zf_stream_default_options()
            o.threads = asked
            if let noPin { o.no_pin = noPin }
            var err: UnsafePointer<CChar>?
            guard let s = graph.withCString({ zf_stream_create($0, &o, &err) }) else {
                throw XCTSkip("zf_stream_create: \(err.map { String(cString: $0) } ?? "failed")")
            }
            return s
        }
        func push(_ s: OpaquePointer) {
            let n = clip.withUnsafeBufferPointer { c in out.withUnsafeMutableBufferPointer { zf_stream_push_audio(s, c.baseAddress, Int32(c.count), $0.baseAddress, Int32($0.count)) } }
            XCTAssertGreaterThanOrEqual(n, 0)
        }
        func finish(_ s: OpaquePointer) {
            _ = out.withUnsafeMutableBufferPointer { zf_stream_finish_audio(s, $0.baseAddress, Int32($0.count)) }
        }

        #if os(macOS)
        let variants: [(String, Int32?)] = [("default (unpinned)", nil), ("no_pin 0 (pinned)", 0)]
        #else
        let variants: [(String, Int32?)] = [("default (pinned)", nil)]
        #endif
        for (name, noPin) in variants {
            var seen: [Int] = []
            for take in 0..<5 {
                let s = try make(noPin)
                push(s)
                let n = Int(zf_stream_threads_active(s))
                seen.append(n)
                XCTAssertEqual(n, want, "\(name), take \(take + 1): \(n) threads, want \(want)")
                finish(s)
                zf_stream_destroy(s)
            }
            let a = try make(noPin), b = try make(noPin)
            push(a)
            push(b)
            let na = Int(zf_stream_threads_active(a)), nb = Int(zf_stream_threads_active(b))
            XCTAssertEqual(na, want, "\(name), two at once, first")
            XCTAssertEqual(nb, want, "\(name), two at once, second")
            finish(a); finish(b)
            zf_stream_destroy(a); zf_stream_destroy(b)
            let s = try make(noPin)
            push(s)
            let after = Int(zf_stream_threads_active(s))
            XCTAssertEqual(after, want, "\(name), after two at once")
            zf_stream_destroy(s)
            print("v4-exact threads \(name): takes \(seen), two at once \(na)/\(nb), after \(after), want \(want)")
        }
    }
}

