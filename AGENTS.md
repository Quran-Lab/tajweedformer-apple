# TajweedFormer for iOS and macOS: reference for coding assistants

Everything an assistant needs to integrate this SDK correctly: use only the names, calls and settings shown here or in the installed version's sources. People: the short version is in [README.md](README.md).

## What you get

<table>
<tr>
<td width="33%" valign="top">

**Hears every word**<br>Streaming recognition of Quranic recitation while the learner recites. Results arrive as often as every 160 ms on the CPU engine (320 ms by default, including on the Neural Engine; 480 ms for longer context).

</td>
<td width="33%" valign="top">

**Points to the word to fix**<br>Wrong letters and vowels, madd held too short or too long, and a score for every word. Qalqalah checks are experimental.

</td>
<td width="33%" valign="top">

**Native on Apple**<br>A Swift Package for iOS 15+ and macOS 12+. On iOS 18+ and macOS 15+ it runs on the Neural Engine, with the exact CPU engine as fallback.

</td>
</tr>
<tr>
<td valign="top">

**Private by default**<br>Offline, on the device. A recording leaves it only when the learner agrees to share it.

</td>
<td valign="top">

**Nothing to host**<br>The SDK downloads the right model for each device (from about 57 MB) from our CDN in six regions, verifies it and keeps it up to date.

</td>
<td valign="top">

**Tuned in the portal**<br>Four presets and three word levels. Change them at any time; your app picks them up without a new build.

</td>
</tr>
</table>

### Strict or gentle: you choose

**Strict** almost never flags a correct recitation. **Balanced** is the default. **Sensitive** catches more, and **Very sensitive** catches the most, for a teacher who reviews every flag first. The word level follows your learners: **strict** for huffaz and advanced students, **general** for most apps, **beginner** for children and classes.

## Why TajweedFormer

