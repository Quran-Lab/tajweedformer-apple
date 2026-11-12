import CoreML
import Foundation
import XCTest
@testable import TajweedFormer

/// Two CoreML packages side by side through the SDK's own host code (`TajweedNeuralEngine`): the same clips go
/// through both, piece by piece, and every head of every chunk is compared value by value.
///
/// Its use: the two kinds of package made from the same weights, the keep-table kind (`zf_keepf` / `zf_keepb`, fed
/// from keeps.bin) and the one-file kind (`keep_sel`, the table inside the package), on one Mac. The expectation,
/// and the assertion, is that nothing differs: the largest absolute difference is 0 on every head, with the Neural
/// Engine allowed and again with the CPU-only compute unit. That run needs both packages of one model, and is
/// skipped without them: `QURANLAB_COMPARE_DIR` names a folder with `keep_table.mlpackage`, `keep_sel.mlpackage` and
/// `keeps/keeps_<context>.bin` (the contexts are the ones with a keep table there). The clips: the SDK's bundled
/// self-test clips, and every `<name>.pcm` (16 kHz mono float32) of the folder `QURANLAB_COMPARE_CLIPS` names, or of
/// the checkout's TestAudio when it is there.
///
/// The comparison itself runs in every test run on the stand-in of a one-file package (TajweedOneFilePackageTests): against
/// itself it finds nothing, against a real keep-table package it finds the differences.
enum PackageComparison {
    /// What was seen of one head.
    struct Seen: Equatable {
        var values = 0
        var differ = 0
        var notFinite = 0
        var largest: Float = 0
        var at = ""
    }

    struct Result {
        /// By head name.
        var seen: [String: Seen] = [:]
        var chunks = 0
        /// What is not as it must be, in words: a head with a value that differs, a chunk count that differs.
        var failed: [String] = []
    }

    typealias Clip = (name: String, samples: [Float])

    /// Every head of the chunks `x` and `y` (the same chunks of two engines), value by value.
    static func compare(_ x: [HeadsBuffer], _ y: [HeadsBuffer], clip: String, index: inout Int, into r: inout Result) {
        if x.count != y.count { r.failed.append("\(clip): \(x.count) chunks against \(y.count)") }
        for (hx, hy) in zip(x, y) {
            for (name, _, _) in HeadsBuffer.layout {
                let vx = hx[name], vy = hy[name]
                var s = r.seen[name] ?? Seen()
                if vx.count != vy.count {
                    r.failed.append("\(clip), chunk \(index), \(name): \(vx.count) values against \(vy.count)")
                } else {
                    s.values += vx.count
                    for i in vx.indices where vx[i] != vy[i] {
                        s.differ += 1
                        let here = "\(clip), chunk \(index), value \(i): \(vx[i]) against \(vy[i])"
                        guard vx[i].isFinite, vy[i].isFinite else {
                            s.notFinite += 1
                            if s.at.isEmpty { s.at = here }
                            continue
                        }
                        let d = abs(vx[i] - vy[i])
                        if d > s.largest {
                            s.largest = d
                            s.at = here
                        }
                    }
                }
                r.seen[name] = s
            }
            index += 1
        }
    }

    /// `clips` through `a` and `b` in 0.1 s pieces, each engine reset before a clip and finished after it.
    @available(iOS 18.0, macOS 15.0, *)
    static func run(_ a: TajweedNeuralEngine, _ b: TajweedNeuralEngine, clips: [Clip]) throws -> Result {
        var r = Result()
        for clip in clips {
            a.reset()
            b.reset()
            var index = 0
            var p = 0
            while p < clip.samples.count {
                let n = min(1600, clip.samples.count - p)
                let x = try clip.samples[p..<p + n].withUnsafeBufferPointer { (q) throws(RecognizerError) in try a.push(q) }
                let y = try clip.samples[p..<p + n].withUnsafeBufferPointer { (q) throws(RecognizerError) in try b.push(q) }
                compare(x, y, clip: clip.name, index: &index, into: &r)
                p += n
            }
            let x = try a.finish()
            let y = try b.finish()
            compare(x, y, clip: clip.name, index: &index, into: &r)
            r.chunks += index
        }
        for (name, _, _) in HeadsBuffer.layout {
            let s = r.seen[name] ?? Seen()
            if s.values == 0 { r.failed.append("\(name): nothing was compared") }
            if s.differ != 0 { r.failed.append("\(name): \(s.differ) of \(s.values) values differ, largest difference \(s.largest), at \(s.at)") }
        }
        return r
    }

