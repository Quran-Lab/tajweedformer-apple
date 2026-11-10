import CryptoKit
import Foundation
import Security

/// One shared session in the outbox.
public struct Contribution: Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable {
        /// Recording, waiting to upload, or uploading.
        case queued
        /// Every segment of the ended session is in R2.
        case uploaded
        /// The server refused it for good, with its error code. The local copy is gone.
        case failed(code: String, message: String)
    }

    /// The session's upload id (32 hex), also the server's id for it.
    public let id: String
    /// Audio segments closed so far.
    public let segments: Int
    /// Bytes of audio closed so far.
    public let bytes: Int64
    /// Known once the session has ended (0 before).
    public let durationMs: Int
    /// The session's UTC day.
    public let day: String
    /// Nil while the session runs; false when it failed, was cancelled, or the app was killed.
    public let completed: Bool?
    public let status: Status
    public let attempts: Int
    /// Why the last attempt did not finish; nil once it has.
    public let lastError: String?
    /// The bitrate (bit/s) of each closed segment, in segment order (2.0.1: the adaptive bitrate, 192000 to 32000).
    public let segmentBitrates: [Int]
}

/// The random contributor id of this install: 128 bits, 32 lowercase hex, in the Keychain (this
/// device only, never synced), sent only with shared sessions. The server keeps only an HMAC of
/// it with the app id. Where the Keychain is unavailable (a test binary without entitlements) it
/// is a file in the SDK's storage.
enum Contributor {
    static let service = "quranlab.sdk"
    static let account = "contributor"

    static func id(storage: URL) -> String {
        if let v = read(storage: storage) { return v }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let v = Data(bytes).hex
        write(v, storage: storage)
        return read(storage: storage) ?? v
    }

    /// A new contributor: the code, the device key and the recovery code all go (the next share makes new ones).
    static func reset(storage: URL) {
        SecItemDelete(query() as CFDictionary)
        try? FileManager.default.removeItem(at: file(storage))
        ContributorKey.reset(storage: storage)
    }

    static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true]
    }

    private static func file(_ storage: URL) -> URL { storage.appendingPathComponent("cloud/contributor") }

    private static func valid(_ s: String) -> Bool { s.count == 32 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase } }

    private static func read(storage: URL) -> String? {
        var q = query()
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
           let s = String(data: d, encoding: .utf8), valid(s) { return s }
        if let d = try? Data(contentsOf: file(storage)), let s = String(data: d, encoding: .utf8), valid(s) { return s }
        return nil
    }

    private static func write(_ v: String, storage: URL) {
        var q = query()
        q[kSecValueData as String] = Data(v.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false
        if SecItemAdd(q as CFDictionary, nil) == errSecSuccess { return }
        let f = file(storage)
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(v.utf8).write(to: f, options: [.atomic])
    }
}

/// qlab-api's sharing routes and the PUTs to R2.
///
/// `POST /v1/uploads` (the session JSON, `x-qlab-id`) answers with presigned PUT URLs for segments
/// 1 to 20, each for its own key `v1/{id}/seg-NNNNN.opus`, signed by the Worker (content-type
/// `audio/ogg` signed, valid 7 days); `POST /v1/uploads/{id}/urls?from=n` answers the next batch, or
/// fresh URLs for the same numbers. The segments go straight to R2 as plain PUTs to those URLs. That
/// is all: nothing is sent at the end.
struct ContributionClient: Sendable {
    let http: HTTPClient
    let apiURL: URL

    /// A presigned PUT URL for segment `n`.
    struct SegmentURL: Codable, Sendable, Hashable {
        var n: Int
        var url: URL
        var expiresAt: Date

        /// Usable for a PUT that starts now (five minutes of margin for a slow start).
        func fresh(at now: Date) -> Bool { expiresAt.timeIntervalSince(now) > 300 }
    }

