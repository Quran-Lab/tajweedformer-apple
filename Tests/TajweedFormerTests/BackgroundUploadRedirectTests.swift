import Foundation
import XCTest
@testable import TajweedFormer

/// The background upload session and a redirect (SPEC 15.4, the second exception; 3.1.3). On that one path the
/// system follows a redirect without asking the SDK, so the rule is applied after the fact: a finished upload that
/// the system redirected (its answer is not from the scheme, host and port of the signed URL it was made to, or the
/// system counted a redirect) counts as NOT uploaded, and the host it ended on is reported.
///
/// Three kinds of test:
/// - a REAL background session of the SDK's uploader on the test's Mac, against two servers on the loopback
///   interface (what the system does there, and that the uploader tells a redirected upload from an upload);
/// - the upload queue's own part, over the suite's stub network: the segment stays, gets a fresh URL and is sent
///   again, and the report carries the host only. There the redirect is the test saying so (the call the uploader
///   makes), because the stub cannot carry a background session;
/// - what counts as redirected, by itself.
/// Not shown: an app that is suspended while the upload runs, a relaunch, a cellular network, a phone.
final class BackgroundUploadRedirectTests: XCTestCase {
    override func tearDown() {
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// What a real background session delivered for the uploads of one test.
    final class Delivered: Sendable {
        let puts = Locked<[String]>([])
        let redirects = Locked<[String]>([])

        var sink: BackgroundUploader.Sink {
            BackgroundUploader.Sink(put: { [self] _, name, result in
                switch result {
                case .success(let answer): puts.withLock { $0.append("\(name): HTTP \(answer.status)") }
                case .failure(let error): puts.withLock { $0.append("\(name): no answer (\(error))") }
                }
            }, redirected: { [self] _, name, host in
                redirects.withLock { $0.append("\(name): \(host)") }
            })
        }

        var count: Int { puts.withLock { $0.count } + redirects.withLock { $0.count } }
    }

    /// One segment's PUT from a file on a real background session of the SDK's uploader; what was delivered.
    func upload(to url: URL, name: String) async throws -> Delivered {
        let uploader = BackgroundUploader.shared(identifier: "ai.quranlab.contributions.test." + UUID().uuidString)
        let delivered = Delivered()
        uploader.attach(delivered.sink)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("background-upload-\(UUID().uuidString).opus")
        let body = Data((0..<3000).map { UInt8($0 % 251) })
        try body.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let request = ContributionClient.putRequest(.init(n: 1, url: url, expiresAt: Date().addingTimeInterval(3600)),
                                                    contentType: "audio/ogg", bytes: Int64(body.count))
        uploader.start(request, file: file, key: "recording/\(name)")
        let end = Date().addingTimeInterval(45)
        while delivered.count == 0, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        return delivered
    }

    /// The control: a real background session uploads a segment to the host of its URL, and the uploader hands the
    /// answer on as an upload.
    func testARealBackgroundSessionUploadsASegment() async throws {
        let server = try LoopbackServer()
        guard await server.start() else { throw XCTSkip("the loopback server did not start") }
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/recordings/test/seg-000001.opus"))
        let delivered = try await upload(to: url, name: "seg-000001.opus")
        XCTAssertEqual(delivered.puts.withLock { $0 }, ["seg-000001.opus: HTTP 200"])
        XCTAssertEqual(delivered.redirects.withLock { $0 }, [])
        let got = server.got.withLock { $0 }
        XCTAssertEqual(got.map { $0.method }, ["PUT"])
        XCTAssertEqual(got.first?.bodyBytes, 3000, "the segment's bytes arrived")
        XCTAssertFalse(got.first?.headerNames.contains("x-qlab-key") ?? true, "the upload carries no key")
        XCTAssertFalse(got.first?.headerNames.contains("authorization") ?? true, "and no token")
    }

    /// The signed URL's host answers a redirect to another host. The system follows it by itself (the uploader's
    /// delegate is not asked), and the other host takes the PUT. The uploader does not hand that on as an upload:
    /// it reports the host the upload ended on, the host only.
    /// The line "REDIRECT-MEASURE:" says what the system did, per status: whether the second host was asked, and
    /// the method, the body's size and the header names of what reached it.
    func testARealBackgroundUploadTheSystemRedirectedIsNotAnUpload() async throws {
        for status in [307, 302] {
            let pair = try await RedirectTests.pair(status)
            defer { pair.stop() }
            let name = "seg-\(status).opus"
            let delivered = try await upload(to: pair.base.appendingPathComponent("recordings/test/\(name)"), name: name)
            let second = pair.second.got.withLock { $0 }
            let reached = second.map { "[\($0.method), body \($0.bodyBytes) bytes, header names: \($0.headerNames.joined(separator: ", "))]" }
            let puts = delivered.puts.withLock { $0 }, redirects = delivered.redirects.withLock { $0 }
            print("REDIRECT-MEASURE: a background upload, HTTP \(status): the second host was asked \(second.count) time(s) \(reached.joined(separator: " ")); "
                + "delivered as an upload: \(puts); delivered as redirected: \(redirects)")
            XCTAssertEqual(delivered.count, 1, "HTTP \(status): the upload task ended, once")
            XCTAssertFalse(puts.contains { $0.hasSuffix("HTTP 200") }, "HTTP \(status): what another host answered is not an upload")
            if !second.isEmpty {
                // the system followed: the uploader says so, with the host and nothing else
                XCTAssertEqual(redirects, ["\(name): localhost"], "HTTP \(status)")
                XCTAssertEqual(puts, [], "HTTP \(status)")
            }
        }
    }

    /// What counts as redirected: a redirect the system counted, or an answer from another scheme, host or port
    /// than the task was made to. The host is compared without case, and what is reported is the host only.
    func testWhatCountsAsARedirectedUpload() throws {
        func url(_ s: String) throws -> URL { try XCTUnwrap(URL(string: s)) }
        let asked = try url("https://storage.example/bucket/v1/a/seg-000001.opus?X-Amz-Signature=abc")
        let same = try url("https://STORAGE.example:443/bucket/v1/a/seg-000001.opus")
        let other = try url("https://Other.Example/secret/path?token=1")
        let otherPort = try url("https://storage.example:8443/x")
        let otherScheme = try url("http://storage.example/x")
        XCTAssertNil(BackgroundUploader.redirectedHost(asked: asked, final: asked))
        XCTAssertNil(BackgroundUploader.redirectedHost(asked: asked, final: same), "the same host in other letters, the same port written out")
        XCTAssertEqual(BackgroundUploader.redirectedHost(asked: asked, final: other), "other.example",
                       "another host: the host, in lower case, and nothing else of the address")
        XCTAssertEqual(BackgroundUploader.redirectedHost(asked: asked, final: otherPort), "storage.example", "the same host, another port")
        XCTAssertEqual(BackgroundUploader.redirectedHost(asked: asked, final: otherScheme), "storage.example", "the same host, another scheme")
        XCTAssertEqual(BackgroundUploader.redirectedHost(asked: asked, final: asked, redirects: 1), "storage.example",
                       "the system counted a redirect, and it ended on the same address")
        XCTAssertEqual(BackgroundUploader.redirectedHost(asked: asked, final: nil, redirects: 2), "unknown")
        XCTAssertNil(BackgroundUploader.redirectedHost(asked: asked, final: nil), "no answer and no redirect counted: nothing to say")
        XCTAssertNil(BackgroundUploader.redirectedHost(asked: nil, final: asked))
    }

    // MARK: the upload queue's part, over the stub network

    func launch(storage: URL) async -> QuranLabCloud {
        let options = CloudFixtures.options(contributions: true, storage: storage)
        let cloud = CloudFixtures.cloud(storage: storage, options: options)
        _ = await cloud.refreshConfig()
        QuranLab.configure(key: CloudFixtures.key, options: options, cloud: cloud)
        return cloud
    }

    /// A recording of 1 s that has ended; its id.
    func record() throws -> String {
        let capture = try XCTUnwrap(Contributions.capture(revision: "test-rev", backend: .exact, weightsSHA256: nil), "sharing is on")
        for i in 0..<10 { try capture.append(SharingTests.audio(4800, seed: i + 1), rate: 48_000) }
        capture.finish(completed: true)
        return capture.id
    }

    func until(_ seconds: TimeInterval, _ done: @Sendable () async -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if await done() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await done()
    }

    /// A segment whose background upload ended on another host: it is not marked sent and its file stays; the
    /// report is the issue `other`, `upload_redirected:<host>`, the host only; the next pass asks the API for a
    /// fresh URL for that segment and sends it again, and then the recording is uploaded.
    /// The redirect here is the call the uploader makes when a task ended on another host (the real session's
    /// part is the test above); the segment's first upload is made to fail by the stub, so that the recording is
    /// waiting with its URL in hand.
    func testASegmentTheSystemRedirectedStaysUnsentGetsAFreshURLAndIsReportedByItsHost() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        server.put.withLock { $0 = { n in n == 1 ? StubProtocol.Reply(status: 500) : nil } }
        let cloud = await launch(storage: CloudFixtures.storage())
        Contributions.answer(share: true)
        let id = try record()
        let outbox = cloud.outbox
        let tried = await until(15) { SharingTests.puts.count == 1 }
        XCTAssertTrue(tried, "the first upload of the segment was tried")
        let name = try XCTUnwrap(SharingTests.puts.first?.url.lastPathComponent)
        XCTAssertEqual(SharingTests.urlCalls(id), [], "its URL came with the start's answer")
        // what the background uploader calls when the task's answer came from another host
        await outbox.redirected(id, name, to: "elsewhere.example")
        let item = await outbox.item(id)
        XCTAssertEqual(item?.status, .queued, "not uploaded")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outbox.root.appendingPathComponent(id).appendingPathComponent(name).path),
                      "the segment's file stays")
        XCTAssertEqual(server.segments(id).count, 0, "the server holds nothing of it")
        let issues = cloud.issues.pending.filter { $0.code.hasPrefix("upload_redirected") }
        XCTAssertEqual(issues.map { $0.kind }, ["other"])
        XCTAssertEqual(issues.map { $0.code }, ["upload_redirected:elsewhere.example"], "the host, and nothing else of the address")
        // the next pass: a fresh URL for that segment, and the segment goes
        await outbox.drain(ignoringBackoff: true)
        let up = await until(10) { await outbox.item(id)?.status == .uploaded }
        XCTAssertTrue(up, "sent again by the queue's ordinary rule")
        XCTAssertEqual(SharingTests.urlCalls(id).first, 1, "a fresh URL was asked for, from that segment on")
        XCTAssertEqual(SharingTests.signature(try XCTUnwrap(SharingTests.puts.last))?.hasPrefix("b2-"), true, "and the upload went to the fresh URL")
        XCTAssertEqual(server.segments(id).count, 1)
    }
}
