# Changelog

## 3.1.4

Corrections to what the SDK does with something it keeps on the device and cannot read at that moment, and to
"delete what I shared" in a process that ends. The same engine, the same model builds and the same API as 3.1.3.

Each fault below is what the code of 3.1.3 does in such a process: found by reading the code and shown by tests
on a Mac, not observed on a device.

- **Fixed: a stored answer about sharing that could not be read was taken for "never answered".** The system
  can start an app in the background while the phone is locked (to hand over finished uploads, for one), also
  before the first unlock after a restart. Files of a protected class cannot be read then: before the first
  unlock that is, by the system's default, every file of an app, and while the phone is locked the files of an
  app that protects its files completely. The SDK named no protection class for its files, so they had the
  app's. In such a process the SDK
  read the learner's stored answer, got nothing, and took that for an answer that was not there. It deleted the
  unsent recordings in the queue at that start, as recordings without a consent. And when the learner then
  opened the app and finished a take in the same process, it asked them again and wrote a fresh state over the
  stored one: a yes, a "Not now" and a final no were lost alike, with the count of the sheets shown. From this
  version an answer that is there and cannot be read is not "never answered". While it cannot be read, sharing
  is neither on nor off in that process: nothing is uploaded, nothing is deleted, nobody is asked, nothing is
  written and no session is counted, and it is read again at the next need. Only a file that is not there is
  "never answered". Whether a file is not there or cannot be read is told by the error of the one read, "no such
  file" against any other.
- **A stored answer that reads and does not parse.** It is treated the same: nothing the SDK does by itself
  writes over it, nothing is uploaded, and nobody is asked. Only the learner's own act begins a new answer over
  it: the switch, either way, or "delete what I shared". The damaged file is then kept aside under another name
  (`cloud/sharing-state.damaged-<seconds>.json`), the unsent queue is removed (under which answer its recordings
  were made is not known), and the new state has its asks used up: the SDK does not ask that install by itself
  again, and the learner's switch is the way on.
- **The learner's switch while the stored answer cannot be read.** The code of 3.1.3 held a fresh state in such
  a process, and the switch changed that state and wrote it over the stored answer: an off as a final no, an on
  as a yes, and with either the count of the sheets shown, the count of the learner's changes of mind and a note
  that a deletion was being asked were lost. Now the stored answer is not written over. An off is written down
  as a small file of its own beside it; nothing is recorded or uploaded while that file is there, and the next
  read of the answer that succeeds, in that process or the next, applies the off and removes the file (a yes the
  learner gives after that is not turned off by it). When that file cannot be written either, `setOn(false)`
  throws `storage_failed`, and the SDK records and uploads nothing more in that process. `setOn(true)` while the
  stored answer cannot be read throws `storage_failed` and changes nothing.
- **The same rule for the other things whose loss touched the learner.** Each of these was "not there" when it
  could not be read, and each is now left as it is until it reads:
  - a queued recording's stamp (the recording was deleted unsent), its item file (an uploaded recording was
    started again, and the item file written over), and, for a recording an app was killed in, its capture file,
    a segment's marker and the open segment's audio (the recording was deleted, or finished with a segment left
    out, whose audio was deleted unsent);
  - the contributor id, the device key and the recovery code, in the Keychain or, for a process without one, in
    files: a new id, key and code were made, and with a new key "delete what I shared" was signed with a key the
    server did not hold, which it answers 202 and deletes nothing. Now none is made anew and none is replaced,
    no recording begins and nothing is uploaded until they read, and a deletion is not asked: the call fails with
    `storage_failed` and changes nothing. For the Keychain only "item not found" is "not there"; every other
    answer, the one before the first unlock included, is "cannot be read";
  - the server's remembered refusal of the key or the app: a model that was still on the device was opened.
    Now no model is opened and nothing is downloaded until it reads (`storage_failed`);
  - a downloaded build's install record and its manifest: the build was deleted and downloaded again. Now it is
    neither opened nor deleted nor downloaded again until they read (`storage_failed`).
  Held is what the system does not give. Three of these files, when they were read and are not what the SDK
  writes there (damaged), go the way they went before, which is the way of a file that was deleted: a remembered
  refusal is no refusal, an install record makes the build not the Client's (deleted and downloaded again), and
  an item file is no item (its recording is one still to send).
  Left as they were, because nothing of the learner's goes with them (each is made, asked for or downloaded
  again): the token and the App Attest key marker, the config, the registration notes, the rollout bucket, the
  recommended-model note, the model's pointer files, the telemetry and report queues, the count of recordings,
  and the accelerator's verdicts.
- **The SDK's files have a protection class by name: "complete until first user authentication".** In an app
  whose own default is "complete", the SDK's files, the learner's unsent recordings among them, are kept at
  "complete until first user authentication", which is the system's default class and what a background upload
  needs: they are readable while the phone is locked after its first unlock. Named at the write: the stored
  answer and the two small files beside it, the other JSON state files of the SDK's `cloud` folder, the
  contributor's files, the registration day and the rollout bucket, every file of a queued recording, the
  install record, the manifest and the model's pointer files; the folders the SDK makes for them get the class
  when they are made. Getting the class at the next start: the model files as they are downloaded, the
  accelerator's files, the first-launch marker, and what an earlier release left.
  That walk visits the SDK's own four folders in its storage folder (`cloud`, `models`, `outbox`,
  `accelerator`) and nothing else: not the storage folder itself, and no file of the app's own that lies in it.
  A file that cannot be changed at that moment is left for the next start. The Keychain items are as they were
  (this device only, readable after the first unlock).