    func startRequest(id: String, session: Data, token: String) -> URLRequest {
        var r = URLRequest(url: apiURL.appendingPathComponent("v1/uploads"))
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(id, forHTTPHeaderField: "x-qlab-id")
        r.httpBody = session
        return r
    }

    /// URLs for segments `from` to `from + 19`.
    func urlsRequest(id: String, from: Int, contributor: String, token: String) -> URLRequest {
        var c = URLComponents(url: apiURL.appendingPathComponent("v1/uploads/\(id)/urls"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "from", value: String(from))]
        var r = URLRequest(url: c.url!)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        r.setValue(contributor, forHTTPHeaderField: "x-qlab-contributor")
        return r
    }

    /// The URLs in an answer of either route; nil when it has none.
    static func urls(_ resp: HTTPClient.Response, id: String) -> [SegmentURL]? {
        guard let o = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any], o["id"] as? String == id,
              let list = o["urls"] as? [[String: Any]] else { return nil }
        let out = list.compactMap { u -> SegmentURL? in
            guard let n = u["n"] as? Int, n > 0, let url = (u["url"] as? String).flatMap(URL.init(string:)),
                  let exp = u["expires_at"] as? Double else { return nil }
            return SegmentURL(n: n, url: url, expiresAt: Date(timeIntervalSince1970: exp))
        }
        return out.isEmpty ? nil : out
    }

    /// A plain PUT of one segment to its presigned URL. content-type is signed into the URL, so it
    /// must be exactly `audio/ogg`; content-length is set so the body is never sent chunked.
    static func putRequest(_ u: SegmentURL, contentType: String, bytes: Int64) -> URLRequest {
        var r = URLRequest(url: u.url)
        r.httpMethod = "PUT"
        r.setValue(contentType, forHTTPHeaderField: "content-type")
        r.setValue(String(bytes), forHTTPHeaderField: "content-length")
        return r
    }

    /// The session JSON sent at the start. `audio.sample_rate` is the coded rate (always 48 kHz);
    /// `input_sample_rate` the capture rate (the SDK resamples anything else to 48 kHz first), and
    /// `input_route` the kind of input (`AudioRoute`, no device names). A session has one input
    /// rate: the recognizer ends a session whose input rate changes, so no mixed-rate field.
    /// `consentTextSHA256`: the hash of the app's own consent wording the learner agreed to (2.0.1); sent only then,
    /// next to `consent_version` (a server before 2.0.1 refuses unknown fields).
    static func session(modelRevision: String?, backend: String, weightsSHA256: String?, consentVersion: String?,
                        contributor: String, day: String, inputSampleRate: Int, inputRoute: String,
                        contributorKey: String? = nil, recoveryHash: String? = nil, consentTextSHA256: String? = nil) -> Data {
        var o: [String: Any] = [
            "format": 1,
            "audio": ["codec": "opus", "container": "ogg", "sample_rate": Int(OggOpusWriter.rate), "channels": 1,
                      "input_sample_rate": inputSampleRate, "input_route": inputRoute],
            "decode": ["model_revision": modelRevision.map { String($0.prefix(64)) as Any } ?? NSNull(), "backend": backend,
                       "weights_sha256": weightsSHA256.map { $0 as Any } ?? NSNull(), "sdk_version": SDKInfo.version],
            "contributor": contributor,
            "day": day,
            "device_class": DeviceContext.deviceClass,
            "os_major": DeviceContext.osMajor,
        ]
        if let consentVersion { o["consent_version"] = consentVersion }
        if let consentTextSHA256, consentVersion?.hasPrefix("custom-") == true { o["consent_text_sha256"] = consentTextSHA256 }
        // the learner's deletion credential: the device key's public half and the hash of the
        // recovery code; the server binds them to the contributor once
        if let contributorKey { o["contributor_key"] = contributorKey }
        if let recoveryHash { o["recovery_hash"] = recoveryHash }
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}

