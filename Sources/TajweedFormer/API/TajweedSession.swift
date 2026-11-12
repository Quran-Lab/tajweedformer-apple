import Foundation

/// How a Session runs. Every field has a default; `TajweedSessionOptions()` is the quick start's.
public struct TajweedSessionOptions: Sendable, Hashable {
    public enum Backend: String, Sendable, Hashable {
        /// The CPU engine first, then the Neural Engine once its build is promoted. The build is the fp16 CoreML
        /// build (`coreml`).
        case auto
        /// The CPU engine only.
        case cpu
        /// As `auto`, with the compact CoreML build (`coreml-compact`: int8 weights, a much smaller download, for
        /// devices short of storage) in place of the fp16 one. A device fetches and tries that build only when it is
        /// named here, never on its own; where it is not promoted, the Session runs on the CPU engine.
        case coremlCompact = "coreml-compact"
    }

    public enum Pace: String, Sendable, Hashable {
        /// A clip or samples arrive as fast as a microphone would give them.
        case realTime
        /// As fast as the engine takes them.
        case fast
    }

    /// The model context (response time). Nil: the config's `inference.context`, then the model's default.
    public var context: String?
    /// The rate of pushed audio (`model.session()` only). `listen` sets it from the microphone or the clip.
    public var sampleRate: Double
    /// The heads each chunk and the take's Heads hold: head names, `defaultHeads` or `allHeads`.
    public var heads: [String]
    public var backend: Backend
    /// When above 0, every frame of the decoded layer carries its K best tokens (1 to the token count).
    public var topK: Int
    /// When set, the take finishes after that much silence following speech (`ended(.silence)`): 500 to 60000;
    /// nil or 0 is off, the default. Silence is what the model hears as silence, and a held vowel is not silence. In a
    /// noisy room a take may not end on silence, so keep a Stop control; values under 1000 can end a take in a
    /// breath pause between two words.
    public var endOnSilenceMs: Int?
    /// `listen(from:)` only.
    public var pace: Pace

    /// The six heads a Session hands out when nothing else is asked for.
    public static let defaultHeads = ["log_probs", "inter1_log_probs", "timing_log_probs", "gem", "attr_qalqalah", "conf"]
    /// Every head of the network.
    public static let allHeads = ["log_probs", "inter1_log_probs", "inter4_log_probs", "id_log_probs", "timing_log_probs", "gem",
                                  "attr_tafkheem", "attr_ghunna", "attr_qalqalah", "attr_face", "boundary", "conf"]

    public init(context: String? = nil, sampleRate: Double = 16_000, heads: [String] = TajweedSessionOptions.defaultHeads,
                backend: Backend = .auto, topK: Int = 0, endOnSilenceMs: Int? = nil, pace: Pace = .realTime) {
        self.context = context
        self.sampleRate = sampleRate
        self.heads = heads
        self.backend = backend
        self.topK = topK
        self.endOnSilenceMs = endOnSilenceMs
        self.pace = pace
    }
}

/// The bounds of a take, the same in the four SDKs (NAMING.md, "Bounds"): one constant per number.
struct TakeBounds: Sendable, Hashable {
    /// The most audio a take holds, in seconds at the input rate (counted in input samples). At the limit the take
    /// ends by itself with `ended(.limit)`.
    var takeSeconds: Double = 1200
    /// The most chunks that wait for the app to read them. When full, the oldest waiting one is dropped: `decoded` is
    /// cumulative, the last chunk is the newest, and `finish()` returns the whole take.
    var waitingChunks = 256
    /// The most events that wait for the app. `ended` is the newest and is never the one dropped.
    var waitingEvents = 64

    static let standard = TakeBounds()

    /// Chunks dropped because the app did not read `chunks`, since the Client was made (`diagnose().droppedChunks`).
    static let droppedChunks = Locked(0)
}

