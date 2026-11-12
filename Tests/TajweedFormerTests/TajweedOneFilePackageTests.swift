import CoreML
import Foundation
import XCTest
@testable import TajweedFormer

/// The one-file kind of CoreML package (SPEC 5.4): the keep table is inside the package, and front and back take
/// `keep_sel` (float16, shape [1, R], one-hot at min(chunk index, R - 1)) in place of `zf_keepf` and `zf_keepb`.
/// These tests run on a stand-in (`Fixtures/keepsel_stub`, written by `scripts/make_onefile_stub_fixture.py`): six
/// functions with the names, inputs, outputs and shapes of such a package, no model, every output 0. It is
/// compiled here, on the machine that runs the test.
enum KeepSelStub {
    static let contexts = ["c16_l64", "c24_l72", "c24_l256"]
    /// The keep rows of every function of the stand-in.
    static let rows = 12

    /// The stand-in as the repository holds it.
    static func package() throws -> URL {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "keepsel_stub", withExtension: nil, subdirectory: "Fixtures"))
        return dir.appendingPathComponent("onefile_stub.mlpackage")
    }

    private static let made = Locked<URL?>(nil)

    /// The stand-in compiled (once per test process).
    @available(iOS 18.0, macOS 15.0, *)
    static func compiled() async throws -> URL {
        if let url = made.withLock({ $0 }) { return url }
        let url = try await MLModel.compileModel(at: try package())
        made.withLock { $0 = url }
        return url
    }

    /// Every regular file under `root`, with its bytes.
    static func files(_ root: URL) throws -> [(path: String, data: Data)] {
        let e = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path))
        var out: [(path: String, data: Data)] = []
        while let rel = e.nextObject() as? String {
            var isDir: ObjCBool = false
            let path = root.appendingPathComponent(rel).path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            out.append((path: rel, data: try Data(contentsOf: URL(fileURLWithPath: path))))
        }
        return out.sorted { $0.path < $1.path }
    }
}

final class TajweedOneFilePackageTests: XCTestCase {
    override func tearDown() {
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// What must not be in a fixture of a public repository: a model's version, a training step, the provenance
    /// of an export. The script that writes the fixture removes the metadata that held them.
    static let forbidden = ["4.1", "v4_s1", "checkpoint", "source_onnx", "model_id", "model_version"]

    /// The stand-in holds nothing but the interface: three small files, a weights file whose every constant is 0
    /// (what is not 0 in it is the header of each stored constant), and nothing that identifies a model.
    func testTheStubHoldsNothingButTheInterface() throws {
        let root = try KeepSelStub.package()
        let files = try KeepSelStub.files(root)
        print("KEEPSEL STUB files: \(files.map { "\($0.path) \($0.data.count)" })")
        XCTAssertEqual(files.map { $0.path }, ["Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin", "Manifest.json"])
        XCTAssertLessThan(files.map { $0.data.count }.reduce(0, +), 70_000, "a real package is over 100 MB")
        let weights = try XCTUnwrap(files.first { $0.path.hasSuffix("weight.bin") }).data
        let notZero = weights.reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
        print("KEEPSEL STUB weight.bin: \(weights.count) bytes, \(notZero) of them not 0")
        XCTAssertLessThan(notZero, 256, "no weights: only the headers of constants that are all 0")
        for f in files {
            for s in Self.forbidden {
                XCTAssertNil(f.data.range(of: Data(s.utf8)), "\(f.path) holds \(s)")
            }
        }
    }

    /// The stand-in compiles on this machine, and each of its six functions takes `st` and `keep_sel` [1, 12]
    /// float16 and neither `zf_keepf` nor `zf_keepb`. Its metadata names no version and no model: nothing the SDK
    /// does with a package can depend on them.
    func testTheStubCompilesAndEveryFunctionTakesKeepSel() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { throw XCTSkip("needs macOS 15 / iOS 18") }
        let compiled = try await KeepSelStub.compiled()
        for context in KeepSelStub.contexts {
            for half in ["front", "back"] {
                let fn = "\(half)_\(context)"
                let c = MLModelConfiguration()
                c.computeUnits = .cpuOnly
                c.functionName = fn
                let model = try MLModel(contentsOf: compiled, configuration: c)
                let inputs = model.modelDescription.inputDescriptionsByName
                let shown = inputs.keys.sorted().map { (name: String) -> String in
                    let k = inputs[name]?.multiArrayConstraint
                    return "\(name) \(k?.shape.map(\.intValue) ?? []) type \(k?.dataType.rawValue ?? -1)"
                }
                print("KEEPSEL STUB \(fn): inputs \(shown); outputs \(model.modelDescription.outputDescriptionsByName.keys.sorted())")
                XCTAssertNotNil(inputs["st"], fn)
                XCTAssertNil(inputs["zf_keepf"], fn)
                XCTAssertNil(inputs["zf_keepb"], fn)
                let sel = try XCTUnwrap(inputs["keep_sel"]?.multiArrayConstraint, fn)
                XCTAssertEqual(sel.shape.map(\.intValue), [1, KeepSelStub.rows], fn)
                XCTAssertEqual(sel.dataType, .float16, fn)
                let metadata = model.modelDescription.metadata
                let version = metadata[.versionString] as? String ?? ""
                let own = metadata[.creatorDefinedKey] as? [String: String] ?? [:]
                XCTAssertEqual(version, "", "\(fn): no version in the metadata")
                XCTAssertEqual(Set(own.keys).subtracting(["stub", "keeps", "precision"]), [], "\(fn): no entry that identifies a model")
            }
        }
    }