- **Fixed: a deletion that the process ended in was never asked again.** "Delete what I shared" noted on the
  device that a deletion was being asked before it asked the server. A process that ended before the server's
  answer left that note; the next start took it for an off and never asked the server again, so what the learner
  had shared was not deleted. Now the note is a small file of its own in the storage folder, holding that a
  deletion was asked, when, and whether its off has been written. A start that finds it turns sharing off, as
  before (once: a yes the learner gives after that stands), and asks the server again with the same
  contributor and the same device key: once per start, and once more with a fresh challenge when the server
  answers 401 `nonce_invalid` or `timestamp_invalid`. After a 202 the device's part is done (the unsent queue,
  the count of recordings, a new contributor, key and code) and the file is removed. A 429, a 5xx or no answer
  leaves it for the next start. A start that cannot read the contributor or the device key does not ask, and
  leaves it too. While the file is there, nothing is recorded for sharing and nothing is uploaded, also when the
  learner has turned sharing on again meanwhile: their yes is stored at once and takes effect when the server
  has confirmed and a new contributor is made, so that no recording belongs to a contributor whose deletion is
  being asked. A state that an earlier version stored with that note is taken over at the first read. A
  deletion the server does not take while the process lives ends as before: the call throws, nothing is left
  on the device, sharing and the queue are as they were. The request carries neither the developer key nor a
  token, as before.
- **Fixed: an upload the system still held for a recording that was gone.** On iOS a segment's upload is handed
  to the system's background session. Only the process that turned sharing off cancelled its uploads; one that
  the system still held when the next process started went on. Now, when the queue opens, every such upload
  whose recording is no longer in the queue as one to send is cancelled: it is gone, or it was made under an
  earlier consent, or the learner's answer or one of its files cannot be read. One that is cancelled for a
  recording that is still to send is sent again later.