/// One take: audio in, chunks and events out, the take's Heads at the end. There are two ways to get one:
/// `model.listen()` (the SDK captures) and `model.session()` (the app pushes audio).
///
///     let session = try await model.listen()
///     for await chunk in session.chunks { label.text = chunk.decoded.text }
///
/// A Session is one take. The next take is a new Session from the same Model, which keeps the engine loaded.
public final class TajweedSession: Sendable {
    /// Each chunk as it is ready. The stream ends when the take ends. At most 256 chunks wait to be read: when the
    /// app reads late, the oldest waiting ones are dropped (each chunk's `decoded` is the take so far, and `finish()`
    /// returns the whole take, so nothing is lost with them).
    public let chunks: AsyncStream<TajweedChunk>
    /// What happened to the take (speech, interruptions, a change of Backend, the end). Ends with the take. At most
    /// 64 events wait to be read; the oldest waiting ones are dropped, never `ended`.
    public let events: AsyncStream<TajweedEvent>

    private let core: SessionCore
    private let input: AsyncStream<SessionInput>.Continuation
    private let pump: Task<Void, Never>
    private let pushed: Bool
    private let rate: Double
    private let shared: SessionShared

    init(recognizer: TajweedRecognizer, vocabulary: Vocabulary, selection: Set<HeadID>, options: TajweedSessionOptions,
         backend: TajweedBackend, pushed: Bool, bounds: TakeBounds = .standard, onEnd: @escaping @Sendable () -> Void) {
        let (chunks, chunkOut) = AsyncStream<TajweedChunk>.makeStream(bufferingPolicy: .bufferingNewest(max(1, bounds.waitingChunks)))
        let (events, eventOut) = AsyncStream<TajweedEvent>.makeStream(bufferingPolicy: .bufferingNewest(max(1, bounds.waitingEvents)))
        // what waits here is audio the take has admitted, so at most `bounds.takeSeconds` of it (and the few events
        // of the source)
        let (inputs, input) = AsyncStream<SessionInput>.makeStream()
        self.chunks = chunks
        self.events = events
        self.input = input
        self.pushed = pushed
        rate = options.sampleRate
        let shared = SessionShared(backend: backend, takeSeconds: bounds.takeSeconds)
        self.shared = shared
        let core = SessionCore(recognizer: recognizer, vocabulary: vocabulary, selection: selection, topK: options.topK,
                               endOnSilenceMs: options.endOnSilenceMs, backend: backend, chunkOut: chunkOut, eventOut: eventOut,
                               shared: shared, onEnd: onEnd)
        self.core = core
        pump = Task { for await i in inputs { await core.handle(i) } }
    }

    /// Audio in: mono samples in -1...1 at the Session's `sampleRate`. Only on a Session made with
    /// `model.session()`. It returns at once and keeps the order; chunks arrive on `chunks`. A take holds at most 20
    /// minutes of audio: the samples up to that limit are taken, the take then ends by itself (`ended(.limit)`), and a
    /// later push throws `session_closed`.
    public func push(_ samples: [Float]) throws(TajweedError) {
        guard pushed else { throw .argument("push is for a Session made with model.session(); listen() feeds this one") }
        guard admit(samples, rate: rate) else { throw TajweedError(.sessionClosed) }
    }

    /// Audio into the take, as far as the take still holds it; at its limit the take ends. False when the take has
    /// ended or is full.
    private func admit(_ samples: [Float], rate: Double) -> Bool {
        guard let a = shared.admit(samples.count, rate: rate) else { return false }
        if a.count > 0 { input.yield(.audio(a.count == samples.count ? samples : Array(samples[0..<a.count]), rate)) }
        if a.full { end(.limit) }
        return true
    }

    /// Ends the take and returns its Heads. On a `listen` Session it also stops the microphone. After a take that
    /// ended by itself (an `ended` event) it returns that take's Heads; after `cancel()` it throws `cancelled`.
    @discardableResult
    public func finish() async throws(TajweedError) -> TajweedHeads {
        shared.stopSource()
        input.yield(.finish)
        input.finish()
        await pump.value
        return try await core.result()
    }