/// The files of one shared session in its outbox folder. The capture writes the session JSON,
/// the segments and a marker per closed segment, and `end.json`; the outbox writes only
/// `item.json`.
enum ShareFiles {
    static let session = "session.json"
    static let capture = "capture.json"
    static let end = "end.json"
    static func name(_ n: Int) -> String { String(format: "seg-%05d", n) }

    /// A closed segment: its size and hash, where the stream stood, and the bitrate it was encoded at (absent in
    /// markers of SDKs before 2.0.1, which encoded at 192000).
    struct Marker: Codable, Sendable {
        var n: Int
        var bytes: Int64
        var sha256: String
        var granule: Int64
        var bitrate: Int?
    }

    struct End: Codable, Sendable {
        var durationMs: Int
        var completed: Bool
    }

    /// Written when the capture starts and again as each segment opens, so recovery of a killed capture knows the
    /// bitrate of the segment it closes.
    struct Capture: Codable, Sendable {
        var preSkip: Int
        /// The bitrate of each segment opened so far, in order.
        var bitrates: [Int]?
    }

    static func sha256(_ url: URL) -> (Int64, String)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hash = SHA256Hasher()
        var n: Int64 = 0
        while let d = try? h.read(upToCount: 1 << 20), !d.isEmpty {
            hash.update(d)
            n += Int64(d.count)
        }
        return (n, hash.hex)
    }

    static func write<T: Encodable>(_ v: T, _ url: URL) throws {
        try JSONEncoder().encode(v).write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ t: T.Type, _ url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(t, from: $0) }
    }

    /// Closes segment `n`: its marker, from the files as they are on disk.
    static func mark(_ folder: URL, n: Int, granule: Int64, bitrate: Int?) throws {
        let base = folder.appendingPathComponent(name(n))
        guard let (bytes, sha) = sha256(base.appendingPathExtension("opus")) else { throw CocoaError(.fileReadNoSuchFile) }
        try write(Marker(n: n, bytes: bytes, sha256: sha, granule: granule, bitrate: bitrate), base.appendingPathExtension("json"))
    }

    /// Seconds of audio in closed segments not uploaded yet, over every session under `root` (an uploaded segment's
    /// audio file is gone, its marker stays): segment n lasts (granule n - granule n-1) / 48000, segment 1 from 0.
    static func backlogSeconds(root: URL) -> Double {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        var samples: Int64 = 0
        for id in names where id.count == 32 {
            let folder = root.appendingPathComponent(id, isDirectory: true)
            var previous: Int64 = 0
            for m in markers(folder) {
                let audio = folder.appendingPathComponent(name(m.n)).appendingPathExtension("opus")
                if fm.fileExists(atPath: audio.path) { samples += max(0, m.granule - previous) }
                previous = m.granule
            }
        }
        return Double(samples) / 48_000
    }

    static func markers(_ folder: URL) -> [Marker] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("seg-") && $0.hasSuffix(".json") }.compactMap { read(Marker.self, folder.appendingPathComponent($0)) }
            .sorted { $0.n < $1.n }
    }

    /// A session the app was killed in: the last segment is cut back to its last whole page,
    /// closed, and the session ended as not completed.
    /// Returns false when there is nothing to share (the folder is then removed).
    @discardableResult
    static func recover(_ folder: URL) -> Bool {
        let fm = FileManager.default
        guard let cap = read(Capture.self, folder.appendingPathComponent(capture)) else {
            try? fm.removeItem(at: folder)
            return false
        }
        var marks = markers(folder)
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let open = names.filter { $0.hasSuffix(".opus") }.compactMap { Int($0.dropFirst(4).dropLast(5)) }
            .filter { n in !marks.contains { $0.n == n } }.sorted()
        for n in open {
            let base = folder.appendingPathComponent(name(n))
            let audio = base.appendingPathExtension("opus")
            let d = (try? Data(contentsOf: audio)) ?? Data()
            let (keep, granule) = wholePages(d)
            if keep == 0 {
                try? fm.removeItem(at: audio)
                continue
            }
            if keep < d.count, let h = try? FileHandle(forWritingTo: audio) {
                try? h.truncate(atOffset: UInt64(keep))
                try? h.close()
            }
            let bitrate: Int? = cap.bitrates.flatMap { (b: [Int]) -> Int? in n >= 1 && n <= b.count ? b[n - 1] : nil }
            try? mark(folder, n: n, granule: granule, bitrate: bitrate)
        }
        marks = markers(folder)
        guard let last = marks.last else {
            try? fm.removeItem(at: folder)
            return false
        }
        let ms = Int(max(0, last.granule - Int64(cap.preSkip)) / 48)
        try? write(End(durationMs: ms, completed: false), folder.appendingPathComponent(end))
        return true
    }

    /// The length of the whole pages at the start of `d` (each with a valid CRC), and the last
    /// one's granule position.
    static func wholePages(_ d: Data) -> (Int, Int64) {
        let b = [UInt8](d)
        var at = 0, granule: Int64 = 0
        while at + 27 <= b.count, b[at] == 0x4f, b[at + 1] == 0x67, b[at + 2] == 0x67, b[at + 3] == 0x53 {
            let nseg = Int(b[at + 26])
            guard at + 27 + nseg <= b.count else { break }
            let len = b[(at + 27)..<(at + 27 + nseg)].reduce(0) { $0 + Int($1) }
            let end = at + 27 + nseg + len
            guard end <= b.count else { break }
            var page = Data(b[at..<end])
            let crc = (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[at + 22 + $1]) << (8 * $1) }
            page.replaceSubrange(22..<26, with: [0, 0, 0, 0])
            guard OggOpusWriter.crc(page) == crc else { break }
            granule = (0..<8).reduce(Int64(0)) { $0 | Int64(b[at + 6 + $1]) << (8 * $1) }
            at = end
        }
        return (at, granule)
    }
}

