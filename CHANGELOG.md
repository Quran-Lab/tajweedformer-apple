# Changelog

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