    /// Ends the take and keeps nothing.
    public func cancel() async {
        shared.stopSource()
        await core.cancel()
        input.finish()
    }

    /// The Backend in force for this take.
    public var backend: TajweedBackend { shared.backend }

    /// Where the learner recited in this take, for the app's analytics on sdk.quranlab.ai: counted into the ayahs
    /// per surah, never sent with a recording. One report per take: before the take ends a later call replaces an
    /// earlier one and the report is counted when the take ends with its Heads; after such a take has ended the first
    /// call is counted at once. A take that was cancelled or failed counts none.
    public func reportRecited(surah: Int, ayahFrom: Int, ayahTo: Int) throws(TajweedError) {
        let range = try Self.recited(surah: surah, ayahFrom: ayahFrom, ayahTo: ayahTo)
        if let r = shared.report(range) {
            QuranLab.reportRecited(surah: r.surah, ayahFrom: r.ayahFrom, ayahTo: r.ayahTo)
        }
    }

    /// A report the SDK takes: 1 <= surah <= 114 and 1 <= ayahFrom <= ayahTo <= the surah's ayah count. Anything
    /// else is `invalid_argument` and changes nothing.
    static func recited(surah: Int, ayahFrom: Int, ayahTo: Int) throws(TajweedError) -> SessionShared.Recited {
        guard (1...114).contains(surah) else { throw .argument("surah \(surah) is not 1 to 114") }
        let count = QuranIndex.ayahs[surah - 1]
        guard ayahFrom >= 1, ayahFrom <= ayahTo, ayahTo <= count else {
            throw .argument("ayahs \(ayahFrom) to \(ayahTo) are not inside surah \(surah) (1 to \(count))")
        }
        return SessionShared.Recited(surah: surah, ayahFrom: ayahFrom, ayahTo: ayahTo)
    }

    // MARK: internal feeds (listen)

    /// Audio from the SDK's own source (the microphone or a clip), with the rate it has now.
    func feed(_ samples: [Float], rate: Double) {
        _ = admit(samples, rate: rate)
    }

    /// An event of the source (an interruption, its end).
    func note(_ event: TajweedEvent) { input.yield(.event(event)) }

    /// The source ended the take (the clip ran out, the app left the foreground, an interruption that cannot resume).
    func end(_ reason: TajweedEvent.EndReason) {
        shared.stopSource()
        input.yield(.end(reason))
    }

    /// What the microphone reports during a `listen` take, as the take's events.
    func notice(_ n: CaptureNotice) {
        switch n {
        case .interruptionBegan: note(.interrupted(.interruption))
        case .interruptionEnded(let canResume):
            if canResume { note(.resumed) } else { end(.interrupted) }
        case .routeChanged: note(.interrupted(.routeChange))
        case .background: end(.background)
        case .failed(let why): end(.error(TajweedError(.microphoneUnavailable, ["detail": why])))
        }
    }

    /// The source of a `listen` Session: stopped when the take ends, however it ends.
    func attach(_ source: any SessionSource) { shared.attach(source) }

    /// Whether the take has ended.
    var hasEnded: Bool { shared.ended }
}

/// What feeds a `listen` Session and has to stop with it.
protocol SessionSource: AnyObject, Sendable {
    func stop()
}

/// The ayah counts of the 114 surahs (the validation of `reportRecited`).
enum QuranIndex {
    static let ayahs: [Int] = [
        7, 286, 200, 176, 120, 165, 206, 75, 129, 109, 123, 111, 43, 52, 99, 128, 111, 110, 98, 135, 112, 78, 118, 64, 77, 227, 93, 88,
        69, 60, 34, 30, 73, 54, 45, 83, 182, 88, 75, 85, 54, 53, 89, 59, 37, 35, 38, 29, 18, 45, 60, 49, 62, 55, 78, 96, 29, 22, 24, 13,
        14, 11, 11, 18, 12, 12, 30, 52, 52, 44, 28, 28, 20, 56, 40, 31, 50, 40, 46, 42, 29, 19, 36, 25, 22, 17, 19, 26, 30, 20, 15, 21,
        11, 8, 8, 19, 5, 8, 8, 11, 11, 8, 3, 9, 5, 4, 7, 3, 6, 3, 5, 4, 5, 6,
    ]
}