- Tests (on the public CI's Mac runner; none ran on a phone, and no test locks a device):
  - "Cannot be read" is a switch of the tests: the SDK's read of the named file fails as the read of a protected
    file fails, the file itself is untouched. The Keychain is a stand-in kept in memory that can be locked (every
    call answered `errSecInteractionNotAllowed`); what the real Keychain answers to an add or a delete while it
    is locked was not measured. The server is the suite's stub.
  - A stored yes with an unsent recording, a stored "Not now" and a stored final no, each unreadable at the
    process's first read, then one finished session, then readable again: the file's bytes are what they were,
    the queue is whole, nobody was asked, nothing was uploaded meanwhile, and the upload goes on once it reads.
    The same for a file that does not parse, across two starts; then the learner's switch on, and off, and a
    deletion over such a file: the new state, the file kept aside with its bytes, the queue gone, nobody asked.
  - One test for each of the other items: the stamp, the item file, the capture file, the open segment's audio,
    a marker of a recording of two segments; the contributor id, the device key and the recovery code as files
    and in the stand-in Keychain (after they read again they are the same bytes, and a deletion is signed with
    the key that was there); a stored Secure Enclave key that the enclave does not give (a blob that is not this
    machine's: the stand-in for an enclave that answers "not now"); the remembered refusal; the install record
    and the manifest. For the remembered refusal, the install record and the item file a second test shows the
    damaged file going the old way.
  - The deletion: the process "ends" by leaving the first call waiting for an answer that never comes and
    opening a new server client and queue on the same storage (no process is killed). The next start asks the
    server; a third start after the 202 asks nothing; the 401 answered once with a fresh challenge; a 503, a 429
    and no answer leave the file; the state of an earlier version; a start that cannot read the device key; a
    start that cannot read the stored answer; the learner's yes while the file is there (stored, nothing recorded
    or uploaded, and after the 202 a take is recorded under a new contributor).
  - The shared case of the same situation (`sharing_off.json`, "delete, the process ends while the server is
    asked"): the stand-in server leaves only the first process's request unanswered and answers the next
    start's with 202, and sharing comes on again after that deletion is confirmed, by the rule above.
  - The upload the system still held: a real background session of the SDK's uploader on the Mac runner and a
    server on the loopback interface that takes the request and does not answer; the earlier process is the test
    starting the upload. Not shown: an app the system suspended or ended, a relaunch by the system.
  - The tests above were run first on the code of 3.1.3, with nothing but the tests' switch added to it: there
    each of them fails. What passes there are the controls (a file that is not there is "never answered"; the
    upload of a recording that is in the queue is not cancelled; a deletion the server does not take while the
    process lives leaves nothing) and the tests of a damaged file going the old way.
  - Not among those, because they test what this version adds:
    - the switch, through `client.sharing.setOn`: an off asked while the stored answer cannot be read, applied
      when it reads in the same process, and by the next start; with the deletion's file there too (the off
      applied once, the deletion still asked); with a device that stores nothing (the call throws, and no take is
      recorded for the rest of the process); an off that was applied while the device stored nothing, then a yes
      (a new start reads the yes); an on asked while the answer cannot be read (throws, nothing changed);
    - the learner's summary, which is not asked of the server while the contributor id cannot be read;
    - which paths the walk of a start visits: a storage folder with the SDK's four folders and files of the
      app's own beside them; the SDK's are visited, the others and the folder itself are not.
  - The protection class: not shown by a test. On the Mac runner every file shows "complete until first user
    authentication", whatever class its write names, so the two tests of it cannot tell this version from the
    one before and are skipped there. That the SDK's files carry the class, and that an earlier release's files
    get it at a start, can be shown only on a device, in an app whose files have another class by default.

## 3.1.3

One correction: no request of the SDK follows a redirect. The same engine, the same model builds and the same
API as 3.1.2.

- **Fixed: a redirect is never followed, on any request.** Since 3.1.0 the requests for model files refused a
  redirect (before 3.1.0 they followed one too, with the key's header: read, not run). Every other request of
  the SDK (the token and attestation calls, the config, the registration,
  telemetry, issue reports, the calls of recording sharing and of its deletion) left a redirect to the system,
  which follows one by itself and sends the request again to the address the answer names. Measured on 3.1.2
  against two test servers: to the second server the system sent the header with the developer key
  (`x-qlab-key`, on the token and attestation calls) and the header with a recording's id (`x-qlab-id`, on a
  sharing call), and with a 307 the request's body as well; it did not send the `authorization` header, which
  carries the install's token, to the other host. None of this happened with Quran Lab's servers: they never
  answered one of these requests with a redirect, so nothing was sent anywhere. From this version the SDK tells
  the system no on every request. An answer that is a redirect is a failed request, like an answer that did not
  come: it is not followed, it is never taken for a refusal of the key, and it is asked again only as the call
  asks again after any failure.
- **The one path where the system does not ask.** On iOS the segments of a shared recording are uploaded on a
  background session, and there the system follows a redirect without asking the SDK. The SDK now looks
  afterwards: an upload that the system redirected does not count as uploaded, whatever the other server
  answered. The segment stays on the device and is sent again later, to a fresh address from Quran Lab's server,
  and the host the upload ended on (the host only) is reported to Quran Lab as an issue (`upload_redirected`).
  That request carries one segment of a recording and neither the key nor a token. It cannot happen with Quran
  Lab's storage, which answers an upload directly.
- Tests (on the public CI's Mac runner; none ran on a phone):
  - On the system's real network stack, not on the stub the other tests use: the SDK's own session and two
    servers on the loopback interface. The first answers 302, then 307, with the address of the second, which is
    another host name of the same machine. For a model request, the token request (the key), the config request
    (the token), a sharing start and a segment's upload as it runs in the app: the second server is never asked,
    the first once, and the call fails.
  - The same tests on the code of 3.1.2, in one run: red for the token request, the config request and the
    sharing start, with the headers named above at the second server. Green there for the model request (refused
    since 3.1.0) and for the segment's upload in the app: 3.1.2 did not send that one on either, because the
    system does not send a body that is read from a file as a stream a second time; the call waited 30 seconds
    and failed.
  - The background upload, with a real background session of the SDK's uploader on the Mac runner and the same
    two servers: the system followed the 307 and the 302 by itself and the second server got the upload with its
    3000 bytes (and no key and no token); the uploader did not hand that on as an upload and named the host. A
    test process on a Mac is never suspended, so an upload that goes on while an app is suspended, a relaunch and
    a phone are not shown.
  - The upload queue's part runs over the stub network, where the redirect is the test making the call the
    uploader makes: the segment stays unsent, the queue asks for a fresh address and sends it again, and the
    issue carries the host only.

## 3.1.2

- **Changed: the sharing sheet and "What is shared" have the text of copy deck `2026-11-09.1` again.** Copy
  deck `2026-11-13.1` (consent `share-2026-11-09`), in eight languages. A learner who already agreed is not
  asked again, and their recordings keep the version they agreed to.
- Tests (on the public CI's Mac runner, against a stub server; none ran on a phone): the eight bundled decks are
  the published ones by their SHA-256; the sheet's strings are the deck's `sheet.who` and `what.detail`, whole, in
  each of the eight languages (checked on the strings the sheet is built from, not on a drawn sheet), and none of
  the deck's strings holds the sentence that deck `2026-11-12.1` added (the test knows that sentence by its length
  and SHA-256 per language only); an install with a stored yes under `share-2026-11-12`, under `share-2026-11-09`
  and under an app's own wording (the stored state written by the test as 3.1.1 and 3.0.1 left it) is not asked
  at start, after many sessions or after a restart, and the recordings it uploads to the stub carry the version
  it agreed to.

## 3.1.1

The sharing sheet has a new design, and two fixes from a report on real devices. No word, no consent rule and no
consent version changed; the same engine, the same model builds and the same API as 3.1.0.

### Fixed
- On a Mac, a command-line tool or any process without an application identifier downloaded the model again at
  every start: the saved install key was never found. Fixed; iPhone and iPad apps were not affected. (Such a
  process's reads of the data protection keychain answer "not found" and only its adds "missing entitlement", so
  the key it had kept in the login keychain was never looked for. Now, on a Mac, a read that finds nothing there
  or is refused looks in the login keychain before it answers that there is no key, and a key that a second read
  finds is never replaced.)

### Changed
- A take that is cancelled or finished before any audio was pushed is no longer counted as a session in the app's
  statistics. (An app that opens a session and cancels it at once, to have the model ready for its options before
  the learner starts, added one aborted session a launch. The recognizer is still made and warmed.)

### The sharing sheet has a new design
- What a learner sees: at the top the Quran Lab emblem and the name "Quran Lab", then the title and the body; one
  card with what is shared, who receives it and how to stop, each line with its icon; the hadith in a card of its
  own; the line about mistakes; in a children's app the guardian's switch. The two buttons sit in a bar at the
  bottom that does not scroll, so they are always in view: "Share my recitations", filled with the accent colour,
  and "Not now", filled with a light tint of it, of the same size, shape and type. What is shared, who receives it
  and how to stop now come before the hadith, so on an iPhone they are on the first screen with the buttons.
- Before (3.1.0): the deck's lines stacked in one font, a box with a stroke, two outlined buttons of different
  heights at the end of the scroll, and the hadith before what is shared.
- On an iPhone the sheet opens at full height with a grabber; on an iPad and on a Mac it is a centred card 480
  points wide. Arabic and Urdu sheets are laid out right to left, whatever the app's own direction, and the other
  six languages left to right. Under the buttons there are 30 points, or the bottom safe area where it is larger.
- The text is the system font at the design's sizes and weights (the title 26 points bold, the body 15.5, the
  card's lines 14.5, the buttons 16 semibold), in its own colours for light and dark mode, and it grows with the
  learner's text size (Larger Text on iOS) up to the largest accessibility size; the buttons then grow in height,
  keep their label on two lines at most, and never cut it. Nothing set on the app's own views reaches the sheet: a
  font, a weight, bold or italic, a text size, a line limit, upper case, an alignment or a placeholder redaction set
  near the app's root no longer changes how it looks (in 3.1.0 a `.fontWeight(.semibold)` or `.bold()` on the app's
  views made every line of the sheet semibold). One exception: `.monospacedDigit()`, which SwiftUI gives no way to
  undo, still gives the digits of the hadith's reference equal widths. The system's Bold Text setting still applies.
- What a theme still changes. `SharingTheme` keeps its fields and its initialiser, so an app that themes the sheet
  compiles as before. `accent` (by default the app's accent colour, as before) fills the share button and the
  switch, and the tint of "Not now", of the emblem and of the hadith's card comes from it. The share button's
  label is white, or near black where white cannot be read on the accent; the "Not now" label and the icons are in
  the accent, or in the text colour where the accent cannot be read on the tint or the card. "Read" means 3 to 1,
  as the system's own buttons have (so the system's blue gets a white label and blue icons), and 4.5 to 1 when the
  learner has turned on Increase Contrast. The running text never takes the accent and keeps 4.5 to 1.
  `background`, `text` and `secondaryText` replace the sheet's own colours, and the cards, the dividers and the
  body text follow them. `cornerRadius` sets the buttons' radius and scales the others with it. `titleFont` and
  `bodyFont` replace the title's and the running text's font. A theme does not change the order, hide a line, or
  change or hide the name at the top.
- The thank-you and the settings views take the same colours and type; what they hold is unchanged.
- Fixed (since 3.0): in Arabic and Urdu a line that begins with Latin letters was laid out as a left to right
  paragraph: who receives the recordings (the sheet's line that starts with the name Quran Lab, in both
  languages) and, in Urdu, the line shown when deleting fails without a network. Read from the right, the name came
  at the end of the line's first row and the full stop on the wrong side. Every text of the sheet, the thank-you
  and the settings now takes its direction from the deck, whatever its first letter. A screen reader reads the
  same words as before.
- The SDK's own presentations (the sheet it shows by itself, `.quranLabSharing(client)`,
  `SharingConsentViewController`) ask iOS for the large detent and the design's corner radius on an iPhone and a
  480 point card on an iPad; `SharingConsentViewControllerMac` asks for 480 by 680 points.
