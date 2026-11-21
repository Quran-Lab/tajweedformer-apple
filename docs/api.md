# TajweedFormer for iOS and macOS: the public API

Generated from the sources by `scripts/make_api_doc.py`; a test fails when a public declaration is missing
here. The names are those of the four TajweedFormer SDKs. Start with the README's quick start.

| Type | What it is |
|---|---|
| [`TajweedClient`](#tajweedclient) | The app's link to Quran Lab: the key, the signed config, registration, telemetry, issues, sharing and the model files on disk. |
| [`TajweedClientOptions`](#tajweedclientoptions) | What a Client may be told besides its key. |
| [`TajweedModel`](#tajweedmodel) | One verified model build on this device: its version, contexts, tokens, calibration and reference data and sample clips. |
| [`TajweedSession`](#tajweedsession) | One take: audio in, chunks and events out, the take's Heads at the end. |
| [`TajweedSessionOptions`](#tajweedsessionoptions) | How a Session runs. |
| [`TajweedHeads`](#tajweedheads) | Raw model output for a span of audio (a chunk, or the whole take from `finish()`): every selected head, and greedy tokens. |
| [`TajweedBackend`](#tajweedbackend) | What ran or will run the model: the CPU engine or the Neural Engine's build, and where the promotion stands. |
| [`TajweedChunk`](#tajweedchunk) | One chunk of a take as it streams. |
| [`TajweedDecoded`](#tajweeddecoded) | The decoded layer: what the model heard in the take so far, ready to show. |
| [`TajweedToken`](#tajweedtoken) | A token the model heard: a run of frames with the same non-blank top token. |
| [`TajweedWord`](#tajweedword) | The tokens between two word bars. |
| [`TajweedFrame`](#tajweedframe) | One 40 ms frame of `log_probs`: the top token, the runner-up and their margin. |
| [`TajweedHead`](#tajweedhead) | One raw head of the network for a span of audio: `frames` rows of `classes` values, row major. |
| [`TajweedEvent`](#tajweedevent) | What happened to a take, on `session.events`. |
| [`TajweedTokens`](#tajweedtokens) | The model's vocabulary (tokens.txt). |
| [`TajweedCalibration`](#tajweedcalibration) | calibration.json exactly as the model ships it (format `quranlab.tajweed-calibration/1`): the thresholds and weights Quran Lab measured for this model, for an app's own judge. |
| [`TajweedReference`](#tajweedreference) | The expected units of each ayah, as data: a lookup by surah and ayah. |
| [`TajweedClip`](#tajweedclip) | A short recitation that ships with the model, for running without a microphone. |
| [`TajweedSharing`](#tajweedsharing) | Sharing recitations with Quran Lab, reached through `client.sharing`. |
| [`TajweedAnalytics`](#tajweedanalytics) | Counters the app reports about its own judge. |
| [`TajweedDiagnosis`](#tajweeddiagnosis) | `client.diagnose()`: where the SDK stands. |
| [`TajweedError`](#tajweederror) | Everything the SDK throws. |
| [`Microphone`](#microphone) | The SDK's microphone, through AVAudioEngine. |
| [`SharingConsentView`](#sharingconsentview) | The consent sheet: why sharing helps, what is shared, who receives it, how to stop, and two buttons of equal weight. |
| [`SharingConsentViewController`](#sharingconsentviewcontroller) | UIKit: the consent sheet in a view controller, for an app that presents it itself. |
| [`SharingConsentViewControllerMac`](#sharingconsentviewcontrollermac) | AppKit: the consent sheet in a view controller (present it as a sheet of the app's window). |
| [`SharingSettingsView`](#sharingsettingsview) | The sharing settings: the switch, "What is shared", "Delete what I shared" (with its confirmation), and the learner's recovery code for a lost device (revealed on tap, shown only here). |
| [`SharingSettingsViewController`](#sharingsettingsviewcontroller) | UIKit: the sharing settings in a view controller. |
| [`SharingSettingsViewControllerMac`](#sharingsettingsviewcontrollermac) | AppKit: the sharing settings in a view controller. |
| [`SharingThanksView`](#sharingthanksview) | The thank-you line with its du'a, and (when the server answers) the learner's real shared minutes. |
| [`SharingTheme`](#sharingtheme) | How the SDK's sharing views look in the app: colours, corner radius and fonts. |
| [`TajweedRecitedOutcome`](#tajweedrecitedoutcome) | The app's own judgement of an ayah or a range: correct, or incorrect with how many mistakes and which rules. |
| [`View`](#view) |  |

## TajweedClient

```swift
public final class TajweedClient: Sendable
```

The app's link to Quran Lab: the key, the signed config, registration, telemetry, issues, sharing and the model files on disk. Make one at launch with the app's key from sdk.quranlab.ai and keep it: One per process: a second one while the first is not closed throws `client_exists`. Nothing in the recognition path waits on the network once the model is on the device. Making the Client downloads no model: the model downloads only when the app calls `model()` or `prefetch()` (a later start checks only for an update of a build this Client installed on this device). A model comes only from Quran Lab's server, through the Client (3.1.0): the key, the signed config, the SDK's own download and its verification. No call takes a model folder, and a Client opens only a build it downloaded itself on this device.

- `public let sharing: TajweedSharing`: Sharing recitations with Quran Lab: whether Quran Lab's switch has it on, the learner's choice, the outbox.
- `public let analytics: TajweedAnalytics`: Counters the app reports itself.
- `public convenience init(key: String, options: TajweedClientOptions = TajweedClientOptions()) throws(TajweedError)`: - Parameter key: the app's key from sdk.quranlab.ai (`qlk_v1_...`), for this app's bundle id.
- `public func close()`: Ends the Client: its network calls and upload queue stop, and another Client can be made. Models made by it stay usable for takes that are open.
- `public func model(version: String? = nil) async throws(TajweedError) -> TajweedModel`: The Model for this app: downloaded on first use (the CPU files of the default context, verified), opened, and warmed so the first take starts at once. Later calls return the same Model. Call it early for a warm start. `version` pins a model version (`"4.0.0"`): the config request names it, and Quran Lab answers that version's build for this SDK, or its normal choice when it has none. Nil takes the version Quran Lab's config names. A first run without a network throws `needs_connection`; `model_unavailable` when Quran Lab has no build for this SDK version yet. When Quran Lab has refused the key or the app (`invalid_key`, or `server_rejected` with its reason), no model is opened and the downloaded model is removed from the device; once the server accepts the key again the model is downloaded again. A Model that was open before the refusal keeps running until the app closes it.
- `public func prefetch(unmeteredOnly: Bool = false, onProgress: (@Sendable (_ done: Int64, _ total: Int64) -> Void)? = nil) async throws(TajweedError)`: Downloads and verifies the model ahead of use. Resumable: a download that stopped goes on where it stopped. With `unmeteredOnly` it follows the connection `diagnose()` reports: it downloads on `unmetered` (Wi-Fi, Ethernet) and on `unknown`, and does nothing on `metered` (cellular, a personal hotspot, Low Data Mode) and on `none`; call it again later. A no-op when the model is on the device. `onProgress` gets the bytes done and the total of the files to download, as they arrive.
- `public var storage: TajweedDiagnosis.Storage`: What the SDK holds on disk: the bytes of each model build, ordered by version then build, and the bytes of the sharing queue. The same object as `diagnose().storage`.
- `public func removeModels() throws(TajweedError)`: Removes the model files (the next `model()` downloads them again). The learner's sharing choice and the upload queue stay.
- `public static func isBackgroundSession(_ identifier: String) -> Bool`: Whether a background URLSession identifier is one of the SDK's (they start with `ai.quranlab.`). For the app delegate, and for SwiftUI's `.backgroundTask(.urlSession(matching:))`.
- `public static func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool`: Forward the app delegate's `application(_:handleEventsForBackgroundURLSession:completionHandler:)` here. The SDK's transfers go on while the app is suspended; when they are done the system starts the app in the background and hands it this completion handler, which the SDK calls once its session has delivered everything. It may be called before the app has made its Client: the handler then waits for the Client, and is called in any case after a short while, so the system is always answered. Returns false, and does not call `completionHandler`, when the session is not the SDK's (pass it to its owner then). An app that does not forward loses nothing: the transfers finish all the same, and the SDK collects their results when the Client is next made. The handler is taken as the system declares it (not marked `@Sendable`), so an app delegate passes it on as it is in any language mode; the SDK calls it once, on the main queue.
- `public static func backgroundEvents(identifier: String) async`: The same for SwiftUI (iOS 16): returns when the SDK's background session `identifier` has delivered its events, at once when the session is not the SDK's. On the app's scene:
- `public func background()`: The app left the foreground. iOS and macOS apps need not call it: the SDK follows the system's notifications. For hosts without them (an extension, a command-line tool).
- `public func foreground()`: The app returned to the foreground (see `background()`).
- `public func diagnose() async -> TajweedDiagnosis`: One structured report of where the SDK stands, safe to paste into an issue: no audio, no text, no identifiers.

## TajweedClientOptions

```swift
public struct TajweedClientOptions: Sendable
```

What a Client may be told besides its key. Every field has a default. SDK 4.0: there is no analytics option. Anonymous analytics (daily counts and durations only, never audio, text, names or device identifiers) are always on; Quran Lab's signed config (`flags.analytics`) is the only off switch. SDK 4.0: there is no audience option. Every app shows the same sharing sheet, every learner is asked under the same rules, and the choice is the learner's.

- `public var appId: String?`: The app's id; nil reads the bundle identifier.
- `public var appVersion: String?`: The app's version; nil reads the bundle's short version (`CFBundleShortVersionString`).
- `public var appBuild: String?`: The app's build number (SDK 4.0.1); nil reads the bundle's `CFBundleVersion`. It goes, with the version, on the config request only (`app_build`, contract section 27), so Quran Lab can give an app's releases the model each was built for, by the rules its developer sets on sdk.quranlab.ai.
- `public var storage: URL?`: Where the SDK keeps models and its queues; nil means `Application Support/QuranLab` (on macOS `Application Support/<bundle id>/QuranLab`). The folder is the SDK's to fill: a model found there that this Client did not download itself on this device is not opened; it is deleted and downloaded.
- `public init(appId: String? = nil, appVersion: String? = nil, appBuild: String? = nil, storage: URL? = nil)`

## TajweedModel

```swift
public final class TajweedModel: Sendable
```

One verified model build on this device: its version, contexts, tokens, calibration and reference data and sample clips. It holds the engine and, once promoted, the Neural Engine's build. Made by `client.model()` (download, verify, open, warm) and by nothing else: a model comes from Quran Lab's server through the Client, and no call opens a folder the app supplies (`TajweedModel.open(_:)` did, to 3.0.1). A Model has one open Session at a time; a take is `listen()` or `session()`, and the next take is a new Session.

- `public var id: String`: The model's id, `"v4.0"`.
- `public var version: String`: The model's version, `"4.0.0"`.
- `public var build: String`: The build id of this folder, for diagnostics only (a new CoreML build of the same weights is a new build of the same version).
- `public var contexts: [String]`: The contexts the model can run (response time: `c8_l64` 160 ms, `c16_l64` 320 ms, `c24_*` 480 ms), the model's own default first.
- `public var defaultContext: String`: The context a Session runs when its options name none: Quran Lab's config for this app, else the model's own.
- `public func chunkMs(_ context: String) throws(TajweedError) -> Int`: The length of a chunk of `context`, in milliseconds.
- `public var tokens: TajweedTokens`: The vocabulary: token names and ids, the blank and the word bar.
- `public var calibration: TajweedCalibration?`: calibration.json as shipped: read-only data for an app's own judge. The SDK never applies it. Nil when the folder has none.
- `public var reference: TajweedReference?`: The expected units of each ayah, read-only data for an app's own judge; nil when this build ships none. The table is not part of the model's download: `reference.fetch()` brings it, once. SDK 4.0: the table is encrypted and only the Core reads it, at the first `units` call after the model opened (it needs the lease then).
- `public var sampleClips: [TajweedClip]`: Short recitations to run without a microphone (`listen(from:)`): the folder's self-test clips, else the three clips the SDK carries.
- `public var backend: TajweedBackend`: The Backend the next Session will use.
- `public func listen(options: TajweedSessionOptions = TajweedSessionOptions()) async throws(TajweedError) -> TajweedSession`: A Session fed by the SDK's microphone: asks for the permission, captures at the device's rate and carries that rate to the Session. Interruptions, route changes and the app leaving the foreground are handled and reported on `session.events`. Throws `microphone_denied` when the permission is refused. Nothing is captured before this call or after the take ends.
- `public func listen(from clip: TajweedClip, options: TajweedSessionOptions = TajweedSessionOptions()) async throws(TajweedError) -> TajweedSession`: The same path with no microphone: a Session fed by one of `sampleClips`, at real-time pace or (with `options.pace = .fast`) as fast as the engine takes it. The take ends with `ended(.sourceEnd)`.
- `public func listen(from samples: [Float], sampleRate: Double, options: TajweedSessionOptions = TajweedSessionOptions()) async throws(TajweedError) -> TajweedSession`: The same with samples the app already has: mono, -1...1, at `sampleRate`.
- `public func session(options: TajweedSessionOptions = TajweedSessionOptions()) async throws(TajweedError) -> TajweedSession`: A Session the app pushes audio into (`session.push(_:)`), at `options.sampleRate`.
- `public func prepare(options: TajweedSessionOptions = TajweedSessionOptions()) async throws(TajweedError) -> TajweedBackend`: Warms the engine for the Session these options describe, ahead of its first take. `client.model()` warms the default Session only; a Session with another context, other heads or another backend gets its own engine, which is otherwise made when its first take opens, too late for that take to start on the Neural Engine. Call this once with the options your takes use (their `context`, `heads` and `backend`; the other fields are not read): the context's files are fetched when they are not on the device yet, the CPU engine is built, and the call waits until the Neural Engine's build for these options is ready or will not be. It returns the Backend the next Session with the same options starts on: the accelerator where this device has one for them, else the CPU engine, with the stage and reason `backend` reports. Where no accelerator applies (an older system, a CPU-only context, `backend: .cpu`) it returns at once with the CPU engine. A second call with the same options finds the engine warm and does nothing more. A Session with other options is not covered by it: it gets its own engine as before. On a device that has not promoted the build yet, the wait includes the promotion (the build's download on an unmetered network, its compilation and its test, up to ten minutes); takes can run meanwhile on the CPU engine. While a Session is open the call throws `session_open`: it is for the time before a take.
- `public func close() async`: Releases the engine. An open Session is cancelled.
- `public func prepareAccelerator(context: String? = nil, again: Bool = false, timeout: Double = 300) async throws(TajweedError) -> TajweedBackend`: Prepares the Neural Engine's build for `context` (nil: the default context) now and waits for it (4.0.0, as Apple 3.1.5): the download on an unmetered network, the compile, the test against the CPU engine, then the build loaded and warm, so the next Session with `backend: .auto` runs on it from its first chunk. A build promoted at an earlier launch is loaded and warmed again (no test). `again: true` first forgets this device's verdict on the build (a failure, a demotion, a promotion) and prepares it from the start: the way to ask for it again after a failure. The preparation also runs by itself in the background (the first `.auto` engine of a launch starts it after the first take or 20 s without one); a process that ends during it simply goes on with it at a later launch. Call this when the app needs the Neural Engine at a known point, or when its takes name `backend: .cpu` (an engine for `.cpu` alone never prepares the Neural Engine). Returns `backend` as it stands when the build is ready, the preparation stopped (`demoted` with a reason, or `cpu` while it waits for an unmetered network, power or a backoff), or `timeout` seconds passed; after a timeout the preparation goes on in the background. Throws `session_open` while a Session is open. Never needed for correctness: the CPU engine serves every take.

## TajweedSession

```swift
public final class TajweedSession: Sendable
```

One take: audio in, chunks and events out, the take's Heads at the end. There are two ways to get one: `model.listen()` (the SDK captures) and `model.session()` (the app pushes audio). A Session is one take. The next take is a new Session from the same Model, which keeps the engine loaded.

- `public let chunks: AsyncStream<TajweedChunk>`: Each chunk as it is ready. The stream ends when the take ends. At most 256 chunks wait to be read: when the app reads late, the oldest waiting ones are dropped (each chunk's `decoded` is the take so far, and `finish()` returns the whole take, so nothing is lost with them).
- `public let events: AsyncStream<TajweedEvent>`: What happened to the take (speech, interruptions, a change of Backend, the end). Ends with the take. At most 64 events wait to be read; the oldest waiting ones are dropped, never `ended`.
- `public func push(_ samples: [Float]) throws(TajweedError)`: Audio in: mono samples in -1...1 at the Session's `sampleRate`. Only on a Session made with `model.session()`. It returns at once and keeps the order; chunks arrive on `chunks`. A take holds at most 20 minutes of audio: the samples up to that limit are taken, the take then ends by itself (`ended(.limit)`), and a later push throws `session_closed`.
- `public func finish() async throws(TajweedError) -> TajweedHeads`: Ends the take and returns its Heads. On a `listen` Session it also stops the microphone. After a take that ended by itself (an `ended` event) it returns that take's Heads; after `cancel()` it throws `cancelled`.
- `public func cancel() async`: Ends the take and keeps nothing.
- `public var backend: TajweedBackend`: The Backend in force for this take.
- `public func reportRecited(surah: Int, ayahFrom: Int, ayahTo: Int, outcome: TajweedRecitedOutcome? = nil, perAyah: [Int: TajweedRecitedOutcome] = [:]) throws(TajweedError)`: Where the learner recited in this take, and optionally whether the app's own judge found it correct, for the app's statistics on sdk.quranlab.ai. The SDK counts the ayat of each take by itself; where it could not tell, it uses this report for that take, and a take is never counted twice. `outcome` applies to every ayah of the range that `perAyah` does not name; neither given, the take is reported as recited and judged nothing (17.9). These numbers are the app's own judgement: the SDK does not judge a recitation. One report per take: a later call replaces an earlier one; it is used when the take ends with its Heads, or at once when that take has already ended. A take that was cancelled or failed counts none. Anything outside the rules (a surah or ayah out of range, a `perAyah` ayah outside the range, mistakes outside 1 to 1000, more than 8 rules, a rule id that is not `^[a-z][a-z0-9_]{0,23}$`) is `invalid_argument` and nothing is sent.

## TajweedSessionOptions

```swift
public struct TajweedSessionOptions: Sendable, Hashable
```

How a Session runs. Every field has a default; `TajweedSessionOptions()` is the quick start's.

- `public var context: String?`: The model context (response time). Nil: the config's `inference.context`, then the model's default.
- `public var sampleRate: Double`: The rate of pushed audio (`model.session()` only). `listen` sets it from the microphone or the clip.
- `public var heads: [String]`: The heads each chunk and the take's Heads hold: head names, `defaultHeads` or `allHeads`.
- `public var backend: Backend`
- `public var topK: Int`: When above 0, every frame of the decoded layer carries its K best tokens (1 to the token count).
- `public var endOnSilenceMs: Int?`: When set, the take finishes after that much silence following speech (`ended(.silence)`): 500 to 60000; nil or 0 is off, the default. Silence is what the model hears as silence, and a held vowel is not silence. In a noisy room a take may not end on silence, so keep a Stop control; values under 1000 can end a take in a breath pause between two words.
- `public var pace: Pace`: `listen(from:)` only.
- `public static let defaultHeads = ["log_probs", "inter1_log_probs", "timing_log_probs", "gem", "attr_qalqalah", "conf"]`: The six heads a Session hands out when nothing else is asked for.
- `public static let allHeads = ["log_probs", "inter1_log_probs", "inter4_log_probs", "id_log_probs", "timing_log_probs", "gem",`: Every head of the network.
- `public init(context: String? = nil, sampleRate: Double = 16_000, heads: [String] = TajweedSessionOptions.defaultHeads, backend: Backend = .auto, topK: Int = 0, endOnSilenceMs: Int? = nil, pace: Pace = .realTime)`

### TajweedSessionOptions.Backend

- `public enum Backend: String, Sendable, Hashable`
- `case auto`: The CPU engine first, then the Neural Engine once its build is promoted. The build is the fp16 CoreML build (`coreml`).
- `case cpu`: The CPU engine only.
- `case coremlCompact = "coreml-compact"`: As `auto`, with the compact CoreML build (`coreml-compact`: int8 weights, a much smaller download, for devices short of storage) in place of the fp16 one. A device fetches and tries that build only when it is named here, never on its own; where it is not promoted, the Session runs on the CPU engine.

### TajweedSessionOptions.Pace

- `public enum Pace: String, Sendable, Hashable`
- `case realTime`: A clip or samples arrive as fast as a microphone would give them.
- `case fast`: As fast as the engine takes them.

## TajweedHeads

```swift
public struct TajweedHeads: Sendable, Hashable
```

Raw model output for a span of audio (a chunk, or the whole take from `finish()`): every selected head, and greedy tokens. Plain data.

- `public var names: [String]`: The names of the heads it holds, in the network's order.
- `public subscript(name: String) -> TajweedHead?`: One raw head by its name; nil when these Heads do not hold it (it was not selected for the Session).
- `public func greedy(_ name: String = "log_probs") -> [TajweedToken]`: The greedy tokens of a CTC head: repeats merged, blank removed, with the times of each run. Empty for a head these Heads do not hold and for an attribute head.
- `public func decoded() -> TajweedDecoded`: The decoded layer of exactly these Heads (for the take's Heads from `finish()`: the final one). It needs `log_probs`, which every Session computes.

## TajweedBackend

```swift
public struct TajweedBackend: Sendable, Hashable, CustomStringConvertible
```

What ran or will run the model: the CPU engine or the Neural Engine's build, and where the promotion stands. Plain data, read from a Model, a Session or a chunk.

- `public let kind: Kind`
- `public let name: String`: `cpu`, `coreml` or `coreml-compact` (the build keys of the model's manifest).
- `public let stage: Stage`
- `public let reason: String?`: The stable reason code of a failed or demoted promotion (the codes of the incident reports), else nil.
- `public var description: String`

### TajweedBackend.Kind

- `public enum Kind: String, Sendable, Hashable`
- `case cpu`: The exact CPU engine: the same bits on every device.
- `case accelerator`: The CoreML build on the Neural Engine.

### TajweedBackend.Stage

- `public enum Stage: String, Sendable, Hashable`
- `case cpu`: No accelerator here, or its promotion has not started.
- `case downloading`
- `case compiling`
- `case testing`
- `case promoted`: The accelerator's build passed its tests: takes run on it.
- `case demoted`: The build failed a stage or a take and is set aside; the CPU engine serves.

## TajweedChunk

```swift
public struct TajweedChunk: Sendable, Hashable
```

One chunk of a take as it streams.

- `public let index: Int`: The chunk's number in the take, from 0. After a `backendChanged` event the chunks from its `fromChunk` on come again with the same indexes: replace what you kept for them.
- `public let startMs: Int`
- `public let endMs: Int`
- `public let firstFrame: Int`: The chunk's first 40 ms frame in the take.
- `public let backend: TajweedBackend`: The Backend that ran it.
- `public let speech: Bool`: True when the chunk holds speech frames.
- `public let heads: TajweedHeads`: The Heads of this chunk only.
- `public let decoded: TajweedDecoded`: The decoded layer of the take so far.

## TajweedDecoded

```swift
public struct TajweedDecoded: Sendable, Hashable
```

The decoded layer: what the model heard in the take so far, ready to show. No known text is involved.

- `public let text: String`: The token names joined by single spaces.
- `public let tokens: [TajweedToken]`
- `public let words: [TajweedWord]`
- `public let frames: [TajweedFrame]`
- `public let settled: Int`: How many leading tokens will not change in this take. It never decreases, except once after a `backendChanged` event that replaced chunks.
- `public let isFinal: Bool`: True on the last one of the take.

## TajweedToken

```swift
public struct TajweedToken: Sendable, Hashable
```

A token the model heard: a run of frames with the same non-blank top token.

- `public let id: Int`
- `public let name: String`: The token's name in the model's vocabulary.
- `public let firstMs: Int`: The start of the run's first frame, of its strongest frame and of its last frame, in milliseconds of the take.
- `public let peakMs: Int`
- `public let lastMs: Int`
- `public let confidence: Double?`: The mean of the `conf` head over the run, 0 to 1; nil where `conf` is not there (greedy tokens of a raw head).

## TajweedWord

```swift
public struct TajweedWord: Sendable, Hashable
```

The tokens between two word bars.

- `public let index: Int`
- `public let tokens: [Int]`: Indexes into the decoded layer's `tokens`.
- `public let text: String`: The token names joined by spaces.
- `public let firstMs: Int`
- `public let lastMs: Int`
- `public let confidence: Double?`: The lowest token confidence; nil without the `conf` head.

## TajweedFrame

```swift
public struct TajweedFrame: Sendable, Hashable
```

One 40 ms frame of `log_probs`: the top token, the runner-up and their margin.

- `public let top1: Int`
- `public let top1LogProb: Float`
- `public let runnerUp: Int`
- `public let runnerUpLogProb: Float`
- `public let margin: Double`: `top1LogProb - runnerUpLogProb`.
- `public let topK: [Int]`: With `topK` set on the Session: the K best token ids of the frame, best first, and their log-probabilities.
- `public let topKLogProbs: [Float]`

## TajweedHead

```swift
public struct TajweedHead: Sendable, Hashable
```

One raw head of the network for a span of audio: `frames` rows of `classes` values, row major.

- `public let name: String`: One of the twelve head names (`log_probs`, `inter1_log_probs`, ..., `conf`).
- `public let kind: Kind`
- `public let frameMs: Int`: Milliseconds per frame: 40 or 20.
- `public let frames: Int`
- `public let classes: Int`: Values per frame.
- `public let values: [Float]`: `frames * classes` values, frames first.

### TajweedHead.Kind

- `public enum Kind: String, Sendable, Hashable`
- `case ctc`: A CTC head over the model's tokens: log-probabilities, greedy tokens apply.
- `case attribute`: A per-frame attribute: class probabilities, or one logit (`boundary`, `conf`).

## TajweedEvent

```swift
public enum TajweedEvent: Sendable, Hashable
```

What happened to a take, on `session.events`.


### TajweedEvent.Cause

- `public enum Cause: String, Sendable, Hashable`
- `case interruption`: A call, or another app took the audio: the take is paused and no audio is read meanwhile.
- `case routeChange`: Headphones in or out, another input: the microphone was reopened and the take goes on.

### TajweedEvent.EndReason

- `public enum EndReason: Sendable, Hashable`
- `case silence`: `endOnSilenceMs` of silence after speech.
- `case background`: The app left the foreground.
- `case hidden`: The page lost visibility (the web SDK; never on Apple platforms).
- `case interrupted`: An interruption that cannot be resumed.
- `case sourceEnd`: The clip or the samples of `listen(from:)` ran out.
- `case limit`: The take reached 20 minutes of audio, the most a take holds.
- `case error(TajweedError)`

## TajweedTokens

```swift
public struct TajweedTokens: Sendable, Hashable
```

The model's vocabulary (tokens.txt).

- `public var count: Int`
- `public var blank: Int`: The id of the CTC blank (0).
- `public var wordBar: Int?`: The id of the word bar `|`, or nil when the vocabulary has none.
- `public func name(_ id: Int) -> String`: The name of a token id; `"?"` outside the vocabulary.
- `public func id(_ name: String) -> Int?`: The id of a token name.

## TajweedCalibration

```swift
public struct TajweedCalibration: Sendable, Hashable
```

calibration.json exactly as the model ships it (format `quranlab.tajweed-calibration/1`): the thresholds and weights Quran Lab measured for this model, for an app's own judge. The SDK reads none of it.

- `public let data: Data`: The file's bytes as shipped.
- `public let sha256: String`: The file's SHA-256 from the signed manifest (lower-case hex).
- `public var format: String`
- `public var modelID: String`
- `public var tokensSHA256: String`: The SHA-256 of the tokens.txt the numbers belong to.
- `public var defaultContext: String`
- `public var defaultPreset: String`
- `public var contexts: [String]`
- `public var classes: [String]`: The site classes (`vowel_sub`, `cons_sub`, ...).
- `public var presets: [String]`: The preset names (`strict`, `balanced`, `sensitive`, `very_sensitive`).
- `public func threshold(context: String, class cls: String, preset: String) -> Double?`: The threshold in nats of a site class at a preset: `contexts.<context>.sites.<class>.thresholds.<preset>`.
- `public func status(context: String, class cls: String) -> String?`: `validated`, `experimental` or `off` for a site class: `contexts.<context>.sites.<class>.status`.
- `public func fusionWeight(context: String, class cls: String) -> Double?`: The fusion weight `a` of a class (its own, else the context's default): `contexts.<context>.fusion.a`.
- `public func number(_ path: String...) -> Double?`: Any number of the file by its path of keys, for the fields without an accessor (`madd.cuts`, `qalqalah.tau`, `gemination.tau`, `word`): `number("contexts", "c16_l64", "qalqalah", "tau")`.
- `public func string(_ path: String...) -> String?`: Any string of the file by its path of keys.

## TajweedReference

```swift
public struct TajweedReference: Sendable
```

The expected units of each ayah, as data: a lookup by surah and ayah. The SDK never aligns them, never compares them with a take and never reads them itself.

- `public var isDownloaded: Bool`: Whether the table is on this device.
- `public func fetch() async throws(TajweedError)`: Downloads and verifies the table, once. Later calls return at once.
- `public func units(surah: Int, ayah: Int) throws(TajweedError) -> (units: [Int], wordStarts: [Int])`: The unit ids of an ayah and the index of the first unit of each word. Throws `reference_missing` before `fetch()`, and `invalid_argument` for a surah or ayah that does not exist.

## TajweedClip

```swift
public struct TajweedClip: Sendable, Hashable
```

A short recitation that ships with the model, for running without a microphone.

- `public let name: String`
- `public let kind: String`: `clean`, or `planted` for a clip with a deliberate mistake in it.
- `public var durationMs: Int`

## TajweedSharing

```swift
public final class TajweedSharing: Sendable
```

Sharing recitations with Quran Lab, reached through `client.sharing`. Every learner is asked, in every app, under the same rules, and the choice is theirs: "Not now", or a yes they can take back, and they can delete what they shared at any time. The developer switches nothing on or off; Quran Lab's signed config keeps an incident switch (`flags.contributions`) that stops all asking and sharing. The SDK asks with its own sheet at the end of a good take, and after "Not now" with a small card, at most three times per install; a yes is never asked again. Once the learner said yes, every take the SDK listens to is shared in full, and takes that follow one another within a few seconds are one recording. The SDK's sheet and settings view are `SharingConsentView`, `SharingSettingsView` and the view modifier `.quranLabSharing(_:)`; an app with its own settings screen uses the members here.

- `public var isAvailable: Bool`: Quran Lab's signed config has sharing on: its incident switch (`flags.contributions`) is on and this platform may upload. False until a verified config says so.
- `public var theme: SharingTheme`: The look of the sheets the SDK presents by itself: the ask at the end of a good take, `ask()`'s, and the card with the sheet it opens. Colours, corner radius and fonts only: the words, the structure and the consent version never change. The views and `.quranLabSharing()` take their own `theme` argument. Before 4.0 the SDK's own sheet always used `SharingTheme.standard` (the Flutter port, 11-18: an app's theme never reached it).
- `public var isOn: Bool`: The learner said yes.
- `public func setOn(_ on: Bool) async throws(TajweedError)`: The settings switch. On records the learner's yes; off stops uploads at once and deletes the unsent queue. Throws `sharing_unavailable` when turned on while Quran Lab's incident switch has sharing off (`isAvailable` is false); off always works, with one exception: when the device gives neither the learner's stored answer nor a place to write the off down, it throws `storage_failed`, and the SDK then records and uploads nothing more in this process. On throws `storage_failed`, and changes nothing, while the learner's stored answer cannot be read.
- `public func ask() -> Bool`: Asks now, at a point of the app's own flow, when an ask is due by the SDK's rules: the sheet the first time, a card after "Not now" (at most three asks per install, never after a yes or after sharing was turned off, never two in one app session or one day, the first not in the first 24 hours or before the 3rd completed take, a re-ask only 14 days and 7 completed takes after the last). Never at launch or during a take: only after a completed take in this app session and with no take open. True when the ask is due and goes on screen now; false, with nothing shown, when it is not due. The SDK also asks by itself at the end of a good take.
- `public func feed(_ samples: [Float], sampleRate: Double)`: Audio the app already captures outside takes (before the first, between them, after the last), mono at `sampleRate`. With sharing on and a yes, the SDK keeps the last second of it in memory and puts it in front of the next take's recording, and adds half a second after a take; otherwise it is dropped at once. The model never sees it. An app that uses `listen()` has no audio outside takes and need not call this.
- `public var items: [Item]`: The outbox: each recording and where its upload stands.
- `public func summary() async -> Summary?`: The learner's summary from Quran Lab's server; nil when the call fails (show nothing then).
- `public func delete() async throws(TajweedError)`: "Delete what I shared": every recording this learner shared from this app is deleted from Quran Lab's servers (signed with this device's key; no app credential can do it), the unsent queue is dropped, and sharing goes off.
- `public var recoveryCode: String?`: The code that deletes the learner's recordings when the device is lost; nil until the learner has shared. Show it only to the learner.
- `public func setWording(_ overrides: [String: String]?) throws(TajweedError)`: Replaces strings of the SDK's sharing copy with the app's own words, by the deck's keys; nil or empty goes back to the deck. A learner who agrees from then on agrees to these words. An unknown key or an empty text throws `invalid_argument` and nothing changes.

### TajweedSharing.Item

- `public struct Item: Sendable, Hashable, Identifiable`: One recording in the outbox.
- `public let id: String`: The recording's upload id.
- `public let day: String`: Its UTC day.
- `public let durationMs: Int`: Known once the recording has ended (0 before).
- `public let bytes: Int64`
- `public let status: String`: `queued` (recording, waiting or uploading), `uploaded` or `failed`.

### TajweedSharing.Summary

- `public struct Summary: Sendable, Hashable`: The learner's own shared minutes, this app's and Quran Lab's totals, and the line to show.
- `public let mySessions: Int`
- `public let myMinutes: Double`
- `public let appContributors: Int?`: Nil while the app has fewer than 10 contributors.
- `public let appMinutes: Double?`
- `public let allContributors: Int`
- `public let allMinutes: Double`
- `public let line: String`: The gratitude line of the copy deck with the learner's minutes, in the app's language.

## TajweedAnalytics

```swift
public final class TajweedAnalytics: Sendable
```

Counters the app reports about its own judge. Nothing is sent unless the app calls it.

- `public func reportChecks(rule: String, checked: Int, flagged: Int) throws(TajweedError)`: How many times the app's own judge checked a rule and how many of those it flagged, for the app's analytics on sdk.quranlab.ai. `rule` is lower-case letters, digits and underscores (use the calibration's class ids where they apply: `vowel_sub`, `madd`, `qalqalah`, `word`), 0 <= flagged <= checked <= 100000. Counts only: never text, audio, ids or times. At most 32 different rules a day are counted.

## TajweedDiagnosis

```swift
public struct TajweedDiagnosis: Sendable, Hashable
```

`client.diagnose()`: where the SDK stands. The same report, with the same fields, on the four SDKs.

- `public let sdkVersion: String`: This SDK's version, and the version of the newest release the signed config names (nil when it names none).
- `public let sdkLatest: String?`
- `public let key: Key`
- `public let config: String`: The signed config: `fresh` (a verified one that has not expired is in force), `stale` or `none`.
- `public let model: Model?`: Nil without a model on the device.
- `public let context: String?`: The context the next Session uses when the app names none; nil without a model.
- `public let backend: TajweedBackend?`: What runs now and where the promotion stands; nil without a model.
- `public let microphone: String`: The microphone permission: `granted`, `denied` or `notAsked`.
- `public let storage: Storage`
- `public let lastError: String?`: The catalogue code of the last error the SDK raised in this process.
- `public let droppedChunks: Int`: Chunks that waited unread on a Session's `chunks` and were dropped to make room (at most 256 wait), since the Client was made. Above 0, the app reads `chunks` late; the takes' Heads are whole all the same.
- `public let connection: String`: The device's connection: `unmetered` (Wi-Fi, Ethernet), `metered` (cellular, a personal hotspot, Low Data Mode), `none`, or `unknown` when the system does not say. `prefetch(unmeteredOnly:)` downloads on `unmetered` and `unknown`.
- `public var downloadProtocol: String?`: The protocol of the last model request that was answered for this Client in this process: `h3`, `h2` or `http/1.1`; nil when none was made yet or the system named none. Held in memory and sent in no telemetry. In `json` it is the optional key `downloadProtocol`, written after the eleven fields when it is known.
- `public var protected: Protected? = nil`: Nil before the protected model's runtime exists (no key configured).
- `public var endpoints: Endpoints? = nil`: SDK 4.0.1: nil without a key (no request is made to any host).
- `public var json: String`: The report as JSON, its eleven fields in the order every SDK writes them, for pasting; then `downloadProtocol` when one is known, (4.0) `protected`, and (4.0.1) `endpoints` after `protected` (28.7).

### TajweedDiagnosis.Key

- `public struct Key: Sendable, Hashable`
- `public let accepted: Bool?`: True, false, or nil while no answer from Quran Lab was seen.
- `public let reason: String?`: Only when `accepted` is false: `invalid_key`, `sdk_too_old` or `server_rejected`.

### TajweedDiagnosis.Model

- `public struct Model: Sendable, Hashable`
- `public let version: String`
- `public let build: String`
- `public let verified: Bool`

### TajweedDiagnosis.StoredModel

- `public struct StoredModel: Sendable, Hashable`: One model build on disk.
- `public let version: String`
- `public let build: String`
- `public let bytes: Int64`

### TajweedDiagnosis.Storage

- `public struct Storage: Sendable, Hashable`
- `public let models: [StoredModel]`: One entry per model build on disk, ordered by version then build.
- `public let sharingQueueBytes: Int64`

### TajweedDiagnosis.Protected

- `public struct Protected: Sendable, Hashable`: SDK 4.0, contract section 25 (`sdk_4.0.0/DIAGNOSIS_40.md`): the protected model as the Core holds it. Its fields in the section's order; no key, path or identifier.
- `public let keyStore: String?`: Where the install's agreement key lives: `secureEnclave`, `keychain` (a software key in the Keychain), or `file` where the Keychain refuses the process (a 0600 file in the storage folder; the Core then seals its state under a key of its release, 18.4.7, as C's `file`). Nil before the install has a key.
- `public let lease: String`: The state of the lease the Core holds, for support: `valid`, `grace` (the model opened while Quran Lab could not be reached, 18.4.7.1), `expired`, `stopped` or `none`. An app does not act on it: `client.model()` says what to do (`needs_connection`: the SDK needs Quran Lab to continue).
- `public let leaseExpires: Int64?`: A time of the lease the Core holds (unix seconds, its `exp`), for support; nil only when `lease` is `none`.
- `public let leaseClass: String?`: `attested` or `standard`, from the lease's flags (bit 3, 18.4.6: `attested` may use the Neural Engine); nil when `lease` is `none` or `stopped`.
- `public let refreshAfter: Int64?`: A time of the lease the Core holds (unix seconds, its `refresh_after`), for support; nil when `lease` is `none` or `stopped`.
- `public let graceUntil: Int64?`: A time the Core gives while `lease` is `grace` (unix seconds), for support; nil otherwise.
- `public let core: String?`: The Core's release and target (`qlc_version`); nil when the Core is not loaded.

### TajweedDiagnosis.Endpoints

- `public struct Endpoints: Sendable, Hashable`: SDK 4.0.1: the Quran Lab servers in use. If the main servers can't be reached, the SDK uses backup servers automatically; this says which one each kind of request uses now. Host names only: never a path, a query or a key.
- `public let api: String?`: The host the next API request goes to first.
- `public let models: String?`: The host the next model request goes to first.
- `public let lastFailover: Failover?`: The last request of this process that found its first host unreachable; nil when none did.

### TajweedDiagnosis.Failover

- `public struct Failover: Sendable, Hashable`: One request that found its first host unreachable (28.7 `lastFailover`).
- `public let role: String`: `api` or `models`.
- `public let from: String`: The host that did not answer.
- `public let to: String?`: The host that answered instead; nil when none did (every host of the list was unreachable, or the list had one host).
- `public let reason: String`: Why the first host was unreachable: `network` (no answer), `timeout`, `http` (a 5xx or another answer that was no answer of the route), `redirect` or `invalid_answer`.
- `public let status: Int?`: The first host's HTTP status, when it answered one.
- `public let at: Int64`: When, in unix seconds.

## TajweedError

```swift
public struct TajweedError: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError
```

Everything the SDK throws. One type on every platform, with the same four fields: `code` is a stable string (the same on Android, Apple, the web and C), `message` says what happened, `fix` is one sentence to act on, and `docs` links the code's entry on sdk.quranlab.ai. Compare `code`, never `message`.

- `public let code: String`: One of the 26 codes of the catalogue (`invalid_key`, `needs_connection`, `session_open`, ...).
- `public let message: String`
- `public let fix: String`: One sentence a developer can act on.
- `public let docs: String`: `https://sdk.quranlab.ai/docs/errors#<code>`.
- `public var description: String`
- `public var errorDescription: String?`
- `public var recoverySuggestion: String?`

## Microphone

```swift
public final class Microphone: @unchecked Sendable
```

The SDK's microphone, through AVAudioEngine. `model.listen()` uses it; an app that wants samples only uses it directly: The input runs at the hardware's rate (48 or 44.1 kHz on most devices) and that rate travels with the samples, so the Session converts it for the model itself and shared recordings keep the full band. Audio arrives in pieces of about 10 ms. - iOS: the audio session is set to record, with 10 ms I/O buffers. An interruption (a call, another app taking the audio) pauses capture until it ends; a route change (headphones in or out) reopens the input at its new rate; the app going to the background ends a `listen` take. - macOS: there is no audio session and no interruption. A change of the input device reopens the input at its new rate (the same event as a route change on iOS). A Mac app that is not frontmost is not suspended, so a `listen` take goes on until it is finished. The device's sample rate is a system-wide setting, so the SDK never changes it. A rate the engine's resampler does not take (96 or 88.2 kHz interfaces) is converted to 48 kHz first. Permission: the first use asks the user (the system's dialog, with the app's `NSMicrophoneUsageDescription`); a refusal is the error `microphone_denied`. A sandboxed or hardened Mac app also needs the `com.apple.security.device.audio-input` entitlement.

- `public init()`
- `public var sampleRate: Double`: The rate of the samples, in Hz: the device's own (48000 or 44100 on most), or 48000 where that is converted. 0 before the input is open. It can change when the input device changes.
- `public func samples() async throws(TajweedError) -> AsyncStream<[Float]>`: Asks for the permission when needed, opens the input and gives its samples: mono, -1...1, at `sampleRate`. The stream ends at `stop()`. Throws `microphone_denied` or `microphone_unavailable`. Read it as it comes: at most 256 buffers wait, and the oldest waiting one is dropped when the app reads late.
- `public func stop()`: Stops capture and releases the input.

## SharingConsentView

```swift
public struct SharingConsentView: View
```

The consent sheet: why sharing helps, what is shared, who receives it, how to stop, and two buttons of equal weight. Nothing is pre-ticked. Every app shows this same sheet (SDK 4.0, contract section 26), and the learner's tap is the answer.

- `public init(_ client: TajweedClient, reask: Bool = false, theme: SharingTheme = .standard, onDone: @escaping @MainActor (Bool) -> Void =`: - Parameters: - client: the app's Client. - reask: the gentler wording of a second or third ask. - onDone: called with the learner's answer once a button was tapped.
- `public var body: some View`

## SharingConsentViewController

```swift
public final class SharingConsentViewController: UIHostingController<SharingConsentView>
```

UIKit: the consent sheet in a view controller, for an app that presents it itself.

- `public init(_ client: TajweedClient, reask: Bool = false, theme: SharingTheme = .standard, onDone: @escaping @MainActor (Bool) -> Void =`

## SharingConsentViewControllerMac

```swift
public final class SharingConsentViewControllerMac: NSHostingController<SharingConsentView>
```

AppKit: the consent sheet in a view controller (present it as a sheet of the app's window).

- `public init(_ client: TajweedClient, reask: Bool = false, theme: SharingTheme = .standard, onDone: @escaping @MainActor (Bool) -> Void =`

## SharingSettingsView

```swift
public struct SharingSettingsView: View
```

The sharing settings: the switch, "What is shared", "Delete what I shared" (with its confirmation), and the learner's recovery code for a lost device (revealed on tap, shown only here). Works whatever Quran Lab's switch says, so a learner can always stop and delete.

- `public init(_ client: TajweedClient, theme: SharingTheme = .standard)`
- `public var body: some View`

## SharingSettingsViewController

```swift
public final class SharingSettingsViewController: UIHostingController<SharingSettingsView>
```

UIKit: the sharing settings in a view controller.

- `public init(_ client: TajweedClient, theme: SharingTheme = .standard)`

## SharingSettingsViewControllerMac

```swift
public final class SharingSettingsViewControllerMac: NSHostingController<SharingSettingsView>
```

AppKit: the sharing settings in a view controller.

- `public init(_ client: TajweedClient, theme: SharingTheme = .standard)`

## SharingThanksView

```swift
public struct SharingThanksView: View
```

The thank-you line with its du'a, and (when the server answers) the learner's real shared minutes.

- `public init(_ client: TajweedClient, theme: SharingTheme = .standard)`
- `public var body: some View`

## SharingTheme

```swift
public struct SharingTheme: Sendable
```

How the SDK's sharing views look in the app: colours, corner radius and fonts. The words are the deck's, and a theme never changes the sheet's structure or hides a line. `accent` fills the share button and the switch; the "Not now" button's fill, the emblem's and the hadith's (the accent at a few percent over the background) and the share button's label (white where white reads on the accent, else near black) are derived from it, and where the accent cannot be read on what is behind it (3 to 1, or 4.5 to 1 when the device asks for more contrast) the "Not now" label and the icons take the text colour. `background`, `text` and `secondaryText` left at their defaults give the sheet's own colours for light and dark; set, the cards, the dividers and the body text are mixed from them. `cornerRadius` is the buttons' (the cards', the emblem's and the sheet's radii scale with it). `titleFont` and `bodyFont` left at their defaults give the sheet's own type, which follows the system's text size.

- `public var accent: Color`
- `public var background: Color`
- `public var text: Color`
- `public var secondaryText: Color`
- `public var cornerRadius: CGFloat`
- `public var titleFont: Font`
- `public var bodyFont: Font`
- `public init(accent: Color = .accentColor, background: Color = Color.clear, text: Color = .primary, secondaryText: Color = .secondary, cornerRadius: CGFloat = 14, titleFont: Font = .title2.weight(.semibold), bodyFont: Font = .body)`
- `public static let standard = SharingTheme()`

## TajweedRecitedOutcome

```swift
public enum TajweedRecitedOutcome: Sendable, Hashable, Codable
```

The app's own judgement of an ayah or a range: correct, or incorrect with how many mistakes and which rules. The SDK only counts it; it never judges a recitation.

- `case correct`
- `case incorrect(mistakes: Int? = nil, rules: [String] = [])`: `mistakes` 1 to 1000 (nil adds none); `rules` at most 8 ids `^[a-z][a-z0-9_]{0,23}$`, the calibration's ids where they apply (`madd`, `qalqalah`). Each rule of an incorrect ayah adds 1 to the day's checks and flags of that rule: use this or `analytics.reportChecks` for a rule, not both.

## View

- `public func quranLabSharing(_ client: TajweedClient, theme: SharingTheme = .standard) -> some View`: Lets the SDK present its recitation-sharing sheet and thank-you on this view, at the right moments, in `theme` for the app's Client. Without it the SDK presents its sheet over the front view controller on iOS.