/// The few values of a take that are read outside its actor: whether it ended, its Backend, its source, the
/// recited range.
final class SessionShared: @unchecked Sendable {
    struct Recited: Sendable, Equatable {
        let surah: Int
        let ayahFrom: Int
        let ayahTo: Int
    }

    private let lock = NSLock()
    private var _ended = false
    /// The most audio the take holds, seconds; the input samples admitted so far, per input rate (Hz); and whether
    /// they fill the take.
    private let takeSeconds: Double
    private var admitted: [Int: Int] = [:]
    private var full = false
    private var _backend: TajweedBackend
    private var source: (any SessionSource)?
    private var _recited: Recited?
    /// Whether the take ended with its Heads (nil while it is open), and whether its report was counted.
    private var endedCounting: Bool?
    private var counted = false

    init(backend: TajweedBackend, takeSeconds: Double = TakeBounds.standard.takeSeconds) {
        _backend = backend
        self.takeSeconds = takeSeconds
    }

    /// How many of `count` samples at `rate` the take still holds (its limit is counted in input samples), and whether
    /// they fill it. Nil once the take has ended or is full.
    func admit(_ count: Int, rate: Double) -> (count: Int, full: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard !_ended, !full else { return nil }
        let r = max(1, Int(rate.rounded()))
        // audio at another rate earlier in the take (the input device changed) counts by its duration
        var other = 0.0
        for (k, n) in admitted where k != r { other += Double(n) / Double(k) }
        let room = Int(((takeSeconds - other) * Double(r)).rounded(.down)) - (admitted[r] ?? 0)
        let take = max(0, min(count, room))
        admitted[r, default: 0] += take
        if take >= room { full = true }
        return (take, full)
    }

    var ended: Bool { lock.lock(); defer { lock.unlock() }; return _ended }
    var backend: TajweedBackend { lock.lock(); defer { lock.unlock() }; return _backend }

    func setBackend(_ b: TajweedBackend) { lock.lock(); _backend = b; lock.unlock() }
    /// A valid report of the app: kept while the take is open; the report to count now when the take already ended
    /// with its Heads and none was counted for it.
    func report(_ r: Recited) -> Recited? {
        lock.lock()
        defer { lock.unlock() }
        guard !counted else { return nil }
        guard let ended = endedCounting else {
            _recited = r
            return nil
        }
        guard ended else { return nil }
        counted = true
        return r
    }

    /// The take ended: the report to count, when it ended with its Heads and the app made one.
    func takeEnded(counts: Bool) -> Recited? {
        lock.lock()
        defer { lock.unlock() }
        guard endedCounting == nil else { return nil }
        endedCounting = counts
        guard counts, let r = _recited else { return nil }
        counted = true
        return r
    }

    func attach(_ s: any SessionSource) {
        lock.lock()
        let late = _ended
        if !late { source = s }
        lock.unlock()
        if late { s.stop() }
    }

    func stopSource() {
        lock.lock()
        let s = source
        source = nil
        lock.unlock()
        s?.stop()
    }

    func markEnded() {
        lock.lock()
        _ended = true
        lock.unlock()
        stopSource()
    }
}

enum SessionInput: Sendable {
    case audio([Float], Double)
    case event(TajweedEvent)
    case end(TajweedEvent.EndReason)
    case finish
}