- Unchanged: every word (copy deck `2026-11-12.1` in eight languages), the consent version `share-2026-11-12`,
  when and how often the sheet is shown, and what each button records.

### Tests
The tests below run on the public CI's Mac runner; the sheet is drawn by SwiftUI on that Mac, not on an iPhone.
Not run on a device: the large detent and the corner radius of the iPhone sheet, the switch's colour, and the text
size, Bold Text and Increase Contrast read from the device.
- The install key in the Mac runner's real Keychain, from the test process (a process without an application
  identifier): its data protection keychain answered a read of a missing item with -25300 (errSecItemNotFound) and
  an add with -34018 (errSecMissingEntitlement); a key one start keeps is the key the next start finds, and a create
  after a read that missed it gives that key back (both failed on 3.1.0's rule). The key store's decision for every
  answer of either keychain, on macOS and on iOS, over a stand-in for the two keychains.
- A take cancelled or finished without audio (pushed, of empty buffers, or a microphone that gave nothing) records
  nothing and is not a finished session for the sharing ask; a take with one buffer of audio and then cancelled is a
  session and aborted, as before.
- Every line of the sheet is drawn whole, as the deck file has it, in each of the eight languages, in the first
  ask, the re-ask and the guardian's variant, and the name is at the top (also with a theme that sets every field
  and with the app's own wording). The 3.1.0 test of the deck's lines is unchanged and passes.
- The two buttons have the same width and height in every language, at the default and the largest text size, on
  a 390 and a 320 point wide phone; 52 points high (one line) at the default size, and never more than two lines of
  a label.
- In the guardian's variant the share button cannot be tapped until the switch is on; clicking the switch enables
  it and clicking it again disables it; "Not now" always can.
- The layout direction follows the deck, also in an app laid out the other way, and every text of every deck (the
  sheet, the thank-you, the settings, the plural forms) is a paragraph in the deck's direction, as Core Text
  resolves the string the views draw.
- Under the buttons: 30 points to the sheet's edge without a safe area and the safe area where it is larger.
- Nothing of the scrolled column is drawn in the grabber's band at the top of the phone sheet (its pixels, light
  and dark).