/// Incremental SHA-256 to hex.
struct SHA256Hasher {
    private var h = CryptoKit.SHA256()
    mutating func update(_ d: Data) { h.update(data: d) }
    var hex: String { h.finalize().map { String(format: "%02x", $0) }.joined() }
}

/// One session being shared: Ogg Opus segments written as the session runs, into the session's
/// folder in the outbox, each closed segment handed to the outbox at once. Lives on the recognizer's actor with the session.
final class ShareCapture {
    /// A session that fails or is cancelled is shared only from this long.
    static let minimumPartial: TimeInterval = 2
    /// Folders being written in this process (so the outbox does not take them for crashed).
    static let active = Locked<Set<String>>([])

    let id: String
    let folder: URL
    private let outbox: ContributionOutbox
    /// The session JSON, given the input rate and route (known at the first audio).
    private let session: (Int, String) -> Data
    private var writer: OggOpusWriter?
    private var segments = 0
    private var failed = false
    /// The bitrate of each segment opened so far (the capture file keeps them for recovery).
    private var bitrates: [Int] = []
    private var preSkip = 0

    init(outbox: ContributionOutbox, consentVersion: String?, consentTextSHA256: String? = nil, modelRevision: String?, backend: String,
         weightsSHA256: String?) {
        self.outbox = outbox
        id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        folder = outbox.root.appendingPathComponent(id, isDirectory: true)
        let weights = weightsSHA256
        let contributor = Contributor.id(storage: outbox.storage), day = Day.string()
        let key = ContributorKey.key(storage: outbox.storage)?.contributorKey
        let recovery = RecoveryCode.hash(ContributorKey.recoveryCode(storage: outbox.storage))
        session = { rate, route in
            ContributionClient.session(modelRevision: modelRevision, backend: backend, weightsSHA256: weights,
                                       consentVersion: consentVersion, contributor: contributor, day: day,
                                       inputSampleRate: rate, inputRoute: route, contributorKey: key, recoveryHash: recovery,
                                       consentTextSHA256: consentTextSHA256)
        }
        let id = self.id
        Self.active.withLock { _ = $0.insert(id) }
    }