/// The take behind a Session: everything that changes it runs here, in the order it was asked for.
actor SessionCore {
    enum Phase {
        case open
        case closing
        case ended(TajweedHeads)
        case failed(TajweedError)
        case cancelled
    }

    private let recognizer: TajweedRecognizer
    private let vocabulary: Vocabulary
    private let selection: Set<HeadID>
    private let topK: Int
    private let endOnSilence: Bool
    private let chunkOut: AsyncStream<TajweedChunk>.Continuation
    private let eventOut: AsyncStream<TajweedEvent>.Continuation
    private let shared: SessionShared
    private let onEnd: @Sendable () -> Void
    private var phase = Phase.open
    /// The 40 ms frames of each chunk handed out, by chunk index.
    private var frameCounts: [Int] = []
    /// Which of those frames are active, by chunk index (8 or 12 values a chunk, for at most 20 minutes of audio).
    private var activity: [[Bool]] = []
    private var backend: TajweedBackend
    private var speech: SpeechTracker

    init(recognizer: TajweedRecognizer, vocabulary: Vocabulary, selection: Set<HeadID>, topK: Int, endOnSilenceMs: Int?,
         backend: TajweedBackend, chunkOut: AsyncStream<TajweedChunk>.Continuation,
         eventOut: AsyncStream<TajweedEvent>.Continuation, shared: SessionShared, onEnd: @escaping @Sendable () -> Void) {
        self.recognizer = recognizer
        self.vocabulary = vocabulary
        self.selection = selection
        self.topK = topK
        endOnSilence = (endOnSilenceMs ?? 0) > 0
        self.backend = backend
        self.chunkOut = chunkOut
        self.eventOut = eventOut
        self.shared = shared
        self.onEnd = onEnd
        speech = SpeechTracker(windowMs: (endOnSilenceMs ?? 0) > 0 ? endOnSilenceMs! : SpeechTracker.defaultWindowMs)
    }

    private var isOpen: Bool {
        if case .open = phase { return true }
        return false
    }

    func handle(_ input: SessionInput) async {
        switch input {
        case .audio(let samples, let rate): await audio(samples, rate)
        case .event(let e): if isOpen { eventOut.yield(e) }
        case .end(let reason): await close(reason)
        case .finish: await close(nil)
        }
    }

    private func audio(_ samples: [Float], _ rate: Double) async {
        guard isOpen, !samples.isEmpty else { return }
        let step: TajweedRecognizer.Step
        do throws(RecognizerError) {
            step = try await recognizer.step(samples, sampleRate: rate, topK: topK)
        } catch {
            await fail(TajweedError(from: error))
            return
        }
        guard isOpen else { return }
        if let last = emit(step, final: false) { await closeOnSilence(at: last) }
    }

    /// Hands out the chunks of a step, each with the decoded layer of the take up to it. With `endOnSilenceMs`, the
    /// chunk that carries the frame at which speech ended is the take's last: it is handed out whole and final, the
    /// chunks after it are not, and its index is returned.
    private func emit(_ step: TajweedRecognizer.Step, final: Bool) -> Int? {
        guard !step.chunks.isEmpty, step.decoded.count == step.chunks.count else { return nil }
        let now = step.backend ?? backend
        if let replaced = step.chunks.first(where: { $0.replaces })?.index {
            // a failover replaced the chunks from here on: they come again, and the speech state is rebuilt from the
            // chunks that stay
            if replaced < frameCounts.count { frameCounts.removeLast(frameCounts.count - replaced) }
            if replaced < activity.count { activity.removeLast(activity.count - replaced) }
            speech.reset()
            var frame = 0
            for kept in activity {
                _ = speech.feed(kept, firstFrame: frame)
                frame += kept.count
            }
            eventOut.yield(.backendChanged(backend: now, fromChunk: replaced))
        } else if now.kind != backend.kind {
            eventOut.yield(.backendChanged(backend: now, fromChunk: step.chunks[0].index))
        }
        backend = now
        shared.setBackend(now)
        for (n, raw) in step.chunks.enumerated() {
            if raw.index < frameCounts.count { frameCounts.removeLast(frameCounts.count - raw.index) }
            if raw.index < activity.count { activity.removeLast(activity.count - raw.index) }
            let first = frameCounts.reduce(0, +)
            let frames = raw.heads.n40
            frameCounts.append(frames)
            let layer = step.decoded[n]
            // the chunk's active frames, from log_probs and the timing head; a chunk that came without them is read
            // from the decoded layer's log_probs alone
            var active = raw.active
            if active.count != frames {
                let lo = min(first, layer.frames.count), hi = min(first + frames, layer.frames.count)
                let blank = vocabulary.blank
                active = layer.frames[lo..<hi].map { $0.top1 != blank }
            }
            activity.append(active)
            let heard = speech.feed(active, firstFrame: first)
            var silence = false
            for e in heard.events {
                eventOut.yield(e)
                if case .speechEnded = e, endOnSilence, !final {
                    // the take ends here: no event follows, also when the chunk's later frames hold speech again
                    silence = true
                    break
                }
            }
            let isLast = silence || (final && n == step.chunks.count - 1)
            let chunk = TajweedChunk(index: raw.index, startMs: raw.startMs, endMs: raw.startMs + frames * SpeechTracker.frameMs,
                                     firstFrame: first, backend: now, speech: heard.speech,
                                     heads: TajweedHeads(raw.heads, vocabulary: vocabulary, selection: selection),
                                     decoded: TajweedDecoded(layer, isFinal: isLast, topK: topK))
            // the app reads late: the oldest waiting chunk made room for this one
            if case .dropped = chunkOut.yield(chunk) { TakeBounds.droppedChunks.withLock { $0 += 1 } }
            if silence { return raw.index }
        }
        return nil
    }

    /// The end of the take: the flush's chunks (the last one final), then the streams end.
    private func close(_ reason: TajweedEvent.EndReason?) async {
        guard isOpen else { return }
        phase = .closing
        do throws(RecognizerError) {
            let step = try await recognizer.finishStep(topK: topK)
            guard case .closing = phase else { return }
            _ = emit(step, final: true)
            ended(step.take, reason: reason, heard: !(step.decoded.last?.tokens.isEmpty ?? true))
        } catch {
            guard case .closing = phase else { return }
            let e = TajweedError(from: error)
            phase = .failed(e)
            _ = shared.takeEnded(counts: false)
            eventOut.yield(.ended(.error(e)))
            finishStreams()
        }
    }

    /// The take ended on silence at chunk `index`: that chunk was its last, and nothing after it is decoded.
    private func closeOnSilence(at index: Int) async {
        phase = .closing
        let take = await recognizer.finish(atChunk: index)
        guard case .closing = phase else { return }
        ended(take, reason: .silence, heard: true)
    }

    /// A take that ended with its Heads: the app's recited range is counted, and it is a moment the SDK may ask
    /// about sharing (only after a take in which the model heard something).
    private func ended(_ take: HeadsBuffer, reason: TajweedEvent.EndReason?, heard: Bool) {
        phase = .ended(TajweedHeads(take, vocabulary: vocabulary, selection: selection, topK: topK, isFinal: true))
        if let reason { eventOut.yield(.ended(reason)) }
        if let r = shared.takeEnded(counts: true) { QuranLab.reportRecited(surah: r.surah, ayahFrom: r.ayahFrom, ayahTo: r.ayahTo) }
        if heard { Contributions.sessionCompleted(feedback: true) }
        finishStreams()
    }

    private func fail(_ e: TajweedError) async {
        guard isOpen else { return }
        phase = .failed(e)
        _ = shared.takeEnded(counts: false)
        await recognizer.cancelTake()
        eventOut.yield(.ended(.error(e)))
        finishStreams()
    }

    func cancel() async {
        switch phase {
        case .open, .closing: break
        default: return
        }
        phase = .cancelled
        _ = shared.takeEnded(counts: false)
        await recognizer.cancelTake()
        finishStreams()
    }

    /// The take's Heads once it ended; the error it ended with otherwise.
    func result() throws(TajweedError) -> TajweedHeads {
        switch phase {
        case .ended(let heads): return heads
        case .failed(let e): throw e
        case .cancelled: throw TajweedError(.cancelled)
        case .open, .closing: throw TajweedError(.sessionClosed)
        }
    }

    private func finishStreams() {
        chunkOut.finish()
        eventOut.finish()
        shared.markEnded()
        onEnd()
    }
}
extension TajweedRecognizer {
    /// What one piece of audio (or the end of the take) added: the new chunks, for each of them the decoded layer of
    /// the take up to it, the Backend that ran them (only when there are chunks), and at the end the take's heads.
    struct Step: Sendable {
        let chunks: [RawChunk]
        let decoded: [DecodedTake]
        let backend: TajweedBackend?
        let take: HeadsBuffer
    }

