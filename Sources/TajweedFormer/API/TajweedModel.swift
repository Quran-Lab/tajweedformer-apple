import Foundation

/// One verified model build on this device: its version, contexts, tokens, calibration and reference data and
/// sample clips. It holds the engine and, once promoted, the Neural Engine's build. Made by
/// `client.model()` (download, verify, open, warm) and by nothing else: a model comes from Quran Lab's server
/// through the Client, and no call opens a folder the app supplies (`TajweedModel.open(_:)` did, to 3.0.1).
///
/// A Model has one open Session at a time; a take is `listen()` or `session()`, and the next take is a new Session.
public final class TajweedModel: Sendable {
    private struct State {
        var folder: ModelFolder
        var recognizer: TajweedRecognizer?
        var recognizerKey = ""
        var reference: ModelReference?
        var open: UUID?
        var closed = false
        var bounds = TakeBounds.standard
    }

    private let state: Locked<State>
    /// The Client that made it (kept alive with it); nil for a folder the SDK's own tests opened.
    let client: TajweedClient?

    /// Internal: an app cannot make a Model from a folder. `client.model()` makes it from the Client's own download;
    /// the SDK's tests make one from a verified test folder.
    init(_ folder: ModelFolder, client: TajweedClient?) {
        state = Locked(State(folder: folder))
        self.client = client
    }

    var folder: ModelFolder { state.withLock { $0.folder } }

    /// The bounds of the takes this Model starts from here on (`TakeBounds.standard`; tests set small ones).
    func setBounds(_ bounds: TakeBounds) { state.withLock { $0.bounds = bounds } }

    // MARK: what the model is

    /// The model's id, `"v4.0"`.
    public var id: String { folder.manifest.modelID }
    /// The model's version, `"4.0.0"`.
    public var version: String { folder.version }
    /// The build id of this folder, for diagnostics only (a new CoreML build of the same weights is a new build of
    /// the same version).
    public var build: String { folder.build }
    /// The contexts the model can run (response time: `c8_l64` 160 ms, `c16_l64` 320 ms, `c24_*` 480 ms), the model's
    /// own default first.
    public var contexts: [String] { folder.contexts }
    /// The context a Session runs when its options name none: Quran Lab's config for this app, else the model's own.
    public var defaultContext: String { Self.defaultContext(folder) }

    /// The length of a chunk of `context`, in milliseconds.
    public func chunkMs(_ context: String) throws(TajweedError) -> Int {
        guard contexts.contains(context) else { throw .argument("context \(context) is not one of \(contexts.joined(separator: ", "))") }
        return TajweedRecognizer.chunkMs(context: context)
    }

    /// The vocabulary: token names and ids, the blank and the word bar.
    public var tokens: TajweedTokens { TajweedTokens(vocabulary: folder.vocabulary) }

    /// calibration.json as shipped: read-only data for an app's own judge. The SDK never applies it. Nil when the
    /// folder has none.
    public var calibration: TajweedCalibration? { TajweedCalibration(folder) }

    /// The expected units of each ayah, read-only data for an app's own judge; nil when this build ships none. The
    /// table is not part of the model's download: `reference.fetch()` brings it, once.
    public var reference: TajweedReference? {
        // a Model of a Client downloads the table through it; a folder a test opened has only what is in the folder
        var download: (@Sendable (ModelFolder, ModelManifest.File) async throws -> Void)?
        if client != nil { download = Self.fetchReference }
        let source = download
        let table: ModelReference? = state.withLock { (s: inout State) -> ModelReference? in
            if let r = s.reference { return r }
            guard let file = s.folder.referenceFile else { return nil }
            let r = ModelReference(folder: s.folder, file: file, download: source)
            s.reference = r
            return r
        }
        guard let table else { return nil }
        return TajweedReference(table: table)
    }

    /// Downloads one file of a model on the device through the Client's server client.
    private static func fetchReference(_ folder: ModelFolder, _ file: ModelManifest.File) async throws {
        guard let cloud = QuranLab.cloud else { throw RecognizerError.offline("the Client was closed") }
        try await cloud.updater.install(file, of: folder)
    }

