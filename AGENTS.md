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

**Nothing to host**<br>The SDK downloads the right model for each device (55.5 MB to start) from Quran Lab's servers, verifies it and keeps it up to date.

</td>
<td valign="top">

**Data for your own judge**<br>The SDK scores nothing. The model's thresholds come with it as read-only data, and the expected units of each ayah where the served build carries them, so your app can judge a recitation its own way.

</td>
</tr>
</table>

## Why TajweedFormer

- **Made for the Quran.** Trained on Quranic recitation, with its own sound units and heads for what tajweed is about.
- **Feedback in the moment.** Output streams while the learner recites, so your app can respond on the word itself, not after the take.
- **One engine on every platform.** The same engine runs the [iOS and macOS](https://github.com/Quran-Lab/tajweedformer-apple), [Android](https://github.com/Quran-Lab/tajweedformer-android), [web](https://github.com/Quran-Lab/tajweedformer-web) and [Windows and Linux](https://github.com/Quran-Lab/tajweedformer-c) SDKs, all set from one portal.
- **Free, and it stays free.** Quran Lab is a non-profit waqf: the SDKs and models are never sold. The licence, NPL-1.2, and Quran Lab's access terms ask two things: no paywall on model features, and no output presented as an authoritative religious ruling. A line telling learners that automatic feedback can be wrong is encouraged, not required.

## Built for AI developers

Copy the setup prompt from [sdk.quranlab.ai](https://sdk.quranlab.ai) and paste it into your coding assistant. That one prompt sets everything up: the package, your key, and the first calls. [AGENTS.md](AGENTS.md), beside this README, gives the assistant the complete API, so the code it writes uses names that exist. Prefer to do it by hand? Get a key in the portal and start below.

## At a glance

- **What it is:** the Swift package `TajweedFormer` for the Quran Lab TajweedFormer models: audio in, the model's
  output out (every head of the network per chunk, and what it heard with confidence and timing). Inference only:
  it scores nothing (see [docs/migrating-to-3.md](docs/migrating-to-3.md)).
- **SDK 4.0: the protected model.** The engine, the model's formats and its keys are in Quran Lab's closed Core
  (`QuranLabCore.xcframework`); this repository is the public wrapper. The model is downloaded encrypted, installed
  by the Core to an encrypted form bound to this install, and opened only by the Core, in memory, with a lease
  from Quran Lab's server. No plaintext model file is ever written, and no call of the SDK returns a model file, a
  path to one, weights or keys.
- **Coming from 3.x:** [docs/migrating-to-4.md](docs/migrating-to-4.md) says what changes. SDK 3.x stops receiving
  the V4 model on 15 January 2027, 00:00 UTC, and model versions from V4.1 on are published only encrypted, for SDK 4.0.
- **Platforms:** iOS 15 and macOS 12 on Apple silicon (arm64 devices, the arm64 Simulator, arm64 Macs).
- **Status:** 4.0.3. Each release is compiled and its tests run on a Mac with Xcode
  (docs/mac-checklist-4.0.md). It carries every fix of 3.1.5, the download work
  included. If Quran Lab's main servers can't be reached, the SDK uses backup servers automatically.

## Install

In Xcode: **File > Add Package Dependencies**, enter `https://github.com/Quran-Lab/tajweedformer-apple` and choose version 4.0.3. In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Quran-Lab/tajweedformer-apple", from: "4.0.3"),
],
// and in your target's dependencies:
.product(name: "TajweedFormer", package: "tajweedformer-apple"),
```

SwiftPM fetches the Quran Lab Core (`QuranLabCore.xcframework`) with the package, from `cdn.quranlab.ai`, and checks it
against the checksum in `Package.swift`. Then add the App Attest capability ("Before you start").

## Before you start

| | |
| - | - |
| **Key** | An iOS or macOS key from [sdk.quranlab.ai](https://sdk.quranlab.ai), for your app's bundle id. On the Simulator, a development key: Quran Lab leases the Core's Simulator build to development keys only. |
| **Devices** | iOS 15 and macOS 12 or later, on Apple silicon only: arm64 devices, the arm64 Simulator and arm64 Macs. Intel Macs and the x86_64 Simulator are not supported. Xcode 16 or later (Swift tools 6.0). |
| **Permissions** | `NSMicrophoneUsageDescription` in Info.plist: without it the system ends the app at the first use of the microphone. A sandboxed or hardened Mac app also needs the `com.apple.security.device.audio-input` entitlement. |
| **Capabilities** | App Attest (Signing & Capabilities). With it, an install is hardware-verified: it gets the Neural Engine and sharing uploads. Without it the SDK still runs, on the CPU engine only. |
| **Download** | Making the Client downloads nothing. The first `client.model()` or `client.prefetch()` downloads the model, encrypted: 55.5 MB, once (68.4 MB on disk), and needs a connection. On iOS 18 and macOS 15, for an attested install, the Neural Engine's build follows in the background: 76.1 MB more. |
| **Offline** | The first `client.model()` or `client.prefetch()` needs a connection; after that the model works offline. When the device is online, the SDK keeps itself up to date in the background. `needs_connection` means the SDK needs Quran Lab to continue. A Model that is open keeps running. |
| **Model** | The model runs only inside the Quran Lab Core: its files are encrypted from Quran Lab's server to the device, and no plain model file is ever written. Do not change the Core's framework beyond Xcode's own signing: a changed Core gets no lease. When Quran Lab refuses the key or the app, the model's files are removed. |
| **Analytics** | Anonymous counts and durations (never audio, text, names or device identifiers) and reports of the failures your learners hit are always sent; you find them at sdk.quranlab.ai under your app, Problems included. |
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
  table gives nil. The SDK never aligns it with a take. SDK 4.0: the table is encrypted and only the Core reads it,
  at the first `units(surah:ayah:)` after the model opened; that call needs the lease, as opening the model does
  (`needs_connection` otherwise, and the next call tries again).

`model.tokens` is the vocabulary (38 tokens: names, ids, the blank and the word bar), and `model.sampleClips` are
short recitations of the model's self-test set, to run the whole path without a microphone.

## The protected model

What SDK 4.0 does, in the order a first `client.model()` does it (quranlab-contract `sdk_4.0.0/PROTECTED_MODEL.md`,
section 18). Making the Client downloads nothing: the model downloads only when the app calls `client.model()` or
`client.prefetch()`. A later start of the Client checks only for an update of a build it installed on this device.

1. **The install's key.** A P-256 key made in the Secure Enclave (a software key in this device's Keychain on a Mac
   without one and on the Simulator, reported as such). It never leaves the key store: the Core gets one lease's
   shared secret and signatures, never the key.
2. **The certificate.** `POST /v1/attest` with the key, its signature over the challenge (`install_sig`) and App
   Attest where the device has it. Quran Lab answers with an install certificate.
   Every new certificate comes with a new key.
3. **The lease.** The signed manifest of the build the config names, then `POST /v1/model-key` with the
   certificate and the Core's proof. The lease is wrapped for this install's key and for this Core release. After
   the first run the model works offline; when the device is online the SDK keeps itself up to date in the
   background, and opening the model never waits for that. An install attested with App Attest is
   hardware-verified, the class that may use the Neural Engine.
4. **The download.** Ciphertext only (the build's CDN form), one request per file, resumable, every file checked
   against the signed manifest. The Core installs each file to this install's device form (the plaintext's SHA-256 is checked inside
   the Core), and the downloaded copy is deleted.
5. **The model opens** in the Core's memory from the device form and the lease, also offline. When
   `client.model()` throws `needs_connection`, the SDK needs Quran Lab to continue, and nothing is decrypted. A model
   already open keeps running until it is closed. A device clock that is wrong or moved never locks a learner out.

On a network that fails, the bytes that arrived stay on the device (ciphertext, the CDN form), and the SDK takes a
file up again by itself: at most five times per file in one call, after 1, 2, 4, 8 and 16 seconds, when there was
no answer, the connection ended, the server failed, no byte came for 30 seconds (a slow connection that keeps
delivering is never cut), or the answer said success and was not the file. An attempt that brings no new byte counts
like any other. A refusal and a redirect are never asked again. Then `client.model()` or `client.prefetch()` throws,
and the next call goes on from what is on the device. Each file is asked for whole, with one request, and written to
the device as it arrives; a transfer that was cut is resumed with one request for the rest, from the last byte on the
device. An answer is the file only as the whole file of the manifest's size, or, for a resume, as a 206 for the rest
of it; anything else is a failed attempt and costs no stored byte. A partial file is continued only as the file it
was started as (the server's ETag is sent back with the resume, and a file that changed comes whole and takes the
partial file's place once all of it has arrived). Every download
and upload goes on whatever network the device has: a first install, an update, another context's files, the
Neural Engine's build, `prefetch()` and shared recordings alike. Nothing waits for Wi-Fi, and there is no option for
it; the system may still pause a transfer by its own settings (Low Data Mode, background limits). Cancelling a call
ends that call's wait: the download goes on while another call waits for it or a `prefetch` asked for it.

On iOS a download that is under way when the learner leaves the app gets the time the system gives a task under
way (about half a minute), and when the app has entered the background what is left of it goes on in a background
session while the app is suspended: one transfer per file, for the rest of it from the last byte on the device. The
background session takes a file of any size, so a file is never cut into pieces. When the app is back the transfers
still under way go on, and the app waits for each and joins what it brings, so nothing they fetched is fetched again;
a transfer that brings nothing for a minute is given up and the app goes on with the file itself. The transfers are
of the CDN form from the model folder the lease named, so nothing a background session keeps is plaintext. A
background transfer's request is kept by the system in its own store until the transfer ends: it carries the
install's token, which is not renewed while the app is away (the app fetches the file itself when the server refused
it for its token), and the developer key unless Quran Lab's signed config says that a background transfer sends the
token alone. On that path alone the system follows a redirect without asking
the SDK: the SDK then refuses the bytes and reports the host it ended on.

A model has a version (`model.version`) and a folder is one build of it (`model.build`, diagnostics only). The SDK
refuses a manifest whose signature does not verify (`signature_invalid`), that needs a newer SDK or is not an
encrypted build (`model_incompatible`), or that is not the build the config named (`checksum_mismatch`).
`client.prefetch(onProgress:)` downloads ahead of use, resumable, with the bytes done and the total, on whatever
network the device has. A download that `prefetch` started goes on when the call is cancelled.
`client.storage` says what is on disk; `client.removeModels()` removes the model files.

When Quran Lab refuses the key or the app on the lease route, the refusal is signed: the Core clears its lease and
removes the model's files only when the signature verifies with a key compiled into it and the refusal names this
request. A stop that is not signed is not acted on there.

**The honest limit.** A model that runs on a device can be taken by someone who controls that device and has the
skill and the time. What 4.0 achieves: a key, an AI agent, a copied folder or a script gets ciphertext only, and
taking the model needs an expert, weeks, and a new effort for every release.

## Backends

Every take runs on the Core's exact CPU engine: the same bits on every device, for every head of every chunk. The
default context is `c16_l64` (320 ms chunks); Quran Lab's signed config can name another for an app
(`inference.context`), and `TajweedSessionOptions.context` wins over both.

The Neural Engine: in SDK 4.0 only the Core may hand an accelerator program to Core ML (from memory where the OS
allows, else through a short-lived file in the app's container that is removed after the load), and only with a
lease that allows accelerator programs. The SDK downloads the accelerator build only when the lease allows it, then
promotes it as before: compiled by the Core, warmed, checked against the CPU engine on the self-test clips, used from
the next session. A lease that does not allow accelerator programs is not a failure of the device or the build: the
CPU engine runs, nothing is counted against the build, and the preparation goes on from where it stood once a lease
allows them (4.0.2). It needs iOS 18 or macOS 15, and the SDK never attempts it on the Simulator. Core ML keeps its own
compiled form for the Neural Engine in the app's `Library/Caches`.

## Quran Lab platform

`TajweedClient(key:)` links the app to [sdk.quranlab.ai](https://sdk.quranlab.ai): registration (once per UTC day per
install), the signed config (refreshed within a minute of a change), issue reports (kind and code only), error
reports (where a failure was and why, one per UTC day and kind of failure, never a message or an identifier), and
telemetry. It downloads no model: that waits for the app's `client.model()` or `client.prefetch()`. What the SDK
sends, when, and what an app can change is in
[docs/platform-client.md](docs/platform-client.md), the same page in every TajweedFormer SDK.

Telemetry is on by default and anonymous by construction: sums and histograms per UTC day (per model version, build,
context and backend: takes, minutes of audio, speech and silence, tokens per head, compute time, latency and
real-time factor; downloads; launches; promotions; per model host, the files, bytes and requests fetched there, the
failures, the time to the first answer and the speed, in buckets), never audio, recognised text or any identifier. It goes as
deltas during the day, each with a random `report_id` so a retry is counted once.

The SDK keeps anonymous daily totals for your statistics at sdk.quranlab.ai: sessions and takes, seconds of audio and
of recitation, the ayat recited per surah and per juz, the hour of the day in the learner's own time, how long takes
and sessions are, how many installs were active and came back, and how the model ran on the device. It works out which
ayat a take recited by itself; `reportRecited` is used only where it could not tell. Nothing is kept per learner: no
audio, no text, no ayah numbers, no identifier, no location beyond the country the request came from. The device keeps
its own list of the days it was used, to work out those totals, and that list never leaves the device.

Two calls add what only the app knows, for its own page on sdk.quranlab.ai:

- The SDK counts the ayat of each take by itself; where it could not tell, it uses what the app reported for that
  take, and a take is never counted twice. `try session.reportRecited(surah:ayahFrom:ayahTo:outcome:perAyah:)`: where
  the learner recited in this take and, optionally, whether your own judge found it correct (`.correct`, or
  `.incorrect(mistakes:rules:)`). These numbers are your app's judgement: the SDK does not judge a recitation.
- `try client.analytics.reportChecks(rule:checked:flagged:)`: how often the app's own judge checked a rule and how
  often it flagged it (at most 32 rules a day).

Anonymous analytics are always on in SDK 4.0: daily counts and durations only, never audio, text, names or device
identifiers. An app cannot turn them off; Quran Lab's signed config (`flags.analytics`) is the only off switch, for
every install of an app.

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
connection (`unmetered`, `metered`, `none` or `unknown`; a report only, nothing waits on it); from 4.0.1 also
`endpoints` (see [docs/api.md](docs/api.md)). Every error
the SDK throws is a `TajweedError` with a stable `code` (26 codes, the same in the four SDKs), a `message`, a `fix`
and a `docs` link. From 4.0.2 it also carries `cause`: what failed, as tokens (`stage`, `reason`, and when known
`httpStatus`, `errorName`, `errorCode`), the same as the error report Quran Lab gets, for the app's logs and support
requests; nil for the codes that only say the app used the API wrongly. On `needs_connection`, `cause.needs` says what
the SDK needs Quran Lab for: `model` (the model files are not on the device yet: connect to download them) or `lease`
(the model is on the device and needs Quran Lab's answer to open).

## Sharing recitations

Every learner is asked, and the choice is theirs. The SDK asks every learner, in every app, with the same sheet and
under the same rules; the learner can say "Not now", turn sharing off, or delete what they shared at any time. No app
is exempt, and the developer switches nothing on or off. Quran Lab's signed config keeps an incident switch
(`flags.contributions`) that stops all asking and sharing; until the SDK holds a signed config, and while that switch
is off, nothing is asked. Being asked is never consent: nothing is recorded for sharing or sent before the learner
taps "Share". The SDK asks at the right moment: the full sheet first, never
in the first 24 hours after the install or before the 3rd completed take, and only at the end of a good take (it
ended normally, and the learner recited at least a minute since the app opened), a few seconds after it with no new
take. After "Not now" a small card at the bottom of the screen asks again once both 14 days and 7 completed takes
have passed, then 30 days and 10; "See how it helps" on it opens the full sheet. Never two asks in one day, three
asks on the install in all, then never. `client.sharing.ask()` shows the ask at a point of your flow when it is due by
these rules (after a completed take, not during one), and returns false otherwise. A yes ends asking for good: the
learner keeps the consent version they agreed to across copy decks, your wording and SDK upgrades, and every shared
recording carries that version.

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
set it from 0, never, to 60 s), and a take that starts in that time continues the same stream. A recording never
holds more than 20 minutes of audio: at that point it closes, and a take that is still running goes on in a new one.

`client.sharing.feed(_:sampleRate:)` is for apps that capture audio themselves outside takes (before the first,
between them, after the last). With sharing on and the learner's yes, the SDK keeps the last second of what is fed
in memory and puts it in front of the next take's recording, and adds up to half a second after a take, so a
recitation is not clipped at a take's edges. The half second after a take is taken from what is fed within 1.5 s of
the take's end; what is fed later waits for the next take. Without a yes, during a take, or with sharing off, a fed buffer is
dropped at once and nothing of it stays in memory. The model never sees the feed. An app that uses `listen()` has no
audio outside takes and need not call it.

Use sharing in one process. The storage folder belongs to the app, and by default every process of the app uses
the same one (on iOS an app and its extension have separate folders unless you pass both the same one; on a Mac
every process with the app's bundle identifier uses the same folder). The SDK keeps the learner's sharing answer
in memory in each process and writes it as a whole, so two processes that each make a Client on the same folder
do not see each other's changes: sharing turned off in one does not stop the other, and the other's next write
puts the earlier answer back. Make the Client in one process of your app. If a second process needs the model,
give it its own `storage` folder (`TajweedClientOptions(storage:)`).

## Platform notes

- **Microphone.** `listen()` uses the SDK's `Microphone` (AVAudioEngine). The app needs
  `NSMicrophoneUsageDescription` in its Info.plist; a sandboxed or hardened Mac app also needs the
  `com.apple.security.device.audio-input` entitlement. A refusal is the error `microphone_denied`. Nothing is
  captured before `listen()` or after the take ends; when the app leaves the foreground the take ends with
  `ended(.background)`.
- **Privacy manifest.** The package and the Core's xcframework each carry a `PrivacyInfo.xcprivacy`; the SDK
  collects nothing linked to a person and uses no tracking. It declares the boot clock (the lease's clock).
- **App Attest.** Recognition needs no capability. Uploads of shared recordings need an attested install, and every
  app's learners are asked to share: add the App Attest capability. Without it the SDK still runs, unattested.
- **The install key.** The protected model's key is in the Secure Enclave (this device only, after first unlock);
  on a Mac without a Secure Enclave and on the Simulator it is a software key in this device's Keychain, and a
  process the Keychain refuses (a command line tool, an unsigned test run) keeps it in a file of the SDK's folder.
  The Core's saved state is sealed under another Keychain key of this device. The key that marks the model files
  as this install's download is kept the same way: in the Keychain, else in a file of the SDK's folder. On a Mac the
  SDK's Keychain calls never ask the user: a process whose login keychain is locked (a command line tool run over
  SSH) uses the file at once (4.0.2).
- **Apple silicon only.** arm64 devices, the arm64 simulator and arm64 Macs; iOS 15 and macOS 12 or later; Xcode 16
  (Swift tools 6.0).
- **One Client per process.** A second `TajweedClient` while the first is not closed throws `client_exists`.

## Build and test

```sh
python3 scripts/build_core_xcframework.py --core <quranlab-core checkout> --test-release --private <folder outside the repo>
swift test
```

`scripts/build_core_xcframework.py` builds the Core for iOS, the iOS Simulator and macOS and joins the slices into
`QuranLabCore.xcframework`: only the functions of `qlcore.h` are exported, and each slice's dSYM goes to the private
folder (kept per release, never shipped). `--test-release` builds the Core's test release, whose keys are the
contract's public test keys: the tests drive it with the contract's vectors. A release build names the release
folder instead (`--gen`). The steps on a Mac are in docs/mac-checklist-4.0.md.

The 3.x tests that ran the plaintext engine on a decoded folder are in `Tests/Retired-3.x` until they are ported
to encrypted test builds; they are not compiled.

| Path | Contents |
|-|-|
| `Sources/TajweedFormer/Protected` | the Core's platform table, the install key, the certificate, the lease, install and open |
| `Sources/TajweedFormer/Model` | the manifest, the download profile, the installer, the store |
| `Sources/TajweedFormer/API` | the public types: Client, Model, Session, Heads, Backend and their data |
| `Sources/TajweedFormer/Tajweed` | the recognizer, the decoded layer |
| `Sources/TajweedFormer/Cloud` | token and App Attest, config, registration, telemetry, issues, updates, the sharing outbox |
| `Sources/TajweedFormer/Sharing` | the consent state and views, the copy decks, the device key, the Ogg Opus writer |

libopus 1.6.1 is BSD-3-Clause; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

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