- **Made for the Quran.** Your app names the ayah; TajweedFormer checks the recitation against it, sound by sound, and gives every word its own verdict.
- **Feedback in the moment.** Results stream while the learner recites, so your app can respond on the word itself, not after the take.
- **One engine on every platform.** The same engine runs the [iOS and macOS](https://github.com/Quran-Lab/tajweedformer-apple), [Android](https://github.com/Quran-Lab/tajweedformer-android), [web](https://github.com/Quran-Lab/tajweedformer-web) and [Windows and Linux](https://github.com/Quran-Lab/tajweedformer-c) SDKs, all set from one portal.
- **Free, and it stays free.** Quran Lab is a non-profit waqf: the SDKs and models are never sold. The licence, NPL-1.2, asks three things: no paywall on model features, no results presented as rulings, and show the notice.

## Built for AI developers

Copy the setup prompt from [portal.quranlab.ai](https://portal.quranlab.ai) and paste it into your coding assistant. That one prompt sets everything up: the package, your key, and the settings for the learners your app is for. [AGENTS.md](AGENTS.md), beside this README, gives the assistant the complete API, so the code it writes uses names that exist. Prefer to do it by hand? Get a key in the portal and start below.

## At a glance

- **What it is:** the Swift package `TajweedFormer` (SDK 2.0.2) for the Quran Lab TajweedFormer V4 model
  (`Quran-Lab/tajweedformer-v4`, folder `sdk/v4.0`). It hosts only V4; the earlier phoneme models stay with the 1.x
  SDKs.
- **Platforms:** iOS 15 and macOS 12 on Apple silicon. The Neural Engine backend needs iOS 18 or macOS 15; on older
  systems the exact CPU engine runs.
- **Status:** preview.

## Quick start

```swift
import TajweedFormer

QuranLab.configure(key: "qlk_v1_...")             // once, at launch

let model = try await TajweedModel.load()          // this device's download profile, verified
let r = try TajweedRecognizer(model: model, options: TajweedOptions(preset: .balanced, word: .general))

try await r.startTake()
for chunk in try await r.append(samples, sampleRate: 48_000) {   // raw layer, as audio arrives
    print(chunk.index, chunk.heads[.logProbs].count)
}
try await r.finish()

let heard = await r.decoded()                      // decoded layer
print(heard.transcript, heard.tokens.map(\.confidence))

let result = try await r.score(surah: 1, ayah: 2)  // tajweed layer
for w in result.words where w.flagged == true { print("word", w.index, w.score!) }
for s in result.flagged { print(s.cls, s.expected as Any, s.alternative as Any, s.llr, s.threshold) }

await r.endSession(feedback: true)                 // the moment the SDK may ask about sharing
```

With a microphone: `try Microphone().start(into: r)` after `startTake()`, and `for await c in await r.chunks()` for
the chunks as they complete. Every error is a `RecognizerError`.

## What a device downloads

The model folder is signed (manifest format 3, Ed25519) and every file is tagged with the platforms, context and role
that decide which device downloads it. Large files travel gzip and are kept decoded. Downloads use HTTP Range into a
`.part` file and resume after the app is killed; each file is checked by size and SHA-256 before and after it is
inflated, and a mismatch deletes both.

| iPhone or Mac, default context | Before (one folder per context) | Now (estimates until measured) |
|-|-|-|
| first install, any iPhone or Mac | about 610 MB (three CoreML fp16 packages and three CPU engine folders), or 206 MB for the default context alone | about 56.5 MB: the CPU files of the context only |
| later, iOS 18 / macOS 15, in the background | (part of the first download) | on an unmetered network: ONE fp16 CoreML package for every context (about 120 MB, or about 76 MB when the model ships its program as a delta against the CPU weights already on the device), its keep table and the self-test set |
| later, `compactCoreML: true` | the same | about 55 MB more: the int8 package instead, for low-storage devices; slightly less accurate |
| another context later | another full folder | about 1 MB |

The first install of a model fetches the CPU set only, so the first session can start as soon as possible; the
Neural Engine's files come later (see "CPU first, then the accelerator"). A device holds one CoreML build: the default
fp16 package, or with `QuranLab.Options(compactCoreML: true)` the int8 package (for low-storage devices; slightly
less accurate); changing the option replaces the build on disk at the next promotion. `QuranLab.Options(neuralEngine:
false)` never downloads a CoreML build. The correction file of 2.0.0 (`coreml/engine.zfs`, which rebuilt the CPU
weights from the package) is no longer downloaded or used: with the CPU set first, the weights are already on disk.

Sources, in order: `.bundle` (`QuranLabModels/v4.0/` in the app, decoded), `.cache` (the SDK's store), `.cdn`. The
updater stages new revisions in the background and switches at the next load.

## Backends and the CPU fallback

- **Neural Engine** (iOS 18, macOS 15): one multifunction CoreML package (fp16 by default, int8 when compact); each
  context's two functions are loaded with
  `MLModelConfiguration.functionName` (`front_<ctx>`, `back_<ctx>`). Features come from the engine's exact fbank.
- **Exact CPU engine**: [tajweedformer-engine](https://github.com/Quran-Lab/tajweedformer-engine), pinned as `engine/`. The
  same bits on every device, for every head of every chunk, as ONNX Runtime's int8 reference.

The default context is `c16_l64` (320 ms chunks). `c8_l64` (160 ms chunks, 64 left frames) has no CoreML package: it
always runs on the exact CPU engine, whichever backend is asked for, and it ships in the next V4.0 revision.

### CPU first, then the accelerator

With `.automatic` (the default, no code needed):

1. **First run.** The first install downloads only the CPU set. The first session runs on the exact CPU engine and
   nothing is queued in front of it: the Neural Engine's work starts after the first session ends, or after 20 seconds
   with no session. On every later launch the CPU engine serves until the Neural Engine is loaded and warm again; a
   session never waits for it.
2. **In the background,** one pipeline per model revision, context, build, OS build and device model, with its state
   kept on disk after each stage (an app killed in the middle resumes at the next launch where it stopped):
   download (the CoreML build, its keep table and the self-test set, on Wi-Fi or Ethernet only, resumable, every file
   verified; when the model ships the build's `weight.bin` as a delta, the delta is downloaded and the program rebuilt
   on the device from the CPU weights it already has, its SHA-256 checked against the signed manifest before CoreML
   sees it, the full file downloaded instead if that fails), compile (the first load with the Neural Engine allowed: the on-device compiler, 10 minutes at most),
   warm-up (silence and a self-test clip; no NaN or inf), golden test, measure, promote. It runs only while the device
   is in good shape (not in Low Power Mode, battery at least 20 % or charging, thermal state nominal or fair) and it
   waits otherwise. An app that registers `QuranLab.registerAcceleratorPreparation(identifier:)` (a
   `BGProcessingTask` that waits for external power) also lets it run while the device is idle.
3. **The golden test** decodes every clip of the model's self-test set (the Basmala clips and a planted mistake
   included) through the Neural Engine and through the CPU engine, with the same streaming code a session uses: greedy
   tokens identical on the clean clips, flagged sites and flagged words identical on every clip, no NaN or inf, and the
   CPU engine's own results equal to the shipped expected file. A build may differ from the CPU engine by the
   tolerance the signed manifest gives it (exact when it gives none), but a missed planted mistake always fails. It
   runs only while no session runs; a session that
   starts stops it, without counting a failure, and it runs again later. Speed is measured and reported, never a
   reason to stay on the CPU: a build that passes is promoted.
4. **The swap** happens only when a session starts, and only to a build that is loaded and warm: the app sees the
   same API, the same results and faster chunks; `activeBackend` says which engine runs. A promoted build is kept with
   its verdict: at the next launch it is loaded and warmed as soon as the recognizer is created, so the first session
   normally starts on it; the golden test runs again only for a new model revision, OS build or build, or when the
   program on disk changed or is gone.
5. **Failing safe.** Any failure keeps the CPU engine and records the stage and the reason (`acceleratorState`
   `.disabled(reason)`). A failure is retried for the same model revision and OS build after 1 hour, 6 hours and 24
   hours, then not again; a golden-test mismatch, a NaN or a crash is never retried for them (a new model revision or
   OS update tries again). A crash marker written around every compile, load and first inference turns a crash there
   into such a failure at the next launch. The signed config's deny-list (`denylist`, and `accel_deny` rules matched
   on the device model, chip, OS build and version, model revision and SDK version) keeps the Neural Engine off; a
   promoted build goes back to the CPU at the next session boundary.
6. **During a session**, every Neural Engine chunk is checked: an exception, a NaN or infinite value, a value outside
   the heads' range, or a chunk that misses its deadline. The session then switches to the CPU engine at that chunk:
   the take's recent audio is replayed through it, the chunks already handed out stay, and the session continues
   with no error. For a take the CPU can replay within about a quarter of a second (a few seconds of audio on a
   phone, longer on a Mac) the result is exactly the CPU engine's; for a longer take the CPU replays its last seconds
   and continues from the failed chunk. The CPU engine is not kept loaded behind the Neural Engine: its weights are
   rewritten into the CPU's fast layout when it loads, so a standby would hold about 64 MB of memory for the whole
   session; it is opened again at the switch instead.
   - **Silence is not a fault.** The model writes nothing during a long madd or a held vowel, so a few chunks with
     no token in audio with sound are only a suspicion. The SDK replays the same audio (the last 30 seconds at most)
     through the CPU engine in the background while the Neural Engine keeps serving, with no stall, at most one check
     at a time and one per 10 seconds of audio. If the CPU engine writes nothing there either (within the build's
     golden-test tolerance), nothing changes and the CPU engine is closed again (counted as `blank_confirmed_ok`). If
     it writes tokens there, the session switches to it (its state is already rebuilt by the check), the take's chunks
     from the first one in question are the CPU's, and the chunk stream hands them out again with the same `index`
     and `replaces == true` (new in 2.0.2: 2.0.1 never handed an index out twice): replace what you have for that
     index and drop what you have for later ones, they come again in order. `finish()`, `heads()` and `score()` give
     the corrected take (for a take of up to 30 s, exactly the CPU engine's). The decisions are compared by greedy tokens (the scoring runs after
     the take, so there are no flags to compare during it).
   - **A cold start is not a fault.** The Neural Engine is warmed up (one prediction on silence, off the audio path)
     when a take starts and when the app becomes active. The first chunk of a take, and the first chunk after the app
     became active, may take up to max(1000 ms, 10 x the warm p90); later chunks get min(300 ms, max(4 x p90,
     2 x median, 50 ms)) from warm chunks only (300 ms before any warm measurement). A late chunk is served by the CPU
     engine, for the rest of that session, and costs nothing more; a call that does not answer at all is abandoned.
   - **What happens to the build.** Late chunks in 3 different sessions within 24 hours, or one disagreement the CPU
     engine confirmed: a pause of 6 hours, then the build serves again, still verified (no new golden test); never
     off for good for these. Off for good for that model revision and OS build: a NaN or infinite value, a value out
     of range, a second confirmed disagreement, a golden-test or CPU mismatch, a crash. An exception keeps the 2.0.1
     rule: the build is demoted and golden-tested again no sooner than a day later, within the retry budget.
   - **From 2.0.1.** At the first launch of 2.0.2, a build that 2.0.1 had demoted or turned off for blank output or a
     missed deadline is cleared: the golden test runs again in the background and the build is promoted as usual.
     Other causes stay.
7. **Telemetry** counts, per backend, model revision and context, the attempts, promotions, the stage and reason of
   each failure, the compile time and the speedup, the in-session switches with their cause and how long they
   stalled (a late chunk is a switch, counted under `failover_causes.deadline`, whether or not it demoted), the
   demotions (`demoted`), and the silent stretches the CPU confirmed (`blank_confirmed_ok`): the `promotions` entries
   of [docs/platform-client.md](docs/platform-client.md). Every failure and switch is also an issue report
   (`promotion_failed`, `accelerator_failover`), with the stage, the cause, the device model, OS build and chip, and
   no audio, text or identifier. Reports are kept on the device for up to 7 days, also when the app has not
   configured Quran Lab or is offline, and sent once the app has configured Quran Lab with its key and the network
   is there. An app that never configures Quran Lab with a key sends none: there is no key or token to send them
   with.

The app can watch it (`acceleratorState`: `.cpu`, `.preparing`, `.ready`, `.disabled(reason)`;
`acceleratorStates()` streams changes), start it and wait for it (`awaitReady(timeout:)`), read the golden test's
numbers (`acceleratorSelfTest`), or choose a backend: `.exact` always, `.neuralEngine` in debug builds (the build
in the folder at once, without the pipeline).

## The three layers

- **Raw:** every output of the network per chunk (`TajweedChunk`): `log_probs`, `inter1_log_probs`,
  `inter4_log_probs` (40 ms), `id_log_probs`, `timing_log_probs`, `gem`, `attr_tafkheem`, `attr_ghunna`,
  `attr_qalqalah`, `attr_face`, `boundary`, `conf` (20 ms), as Float arrays with their width, rate, kind and class
  names (`TajweedHead`). `heads: .default` hands out what the scorer needs plus `conf`; `.all` everything;
  `.adding([...])` a choice. The CPU engine computes only the heads asked for (and the scorer's), so a head nobody
  asked for costs nothing; the CoreML package computes all twelve, and the API is the same on both.
- **Decoded:** `DecodedTake`: per 40 ms frame the top token and the runner-up with log-probs and margin, and
  `decoded(topK:)` ranks log_probs to any depth (1 to 38, 38 being the whole list); `ranking(_:k:)` ranks any token
  head (log_probs, inter1, inter4, id, timing) or class head (gem, tafkheem, ghunna, qalqalah, face) with its names
  and margins to the next rank. All rankings come from the engine (highest first, ties to the lower id) for heads of
  either backend; the greedy
  tokens with their frames, times, peak log-prob, runner-up, margin and confidence (the conf head); words; the
  transcript. No known text needed.
- **Tajweed:** `TajweedResult` for a known surah and ayah, scored by the engine's own scorer (the same verdicts on
  every platform): per site the class, the expected unit, the best alternative, the per-head and fused LLRs, the
  threshold and the flag; madd counts with their durations; qalqalah and gemination evidence; and per word the score
  (the engine's: the largest fused LLR of every single-unit edit inside the word), the best edit, the threshold, the
  flag and the flagged items.

Settings: presets (`strict`, `balanced`, `sensitive`, `verySensitive`), per-class overrides (a preset or a raw
threshold), checks, the context, and the word level (`strict`, `general`, `beginner`, `custom(score)`, `off`). App
code wins over the portal's settings in the signed config, which win over calibration.json. A check that calibration
marks `off` turns on only from app code in a debug build; `settings.refused` and `settings.dropped` say what was not
taken.

## Quran Lab platform

`QuranLab.configure(key:)` links the app to [portal.quranlab.ai](https://portal.quranlab.ai): registration (once per
UTC day per install), the signed config (refreshed within a minute of a portal change), issue reports (kind and code
only), and telemetry. What the SDK sends, when, and what an app can change is in
[docs/platform-client.md](docs/platform-client.md), the same page in every TajweedFormer SDK.

Telemetry is on by default and anonymous by construction: sums and histograms per UTC day (backend and fallback
reasons, device class, latency, real-time factor, sessions and minutes, surah coverage, presets in use, flag rates,
margins and confidences, downloads, and since 2.0.1 launches, ayahs and words scored, per rule what was checked and
flagged, and how often the sharing sheet was shown and answered), never audio, recognised text or any identifier.
Since 2.0.1 it goes as deltas during the day: every 15 minutes while the app is in use, when it goes to the
background, and at launch, each with a random `report_id` so a retry is counted once. The signed config's
`flags.analytics` turns it off for every install of an app; `analytics: .off` turns it off in code.

## Sharing recitations

Quran Lab decides per app whether the SDK offers sharing (the signed config's `flags.contributions`; since 2.0.1
`QuranLab.Options.contributions` is ignored). Set `audience: .children` for a children's app. Offered is never consent:
nothing is recorded for sharing or sent before the learner taps "Share". The SDK asks at the right moment: never on
first launch; after a finished session with feedback (`endSession(feedback:)`); after "Not now" again, each time at
least 7 sessions later, until the sheet was shown three times on the install in all, then never. Apps may choose the
timing (`Contributions.askNow()`; it counts as one of the three). A yes ends asking for good: the learner keeps the
consent version they agreed to across copy decks, your wording and SDK upgrades (a 2.0.0 grant keeps sharing under
`share-2026-11-07b`, with no sheet), and every shared session carries that version. Turning sharing off after a yes
never brings the sheet back; only the settings switch turns it on or off again. The copy ships in eight languages
(deck `2026-11-09.1`, consent version `share-2026-11-09`). `SharingSettingsView` gives the learner the switch, "What is
shared", "Delete what I shared" and their recovery code; stopping and deleting work whatever version the learner
agreed to.

How the ask looks:

1. **Default.** The SDK's own sheet: add `.quranLabSharing()` to a SwiftUI view near the root, or present
   `SharingConsentViewController` (UIKit) or `SharingConsentViewControllerMac` (AppKit) when `endSession` returns
   `.ask`. On iOS an app that does neither still gets the sheet, over the front view controller.
2. **Themed.** `SharingTheme` (accent, background, text and secondary text colours, corner radius, title and body
   fonts): pass it to `.quranLabSharing(theme:)` and the views, or set `Contributions.theme` once (the sheet the SDK
   presents by itself uses it). The words and the consent version do not change.
3. **Your own UI.** `Contributions.setPresenter { moment in ... }`: the SDK hands each moment (`.ask`, `.thanks`) to
   your closure on the main actor and shows nothing itself. Show the strings of `Contributions.copy`, with buttons of
   equal weight, and report the learner's own tap with `Contributions.answer(share:guardianConfirmed:)`. The SDK
   counts the asks and keeps the same rules (three in all) as for its own sheet.
4. **Your own wording.** `try Contributions.setWording(["sheet.what": "...", ...])` (deck keys; a plural line by
   category, `impact.minutes.one`) before the first session, at every launch. A learner who agrees from then on
   agrees to your words: their consent version is `custom-` and 24 hex digits of the words' hash, and every session
   they share carries it and `consent_text_sha256`. A learner who agreed earlier is not asked again and keeps the
   version (and hash) they agreed to.
   `Contributions.consentTextSHA256` and `Contributions.consentText` give you the hash and the canonical text to send
   to Quran Lab. An unknown key or an empty text throws `invalidArgument`. Your words must still say that the audio
   of recitation sessions is sent to Quran Lab, what else is sent, what it is used for, and how to stop and delete.

While the learner shares, every take is uploaded in full as it runs: Ogg Opus, mono, 48 kHz, in segments of 10, 20, 40
and then 60 seconds, PUT to presigned URLs from a persistent outbox that survives force-quit and reboot. On a bad
network the SDK lowers the bitrate of the audio still to be encoded (192, 96, 64, 32 kbit/s: a network failure of an
upload, or 120 s or more of closed audio waiting when a segment closes, one step down; three uploads in a row with at
most 30 s waiting, one step up); a change takes effect at the next segment, and `Contribution.segmentBitrates` lists
each segment's bitrate. Details: [docs/platform-client.md](docs/platform-client.md). Deleting is
signed with a P-256 key made on the device (in the Secure Enclave where there is one): no app key or token can delete
a learner's recordings, and there is no call to do so for another learner. On a Mac without App Attest support
(`DCAppAttestService.isSupported` false), the SDK runs unattested and sharing waits until Quran Lab opens the
`capped` upload tier for macOS.

## Build and test

```sh
git clone --recurse-submodules https://github.com/Quran-Lab/tajweedformer-apple
cd tajweedformer-apple
scripts/build_xcframework.sh     # TajweedFormerCore.xcframework from the pinned engine
swift test
```

CI (`.github/workflows/ci.yml`) builds the xcframework from the pinned engine, runs `swift test` on macOS with the V4
test assets (the engine's conformance through the SDK's stream API, the scorer and layer vectors, the format 3
folder, the CoreML packages on the runner's CPU), the sharing tests under the thread sanitizer, and builds the package
for iOS, the iOS Simulator and macOS. `scripts/make_test_folder_v4.py` writes the small synthetic folder the format 3
tests use.

| Path | Contents |
|-|-|
| `Sources/TajweedFormer/Model` | the manifest, the download profile, the installer, gzip, the store |
| `Sources/TajweedFormer/Tajweed` | the recognizer, both backends, the layers, settings and the scorer |
| `Sources/TajweedFormer/Cloud` | token and App Attest, config, registration, telemetry, issues, updates, the sharing outbox |
| `Sources/TajweedFormer/Sharing` | the consent state and views, the copy decks, the device key, the Ogg Opus writer |
| `engine/` | tajweedformer-engine, pinned |

libopus 1.6.1 is BSD-3-Clause; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Download size

The SDK downloads only the Apple profile of the model folder (`sdk/v4.0`, manifest format 3), gzip on the
wire, resumable, every file checked against the signed manifest. One download serves both backends and every
context: the exact CPU engine rebuilds its weights on the device from the CoreML package's weights.

| Profile | What is downloaded | Size (gzip) |
| - | - | - |
| Default (iOS 18+, macOS 15+) | tokens, calibration, expected table, the c16_l64 graph and frames, the shared fp16 CoreML package (every context), its keep tables, the CPU engine's sidecar `coreml/engine.zfs` | **about 125 MB** |
| Compact (an app flag, for low-storage devices) | the same with the int8 CoreML package and its sidecar | **about 60 MB** |
| iOS 15 to 17, macOS 12 to 14 (no multifunction CoreML) | the CPU set, as on Android | **56.5 MB** |

The Apple sizes are estimates until the CoreML package build measures them on a Mac.

## Licence

Quran Lab is a waqf: the SDKs and the models are free to use and are never sold.

The source code in this repository and the TajweedFormer model weights are released under the
Quran-Lab No-Profit License 1.2 ([NPL-1.2](LICENSE)): use, copy, modify and build on them freely,
but never charge for them, for access to them, or for any feature they power. The weights are not
stored in this repository; Quran Lab hosts them itself and serves them to apps by
`cdn.quranlab.ai/models` under the same licence. Request access at
[portal.quranlab.ai/access](https://portal.quranlab.ai/access).

Third-party components keep their own licences, listed in their folders under `third_party/`.
