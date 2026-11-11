import Foundation
import XCTest
@testable import TajweedFormer

/// A microphone for tests: the permission answer is set, `open` hands back the two callbacks, and the test delivers
/// samples and notices itself.
final class FakeMicrophone: CaptureDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: (@Sendable ([Float], Double) -> Void)?
    private var notice: (@Sendable (CaptureNotice) -> Void)?
    private var _opened = 0, _closed = 0, _asked = 0
    let granted: Bool
    let failure: RecognizerError?

    init(granted: Bool = true, failure: RecognizerError? = nil) {
        self.granted = granted
        self.failure = failure
    }

    var opened: Int { lock.lock(); defer { lock.unlock() }; return _opened }
    var closed: Int { lock.lock(); defer { lock.unlock() }; return _closed }
    var asked: Int { lock.lock(); defer { lock.unlock() }; return _asked }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return deliver != nil }

    func authorize() async -> Bool {
        countAsk()
        return granted
    }

    private func countAsk() {
        lock.lock()
        _asked += 1
        lock.unlock()
    }

    func open(deliver: @escaping @Sendable ([Float], Double) -> Void,
              notice: @escaping @Sendable (CaptureNotice) -> Void) throws(RecognizerError) {
        if let failure { throw failure }
        lock.lock()
        self.deliver = deliver
        self.notice = notice
        _opened += 1
        lock.unlock()
    }

    func close() {
        lock.lock()
        if deliver != nil { _closed += 1 }
        deliver = nil
        notice = nil
        lock.unlock()
    }

    /// What the hardware would give: samples at `rate`, in pieces of 10 ms. Nothing goes anywhere once it is closed.
    func speak(_ samples: [Float], rate: Double) {
        let piece = max(1, Int(rate / 100))
        var at = 0
        while at < samples.count {
            lock.lock()
            let d = deliver
            lock.unlock()
            guard let d else { return }
            d(Array(samples[at..<min(samples.count, at + piece)]), rate)
            at += piece
        }
    }

    func send(_ n: CaptureNotice) {
        lock.lock()
        let f = notice
        lock.unlock()
        f?(n)
    }
}