    /// The table of a result: one line per head, each starting with `label`.
    static func table(_ r: Result, label: String) -> [String] {
        var out = ["\(label): head | values | differ | not finite | largest difference | where"]
        for (name, _, _) in HeadsBuffer.layout {
            let s = r.seen[name] ?? Seen()
            out.append("\(label): \(name) | \(s.values) | \(s.differ) | \(s.notFinite) | \(s.largest) | \(s.at.isEmpty ? "nowhere" : s.at)")
        }
        return out
    }

    static func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }

    /// The bundled self-test clips, then the `.pcm` clips of `QURANLAB_COMPARE_CLIPS` or of the checkout's TestAudio.
    static func clips() throws -> [Clip] {
        var out: [Clip] = try SelfTestClips.load().clips.map { (name: $0.name, samples: $0.samples) }
        var folder: URL?
        if let named = ProcessInfo.processInfo.environment["QURANLAB_COMPARE_CLIPS"], !named.isEmpty {
            folder = URL(fileURLWithPath: named)
        } else if let audio = try? Fixtures.audioDirectory() {
            folder = audio
        }
        if let folder {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".pcm") }.sorted()
            for n in names {
                let data = try Data(contentsOf: folder.appendingPathComponent(n))
                let samples: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                if !samples.isEmpty { out.append((name: String(n.dropLast(4)), samples: samples)) }
            }
        }
        return out
    }
}