    // MARK: the kind, from the inputs

    /// The inputs of a front and a back function, as name to shape: `keeps` names what each takes for its keep rows.
    static func inputs(front: [String: [Int]], back: [String: [Int]]) -> (front: [String: [Int]], back: [String: [Int]]) {
        var f: [String: [Int]] = ["x": [1, 1, 45, 80], "st": [1, 1, 2322, 64]]
        var b: [String: [Int]] = ["var_13545_cast_fp16": [16, 1, 384], "st": [1, 1, 2156, 64]]
        f.merge(front) { _, new in new }
        b.merge(back) { _, new in new }
        return (f, b)
    }

    /// What `CoreMLPackageKind.tell` says of these inputs: the kind, or the words of its refusal.
    static func told(front: [String: [Int]], back: [String: [Int]]) -> (kind: CoreMLPackageKind?, refusal: String?) {
        let i = inputs(front: front, back: back)
        do throws(RecognizerError) {
            let kind = try CoreMLPackageKind.tell(front: i.front, back: i.back)
            return (kind, nil)
        } catch {
            guard case .neuralEngineUnavailable(let why) = error else { return (nil, "another error: \(error)") }
            return (nil, why)
        }
    }

    /// The two kinds are told apart by the inputs alone: `zf_keepf` in front and `zf_keepb` in back is the
    /// keep-table kind; `keep_sel` [1, R] in both is the one-file kind, with R read from the shape (12, 17 and 33
    /// here; the stand-in has 12, so 17 and 33 are tested on this function and not through a load).
    func testTheKindIsToldFromTheInputs() {
        let table = Self.told(front: ["zf_keepf": [1, 6912]], back: ["zf_keepb": [1, 4800]])
        XCTAssertEqual(table.kind, .keepTable)
        XCTAssertNil(table.refusal)
        for rows in [12, 17, 33, 1] {
            let one = Self.told(front: ["keep_sel": [1, rows]], back: ["keep_sel": [1, rows]])
            XCTAssertEqual(one.kind, .keepSel(rows: rows), "R \(rows)")
            XCTAssertNil(one.refusal, "R \(rows)")
        }
    }