- The sheet drawn inside each of 22 modifiers an app may set on its views is the same, pixel for pixel, as without
  them.
- The colours: the design's tokens in light and dark mode, the tint and the label on the accent as the design
  derives them; the running text at 4.5 to 1; the labels and icons at 3 to 1, or 4.5 with Increase Contrast, with
  the system's blue (a white label and blue icons in light and dark mode; near black and the text colour with
  Increase Contrast), a yellow accent (near black, the text colour) and the design's teal.

## 3.1.0

A model comes from Quran Lab's server, through the Client, and in no other way. The same change in the Android,
Apple, web and C SDKs, and one sentence more on the sharing sheet. The same engine and the same model builds as
3.0.1.

### Removed: opening a model folder the app supplies
- `TajweedModel.open(_:)` is removed, and the Client no longer looks for a model in the app bundle
  (`QuranLabModels/<model id>/`). A model comes from Quran Lab's server through the Client.
- Why: the model is Quran Lab's to deliver, verify and update; an app that carries its own copy cannot be told of
  a newer or a withdrawn build.
- What replaces it: `client.model()` downloads the model on first use, verifies it, opens it and warms it, and
  `client.prefetch()` downloads it ahead of use.
- Migration: replace `try await TajweedModel.open(folder)` with `try await client.model()` on a
  `TajweedClient(key:)`, and take the model folder out of the app's resources. An app that still calls the removed
  function does not compile.

### Changed: the Client opens only a build it downloaded itself
- The Client marks every build it downloads with a record that is bound to the device: the record's key lives in
  the Keychain (this device only, readable after first unlock), not among the app's files. A model folder in the
  Client's storage without a valid record (put there in advance, or copied from another device) is not opened and
  none of its files is reused: it is deleted, and the build is downloaded.
- An install that updates from 3.0 downloads its model once more at the first launch after the update, because the
  model that 3.0 downloaded has no record. Without a connection at that launch `client.model()` throws
  `needs_connection`, and the download happens at the next call with a connection.
- After that download a learner without a connection keeps working, as before. An interrupted download resumes
  where it stopped.
- When the Keychain does not answer (for example before the first unlock after a restart), `client.model()` and
  `client.prefetch()` throw `storage_failed`; nothing is opened, deleted or downloaded, and the next call tries
  again.
- On a Mac, an app without a provisioning profile (an unsigned or ad hoc signed binary, a command line tool) is
  refused by that keychain; there, and only there, the key lives in the Mac's login keychain, in an item named for
  the app's bundle id. It is not among the app's files, and it can travel to another Mac with the keychain.

### Changed: model files are requested with the install's token
- Every request for a model file (the manifest, every file, every range of a file) carries the install's token
  beside the developer key. The SDK has the token before its first model request, attested where the system
  supports App Attest. When the download server answers `invalid_token` the SDK renews the token once and repeats
  the request once. A model request never follows a redirect.
- New answers of the download server, each with its own words: `server_rejected` with the reason
  `model_attestation_required` (the install could not be confirmed where Quran Lab asks for that; never for a
  development key) or `model_not_allowed` (model files are switched off for the platform), and `download_failed`
  when Quran Lab's daily limit for model downloads is reached (try again later; the SDK does not repeat the request
  in a loop). None of them stops a model that is already on the device.

### Changed: a refused key or app does not run the model, and the model is removed
- When Quran Lab refuses the key or the app (a revoked key, a paused or blocked app), the SDK stops running the
  model and removes the downloaded model from the device. Once the key is accepted again the model is downloaded
  again.
- The refusals that do this say why: a key that is revoked or that Quran Lab never issued, a key of another app
  or of the wrong type, an app that is blocked by Quran Lab or paused by its developer, an account without access.
  `client.model()` and `client.prefetch()` throw the refusal's error (`invalid_key`, or `server_rejected` with its
  reason) and open no model. The refusal is remembered on the device, so a launch without a network stays
  refused. Until 3.0.1 a refusal stopped the network calls of the launch and nothing else.
- What is removed: every model build the SDK holds, with its partial downloads and the Core ML packages in the
  build folders (what `client.removeModels()` removes), in the call that received the refusal. The learner's
  sharing choice and the recordings that are not sent yet stay. When a file cannot be removed the SDK tries again
  at every start; the app gets the refusal's error, never an error about the removal. What the system cached by
  itself is not the SDK's to remove: the compiled form that Core ML keeps for the Neural Engine of a package the
  SDK loaded stays until the system drops it.
- A Model that is already open when the refusal arrives keeps running until the app closes it; its files are
  removed when it is closed, or at the next start.
- Not a refusal, and a model on the device keeps running and stays: no network, a timeout, a failure of the
  server, a rate limit, a network that Quran Lab does not serve, `sdk_too_old`, and every answer that names no
  reason.
- The words of `app_blocked` now say both cases: blocked by Quran Lab, or paused by its developer on the app's
  page. The fix of `model_missing` no longer speaks of opening a folder.

