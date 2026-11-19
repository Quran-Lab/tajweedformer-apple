import Foundation
import XCTest
@testable import TajweedFormer

/// The bounds of a take (NAMING.md "Bounds", SDK 3.0.0): a take holds at most 20 minutes of audio and then ends by
/// itself; at most 256 chunks and 64 events wait for the app, the oldest waiting one is dropped, never the last
/// chunk or `ended`; a microphone stream nobody reads does not grow. Each test fails when its bound is removed, uses
/// a fixed number of pushes with small bounds, and reads its streams with a time limit.
final class TakeBoundsTests: XCTestCase {
    struct TimedOut: Error {
        let what: String
    }

    /// Everything a stream gives until it ends; an error when it has not ended after `seconds`.
    static func collect<T: Sendable>(_ stream: AsyncStream<T>, within seconds: Double) async throws -> [T] {
        try await withThrowingTaskGroup(of: [T]?.self) { group in
            group.addTask {
                var out: [T] = []
                for await x in stream { out.append(x) }
                return out
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let items = first else {
                throw TimedOut(what: "the stream did not end within \(seconds) s")
            }
            return items
        }
    }

    override func setUp() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { _ in FakeCPUEngine() } }
        Fixtures.configure()
        TakeBounds.droppedChunks.withLock { $0 = 0 }
    }

    override func tearDown() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = nil }
    }

    /// The bundled test folder's CPU set over the stand-in engine.
    func folder() async throws -> ModelFolder {
        let server = try Fixtures.v4mini().appendingPathComponent("server")
        let m = try ModelManifest.read(server)
        let dir = Fixtures.storage().appendingPathComponent("model")
        _ = try await ModelInstaller(source: DirectoryFileSource(root: server))
            .install(m, profile: DownloadProfile(context: "c16_l64", coreML: false), into: dir)
        return try ModelFolder.open(directory: dir, verifier: ManifestVerifier(trustedKeys: [try Fixtures.v4miniKey()], requireSignature: true))
    }

    func model(_ bounds: TakeBounds) async throws -> TajweedModel {
        let model = TajweedModel(try await folder(), client: nil)
        model.setBounds(bounds)
        return model
    }

    func testTheNumbers() {
        XCTAssertEqual(TakeBounds.standard, TakeBounds(takeSeconds: 1200, waitingChunks: 256, waitingEvents: 64))
        XCTAssertEqual(Microphone.waitingBuffers, 256)
    }

    // MARK: chunks and events

    /// An app that never reads `chunks` while the take runs: only the newest wait, the last one is the take's final
    /// chunk, the take's Heads are whole, and the dropped ones are counted.
    func testAtMostTheBoundOfChunksWaitAndTheOldestAreDropped() async throws {
        let model = try await model(TakeBounds(takeSeconds: 1200, waitingChunks: 4, waitingEvents: 64))
        let session = try await model.session()
        let audio = fakeRecitation(seconds: 4)
        var at = 0
        while at < audio.count {
            try session.push(Array(audio[at..<min(audio.count, at + 1600)]))
            at += 1600
        }
        let heads = try await session.finish()
        let chunks = try await Self.collect(session.chunks, within: 30)
        XCTAssertEqual(chunks.count, 4, "the bound")
        let last = try XCTUnwrap(chunks.last)
        XCTAssertTrue(last.decoded.isFinal, "the last chunk is never the one dropped")
        let total = last.index + 1
        XCTAssertGreaterThan(total, 10)
        XCTAssertEqual(chunks.map(\.index), Array((total - 4)..<total), "the newest four")
        XCTAssertEqual(TakeBounds.droppedChunks.withLock { $0 }, total - 4)
        // nothing the app needs went with them: the decoded layer is cumulative and the take's Heads are whole
        XCTAssertEqual(last.decoded.frames.count, 8 * total)
        XCTAssertEqual(heads["log_probs"]?.frames, 8 * total)
    }

    /// The count of dropped chunks is in the diagnosis, from when the Client was made.
    func testDroppedChunksAreInTheDiagnosis() async throws {
        TakeBounds.droppedChunks.withLock { $0 = 7 }
        let client = try TajweedClient(key: nil, configuration: QuranLab.Options(modelSource: [], analytics: .off,
                                                                                 storageDirectory: Fixtures.storage(), cloud: nil), cloud: nil)
        defer { client.close() }
        let fresh = await client.diagnose()
        XCTAssertEqual(fresh.droppedChunks, 0, "counted since the Client was made")
        TakeBounds.droppedChunks.withLock { $0 = 5 }
        let later = await client.diagnose()
        XCTAssertEqual(later.droppedChunks, 5)
        XCTAssertNil(DiagnosisTests.problem(try DiagnosisTests.report(later)))
    }

    /// Events nobody reads: only the newest wait, and `ended` is among them.
    func testAtMostTheBoundOfEventsWaitAndEndedIsKept() async throws {
        let model = try await model(TakeBounds(takeSeconds: 1200, waitingChunks: 256, waitingEvents: 3))
        let mic = FakeMicrophone()
        let session = try await model.listen(options: .init(), device: mic)
        mic.speak(fakeRecitation(seconds: 1), rate: 16_000)
        for _ in 0..<20 { mic.send(.routeChanged) }
        mic.send(.background)
        // the take has ended and every event was handed out before anything reads them
        _ = try await session.finish()
        let events = try await Self.collect(session.events, within: 30)
        XCTAssertEqual(events.count, 3, "the bound")
        XCTAssertEqual(events.last, .ended(.background))
        XCTAssertEqual(events.first, .interrupted(.routeChange))
    }

    // MARK: the take's limit

    /// The limit is counted in input samples, at whatever rate they come.
    func testTheLimitIsCountedInInputSamples() {
        let s = SessionShared(backend: .cpu, takeSeconds: 1200)
        XCTAssertEqual(s.admit(19_199_999, rate: 16_000)?.count, 19_199_999)
        let a = s.admit(5, rate: 16_000)
        XCTAssertEqual(a?.count, 1, "the sample that fills 20 minutes at 16 kHz")
        XCTAssertEqual(a?.full, true)
        XCTAssertNil(s.admit(1, rate: 16_000), "nothing after it")
        let exact = SessionShared(backend: .cpu, takeSeconds: 1200)
        let whole = exact.admit(57_600_000 + 1, rate: 48_000)
        XCTAssertEqual(whole?.count, 57_600_000)
        XCTAssertEqual(whole?.full, true)
        // an input device that changed its rate: each part counts by its duration
        let t = SessionShared(backend: .cpu, takeSeconds: 1)
        XCTAssertEqual(t.admit(8_000, rate: 16_000)?.full, false)
        let b = t.admit(48_000, rate: 48_000)
        XCTAssertEqual(b?.count, 24_000)
        XCTAssertEqual(b?.full, true)
    }

    /// A pushed take: the audio up to the limit is decoded, the take ends with `ended(limit)` and a final chunk,
    /// its Heads are kept, and a later push is `session_closed`.
    func testAPushedTakeEndsByItselfAtItsLimit() async throws {
        let model = try await model(TakeBounds(takeSeconds: 2, waitingChunks: 256, waitingEvents: 64))
        let session = try await model.session()
        let audio = fakeRecitation(seconds: 1.5)
        try session.push(audio)
        try session.push(audio)   // its first 0.5 s fill the take
        XCTAssertThrowsError(try session.push(audio)) { XCTAssertEqual(($0 as? TajweedError)?.code, "session_closed") }
        let events = try await Self.collect(session.events, within: 30)
        XCTAssertEqual(events.last, .ended(.limit))
        let chunks = try await Self.collect(session.chunks, within: 30)
        let last = try XCTUnwrap(chunks.last)
        XCTAssertTrue(last.decoded.isFinal)
        // 2 s went in, not the 4.5 s that were pushed (the stand-in engine's flush adds at most a second)
        XCTAssertGreaterThan(last.endMs, 1_600)
        XCTAssertLessThan(last.endMs, 3_400)
        let heads = try await session.finish()
        XCTAssertEqual(heads["log_probs"]?.frames, 8 * chunks.count, "all its Heads are kept")
        XCTAssertThrowsError(try session.push(audio)) { XCTAssertEqual(($0 as? TajweedError)?.code, "session_closed") }
        // the Model is free for the next take
        let next = try await model.session()
        await next.cancel()
    }

    /// A `listen` take stops the microphone at the limit.
    func testAListenTakeStopsTheMicrophoneAtItsLimit() async throws {
        let model = try await model(TakeBounds(takeSeconds: 1, waitingChunks: 256, waitingEvents: 64))
        let mic = FakeMicrophone()
        let session = try await model.listen(options: .init(), device: mic)
        mic.speak(fakeRecitation(seconds: 3), rate: 16_000)
        let events = try await Self.collect(session.events, within: 30)
        XCTAssertEqual(events.last, .ended(.limit))
        XCTAssertFalse(mic.isOpen, "nothing is captured after the take ended")
        XCTAssertEqual(mic.closed, 1)
        let chunks = try await Self.collect(session.chunks, within: 30)
        XCTAssertLessThan(try XCTUnwrap(chunks.last).endMs, 2_400, "1 s went in, not 3")
        _ = try await session.finish()
    }

    // MARK: other streams

    /// `Microphone.samples()`: buffers nobody reads do not pile up.
    func testAMicrophoneStreamNobodyReadsKeepsTheNewestBuffers() async throws {
        let (stream, c) = Microphone.stream()
        let n = Microphone.waitingBuffers + 50
        for i in 0..<n { c.yield([Float(i)]) }
        c.finish()
        let got = try await Self.collect(stream, within: 30)
        XCTAssertEqual(got.count, Microphone.waitingBuffers)
        XCTAssertEqual(got.first, [50])
        XCTAssertEqual(got.last, [Float(n - 1)])
    }

    /// The recognizer's own chunk stream keeps at most `chunkBuffer` unread chunks.
    func testTheRecognizersChunkStreamIsBounded() async throws {
        let r = try TajweedRecognizer(model: try await folder(), backend: .exact)
        try await r.startTake()
        let stream = await r.chunks()
        // 15 s in 15 pushes: more chunks than the stream keeps
        for i in 0..<15 { try await r.append(fakeRecitation(seconds: 1, seed: i)) }
        _ = try await r.finish()
        let chunks = try await Self.collect(stream, within: 30)
        XCTAssertEqual(chunks.count, TajweedRecognizer.chunkBuffer)
        XCTAssertGreaterThan(try XCTUnwrap(chunks.last).index + 1, TajweedRecognizer.chunkBuffer, "the take had more")
    }
}