/// SDK 3.0.0: Model, Session, chunks and events over a stand-in CPU engine (the take's order and shape, not the
/// model's numbers).
final class SessionAPITests: XCTestCase {
    override func setUp() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { _ in FakeCPUEngine() } }
        Fixtures.configure()
    }

    override func tearDown() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = nil }
    }

    /// The bundled test folder's CPU set, opened as a Model.
    func model() async throws -> TajweedModel {
        let server = try Fixtures.v4mini().appendingPathComponent("server")
        let m = try ModelManifest.read(server)
        let dir = Fixtures.storage().appendingPathComponent("model")
        _ = try await ModelInstaller(source: DirectoryFileSource(root: server))
            .install(m, profile: DownloadProfile(context: "c16_l64", coreML: false), into: dir)
        let folder = try ModelFolder.open(directory: dir, verifier: ManifestVerifier(trustedKeys: [try Fixtures.v4miniKey()], requireSignature: true))
        return TajweedModel(folder, client: nil)
    }

    func collect<T: Sendable>(_ stream: AsyncStream<T>) async -> [T] {
        var out: [T] = []
        for await x in stream { out.append(x) }
        return out
    }

    func code(_ body: () async throws -> Void) async -> String? {
        do { try await body() } catch let e as TajweedError { return e.code } catch { return "other: \(error)" }
        return nil
    }

    /// A recitation at `rate`: the same tone as `fakeRecitation`, sampled at that rate.
    func recitation(seconds: Double, rate: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            return Float(0.2 * sin(2 * .pi * 180 * t) * (0.6 + 0.4 * sin(2 * .pi * 0.8 * t)))
        }
    }

    // MARK: a pushed take

    func testAPushedTakeGivesChunksInOrderAndTheTakesHeads() async throws {
        let model = try await model()
        let session = try await model.session()
        let audio = fakeRecitation(seconds: 3)
        var at = 0
        while at < audio.count {
            try session.push(Array(audio[at..<min(audio.count, at + 1600)]))
            at += 1600
        }
        let heads = try await session.finish()
        let chunks = await collect(session.chunks)
        XCTAssertGreaterThan(chunks.count, 8, "3 s of audio and the flush")
        XCTAssertEqual(chunks.map(\.index), Array(0..<chunks.count))
        var frame = 0
        for c in chunks {
            XCTAssertEqual(c.firstFrame, frame)
            XCTAssertEqual(c.startMs, c.index * 320)
            XCTAssertEqual(c.endMs, c.startMs + 320)
            XCTAssertEqual(c.backend.kind, .cpu)
            XCTAssertEqual(c.heads["log_probs"]?.frames, 8)
            XCTAssertEqual(c.heads["log_probs"]?.classes, 38)
            XCTAssertEqual(c.heads["log_probs"]?.frameMs, 40)
            XCTAssertEqual(c.heads["log_probs"]?.kind, .ctc)
            frame += 8
            XCTAssertEqual(c.decoded.frames.count, frame, "the decoded layer is the take so far")
        }
        XCTAssertEqual(chunks.filter { $0.decoded.isFinal }.map(\.index), [chunks.count - 1], "only the last chunk is final")
        // the take's Heads are every chunk's, and their decoded layer is the last chunk's
        let final = heads.decoded()
        XCTAssertTrue(final.isFinal)
        XCTAssertEqual(final.tokens, chunks.last?.decoded.tokens)
        XCTAssertEqual(final.settled, final.tokens.count)
        XCTAssertEqual(heads["log_probs"]?.frames, frame)
        XCTAssertEqual(heads.greedy().map(\.id), final.tokens.map(\.id))
        XCTAssertEqual(heads.greedy().map(\.firstMs), final.tokens.map(\.firstMs))
        XCTAssertEqual(heads.greedy().map(\.lastMs), final.tokens.map(\.lastMs))
        XCTAssertFalse(final.tokens.isEmpty)
        XCTAssertEqual(final.text, final.tokens.map(\.name).joined(separator: " "))
        XCTAssertNil(heads["attr_face"], "a head that was not selected is not there")
        XCTAssertEqual(heads.greedy("attr_face"), [])
    }

    func testSettledNeverDecreasesWithinATake() async throws {
        let model = try await model()
        let session = try await model.listen(from: fakeRecitation(seconds: 6), sampleRate: 16_000, options: .init(pace: .fast))
        var settled = 0
        var tokens: [TajweedToken] = []
        for await c in session.chunks {
            XCTAssertGreaterThanOrEqual(c.decoded.settled, settled)
            XCTAssertLessThanOrEqual(c.decoded.settled, c.decoded.tokens.count)
            // what was settled did not change
            XCTAssertEqual(Array(c.decoded.tokens.prefix(settled)), Array(tokens.prefix(settled)))
            settled = c.decoded.settled
            tokens = c.decoded.tokens
        }
        XCTAssertEqual(settled, tokens.count, "the final decoded layer is settled")
    }

    func testOneOpenSessionPerModel() async throws {
        let model = try await model()
        let first = try await model.session()
        let busy = await code { _ = try await model.session() }
        XCTAssertEqual(busy, "session_open")
        let busyListen = await code { _ = try await model.listen(from: [0, 0, 0], sampleRate: 16_000) }
        XCTAssertEqual(busyListen, "session_open")
        try await first.finish()
        let second = try await model.session()
        await second.cancel()
        let third = try await model.session()
        try await third.finish()
    }

    func testCallsOnAnEndedSession() async throws {
        let model = try await model()
        let session = try await model.session()
        try session.push(fakeRecitation(seconds: 1))
        try await session.finish()
        XCTAssertThrowsError(try session.push([0, 0])) { XCTAssertEqual(($0 as? TajweedError)?.code, "session_closed") }
        // finish again gives the same take's Heads
        let again = try await session.finish()
        XCTAssertFalse(again.names.isEmpty)

        let cancelled = try await model.session()
        try cancelled.push(fakeRecitation(seconds: 1))
        await cancelled.cancel()
        let after = await code { _ = try await cancelled.finish() }
        XCTAssertEqual(after, "cancelled")
        let chunks = await collect(cancelled.chunks)
        XCTAssertFalse(chunks.contains { $0.decoded.isFinal }, "a cancelled take has no final chunk")
    }

    func testWhatTheOptionsRefuse() async throws {
        let model = try await model()
        let cases: [TajweedSessionOptions] = [
            .init(context: "c99_l1"), .init(sampleRate: 12_345), .init(heads: ["log_probs", "scores"]), .init(heads: []),
            .init(topK: 39), .init(topK: -1), .init(endOnSilenceMs: 10),
        ]
        for o in cases {
            let c = await code { _ = try await model.session(options: o) }
            XCTAssertEqual(c, "invalid_argument", "\(o)")
        }
        // a refused call leaves the Model free
        let ok = try await model.session(options: .init(sampleRate: 48_000, heads: TajweedSessionOptions.allHeads, topK: 3))
        try ok.push(recitation(seconds: 2, rate: 48_000))
        let heads = try await ok.finish()
        let frames = heads.decoded().frames
        XCTAssertFalse(frames.isEmpty)
        XCTAssertTrue(frames.allSatisfy { $0.topK.count == 3 && $0.topK.first == $0.top1 }, "topK ranks each frame, best first")
        let listenOnly = try await model.listen(from: fakeRecitation(seconds: 1), sampleRate: 16_000, options: .init(pace: .fast))
        XCTAssertThrowsError(try listenOnly.push([0])) { XCTAssertEqual(($0 as? TajweedError)?.code, "invalid_argument") }
        try await listenOnly.finish()
        XCTAssertThrowsError(try model.chunkMs("nope")) { XCTAssertEqual(($0 as? TajweedError)?.code, "invalid_argument") }
        XCTAssertEqual(try model.chunkMs("c16_l64"), 320)
    }

    // MARK: listen without a microphone

    func testListenFromSamplesEndsWithTheSource() async throws {
        let model = try await model()
        let session = try await model.listen(from: fakeRecitation(seconds: 3), sampleRate: 16_000, options: .init(pace: .fast))
        let events = await collect(session.events)
        XCTAssertEqual(events.last, .ended(.sourceEnd))
        XCTAssertTrue(events.contains { if case .speechStarted = $0 { return true }; return false })
        let chunks = await collect(session.chunks)
        XCTAssertEqual(chunks.last?.decoded.isFinal, true)
        XCTAssertTrue(chunks.contains { $0.speech })
        let heads = try await session.finish()
        XCTAssertEqual(heads.decoded().tokens, chunks.last?.decoded.tokens)
        // the Model is free again
        let next = try await model.session()
        await next.cancel()
    }

    func testRealTimePaceTakesTheClipsLength() async throws {
        let model = try await model()
        let began = Date()
        let session = try await model.listen(from: fakeRecitation(seconds: 1.2), sampleRate: 16_000)
        _ = await collect(session.chunks)
        XCTAssertGreaterThan(Date().timeIntervalSince(began), 1.0, "a clip at real-time pace arrives as a microphone would give it")
    }

    func testEndOnSilenceFinishesTheTake() async throws {
        let model = try await model()
        let audio = fakeRecitation(seconds: 2) + [Float](repeating: 0, count: 5 * 16_000)
        let session = try await model.listen(from: audio, sampleRate: 16_000, options: .init(endOnSilenceMs: 800, pace: .fast))
        let events = await collect(session.events)
        XCTAssertEqual(events.last, .ended(.silence))
        guard case .speechStarted(let started)? = events.first else { return XCTFail("\(events)") }
        XCTAssertLessThan(started, 800)
        let ended = events.compactMap { e -> (Int, Int)? in
            if case .speechEnded(let at, let silence) = e { return (at, silence) }
            return nil
        }
        XCTAssertEqual(ended.count, 1)
        // the stand-in engine hears the tone up to the end of chunk 6 (frame 55, the last active frame): speech ends at
        // the end of that frame, and the take ends with the chunk that carries frame 55 + 20 (800 ms is 20 frames)
        XCTAssertEqual(ended[0].1, 800)
        XCTAssertEqual(ended[0].0, 40 * (55 + 1), "speech ended at the end of the last frame with sound")
        let chunks = await collect(session.chunks)
        XCTAssertEqual(chunks.count, 10, "the chunk that carries frame 75 is the last: nothing after it is decoded")
        XCTAssertEqual(chunks.filter { $0.decoded.isFinal }.map(\.index), [9])
        XCTAssertEqual(chunks.map(\.speech), [true, true, true, true, true, true, true, false, false, false], "a chunk holds speech when one of its frames does")
        XCTAssertEqual(chunks.last?.decoded.settled, chunks.last?.decoded.tokens.count)
        let heads = try await session.finish()
        XCTAssertEqual(heads["log_probs"]?.frames, 8 * 10, "the take's Heads are the frames up to that chunk")
        XCTAssertEqual(heads.decoded().tokens, chunks.last?.decoded.tokens)
    }

    func testWithoutTheOptionSpeechEndsAfter1500msAndTheTakeGoesOn() async throws {
        let model = try await model()
        let audio = fakeRecitation(seconds: 2) + [Float](repeating: 0, count: 4 * 16_000) + fakeRecitation(seconds: 1)
        let session = try await model.listen(from: audio, sampleRate: 16_000, options: .init(pace: .fast))
        let events = await collect(session.events)
        let silences = events.compactMap { e -> Int? in
            if case .speechEnded(_, let silence) = e { return silence }
            return nil
        }
        XCTAssertEqual(silences, [1520], "1500 ms is 38 frames")
        XCTAssertEqual(events.filter { if case .speechStarted = $0 { return true }; return false }.count, 2, "speech started again")
        XCTAssertEqual(events.last, .ended(.sourceEnd))
    }

    // MARK: listen with a (fake) microphone

    func testARefusedPermissionIsMicrophoneDenied() async throws {
        let model = try await model()
        let mic = FakeMicrophone(granted: false)
        let c = await code { _ = try await model.listen(options: .init(), device: mic) }
        XCTAssertEqual(c, "microphone_denied")
        XCTAssertEqual(mic.asked, 1)
        XCTAssertEqual(mic.opened, 0, "nothing is captured")
        // and the Model is free
        let next = try await model.session()
        await next.cancel()
    }

    func testAMicrophoneThatDoesNotOpenIsMicrophoneUnavailable() async throws {
        let model = try await model()
        let mic = FakeMicrophone(failure: .microphoneUnavailable("no audio input device"))
        let c = await code { _ = try await model.listen(options: .init(), device: mic) }
        XCTAssertEqual(c, "microphone_unavailable")
        let next = try await model.session()
        await next.cancel()
    }

    /// The 2.x quick start's bug: a 48 kHz microphone into a 16 kHz recognizer. `listen` carries the device's rate.
    func testTheDevicesRateIsCarriedToTheSession() async throws {
        let model = try await model()
        let mic = FakeMicrophone()
        let session = try await model.listen(options: .init(), device: mic)
        XCTAssertEqual(mic.opened, 1)
        mic.speak(recitation(seconds: 3, rate: 48_000), rate: 48_000)
        let heads = try await session.finish()
        XCTAssertEqual(mic.closed, 1, "finish stops the microphone")
        XCTAssertFalse(mic.isOpen)
        let chunks = await collect(session.chunks)
        // 3 s of audio is 3 s of chunks whatever the device's rate: as many as the same take at 16 kHz
        let reference = try await model.session()
        try reference.push(recitation(seconds: 3, rate: 16_000))
        _ = try await reference.finish()
        let want = await collect(reference.chunks)
        XCTAssertEqual(chunks.count, want.count)
        XCTAssertEqual(heads["log_probs"]?.frames, 8 * want.count)
        XCTAssertFalse(heads.decoded().tokens.isEmpty)
    }

    func testAnInterruptionPausesAndResumesTheSameTake() async throws {
        let model = try await model()
        let mic = FakeMicrophone()
        let session = try await model.listen(options: .init(), device: mic)
        mic.speak(fakeRecitation(seconds: 1.5), rate: 16_000)
        mic.send(.interruptionBegan)
        mic.send(.interruptionEnded(canResume: true))
        mic.speak(fakeRecitation(seconds: 1.5), rate: 16_000)
        mic.send(.routeChanged)
        mic.speak(recitation(seconds: 1, rate: 44_100), rate: 44_100)
        _ = try await session.finish()
        let events = await collect(session.events)
        let kinds = events.filter { e in
            switch e {
            case .interrupted, .resumed, .ended: return true
            default: return false
            }
        }
        XCTAssertEqual(kinds, [.interrupted(.interruption), .resumed, .interrupted(.routeChange)])
        let chunks = await collect(session.chunks)
        XCTAssertEqual(chunks.map(\.index), Array(0..<chunks.count), "one take across the interruption and the new rate")
        XCTAssertGreaterThan(chunks.count, 12)
    }

    func testAnInterruptionThatCannotResumeEndsTheTake() async throws {
        let model = try await model()
        let mic = FakeMicrophone()
        let session = try await model.listen(options: .init(), device: mic)
        mic.speak(fakeRecitation(seconds: 2), rate: 16_000)
        mic.send(.interruptionBegan)
        mic.send(.interruptionEnded(canResume: false))
        let events = await collect(session.events)
        XCTAssertEqual(events.last, .ended(.interrupted))
        XCTAssertFalse(mic.isOpen, "the microphone is released")
        let heads = try await session.finish()
        XCTAssertFalse(heads.decoded().tokens.isEmpty, "what was heard so far is the take")
    }

    func testTheBackgroundEndsTheTake() async throws {
        let model = try await model()
        let mic = FakeMicrophone()
        let session = try await model.listen(options: .init(), device: mic)
        mic.speak(fakeRecitation(seconds: 2), rate: 16_000)
        mic.send(.background)
        let events = await collect(session.events)
        XCTAssertEqual(events.last, .ended(.background))
        XCTAssertEqual(mic.closed, 1)
        // no audio is captured after the take ended
        mic.speak(fakeRecitation(seconds: 1), rate: 16_000)
        let chunks = await collect(session.chunks)
        XCTAssertEqual(chunks.last?.decoded.isFinal, true)
        let heads = try await session.finish()
        XCTAssertEqual(heads["log_probs"]?.frames, 8 * chunks.count)
        // the app is back: the next take is one call
        let next = try await model.listen(options: .init(), device: FakeMicrophone())
        await next.cancel()
    }

    func testAnInputThatFailsEndsTheTakeWithTheError() async throws {
        let model = try await model()
        let mic = FakeMicrophone()
        let session = try await model.listen(options: .init(), device: mic)
        mic.speak(fakeRecitation(seconds: 1), rate: 16_000)
        mic.send(.failed("no audio input device"))
        let events = await collect(session.events)
        guard case .ended(.error(let e))? = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(e.code, "microphone_unavailable")
    }

    // MARK: the model's data

    func testTheModelsData() async throws {
        let model = try await model()
        XCTAssertEqual(model.id, "v4.0")
        XCTAssertTrue(model.contexts.contains("c16_l64"))
        XCTAssertEqual(model.defaultContext, "c16_l64")
        XCTAssertEqual(model.tokens.count, 38)
        XCTAssertEqual(model.tokens.blank, 0)
        XCTAssertEqual(model.tokens.name(0), model.tokens.id(model.tokens.name(0)).map { model.tokens.name($0) })
        XCTAssertEqual(model.tokens.name(999), "?")
        let cal = try XCTUnwrap(model.calibration)
        XCTAssertEqual(cal.format, "quranlab.tajweed-calibration/1")
        XCTAssertEqual(cal.data, try Data(contentsOf: model.folder.directory.appendingPathComponent("calibration.json")))
        XCTAssertEqual(cal.sha256, model.folder.manifest.file(local: "calibration.json")?.localSHA256)
        XCTAssertEqual(cal.threshold(context: "c16_l64", class: "cons_sub", preset: "strict"), 2.75)
        XCTAssertEqual(cal.status(context: "c16_l64", class: "insertion"), "off")
        XCTAssertEqual(cal.fusionWeight(context: "c16_l64", class: "cons_sub"), 0.5)
        XCTAssertEqual(cal.fusionWeight(context: "c16_l64", class: "vowel_sub"), 0.8, "a class without its own weight takes the default")
        XCTAssertEqual(cal.number("contexts", "c16_l64", "qalqalah", "tau"), 0.2556)
        XCTAssertFalse(model.sampleClips.isEmpty)
        XCTAssertTrue(model.sampleClips.allSatisfy { $0.durationMs > 500 && !$0.name.isEmpty })
        let b = await model.backend
        XCTAssertEqual(b.kind, .cpu)
        await model.close()
        let closed = await code { _ = try await model.session() }
        XCTAssertEqual(closed, "model_missing")
    }

    /// The reference table is data the app asks for: not downloaded with the model; once it is in the folder and
    /// verifies against the signed manifest, a lookup gives an ayah's units and where its words start, read by the
    /// engine (`zf_tajweed_reference_*`).
    func testTheReferenceTable() async throws {
        let model = try await model()
        XCTAssertEqual(model.version, "4.0.0")
        XCTAssertEqual(model.build.count, 40)
        let reference = try XCTUnwrap(model.reference)
        XCTAssertFalse(reference.isDownloaded, "not part of the model's download")
        XCTAssertThrowsError(try reference.units(surah: 1, ayah: 1)) { XCTAssertEqual(($0 as? TajweedError)?.code, "reference_missing") }
        let noSource = await code { try await reference.fetch() }
        XCTAssertEqual(noSource, "reference_missing", "no Client to download it with")
        // a file that does not verify is not taken
        let file = model.folder.directory.appendingPathComponent("expected_tj3.zfx")
        try Data("not the table".utf8).write(to: file)
        let wrong = await code { try await reference.fetch() }
        XCTAssertEqual(wrong, "reference_missing")
        XCTAssertFalse(reference.isDownloaded)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: Fixtures.v4mini().appendingPathComponent("decoded/expected_tj3.zfx"), to: file)
        try await reference.fetch()
        XCTAssertTrue(reference.isDownloaded)
        XCTAssertTrue(try XCTUnwrap(model.reference).isDownloaded, "the Model keeps one table")
        // the fixture's table (scripts/make_test_folder_v4.py reference_table): surah 1 with 7 ayahs, surah 2 with 3;
        // ayah number a of the table has 5 + a % 4 units, a word bar (id 1) after every third
        func expected(_ a: Int) -> (units: [Int], starts: [Int]) {
            let n = 5 + a % 4
            var units: [Int] = [], starts: [Int] = [0]
            for i in 0..<n {
                units.append(2 + (a * 7 + i * 3) % 35)
                if i % 3 == 2 && i != n - 1 {
                    units.append(1)
                    starts.append(units.count)
                }
            }
            return (units, starts)
        }
        var a = 0
        for (surah, count) in [(1, 7), (2, 3)] {
            for ayah in 1...count {
                let got = try reference.units(surah: surah, ayah: ayah)
                XCTAssertEqual(got.units, expected(a).units, "\(surah):\(ayah)")
                XCTAssertEqual(got.wordStarts, expected(a).starts, "\(surah):\(ayah)")
                a += 1
            }
        }
        for (surah, ayah) in [(1, 8), (1, 0), (3, 1), (0, 1), (2, 4), (115, 1)] {
            XCTAssertThrowsError(try reference.units(surah: surah, ayah: ayah), "\(surah):\(ayah)") {
                XCTAssertEqual(($0 as? TajweedError)?.code, "invalid_argument")
            }
        }
    }
}