### The sharing sheet
- **Changed: the sharing sheet and "What is shared" now say that no human ever listens to your recordings:
  only software learns from them.** Copy deck `2026-11-12.1` (consent `share-2026-11-12`) in eight languages. A
  learner who already agreed is not asked again, and their recordings keep the version they agreed to.

### Tests
The tests below run on the public CI's Mac runner against a stub server; those that open a model use a small test
model (not a released model build) and a stand-in engine. The device's key store is a stand-in in memory in every
test: no test touches a real Keychain. Where App Attest is needed it is a stand-in too. None of them ran on a
phone or against Quran Lab's servers.
- The sharing deck: the eight bundled decks are the published ones byte for byte; the line about who receives the
  recordings and "What is shared" are the deck's own text, whole, in each of the eight languages (checked on the
  strings the sheet is built from and on the sheet's source, not on a drawn sheet); an install with a stored yes
  under `share-2026-11-09` (the state written by the test as SDK 3.0.1 left it) is not asked at start, after many
  sessions or after a restart, and the recordings it uploads to the stub carry `share-2026-11-09`.
- The install record: a storage filled in advance exactly as a real download leaves it (without a record, with the
  record of another device, on a device without a key, with a record of another build) is not opened and is
  replaced by a download; a real download and then a relaunch opens with no request for a file, also without a
  network; an interrupted download resumes (the stub fails one file, and the test writes the first bytes of that
  file as a broken transfer leaves them), and the same folder on another device does not; the two ways the key
  store can fail (the stand-in is told to have no key, or to fail); the record is written before the first file is
  asked for; the update from 3.0, with and without a connection (a 3.1.0 download with its record taken away
  stands for what 3.0 left).
- Model requests: the exact headers of the manifest request and of every range request; the token is in hand
  before the first of them, the attested one with the stand-in for App Attest; the renewal on `invalid_token`,
  once; no redirect is followed.
- The refused Client: every case of the vector the four SDKs share (`model_gate.json`, 32 answers of the API and of
  the download server), with a model on the device and without one; a relaunch without a network stays refused; an
  accepting answer ends it; a refusal of a model request is not ended by an answer of the API; a Model that is
  open keeps running.
- The removal: a refusal with a downloaded model on the device leaves no model file and no install record when
  the call returns, also in the middle of a download; the remembered refusal and the device key stay, and so do a
  stored sharing state and a stand-in file in the upload queue's folder that stands for a recording not sent yet
  (no real recording is queued in this test); an answer that is not a refusal removes nothing; after the accepting
  answer every file of the build is asked for again; the files of an open Model go when it is closed; a removal
  that fails (made to fail by a switch of the test, not by a real storage error) is tried again at the next
  start; a start without a network that finds a remembered refusal and model files, put back by the test, removes
  them first.
- No public declaration takes a model, a base URL, a trusted key, a verifier or a transport (read from the
  sources).

## 3.0.1

One fix for sharing and two for `diagnose()`. The same engine and the same model builds as 3.0.0, and nothing to
change in an app's code.

### Sharing: off means off, whatever was being uploaded
- What was wrong, since 2.0.0: when a learner turned sharing off, or deleted what they shared, while a segment of
  a recording was being uploaded, that upload was not cancelled. The rest of the segment still went to Quran Lab's
  storage after the call had returned: at most the remainder of one segment (a segment holds 10 to 60 s of audio;
  60 s is 1.44 MB at the top bitrate). Nothing followed it: no further segment, no further request, and the unsent
  queue was deleted from the device as documented. In production the sharing sheet has been on for iOS and macOS
  only, so this SDK is the one whose learners could share.
- How it was found: after 3.0.0 was released, by the test of the situations the four TajweedFormer SDKs share
  (`sharing_off.json`: a server that holds a segment upload, the start of an upload, a batch of upload URLs or the
  take list in flight, while the learner turns sharing off or deletes; 12 situations, 20 runs each). With a
  segment in flight, audio left after the call in 60 of 60 runs: up to 275,412 bytes of a 279,508 byte segment.
- Fixed: every request of an upload is cancelled the moment sharing goes off (the start of the upload, the upload
  URLs, each segment, the take list, the wait for a token, and on iOS the uploads of the background session), and
  the upload checks that sharing is still on before every request and after every answer. After `setOn(false)` or
  `delete()` has returned, the request in flight is cancelled and the SDK hands nothing more to the system. What
  the system had already buffered for the connection may still go out, and that can be the whole segment that
  was being sent; nothing after it is sent. In the test, against a local stub, 0 bytes more arrived. Measured
  on a phone of another platform (Android 11), the system's buffer held 2,220,032 bytes when the request was
  ended, which is more than one segment; the buffer of iOS and macOS is not measured.
- `setOn(false)` returns within 3 s whatever the network does, and turning sharing on again works at once. Until
  now a request that hung kept the queue busy, and the next recording waited behind it for up to 30 s.
- `delete()` stops the queue before it asks the server. Until now it asked first, and segments could still be
  sent while the server was deleting. As before in this SDK, a delete the server accepted turns sharing off (the
  learner turns it on again with the switch, and is not asked again); a delete the server did not take throws and
  changes nothing: sharing stays on, nothing on the device is deleted, and the queue goes on.
- A take list that had not been sent when sharing went off is deleted with it. Until now its file (the start and
  the gap of each take, no audio) stayed in the folder of the uploaded recording.