    /// Short recitations to run without a microphone (`listen(from:)`): the folder's self-test clips, else the
    /// three clips the SDK carries.
    public var sampleClips: [TajweedClip] {
        let f = folder
        if f.verifiedFiles.contains("selftest/selftest.json"), let set = SelfTestSet.load(f.directory, context: f.manifest.defaultContext) {
            return set.clips.map { TajweedClip(name: $0.id, kind: $0.planted ? "planted" : "clean", samples: $0.samples) }
        }
        return ((try? SelfTestClips.load())?.clips ?? []).map { TajweedClip(name: $0.name, kind: "clean", samples: $0.samples) }
    }

    /// The Backend the next Session will use.
    public var backend: TajweedBackend {
        get async {
            guard let r = state.withLock({ $0.recognizer }) else { return .cpu }
            return await r.backendNext
        }
    }

    /// The Backend a Session with the default options would use now (the default context, `backend: .auto`): what
    /// `diagnose()` reports. A promoted build reads `promoted` from the stored promotion state, whatever Session
    /// the Model ran last. While the Model's engine is the default Session's, a promotion that is still running
    /// shows the stage it is at.
    func defaultBackend() async -> TajweedBackend {
        let f = folder
        let context = Self.defaultContext(f)
        let stored = TajweedClient.storedBackend(f, context: context)
        if stored.stage == .promoted { return stored }
        let mine = "\(f.directory.path)|\(context)|\(TajweedSessionOptions.Backend.auto.rawValue)|"
        let engine = state.withLock { (s: inout State) -> TajweedRecognizer? in s.recognizerKey.hasPrefix(mine) ? s.recognizer : nil }
        if let engine { return await engine.backendNext }
        return stored
    }

    // MARK: takes

    /// A Session fed by the SDK's microphone: asks for the permission, captures at the device's rate and carries
    /// that rate to the Session. Interruptions, route changes and the app leaving the foreground are handled and
    /// reported on `session.events`. Throws `microphone_denied` when the permission is refused. Nothing is captured
    /// before this call or after the take ends.
    public func listen(options: TajweedSessionOptions = TajweedSessionOptions()) async throws(TajweedError) -> TajweedSession {
        try await listen(options: options, device: Microphone())
    }

    /// The same path with no microphone: a Session fed by one of `sampleClips`, at real-time pace or (with
    /// `options.pace = .fast`) as fast as the engine takes it. The take ends with `ended(.sourceEnd)`.
    public func listen(from clip: TajweedClip, options: TajweedSessionOptions = TajweedSessionOptions()) async throws(TajweedError) -> TajweedSession {
        try await listen(from: clip.samples, sampleRate: TajweedClip.sampleRate, options: options)
    }

    /// The same with samples the app already has: mono, -1...1, at `sampleRate`.
    public func listen(from samples: [Float], sampleRate: Double,
                       options: TajweedSessionOptions = TajweedSessionOptions()) async throws(TajweedError) -> TajweedSession {
        try Self.check(sampleRate: sampleRate)
        let session = try await start(options, pushed: false)
        let source = ClipSource()
        session.attach(source)
        source.start(samples: samples, rate: sampleRate, pace: options.pace, session: session)
        return session
    }

    /// A Session the app pushes audio into (`session.push(_:)`), at `options.sampleRate`.
    public func session(options: TajweedSessionOptions = TajweedSessionOptions()) async throws(TajweedError) -> TajweedSession {
        try Self.check(sampleRate: options.sampleRate)
        return try await start(options, pushed: true)
    }