/// SDK 3.0.0: one Client per process.
final class ClientTests: XCTestCase {
    func options(_ storage: URL = Fixtures.storage()) -> QuranLab.Options {
        QuranLab.Options(modelSource: [], analytics: .off, storageDirectory: storage, cloud: nil)
    }

    func testASecondClientIsClientExistsUntilTheFirstIsClosed() throws {
        let first = try TajweedClient(key: nil, configuration: options(), cloud: nil)
        XCTAssertThrowsError(try TajweedClient(key: nil, configuration: options(), cloud: nil)) {
            XCTAssertEqual(($0 as? TajweedError)?.code, "client_exists")
        }
        XCTAssertThrowsError(try TajweedClient(key: "qlk_v1_another")) { XCTAssertEqual(($0 as? TajweedError)?.code, "client_exists") }
        first.close()
        first.close()
        let second = try TajweedClient(key: nil, configuration: options(), cloud: nil)
        second.close()
    }

    func testAClientThatIsDroppedFreesItsPlace() throws {
        do { _ = try TajweedClient(key: nil, configuration: options(), cloud: nil) }
        let next = try TajweedClient(key: nil, configuration: options(), cloud: nil)
        next.close()
    }

    func testAnEmptyKeyIsRefused() {
        XCTAssertThrowsError(try TajweedClient(key: "  ")) { XCTAssertEqual(($0 as? TajweedError)?.code, "invalid_argument") }
    }

