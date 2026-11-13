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
| [`View`](#view) |  |

## TajweedClient

```swift
public final class TajweedClient: Sendable
```

The app's link to Quran Lab: the key, the signed config, registration, telemetry, issues, sharing and the model files on disk. Make one at launch with the app's key from sdk.quranlab.ai and keep it: One per process: a second one while the first is not closed throws `client_exists`. Nothing in the recognition path waits on the network once the model is on the device. A model comes only from Quran Lab's server, through the Client (3.1.0): the key, the signed config, the SDK's own download and its verification. No call takes a model folder, and a Client opens only a build it downloaded itself on this device.

- `public let sharing: TajweedSharing`: Sharing recitations with Quran Lab: whether it is offered, the learner's choice, the outbox.
- `public let analytics: TajweedAnalytics`: Counters the app reports itself.
- `public convenience init(key: String, options: TajweedClientOptions = TajweedClientOptions()) throws(TajweedError)`: - Parameter key: the app's key from sdk.quranlab.ai (`qlk_v1_...`), for this app's bundle id.
- `public func close()`: Ends the Client: its network calls and upload queue stop, and another Client can be made. Models made by it stay usable for takes that are open.
- `public func model(version: String? = nil) async throws(TajweedError) -> TajweedModel`: The Model for this app: downloaded on first use (the CPU files of the default context, verified), opened, and warmed so the first take starts at once. Later calls return the same Model. Call it early for a warm start. `version` pins a model version (`"4.0.0"`): the config request names it, and Quran Lab answers that version's build for this SDK, or its normal choice when it has none. Nil takes the version Quran Lab's config names. A first run without a network throws `needs_connection`; `model_unavailable` when Quran Lab has no build for this SDK version yet. When Quran Lab has refused the key or the app (`invalid_key`, or `server_rejected` with its reason), no model is opened and the downloaded model is removed from the device; once the server accepts the key again the model is downloaded again. A Model that was open before the refusal keeps running until the app closes it.
- `public func prefetch(unmeteredOnly: Bool = false, onProgress: (@Sendable (_ done: Int64, _ total: Int64) -> Void)? = nil) async throws(TajweedError)`: Downloads and verifies the model ahead of use. Resumable: a download that stopped goes on where it stopped. With `unmeteredOnly` it follows the connection `diagnose()` reports: it downloads on `unmetered` (Wi-Fi, Ethernet) and on `unknown`, and does nothing on `metered` (cellular, a personal hotspot, Low Data Mode) and on `none`; call it again later. A no-op when the model is on the device. `onProgress` gets the bytes done and the total of the files to download, as they arrive.
- `public var storage: TajweedDiagnosis.Storage`: What the SDK holds on disk: the bytes of each model build, ordered by version then build, and the bytes of the sharing queue. The same object as `diagnose().storage`.
- `public func removeModels() throws(TajweedError)`: Removes the model files (the next `model()` downloads them again). The learner's sharing choice and the upload queue stay.
- `public func background()`: The app left the foreground. iOS and macOS apps need not call it: the SDK follows the system's notifications. For hosts without them (an extension, a command-line tool).
- `public func foreground()`: The app returned to the foreground (see `background()`).
- `public func diagnose() async -> TajweedDiagnosis`: One structured report of where the SDK stands, safe to paste into an issue: no audio, no text, no identifiers.

## TajweedClientOptions

```swift
public struct TajweedClientOptions: Sendable
```

What a Client may be told besides its key. Every field has a default.

- `public var appId: String?`: The app's id; nil reads the bundle identifier.
- `public var appVersion: String?`: The app's version; nil reads the bundle's short version.
- `public var storage: URL?`: Where the SDK keeps models and its queues; nil means `Application Support/QuranLab` (on macOS `Application Support/<bundle id>/QuranLab`). The folder is the SDK's to fill: a model found there that this Client did not download itself on this device is not opened; it is deleted and downloaded.
- `public var analytics: Analytics`
- `public var audience: Audience`
- `public init(appId: String? = nil, appVersion: String? = nil, storage: URL? = nil, analytics: Analytics = .on, audience: Audience = .general)`

### TajweedClientOptions.Analytics

- `public enum Analytics: String, Sendable, Hashable`
- `case on`: Anonymous daily sums and histograms: never audio, text or identifiers.
- `case off`

### TajweedClientOptions.Audience

- `public enum Audience: String, Sendable, Hashable`
- `case general`
- `case children`: The sharing sheet addresses the parent or guardian and needs their confirmation.

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
- `public var reference: TajweedReference?`: The expected units of each ayah, read-only data for an app's own judge; nil when this build ships none. The table is not part of the model's download: `reference.fetch()` brings it, once.
- `public var sampleClips: [TajweedClip]`: Short recitations to run without a microphone (`listen(from:)`): the folder's self-test clips, else the three clips the SDK carries.
- `public var backend: TajweedBackend`: The Backend the next Session will use.
- `public func listen(options: TajweedSessionOptions = TajweedSessionOptions()) async throws(TajweedError) -> TajweedSession`: A Session fed by the SDK's microphone: asks for the permission, captures at the device's rate and carries that rate to the Session. Interruptions, route changes and the app leaving the foreground are handled and reported on `session.events`. Throws `microphone_denied` when the permission is refused. Nothing is captured before this call or after the take ends.
- `public func listen(from clip: TajweedClip, options: TajweedSessionOptions = TajweedSessionOptions()) async throws(TajweedError) -> TajweedSession`: The same path with no microphone: a Session fed by one of `sampleClips`, at real-time pace or (with `options.pace = .fast`) as fast as the engine takes it. The take ends with `ended(.sourceEnd)`.
- `public func listen(from samples: [Float], sampleRate: Double, options: TajweedSessionOptions = TajweedSessionOptions()) async throws(TajweedError) -> TajweedSession`: The same with samples the app already has: mono, -1...1, at `sampleRate`.
- `public func session(options: TajweedSessionOptions = TajweedSessionOptions()) async throws(TajweedError) -> TajweedSession`: A Session the app pushes audio into (`session.push(_:)`), at `options.sampleRate`.
- `public func close() async`: Releases the engine. An open Session is cancelled.

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
- `public func reportRecited(surah: Int, ayahFrom: Int, ayahTo: Int) throws(TajweedError)`: Where the learner recited in this take, for the app's analytics on sdk.quranlab.ai: counted into the ayahs per surah, never sent with a recording. One report per take: before the take ends a later call replaces an earlier one and the report is counted when the take ends with its Heads; after such a take has ended the first call is counted at once. A take that was cancelled or failed counts none.

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

Sharing recitations with Quran Lab, reached through `client.sharing`. Quran Lab decides per app whether learners are asked (the signed config); the developer switches nothing on. The SDK asks with its own sheet after a finished take, at most three times per install; a yes is never asked again. Once the learner said yes, every take the SDK listens to is shared in full, and takes that follow one another within a few seconds are one recording. The SDK's sheet and settings view are `SharingConsentView`, `SharingSettingsView` and the view modifier `.quranLabSharing(_:)`; an app with its own settings screen uses the members here.

- `public var isAvailable: Bool`: Quran Lab's config allows sharing for this app on this platform. False until a verified config says so.
- `public var isOn: Bool`: The learner said yes.
- `public func setOn(_ on: Bool, guardianConfirmed: Bool = false) async throws(TajweedError)`: The settings switch. On records the learner's yes (a children's app needs `guardianConfirmed`); off stops uploads at once and deletes the unsent queue. Throws `sharing_unavailable` when turned on while Quran Lab's config does not allow sharing for this app; off always works, with one exception: when the device gives neither the learner's stored answer nor a place to write the off down, it throws `storage_failed`, and the SDK then records and uploads nothing more in this process. On throws `storage_failed`, and changes nothing, while the learner's stored answer cannot be read.
- `public func ask() -> Bool`: Asks now with the SDK's sheet, when an ask is still allowed (at most three per install, never after a yes or after sharing was turned off). True when the sheet is shown. The SDK also asks by itself after a finished take.
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
- `public var json: String`: The report as JSON, its eleven fields in the order every SDK writes them, for pasting.

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

The consent sheet: why sharing helps, what is shared, who receives it, how to stop, and two buttons of equal weight. Nothing is pre-ticked; in a children's app the share button is enabled only after the parent or guardian confirms.

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

The sharing settings: the switch, "What is shared", "Delete what I shared" (with its confirmation), and the learner's recovery code for a lost device (revealed on tap, shown only here). Works whatever the developer flag says, so a learner can always stop and delete.

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

## View

- `public func quranLabSharing(_ client: TajweedClient, theme: SharingTheme = .standard) -> some View`: Lets the SDK present its recitation-sharing sheet and thank-you on this view, at the right moments, in `theme` for the app's Client. Without it the SDK presents its sheet over the front view controller on iOS.