    /// Warms the engine for the Session these options describe, ahead of its first take. `client.model()` warms the
    /// default Session only; a Session with another context, other heads or another backend gets its own engine,
    /// which is otherwise made when its first take opens, too late for that take to start on the Neural Engine.
    /// Call this once with the options your takes use (their `context`, `heads` and `backend`; the other fields are
    /// not read): the context's files are fetched when they are not on the device yet, the CPU engine is built, and
    /// the call waits until the Neural Engine's build for these options is ready or will not be. It returns the
    /// Backend the next Session with the same options starts on: the accelerator where this device has one for
    /// them, else the CPU engine, with the stage and reason `backend` reports. Where no accelerator applies (an
    /// older system, a CPU-only context, `backend: .cpu`) it returns at once with the CPU engine. A second call with
    /// the same options finds the engine warm and does nothing more. A Session with other options is not covered
    /// by it: it gets its own engine as before.
    /// On a device that has not promoted the build yet, the wait includes the promotion (the build's download on an
    /// unmetered network, its compilation and its test, up to ten minutes); takes can run meanwhile on the CPU
    /// engine. While a Session is open the call throws `session_open`: it is for the time before a take.
    @discardableResult
    public func prepare(options: TajweedSessionOptions = TajweedSessionOptions()) async throws(TajweedError) -> TajweedBackend {
        let selection = try Self.selection(options.heads)
        let context = options.context ?? Self.defaultContext(folder)
        guard folder.manifest.contexts.contains(context) else {
            throw .argument("context \(context) is not one of \(folder.manifest.contexts.joined(separator: ", "))")
        }
        enum Standing { case closed, busy, free }
        let standing = state.withLock { (s: inout State) -> Standing in
            if s.closed { return .closed }
            return s.open != nil ? .busy : .free
        }
        switch standing {
        case .closed: throw TajweedError(.modelMissing, ["detail": "this TajweedModel was closed"])
        case .busy: throw TajweedError(.sessionOpen)
        case .free: break
        }
        do throws(RecognizerError) {
            let (r, _) = try await engine(context: context, backend: options.backend, selection: selection)
            // warm already (an earlier prepare, or takes with these options): nothing more to do
            let now = await r.backendNext
            if now.kind == .accelerator { return now }
            try await r.prepare()
            _ = await r.awaitReady(timeout: Self.prepareWait)
            return await r.backendNext
        } catch {
            throw TajweedError(from: error)
        }
    }

    /// The longest `prepare(options:)` waits for the Neural Engine's build (a first promotion downloads, compiles
    /// and tests it).
    static let prepareWait: TimeInterval = 600

    /// Releases the engine. An open Session is cancelled.
    public func close() async {
        let r = state.withLock { (s: inout State) -> TajweedRecognizer? in
            defer { s.recognizer = nil; s.closed = true }
            return s.recognizer
        }
        await r?.cancelTake()
        client?.forget(self)
    }

    // MARK: internals

    /// `listen()` with the device given (the SDK's microphone; a fake in tests).
    func listen(options: TajweedSessionOptions, device: any CaptureDevice) async throws(TajweedError) -> TajweedSession {
        guard await device.authorize() else { throw TajweedError(.microphoneDenied) }
        let session = try await start(options, pushed: false)
        do throws(RecognizerError) {
            try device.open(deliver: { samples, rate in session.feed(samples, rate: rate) },
                            notice: { n in session.notice(n) })
        } catch {
            await session.cancel()
            throw TajweedError(from: error)
        }
        session.attach(LiveCapture(device))
        return session
    }

    static func check(sampleRate: Double) throws(TajweedError) {
        guard Double(Int(sampleRate)) == sampleRate, SampleRateConverter.rates.contains(Int(sampleRate)) else {
            let rates = SampleRateConverter.rates.sorted().map(String.init).joined(separator: ", ")
            throw .argument("sample rate \(sampleRate) Hz; the SDK takes \(rates) Hz")
        }
    }

    /// `endOnSilenceMs` is off (nil or 0) or 500 to 60000.
    static func check(endOnSilenceMs ms: Int?) throws(TajweedError) {
        let range = SpeechTracker.windowRangeMs
        if let ms, ms != 0, !range.contains(ms) {
            throw .argument("endOnSilenceMs \(ms) is not \(range.lowerBound) to \(range.upperBound) (0 or nil turns it off)")
        }
    }