    /// The 2.x defect: configuring twice left two outboxes on one storage, each sending the same recording. A closed
    /// Client's outbox runs no pass, and the next Client's is the only one.
    func testAClosedClientsOutboxSendsNothing() async throws {
        let storage = CloudFixtures.storage()
        StubProtocol.reset { _ in .down }
        let first = try TajweedClient(key: CloudFixtures.key, configuration: CloudFixtures.options(storage: storage),
                                      cloud: { CloudFixtures.cloud(storage: $0) })
        let old = try XCTUnwrap(QuranLab.cloud)
        XCTAssertEqual(old.storage.path, storage.path)
        first.close()
        XCTAssertNil(QuranLab.cloud)
        XCTAssertTrue(old.isStopped, "no network call of the closed Client's server client")
        await old.outbox.drain(ignoringBackoff: true)
        XCTAssertTrue(old.outbox.isClosed)
        let second = try TajweedClient(key: CloudFixtures.key, configuration: CloudFixtures.options(storage: storage),
                                       cloud: { CloudFixtures.cloud(storage: $0) })
        let new = try XCTUnwrap(QuranLab.cloud)
        XCTAssertFalse(new === old)
        XCTAssertFalse(new.outbox.isClosed)
        second.close()
    }

    func testStorageAndRemoveModels() throws {
        let storage = Fixtures.storage()
        let client = try TajweedClient(key: nil, configuration: options(storage), cloud: nil)
        defer { client.close() }
        let fm = FileManager.default
        // one build of a model version: a folder with its signed manifest
        let model = storage.appendingPathComponent("models/v4.0/rev-a")
        try fm.createDirectory(at: model, withIntermediateDirectories: true)
        let manifest = try Data(contentsOf: Fixtures.v4mini().appendingPathComponent("server/manifest.json"))
        try manifest.write(to: model.appendingPathComponent("manifest.json"))
        try Data(count: 1000).write(to: model.appendingPathComponent("layers.zfw"))
        // a folder that is no 3.0 build (no manifest) is not listed
        let stray = storage.appendingPathComponent("models/v4.0/rev-old")
        try fm.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data(count: 50).write(to: stray.appendingPathComponent("layers.zfw"))
        let outbox = storage.appendingPathComponent("outbox/abc")
        try fm.createDirectory(at: outbox, withIntermediateDirectories: true)
        try Data(count: 300).write(to: outbox.appendingPathComponent("seg-00001.opus"))
        let consent = storage.appendingPathComponent("cloud/sharing-state.json")
        try fm.createDirectory(at: consent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: consent)
        let build = String(Manifest30VectorTests.sha256(manifest).prefix(40))
        XCTAssertEqual(client.storage, TajweedDiagnosis.Storage(
            models: [TajweedDiagnosis.StoredModel(version: "4.0.0", build: build, bytes: Int64(1000 + manifest.count))], sharingQueueBytes: 300))
        try client.removeModels()
        XCTAssertEqual(client.storage, TajweedDiagnosis.Storage(models: [], sharingQueueBytes: 300))
        XCTAssertTrue(fm.fileExists(atPath: consent.path), "the consent state stays")
        XCTAssertTrue(fm.fileExists(atPath: outbox.appendingPathComponent("seg-00001.opus").path), "the sharing queue stays")
    }