    /// A package the host cannot run is refused when it is loaded: one kind in front and the other in back (either
    /// way round), both kinds in one function, neither, an R that differs between front and back, and a `keep_sel`
    /// that is not [1, R].
    func testAPackageOfMixedKindsOrOfNeitherIsRefused() {
        let sel = ["keep_sel": [1, 12]]
        let refused: [(name: String, front: [String: [Int]], back: [String: [Int]])] = [
            ("keep rows in front, keep_sel in back", ["zf_keepf": [1, 6912]], sel),
            ("keep_sel in front, keep rows in back", sel, ["zf_keepb": [1, 4800]]),
            ("both in front and in back", ["zf_keepf": [1, 6912], "keep_sel": [1, 12]], ["zf_keepb": [1, 4800], "keep_sel": [1, 12]]),
            ("both in front only", ["zf_keepf": [1, 6912], "keep_sel": [1, 12]], sel),
            ("neither", [:], [:]),
            ("neither in back", sel, [:]),
            ("neither in front", [:], ["zf_keepb": [1, 4800]]),
            ("R differs between front and back", ["keep_sel": [1, 12]], ["keep_sel": [1, 17]]),
            ("keep_sel of one dimension", ["keep_sel": [12]], ["keep_sel": [12]]),
            ("keep_sel of two rows", ["keep_sel": [2, 12]], ["keep_sel": [2, 12]]),
            ("keep_sel without a row", ["keep_sel": [1, 0]], ["keep_sel": [1, 0]]),
        ]
        for r in refused {
            let got = Self.told(front: r.front, back: r.back)
            XCTAssertNil(got.kind, r.name)
            let why = got.refusal ?? ""
            print("KEEPSEL refused, \(r.name): \(why)")
            XCTAssertTrue(why.hasPrefix("the package does not follow the V4 host contract"), "\(r.name): \(why)")
        }
    }

    /// The keep row of chunk c is min(c, R - 1), chunk 0 a stream's first call, and its selector is R values with
    /// 1.0 at that row and 0.0 elsewhere: for R of 12, 17 and 33, for chunks up to and beyond R.
    func testTheRowOfAChunkAndItsSelector() {
        for rows in [12, 17, 33] {
            XCTAssertEqual(CoreMLPackageKind.row(chunk: 0, rows: rows), 0, "a stream's first call")
            for chunk in 0..<(rows + 40) {
                let row = CoreMLPackageKind.row(chunk: chunk, rows: rows)
                XCTAssertEqual(row, min(chunk, rows - 1), "R \(rows), chunk \(chunk)")
                let sel = CoreMLPackageKind.oneHot(row: row, rows: rows)
                XCTAssertEqual(sel.count, rows)
                XCTAssertEqual(sel.firstIndex(of: 1), row, "R \(rows), chunk \(chunk)")
                XCTAssertEqual(sel.filter { $0 != 0 }.count, 1, "R \(rows), chunk \(chunk): one-hot")
            }
            XCTAssertEqual(CoreMLPackageKind.row(chunk: 100_000, rows: rows), rows - 1)
        }
    }

    // MARK: the engine on the stand-in

    /// 0.1 s pieces of a recitation-like signal through the engine: at most one chunk completes per piece, so the
    /// keep row of every chunk can be read after the piece that completed it. The rows, in chunk order.
    @available(iOS 18.0, macOS 15.0, *)
    func rowsFed(_ e: TajweedNeuralEngine, seconds: Double) throws -> [Int] {
        let samples = fakeRecitation(seconds: seconds)
        var rows: [Int] = []
        var at = 0
        while at < samples.count {
            let n = min(1600, samples.count - at)
            let chunks = try samples[at..<at + n].withUnsafeBufferPointer { (p) throws(RecognizerError) in try e.push(p) }
            XCTAssertLessThanOrEqual(chunks.count, 1, "a 0.1 s piece completes at most one chunk")
            if !chunks.isEmpty { rows.append(try XCTUnwrap(e.lastKeepRow)) }
            at += n
        }
        return rows
    }