    func step(_ samples: [Float], sampleRate: Double, topK: Int) throws(RecognizerError) -> Step {
        let chunks = try append(samples, sampleRate: sampleRate)
        if chunks.isEmpty { return Step(chunks: [], decoded: [], backend: nil, take: HeadsBuffer()) }
        return Step(chunks: chunks, decoded: try layers(chunks, topK), backend: backendNow, take: HeadsBuffer())
    }

    func finishStep(topK: Int) async throws(RecognizerError) -> Step {
        let take = try await finish()
        return Step(chunks: lastFlush, decoded: try layers(lastFlush, topK), backend: backendNow, take: take)
    }

    /// The decoded layer of the take up to each of `chunks`: the whole take so far for the newest, the take cut after
    /// the chunk for the ones a single call completed before it.
    private func layers(_ chunks: [RawChunk], _ topK: Int) throws(RecognizerError) -> [DecodedTake] {
        var out: [DecodedTake] = []
        for c in chunks {
            if c.index >= takeChunkFrames.count - 1 {
                out.append(topK > 0 ? try decoded(topK: topK) : decoded())
            } else {
                var h = take
                h.truncate(n40: takeChunkFrames.prefix(c.index + 1).reduce(0, +))
                var d = DecodedTake(heads: h, vocabulary: model.vocabulary)
                d.ranked = try? TajweedRanking.rank(h.logProbs, head: .logProbs, k: max(2, topK), names: model.vocabulary.symbols)
                out.append(d)
            }
        }
        return out
    }

