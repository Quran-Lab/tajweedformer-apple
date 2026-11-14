# TajweedFormer for iOS and macOS: reference for coding assistants

Everything an assistant needs to integrate this SDK correctly: use only the names, calls and settings shown here or in the installed version's sources. People: the short version is in [README.md](README.md).

## What you get

<table>
<tr>
<td width="33%" valign="top">

**Hears the recitation**<br>Streaming recognition of Quranic recitation: audio in, and what the model heard comes out as often as every 160 ms on the CPU engine (320 ms by default, including on the Neural Engine; 480 ms for longer context).

</td>
<td width="33%" valign="top">

**Every output of the model**<br>The sounds it heard with confidence and timing, and every head of the network per chunk (lengthening, gemination, ghunna, qalqalah and more): yours to build on.

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

**Nothing to host**<br>The SDK downloads the right model for each device (56.5 MB to start) from our CDN in six regions, verifies it and keeps it up to date.

</td>
<td valign="top">

**Data for your own judge**<br>The SDK scores nothing. The model's thresholds come with it as read-only data, so your app can judge a recitation its own way. The expected units of each ayah do not: with this release and the model build served now, `model.reference` is nil.

</td>
</tr>
</table>

## Why TajweedFormer

- **Made for the Quran.** Trained on Quranic recitation, with its own sound units and heads for what tajweed is about.
- **Feedback in the moment.** Output streams while the learner recites, so your app can respond on the word itself, not after the take.
- **One engine on every platform.** The same engine runs the [iOS and macOS](https://github.com/Quran-Lab/tajweedformer-apple), [Android](https://github.com/Quran-Lab/tajweedformer-android), [web](https://github.com/Quran-Lab/tajweedformer-web) and [Windows and Linux](https://github.com/Quran-Lab/tajweedformer-c) SDKs, all set from one portal.
- **Free, and it stays free.** Quran Lab is a non-profit waqf: the SDKs and models are never sold. The licence, NPL-1.2, asks three things: no paywall on model features, no results presented as rulings, and show the notice.

## Built for AI developers

Copy the setup prompt from [sdk.quranlab.ai](https://sdk.quranlab.ai) and paste it into your coding assistant. That one prompt sets everything up: the package, your key, and the first calls. [AGENTS.md](AGENTS.md), beside this README, gives the assistant the complete API, so the code it writes uses names that exist. Prefer to do it by hand? Get a key in the portal and start below.

## At a glance

- **What it is:** the Swift package `TajweedFormer` for the Quran Lab TajweedFormer V4 model
  (`Quran-Lab/tajweedformer-v4`, folder `sdk/v4.0`): audio in, the model's output out (every head of the network per
  chunk, and what it heard with confidence and timing). SDK 3.0.0 is inference only: it scores nothing and holds
  no tajweed settings (SDK 2.x did; see [docs/migrating-to-3.md](docs/migrating-to-3.md)). It hosts only V4.
- **Platforms:** iOS 15 and macOS 12 on Apple silicon. The Neural Engine backend needs iOS 18 or macOS 15; on older
  systems the exact CPU engine runs.
- **Status:** released; this is version 3.1.4. CI builds every push for iOS and macOS and runs the tests on macOS.
  The whole path through the public API (the key and the signed config, the download, the verified model, the
  promotion pipeline, takes on the CPU engine and on the Neural Engine) has run on an Apple silicon Mac against
  Quran Lab's servers with `scripts/prove-on-mac.sh` (version 3.0.0); that proof has not been run on an iPhone.

## Install

In Xcode: **File > Add Package Dependencies**, enter `https://github.com/Quran-Lab/tajweedformer-apple` and choose version 3.1.4. In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Quran-Lab/tajweedformer-apple", from: "3.1.4"),
],
// and in your target's dependencies:
.product(name: "TajweedFormer", package: "tajweedformer-apple"),
```

## Before you start

| | |
| - | - |
| **Key** | An iOS or macOS key from [sdk.quranlab.ai](https://sdk.quranlab.ai), for your app's bundle id. |
| **Devices** | iOS 15 and macOS 12 or later, on Apple silicon only: the binary has arm64 slices for devices, the arm64 simulator and arm64 Macs. Intel Macs and the x86_64 simulator are not supported. Xcode 16 or later (Swift tools 6.0). |
| **Permissions** | `NSMicrophoneUsageDescription` in Info.plist: without it the system ends the app at the first use of the microphone. A sandboxed or hardened Mac app also needs the `com.apple.security.device.audio-input` entitlement. |
| **Capabilities** | None for recognition. If your app offers recording sharing, add the App Attest capability: uploads need an attested install. Without it the SDK still runs, unattested. |
| **Download** | The first launch downloads the model: 56.5 MB, once (73.5 MB on disk), on any network. On iOS 18 and macOS 15 the Neural Engine's build follows in the background on Wi-Fi: 76.1 MB more. |
| **Network** | No request of the SDK follows a redirect: an answer that is one is a failed request, never followed. |
| **Model** | A model comes only from Quran Lab's server, through the Client: `try await client.model()`, or `client.prefetch()` ahead of use; the Client opens only a model it downloaded itself on this device, and an app that updates from an SDK before 3.1.0 downloads the model once more. When Quran Lab refuses the key or the app (a revoked key, a paused or blocked app), the SDK stops running the model and removes the downloaded model from the device. Once the key is accepted again the model is downloaded again. What the system cached by itself stays: the compiled form that Core ML keeps for the Neural Engine of a package the SDK loaded. |
| **Keychain** | The SDK keeps one key per install in the Keychain (this device only) and marks with it the model it downloaded. A Mac app without a provisioning profile (an unsigned or ad hoc signed binary, a command line tool) is refused by that keychain: there the key lives in the Mac's login keychain, in an item named for the app's bundle id, and can travel to another Mac with the keychain. |
| **Takes** | A Model has one open Session (one take) at a time; the next take is a new Session. A take holds at most 20 minutes of audio. |

## Quick start

From your key to what the model hears from the microphone, in four steps: Client, model, listen, read.

```swift
import TajweedFormer