    func testAFirstRunWithoutANetworkNeedsAConnection() async throws {
        let storage = CloudFixtures.storage()
        StubProtocol.reset { _ in .down }
        let client = try TajweedClient(key: CloudFixtures.key, configuration: CloudFixtures.options(storage: storage),
                                       cloud: { CloudFixtures.cloud(storage: $0) })
        defer { client.close() }
        do throws(TajweedError) {
            _ = try await client.model()
            XCTFail("no model without a network")
        } catch {
            XCTAssertEqual(error.code, "needs_connection")
        }
        let d = await client.diagnose()
        XCTAssertEqual(d.lastError, "needs_connection")
        XCTAssertEqual(d.config, "none")
        XCTAssertNil(d.model)
        XCTAssertEqual(d.sdkVersion, "3.0.0")
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(d.json.utf8)) as? [String: Any])
    }

    func testReportChecksRefusesWhatTheServerWould() throws {
        let client = try TajweedClient(key: nil, configuration: options(), cloud: nil)
        defer { client.close() }
        try client.analytics.reportChecks(rule: "vowel_sub", checked: 31, flagged: 1)
        try client.analytics.reportChecks(rule: "madd", checked: 0, flagged: 0)
        let bad: [(String, Int, Int)] = [("Vowel", 1, 0), ("", 1, 0), ("9rule", 1, 0), ("a-b", 1, 0), (String(repeating: "a", count: 25), 1, 0),
                                         ("madd", 1, 2), ("madd", -1, 0), ("madd", 5, -1), ("madd", 100_001, 0)]
        for (rule, checked, flagged) in bad {
            XCTAssertThrowsError(try client.analytics.reportChecks(rule: rule, checked: checked, flagged: flagged), "\(rule) \(checked) \(flagged)") {
                XCTAssertEqual(($0 as? TajweedError)?.code, "invalid_argument")
            }
        }
    }
}
