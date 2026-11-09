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

- **What it is:** the Swift package `TajweedFormer` (SDK 2.0.0) for the Quran Lab TajweedFormer V4 model
  (`Quran-Lab/tajweedformer-v4`, folder `sdk/v4.0`). It hosts only V4; the earlier phoneme models stay with the 1.x
  SDKs.
- **Platforms:** iOS 15 and macOS 12 on Apple silicon. The Neural Engine backend needs iOS 18 or macOS 15; on older
  systems the exact CPU engine runs.
- **Status:** preview.

## Quick start

```swift
import TajweedFormer

QuranLab.configure(key: "qlk_v1_...", options: .init(contributions: true))   // once, at launch

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
| iOS 18 / macOS 15, default | about 610 MB (three CoreML fp16 packages and three CPU engine folders), or 206 MB for the default context alone | about 125 MB: the CPU files of the context, ONE fp16 CoreML package for every context, its keep table and the correction file |
| iOS 18 / macOS 15, `compactCoreML: true` | the same | about 60 MB: the same with the int8 package, for low-storage devices; slightly less accurate |
| older systems | the same | about 56.5 MB: the CPU files only |
| another context later | another full folder | about 1 MB |

The CPU engine's weights (`layers.zfw`, `frontend.zfw`) are not downloaded on iOS 18 / macOS 15: they are rebuilt on
the device from the CoreML package's own int8 weights plus `coreml/engine.zfs` right after the download, byte for
byte, and checked against the manifest's SHA-256 like any download. If the correction is missing or a rebuild fails,
they are downloaded instead. A device holds one CoreML build: the default fp16 package, or with
`QuranLab.Options(compactCoreML: true)` the int8 package (for low-storage devices; slightly less accurate); changing the
option replaces the build on disk at the next install. `QuranLab.Options(neuralEngine: false)` downloads the CPU set
only.

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

CPU first, the Neural Engine as a verified upgrade. With `.automatic` (the default, no code needed):

1. The exact CPU engine serves from the first take, always. Its weights are rebuilt from the CoreML package right
   after the download, before any CoreML work starts.
2. The CoreML package is prepared in the background, at low priority and with a timeout: the first load of the
   context's functions with the Neural Engine allowed, which runs the on-device compiler. On macOS this starts once the
   CPU engine is ready; on iOS after the first finished take, or earlier from the app's background task
   (`QuranLab.registerAcceleratorPreparation(identifier:)`, a `BGProcessingTask` that waits for external power).
3. A self-test before promotion, on the model folder's self-test set (`selftest/`, Basmala clips included): greedy
   tokens identical to the exact engine's expected outputs on the clean clips, and flagged sites and flagged words
   identical on every clip at the default settings (compared as sets both ways, so a missed flag on the
   planted-mistake clip fails as surely as an extra one; its tokens are not compared, since a mistaken reading may
   decode differently at int8 and fp16 while flagging the same sites);
   no NaN or inf; per-chunk p90 at most half the chunk's audio, and the median below the CPU engine's in the same run.
   A failure is kept for that model revision, OS build, device model and context and never retried for them; a new
   revision or OS build prepares again.
4. Promotion at the next take, never during one.
5. Runtime guards: a chunk over three times its audio, a NaN or inf, three all-blank chunks in a row while the audio
   has energy, or an exception sends the take back to the CPU engine (it re-runs there; chunks already handed out are
   not handed out again) and keeps the CPU engine for the rest of the launch; a second trip on the same model revision
   and OS build, in any launch, disables the package for them for good. A crash sentinel is written before every
   load and first prediction; found at the next launch, it disables the package for that revision and OS build.
   Thermal state serious or critical, and memory warnings, prefer the CPU engine.
6. The signed config's deny-list forces the CPU engine per device class, OS version or model revision. Every
   fallback, its reason and the time to ready go to telemetry.

The app can watch it (`acceleratorState`: `.cpu`, `.preparing`, `.ready`, `.disabled(reason)`;
`acceleratorStates()` streams changes), wait for it (`awaitReady(timeout:)`), or choose a backend: `.exact` always,
`.neuralEngine` in debug builds (no self-test).

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

`QuranLab.configure(key:)` links the app to [portal.quranlab.ai](https://portal.quranlab.ai): registration, the signed
config (refreshed within a minute of a portal change), issue reports (kind and code only), and telemetry.

Telemetry is on by default and anonymous by construction: daily sums and histograms (backend and fallback reasons,
device class, latency, real-time factor, sessions and minutes, surah coverage, presets in use, flag rates, margins and
confidences, downloads), never audio, recognised text or any identifier. The signed config's `flags.analytics` turns
it off for every install of an app; `analytics: .off` turns it off in code.

## Sharing recitations

One switch: `QuranLab.Options(contributions: true)` (and `audience: .children` for a children's app). The SDK then
asks the learner at the right moment with its own consent sheet: never on first launch; after a finished session with
feedback (`endSession(feedback:)`); after "Not now" at most twice more, each at least 7 sessions later. Add
`.quranLabSharing()` to a SwiftUI view near the root, or present `SharingConsentViewController` (UIKit) or
`SharingConsentViewControllerMac` (AppKit) when `endSession` returns `.ask`. `SharingSettingsView` gives the learner
the switch, "What is shared", "Delete what I shared" and their recovery code. The copy ships in eight languages; apps
may restyle it and choose the timing (`Contributions.askNow()`), never change what it discloses.

While the learner shares, every take is uploaded in full as it runs: Ogg Opus, mono, 48 kHz, in segments of 10, 20, 40
and then 60 seconds, PUT to presigned URLs from a persistent outbox that survives force-quit and reboot. Deleting is
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
| `Sources/TajweedFormer/Model` | the manifest, the download profile, the installer, gzip, the correction rebuild, the store |
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