    /// The context in force when the app names none: the signed config's `inference.context` when the model has it,
    /// else the manifest's default.
    static func defaultContext(_ folder: ModelFolder) -> String {
        let config = QuranLab.cloud?.currentConfig?.inferenceContext
        if let config, folder.manifest.contexts.contains(config) { return config }
        return folder.manifest.defaultContext
    }

    private func release(_ token: UUID) {
        state.withLock { if $0.open == token { $0.open = nil } }
    }

    /// The heads a Session's options name: every name a head of the model, and at least one.
    static func selection(_ heads: [String]) throws(TajweedError) -> Set<HeadID> {
        var selection = Set<HeadID>()
        for name in heads {
            guard let h = HeadID(rawValue: name) else { throw .argument("\(name) is not a head of the model") }
            selection.insert(h)
        }
        guard !selection.isEmpty else { throw .argument("heads is empty: name at least one head") }
        return selection
    }

    /// The engine for a context, backend choice and heads, with the folder it runs from: the context's files are
    /// fetched first when they are not on the device yet (another context's files come on first use, into the same
    /// folder).
    private func engine(context: String, backend: TajweedSessionOptions.Backend,
                        selection: Set<HeadID>) async throws(RecognizerError) -> (TajweedRecognizer, ModelFolder) {
        var f = folder
        if !f.isUsable(context: context) {
            guard client != nil else { throw RecognizerError.modelMissing("the files of \(context) are not in the folder") }
            f = try await ModelFolder.load(f.id, sources: [.cache, .cdn], context: context)
            let fetched = f
            state.withLock { (s: inout State) in
                s.folder = fetched
                s.recognizer = nil
                s.reference = nil
            }
        }
        return (try recognizer(f, context: context, backend: backend, selection: selection), f)
    }

    /// Warms the engine for the default Session (the first take then starts at once).
    func warm() async throws(TajweedError) {
        let f = folder
        let context = Self.defaultContext(f)
        guard f.isUsable(context: context) else { return }
        let selection = Set(TajweedSessionOptions.defaultHeads.compactMap { HeadID(rawValue: $0) })
        do throws(RecognizerError) {
            let r = try recognizer(f, context: context, backend: .auto, selection: selection)
            try await r.prepare()
        } catch {
            throw TajweedError(from: error)
        }
    }

    /// The CoreML build a Session's `backend` names: the compact one for `coremlCompact`; nil when it names none (the
    /// Session then gets the fp16 build).
    static func namedCompact(_ backend: TajweedSessionOptions.Backend) -> Bool? { backend == .coremlCompact ? true : nil }

    /// The recognizer for a context, backend choice and head selection: the one the Model holds when it matches, else
    /// a new one in its place (one engine at a time).
    private func recognizer(_ folder: ModelFolder, context: String, backend: TajweedSessionOptions.Backend,
                            selection: Set<HeadID>) throws(RecognizerError) -> TajweedRecognizer {
        let key = "\(folder.directory.path)|\(context)|\(backend.rawValue)|" + selection.map(\.rawValue).sorted().joined(separator: ",")
        if let r = state.withLock({ (s: inout State) -> TajweedRecognizer? in s.recognizerKey == key ? s.recognizer : nil }) { return r }
        // the old engine goes before the new one opens
        state.withLock { $0.recognizer = nil }
        let r = try TajweedRecognizer(model: folder, context: context, backend: backend == .cpu ? .exact : .automatic,
                                      heads: HeadSelection(selection), compact: Self.namedCompact(backend))
        state.withLock { (s: inout State) in
            s.recognizer = r
            s.recognizerKey = key
        }
        return r
    }