final class TajweedPackageComparisonTests: XCTestCase {
    /// The comparison on the stand-in against itself: every head of every chunk is compared, and nothing differs.
    func testTheComparisonFindsNothingBetweenAPackageAndItself() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { throw XCTSkip("needs macOS 15 / iOS 18") }
        let stub = try await KeepSelStub.compiled()
        let a = try TajweedNeuralEngine(model: stub, keeps: nil, front: "front_c16_l64", back: "back_c16_l64", computeUnits: .cpuOnly)
        let b = try TajweedNeuralEngine(model: stub, keeps: nil, front: "front_c16_l64", back: "back_c16_l64", computeUnits: .cpuOnly)
        let clips: [PackageComparison.Clip] = [(name: "one", samples: fakeRecitation(seconds: 3)), (name: "two", samples: fakeRecitation(seconds: 2, seed: 2))]
        let r = try PackageComparison.run(a, b, clips: clips)
        for line in PackageComparison.table(r, label: "COMPARE stand-in against itself") { print(line) }
        XCTAssertEqual(r.failed, [])
        XCTAssertGreaterThan(r.chunks, 10)
        XCTAssertEqual(Set(r.seen.keys), Set(HeadsBuffer.layout.map(\.name)), "every head was compared")
        for (name, s) in r.seen {
            XCTAssertGreaterThan(s.values, 0, name)
            XCTAssertEqual(s.differ, 0, name)
            XCTAssertEqual(s.largest, 0, name)
        }
    }

    /// And it sees a difference where there is one: a real keep-table package against the stand-in, whose outputs
    /// are all 0 (needs the packages of TAJWEED_COREML).
    func testTheComparisonSeesTheDifferenceBetweenARealPackageAndTheStandIn() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { throw XCTSkip("needs macOS 15 / iOS 18") }
        guard let root = ProcessInfo.processInfo.environment["TAJWEED_COREML"] else {
            throw XCTSkip("set TAJWEED_COREML to the V4 CoreML test folder")
        }
        let dir = URL(fileURLWithPath: root).appendingPathComponent("c16_l64")
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("keeps.bin").path) else {
            throw XCTSkip("TAJWEED_COREML has no c16_l64 package")
        }
        let real = try await MLModel.compileModel(at: dir.appendingPathComponent("package.mlpackage"))
        let stub = try await KeepSelStub.compiled()
        let a = try TajweedNeuralEngine(model: real, keeps: dir.appendingPathComponent("keeps.bin"), computeUnits: .cpuOnly)
        let b = try TajweedNeuralEngine(model: stub, keeps: nil, front: "front_c16_l64", back: "back_c16_l64", computeUnits: .cpuOnly)
        guard a.window == b.window, a.advance == b.advance else {
            throw XCTSkip("the test package and the stand-in differ in geometry: window \(a.window) and \(b.window)")
        }
        let r = try PackageComparison.run(a, b, clips: [(name: "one", samples: fakeRecitation(seconds: 3))])
        XCTAssertFalse(r.failed.isEmpty, "a real package and a package of zeros must differ")
        let logProbs = try XCTUnwrap(r.seen["log_probs"])
        XCTAssertGreaterThan(logProbs.differ, 0)
        XCTAssertGreaterThan(logProbs.largest, 0)
        XCTAssertFalse(logProbs.at.isEmpty, "where the largest difference is")
        print("COMPARE a real package against the stand-in: log_probs \(logProbs.differ) of \(logProbs.values) differ, largest \(logProbs.largest) at \(logProbs.at)")
    }

    /// The two kinds of package of the same weights on this Mac (see the top of the file); skipped without the
    /// folder that holds them.
    func testTheTwoKindsOfPackageGiveTheSameHeads() async throws {
        guard let root = ProcessInfo.processInfo.environment["QURANLAB_COMPARE_DIR"], !root.isEmpty else {
            throw XCTSkip("needs both packages of one model: QURANLAB_COMPARE_DIR names their folder")
        }
        guard #available(macOS 15.0, iOS 18.0, *) else { throw XCTSkip("needs macOS 15 / iOS 18") }
        let dir = URL(fileURLWithPath: root)
        let keepsDir = dir.appendingPathComponent("keeps")
        var contexts = try FileManager.default.contentsOfDirectory(atPath: keepsDir.path).compactMap { (n: String) -> String? in
            n.hasPrefix("keeps_") && n.hasSuffix(".bin") ? String(n.dropFirst(6).dropLast(4)) : nil
        }.sorted()
        if let only = ProcessInfo.processInfo.environment["QURANLAB_COMPARE_CONTEXTS"], !only.isEmpty {
            let wanted = Set(only.split(separator: " ").map(String.init))
            contexts = contexts.filter { wanted.contains($0) }
        }
        XCTAssertFalse(contexts.isEmpty, "no keeps/keeps_<context>.bin in \(root)")
        let clips = try PackageComparison.clips()
        XCTAssertFalse(clips.isEmpty)
        let seconds = clips.reduce(0.0) { $0 + Double($1.samples.count) / 16_000 }
        print("COMPARE contexts \(contexts); \(clips.count) clips, \(String(format: "%.1f", seconds)) s of audio: \(clips.map { $0.name })")
        print("COMPARE compiling both packages (the first load on this Mac takes a while)")
        let table = try await MLModel.compileModel(at: dir.appendingPathComponent("keep_table.mlpackage"))
        let oneFile = try await MLModel.compileModel(at: dir.appendingPathComponent("keep_sel.mlpackage"))

        var failed: [String] = []
        let units: [(unit: MLComputeUnits, name: String)] = [(.cpuAndNeuralEngine, "Neural Engine allowed (cpuAndNeuralEngine)"),
                                                            (.cpuOnly, "CPU only (cpuOnly)")]
        for u in units {
            for context in contexts {
                let at = "\(context), \(u.name)"
                let a = try TajweedNeuralEngine(model: table, keeps: keepsDir.appendingPathComponent("keeps_\(context).bin"),
                                                front: "front_\(context)", back: "back_\(context)", computeUnits: u.unit)
                let b = try TajweedNeuralEngine(model: oneFile, keeps: nil, front: "front_\(context)", back: "back_\(context)",
                                                computeUnits: u.unit)
                XCTAssertEqual(a.kind, .keepTable, "\(at): the first package")
                guard case .keepSel(let rows) = b.kind else {
                    failed.append("\(at): the second package is not of the one-file kind")
                    continue
                }
                print("COMPARE \(at): keep table of \(a.keepRowCount) rows, keep_sel of \(rows) rows, window \(a.window), advance \(a.advance)")
                if a.keepRowCount != rows { failed.append("\(at): the keep table has \(a.keepRowCount) rows and keep_sel \(rows)") }
                if a.window != b.window || a.advance != b.advance {
                    failed.append("\(at): the packages differ in geometry")
                    continue
                }
                let r = try PackageComparison.run(a, b, clips: clips)
                print("COMPARE \(at): \(r.chunks) chunks; median chunk time of the last clip "
                      + "\(String(format: "%.3f", 1000 * PackageComparison.median(a.chunkSeconds))) ms (keep table), "
                      + "\(String(format: "%.3f", 1000 * PackageComparison.median(b.chunkSeconds))) ms (keep_sel)")
                for line in PackageComparison.table(r, label: "COMPARE \(at)") { print(line) }
                failed += r.failed.map { "\(at): \($0)" }
            }
        }
        print("COMPARE result: " + (failed.isEmpty ? "IDENTICAL: no value of any head differs, in any context, under either compute unit"
                                                   : "DIFFERENT, \(failed.count) findings"))
        for f in failed { print("COMPARE finding: \(f)") }
        XCTAssertEqual(failed, [], "the two kinds of package must give the same heads")
    }
}
