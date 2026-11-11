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
  <img alt="status: preview" src="https://img.shields.io/badge/status-preview-2a3b8f?style=flat-square">
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

**Tajweed scoring in SDK 2.x**<br>For a known ayah, SDK 2.x also scores the take: letters and vowels, madd held too short or too long, a score for every word. Qalqalah checks are experimental.

</td>
</tr>
</table>

### Tajweed scoring in SDK 2.x

Scoring has four presets. **Strict** almost never flags a correct recitation. **Balanced** is the default. **Sensitive** catches more, and **Very sensitive** catches the most, for a teacher who reviews every flag first. The word level follows your learners: **strict** for huffaz and advanced students, **general** for most apps, **beginner** for children and classes. You set them in the portal and your app picks them up without a new build. Scoring is part of SDK 2.x; SDK 3.0 is inference only, so build new judging on the model's output.

## Why TajweedFormer

- **Made for the Quran.** Trained on Quranic recitation, with its own sound units and heads for what tajweed is about.
- **Feedback in the moment.** Output streams while the learner recites, so your app can respond on the word itself, not after the take.
- **One engine on every platform.** The same engine runs the [iOS and macOS](https://github.com/Quran-Lab/tajweedformer-apple), [Android](https://github.com/Quran-Lab/tajweedformer-android), [web](https://github.com/Quran-Lab/tajweedformer-web) and [Windows and Linux](https://github.com/Quran-Lab/tajweedformer-c) SDKs, all set from one portal.
- **Free, and it stays free.** Quran Lab is a non-profit waqf: the SDKs and models are never sold. The licence, NPL-1.2, asks three things: no paywall on model features, no results presented as rulings, and show the notice.

## Built for AI developers

Copy the setup prompt from [portal.quranlab.ai](https://portal.quranlab.ai) and paste it into your coding assistant. That one prompt sets everything up: the package, your key, and the settings for the learners your app is for. [AGENTS.md](AGENTS.md), beside this README, gives the assistant the complete API, so the code it writes uses names that exist. Prefer to do it by hand? Get a key in the portal and start below.

## Install

In Xcode: **File > Add Package Dependencies**, enter `https://github.com/Quran-Lab/tajweedformer-apple` and choose version 2.0.3. In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Quran-Lab/tajweedformer-apple", from: "2.0.3"),
],
// and in your target's dependencies:
.product(name: "TajweedFormer", package: "tajweedformer-apple"),
```

## Before you start

| | |
| - | - |
| **Key** | An iOS or macOS key from [portal.quranlab.ai](https://portal.quranlab.ai), for your app's bundle id. |
| **Devices** | iOS 15 and macOS 12 or later, on Apple silicon only: the binary has arm64 slices for devices, the arm64 simulator and arm64 Macs. Intel Macs and the x86_64 simulator are not supported. Xcode 16 or later (Swift tools 6.0). |
| **Permissions** | `NSMicrophoneUsageDescription` in Info.plist: without it the system ends the app at the first use of the microphone. A sandboxed or hardened Mac app also needs the `com.apple.security.device.audio-input` entitlement. |
| **Capabilities** | None for recognition. If your app offers recording sharing, add the App Attest capability: uploads need an attested install. Without it the SDK still runs, unattested. |
| **Download** | The first launch downloads the model: 56.5 MB, once (73.5 MB on disk), on any network. On iOS 18 and macOS 15 the Neural Engine's build follows in the background on Wi-Fi: 76.1 MB more. |
| **Takes** | A recognizer runs one take at a time. |

## Quick start

From your key to what the model hears from the microphone:

```swift
import TajweedFormer

/// The microphone in, what the model heard out.
@MainActor
final class Listener {
    private let microphone = Microphone()
    private var recognizer: TajweedRecognizer?

    func start() async throws {
        QuranLab.configure(key: "qlk_v1_...")                        // once, at launch: your key from portal.quranlab.ai
        guard await Microphone.requestPermission() else { return }   // the system's microphone dialog
        let model = try await TajweedModel.load()                    // downloads the model once, verified
        let recognizer = try TajweedRecognizer(model: model)
        self.recognizer = recognizer
        try await recognizer.startTake()
        let chunks = await recognizer.chunks()
        try microphone.start(into: recognizer)
        for await chunk in chunks {                                  // every 320 ms while the learner recites
            let heard = await recognizer.decoded()                   // what the model heard so far
            print(chunk.index, heard.transcript)
        }
    }

    func stop() async throws {
        microphone.stop()
        try await recognizer?.finish()                               // ends the take, and the loop in start()
    }
}
```

Keep one `Listener` and call `Task { try await listener.start() }` from a button; `try await listener.stop()` ends
the take. `decoded()` is what the model heard so far: the transcript, and each token with its confidence, runner-up
and times; each `chunk` carries every head of the network you selected. Every error is a `RecognizerError`. The code is
[`Tests/TajweedFormerTests/QuickStartTests.swift`](Tests/TajweedFormerTests/QuickStartTests.swift), which CI compiles
with the package.

In SDK 2.x a finished take of a known ayah can also be scored (`try await recognizer.score(surah: 1, ayah: 2)`:
verdicts per site and per word), and `await recognizer.endSession(feedback: true)` marks the moment the SDK may ask
about sharing.

## More

The full reference (every layer of the API, backends, what a device downloads, platform settings, recording sharing, building and testing) is in [AGENTS.md](AGENTS.md), written for coding assistants and just as readable for you. Guides: [portal.quranlab.ai/docs](https://portal.quranlab.ai/docs).

## Licence

Quran Lab is a waqf: the SDKs and the models are free to use and are never sold.

The source code in this repository and the TajweedFormer model weights are released under the
Quran-Lab No-Profit License 1.2 ([NPL-1.2](LICENSE)): use, copy, modify and build on them freely,
but never charge for them, for access to them, or for any feature they power. The weights are not
stored in this repository; Quran Lab hosts them itself and serves them to apps by
`cdn.quranlab.ai/models` under the same licence. Get access at
[portal.quranlab.ai](https://portal.quranlab.ai).

Third-party components keep their own licences, listed in their folders under `third_party/`.
