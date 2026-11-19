# How the SDK talks to Quran Lab (2.0.3)

This page is the same in every TajweedFormer SDK (Android, iOS and macOS, web, Windows and Linux). It describes
what the SDK sends to Quran Lab, when, and what an app can change. Names of the API differ per platform; the
platform's own README gives them.

## Recitation sharing

### Every learner is asked; the choice is theirs

The SDK asks every learner, in every app, with the same sheet and under the same rules, and the learner decides:
"Share" or "Not now", and after a yes they can stop or delete what they shared at any time. No app is exempt, and an
app has no option to turn the ask off (the app's own sharing option is ignored since 2.0.1). The signed config the SDK
downloads keeps Quran Lab's incident switch (`flags.contributions`), which stops all asking and sharing, and says per
platform who may upload; without a signed config in force nothing is asked. Being asked is never consent: nothing is
recorded for sharing and nothing is sent before the learner answers "Share", and a learner who never answers never
shares.

### Consent

- The SDK asks at most three times per install, ever: the full sheet, then after "Not now" a small card (SDK 4.0)
  once both 14 days and 7 completed takes have passed, then 30 days and 10. A learner who said "Share" is never
  asked again; a learner who turned sharing off after a yes is not asked again. After that, only the app's own
  settings entry point (the SDK's settings switch) turns sharing on or off. The count carries over from 2.0.0 and
  3.x.
- The learner agrees to one wording, identified by a consent version, recorded when they agree. The SDK's
  own copy deck has version `share-2026-11-09` (deck `2026-11-19.1`, eight languages). Every shared session
  carries the version the learner actually agreed to (`consent_version`), for example `share-2026-11-12`
  for a learner who agreed in a 3.1.0 or 3.1.1 app, who is not asked again.
- A grant persists: a new copy deck, a new SDK version or new app wording neither pauses sharing nor asks
  again. A learner who agreed in a 2.0.0 install keeps sharing after the app moves to 2.0.1, with no sheet.
- The learner can stop at any time (uploads stop at once and the unsent queue is deleted) and delete
  everything they shared (signed with a key that never leaves the device; a one-time recovery code works
  at portal.quranlab.ai/delete). Both work whatever wording the learner agreed to.

### The default sheet, a themed sheet, or your own

1. **Default.** The SDK shows its own sheet at a good moment (the end of a take that ended normally, with a
   minute of recitation since the app opened; never in the install's first 24 hours or before its 3rd completed
   take), in the learner's language, right to left for Arabic and Urdu. Every app shows the same sheet.
2. **Themed.** Colours, corner radius and fonts of the SDK's sheets can be set; the words, their order, every
   line and the name at the top stay the SDK's. This does not change the consent version.
3. **Your own moment.** An app that knows a better moment than the SDK's calls `client.sharing.ask()`: the
   SDK shows its own ask then when one is due by the same rules (after a completed take, never during one;
   SDK 4.0), and that counts as one of the three; otherwise it returns false and shows nothing. Drawing
   the ask itself is not available in this version: the sheet is always the SDK's, and no call hands the
   app the request to ask or takes the learner's answer from a screen of the app's. What an app changes is
   the look (item 2) and the words (item 4).

   `client.sharing.setOn` is the learner's own switch in the app's settings, and is called from that switch
   only. It must not be used to hold the SDK's sheet back or to record an answer given on another screen:
   the yes it records is to Quran Lab's text, which a learner who saw another screen has not read.
4. **Your own wording.** An app may replace any string of the deck with its own text. Then the learner
   agrees to that text, so the SDK records the grant under a version derived from it and sends its hash
   with every session, so that Quran Lab can review it:

   ```
   canonical  = "quranlab.consent-text/1\n" + "base " + <deck consent_version> + "\n"
                + for each replaced key, sorted by its UTF-8 bytes: key + "\t" + escaped text + "\n"
   escaped    = the text with \ -> \\, newline -> \n, carriage return -> \r, tab -> \t
   consent_text_sha256 = SHA-256 of the canonical UTF-8 bytes, lower-case hex
   consent_version     = "custom-" + its first 24 hex digits
   ```

   Keys are the deck's keys (a plural line by category: `impact.minutes.one`, `impact.minutes.other`, ...).
   An unknown key or an empty text is refused. The version is the one in force when the learner agrees,
   and stays theirs: if the app changes its wording later, learners who already agreed keep their version
   and are not asked again (show the new wording in your settings if you like); learners who agree after
   the change get the new version. Your text must stay honest: say that the audio of recitation sessions is sent to Quran
   Lab, what else is sent (below), that it is used to improve free recitation models, and how to stop and
   delete. Quran Lab reviews it.

### What a shared session sends

The audio of each recitation session while the SDK listens (Opus in one Ogg stream, cut into segments of
10, 20, 40, then 60 s, uploaded during and after the session), and one session description: the model
version and backend, the SDK version, the device family and system major version, the capture sample rate
and input kind (built in, wired, Bluetooth, ...), the UTC day, a random code for this install (with the
public half of its deletion key and the hash of its recovery code at the first session), the consent
version, and, for your own wording, `consent_text_sha256`. Not sent: which ayah was recited, names,
accounts, contacts, location, device identifiers.

### Takes in a row are one recording (2.0.3)

An app often stops and starts its takes while the learner keeps reciting. So when a take ends, the shared
recording stays open for a few seconds (3 s, or what Quran Lab's signed config sets): if the next take starts
in that time, its audio continues the same recording, one Ogg stream with no new headers, and the time between
the takes is simply left out (no audio is made up for it). The recording closes when no take follows in time,
when the app goes to the background, when sharing is turned off, after 20 minutes, or when the next take has
another sample rate. For a recording of several takes the SDK sends, after its last segment, where each take
starts in the stream and how long the pause before it was (in tenths of a second), so the takes can be told
apart. Audio from before or after a take is never recorded: the SDK only has the audio the app gives it during
takes.

### Bitrate on bad networks

Opus mono at 48 kHz starts at 192 kbit/s. When uploads fail for network reasons (no connection, a timeout,
HTTP 408 or 5xx) or the queue backs up, the SDK lowers the bitrate of the audio still to be encoded; when
uploads succeed again it steps back up. The ladder is 192, 96, 64, 32 kbit/s:

- an upload failure: one step down;
- a segment closes while 120 s or more of closed audio waits to be uploaded: one step down;
- three segment uploads in a row succeed while at most 30 s waits: one step up.

A change takes effect at the next segment (Opus allows a new bitrate on any packet, so the stream needs no
new headers and stays one valid Ogg Opus file). Each segment has one bitrate, kept in its record on the
device and shown in the outbox's items. The floor is 32 kbit/s because recitation keeps its detail there:
on real recitation the 80-band log-mel features the model reads differ from the original by 0.22 dB at 192,
0.46 at 96, 0.68 at 64 and 1.17 at 32 kbit/s, but 1.60 at 24 and 2.48 at 16 kbit/s, while each step below
32 saves only about 0.07 MB a minute. The rates are targets of variable-bitrate Opus: on recitation the
32 kbit/s rung codes at about 36 to 47 kbit/s (0.27 to 0.36 MB a minute) and the 192 kbit/s rung at about 210
(1.6 MB a minute). A new process starts again at 192 kbit/s.

## Telemetry

On by default, anonymous by construction: sums and histograms, no audio, text, identifiers or times finer than
the UTC day. Off with the signed config's `flags.analytics: false` or the developer's one opt-out in code.

### Deltas during the day (2.0.1)

The SDK sends a delta: what happened since the previous delta of the same UTC day, never spanning midnight,
with a fresh random `report_id` (32 lower-case hex, drawn per delta). It sends one every 15 minutes while
the app is in use and one when the app goes to the background; unsent deltas are kept up to 7 days. A retry
sends the same body with the same `report_id`, which the server counts once. 202 deletes the delta; 400 drops
it; 401 renews the token and retries; 429, 5xx, 503 and network errors keep it for a retry with backoff.

The body is telemetry v2 (`"v": 2`, `day`, `product`, `platform`, `sdk_version`, `app_version`, `device`,
`cohorts` (may be `[]`), `coverage`, `downloads`) with these fields added, each left out when zero:

| Field | Meaning |
| --- | --- |
| `report_id` | random per delta, always sent |
| `launches` | app launches: cold starts and returns from the background |
| `ayahs` | ayahs the learner completed (scored) |
| `surah_ayahs` | per surah, `"1"` to `"114"`, the ayahs completed |
| `words` | words scored |
| `rule_checks`, `rule_flags` | per tajweed rule or class id (`vowel_sub` ... `insertion`, `madd`, `qalqalah`, `gemination`, `word`), how many were checked and how many of those were flagged |
| `share_asked`, `share_yes`, `share_no` | the sharing sheet was shown, the learner chose to share, the learner declined |
| `promotions` | iOS, macOS and Android only: per accelerator, model revision and context, the promotions that ended and the failovers (below) |

Each `promotions` entry (at most 8; zero counts left out):

```json
{"backend": "ane", "revision": "v4.0+abc", "context": "c16_l64",
 "attempts": 1, "promoted": 1,
 "failed_at": {"download": 0, "compile": 0, "warmup": 0, "golden": 0},
 "reasons": {"network": 0, "storage": 0, "verify": 0, "compile_error": 0, "compile_timeout": 0, "load_error": 0,
             "crash": 0, "hang": 0, "non_finite": 0, "golden_mismatch": 0, "cpu_mismatch": 0, "failover": 0,
             "denylist": 0, "other": 0, "interrupted": 0, "slower_than_cpu": 0},
 "compile_ms": {"le_1000": 0, "le_5000": 0, "le_15000": 0, "le_30000": 0, "le_60000": 0, "le_120000": 0, "gt_120000": 0},
 "speedup": {"lt_0_5": 0, "lt_1": 0, "le_1_5": 0, "le_2": 0, "le_3": 0, "le_5": 0, "gt_5": 0},
 "failovers": 0,
 "failover_causes": {"exception": 0, "non_finite": 0, "out_of_range": 0, "blank": 0, "deadline": 0},
 "failover_stall_ms": {"le_50": 0, "le_100": 0, "le_200": 0, "le_300": 0, "le_500": 0, "le_1000": 0, "gt_1000": 0},
 "demoted": 0, "blank_confirmed_ok": 0,
 "slower_than_cpu": [{"accelerator_ms": 35.0, "cpu_ms": 8.0}]}
```

`backend` is `ane`, `gpu` or `npu:<soc>`. An attempt is counted once, when it ends. `speedup` is the CPU's
median chunk time over the accelerator's on the self-test clips (`lt_0_5` and `lt_1`: the accelerator was
slower). SDK 4.0: a build that passed the golden test but is slower than the CPU engine on the device is not
promoted; the attempt counts under `reasons.slower_than_cpu`, and `slower_than_cpu` lists each such attempt's two
medians in milliseconds (at most 8 a day). `reasons.interrupted`: the app was quit during a stage. `failover_stall_ms` runs from the failed chunk being detected to its CPU
result. `demoted` counts promoted builds taken back to the CPU after a failure in a session.
`blank_confirmed_ok` counts silent stretches the CPU confirmed (no switch).

Never included: audio, text, phonemes, verdict lists, timestamps, ids, locale, account, network type,
location, app user data.

### Register

`POST /v1/register` is called once per UTC day per install (the first launch or return to the foreground of
the day; a day stamp on the device), not at every launch, so the server counts daily active installs.

## CPU first, then the accelerator (iOS, macOS, Android)

1. **First run.** The first install downloads only the CPU files of the default context, and the first session
   runs on the exact CPU engine. Nothing else is downloaded or compiled before it.
2. **In the background,** one step at a time, remembered across launches for each model revision, context,
   accelerator build, OS build and device: download the accelerator's program (Wi-Fi or an unmetered network,
   resumable, verified against the signed manifest; usually as a small delta that the SDK applies to the CPU
   weights already on the device, checking the rebuilt program's SHA-256 before the runtime sees it); compile
   it for this device at low priority (the Neural Engine compiler on Apple, the NPU program on Android, kept and
   redone after an OS update); warm up; then decode every self-test clip, the Basmala and a clip with a planted
   mistake included, through the accelerator and through the CPU engine and compare the tokens, the flagged
   sites and the per-word verdicts in both directions. A build passes when it finds the planted mistake and
   differs from the CPU by no more than its tolerance, which the signed manifest gives per build (none means
   identical). SDK 4.0, as Android: a build that passes is promoted only when its median chunk time is not slower
   than the CPU engine's on the same device (the signed config's `flags.accel_min_speedup` may ask for more, never
   less than 1.0); otherwise the CPU engine stays (`slower_than_cpu`), tried again after an SDK or OS update, a new
   build, or 30 days.
3. **The swap** happens only between sessions, to an accelerator that is already loaded and warm, so the next
   session starts without a pause and the app sees only faster chunks. A promoted device keeps its compiled
   program and verdict, loads it again at the next launch in the background, and usually starts its first
   session on the accelerator; a session never waits for it.
4. **If anything fails** before promotion (download, compile, a crash or hang, a different result), the CPU
   stays, the reason is recorded, and the step is retried later (after 1, 6 and 24 hours at most; never for a
   wrong result, a NaN, or a stop of the app at the golden test or the measurement, until a new model or OS
   version). Only in good conditions: not in low power mode, battery at 20 % or charging, the device not hot.
   A stop of the app at compile or warm-up is retried, and a second one there ends it; a stop during the
   download counts nothing, and the attempt goes on at the next launch. A quit of the app (a normal end of
   the process) is `interrupted`: retried after the wait, and never uses up the retries. On
   iPhone and iPad a stop while the app was in the background counts nothing, until the third in a row at the
   same stage; on a Mac the SDK cannot tell, and the stop is counted.
5. **If the accelerator fails during a session** (an error, NaN or out-of-range output, or a chunk past its
   deadline), the session switches to the CPU at that chunk: the CPU engine rebuilds its state from the last
   few seconds of audio and redoes the chunk, so no audio is lost and the learner sees at most a short stall.
   On phones and Macs the CPU engine rewrites its weights into the processor's fast layout when it loads, which
   would hold about 64 MB for the whole session, so it is closed while the accelerator serves and opened again
   at the switch: a short cold start instead of that memory.
   - **Silence is not a fault.** The model writes nothing during a held vowel or a long madd. When an accelerator
     writes nothing for a stretch of audio with sound, the SDK checks the same audio on the CPU in the
     background while the accelerator keeps serving: if the CPU also writes nothing, nothing happens (counted as
     `blank_confirmed_ok`); only if the CPU writes something does the session switch.
   - **A cold start is not a fault.** The accelerator is warmed up when a take starts and when the app becomes
     active, the first chunk of a take has a generous limit (at least 1 s), and the limit of later chunks comes
     from warm chunks only. A single late chunk is served by the CPU and costs nothing more.
   - **What sets an accelerator aside.** Late chunks in three sessions within 24 hours, or one disagreement with
     the CPU: a few hours' pause, then it serves again (no new test). For good, for that model and OS version:
     NaN or out-of-range output, a second disagreement with the CPU, or a self-test mismatch. A stop of the app
     while a promoted build loads and warms up at launch is a stop at warm-up (item 4): the build is tested again
     after the wait, and a second such stop ends it; a quit, or a stop in the background, there holds nothing
     against the build. A stop of the app while the accelerator serves a session sets nothing aside. An error
     from the accelerator itself sets it aside for a day, then it is tested again (at most three times for that
     model and OS version). Each switch to the CPU is still reported to Quran Lab, also when it sets nothing
     aside. An install that 2.0.1 had set aside for silence or a late chunk is tested again and promoted again.
6. **Quran Lab can keep an accelerator off** on matching devices (by device, chip, OS build, delegate or model
   revision) through the signed config; a promoted device then goes back to the CPU at its next session.
7. **Quran Lab hears about every incident.** A failed promotion and an in-session switch are each also sent
   as an issue report (`promotion_failed`, `accelerator_failover`) with what is needed to investigate: the
   stage and cause, the error's domain, code and message (paths removed), the chunk and its deadline, the
   self-test clip that differed, the device model, OS build, chip, compute units, model revision and context,
   the thermal and low-power state, and the stall. Never audio, text or identifiers.
   Reports made offline, or before the app configured Quran Lab, are kept on the device for up to 7 days and sent
   once the app has configured Quran Lab with its key and the network is there; an app that never configures
   Quran Lab sends none.

## Tajweed settings

Unchanged: the app's settings win over the portal's tajweed block, which wins over the model's
calibration.json.