    /// Starts a take: checks the options, claims the Model's one open Session, fetches the context's files when they
    /// are not on disk yet, and opens the take on the engine.
    private func start(_ options: TajweedSessionOptions, pushed: Bool) async throws(TajweedError) -> TajweedSession {
        let selection = try Self.selection(options.heads)
        guard (0...38).contains(options.topK) else { throw .argument("topK \(options.topK) is not 0 to 38") }
        try Self.check(endOnSilenceMs: options.endOnSilenceMs)
        let token = UUID()
        enum Claim { case closed, busy, claimed }
        let claim = state.withLock { (s: inout State) -> Claim in
            if s.closed { return .closed }
            if s.open != nil { return .busy }
            s.open = token
            return .claimed
        }
        switch claim {
        case .closed: throw TajweedError(.modelMissing, ["detail": "this TajweedModel was closed"])
        case .busy: throw TajweedError(.sessionOpen)
        case .claimed: break
        }
        do throws(TajweedError) {
            return try await open(options, selection: selection, pushed: pushed, token: token)
        } catch {
            release(token)
            throw error
        }
    }

    private func open(_ options: TajweedSessionOptions, selection: Set<HeadID>, pushed: Bool,
                      token: UUID) async throws(TajweedError) -> TajweedSession {
        let known = folder
        let context = options.context ?? Self.defaultContext(known)
        guard known.manifest.contexts.contains(context) else {
            throw .argument("context \(context) is not one of \(known.manifest.contexts.joined(separator: ", "))")
        }
        do throws(RecognizerError) {
            let (r, f) = try await engine(context: context, backend: options.backend, selection: selection)
            try await r.startTake()
            let backend = await r.backendNow
            let bounds = state.withLock { $0.bounds }
            return TajweedSession(recognizer: r, vocabulary: f.vocabulary, selection: selection, options: options, backend: backend,
                                  pushed: pushed, bounds: bounds, onEnd: { [weak self] in self?.release(token) })
        } catch {
            throw TajweedError(from: error)
        }
    }
}

/// The model's vocabulary (tokens.txt).
public struct TajweedTokens: Sendable, Hashable {
    let vocabulary: Vocabulary

    public var count: Int { vocabulary.count }
    /// The id of the CTC blank (0).
    public var blank: Int { vocabulary.blank }
    /// The id of the word bar `|`, or nil when the vocabulary has none.
    public var wordBar: Int? { vocabulary.symbols.firstIndex(of: "|") }
    /// The name of a token id; `"?"` outside the vocabulary.
    public func name(_ id: Int) -> String { vocabulary.symbol(id) }
    /// The id of a token name.
    public func id(_ name: String) -> Int? { vocabulary.symbols.firstIndex(of: name) }
}

/// calibration.json exactly as the model ships it (format `quranlab.tajweed-calibration/1`): the thresholds and
/// weights Quran Lab measured for this model, for an app's own judge. The SDK reads none of it.
public struct TajweedCalibration: Sendable, Hashable {
    /// The file's bytes as shipped.
    public let data: Data
    /// The file's SHA-256 from the signed manifest (lower-case hex).
    public let sha256: String
    let root: JSONValue

    init?(_ folder: ModelFolder) {
        guard folder.verifiedFiles.contains("calibration.json"),
              let data = try? Data(contentsOf: folder.directory.appendingPathComponent("calibration.json")),
              let root = JSONValue(data: data) else { return nil }
        self.data = data
        self.root = root
        sha256 = folder.manifest.file(local: "calibration.json")?.localSHA256 ?? ""
    }

    public var format: String { root["format"]?.string ?? "" }
    public var modelID: String { root["model_id"]?.string ?? "" }
    /// The SHA-256 of the tokens.txt the numbers belong to.
    public var tokensSHA256: String { root["tokens_sha256"]?.string ?? "" }
    public var defaultContext: String { root["default_context"]?.string ?? "" }
    public var defaultPreset: String { root["default_preset"]?.string ?? "" }
    public var contexts: [String] { (root["contexts"]?.object.map { Array($0.keys) } ?? []).sorted() }
    /// The site classes (`vowel_sub`, `cons_sub`, ...).
    public var classes: [String] { root["classes"]?.array?.compactMap(\.string) ?? [] }
    /// The preset names (`strict`, `balanced`, `sensitive`, `very_sensitive`).
    public var presets: [String] { (root["presets"]?.object.map { Array($0.keys) } ?? []).sorted() }

