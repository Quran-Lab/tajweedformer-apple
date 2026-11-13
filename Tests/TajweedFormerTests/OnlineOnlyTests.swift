import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// A model comes only from Quran Lab's server, through the Client (SDK 3.1.0, SPEC section 15). Through the public
/// Client over a stub API and CDN that serve the bundled test folder:
/// - the install record (15.2): a storage filled in advance exactly as a real download leaves it is not opened and
///   is replaced by a download, also with a record made on another device or for another build; a real download
///   then a relaunch opens with no request for a file, also without a network; an interrupted download resumes,
///   and the same folder without this device's record does not; the key store's two failure modes; the record is
///   written before the first file is asked for; an install that updates from an earlier SDK downloads once more;
/// - a model request (15.4): the exact headers of the manifest request and of a file's Range request, the token in
///   hand before the first of them, attested where App Attest is supported, the renewal on 401 `invalid_token`, no
///   redirect followed;
/// - the model gate (15.3): every case of the shared vector `model_gate.json`, with a model from a real download on
///   the device and without one; a relaunch without a network after a refusal stays stopped, and an accepting
///   answer clears it;
/// - no public declaration takes a model.
/// The device's key store is a stand-in in every test: none touches a real Keychain.
final class OnlineOnlyTests: XCTestCase {
    let fm = FileManager.default

