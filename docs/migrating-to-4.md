# Migrating from 3.x to 4.0 (iOS and macOS)

4.0 keeps the 3.x API (Client, Model, Session, Heads, Backend) with two options fewer (analytics and audience,
below). What changes is underneath: the engine, the model's formats and its keys move into the Quran Lab Core, a closed
framework that comes with the package, and the model opens only inside the Core, under a lease for this install. Most
apps raise the package's version, add the App Attest capability, and delete `analytics:` and `audience:` if they set
them.

**When to move.** SDK 3.x stops receiving the V4 model on 15 January 2027, 00:00 UTC. New model versions, from V4.1
on, are published only encrypted, for SDK 4.0: an app on 3.x never gets them.

| 3.x | 4.0 |
| --- | --- |
| `TajweedClientOptions(analytics: .off)` turned the anonymous analytics off. | Removed, with `TajweedClientOptions.Analytics`, so code that sets it no longer compiles: delete `analytics:`. Anonymous analytics are always on, because they are daily counts and durations only, never audio, text, names or device identifiers. Only Quran Lab can switch them off, from its signed config. |
| `TajweedClientOptions(audience: .children)` chose another sharing sheet, and `client.sharing.setOn(_:guardianConfirmed:)` took a confirmation. | Removed, with `TajweedClientOptions.Audience` and the `guardianConfirmed:` argument, so code that sets them no longer compiles: delete the argument. Every app shows the same sharing sheet, and `setOn(_:)` takes the learner's switch alone. Complying with children's privacy law is your app's and its app store's. |
| The model's folder held plain files. | The model is encrypted for this install. Only the calibration and the sample clips are plain. No call returns a model file, a path into the model, weights or keys. The model downloads once more after the upgrade, when the app first calls `client.model()` or `client.prefetch()`, so that call needs a connection once. |
| Making the Client (`TajweedClient(key:)`) could download the model at launch, on a device that had none. | Making the Client downloads nothing. The model downloads only when the app calls `client.model()` or `client.prefetch()`; a later start checks only for an update of a build the Client installed on this device. Call `prefetch()` where you want the model on the device ahead of the first take. |
| `client.model()` worked offline once the model was downloaded. | It works offline while the install's lease is valid: learners keep working offline for days at a time (the exact time is set by Quran Lab and may change), and the lease is renewed in the background whenever the device is online. See "The protected model". |
| The App Attest capability was needed only to upload shared recordings. | It also decides the install's class: with it, the install is hardware-verified and may use the Neural Engine; without it, the SDK still runs, on the CPU engine only. |
| The Neural Engine build ran after its check on iOS 18 and macOS 15. | The same, with the program handed to Core ML by the Core, and only under a lease that allows it (an attested install of a production key). `model.prepareAccelerator(context:again:timeout:)` prepares it now and waits. |
| `model.reference` read a plain table after `fetch()`. | `fetch()` still brings it, now encrypted, and the Core reads it at the first `units(surah:ayah:)` after the model opened. That call needs the lease, as opening the model does. |
| `session.reportRecited(surah:ayahFrom:ayahTo:)` was the only count of recited ayahs. | The SDK counts the ayahs of each take itself. Your report is used only for a take it could not place, and a take is never counted twice, so keep calling it if you already do. `outcome:` and `perAyah:` add your app's own judgement (`.correct`, or `.incorrect(mistakes:rules:)`). |
| A server failure could be `needs_connection`. | `needs_connection` only when Quran Lab gave no answer at all. See "Error codes". |

## Install and requirements

- Raise the package to 4.0.0. The Core comes with it as `QuranLabCore.xcframework`: nothing else to add.
- iOS 15 and macOS 12 on Apple silicon, Xcode 16, as in 3.x.
- **Add the App Attest capability** (Signing & Capabilities) for hardware-verified installs, the Neural Engine and sharing uploads.
- Do not change the Core's framework beyond Xcode's own signing: the Core checks its own code, and a changed Core gets
  no lease. Signing and re-signing are fine.
- On the Simulator, use a development key: Quran Lab leases the Core's Simulator build to development keys only.
- The privacy manifests now also declare crash data (not linked to the learner, not used for tracking) and the boot
  clock, which the lease's clock reads. Check your App Store privacy answers against them.

## The protected model

- **Encrypted end to end.** The model downloads encrypted, the Core installs it encrypted again for this install, and
  it is decrypted only in the Core's memory when it opens. No plaintext model file is ever written.