    /// The threshold in nats of a site class at a preset: `contexts.<context>.sites.<class>.thresholds.<preset>`.
    public func threshold(context: String, class cls: String, preset: String) -> Double? {
        number("contexts", context, "sites", cls, "thresholds", preset)
    }

    /// `validated`, `experimental` or `off` for a site class: `contexts.<context>.sites.<class>.status`.
    public func status(context: String, class cls: String) -> String? {
        string("contexts", context, "sites", cls, "status")
    }

    /// The fusion weight `a` of a class (its own, else the context's default): `contexts.<context>.fusion.a`.
    public func fusionWeight(context: String, class cls: String) -> Double? {
        number("contexts", context, "fusion", "a", cls) ?? number("contexts", context, "fusion", "a", "default")
    }

    /// Any number of the file by its path of keys, for the fields without an accessor (`madd.cuts`, `qalqalah.tau`,
    /// `gemination.tau`, `word`): `number("contexts", "c16_l64", "qalqalah", "tau")`.
    public func number(_ path: String...) -> Double? { value(path)?.number }

    /// Any string of the file by its path of keys.
    public func string(_ path: String...) -> String? { value(path)?.string }

    private func value(_ path: [String]) -> JSONValue? {
        var v: JSONValue? = root
        for k in path { v = v?[k] }
        return v
    }
}

/// The expected units of each ayah, as data: a lookup by surah and ayah. The SDK never aligns them, never compares
/// them with a take and never reads them itself.
public struct TajweedReference: Sendable {
    let table: any ReferenceTable

    /// Whether the table is on this device.
    public var isDownloaded: Bool { table.isDownloaded }

    /// Downloads and verifies the table, once. Later calls return at once.
    public func fetch() async throws(TajweedError) { try await table.fetch() }

    /// The unit ids of an ayah and the index of the first unit of each word. Throws `reference_missing` before
    /// `fetch()`, and `invalid_argument` for a surah or ayah that does not exist.
    public func units(surah: Int, ayah: Int) throws(TajweedError) -> (units: [Int], wordStarts: [Int]) {
        try table.units(surah: surah, ayah: ayah)
    }
}

/// Where a Model's reference table comes from.
protocol ReferenceTable: Sendable {
    var isDownloaded: Bool { get }
    func fetch() async throws(TajweedError)
    func units(surah: Int, ayah: Int) throws(TajweedError) -> (units: [Int], wordStarts: [Int])
}

/// A short recitation that ships with the model, for running without a microphone.
public struct TajweedClip: Sendable, Hashable {
    static let sampleRate = 16_000.0

    public let name: String
    /// `clean`, or `planted` for a clip with a deliberate mistake in it.
    public let kind: String
    let samples: [Float]

    public var durationMs: Int { Int((Double(samples.count) / Self.sampleRate * 1000).rounded()) }
}

/// Feeds a clip or samples into a take in pieces of 100 ms, then ends it.
final class ClipSource: SessionSource {
    private let task = Locked<Task<Void, Never>?>(nil)

    func start(samples: [Float], rate: Double, pace: TajweedSessionOptions.Pace, session: TajweedSession) {
        let t = Task.detached(priority: .userInitiated) {
            let piece = max(1, Int(rate / 10))
            let began = Date()
            var at = 0
            while at < samples.count, !Task.isCancelled {
                let end = min(samples.count, at + piece)
                session.feed(Array(samples[at..<end]), rate: rate)
                at = end
                if pace == .realTime {
                    // the wall clock catches up with the audio handed over
                    let ahead = Double(at) / rate - Date().timeIntervalSince(began)
                    if ahead > 0 { try? await Task.sleep(nanoseconds: UInt64(ahead * 1_000_000_000)) }
                }
            }
            if !Task.isCancelled { session.end(.sourceEnd) }
        }
        task.withLock { $0 = t }
    }

    func stop() {
        task.withLock { (t: inout Task<Void, Never>?) in
            t?.cancel()
            t = nil
        }
    }
}

