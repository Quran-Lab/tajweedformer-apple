# Changelog

## 3.0.0

A breaking release. The SDK is an inference engine: audio in, the model's output out (every head of the network,
and what the model heard), and nothing derived from a known text. The scorer and the tajweed settings are removed,
and the public API is five types with the same names in the four TajweedFormer SDKs. What to change in an app, and
what an app that showed verdicts builds itself: [docs/migrating-to-3.md](docs/migrating-to-3.md). The whole public
surface: [docs/api.md](docs/api.md).

A 3.x SDK runs only model builds made for it; the 2.x builds stay with SDK 2.x.

### Removed
- Scoring: `score(surah:ayah:)`, `TajweedResult` and its sites, madd, qalqalah, gemination and word verdicts,
  `TajweedOptions`, presets, per-class overrides, word levels, and the tajweed settings of the signed config.
- The 2.x entry points: `QuranLab.configure`, `TajweedRecognizer`, `TajweedModel.load()`, `Contributions`,
  `RecognizerError`, and every other public type that is not in docs/api.md. The public surface went from 738
  declarations in 115 types to 247 in 46 (the 23 named types, their nested value types and the sharing views).

### The API
- `TajweedClient(key:)`: one per process (`client_exists` for a second one). `client.model()` downloads the model
  once, verifies it, opens and warms it; `client.model(version:)` asks for a model version. `client.prefetch`
  (resumable, with progress, optionally on unmetered networks only), `client.storage`, `client.removeModels()`.
- `TajweedModel`: `version`, `build`, `contexts`, `defaultContext`, `tokens`, `sampleClips`, `backend`, and two files
  of the model as data for an app's own judge: `calibration` (the thresholds and weights Quran Lab measured; never
  applied by the SDK) and `reference` (the expected units of every ayah; downloaded only by `reference.fetch()`).