- **The install's key.** The first `client.model()` makes this install's key in the Secure Enclave (a software key in
  this device's Keychain on a Mac without one and on the Simulator) and gets an install certificate from Quran Lab,
  with App Attest where the app and the device have it. The first call takes a little longer for this.
- **A lease per install.** The model opens under a lease Quran Lab signs for this install. Learners keep working
  offline for days at a time; the exact time is set by Quran Lab and may change. While the device is online the SDK
  renews the lease in the background about once a day, and a valid lease never waits for a renewal. Offline with a
  valid lease, the model opens. With App Attest the install is hardware-verified and may use the Neural Engine. When
  App Attest fails on a device, the SDK goes on unattested, on the CPU engine: it never locks a learner out for it.
- **When Quran Lab cannot be reached.** If the lease has ended and Quran Lab cannot be reached (no answer, a server
  error, or "too many requests"), the model keeps opening under that lease for up to 24 hours more. A refusal from
  Quran Lab ends this at once. A model open
  past the end of the lease first asks Quran Lab for a new one and waits at most 10 seconds, and not at all when the
  device is offline. Each such open is reported to Quran Lab; your app gets no error. After the 24 hours the model
  opens only with a new lease: until then `client.model()` throws `needs_connection` when Quran Lab gave no answer, and
  `download_failed` when it answered with a server error.
- **A Model already open keeps running** until it is closed, past the end of its lease and of those 24 hours too.
- **The clock is the Core's.** A device clock that is wrong or moved never lengthens a lease, and never locks a learner
  out for long.
- **Refusals.** When Quran Lab stops a key or an app, its answer on the lease route is signed. Only when the Core
  verifies it are the lease and the model's files removed, as in 3.x. Any other refusal there removes nothing and is
  `server_rejected`.
- **The honest limit.** A model that runs on a device can be taken by someone who controls that device and has the
  skill and the time. The goal of 4.0 is that a key, an AI agent, a copied folder or a script gets nothing usable, and
  that taking the model needs an expert, weeks, and a new effort for every release.

## Error codes

The catalogue is the same 26 codes (`error.code`), so code that checks them works as before. What changes is which
code a failure gets: an answer from a server is never `needs_connection` (3.1.4 answered some server failures with
it).

| What happened | Code |
| --- | --- |
| A request the call needs got no answer at all (offline, DNS, a refused connection) and the model is not on the device yet | `needs_connection` |
| The lease and its 24 hours above have ended, and Quran Lab gave no answer | `needs_connection` |
| Quran Lab answered with a failure: a server error, a 429, a redirect, a config that does not verify with none stored | `download_failed`; the message names what answered ("the server answered 503"). Call again later |
| Quran Lab refused the key or the app | `invalid_key`, or `server_rejected` with the reason, as in 3.x; `sdk_too_old` when the key needs a newer SDK |

## Error reports

New in 4.0. Every `TajweedError` your app gets, except the codes that only say the API was used wrongly
(`invalid_argument`, `client_exists`, `session_open`, `session_closed`, `cancelled`), and every failure the SDK goes
on from without telling your app (for example a renewal of the lease that failed), is sent to Quran Lab as one small
report: where it failed, why, the HTTP status, the error's domain and code, how often that day, the device's model
code (`iPhone16,2`) and memory tier. Never a message, a path, a URL or an identifier. One report per kind of failure
per day, with its count; at most 16 a day and 32 waiting, kept 7 days. Your app's page at sdk.quranlab.ai lists them
under Problems, with what to do. No option turns them off; Quran Lab can, from its signed config.

## Sharing

- **Every learner is asked; the choice is theirs.** The SDK asks every learner, with the same sheet and under the same
  rules in every app, and each learner decides: "Not now", or a yes they can take back, and they can delete what they
  shared at any time. There is no option to turn the ask off and no app is exempt. Quran Lab's signed config keeps an
  incident switch (`flags.contributions`) that stops all asking and sharing; it is not a decision about your app.
- **Asked later and less often.** The first ask, the full sheet, comes never in the install's first 24 hours nor before
  its 3rd completed take, only at the end of a good take. After "Not now" a small card at the bottom of the screen asks
  again after 14 days and 7 takes, then 30 days and 10; "See how it helps" on it opens the full sheet. Three asks at
  most, ever. `client.sharing.ask()` returns false when no ask is due.
- **Takes in a row.** A shared recording now stays open for up to 60 seconds after a take (3 seconds unless Quran
  Lab's config sets it), so a learner who pauses between turns gives one recording. Nothing to change.
- **What a shared recording carries.** Its description now names the device's model code (`iPhone16,2`). When Quran
  Lab's config turns it on, a take captured at a rate other than 48 kHz is shared as lossless FLAC at its own rate.

## What stays the same

The five names, every call of a take, the Heads and the decoded layer, events, one Client per process, the sharing
sheet and its theming, the settings view, the learner's earlier answer with the consent version they agreed to, and
the 26 error codes. Quran Lab encourages, but does not require, one line where your app shows feedback built on the
model, for example: "Automatic tajweed feedback can be wrong. It does not replace a qualified teacher."
