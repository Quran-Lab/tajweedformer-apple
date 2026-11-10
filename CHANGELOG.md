# Changelog

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
