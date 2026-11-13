<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/quranlab-mark-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset=".github/assets/quranlab-mark-light.svg">
    <img alt="Quran Lab" src=".github/assets/quranlab-mark-light.svg" width="51" height="48">
  </picture>
</p>

<h1 align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/banner-dark.svg"><img alt="TajweedFormer for iOS and macOS" src="docs/banner-light.svg" width="100%"></picture></h1>

<p align="center">TajweedFormer V4 for iPhone, iPad and Mac: recitation audio in, the model's output out while the learner recites. On the device, offline, and free.</p>

<p align="center">
  <a href="https://github.com/Quran-Lab/tajweedformer-apple/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/Quran-Lab/tajweedformer-apple/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="platform: iOS, macOS" src="https://img.shields.io/badge/platform-iOS%2015%20%7C%20macOS%2012-1c1b19?style=flat-square">
  <img alt="version: 3.1.5" src="https://img.shields.io/badge/version-3.1.5-2a3b8f?style=flat-square">
  <img alt="model licence: NPL-1.2" src="https://img.shields.io/badge/model%20licence-NPL--1.2-1c1b19?style=flat-square">
</p>

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

**Data for your own judge**<br>The SDK scores nothing. The model's thresholds and the expected units of each ayah come with it as read-only data, so your app can judge a recitation its own way.

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

## Install

In Xcode: **File > Add Package Dependencies**, enter `https://github.com/Quran-Lab/tajweedformer-apple` and choose version 3.1.5. In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Quran-Lab/tajweedformer-apple", from: "3.1.5"),
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

## More

The full reference (every layer of the API, backends, what a device downloads, platform settings, recording sharing, building and testing) is in [AGENTS.md](AGENTS.md), written for coding assistants and just as readable for you. Guides: [sdk.quranlab.ai/docs](https://sdk.quranlab.ai/docs).

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