### Sharing: a recording made before an off is never uploaded later
- What was wrong, since 2.0.0: turning sharing off deletes the unsent queue, and nothing else kept those recordings
  from being sent. When the process ended after the off was saved and before the queue was deleted, or a recording
  could not be deleted, the recordings stayed on the device; the next launch took them back into the queue, and
  when sharing was turned on again they were uploaded. The fault needed all of: sharing turned off (or a deletion),
  the process ending before the queue was deleted or a recording that could not be deleted, and sharing turned on
  again.
- What the test saw (the restart cases of `sharing_off.json`: nine recordings in the queue, the deletes made to
  fail, a new process on the same storage, sharing on again): before this fix all nine were uploaded whole, 18
  requests and 88,529 bytes of audio in a run, and a launch with sharing off deleted none of them.
- Fixed: the learner's answer carries a count of their changes of mind (sharing on, sharing off, an accepted
  deletion), written in the same write as the answer, and every recording is stamped with the count it was begun
  under, on the device only. A recording with another count, and every unsent recording while the learner's yes is
  not in force, is never taken into the queue and is deleted when the SDK starts and before every upload pass; one
  that cannot be deleted yet is tried again. A pause of sharing by Quran Lab's config is not the learner's no and
  keeps the queue. A queue left by an earlier SDK is uploaded as before while sharing stays on.
- `delete()` writes on the device that a deletion is being asked before it asks the server. A process that ends
  before the answer is written finds that at its next launch and turns sharing off. When the device cannot store
  the off (a full disk), the server is asked all the same, and the off is stored as soon as the device can. One
  case remains and is accepted: the device stored that a deletion was being asked, the server did not take the
  deletion, the write that puts the earlier state back failed, and the process ended before a retry succeeded.
  Sharing is then off at the next launch, and nothing is uploaded; the learner turns sharing on again with the
  switch and is not asked again.

### `diagnose()`
- `backend` is what a Session with the default options would run on now, for the model's default context: a
  promoted CoreML build reads `accelerator`, its name, `promoted`, with or without an open Model; a build that was
  set aside reads `cpu`, `demoted`, with its reason. Until now it was the Backend of the engine of the Model's last
  Session, so after a Session on the CPU engine or in another context a promoted build read as `cpu`; and without
  an open Model it was always `cpu`.
- `scripts/prove-on-mac.sh`: the summary's line about the SDK is made from the last `diagnose()` of the run, the
  one step 6 prints. It was made from the first, so the two could disagree when the newest release changed while
  the run went on.

## 3.0.0

A breaking release. The SDK is an inference engine: audio in, the model's output out (every head of the network,
and what the model heard), and nothing derived from a known text. The scorer and the tajweed settings are removed,
and the public API is five types with the same names in the four TajweedFormer SDKs. What to change in an app, and
what an app that showed verdicts builds itself: [docs/migrating-to-3.md](docs/migrating-to-3.md). The whole public
surface: [docs/api.md](docs/api.md).

A 3.x SDK runs only model builds made for it; the 2.x builds stay with SDK 2.x.

### Removed
- Scoring: `score(surah:ayah:)`, `TajweedResult` and its sites, madd, qalqalah, gemination and word verdicts,
  `TajweedOptions`, presets, per-class overrides, word levels, and the tajweed settings of the signed config.
- The 2.x entry points: `QuranLab.configure`, `TajweedRecognizer`, `TajweedModel.load()`, `Contributions`,
  `RecognizerError`, and every other public type that is not in docs/api.md. The public surface went from 738
  declarations in 115 types to 247 in 46 (the 23 named types, their nested value types and the sharing views).

### The API
- `TajweedClient(key:)`: one per process (`client_exists` for a second one). `client.model()` downloads the model
  once, verifies it, opens and warms it; `client.model(version:)` asks for a model version. `client.prefetch`
  (resumable, with progress, optionally on unmetered networks only), `client.storage`, `client.removeModels()`.
- `TajweedModel`: `version`, `build`, `contexts`, `defaultContext`, `tokens`, `sampleClips`, `backend`, and two files
  of the model as data for an app's own judge: `calibration` (the thresholds and weights Quran Lab measured; never
  applied by the SDK) and `reference` (the expected units of every ayah; downloaded only by `reference.fetch()`).
