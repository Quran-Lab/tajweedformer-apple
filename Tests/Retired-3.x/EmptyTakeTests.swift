import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 3.1.1: a take that ends before one sample of audio was pushed (or captured, with `listen`), cancelled or
/// finished, is not a session: it records nothing in the telemetry (no session, no aborted take, no duration, no
/// backend) and it is not a finished session for the sharing ask. An app that opens a session with its options and
/// cancels it at once, to have the recognizer for them made and warm before the learner starts, adds nothing to its
/// daily statistics. A take with audio is counted as before.
final class EmptyTakeTests: XCTestCase {
    final class Sink: AnalyticsSink, @unchecked Sendable {
        let events = Locked<[AnalyticsEvent]>([])
        func record(_ event: AnalyticsEvent) { events.withLock { $0.append(event) } }

        /// The takes the telemetry recorded: finished ones (counted or aborted) and ones a kill left open.
        var takes: [SessionTelemetry] {
            events.withLock { all in
                all.compactMap { e -> SessionTelemetry? in
                    if case .sessionFinished(let t) = e { return t }
                    return nil
                }
            }
        }

        var abortedAtLaunch: Int {
            events.withLock { all in
                all.filter { e in
                    if case .sessionAborted = e { return true }
                    return false
                }.count
            }
        }
    }

    let sink = Sink()

    override func setUp() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { _ in FakeCPUEngine() } }
        QuranLab.configure(options: .init(modelSource: [], analytics: .on, analyticsSink: sink, storageDirectory: Fixtures.storage(), cloud: nil))
    }

    override func tearDown() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = nil }
        Fixtures.configure()
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

    /// Opened and cancelled at once: no session, no aborted take, and the sharing ask did not count it.
    func testAnEmptyCancelledTakeRecordsNothing() async throws {
        let model = try await model()
        let asked = Contributions.state().sessions
        let session = try await model.session()
        await session.cancel()
        let again = try await model.session(options: .init(pace: .fast))
        await again.cancel()
        XCTAssertEqual(sink.takes.count, 0, "an empty cancelled take is not a session")
        XCTAssertEqual(sink.abortedAtLaunch, 0)
        XCTAssertEqual(Contributions.state().sessions, asked, "not a finished session for the sharing ask")
    }

    /// Opened and finished without audio: its Heads come back as before, and nothing is recorded.
    func testAnEmptyFinishedTakeRecordsNothing() async throws {
        let model = try await model()
        let asked = Contributions.state().sessions
        let session = try await model.session()
        _ = try await session.finish()
        XCTAssertEqual(sink.takes.count, 0, "an empty finished take is not a session")
        XCTAssertEqual(Contributions.state().sessions, asked, "not a finished session for the sharing ask")
        // an empty buffer is not audio either
        let empty = try await model.session()
        try empty.push([])
        _ = try await empty.finish()
        XCTAssertEqual(sink.takes.count, 0, "a take of empty buffers is not a session")
    }

    /// A listen take whose microphone gave nothing before it was cancelled or finished: nothing is recorded.
    func testAnEmptyListenTakeRecordsNothing() async throws {
        let model = try await model()
        let mic = FakeMicrophone()
        let session = try await model.listen(options: .init(), device: mic)
        await session.cancel()
        let other = try await model.listen(options: .init(), device: FakeMicrophone())
        _ = try? await other.finish()
        XCTAssertEqual(sink.takes.count, 0, "nothing was captured")
    }

    /// One buffer of audio, then cancelled: counted as before, a session and an aborted take. A finished take with
    /// audio is a counted session.
    func testATakeWithAudioIsCountedAsBefore() async throws {
        let model = try await model()
        let session = try await model.session()
        try session.push(fakeRecitation(seconds: 1))
        // the recognizer has taken the buffer once a chunk of it is out
        var chunks = session.chunks.makeAsyncIterator()
        _ = await chunks.next()
        await session.cancel()
        XCTAssertEqual(sink.takes.count, 1, "the cancelled take with audio is a session")
        XCTAssertEqual(sink.takes.first?.counts, false, "and an aborted one")
        let finished = try await model.session()
        try finished.push(fakeRecitation(seconds: 1))
        _ = try await finished.finish()
        XCTAssertEqual(sink.takes.count, 2)
        XCTAssertEqual(sink.takes.last?.counts, true, "a finished take with audio counts")
        XCTAssertGreaterThan(sink.takes.last?.audioMs ?? 0, 0)
    }
}