func quickStart(key: String) async throws {
    let client = try TajweedClient(key: key)                  // once per process; your key from sdk.quranlab.ai
    let model = try await client.model()                      // downloads the model once, verifies it, opens and warms it
    let session = try await model.listen(options: .init(endOnSilenceMs: 1500))   // asks for the microphone
    for await chunk in session.chunks {                       // every 320 ms, until 1.5 s of silence end the take
        print(chunk.decoded.text)                             // what the model heard so far
    }
}
```

Call it from a button: `Task { try await quickStart(key: "qlk_v1_...") }`. `listen()` asks for the microphone,
captures at the device's own rate and carries that rate to the Session, so no sample rate appears here. With
`endOnSilenceMs` the take finishes by itself 1.5 s after the learner stops; without it, call
`try await session.finish()`. Silence is what the model hears as silence (a held vowel is not silence), so in a
noisy room a take may not end on silence: keep a Stop button that calls `session.finish()`; the 20-minute limit ends
the take in any case. `endOnSilenceMs` takes 500 to 60000; values under 1000 can end a take in a breath pause between
two words, and 1500 is what this quick start uses.

Each `chunk` carries the raw heads you selected (`chunk.heads`) and the decoded layer of the take so far
(`chunk.decoded`: the text, each token with its times and confidence, and how many tokens are settled). The next take
is a new `model.listen()`. Every error is a `TajweedError` with a stable `code`, a `fix` and a `docs` link.

The code is [`examples/QuickStart`](examples/QuickStart), a program CI builds: `swift run QuickStart` runs a sample
clip of the model through the same path with no microphone, `swift run QuickStart --listen` listens.

## The five things

| | What it is | How you get it |
|-|-|-|
| `TajweedClient` | The app's link to Quran Lab: the key, the signed config, the model files, telemetry, sharing. One per process. | `try TajweedClient(key:)` |
| `TajweedModel` | One verified model build on the device, with the engine loaded. | `try await client.model()` |
| `TajweedSession` | One take: audio in, chunks and events out, the take's Heads at the end. | `model.listen()` (the SDK captures) or `model.session()` (you push audio) |
| `TajweedHeads` | The raw output of the network for a span of audio. | `chunk.heads`, and the whole take from `session.finish()` |
| `TajweedBackend` | What runs the model: the CPU engine or the Neural Engine's build. | `chunk.backend`, `session.backend`, `model.backend` |

Every public name is in [docs/api.md](docs/api.md), generated from the sources. Coming from 2.x:
[docs/migrating-to-3.md](docs/migrating-to-3.md).

## What the SDK gives

SDK 3.0.0 is an inference engine. It gives the model's output and nothing derived from a known text: it does not
score a recitation, flag a mistake or hold tajweed settings. An app that judges a recitation does it with its own
rules over this output.

- **Heads.** Every chunk (320 ms by default) and the finished take carry the heads you selected, as Float arrays
  with their name, kind, frame length, frame count and class count (`TajweedHead`): the CTC heads `log_probs`,
  `inter1_log_probs`, `inter4_log_probs` (40 ms frames), `id_log_probs`, `timing_log_probs`, and the attribute heads
  `gem`, `attr_tafkheem`, `attr_ghunna`, `attr_qalqalah`, `attr_face`, `boundary`, `conf` (20 ms frames).
  `TajweedSessionOptions.heads` selects them: `defaultHeads` (six), `allHeads` (twelve) or your own list. The CPU
  engine computes only the heads asked for, so a head nobody asked for costs nothing; the CoreML package computes
  all twelve.
- **The decoded layer** (`chunk.decoded`, `heads.decoded()`): what the model heard so far. The text, each token with
  its id, name, times and confidence, the words between word bars, and per 40 ms frame the top token and the runner-up
  with their log-probabilities and the margin; with `topK` above 0, the K best tokens of every frame. `settled`
  says how many tokens will not change any more; `isFinal` marks the take's last chunk. No known text is involved.
- **Events** (`session.events`): `speechStarted` and `speechEnded` (a frame is speech within 12 frames of a token),
  `interrupted` and `resumed` (a call, another app, a change of input device), `backendChanged` (a failover replaced
  the chunks from an index on), and `ended` with its reason: `silence` (with `endOnSilenceMs`), `background`,
  `interrupted`, `sourceEnd` (a clip ran out), `limit` (a take holds at most 20 minutes of audio) or `error`.

A take is one Session. `model.listen()` asks for the microphone and captures at the device's own rate;
`model.listen(from:)` runs a sample clip or your own samples through the same path; `model.session()` takes the
audio you push. The next take is a new Session from the same Model, which keeps the engine loaded; a Model has one
open Session at a time (`session_open`). When the app returns from the background, start a new take: the one that
ran ended with `ended(.background)`.

What waits for your app is bounded: at most 256 chunks and 64 events wait unread, and when you read late the oldest
waiting ones are dropped. Nothing is lost with them: each chunk's `decoded` is the take so far, the last chunk and
`ended` are never the ones dropped, and `finish()` returns the whole take. `diagnose().droppedChunks` counts them.

## Calibration and reference data

Two files of the model are data for an app's own judge. The SDK hands them over and applies neither.

- **`model.calibration`** is `calibration.json` exactly as the model ships it: the thresholds and fusion weights
  Quran Lab measured for this model, per context, site class and preset (`threshold(context:class:preset:)`,
  `status(context:class:)`, `fusionWeight(context:class:)`, and `number(...)` or `string(...)` for any other field),
  with the file's bytes and its SHA-256 from the signed manifest. A class whose status is `off` or `experimental`
  was not validated: treat its numbers as a starting point.
- **`model.reference`** is the table of expected units for every ayah (the tokens a correct recitation writes, and
  where each word starts). It is not part of the model's download: `try await model.reference?.fetch()` brings it
  once, verified against the signed manifest, and `units(surah:ayah:)` reads it. A build without the
  table gives nil. The SDK never aligns it with a take.

`model.tokens` is the vocabulary (38 tokens: names, ids, the blank and the word bar), and `model.sampleClips` are
short recitations of the model's self-test set, to run the whole path without a microphone.

## What a device downloads

The model folder is signed (manifest format 3, Ed25519) and every file is tagged with the platforms, context and role
that decide which device downloads it. Large files travel gzip and are kept decoded. Downloads use HTTP Range into a
`.part` file and resume after the app is killed; each file is checked by size and SHA-256 before and after it is
inflated, and a mismatch deletes both.

A model has a version (`model.version`, `"4.0.0"`) and a folder is one build of it (`model.build`, the first 40 hex
digits of the SHA-256 of its manifest). Quran Lab's signed config names the version and the build for each app;
`client.model(version:)` asks for a version. The SDK refuses a manifest whose signature does not verify
(`signature_invalid`), that has no version or needs a newer SDK (`model_incompatible`), or that is not the build the
config named (`checksum_mismatch`). When Quran Lab has no build for this SDK version yet, `client.model()` throws
`model_unavailable`; a first run without a network throws `needs_connection`.

| iPhone or Mac, default context | What is downloaded |
|-|-|
| first install, any iPhone or Mac | the CPU files of the context only |
| later, iOS 18 / macOS 15, in the background | on an unmetered network: one fp16 CoreML package (`coreml`) for every context, as a delta against the CPU weights already on the device: 76.1 MB (the whole program, 119.5 MB, when the delta cannot be used), with the context's keep table and the self-test set, 77.2 MB in all |
| only for a Session with `backend: .coremlCompact` | the compact CoreML package (`coreml-compact`, int8) the same way: a delta of 1.7 MB (the whole program, 53.9 MB, when the delta cannot be used), 2.8 MB in all |
| another context later | its own small files, at the first Session that names it |
| the reference table | only when the app calls `model.reference?.fetch()` |

`client.prefetch(unmeteredOnly:onProgress:)` downloads ahead of use, resumable, with the bytes done and the total.
With `unmeteredOnly: true` it downloads on Wi-Fi or Ethernet and does nothing on cellular, a personal hotspot, a
network in Low Data Mode or no network (call it again later). Where the system does not say what the connection is
(`diagnose().connection` is `unknown`) the option cannot be honoured, and it downloads.
`client.storage` says what is on disk (bytes per model build, and of the sharing queue), and
`client.removeModels()` removes the model files, never the learner's sharing choice or the upload queue.

A model comes from Quran Lab's server, through the Client: `client.model()` and `client.prefetch()` are the calls
that bring one to a device, and no call opens a model folder the app supplies. The Client opens only a build it
downloaded itself on this device. A model folder in its storage that it did not download (put there in advance, or
copied from another device) is not opened: it is deleted, and the build is downloaded.
After that download a learner without a connection keeps working. Every request for a model file carries the
developer key and the install's token. An install that updates from 3.0 downloads its model once more at the first
launch after the update (`needs_connection` when that launch has no network).

## Backends and the CPU fallback

- **Neural Engine** (iOS 18, macOS 15): one multifunction CoreML package; each context's two functions are loaded
  with `MLModelConfiguration.functionName` (`front_<ctx>`, `back_<ctx>`). Features come from the engine's exact fbank.
- **Exact CPU engine**: [tajweedformer-engine](https://github.com/Quran-Lab/tajweedformer-engine), pinned as `engine/`. The
  same bits on every device, for every head of every chunk.

The default context is `c16_l64` (320 ms chunks); Quran Lab's signed config can name another for an app
(`inference.context`), and `TajweedSessionOptions.context` wins over both. `c8_l64` (160 ms chunks) has no CoreML
package: it always runs on the exact CPU engine.

### CPU first, then the accelerator

The Neural Engine's build is the fp16 CoreML build (`coreml`). The compact build (`coreml-compact`: int8 weights, a
download of 1.7 MB where the fp16 build's is 76.1 MB, for devices short of storage) is fetched and tried only when a
Session names it, `TajweedSessionOptions(backend: .coremlCompact)`; a device does not try it on its own. Both go
through the same pipeline, and a folder may hold both. One limit in 3.0.0: a Model warms the default Session when it
is opened, and that Session's pipeline starts by itself after 20 seconds without a take, so an app that names
`.coremlCompact` and whose first take starts later than that also downloads the fp16 build (on Wi-Fi or Ethernet).

With `backend: .auto` (the default, no code needed):

1. **First run.** The first install downloads only the CPU set. The first take runs on the exact CPU engine and
   nothing is queued in front of it: the Neural Engine's work starts after the first take ends, or after 20 seconds
   with no take. On every later launch the CPU engine serves until the Neural Engine is loaded and warm again; a
   take never waits for it.
2. **In the background,** one pipeline per model build, context, OS build and device model, with its state kept on
   disk after each stage (an app killed in the middle resumes at the next launch where it stopped): download (the
   CoreML build, its keep table and the self-test set, on Wi-Fi or Ethernet only, resumable, every file verified),
   compile (the first load with the Neural Engine allowed, 10 minutes at most), warm-up (silence and a self-test
   clip; no NaN or inf), golden test, measure, promote. It runs only while the device is in good shape (not in Low
   Power Mode, battery at least 20 % or charging, thermal state nominal or fair) and waits otherwise.
3. **The golden test** runs every clip of the model's self-test set through the Neural Engine and through the CPU
   engine, with the same streaming code a take uses, and compares the raw outputs: per CTC head the greedy tokens
   (edit distance) and the distance of the log-probabilities (mean and 99th percentile), and the mean difference of
   the attribute heads' probabilities. A build passes within the tolerance the signed manifest gives it
   (`golden_raw_tolerance`); without one it must give the CPU engine's tokens exactly. The CPU engine's own tokens
   must equal the shipped expected file. It runs only while no take runs.
4. **The swap** happens only when a take starts, and only to a build that is loaded and warm: the app sees the same
   API and faster chunks; `session.backend` says which engine runs, `model.backend` which the next take will use
   and where the promotion stands (`stage`: `cpu`, `downloading`, `compiling`, `testing`, `promoted`, `demoted`,
   with a `reason` when it failed).
5. **Failing safe.** Any failure keeps the CPU engine and records the stage and the reason. A failure is retried
   for the same model build and OS build after 1 hour, 6 hours and 24 hours, then not again; a golden-test mismatch,
   a NaN or a crash is never retried for them (a new build or an OS update tries again). The signed config's
   deny-list (`denylist` and `accel_deny` rules) keeps the Neural Engine off.
6. **During a take**, every Neural Engine chunk is checked: an exception, a NaN or infinite value, a value outside
   the heads' range, or a chunk that misses its deadline. The take then switches to the CPU engine at that chunk:
   its recent audio is replayed through it, and the take continues with no error. When the CPU's replay changes
   chunks the app already has, the event `backendChanged(backend:fromChunk:)` says from which index on, and those
   chunks come again on `chunks` with the same `index`: replace what you have for them.
   - **Silence is not a fault.** The model writes nothing during a long madd or a held vowel, so a few chunks with no
     token in audio with sound are only a suspicion: the SDK replays that audio (the last 30 seconds at most) through
     the CPU engine in the background, and switches only when the CPU engine writes tokens there.
   - **A cold start is not a fault.** The Neural Engine is warmed up when a take starts and when the app becomes
     active; the first chunk after that has a longer deadline.
7. **Telemetry and incidents.** Per backend, model version, build and context: the attempts, promotions, the stage
   and reason of each failure, the compile time and the speedup, the switches inside takes with their cause. Every
   failure and switch is also an issue report (`promotion_failed`, `accelerator_failover`) with the stage, the cause,
   the device model, OS build and chip, and for a failed golden test what was measured against which tolerance. No
   audio, text or identifier.

## Quran Lab platform

`TajweedClient(key:)` links the app to [sdk.quranlab.ai](https://sdk.quranlab.ai): registration (once per UTC day per
install), the signed config (refreshed within a minute of a change), issue reports (kind and code only), and
telemetry. What the SDK sends, when, and what an app can change is in
[docs/platform-client.md](docs/platform-client.md), the same page in every TajweedFormer SDK.

Telemetry is on by default and anonymous by construction: sums and histograms per UTC day (per model version, build,
context and backend: takes, minutes of audio, speech and silence, tokens per head, compute time, latency and
real-time factor; downloads; launches; promotions), never audio, recognised text or any identifier. It goes as
deltas during the day, each with a random `report_id` so a retry is counted once. Two calls add what only the app
knows, for its own page on sdk.quranlab.ai:

- `try session.reportRecited(surah:ayahFrom:ayahTo:)`: where the learner recited in this take (one report per take).
- `try client.analytics.reportChecks(rule:checked:flagged:)`: how often the app's own judge checked a rule and how
  often it flagged it (at most 32 rules a day).

`TajweedClientOptions(analytics: .off)` turns telemetry off in code; Quran Lab's config can turn it off for every
install of an app.

When Quran Lab refuses the key or the app (a revoked key, a paused or blocked app), the SDK stops running the model
and removes the downloaded model from the device. Once the key is accepted again the model is downloaded again.
`client.model()` and `client.prefetch()` throw the refusal's error meanwhile (`invalid_key`, or `server_rejected`
with its reason), also at a later launch without a network. A Model that is already open when the refusal arrives
keeps running until the app closes it, and its files are removed then. The learner's sharing choice and the
recordings that are not sent yet stay. What stays on Apple platforms after the removal is what the system cached
by itself: the compiled form that Core ML keeps for the Neural Engine of a package the SDK loaded.

`await client.diagnose()` is one report of where the SDK stands, safe to paste into an issue (`.json`): the SDK's
version and the newest one, whether the key is accepted, the config, the model's version and build, the context,
the backend, the microphone permission, what is on disk, the last error's code, the dropped chunks and the
connection (`unmetered`, `metered`, `none` or `unknown`). Every error
the SDK throws is a `TajweedError` with a stable `code` (26 codes, the same in the four SDKs), a `message`, a `fix`
and a `docs` link.

## Sharing recitations

Quran Lab decides per app whether the SDK offers sharing (the signed config); the developer switches nothing on.
Set `TajweedClientOptions(audience: .children)` for a children's app. Offered is never consent: nothing is recorded
for sharing or sent before the learner taps "Share". The SDK asks at the right moment: never on first launch; after
a finished take in which the model heard something; after "Not now" again at least 7 takes later, until the sheet was
shown three times on the install in all, then never. `client.sharing.ask()` asks now (it counts as one of the
three). A yes ends asking for good: the learner keeps the consent version they agreed to across copy decks, your
wording and SDK upgrades, and every shared recording carries that version.

- The sheet: add `.quranLabSharing(client)` to a SwiftUI view near the root, or present
  `SharingConsentViewController` (UIKit) or `SharingConsentViewControllerMac` (AppKit). On iOS an app that does
  neither still gets the sheet, over the front view controller. It has its own design: the Quran Lab emblem and
  name at the top, what is shared, who receives it and how to stop in one card, and the two buttons, of the same
  size, in a bar that does not scroll; full height with a grabber on an iPhone, a centred card 480 points wide on
  an iPad or a Mac; its own colours for light and dark mode; the system font, growing with the learner's text
  size. Nothing set on your own views (a font, a weight, a text size, a line limit) changes it.
- Theming: `SharingTheme` sets the accent (the share button and the switch; the tint of "Not now", the emblem and
  the hadith's card comes from it, and where the accent cannot be read on that tint, "Not now" and the icons take
  the text colour), the background, text and secondary colours (the cards and dividers follow them), the corner
  radius (the buttons'; the others scale with it) and the title's and running text's fonts. Left at its defaults
  the sheet takes your app's accent colour and its own colours and type. A theme never changes the order of the
  sheet, hides a line or the name, or changes a word or the consent version.
- The settings: `SharingSettingsView` gives the learner the switch, "What is shared", "Delete what I shared" and
  their recovery code. In code: `client.sharing.isAvailable`, `isOn`, `setOn(_:)`, `items` (the outbox),
  `summary()`, `delete()`, `recoveryCode`.
- Your own wording: `try client.sharing.setWording([...])` by the deck's keys, before the first take at every
  launch. A learner who agrees from then on agrees to your words, under a consent version derived from them. Your
  words must still say that the audio of recitation takes is sent to Quran Lab, what else is sent, what it is used
  for, and how to stop and delete.

No request of the SDK follows a redirect: an answer that is one is a failed request, never followed. On one path
the system does not ask the SDK, the background session that uploads shared recordings on iOS: there the system
follows a redirect by itself, and the SDK then does not count that upload as done, sends the segment again later
with a fresh address, and reports the host it ended on (the host only) to Quran Lab.

While the learner shares, every take is uploaded in full as it runs: Ogg Opus, mono, 48 kHz, in segments, PUT to
presigned URLs from a persistent outbox that survives force-quit and reboot; on a bad network the SDK lowers the
bitrate of the audio still to be encoded. Turning sharing off, or deleting, cancels what is being uploaded at that
moment and deletes the unsent queue: once the call has returned the SDK hands nothing more to the system (what the
system had already buffered for the connection may still go out, which can be the segment being sent). Deleting is signed
with a P-256 key made on the device (in the Secure Enclave where there is one): no app key or token can delete a
learner's recordings.

Takes in a row are one recording: a recording stays open after a take for a few seconds (3 s; Quran Lab's config can
set it from 0, never, to 10 s), and a take that starts in that time continues the same stream. A recording never
holds more than 20 minutes of audio: at that point it closes, and a take that is still running goes on in a new one.

`client.sharing.feed(_:sampleRate:)` is for apps that capture audio themselves outside takes (before the first,
between them, after the last). With sharing on and the learner's yes, the SDK keeps the last second of what is fed
in memory and puts it in front of the next take's recording, and adds up to half a second after a take, so a
recitation is not clipped at a take's edges. The half second after a take is taken from what is fed within 1.5 s of
the take's end; what is fed later waits for the next take. Without a yes, during a take, or with sharing off, a fed buffer is
dropped at once and nothing of it stays in memory. The model never sees the feed. An app that uses `listen()` has no
audio outside takes and need not call it.

## Platform notes

- **Microphone.** `listen()` uses the SDK's `Microphone` (AVAudioEngine). The app needs
  `NSMicrophoneUsageDescription` in its Info.plist; a sandboxed or hardened Mac app also needs the
  `com.apple.security.device.audio-input` entitlement. A refusal is the error `microphone_denied`. Nothing is
  captured before `listen()` or after the take ends; when the app leaves the foreground the take ends with
  `ended(.background)`.
- **Privacy manifest.** The package and the engine's xcframework each carry a `PrivacyInfo.xcprivacy`; the SDK
  collects nothing linked to a person and uses no tracking.
- **App Attest.** Recognition needs no capability. Uploads of shared recordings need an attested install: add the
  App Attest capability if your app offers sharing. Without it the SDK still runs, unattested.
- **The install key.** The SDK keeps one key per install in the Keychain (this device only, readable after first
  unlock) and marks with it the model builds it downloaded; when the Keychain does not answer, `client.model()`
  throws `storage_failed` and the next call tries again. On a Mac, an app without a provisioning profile (an
  unsigned or ad hoc signed binary, a command line tool) is refused by that keychain, and there the key lives in
  the Mac's login keychain, in an item named for the app's bundle id, which can travel to another Mac with the
  keychain.
- **Apple silicon only.** arm64 devices, the arm64 simulator and arm64 Macs; iOS 15 and macOS 12 or later; Xcode 16
  (Swift tools 6.0).
- **One Client per process.** A second `TajweedClient` while the first is not closed throws `client_exists`.

## Build and test

```sh
git clone --recurse-submodules https://github.com/Quran-Lab/tajweedformer-apple
cd tajweedformer-apple
scripts/build_xcframework.sh     # TajweedFormerCore.xcframework from the pinned engine
swift test
```

CI (`.github/workflows/ci.yml`) builds the xcframework from the pinned engine, runs `swift test` on macOS with the V4
test assets (the engine's conformance through the SDK's stream API, the shared 3.0 vectors, the format 3
folder, the CoreML packages on the runner's CPU), the sharing tests under the thread sanitizer, and builds the package
for iOS, the iOS Simulator and macOS, and builds the example program. `scripts/make_test_folder_v4.py` writes the small
synthetic folder the format 3 tests use; `scripts/make_api_doc.py` writes [docs/api.md](docs/api.md) from the sources.

`scripts/prove-on-mac.sh <key> [<clips folder>]` is the proof on a Mac with a real key, against Quran Lab's servers:
it checks the Mac first (macOS 15, Xcode 16, Apple silicon, disk space, power, the network), then takes the whole path
through the public API (the Client and the signed config, the download with its progress, the verified model, every
sample clip in every context on the CPU engine and on the Neural Engine, the promotion pipeline for the fp16 CoreML
build with the golden stage's measures, `diagnose()`) and prints a one-screen summary. A build the golden stage does
not pass (measures outside the tolerance its signed manifest gives it, or tokens that differ from the CPU engine's
when the manifest gives it none) stays on the CPU engine, which is the pipeline's answer and no failure of the run.
The summary ends with the measures and a tolerance made from them, a proposal for Quran Lab's model side. `--compact`
takes the compact CoreML build through the pipeline as well. Nothing it prints names the key, the install or the app; the run
registers as "SDK proof (Mac)". `--check` only checks the Mac; `--help` says what the run sends. CI rehearses the
script over the test suite's stub server (`--rehearse`).

| Path | Contents |
|-|-|
| `Sources/TajweedFormer/Model` | the manifest, the download profile, the installer, gzip, the store |
| `Sources/TajweedFormer/API` | the public types: Client, Model, Session, Heads, Backend and their data |
| `Sources/TajweedFormer/Tajweed` | the recognizer, both backends, the promotion and its golden test, the decoded layer |
| `Sources/TajweedFormer/Cloud` | token and App Attest, config, registration, telemetry, issues, updates, the sharing outbox |
| `Sources/TajweedFormer/Sharing` | the consent state and views, the copy decks, the device key, the Ogg Opus writer |
| `engine/` | tajweedformer-engine, pinned |

libopus 1.6.1 is BSD-3-Clause; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Download size

The SDK downloads only the Apple profile of the model folder (`sdk/v4.0`, manifest format 3), gzip on the
wire, resumable, every file checked against the signed manifest. The CPU set comes first, so the first session
starts as soon as possible; the Neural Engine's build follows in the background. Sizes are those of model
revision v4.0-2026-11-10, default context `c16_l64`:

| When | What is downloaded | Size |
| - | - | - |
| First launch, every iPhone and Mac | tokens, calibration, expected table, the shared weights and front end, the c16_l64 graph and its frames | **56.5 MB** (73.5 MB on disk) |
| Later, iOS 18 and macOS 15, on Wi-Fi | the fp16 CoreML build for every context, as a delta against the CPU weights already on the device | +76.1 MB (the whole package, +119.9 MB, only if the delta cannot be applied) |
| Only for a Session with `backend: .coremlCompact` | the int8 CoreML build (`coreml-compact`) instead, for low-storage devices | +1.7 MB as a delta (+54.4 MB whole) |
| Another context later (CPU) | that context's graph and frames | +0.65 to 0.86 MB each |

iOS 15 to 17 and macOS 12 to 14 run the CPU engine only and download the first row only.

## Problems and wishes

Something does not work, something is missing, or you want to tell us how it went:
[open an issue](https://github.com/Quran-Lab/tajweedformer-apple/issues/new/choose). There is a form for a bug, one for a
wish and one for a word of feedback. Issues are public, so leave out keys and anything that came from a learner.
A security problem does not go into an issue: use "Report a vulnerability" on the
[Security tab](https://github.com/Quran-Lab/tajweedformer-apple/security). A coding assistant can file an issue for you; it
shows you the text first.

## Licence

Quran Lab is a waqf: the SDKs and the models are free to use and are never sold.

The source code in this repository and the TajweedFormer model weights are released under the
Quran-Lab No-Profit License 1.2 ([NPL-1.2](LICENSE)): use, copy, modify and build on them freely,
but never charge for them, for access to them, or for any feature they power. The weights are not
stored in this repository; Quran Lab hosts them itself and serves them to apps by
`cdn.quranlab.ai/models` under the same licence. Get access at
[sdk.quranlab.ai](https://sdk.quranlab.ai).

Third-party components keep their own licences, listed in their folders under `third_party/`.