- `TajweedSession`, one take: `model.listen()` asks for the microphone and captures at the device's rate;
  `model.listen(from:)` runs a sample clip or your samples through the same path; `model.session()` takes pushed
  audio. `chunks` (each with its `heads` and the `decoded` layer of the take so far), `events`, `finish()` (the
  take's `TajweedHeads`), `cancel()`.
- Events: `speechStarted`, `speechEnded`, `interrupted`, `resumed`, `backendChanged`, and `ended` with its reason
  (`silence`, `background`, `interrupted`, `sourceEnd`, `limit`, `error`). `endOnSilenceMs` finishes a take by
  itself after silence. `decoded.settled` says how many tokens will not change; `isFinal` marks the last chunk.
- `TajweedError`: one error type with a stable `code` (26 codes, the same in the four SDKs), `message`, `fix` and
  `docs`. New situations have their own codes: `needs_connection` (a first run without a network),
  `model_unavailable` (Quran Lab has no model build for this SDK version yet), `session_open`, `client_exists`,
  `runtime_unsupported` (a processor the SDK does not run on: an Intel Mac, the x86_64 simulator),
  `network_not_permitted` (the app may not use the network).
- A refusal says what to do. When Quran Lab refuses the app with a reason it names (the account has no access yet,
  the key is of another type, the key is not for this app id, the app is blocked, and three more), the error is
  `server_rejected` with that reason's own message and fix; any other refusal names the server's code. The answer's
  `reason` is read first: a key that belongs to another app, a key of another type and an identifier that is not on
  the key arrive as a refused key (401) with the check named in `reason`, and the error is `server_rejected` with
  that check's message and fix ("This key belongs to another app"), not `invalid_key`.
- `client.diagnose()`: one report of where the SDK stands, safe to paste into an issue. Its `connection` is
  `unmetered`, `metered`, `none` or `unknown`, and `prefetch(unmeteredOnly: true)` follows it: it downloads on
  `unmetered` and `unknown` and does nothing on `metered` and `none`.

### Models
- A model has a version and a folder is a build of it. The signed manifest carries the version; the build id is the
  first 40 hex digits of the SHA-256 of the manifest. A manifest without a version (a 2.x build) verifies and is
  refused (`model_incompatible`). Telemetry and incident reports name the version and the build.
- The Neural Engine's build is promoted by a golden test on raw outputs: per CTC head the greedy tokens and the
  distance of the log-probabilities, and the mean difference of the attribute heads' probabilities, against the CPU
  engine, within the tolerance the signed manifest gives the build (tokens only without one).
- The context a Session runs: `TajweedSessionOptions.context`, else the signed config's `inference.context`, else
  the model's default.
- The Neural Engine's build is the fp16 CoreML build (`coreml`), as in 2.x. The compact build (`coreml-compact`, a
  delta of 1.7 MB against the CPU weights already there, where the fp16 build's is 76.1 MB) is named per Session,
  `TajweedSessionOptions(backend: .coremlCompact)`, in place of 2.x's `compactCoreML` option; a device does not try
  it on its own. A folder may hold both builds; installing one no longer deletes the other.
- Speech and silence come from the model's own output, one rule for the events, `chunk.speech` and the telemetry: a
  40 ms frame is speech when `log_probs` or `timing_log_probs` hears a sound on it, so a held vowel is speech. The
  SDK computes the timing head on every take and hands it out only when it is selected. `speechEnded` comes when the
  window (`endOnSilenceMs`, else 1500 ms) has passed after the last such frame. `endOnSilenceMs` takes 500 to 60000.

### Bounds
- A take holds at most 20 minutes of audio; at the limit it ends by itself with `ended(.limit)`, its Heads kept.
- At most 256 chunks and 64 events wait for the app; when it reads late, the oldest waiting ones are dropped (the
  last chunk and `ended` never), and `diagnose().droppedChunks` counts them. `finish()` returns the whole take.

### Telemetry
- Per model version, build, context and backend: takes, audio, speech and silence, tokens per head, compute time.
  Everything derived from scoring is gone. Two calls report what only the app knows:
  `session.reportRecited(surah:ayahFrom:ayahTo:)` and `client.analytics.reportChecks(rule:checked:flagged:)`.

### Sharing recitations
- Reached through `client.sharing`. The rules are unchanged: Quran Lab decides per app, the learner is asked at most
  three times, a yes is never asked again, and a learner keeps the consent version they agreed to.
- Takes in a row share one recording. A shared recording stays open after a take for a few seconds (3 s; the signed
  config's `flags.share_join_ms`, 0 to 10000 ms, 0 never joins), and a take that starts in that time at the same
  input rate continues the same Ogg stream: no new headers, the encoder keeps its state, and the pause between the
  takes gets no audio. A recording of two or more takes sends where each take starts and the pause before it
  (`POST /v1/uploads/{id}/takes`) after its last segment. A take list the server refuses with 400 is kept and tried
  again on the outbox's backoff until it is accepted, sharing goes off or seven days pass.
- `client.sharing.feed(_:sampleRate:)`, for apps that capture audio themselves outside takes: the last second of
  what is fed goes in front of the next take's recording and up to half a second after a take, so a recitation is
  not clipped at a take's edges. Kept in memory only, one second at most; dropped at once without the learner's yes.
  After every take the recording waits for that half second until 1.5 s after the take's end, also when no take can
  join it any more; what is fed later goes in front of the next take. In that time only fed audio is recorded: with
  `listen()` the microphone is closed when the take ends.
- A recording never holds more than 20 minutes of audio: it closes there, also inside a take, and the take goes on
  in a new recording. A take that starts with 30 s or less of room is held in memory until it ends, and joins only
  when it fits.
- The session JSON of a recording carries `take_seq` (the install's count of shared recordings) and `gap_ms_prev`
  (the time since the previous one, rounded to 100 ms, left out above an hour). No identifier, no wall-clock time.

### Fixed
- Configuring twice left two upload queues on one storage, each sending the same recording. There is one Client per
  process, and a closed Client's queue sends nothing.
- A golden test that passed kept none of what it measured. The measures (token edits and log-probability distances
  per head, the mean probability difference of the attribute heads) are kept with the promotion's record, also for
  a build that signs no tolerance and for a test that failed.
- `prefetch` reported no progress when the launch's own update check had already started the download. A listener
  that comes while a download runs gets its progress from where it stands.
- The Backend's name came from the folder as it was when the model was opened, so it could name the other CoreML
  build. The name comes from the build the promotion pipeline runs.
- One `diagnose()` report could say the config was fresh while the key was still unanswered, when the config
  arrived while the report was made. The config's state is read first.

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