    /// The stand-in loads as a one-file package without a keep table, in every context it has, and a stream runs
    /// through front and back: chunk c is fed row min(c, 11), from the first call on and beyond row 11; the selector
    /// the engine feeds is the one-hot of that row; every head comes out finite and of its shape. A reset and a
    /// warm-up start the next stream at row 0 again.
    func testTheStubRunsAsAOneFilePackageAndEveryChunkIsFedItsRow() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { throw XCTSkip("needs macOS 15 / iOS 18") }
        let compiled = try await KeepSelStub.compiled()
        for context in KeepSelStub.contexts {
            for units in [MLComputeUnits.cpuOnly, .cpuAndNeuralEngine] {
                let at = "\(context) units \(units.rawValue)"
                let e = try TajweedNeuralEngine(model: compiled, keeps: nil, front: "front_\(context)", back: "back_\(context)", computeUnits: units)
                XCTAssertEqual(e.kind, .keepSel(rows: KeepSelStub.rows), at)
                XCTAssertEqual(e.keepRowCount, KeepSelStub.rows, at)
                XCTAssertNil(e.lastKeepRow, "\(at): nothing fed before a stream's first chunk")
                for chunk in [0, 1, 5, 11, 12, 40] {
                    let sel = try XCTUnwrap(e.keepSelValues(chunk: chunk), at)
                    XCTAssertEqual(sel, CoreMLPackageKind.oneHot(row: min(chunk, 11), rows: 12), "\(at): the selector of chunk \(chunk)")
                }
                // 10 s: 20 chunks and more in every context, so the rows go beyond the last one
                let rows = try rowsFed(e, seconds: 10)
                print("KEEPSEL STUB \(at): window \(e.window), advance \(e.advance), \(rows.count) chunks, rows fed \(rows)")
                XCTAssertGreaterThan(rows.count, KeepSelStub.rows + 4, at)
                XCTAssertEqual(rows, rows.indices.map { min($0, KeepSelStub.rows - 1) }, "\(at): chunk c is fed row min(c, 11)")
                XCTAssertEqual(rows.first, 0, "\(at): a stream's first call is chunk 0")
                let h = e.take
                XCTAssertGreaterThan(h.n40, 0, at)
                XCTAssertTrue(h.isFinite, "\(at): non-finite heads")
                for (name, width, ms) in HeadsBuffer.layout {
                    XCTAssertEqual(h[name].count, (ms == 40 ? h.n40 : h.n20) * width, "\(at) \(name)")
                }
                // the next stream starts at row 0 again: after a reset, and after a warm-up (which runs one chunk)
                e.reset()
                XCTAssertNil(e.lastKeepRow, at)
                XCTAssertEqual(try rowsFed(e, seconds: 2).first, 0, "\(at): after a reset")
                try e.warmUp()
                XCTAssertNil(e.lastKeepRow, "\(at): a warm-up leaves nothing behind")
                XCTAssertEqual(try rowsFed(e, seconds: 2).prefix(3), [0, 1, 2], "\(at): after a warm-up")
            }
        }
    }

    /// A one-file package does not read a keep table: a path to one that does not exist changes nothing.
    func testAOneFilePackageDoesNotReadAKeepTable() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { throw XCTSkip("needs macOS 15 / iOS 18") }
        let compiled = try await KeepSelStub.compiled()
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("no-keeps-\(UUID().uuidString).bin")
        let e = try TajweedNeuralEngine(model: compiled, keeps: nowhere, front: "front_c16_l64", back: "back_c16_l64", computeUnits: .cpuOnly)
        XCTAssertEqual(e.kind, .keepSel(rows: 12))
        XCTAssertEqual(try rowsFed(e, seconds: 2).prefix(2), [0, 1])
    }

    /// A function the package does not have is refused at load, with the reason every package the host cannot run
    /// gets (`neuralEngineUnavailable`, which the pipeline's compile stage reports as `compile_error`).
    func testAContextThePackageHasNoFunctionsForIsRefusedAtLoad() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { throw XCTSkip("needs macOS 15 / iOS 18") }
        let compiled = try await KeepSelStub.compiled()
        XCTAssertThrowsError(try TajweedNeuralEngine(model: compiled, keeps: nil, front: "front_c99_l1", back: "back_c99_l1", computeUnits: .cpuOnly)) { e in
            guard case .neuralEngineUnavailable(let why)? = e as? RecognizerError else { return XCTFail("\(e)") }
            print("KEEPSEL STUB a function the package does not have: \(why)")
        }
    }

    // MARK: a model folder with the stand-in, through the pipeline's own compile stage

    /// A folder of decoded model files whose fp16 package is the compiled stand-in, with no manifest yet: the
    /// bundled test folder with its fake packages and its keep tables removed, and c16_l64's CPU files copied to
    /// c8_l64 (a context the stand-in has no functions for).
    @available(iOS 18.0, macOS 15.0, *)
    static func bareFolder() async throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tf-onefile-\(UUID().uuidString)")
        try fm.copyItem(at: Fixtures.v4mini().appendingPathComponent("decoded"), to: dir)
        try fm.copyItem(at: dir.appendingPathComponent("c16_l64"), to: dir.appendingPathComponent("c8_l64"))
        for sub in ["coreml", "coreml-compact"] { try fm.removeItem(at: dir.appendingPathComponent(sub)) }
        try fm.createDirectory(at: dir.appendingPathComponent("coreml"), withIntermediateDirectories: true)
        try fm.copyItem(at: try await KeepSelStub.compiled(), to: dir.appendingPathComponent("coreml/tajweedformer_v4.mlmodelc"))
        return dir
    }

    /// A verified model folder whose fp16 package is the compiled stand-in: the bundled test folder with its fake
    /// package replaced, no keep table, c16_l64's CPU files copied to c8_l64, and a manifest whose signed tolerance
    /// names `coreml:<context>` for each of `served` (identical tokens, written as a tolerance).
    @available(iOS 18.0, macOS 15.0, *)
    static func folder(served: [String]) async throws -> ModelFolder {
        let dir = try await bareFolder()
        var m = try Fixtures.manifest(for: dir, revision: "v4.0-test.onefile")
        let entry: [String: Any] = ["log_probs": ["token_edits": 0, "lp_mean": 30.0, "lp_p99": 30.0]]
        var tolerance: [String: Any] = [:]
        for context in served { tolerance["coreml:\(context)"] = entry }
        m.goldenRawField = JSONValue(any: try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: tolerance)))
        // a private storage folder: the recognizer looks for an earlier promotion's record
        Fixtures.configure()
        m.signature = try CloudFixtures.signer.signature(for: Data(m.signedText().utf8)).base64EncodedString()
        try m.jsonData().write(to: dir.appendingPathComponent(ModelManifest.fileName))
        let verifier = ManifestVerifier(trustedKeys: [CloudFixtures.signer.publicKey.rawRepresentation], requireSignature: true)
        return try ModelFolder.open(directory: dir, verifier: verifier)
    }

    /// The folder's one-file build goes through the SDK's own compile stage: the folder hands the package out
    /// without a keep table, and the stage loads it as a one-file package.
    func testAFoldersOneFileBuildLoadsThroughThePipelinesCompileStage() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { throw XCTSkip("needs macOS 15 / iOS 18") }
        let model = try await Self.folder(served: ["c16_l64"])
        XCTAssertNil(model.coreMLProblem)
        let build = try XCTUnwrap(model.coreML(context: "c16_l64", compact: false))
        XCTAssertNil(build.keeps)
        XCTAssertEqual(build.frontFunction, "front_c16_l64")
        XCTAssertNil(model.coreML(context: "c24_l72"), "no key for c24_l72: not served")
        let r = try TajweedRecognizer(model: model, context: "c16_l64", backend: .automatic)
        let loaded = try await r.makeStages().compile()
        let engine = try XCTUnwrap(loaded.value as? TajweedNeuralEngine)
        XCTAssertEqual(engine.kind, .keepSel(rows: KeepSelStub.rows))
        XCTAssertEqual(try rowsFed(engine, seconds: 2).prefix(3), [0, 1, 2])
    }

    /// A package the host cannot run ends the compile stage with `compile_error`, the reason that stage gives for
    /// any package it cannot load: here a context the manifest says the build serves and the package has no
    /// functions for. (A package of mixed kinds, and a keep-table package without a listed keep table, are refused
    /// by the same load with the same error; no such package exists to put in a folder.)
    func testAPackageTheHostCannotRunEndsTheCompileStageWithCompileError() async throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { throw XCTSkip("needs macOS 15 / iOS 18") }
        let model = try await Self.folder(served: ["c16_l64", "c8_l64"])
        XCTAssertNotNil(model.coreML(context: "c8_l64", compact: false), "the manifest decides, also for c8_l64")
        let r = try TajweedRecognizer(model: model, context: "c8_l64", backend: .automatic)
        var failure: PromotionFailure?
        do throws(PromotionFailure) {
            _ = try await r.makeStages().compile()
        } catch {
            failure = error
        }
        let f = try XCTUnwrap(failure, "the compile stage accepted a package without functions for the context")
        print("KEEPSEL STUB compile stage, a context the package has no functions for: \(f.reason.rawValue): \(f.detail)")
        XCTAssertEqual(f.reason, .compileError)
        XCTAssertEqual(f.reason.rawValue, "compile_error")
    }

    // MARK: both kinds in one process (needs the keep-table packages of TAJWEED_COREML)

    /// A keep-table package (the builds of 4.0.0) and a one-file package side by side in one process: each is told
    /// from its own inputs, the keep-table package still decodes the Basmala token for token while the one-file
    /// stand-in runs between its pieces, and a keep-table package without its keep table is refused at load.
    func testAKeepTablePackageAndAOneFilePackageSideBySide() async throws {
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
        let table = try TajweedNeuralEngine(model: real, keeps: dir.appendingPathComponent("keeps.bin"), computeUnits: .cpuOnly)
        let oneFile = try TajweedNeuralEngine(model: stub, keeps: nil, front: "front_c16_l64", back: "back_c16_l64", computeUnits: .cpuOnly)
        XCTAssertEqual(table.kind, .keepTable)
        XCTAssertNil(table.keepSelValues(chunk: 0), "a keep-table package has no selector")
        XCTAssertGreaterThan(table.keepRowCount, 0)
        XCTAssertEqual(oneFile.kind, .keepSel(rows: 12))

        // the keep-table package without its keep table: refused at load
        XCTAssertThrowsError(try TajweedNeuralEngine(model: real, keeps: nil, computeUnits: .cpuOnly)) { e in
            guard case .neuralEngineUnavailable(let why)? = e as? RecognizerError else { return XCTFail("\(e)") }
            print("KEEPSEL a keep-table package without its keep table: \(why)")
            XCTAssertTrue(why.contains("keep table"), why)
        }

        // interleaved: a piece to one, a piece to the other
        let expect = try XCTUnwrap(JSONValue(data: Data(contentsOf: dir.appendingPathComponent("basmala.json")))?.object)
        let (clip, ids) = try XCTUnwrap(expect.sorted(by: { $0.key < $1.key }).first)
        let samples = try Fixtures.samples(clip)
        let filler = fakeRecitation(seconds: Double(samples.count) / 16_000 + 1)
        var at = 0
        var stubRows: [Int] = []
        while at < samples.count {
            let n = min(1600, samples.count - at)
            _ = try samples[at..<at + n].withUnsafeBufferPointer { (p) throws(RecognizerError) in try table.push(p) }
            let chunks = try filler[at..<at + n].withUnsafeBufferPointer { (p) throws(RecognizerError) in try oneFile.push(p) }
            if !chunks.isEmpty { stubRows.append(try XCTUnwrap(oneFile.lastKeepRow)) }
            at += n
        }
        _ = try table.finish()
        _ = try oneFile.finish()
        let want = (ids.array ?? []).compactMap { $0.number.map(Int.init) }
        XCTAssertEqual(table.take.greedy, want, "\(clip): the keep-table package's tokens, with a one-file package running beside it")
        XCTAssertEqual(stubRows, stubRows.indices.map { min($0, 11) }, "the one-file package's rows, with a keep-table package running beside it")
        print("KEEPSEL side by side, \(clip): keep-table package \(table.take.greedy.count) tokens over \(table.chunkSeconds.count) chunks; "
              + "one-file stand-in \(stubRows.count) chunks before the end, rows \(stubRows)")
    }
}