    override func setUp() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { _ in FakeCPUEngine() } }
    }

    override func tearDown() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = nil }
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    // MARK: the stub and a launch

    static let token = "qlt_v1.eyJ2IjoxfQ.sig"

    static func server() throws -> URL { try Fixtures.v4mini().appendingPathComponent("server") }

    /// The build id of the bundled test folder: the first 40 hex digits of the SHA-256 of its manifest.json.
    static func build() throws -> String {
        String(Manifest30VectorTests.sha256(try Data(contentsOf: server().appendingPathComponent("manifest.json"))).prefix(40))
    }

    /// The path of a model request after the model's folder (`manifest.json`, `layers.zfw.gz`); nil for any other
    /// request.
    static func modelPath(_ s: StubProtocol.Seen) -> String? {
        guard s.url.host == CloudFixtures.cdn.host, let at = s.path.range(of: "/sdk/v4.0/") else { return nil }
        return String(s.path[at.upperBound...])
    }

    /// The answer of a download server that has the test folder.
    static func file(_ path: String) -> StubProtocol.Reply {
        guard let server = try? server(), let data = try? Data(contentsOf: server.appendingPathComponent(path)) else {
            return StubProtocol.Reply(status: 404)
        }
        return StubProtocol.Reply(status: 200, headers: ["content-type": "application/octet-stream"], body: data)
    }

    /// Installs the stub: a healthy API whose signed config names `named` (the test folder's build when nil), and a
    /// CDN that serves the test folder. `cdn` sees every model request first and may answer it itself; `api` the
    /// same for every other request.
    @discardableResult
    static func serve(named: String? = nil,
                      api: @escaping @Sendable (StubProtocol.Seen) -> StubProtocol.Reply? = { _ in nil },
                      cdn: @escaping @Sendable (_ path: String, _ seen: StubProtocol.Seen) -> StubProtocol.Reply? = { _, _ in nil }) throws -> String {
        let build = try build()
        StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(models: ["Quran-Lab/tajweedformer-v4": named ?? build]), extra: { s in
            guard let path = modelPath(s) else { return api(s) }
            return cdn(path, s) ?? file(path)
        }))
        return build
    }

    /// The model requests so far, in order.
    static var modelRequests: [StubProtocol.Seen] { StubProtocol.seen.filter { modelPath($0) != nil } }
    /// Their paths.
    static var fetched: [String] { StubProtocol.seen.compactMap(modelPath) }

    /// `client.model()` of a Client; the build it opened, or the error it threw.
    static func model(_ client: TajweedClient) async -> (build: String?, error: TajweedError?) {
        do throws(TajweedError) {
            let model = try await client.model()
            let build = model.build
            await model.close()
            return (build, nil)
        } catch {
            return (nil, error)
        }
    }

    /// One launch: a new Client on `storage` on the device `keys`, `client.model()`, and the Client closed again.
    func launch(_ storage: URL, keys: MemoryInstallKeyStore = CloudFixtures.installKeys,
                app: AppIdentity = CloudFixtures.app) async throws -> (build: String?, error: TajweedError?) {
        let client = try StubbedModelServer.client(storage: storage, app: app, installKeys: keys)
        let got = await Self.model(client)
        client.close()
        return got
    }

    /// The model's folder in a storage after a download: `models/v4.0/<revision>`.
    func folder(_ storage: URL) throws -> URL {
        let base = storage.appendingPathComponent("models/v4.0")
        let revision = try String(contentsOf: base.appendingPathComponent("current"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return base.appendingPathComponent(revision)
    }

    /// Every regular file under `dir` with its size, sorted: what a folder holds.
    func snapshot(_ dir: URL) -> [String] {
        guard let e = fm.enumerator(atPath: dir.path) else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            let path = dir.appendingPathComponent(rel).path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            out.append("\(rel) \(((try? fm.attributesOfItem(atPath: path))?[.size] as? Int) ?? -1)")
        }
        return out.sorted()
    }

    /// A storage whose `models` folder is a copy of `source`'s: the files and pointer files exactly as a real
    /// download left them, the install record included.
    func copy(of source: URL) throws -> URL {
        let storage = CloudFixtures.storage()
        try fm.copyItem(at: source.appendingPathComponent("models"), to: storage.appendingPathComponent("models"))
        return storage
    }

    // MARK: the install record (15.2)

    /// The record itself: bound to the build, the state and the device key.
    func testTheInstallRecordIsBoundToTheBuildTheStateAndTheDevice() throws {
        let dir = CloudFixtures.storage()
        let manifest = try Data(contentsOf: Self.server().appendingPathComponent("manifest.json"))
        try manifest.write(to: dir.appendingPathComponent("manifest.json"))
        let build = try Self.build()
        XCTAssertEqual(InstallRecord.buildOnDisk(dir), build)
        let device = MemoryInstallKeyStore()
        XCTAssertEqual(InstallRecord.standing(of: dir, build: build, keys: device), .notOwn("this device has no install key"))
        try InstallRecord.write(.downloading, build: build, in: dir, keys: device)
        XCTAssertTrue(device.hasKey, "the key is made at first need")
        XCTAssertEqual(device.creates, 1)
        XCTAssertEqual(InstallRecord.standing(of: dir, build: build, keys: device), .own(.downloading))
        try InstallRecord.write(.installed, build: build, in: dir, keys: device)
        XCTAssertEqual(device.creates, 1, "the same key")
        XCTAssertEqual(InstallRecord.standing(of: dir, build: build, keys: device), .own(.installed))
        // the MAC is HMAC-SHA256(device key, "quranlab-model-install 1\n<build>\n<state>\n"), hex
        let record = try XCTUnwrap(InstallRecord.read(dir))
        XCTAssertEqual(String(decoding: InstallRecord.message(build: build, state: .installed), as: UTF8.self), "quranlab-model-install 1\n\(build)\ninstalled\n")
        guard case .key(let key) = device.load() else { return XCTFail("no key") }
        XCTAssertEqual(key.count, 32)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data("quranlab-model-install 1\n\(build)\ninstalled\n".utf8), using: SymmetricKey(data: key)))
        XCTAssertEqual(record.mac, mac.map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(record.build, build)
        // another device, another build, another state, a changed record
        let other = MemoryInstallKeyStore()
        _ = other.create()
        XCTAssertEqual(InstallRecord.standing(of: dir, build: build, keys: other), .notOwn("the install record was not made on this device"))
        XCTAssertEqual(InstallRecord.standing(of: dir, build: String(repeating: "a", count: 40), keys: device), .notOwn("the install record is of another build"))
        var changed = record
        changed.state = .downloading
        try JSONEncoder().encode(changed).write(to: InstallRecord.url(dir))
        XCTAssertEqual(InstallRecord.standing(of: dir, build: build, keys: device), .notOwn("the install record was not made on this device"),
                       "a record whose state was changed by hand")
        try fm.removeItem(at: InstallRecord.url(dir))
        XCTAssertEqual(InstallRecord.standing(of: dir, build: build, keys: device), .notOwn("the folder has no install record"))
        // a key store that fails is the answer, whatever the folder holds; nothing is written
        device.fail("locked")
        XCTAssertEqual(InstallRecord.standing(of: dir, build: build, keys: device), .keyStoreFailed("locked"))
        XCTAssertThrowsError(try InstallRecord.write(.installed, build: build, in: dir, keys: device)) { e in
            guard case .storageFailed? = e as? RecognizerError else { return XCTFail("\(e)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: InstallRecord.url(dir).path))
        // the record is never a file the manifest lists
        XCTAssertNil(try ModelManifest.parse(manifest).file(local: InstallRecord.fileName))
    }

    /// A storage filled in advance, with the files and pointer files exactly as a real download leaves them: not
    /// opened, deleted, and the build downloaded, every file of it. Three ways to fill it: without a record (a
    /// model shipped in an app, or one an earlier SDK downloaded), with the record of the device it was copied
    /// from, and on a device that has no install key at all.
    func testAStorageFilledInAdvanceIsNotOpenedAndIsReplacedByADownload() async throws {
        let build = try Self.serve()
        let deviceA = MemoryInstallKeyStore()
        let real = CloudFixtures.storage()
        let first = try await launch(real, keys: deviceA)
        XCTAssertEqual(first.build, build, "\(String(describing: first.error))")
        let downloaded = Set(Self.fetched)
        XCTAssertTrue(downloaded.contains("manifest.json"))
        XCTAssertGreaterThan(downloaded.count, 5, "the manifest and the CPU set")
        XCTAssertEqual(InstallRecord.standing(of: try folder(real), build: build, keys: deviceA), .own(.installed), "a real download leaves its record")

        for way in ["no record", "the record of another device", "a device without an install key"] {
            let storage = try copy(of: real)
            let dir = try folder(storage)
            let device = MemoryInstallKeyStore()
            if way == "no record" { try fm.removeItem(at: InstallRecord.url(dir)) }
            if way != "a device without an install key" { _ = device.create() }
            // something only the folder that was put there holds: gone when that folder was deleted, not reused
            let planted = dir.appendingPathComponent("planted.txt")
            try Data("put here in advance".utf8).write(to: planted)
            try Self.serve()
            let got = try await launch(storage, keys: device)
            XCTAssertEqual(got.build, build, "\(way): \(String(describing: got.error))")
            XCTAssertEqual(Set(Self.fetched), downloaded, "\(way): the manifest and every file were downloaded again")
            XCTAssertFalse(fm.fileExists(atPath: planted.path), "\(way): the folder that was put there is gone")
            XCTAssertEqual(InstallRecord.standing(of: try folder(storage), build: build, keys: device), .own(.installed), "\(way): the Client's own now")
            // and from here it is the Client's own: a relaunch asks for no file
            try Self.serve()
            let again = try await launch(storage, keys: device)
            XCTAssertEqual(again.build, build, way)
            XCTAssertEqual(Self.fetched, [], "\(way): a relaunch after the download")
        }
    }

    /// An install that updates from an earlier SDK holds a model without a record: it is not opened and is
    /// downloaded once more. Without a connection at that first launch the call fails with `needs_connection`, and
    /// the next launch with a connection downloads.
    func testAnInstallThatUpdatesFromAnEarlierSDKDownloadsOnceMore() async throws {
        let build = try Self.serve()
        let real = CloudFixtures.storage()
        _ = try await launch(real)
        let storage = try copy(of: real)
        // as SDK 3.0 left it: the same files and pointers, no install record
        try fm.removeItem(at: InstallRecord.url(try folder(storage)))
        StubProtocol.reset { _ in .down }
        let offline = try await launch(storage)
        XCTAssertNil(offline.build, "not opened")
        XCTAssertEqual(offline.error?.code, "needs_connection")
        try Self.serve()
        let online = try await launch(storage)
        XCTAssertEqual(online.build, build)
        XCTAssertTrue(Self.fetched.contains("layers.zfw.gz"), "downloaded once more: \(Self.fetched)")
        try Self.serve()
        let later = try await launch(storage)
        XCTAssertEqual(later.build, build)
        XCTAssertEqual(Self.fetched, [], "once: the next launch asks for nothing")
    }

    /// A record that says `installed` for another build, made with this device's own key, is not valid for the
    /// folder: the folder is replaced by a download.
    func testARecordOfAnotherBuildDoesNotOpenAFolder() async throws {
        let build = try Self.serve()
        let device = MemoryInstallKeyStore()
        let storage = CloudFixtures.storage()
        _ = try await launch(storage, keys: device)
        let dir = try folder(storage)
        try InstallRecord.write(.installed, build: String(repeating: "c", count: 40), in: dir, keys: device)
        XCTAssertEqual(store(storage, device).standing(of: dir), .notOwn("the install record is of another build"))
        try Self.serve()
        let got = try await launch(storage, keys: device)
        XCTAssertEqual(got.build, build)
        XCTAssertTrue(Self.fetched.contains("layers.zfw.gz"), "downloaded again: \(Self.fetched)")
        XCTAssertEqual(InstallRecord.standing(of: try folder(storage), build: build, keys: device), .own(.installed))
    }

    func store(_ storage: URL, _ keys: MemoryInstallKeyStore) -> ModelStore {
        ModelStore(root: storage.appendingPathComponent("models"), verifier: ManifestVerifier(trustedKeys: [], requireSignature: false), installKeys: keys)
    }

    /// A real download, then a relaunch: the model opens with no request for a file, with the download server up
    /// and without any network (a learner without a connection keeps working after a real download).
    func testARealDownloadThenARelaunchOpensWithNoRequestForAFile() async throws {
        let build = try Self.serve()
        let storage = CloudFixtures.storage()
        let first = try await launch(storage)
        XCTAssertEqual(first.build, build)
        XCTAssertFalse(Self.fetched.isEmpty)
        try Self.serve()
        let second = try await launch(storage)
        XCTAssertEqual(second.build, build)
        XCTAssertEqual(Self.fetched, [], "no model request at the relaunch")
        StubProtocol.reset { _ in .down }
        let offline = try await launch(storage)
        XCTAssertEqual(offline.build, build, "without a network: \(String(describing: offline.error))")
    }

    /// An interrupted download resumes: the files it had finished are not asked for again, and a file it had begun
    /// goes on at the byte where it stopped. The same download folder on a device whose record it is not (copied
    /// there) is deleted and everything is asked for from the first byte.
    func testAnInterruptedDownloadResumesAndOneThatIsNotTheClientsDoesNot() async throws {
        let build = try Self.build()
        // the download server loses the weights file: the download stops there
        try Self.serve(cdn: { path, _ in path == "layers.zfw.gz" ? .down : nil })
        let device = MemoryInstallKeyStore()
        let storage = CloudFixtures.storage()
        let stopped = try await launch(storage, keys: device)
        XCTAssertNil(stopped.build)
        let download = storage.appendingPathComponent("models/v4.0/.download-\(build)")
        XCTAssertEqual(InstallRecord.standing(of: download, build: build, keys: device), .own(.downloading), "the record of a download under way")
        let finished = Self.fetched.filter { $0 != "manifest.json" && $0 != "layers.zfw.gz" }
        XCTAssertFalse(finished.isEmpty, "files that were finished before it stopped: \(Self.fetched)")
        // a file the download had begun: its first 100 bytes are there, as a transfer that broke off leaves them
        let stored = try Data(contentsOf: Self.server().appendingPathComponent("layers.zfw.gz"))
        try stored.prefix(100).write(to: download.appendingPathComponent("layers.zfw.gz.part"))
        let foreign = CloudFixtures.storage()
        try fm.copyItem(at: storage.appendingPathComponent("models"), to: foreign.appendingPathComponent("models"))

        try Self.serve()
        let resumed = try await launch(storage, keys: device)
        XCTAssertEqual(resumed.build, build, "\(String(describing: resumed.error))")
        let asked = Self.modelRequests
        for path in finished { XCTAssertFalse(asked.contains { Self.modelPath($0) == path }, "\(path) was finished and is not asked for again") }
        let weights = asked.filter { Self.modelPath($0) == "layers.zfw.gz" }
        XCTAssertEqual(weights.map { $0.headers["range"] }, ["bytes=100-\(stored.count - 1)"], "the file goes on where it stopped")
        XCTAssertEqual(InstallRecord.standing(of: try folder(storage), build: build, keys: device), .own(.installed))

        // the same download folder on another device: not the Client's
        try Self.serve()
        let other = MemoryInstallKeyStore()
        _ = other.create()
        let fresh = try await launch(foreign, keys: other)
        XCTAssertEqual(fresh.build, build, "\(String(describing: fresh.error))")
        let all = Self.modelRequests
        for path in finished { XCTAssertTrue(all.contains { Self.modelPath($0) == path }, "\(path) is downloaded again, not reused") }
        XCTAssertEqual(all.filter { Self.modelPath($0) == "layers.zfw.gz" }.map { $0.headers["range"] }, ["bytes=0-\(stored.count - 1)"],
                       "nothing is resumed: the file is asked for from its first byte")
    }

    /// The key store answers that there is no key (the device lost it, or never had one): no record can be valid,
    /// so the model on the device is deleted, a key is made, and the build is downloaded.
    func testADeviceWithoutItsInstallKeyDownloadsAgain() async throws {
        let build = try Self.serve()
        let device = MemoryInstallKeyStore()
        let storage = CloudFixtures.storage()
        _ = try await launch(storage, keys: device)
        XCTAssertEqual(device.creates, 1)
        device.forget()
        try Self.serve()
        let got = try await launch(storage, keys: device)
        XCTAssertEqual(got.build, build)
        XCTAssertTrue(Self.fetched.contains("layers.zfw.gz"), "downloaded again: \(Self.fetched)")
        XCTAssertEqual(device.creates, 2, "a new key")
        XCTAssertEqual(InstallRecord.standing(of: try folder(storage), build: build, keys: device), .own(.installed))
    }

    /// The key store fails in another way (locked, unavailable): nothing is opened, nothing is deleted, nothing is
    /// downloaded; the call fails with `storage_failed`; the next call, with the key store back, goes on as if
    /// nothing had happened. With a model on the device, and on a first install.
    func testAKeyStoreThatFailsOpensNothingDeletesNothingAndDownloadsNothing() async throws {
        let build = try Self.serve()
        let device = MemoryInstallKeyStore()
        let storage = CloudFixtures.storage()
        _ = try await launch(storage, keys: device)
        let before = snapshot(storage.appendingPathComponent("models"))
        device.fail("the Keychain is locked")
        try Self.serve()
        let failed = try await launch(storage, keys: device)
        XCTAssertNil(failed.build, "nothing is opened")
        XCTAssertEqual(failed.error?.code, "storage_failed")
        XCTAssertTrue(failed.error?.message.contains("the Keychain is locked") ?? false, failed.error?.message ?? "")
        XCTAssertEqual(Self.fetched, [], "nothing is downloaded")
        XCTAssertEqual(snapshot(storage.appendingPathComponent("models")), before, "nothing is deleted")
        device.fail(nil)
        let again = try await launch(storage, keys: device)
        XCTAssertEqual(again.build, build, "the next call tries again")
        XCTAssertEqual(Self.fetched, [], "and opens what was there")
        XCTAssertEqual(device.creates, 1, "the same key")

        // a first install: no model request at all, and no folder made
        let empty = CloudFixtures.storage()
        let locked = MemoryInstallKeyStore()
        locked.fail("the Keychain is locked")
        try Self.serve()
        let first = try await launch(empty, keys: locked)
        XCTAssertEqual(first.error?.code, "storage_failed")
        XCTAssertEqual(Self.fetched, [])
        XCTAssertEqual(snapshot(empty.appendingPathComponent("models")).filter { !$0.hasPrefix("recommended.json") }, [])
        locked.fail(nil)
        let then = try await launch(empty, keys: locked)
        XCTAssertEqual(then.build, build)
    }

    /// The record is written, with the state `downloading`, before the first byte of the first file is asked for,
    /// and says `installed` once every file is verified.
    func testTheRecordIsWrittenBeforeTheFirstFileIsAskedFor() async throws {
        let build = try Self.build()
        let storage = CloudFixtures.storage()
        let record = InstallRecord.url(storage.appendingPathComponent("models/v4.0/.download-\(build)"))
        let seen = Locked<[String]>([])
        try Self.serve(cdn: { path, _ in
            guard path != "manifest.json" else { return nil }
            let state = (try? Data(contentsOf: record)).flatMap { try? JSONDecoder().decode(InstallRecord.self, from: $0) }?.state.rawValue ?? "no record"
            seen.withLock { $0.append("\(path): \(state)") }
            return nil
        })
        let got = try await launch(storage)
        XCTAssertEqual(got.build, build)
        let states = seen.withLock { $0 }
        XCTAssertFalse(states.isEmpty)
        XCTAssertTrue(states.allSatisfy { $0.hasSuffix(": downloading") }, "\(states)")
        XCTAssertEqual(InstallRecord.read(try folder(storage))?.state, .installed)
        XCTAssertFalse(fm.fileExists(atPath: record.path), "the record went with the folder when the download was put in place")
    }

    // MARK: a model request (15.4)

    /// The exact headers of the manifest request and of a file's Range request: the key and the install's token,
    /// both, on every model request; the token was asked for before the first of them. Where App Attest is
    /// supported that token is the attested one.
    func testEveryModelRequestCarriesTheKeyAndTheInstallsTokenAttestedWhereSupported() async throws {
        let build = try Self.build()
        StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(models: ["Quran-Lab/tajweedformer-v4": build]),
                                                token: CloudFixtures.attestedToken, extra: { s in Self.modelPath(s).map(Self.file) }))
        let storage = CloudFixtures.storage()
        var made = CloudFixtures.options(signingKeys: [CloudFixtures.signer.publicKey.rawRepresentation, try Fixtures.v4miniKey()], storage: storage)
        made.cloud?.appleTeamID = "ABCDE12345"
        let options = made
        let client = try TajweedClient(key: CloudFixtures.key, configuration: options, cloud: { root in
            CloudFixtures.cloud(storage: root, options: options, attester: FakeAttester(isSupported: true), installKeys: MemoryInstallKeyStore())
        })
        defer { client.close() }
        let got = await Self.model(client)
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        let all = StubProtocol.seen
        let requests = Self.modelRequests
        XCTAssertGreaterThan(requests.count, 5)
        let manifest = try XCTUnwrap(requests.first)
        XCTAssertEqual(Self.modelPath(manifest), "manifest.json", "the manifest first")
        for r in requests {
            let path = Self.modelPath(r) ?? "?"
            XCTAssertEqual(r.headers["x-qlab-key"], CloudFixtures.key, path)
            XCTAssertEqual(r.headers["authorization"], "Bearer qlt_v1.eyJ2IjoxfQ.att", "\(path): the attested token")
            XCTAssertEqual(r.method, "GET", path)
            if path == "manifest.json" {
                XCTAssertNil(r.headers["range"], "the manifest is asked for whole")
            } else {
                let size = try XCTUnwrap(try? Data(contentsOf: Self.server().appendingPathComponent(path)).count, path)
                XCTAssertEqual(r.headers["range"], "bytes=0-\(size - 1)", path)
            }
        }
        // the SDK had the token before its first model request: the attestation came first
        let firstModel = try XCTUnwrap(all.firstIndex { Self.modelPath($0) != nil })
        let attested = try XCTUnwrap(all.firstIndex { $0.path == "/v1/attest" })
        XCTAssertLessThan(attested, firstModel, "the token before the first model request")
        XCTAssertNotNil((all[attested].json ?? [:])["attestation"], "an attestation was sent for it")
        // the one place both headers are made
        let headers = ModelRequestAuthorization.headers(key: "k", token: "t")
        XCTAssertEqual(headers.map { $0.name }, ["x-qlab-key", "authorization"])
        XCTAssertEqual(headers.map { $0.value }, ["k", "Bearer t"])
    }

    /// Without App Attest the token is the unattested one, and it is still there before the first model request.
    func testWithoutAppAttestTheModelRequestCarriesTheUnattestedToken() async throws {
        let build = try Self.serve()
        let got = try await launch(CloudFixtures.storage())
        XCTAssertEqual(got.build, build)
        for r in Self.modelRequests {
            XCTAssertEqual(r.headers["authorization"], "Bearer \(Self.token)")
            XCTAssertEqual(r.headers["x-qlab-key"], CloudFixtures.key)
        }
        let all = StubProtocol.seen
        XCTAssertLessThan(try XCTUnwrap(all.firstIndex { $0.path == "/v1/attest" }), try XCTUnwrap(all.firstIndex { Self.modelPath($0) != nil }))
    }

    /// 401 `invalid_token` on a model request: the token is renewed once and the request repeated once, with the
    /// new token. When the repeat is refused too the download fails with `download_failed` and nothing is asked a
    /// third time; it is not a stop of the model.
    func testAModelRequestRenewsTheTokenOnceOnInvalidToken() async throws {
        let issued = Locked(0)
        let tokens: @Sendable (StubProtocol.Seen) -> StubProtocol.Reply? = { s in
            guard s.path == "/v1/attest" else { return nil }
            let n = issued.withLock { (i: inout Int) -> Int in i += 1; return i }
            return .json(["token": "qlt_v1.token-\(n)", "expires_in": 86_400, "attested": false])
        }
        let refusal = StubProtocol.Reply.json(["error": "invalid_token", "message": "The token is not valid."], status: 401)
        // the first token is refused by the download server, the second is taken
        let build = try Self.serve(api: tokens, cdn: { _, s in s.headers["authorization"] == "Bearer qlt_v1.token-1" ? refusal : nil })
        let got = try await launch(CloudFixtures.storage(), keys: MemoryInstallKeyStore())
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        let manifests = Self.modelRequests.filter { Self.modelPath($0) == "manifest.json" }
        XCTAssertEqual(manifests.map { $0.headers["authorization"] }, ["Bearer qlt_v1.token-1", "Bearer qlt_v1.token-2"], "renewed once, repeated once")
        XCTAssertEqual(issued.withLock { $0 }, 2, "one renewal")
        XCTAssertTrue(Self.modelRequests.dropFirst(2).allSatisfy { $0.headers["authorization"] == "Bearer qlt_v1.token-2" })

        // every token is refused: one renewal, one repeat, then the download has failed
        issued.withLock { $0 = 0 }
        try Self.serve(api: tokens, cdn: { _, _ in refusal })
        let storage = CloudFixtures.storage()
        let client = try StubbedModelServer.client(storage: storage, installKeys: MemoryInstallKeyStore())
        let failed = await Self.model(client)
        XCTAssertNil(failed.build)
        XCTAssertEqual(failed.error?.code, "download_failed", "\(String(describing: failed.error))")
        XCTAssertEqual(Self.modelRequests.map { $0.headers["authorization"] }, ["Bearer qlt_v1.token-1", "Bearer qlt_v1.token-2"], "no third request")
        XCTAssertNil(QuranLab.cloud?.gate.stop, "not a refusal of the key or the app")
        client.close()

        // a 401 `invalid_token` that names why the key is refused (the key was revoked after the token was issued)
        // is not renewed: one request, and the refusal stops the model
        issued.withLock { $0 = 0 }
        let revoked = StubProtocol.Reply.json(["error": "invalid_token", "message": "The key of this token was revoked.", "reason": "key_revoked"], status: 401)
        try Self.serve(api: tokens, cdn: { _, _ in revoked })
        let other = try StubbedModelServer.client(storage: CloudFixtures.storage(), installKeys: MemoryInstallKeyStore())
        defer { other.close() }
        let refused = await Self.model(other)
        XCTAssertNil(refused.build)
        XCTAssertEqual(refused.error?.code, "invalid_key", "\(String(describing: refused.error))")
        XCTAssertEqual(Self.modelRequests.map { $0.headers["authorization"] }, ["Bearer qlt_v1.token-1"], "not renewed, not repeated")
        XCTAssertEqual(issued.withLock { $0 }, 1, "no renewal")
        XCTAssertEqual(QuranLab.cloud?.gate.stop?.reason, "key_revoked")
        XCTAssertEqual(QuranLab.cloud?.gate.stop?.from, .model)
    }

    /// A model request never follows a redirect: the answer is a failed download, and the address it names is
    /// never asked.
    func testAModelRequestDoesNotFollowARedirect() async throws {
        try Self.serve(cdn: { path, _ in
            path == "manifest.json" ? StubProtocol.Reply(status: 302, headers: ["location": "https://elsewhere.example/manifest.json"]) : nil
        })
        let got = try await launch(CloudFixtures.storage(), keys: MemoryInstallKeyStore())
        XCTAssertNil(got.build)
        XCTAssertNotNil(got.error)
        XCTAssertFalse(StubProtocol.seen.contains { $0.url.host == "elsewhere.example" }, "the redirect was not followed")
        XCTAssertEqual(Self.fetched, ["manifest.json"])
    }

    // MARK: the model gate (15.3)

    /// One case of the vector as replies of the stub: what the API answers, what the CDN answers to a model request
    /// (nil: as a healthy server), and the config's own reply when the case is a config that does not verify.
    struct Answer: Sendable {
        var api: StubProtocol.Reply?
        var cdn: StubProtocol.Reply?
        var config: StubProtocol.Reply?
    }

    static func answer(_ c: [String: Any]) throws -> Answer {
        let from = try XCTUnwrap(c["from"] as? String)
        guard let status = c["status"] as? Int, let body = c["body"] as? [String: Any] else {
            // no answer at all
            return from == "api" ? Answer(api: .down) : Answer(cdn: .down)
        }
        if status == 200 {
            // a config whose signature does not verify (signed by a key the SDK does not trust)
            return Answer(config: CloudFixtures.config(models: ["Quran-Lab/tajweedformer-v4": try build()], key: Curve25519.Signing.PrivateKey()))
        }
        let reply = StubProtocol.Reply.json(body, status: status)
        return from == "api" ? Answer(api: reply) : Answer(cdn: reply)
    }

    /// Every case of `model_gate.json`, twice: with a model from a real download on the device, and without one.
    /// With a model: an answer that stops the model makes `client.model()` fail with the case's error and open
    /// nothing; any other answer leaves the model running. Without one: the call fails with the case's error, when
    /// the case names one. The stop is remembered exactly for the cases that stop (a `reason` of the list, never an
    /// answer without one), and exactly those remove the model from the device (`removes_models`): no model file
    /// and no install record is left when the call returns, and any other answer removes nothing. Then, for the
    /// stops: a relaunch without a network stays stopped, and a launch that the server accepts clears it and
    /// downloads the build again, every file of it. A refusal of a model request is not cleared by the API's
    /// accepting answers: it ends when the CDN, asked again, serves the key.
    func testEveryCaseOfTheModelGateVector() async throws {
        let v = try Vectors30.json("model_gate.json")
        XCTAssertEqual(v["format"] as? String, "quranlab.sdk-model-gate-vectors/3")
        // `sdk` names the version the file was built with and fills {sdk} in its texts: this SDK is that version or a
        // later 3.1.x, and puts its own version in its place before it compares
        let written = try XCTUnwrap(v["sdk"] as? String)
        XCTAssertTrue(ModelManifest.version(SDKInfo.version, isAtLeast: written), "SDK \(SDKInfo.version) is not older than the vector's \(written)")
        XCTAssertEqual(SDKInfo.version.split(separator: ".").prefix(2).joined(separator: "."), "3.1", "the vector holds for SDK 3.1.x")
        func ours(_ text: Any?) -> String? { (text as? String)?.replacingOccurrences(of: "this is " + written + ".", with: "this is " + SDKInfo.version + ".") }
        XCTAssertEqual(Set(try XCTUnwrap(v["stop_reasons"] as? [String])), ModelGate.stopReasons, "the list of refusals that stop a model, in one constant")
        XCTAssertEqual(Set(try XCTUnwrap(v["key_reasons"] as? [String])), ModelGate.keyReasons, "the stop reasons whose error is invalid_key")
        XCTAssertTrue(ModelGate.keyReasons.isSubset(of: ModelGate.stopReasons))
        let reasons = try XCTUnwrap(ErrorCatalogue.shared.entries["server_rejected"]).reasons
        for r in try XCTUnwrap(v["model_request_reasons"] as? [String]) {
            XCTAssertNotNil(reasons[r], "\(r) has its words in the catalogue")
            XCTAssertFalse(ModelGate.stopReasons.contains(r), "\(r) is a refusal of a model request, never a stop")
        }
        let app = AppIdentity(platform: "ios", bundleID: try XCTUnwrap(v["app"] as? String), name: "Example", version: "2.1")
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 32)
        let build = try Self.build()
        // a build the download server does not have: with it in the config, a launch asks the CDN for a model
        let newer = String(repeating: "b", count: 40)
        // what a first install asks the download server for: the manifest and every file of the CPU set
        try Self.serve()
        _ = try await launch(CloudFixtures.storage(), app: app)
        let whole = Set(Self.fetched)
        XCTAssertGreaterThan(whole.count, 5)
        var stopped = 0
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            let from = try XCTUnwrap(c["from"] as? String, name)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            let stops = try XCTUnwrap(expect["stops_model"] as? Bool, name)
            let removes = try XCTUnwrap(expect["removes_models"] as? Bool, name)
            XCTAssertEqual(removes, stops, "\(name): a stop removes the model, and nothing else does")
            let wanted = expect["error"] as? [String: Any]
            let answer = try Self.answer(c)
            if stops { stopped += 1 }
            // the rule every case follows: a stop exactly when the body carries a reason of the list
            XCTAssertEqual(ModelGate.stops(reason: (c["body"] as? [String: Any])?["reason"] as? String), stops, name)
            for withModel in [true, false] {
                let at = "\(name), " + (withModel ? "a model on the device" : "no model on the device")
                let storage = CloudFixtures.storage()
                let models = storage.appendingPathComponent("models")
                var held: [String] = []
                if withModel {
                    try Self.serve()
                    let first = try await launch(storage, app: app)
                    XCTAssertEqual(first.build, build, "\(at): the real download")
                    held = snapshot(try folder(storage))
                    XCTAssertTrue(held.contains { $0.hasPrefix(InstallRecord.fileName + " ") }, "\(at): the build's folder and its install record")
                }
                // the launch that gets the answer
                let config = answer.config ?? CloudFixtures.config(models: ["Quran-Lab/tajweedformer-v4": from == "cdn" && withModel ? newer : build])
                StubProtocol.reset(CloudFixtures.server(config: config, extra: { s in
                    guard let path = Self.modelPath(s) else { return answer.api }
                    return answer.cdn ?? Self.file(path)
                }))
                let client = try StubbedModelServer.client(storage: storage, app: app)
                let cloud = try XCTUnwrap(QuranLab.cloud, at)
                // the answer arrives: from the API with the config; from the CDN with a model request (with a model
                // on the device, the update to the build the new config names)
                _ = await cloud.refreshConfig()
                if from == "cdn", withModel { _ = await cloud.checkForUpdate(.recommended) }
                let got = await Self.model(client)
                // (for a refusal of a model request the API has accepted the key all along, with the config and the
                // token of this launch: that does not clear it)
                XCTAssertEqual(cloud.gate.stop != nil, stops, "\(at): the stop is remembered exactly when the answer is one")
                if stops { XCTAssertEqual(cloud.gate.stop?.from, from == "cdn" ? ModelGate.Source.model : ModelGate.Source.api, at) }
                // a stop removes every model build from the device, and nothing else does
                if removes {
                    XCTAssertEqual(snapshot(models).filter { !$0.hasPrefix("recommended.json") }, [], "\(at): no model file and no install record is left")
                } else if withModel {
                    XCTAssertEqual(snapshot(try folder(storage)), held, "\(at): an answer that is not a stop removes nothing")
                }
                if withModel && !stops {
                    XCTAssertEqual(got.build, build, "\(at): the model keeps running (\(String(describing: got.error)))")
                } else {
                    XCTAssertNil(got.build, "\(at): no model is opened")
                    let e = try XCTUnwrap(got.error, at)
                    if let wanted {
                        XCTAssertEqual(e.code, wanted["code"] as? String, at)
                        XCTAssertEqual(e.message, ours(wanted["message"]), at)
                        XCTAssertEqual(e.fix, ours(wanted["fix"]), at)
                    } else {
                        XCTAssertFalse(["server_rejected", "invalid_key", "sdk_too_old"].contains(e.code), "\(at): no refusal of its own, got \(e.code)")
                    }
                }
                if name == "CDN 429 model_limit", !withModel {
                    XCTAssertEqual(Self.fetched, ["manifest.json"], "the limit is not answered with a loop")
                }
                client.close()
                guard stops, let wanted else { continue }
                // a relaunch without a network: the refusal is remembered on the device
                StubProtocol.reset { _ in .down }
                let offline = try await launch(storage, app: app)
                XCTAssertNil(offline.build, "\(at): a relaunch without a network stays stopped")
                XCTAssertEqual(offline.error?.code, wanted["code"] as? String, at)
                XCTAssertEqual(offline.error?.message, ours(wanted["message"]), at)
                XCTAssertEqual(snapshot(models).filter { !$0.hasPrefix("recommended.json") }, [], "\(at): still no model on the device")
                // a launch the server accepts: the stop is cleared. A refusal of the API ends with the API's answer;
                // a refusal of a model request ends when the CDN, asked again, serves the key. The device holds no
                // model, so the build is downloaded as on a first install: every file of it is asked for again
                try Self.serve()
                let accepted = try await launch(storage, app: app)
                XCTAssertEqual(accepted.build, build, "\(at): an accepting answer clears the stop (\(String(describing: accepted.error)))")
                XCTAssertNil(ModelGate(storage: storage).stop, "\(at): nothing is remembered any more")
                XCTAssertEqual(Set(Self.fetched), whole, "\(at): the manifest and every file of the build are asked for again")
            }
        }
        XCTAssertEqual(stopped, 13, "the cases that stop a model")
    }

    /// A refusal of a model request holds while the API accepts the key: a config and a token that succeed do not
    /// clear it, and at a launch where the CDN still refuses, no model is opened or downloaded (the one that was
    /// on the device went with the refusal). Without a network nothing is asked. It ends when the CDN serves a
    /// model request again, and the build is downloaded.
    func testARefusalOfAModelRequestIsNotClearedByAnAnswerOfTheAPI() async throws {
        let build = try Self.serve()
        let storage = CloudFixtures.storage()
        let first = try await launch(storage)
        XCTAssertEqual(first.build, build)
        // the CDN refuses the key from now on; the API keeps accepting it
        let refusal = StubProtocol.Reply.json(["error": "missing or invalid x-qlab-key", "reason": "key_type_mismatch"], status: 401)
        try Self.serve(named: String(repeating: "b", count: 40), cdn: { _, _ in refusal })
        let client = try StubbedModelServer.client(storage: storage)
        let cloud = try XCTUnwrap(QuranLab.cloud)
        _ = await cloud.refreshConfig()
        _ = await cloud.checkForUpdate(.recommended)
        XCTAssertEqual(cloud.gate.stop?.from, .model)
        XCTAssertEqual(snapshot(storage.appendingPathComponent("models")).filter { !$0.hasPrefix("recommended.json") }, [],
                       "the model went with the refusal, in the call that received it")
        // answers of the API that accept the key: a new token and the config
        await cloud.tokens?.invalidate()
        let fresh = await cloud.refreshConfig()
        XCTAssertNotNil(fresh, "the API accepts the key")
        XCTAssertTrue(StubProtocol.seen.contains { $0.path == "/v1/attest" }, "a token was issued")
        XCTAssertEqual(cloud.gate.stop?.reason, "key_type_mismatch", "still remembered")
        let got = await Self.model(client)
        XCTAssertNil(got.build)
        XCTAssertEqual(got.error?.code, "server_rejected")
        XCTAssertEqual(got.error?.message, "This key is of the wrong type for this platform (key_type_mismatch).")
        client.close()
        // the next launch: the API accepts, the CDN is asked again and still refuses
        try Self.serve(cdn: { _, _ in refusal })
        let still = try await launch(storage)
        XCTAssertNil(still.build)
        XCTAssertEqual(still.error?.code, "server_rejected")
        XCTAssertEqual(Set(Self.fetched), ["manifest.json"], "the CDN is asked, and nothing is downloaded")
        // without a network: nothing is asked, and it holds
        StubProtocol.reset { _ in .down }
        let offline = try await launch(storage)
        XCTAssertEqual(offline.error?.code, "server_rejected")
        // the CDN serves the key again: its answer decides, and the build is downloaded
        try Self.serve()
        let served = try await launch(storage)
        XCTAssertEqual(served.build, build, "\(String(describing: served.error))")
        XCTAssertTrue(Self.fetched.contains("layers.zfw.gz"), "downloaded again: \(Self.fetched)")
        XCTAssertNil(ModelGate(storage: storage).stop)
    }

    // MARK: a stop removes the model from the device (15.3, contract 1.10.0)

    /// An answer of the API that stops the model: every API request is refused with `reason`, and the download
    /// server is not reached.
    static func refuse(_ reason: String = "app_blocked") {
        StubProtocol.reset { s in
            s.url.host == CloudFixtures.api.host ? .json(["error": "app_blocked", "message": "Refused.", "reason": reason], status: 403)
                : StubProtocol.Reply(status: 404)
        }
    }

    /// What is under `<storage>/models`, without the note of which model Quran Lab recommends (not a model file).
    func modelFiles(_ storage: URL) -> [String] {
        snapshot(storage.appendingPathComponent("models")).filter { !$0.hasPrefix("recommended.json") }
    }

    /// Every install record under a storage folder, wherever it is.
    func installRecords(_ storage: URL) -> [String] {
        snapshot(storage).filter { $0.contains(InstallRecord.fileName) }
    }

    /// A stop with a model from a real download on the device: when the call that received the refusal returns,
    /// the SDK's storage holds no model file and no install record. What is not a model stays: the remembered
    /// refusal, the device key, the learner's sharing state, a recording that is not sent yet. Once the server
    /// accepts the key again, `client.model()` asks for every file of the build again.
    func testAStopRemovesTheModelFromTheDeviceAndLeavesTheRest() async throws {
        let build = try Self.serve()
        let device = MemoryInstallKeyStore()
        let storage = CloudFixtures.storage()
        let first = try await launch(storage, keys: device)
        XCTAssertEqual(first.build, build)
        let whole = Set(Self.fetched)
        XCTAssertFalse(modelFiles(storage).isEmpty)
        XCTAssertEqual(installRecords(storage).count, 1, "\(installRecords(storage))")
        // what the install holds beside the model: the learner's answer about sharing, and a recording in the queue
        // (a stand-in file where the queue keeps its recordings)
        let sharing = storage.appendingPathComponent("cloud/sharing-state.json")
        let answer = Data(SharingConsentPersistTests.granted301.utf8)
        try answer.write(to: sharing)
        let unsent = storage.appendingPathComponent("outbox/not-sent-yet/seg-00001.opus")
        try fm.createDirectory(at: unsent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 300).write(to: unsent)

        // the server refuses the app
        Self.refuse()
        let client = try StubbedModelServer.client(storage: storage, installKeys: device)
        let cloud = try XCTUnwrap(QuranLab.cloud)
        _ = await cloud.refreshConfig()
        // the call that received the refusal has returned: the model is gone
        XCTAssertEqual(modelFiles(storage), [], "no model file is left")
        XCTAssertEqual(installRecords(storage), [], "no install record is left")
        let got = await Self.model(client)
        XCTAssertNil(got.build)
        XCTAssertEqual(got.error?.code, "server_rejected", "the refusal's error, nothing about the removal")
        XCTAssertEqual(got.error?.message, "Quran Lab does not serve this app at the moment: it is blocked by Quran Lab or paused by its developer (app_blocked).")
        // what is not a model stays
        XCTAssertEqual(cloud.gate.stop?.reason, "app_blocked", "the remembered refusal")
        XCTAssertTrue(fm.fileExists(atPath: storage.appendingPathComponent("cloud/model-stop.json").path), "the refusal is on the device")
        XCTAssertTrue(device.hasKey, "the device key")
        XCTAssertEqual(device.creates, 1, "the same device key")
        let kept = try XCTUnwrap(Contributions.stateFile(storage: storage).read(), "the sharing state")
        XCTAssertEqual(kept.consent, .granted, "the learner's answer about sharing")
        XCTAssertEqual(kept.consentVersion, "share-2026-11-09")
        XCTAssertEqual(try Data(contentsOf: unsent).count, 300, "the recording that is not sent yet")
        client.close()

        // the server accepts the key again: the device holds no model, so the build is downloaded as on a first install
        try Self.serve()
        let again = try await launch(storage, keys: device)
        XCTAssertEqual(again.build, build, "\(String(describing: again.error))")
        XCTAssertEqual(Set(Self.fetched), whole, "the manifest and every file are asked for again")
        XCTAssertEqual(installRecords(storage).count, 1)
        XCTAssertEqual(device.creates, 1, "with the device key it had")
    }

    /// A refusal that arrives in the middle of a download (the download server refuses a file): the files that
    /// were already downloaded and the partial download go too.
    func testAStopInTheMiddleOfADownloadRemovesThePartialDownload() async throws {
        let build = try Self.build()
        let refusal = StubProtocol.Reply.json(["error": "missing or invalid x-qlab-key", "reason": "key_revoked"], status: 401)
        // the key is revoked while the files are on their way: from the weights file on, every model request is refused
        let revoked = Locked(false)
        try Self.serve(cdn: { path, _ in
            let refused = revoked.withLock { (r: inout Bool) -> Bool in
                if path == "layers.zfw.gz" { r = true }
                return r
            }
            return refused ? refusal : nil
        })
        let storage = CloudFixtures.storage()
        let client = try StubbedModelServer.client(storage: storage, installKeys: MemoryInstallKeyStore())
        defer { client.close() }
        let got = await Self.model(client)
        XCTAssertNil(got.build)
        XCTAssertEqual(got.error?.code, "invalid_key")
        XCTAssertTrue(Self.fetched.contains("calibration.json.gz"), "files were downloaded before the refusal: \(Self.fetched)")
        XCTAssertEqual(QuranLab.cloud?.gate.stop?.reason, "key_revoked")
        XCTAssertEqual(modelFiles(storage), [], "nothing of the download \(build) is left")
        XCTAssertEqual(installRecords(storage), [])
    }

    /// A removal that fails (a storage error) is never an error of its own: the app gets the refusal's error. It
    /// is tried again at the next start, before anything else, also without a network. And a start without a
    /// network that finds a remembered refusal and model files (put back by hand) removes them first and fails
    /// with the refusal's error.
    func testARemovalThatFailsIsTriedAgainAtTheNextStart() async throws {
        defer { ModelGate.refusesRemoval.withLock { $0 = nil } }
        let build = try Self.serve()
        let storage = CloudFixtures.storage()
        let first = try await launch(storage)
        XCTAssertEqual(first.build, build)
        let before = modelFiles(storage)
        XCTAssertFalse(before.isEmpty)
        // a copy of the model files as the download left them, for the last part
        let kept = CloudFixtures.storage()
        try fm.copyItem(at: storage.appendingPathComponent("models"), to: kept.appendingPathComponent("models"))

        // the device refuses to remove files while the refusal arrives
        ModelGate.refusesRemoval.withLock { $0 = { true } }
        Self.refuse()
        let client = try StubbedModelServer.client(storage: storage)
        let cloud = try XCTUnwrap(QuranLab.cloud)
        _ = await cloud.refreshConfig()
        XCTAssertNotNil(cloud.gate.stop)
        XCTAssertEqual(modelFiles(storage), before, "the removal failed: the files are still there")
        let got = await Self.model(client)
        XCTAssertNil(got.build, "and no model is opened all the same")
        XCTAssertEqual(got.error?.code, "server_rejected", "the refusal's error, not a storage error")
        XCTAssertEqual(modelFiles(storage), before)
        client.close()

        // the next start, without a network: the removal is done before anything else
        ModelGate.refusesRemoval.withLock { $0 = nil }
        StubProtocol.reset { _ in .down }
        let next = try StubbedModelServer.client(storage: storage)
        XCTAssertEqual(modelFiles(storage), [], "removed when the Client started")
        XCTAssertEqual(installRecords(storage), [])
        let offline = await Self.model(next)
        XCTAssertEqual(offline.error?.code, "server_rejected")
        next.close()

        // model files put back by hand while the refusal is remembered: the next start removes them, without a network
        try? fm.removeItem(at: storage.appendingPathComponent("models"))
        try fm.copyItem(at: kept.appendingPathComponent("models"), to: storage.appendingPathComponent("models"))
        XCTAssertEqual(modelFiles(storage), before)
        let last = try StubbedModelServer.client(storage: storage)
        defer { last.close() }
        XCTAssertEqual(modelFiles(storage), [], "a start that finds a remembered refusal and model files removes them first")
        let refused = await Self.model(last)
        XCTAssertNil(refused.build)
        XCTAssertEqual(refused.error?.code, "server_rejected")
        XCTAssertEqual(refused.error?.message, "Quran Lab does not serve this app at the moment: it is blocked by Quran Lab or paused by its developer (app_blocked).")
    }

    /// A Model that is already open when the refusal arrives keeps running until the app closes it, and its files
    /// stay that long (the engine opens files of the folder again for another context and for the accelerator's
    /// build). When it is closed its files go, and the next `client.model()` opens nothing.
    func testAModelOpenWhenTheRefusalArrivesKeepsRunningUntilItIsClosed() async throws {
        let build = try Self.serve()
        let storage = CloudFixtures.storage()
        let client = try StubbedModelServer.client(storage: storage)
        defer { client.close() }
        let model = try await client.model()
        XCTAssertEqual(model.build, build)
        let before = modelFiles(storage)
        XCTAssertFalse(before.isEmpty)
        // the server now refuses the app
        Self.refuse()
        let cloud = try XCTUnwrap(QuranLab.cloud)
        await cloud.tokens?.invalidate()
        _ = await cloud.refreshConfig()
        XCTAssertNotNil(cloud.gate.stop, "the refusal arrived and is remembered")
        XCTAssertEqual(modelFiles(storage), before, "the open Model's files stay while it is open")
        // the open Model still takes a take
        let session = try await model.listen(from: fakeRecitation(seconds: 2), sampleRate: 16_000, options: .init(backend: .cpu, pace: .fast))
        for await _ in session.chunks {}
        _ = try await session.finish()
        let same = try await client.model()
        XCTAssertTrue(same === model, "the Model the app holds is still the Client's")
        XCTAssertEqual(modelFiles(storage), before)
        await model.close()
        XCTAssertEqual(modelFiles(storage), [], "once the Model is closed its files are gone")
        XCTAssertEqual(installRecords(storage), [])
        let after = await Self.model(client)
        XCTAssertNil(after.build, "once closed, no model is opened for a refused Client")
        XCTAssertEqual(after.error?.code, "server_rejected")
        let d = await client.diagnose()
        XCTAssertEqual(d.key.accepted, false)
        XCTAssertEqual(d.key.reason, "server_rejected")
    }

    // MARK: no public way to hand the SDK a model (15.1)

    /// The sources of a model, every one: a folder (the SDK's own tests), the store, the CDN. The app bundle is none.
    static func name(_ source: ModelSource) -> String {
        switch source {
        case .directory: return "directory"
        case .cache: return "cache"
        case .cdn: return "cdn"
        }
    }

    /// No public declaration opens a model folder or takes a model as a URL, a path, bytes or a bundle folder, and
    /// none sets a base URL, a trusted key, a verifier or a transport. The one public URL is the Client's storage
    /// folder, which the SDK fills itself. Read from the sources; the compiler says the rest (an app that calls
    /// `TajweedModel.open` does not compile).
    func testNoPublicDeclarationTakesAModel() throws {
        XCTAssertEqual([ModelSource.cache, .cdn, .directory(URL(fileURLWithPath: "/x"))].map(Self.name), ["cache", "cdn", "directory"])
        XCTAssertEqual(QuranLab.Options().modelSource, [.cache, .cdn], "what a Client's configuration looks in: its own store, then the CDN")
        let sources = Fixtures.repo.appendingPathComponent("Sources/TajweedFormer")
        guard let e = fm.enumerator(atPath: sources.path) else { throw XCTSkip("the sources are not in this checkout") }
        var declarations: [String] = []
        var files = 0
        while let rel = e.nextObject() as? String {
            guard rel.hasSuffix(".swift"), let text = try? String(contentsOf: sources.appendingPathComponent(rel), encoding: .utf8) else { continue }
            files += 1
            for line in text.components(separatedBy: "\n") {
                let s = line.trimmingCharacters(in: .whitespaces)
                if !s.hasPrefix("//") { XCTAssertFalse(s.contains("QuranLabModels"), "\(rel) still reads the app bundle's model folder: \(s)") }
                guard s.range(of: #"^(@\w+(\([^)]*\))? +)*(public|open) "#, options: .regularExpression) != nil else { continue }
                declarations.append("\(rel): \(s)")
            }
        }
        XCTAssertGreaterThan(files, 40, "the SDK's sources were read")
        XCTAssertGreaterThan(declarations.count, 200)
        XCTAssertEqual(declarations.filter { $0.range(of: #"func open\b"#, options: .regularExpression) != nil }, [], "no public call opens a model")
        let withURL = declarations.filter { $0.range(of: #"\bURL\b"#, options: .regularExpression) != nil }.map { String($0.prefix { $0 != "{" }).trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(withURL.count, 2, "\(withURL)")
        XCTAssertTrue(withURL.allSatisfy { $0.hasPrefix("API/TajweedClient.swift: ") && $0.contains("storage: URL?") }, "the storage folder and nothing else: \(withURL)")
        for word in ["Bundle", "ManifestVerifier", "ModelSource", "CloudOptions", "URLSession", "signingKeys", "trustedKeys", "cdnURL", "apiURL", "InstallKeyStoring"] {
            XCTAssertEqual(declarations.filter { $0.range(of: "\\b\(word)\\b", options: .regularExpression) != nil }, [], "a public declaration names \(word)")
        }
    }
}