    /// The Backend the next take will run on: the Neural Engine's build once it is promoted and warm.
    var backendNext: TajweedBackend {
        let now = backendNow
        guard now.stage == .promoted else { return TajweedBackend(kind: .cpu, name: "cpu", stage: now.stage, reason: now.reason) }
        return TajweedBackend(kind: .accelerator, name: acceleratorBuildName, stage: .promoted, reason: nil)
    }

    /// The build key of the Neural Engine's build this recognizer promotes and runs: the pipeline's (`coreml` or
    /// `coreml-compact`), which may differ from what the folder held when it was opened (the pipeline replaces the
    /// build on disk when the app asks for the other one). Without a pipeline (a build forced in a debug build), the
    /// build in the folder.
    var acceleratorBuildName: String {
        if let controller = acceleratorController { return controller.env.build }
        return (model.coreML(context: context)?.compact ?? compact) ? "coreml-compact" : "coreml"
    }

    /// The Backend in force and where the Neural Engine's promotion stands.
    var backendNow: TajweedBackend {
        let onAccelerator = activeBackend == .neuralEngine
        let controller = acceleratorController
        var stage = TajweedBackend.Stage.cpu
        var reason: String?
        switch acceleratorState {
        case .cpu: stage = .cpu
        case .preparing:
            switch controller?.record?.completed {
            case nil: stage = .downloading
            case .download?: stage = .compiling
            default: stage = .testing
            }
        case .ready: stage = .promoted
        case .disabled:
            if let controller {
                stage = .demoted
                reason = controller.record?.lastReason?.rawValue ?? "other"
            }
        }
        return TajweedBackend(kind: onAccelerator ? .accelerator : .cpu, name: onAccelerator ? acceleratorBuildName : "cpu",
                              stage: stage, reason: reason)
    }
}