    func append(_ mono: [Float], rate: Double) throws(RecognizerError) {
        guard !failed else { return }
        guard Contributions.isActive else { return abandon() }
        if writer == nil {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try session(Int(rate.rounded()), AudioRoute.current()).write(to: folder.appendingPathComponent(ShareFiles.session))
            } catch {
                throw .storageFailed("cannot create \(folder.lastPathComponent): \(error.localizedDescription)")
            }
            let folder = self.folder
            let w = try OggOpusWriter(segmentURL: { n in folder.appendingPathComponent(ShareFiles.name(n)).appendingPathExtension("opus") },
                                      plan: SegmentPlan.seconds, inputRate: rate) { [unowned self] seg in self.closed(seg) }
            // 2.0.1: each segment opens at the ladder's bitrate in force then
            let ladder = outbox.ladder
            w.bitrateForSegment = { (_: Int) -> Int in ladder.bitrate }
            w.onSegmentOpen = { [unowned self] (n: Int, bps: Int) in self.opened(n, bitrate: bps) }
            preSkip = w.preSkip
            try? ShareFiles.write(ShareFiles.Capture(preSkip: w.preSkip, bitrates: []), folder.appendingPathComponent(ShareFiles.capture))
            writer = w
        }
        guard writer?.inputRate == rate else { return }
        try writer?.append(mono)
    }

    /// A segment opened: its bitrate goes to the capture file before any of its audio is on disk.
    private func opened(_ n: Int, bitrate: Int) {
        if bitrates.count == n - 1 { bitrates.append(bitrate) }
        try? ShareFiles.write(ShareFiles.Capture(preSkip: preSkip, bitrates: bitrates), folder.appendingPathComponent(ShareFiles.capture))
    }

    /// A segment closed: its marker is written, the ladder hears of the outbox's backlog (before the next segment
    /// opens), and the outbox of the segment.
    private func closed(_ seg: OggSegment) {
        segments = seg.n
        do {
            try ShareFiles.mark(folder, n: seg.n, granule: seg.granule, bitrate: seg.bitrate)
        } catch {
            failed = true
            return
        }
        self.outbox.ladder.segmentClosed(backlogSeconds: ShareFiles.backlogSeconds(root: self.outbox.root))
        let outbox = self.outbox
        Task.detached(priority: .utility) { await outbox.poke() }
    }

    /// Ends the capture: the last segment and `end.json`; or nothing kept, when sharing went off,
    /// or a failed or cancelled session is shorter than `minimumPartial` with no segment gone.
    func finish(completed: Bool) {
        guard let writer, !failed, Contributions.isActive, writer.duration > 0,
              completed || writer.duration >= Self.minimumPartial || segments > 0 else { return abandon() }
        do {
            let ms = try writer.finish()
            try ShareFiles.write(ShareFiles.End(durationMs: ms, completed: completed), folder.appendingPathComponent(ShareFiles.end))
        } catch {
            return abandon()
        }
        release()
        Contributions.noteShared()
        let outbox = self.outbox
        Task.detached(priority: .utility) { await outbox.poke() }
    }

    func abandon() {
        writer?.abandon()
        writer = nil
        failed = true
        // segments already handed over stay with the outbox only while sharing is on
        if segments == 0 || !Contributions.isActive {
            try? FileManager.default.removeItem(at: folder)
        } else {
            ShareFiles.recover(folder)
        }
        release()
        let outbox = self.outbox
        Task.detached(priority: .utility) { await outbox.poke() }
    }

    private func release() {
        let id = self.id
        Self.active.withLock { _ = $0.remove(id) }
    }
}
