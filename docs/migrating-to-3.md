# Migrating from TajweedFormer 2.x to 3.0.0 (iOS and macOS)

3.0.0 is a breaking release. The SDK is now an inference engine: it gives the model's output (every head of the
network, and what the model heard) and nothing derived from a known text. The scorer, the tajweed settings and their
results are gone, and the public API is five types with the same names in the four TajweedFormer SDKs. This page
says what to change, and what an app that showed verdicts now builds itself.

Models are not shared between the two lines: a 3.x SDK runs only model builds made for it, and a 2.x SDK keeps
running the 2.x builds.

## The API, old to new

| 2.x | 3.0.0 |
|---|---|
| `QuranLab.configure(key:)` | `let client = try TajweedClient(key:)`, once per process (a second one throws `client_exists`) |
| `QuranLab.Options(...)` | `TajweedClientOptions(appId:appVersion:storage:analytics:audience:)` |
| `TajweedModel.load()` | `try await client.model()` (downloads once, verifies, opens and warms) |
| `TajweedRecognizer(model:)`, `startTake()` | `try await model.listen()` (the SDK captures) or `try await model.session()` (you push audio); a Session is one take |
| `Microphone.requestPermission()`, `microphone.start(into:)` | nothing: `model.listen()` asks and captures. `Microphone().samples()` is there for apps that want the samples themselves |
| `recognizer.append(samples)` | `try session.push(samples)` at `TajweedSessionOptions.sampleRate` |
| `recognizer.chunks()` | `session.chunks` (each `TajweedChunk` has `heads` and `decoded`) |
| `recognizer.decoded()` (`DecodedTake`) | `chunk.decoded`, or `heads.decoded()` on the take's Heads (`TajweedDecoded`) |
| `recognizer.finish()` | `try await session.finish()` returns the take's `TajweedHeads` |
| `recognizer.cancelTake()` | `await session.cancel()` |
| `recognizer.activeBackend`, `acceleratorState` | `session.backend`, `model.backend` (`TajweedBackend`: `kind`, `name`, `stage`, `reason`) |
| `heads: .default`, `.all`, `.adding([...])` | `TajweedSessionOptions(heads:)` with head names; `defaultHeads`, `allHeads` |
| `RecognizerError` | `TajweedError` with `code`, `message`, `fix`, `docs`; compare `code` |
| `Contributions.*`, `endSession(feedback:)` | `client.sharing` (`isAvailable`, `isOn`, `setOn`, `ask`, `items`, `summary`, `delete`, `recoveryCode`, `setWording`, `feed`); the SDK notes the end of a take itself |
| `.quranLabSharing()` | `.quranLabSharing(client)` |
| `recognizer.score(surah:ayah:)`, `TajweedResult`, `TajweedOptions`, presets, word levels | removed: see below |

New in 3.0.0: `session.events` (speech started and ended, interruptions, the end of the take and why),
`TajweedSessionOptions.endOnSilenceMs` (the take finishes by itself after silence), `decoded.settled` and `isFinal`,
`model.listen(from:)` with the model's sample clips, `client.prefetch`, `client.storage`, `client.removeModels()`,
`client.diagnose()`, `model.version` and `model.build`, `model.calibration`, `model.reference`.

The Neural Engine's build is the fp16 CoreML build, as in 2.x. `QuranLab.Options.compactCoreML` is gone with the
rest of `QuranLab.Options`: an app that used it names the compact build per Session,
`TajweedSessionOptions(backend: .coremlCompact)`; it is then fetched and goes through the same pipeline.

Speech and silence are read from two heads. `speechStarted`, `speechEnded`, `chunk.speech` and `endOnSilenceMs` count a
frame as speech when `log_probs` or `timing_log_probs` hears a sound on it, so a held vowel does not end a take.
`endOnSilenceMs` takes 500 to 60000.

## What 3.0.0 no longer does

There is no `score`, no `TajweedResult`, no site or word flag, no madd, qalqalah or gemination verdict, no preset,
no per-class override and no word level. The tajweed settings an app's page on sdk.quranlab.ai held for 2.x do not
reach a 3.x SDK; the response time setting does (it chooses the context).

An app that judged recitations with 2.x and wants to keep doing so builds the judge itself, over the output the SDK
gives. Everything the 2.x scorer read is still there:

1. **The expected tokens of the ayah.** `model.reference` is the table the 2.x scorer used: after
   `try await model.reference?.fetch()` (once), `units(surah:ayah:)` gives the ayah's unit ids, which are ids of
   `model.tokens`, and the index of the first unit of each word. The SDK does not align them with a take.
2. **Alignment and per-site evidence.** The 2.x scorer ran the full-sequence CTC forward of the expected sequence
   and of each single-unit alternative on `log_probs` and `inter1_log_probs`, fused the two with the calibration's
   fusion weight (`model.calibration?.fusionWeight(context:class:)`), and flagged a site when the fused score passed
   the class's threshold (`threshold(context:class:preset:)`). Both heads are in the take's Heads (`heads["log_probs"]`,
   `heads["inter1_log_probs"]`: `frames` rows of `classes` values).
3. **Madd, qalqalah, gemination, words.** Madd counts come from `timing_log_probs`, qalqalah from `attr_qalqalah`,
   gemination from `gem`; the cuts and taus the scorer used are in the calibration
   (`number("contexts", context, "qalqalah", "tau")` and the like). The 2.x word score was the largest fused score of
   the single-unit edits inside the word.
4. **Presets and overrides** are the app's own now: the calibration lists Quran Lab's presets and their thresholds
   per class, and which classes were validated (`status(context:class:)`).

The calibration's numbers were measured for the model build they ship with, on the heads as the SDK gives them. They
are data: a starting point Quran Lab measured, not a judgement the SDK makes.

## Analytics after each take

The SDK no longer knows where the learner recited or what a judge found, so two calls tell it, for the app's page on
sdk.quranlab.ai. Counts only: never text, audio, ids or times.

```swift
try session.reportRecited(surah: 1, ayahFrom: 2, ayahTo: 2)
try client.analytics.reportChecks(rule: "vowel_sub", checked: 31, flagged: 1)
```

## Staying on 2.x

SDK 2.0.2 keeps working until Quran Lab retires SDK 2.x, which happens when 3.0 is released or shortly after;
there is no long overlap, so plan the move to 3.0 now. 2.0.2 keeps the scorer and runs the 2.x model builds; it
gets no new features, and a key that is answered with `sdk_too_old` needs 3.x.