- `TajweedSession`, one take: `model.listen()` asks for the microphone and captures at the device's rate;
  `model.listen(from:)` runs a sample clip or your samples through the same path; `model.session()` takes pushed
  audio. `chunks` (each with its `heads` and the `decoded` layer of the take so far), `events`, `finish()` (the
  take's `TajweedHeads`), `cancel()`.
- Events: `speechStarted`, `speechEnded`, `interrupted`, `resumed`, `backendChanged`, and `ended` with its reason
  (`silence`, `background`, `interrupted`, `sourceEnd`, `limit`, `error`). `endOnSilenceMs` finishes a take by
  itself after silence. `decoded.settled` says how many tokens will not change; `isFinal` marks the last chunk.
- `TajweedError`: one error type with a stable `code` (26 codes, the same in the four SDKs), `message`, `fix` and
  `docs`. New situations have their own codes: `needs_connection` (a first run without a network),
  `model_unavailable` (Quran Lab has no model build for this SDK version yet), `session_open`, `client_exists`,
  `runtime_unsupported` (a processor the SDK does not run on: an Intel Mac, the x86_64 simulator),
  `network_not_permitted` (the app may not use the network).
- A refusal says what to do. When Quran Lab refuses the app with a reason it names (the account has no access yet,
  the key is of another type, the key is not for this app id, the app is blocked, and three more), the error is
  `server_rejected` with that reason's own message and fix; any other refusal names the server's code. The answer's
  `reason` is read first: a key that belongs to another app, a key of another type and an identifier that is not on
  the key arrive as a refused key (401) with the check named in `reason`, and the error is `server_rejected` with
  that check's message and fix ("This key belongs to another app"), not `invalid_key`.
- `client.diagnose()`: one report of where the SDK stands, safe to paste into an issue. Its `connection` is
  `unmetered`, `metered`, `none` or `unknown`, and `prefetch(unmeteredOnly: true)` follows it: it downloads on
  `unmetered` and `unknown` and does nothing on `metered` and `none`.

### Models
- A model has a version and a folder is a build of it. The signed manifest carries the version; the build id is the
  first 40 hex digits of the SHA-256 of the manifest. A manifest without a version (a 2.x build) verifies and is
  refused (`model_incompatible`). Telemetry and incident reports name the version and the build.
- The Neural Engine's build is promoted by a golden test on raw outputs: per CTC head the greedy tokens and the
  distance of the log-probabilities, and the mean difference of the attribute heads' probabilities, against the CPU
  engine, within the tolerance the signed manifest gives the build (tokens only without one).
- The context a Session runs: `TajweedSessionOptions.context`, else the signed config's `inference.context`, else
  the model's default.
- The Neural Engine's build is the fp16 CoreML build (`coreml`), as in 2.x. The compact build (`coreml-compact`, a
  delta of 1.7 MB against the CPU weights already there, where the fp16 build's is 76.1 MB) is named per Session,
  `TajweedSessionOptions(backend: .coremlCompact)`, in place of 2.x's `compactCoreML` option; a device does not try
  it on its own. A folder may hold both builds; installing one no longer deletes the other.
- Speech and silence come from the model's own output, one rule for the events, `chunk.speech` and the telemetry: a
  40 ms frame is speech when `log_probs` or `timing_log_probs` hears a sound on it, so a held vowel is speech. The
  SDK computes the timing head on every take and hands it out only when it is selected. `speechEnded` comes when the
  window (`endOnSilenceMs`, else 1500 ms) has passed after the last such frame. `endOnSilenceMs` takes 500 to 60000.

### Bounds
- A take holds at most 20 minutes of audio; at the limit it ends by itself with `ended(.limit)`, its Heads kept.
- At most 256 chunks and 64 events wait for the app; when it reads late, the oldest waiting ones are dropped (the
  last chunk and `ended` never), and `diagnose().droppedChunks` counts them. `finish()` returns the whole take.

### Telemetry
- Per model version, build, context and backend: takes, audio, speech and silence, tokens per head, compute time.
  Everything derived from scoring is gone. Two calls report what only the app knows:
  `session.reportRecited(surah:ayahFrom:ayahTo:)` and `client.analytics.reportChecks(rule:checked:flagged:)`.

### Sharing recitations
- Reached through `client.sharing`. The rules are unchanged: Quran Lab decides per app, the learner is asked at most
  three times, a yes is never asked again, and a learner keeps the consent version they agreed to.
- Takes in a row share one recording. A shared recording stays open after a take for a few seconds (3 s; the signed
  config's `flags.share_join_ms`, 0 to 10000 ms, 0 never joins), and a take that starts in that time at the same
  input rate continues the same Ogg stream: no new headers, the encoder keeps its state, and the pause between the
  takes gets no audio. A recording of two or more takes sends where each take starts and the pause before it
  (`POST /v1/uploads/{id}/takes`) after its last segment. A take list the server refuses with 400 is kept and tried
  again on the outbox's backoff until it is accepted, sharing goes off or seven days pass.
- `client.sharing.feed(_:sampleRate:)`, for apps that capture audio themselves outside takes: the last second of
  what is fed goes in front of the next take's recording and up to half a second after a take, so a recitation is
  not clipped at a take's edges. Kept in memory only, one second at most; dropped at once without the learner's yes.
  After every take the recording waits for that half second until 1.5 s after the take's end, also when no take can
  join it any more; what is fed later goes in front of the next take. In that time only fed audio is recorded: with
  `listen()` the microphone is closed when the take ends.
- A recording never holds more than 20 minutes of audio: it closes there, also inside a take, and the take goes on
  in a new recording. A take that starts with 30 s or less of room is held in memory until it ends, and joins only
  when it fits.
- The session JSON of a recording carries `take_seq` (the install's count of shared recordings) and `gap_ms_prev`
  (the time since the previous one, rounded to 100 ms, left out above an hour). No identifier, no wall-clock time.

### Fixed
- Configuring twice left two upload queues on one storage, each sending the same recording. There is one Client per
  process, and a closed Client's queue sends nothing.
- A golden test that passed kept none of what it measured. The measures (token edits and log-probability distances
  per head, the mean probability difference of the attribute heads) are kept with the promotion's record, also for
  a build that signs no tolerance and for a test that failed.
- `prefetch` reported no progress when the launch's own update check had already started the download. A listener
  that comes while a download runs gets its progress from where it stands.
- The Backend's name came from the folder as it was when the model was opened, so it could name the other CoreML
  build. The name comes from the build the promotion pipeline runs.
- One `diagnose()` report could say the config was fresh while the key was still unanswered, when the config
  arrived while the report was made. The config's state is read first.

## 2.0.2

The in-session failover no longer punishes a healthy Neural Engine (a developer measured two 2.0.1 rules firing on
normal recitation: blank output during held vowels and madd, and a deadline missed by the first chunk after the
Neural Engine sat idle).

- Blank output is a suspicion: when the Neural Engine writes nothing for a few chunks of audio with sound, the same
  audio is checked on the CPU engine in the background while the Neural Engine keeps serving. The CPU blank too:
  nothing happens (`promotions[].blank_confirmed_ok`). The CPU writing tokens: the take switches to the CPU from the
  first silent chunk, with nothing lost, and the incident carries the divergence.
- Behaviour change in the chunk stream: after a confirmed disagreement, `chunks()` and the chunks `append` returns
  hand out the chunks again from the first one in question, with the SAME `index` and `TajweedChunk.replaces ==
  true`, then continue in order (2.0.1 never handed an index out twice). On a chunk with `replaces`, replace what you
  have for that index and drop what you have for every later index (they come again in order); do not append.
  `heads()`, `decoded()` and `finish()` then give the CPU's replay of the whole take for takes up to 30 s, and the
  Neural Engine's chunks before the switch plus the CPU's after it for longer takes.
- A cold start is not a failure: a warm-up when a take starts and when the app becomes active; the first chunk of a
  take gets at least 1 s (max(1000 ms, 10 x p90)); later limits come from warm chunks only.
- A late chunk is served by the CPU and demotes nothing; late chunks in 3 sessions within 24 h, or one confirmed
  disagreement with the CPU, pause the build for 6 h (no new golden test). Off for good only for NaN or out-of-range
  output, a second confirmed disagreement, a golden or CPU mismatch, or a crash. An exception from the Neural Engine
  keeps the 2.0.1 rule (tested again a day later, at most three times).
- On the first launch of 2.0.2, builds that 2.0.1 set aside for silence or a late chunk are tested again and
  promoted again.
- Incident reports are kept on the device (7 days) even before `QuranLab.configure` is called, and sent once Quran
  Lab is configured and online. An app that never configures Quran Lab sends none.
- Staying on 2.0.1: `TajweedRecognizer(model: model, options: options, debugBuild: true, backend: .neuralEngine)`
  (it throws `invalidArgument` without `debugBuild: true`) uses the CoreML build already in the model folder and
  skips the promotion pipeline, the persisted record, every demotion and backoff, the deny-lists, the thermal and
  memory checks, and the promotions telemetry and incident reports; its deadline is the fixed 300 ms, so the slow
  first chunk after idle passes. Still applied: the per-take checks, including the blank rule, after which that
  recognizer stays on the CPU until you create a new one. You give up the golden test, the automatic fallback across
  sessions, the deny-lists, the background compile (the first load compiles inside `prepare()` or the first
  `startTake()`), and the Neural Engine telemetry and incident reports. Upgrading to 2.0.2 is the fix.

## 2.0.1

### CPU first, then the Neural Engine

- The first install downloads only the CPU files of the default context (2.0.0 downloaded the CoreML package,
  about 125 MB, before the first session), and the first session runs on the exact CPU engine.
- Neural Engine promotion is a persisted pipeline per model revision, context, CoreML build, OS build and
  device: download on an unmetered network (preferably a QLPD1 delta rebuilt on the device from the CPU
  weights, SHA-256 checked before CoreML sees it), compile at low priority (kept in Application Support,
  excluded from backup, redone after an OS update), warm-up, then a golden test of all five self-test clips
  through CoreML and the CPU engine in both directions (tokens, flagged sites, per-word verdicts; the planted
  mistake must be found), within the build's tolerance from the signed manifest. A passing build is always
  promoted; its speed is reported only. Retries after 1, 6 and 24 hours; never for a wrong result, NaN or crash.
- The swap happens only between sessions, to a warm model; a promoted device loads it again at the next launch
  and usually starts its first session on it, never waiting.
- In-session failover: an exception, NaN or out-of-range output, blank output over speech or a missed deadline
  switches the session to the CPU at that chunk, rebuilt from recent audio; the Neural Engine is set aside for
  that revision and OS. The CPU engine is closed while the Neural Engine serves (it would hold about 64 MB in
  its dot-product layout) and opened at the switch. The correction file of 2.0.0 is no longer used.
- `accel_deny` rules in the signed config keep the Neural Engine off on matching devices; every incident is
  reported (`promotion_failed`, `accelerator_failover`), and the telemetry gains a `promotions` entry.

### Recitation sharing

- The sharing sheet is offered where Quran Lab decides, per app, in the signed config; `Options.contributions`
  is ignored, and without a verified config nothing is offered. An app without `.quranLabSharing()` or a
  presenter now gets the SDK's sheet on iOS (2.0.0 counted the ask and showed nothing). Nothing is recorded or
  sent before the learner answers "Share".
- Asking: the sheet is shown at most three times per install, ever (the count carries over from 2.0.0);
  "Not now" may lead to a later ask within those three, a yes ends asking forever, and so does turning
  sharing off after a yes (the app's settings can still turn it on). A yes persists across copy decks, app
  wording and the upgrade from 2.0.0 (no sheet, no pause), and each session carries the version the learner
  agreed to. Stopping and deleting work whatever the learner agreed to.
- The consent sheet, default or yours: `Contributions.theme` themes the SDK's sheets; your own UI with
  `Contributions.setPresenter(_:)`, the SDK's localized strings and `Contributions.answer(share:)`; your own
  wording with `Contributions.setWording(_:)`, recorded as consent version `custom-<24 hex>` with its SHA-256
  sent with each session for Quran Lab to review.
- Copy deck 2026-11-09.1 (consent `share-2026-11-09`) in eight languages: no longer says the recited ayah is
  sent (it is not); new lines for a failed deletion and for the recovery code.
- Adaptive Opus bitrate on bad networks: 192, 96, 64 or 32 kbit/s, lowered when uploads fail or back up and
  raised again when they succeed, changed between segments of the same Ogg stream
  (`Contribution.segmentBitrates`).

### Telemetry and the platform client

- Deltas during the day (at launch, every 15 minutes in use, at background), each with a random `report_id`;
  new aggregate counters (launches, ayahs, ayahs per surah, words, tajweed rule checks and flags, sharing
  sheet outcomes, accelerator promotions). Register once per UTC day per install.
- In debug builds, one log line when Quran Lab's signed config names a newer SDK.
- Fixes: a segment upload that succeeds clears the session's backoff; a drain that ignores the backoff is
  honoured while another pass runs.
- `docs/platform-client.md`: what the SDK sends to Quran Lab, when, and what an app can change.

## 2.0.0 (first public release)

- TajweedFormer V4: `TajweedModel` loads a signed `sdk/v4.0` folder; `TajweedRecognizer` streams
  audio through the Neural Engine or the exact engine and keeps every head of the network;
  `score(surah:ayah:)` returns per-site tajweed verdicts with their evidence.
- Tajweed settings in three layers (app code, the portal's block, `calibration.json`), identical in
  every TajweedFormer SDK.
- Exact backend: the 35 conformance clips give the engine's expected outputs, every output of every
  chunk, through this SDK's own API. Neural Engine backend: token-identical to the reference on the
  35 conformance clips in every shipped context (greedy tokens of log_probs, checked on Apple silicon Macs).
- SwiftPM package, product and module `TajweedFormer`; iOS 15+, macOS 12+.
