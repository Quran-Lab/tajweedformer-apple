#!/bin/bash
# The proof on a Mac: one command that takes TajweedFormer for iOS and macOS through its whole path against Quran
# Lab's production servers with your own app key, and prints a one-screen summary whose last lines you paste back.
#
#   scripts/prove-on-mac.sh <key> [<clips folder>]
#   QURANLAB_KEY=<key> scripts/prove-on-mac.sh [<clips folder>]
#   scripts/prove-on-mac.sh [<clips folder>]      asks for the key without showing it
#   scripts/prove-on-mac.sh --check               only the checks of this Mac (step 0): no key, nothing is built
#   scripts/prove-on-mac.sh --compact <key> ...   also takes the compact CoreML build through the pipeline (see below)
#
# <key>            a desktop key from sdk.quranlab.ai (qlk_v1_...). It goes to the test process in its environment:
#                  it is never written to a file and never printed. A key works for the first app identifier that
#                  used it, and this run registers as ai.quranlab.sdk.prove: the key you give it will belong to
#                  that identifier. Use a key made for the proof, or allow that identifier on the key's page
#                  (https://sdk.quranlab.ai/keys). QURANLAB_APP_ID names another identifier for the run.
# <clips folder>   optional, for step 5: the conformance clips as audio/<clip>.pcm (16 kHz mono float32). Their
#                  expected rows are the engine's (engine/conformance of this checkout, or QURANLAB_PROVE_EXPECTED).
# --resume         keep what an earlier run downloaded and prepared (the default is a fresh start, so that every
#                  run shows the whole path).
# --compact        the run takes the fp16 CoreML build (coreml) through the pipeline: it is the build an Apple
#                  device gets by default. With --compact it then does the same with the compact build
#                  (coreml-compact), which a device gets only when an app names it. Use it to measure both builds
#                  on a device (it adds a download of about 3 MB and three more compiles).
#
# The steps (the run itself is Tests/TajweedFormerTests/ProveOnMac.swift, through the SDK's public API):
#   0  this Mac: macOS, Xcode and Swift, Apple silicon, free disk space, power, the network. Checked before
#      anything is built; when something is missing the script stops with one sentence that says how to fix it.
#      A later stop on an SDK error prints the error's message and, under it, its fix from the error catalogue.
#   1  TajweedClient(key:), the signed config, the model version and build it names.
#   2  client.prefetch with its byte progress, client.model(): the manifest's signature with the release key,
#      every file's size and SHA-256, the model's version and build.
#   3  every sample clip of the model through listen(from:), in every context, on the CPU engine and, where a
#      build was promoted, on the Neural Engine: the take's tokens against the folder's expected tokens.
#   4  the promotion pipeline to its end for coreml (and coreml-compact with --compact) in every context the
#      model's signed manifest has that build serve: download, assembly, compile, warm-up, the golden stage. A model
#      with no accelerator build for any context (no CoreML files, or a package with no context signed for it) has
#      nothing for the pipeline to do: the step says so in one sentence and passes. The golden stage judges a build by the tolerance
#      its signed manifest gives it, and on identical tokens when it gives none; for each build and context the
#      run prints, per head, what was measured next to the signed bound (token_edits, lp_mean, lp_p99; p_mean for
#      the attribute heads), so a line shows why a build passed or which measure was outside, or it says that the
#      manifest gives the build no tolerance and tokens decided. A build that does not pass is not promoted and
#      the device stays on the CPU engine: that is
#      the pipeline's answer and the step passes. It fails only on a fault of the pipeline (a crash, a stage that
#      does not end, a promotion outside the tolerance). Its line says how many builds ended each way.
#   5  optional, with a clips folder: the conformance clips bit for bit on the CPU engine through the Session
#      API, and the same clips on the Neural Engine against the CPU engine.
#   6  client.diagnose() as JSON.
#   7  the summary: one line per step (PASS, FAIL, SKIPPED), then the golden stage's measures: one record per
#      build and context (token_edits, lp_mean and lp_p99 in nats, p_mean a probability, the model, the device's
#      os_build, device_model and chip), and under them a tolerance made from the records, no margin added: for a
#      build with keep tables one entry per build (the largest value of each measure over its contexts); for a
#      build without keep tables, whose package carries the table inside, one entry per build and context under
#      the key <build>:<context>, since such a build is tried only where that key is signed. The line above the
#      entries says which. That tolerance is a proposal for the model side: the margin and the signing are theirs.
#
# What it sends is what the SDK sends for any app's first launch with that key (docs/platform-client.md): the key
# and an app id for a session token (the app id is ai.quranlab.sdk.prove unless QURANLAB_APP_ID names another;
# the first run makes that app id the one the key belongs to), the daily registration under the name
# "SDK proof (Mac)", the request for the signed config,
# the model's downloads from cdn.quranlab.ai, the SDK's anonymous telemetry (counts per day: launches, takes,
# downloads, promotions; the run sends the day's counts when it ends instead of leaving them for the SDK's next
# interval, so that step 6 can say the server took them) and, if a stage of the Neural Engine's preparation
# fails, the issue report any app sends (stage, cause, device model, OS build and, for a golden stage, what it
# measured). The measures of a golden stage that passes are printed, not sent. It shares no recording (sharing
# is never switched on) and opens
# no microphone: the takes are the model's own sample clips and the files of the clips folder. Its files go to
# its work folder ($TMPDIR/tajweedformer-prove, or QURANLAB_PROVE_DIR); Core ML keeps its own cache of a
# compiled model, as for any app.
#
# Nothing it prints names the key, the install, the app or the account. Exit status: 0 when every step that ran
# passed, 1 when a step failed, 2 when the run could not start (a check of step 0, or the build).
#
# More environment, all optional: QURANLAB_EXPECT_VERSION (a model version the signed config must name; unset, or
# "any", the run takes the version the config names for this key, checks that the downloaded model is that
# version, and prints it: the script names no model version of its own), QURANLAB_EXPECT_BUILD (a build id the
# signed config must name; unset, the run takes the build the config names and prints it: a build id changes with
# every signing),
# QURANLAB_PROVE_CONTEXTS (a part of the contexts, as words separated by spaces) and QURANLAB_PROVE_BUILDS (the
# builds and their order, in place of what --compact chooses).
# --rehearse runs the same script over the test suite's stub server with stand-in
# engines (no key, nothing leaves the Mac): CI uses it to check this script.

set -u

NEED_MACOS=15
NEED_XCODE=16
NEED_SWIFT=6
# what the package's CI builds with: an Xcode from NEED_XCODE up to here is allowed, and is not exercised by CI
CI_XCODE=26
NEED_FREE_GB=6
# the API's health check (it answers 200), and the download server's folder (it answers 401 without a signed link)
API_URL="${QURANLAB_PROVE_PROBE_API:-https://api.quranlab.ai/v1/health}"
CDN_URL="${QURANLAB_PROVE_PROBE_CDN:-https://cdn.quranlab.ai/models/}"

say() { printf '%s\n' "$*"; }

# One sentence: what is missing and how to fix it. Nothing was built, nothing was sent.
stop() {
    say ""
    say "STOP: $*"
    exit 2
}

usage() { sed -n '2,/^$/p' "$0" | sed -e 's/^# \{0,1\}//' -e 's/^#$//'; }

# Nothing shown names the key, a token or a home folder.
scrub() {
    sed -E -e "s#${HOME:-/nonexistent}#~#g" \
        -e 's#qlk_v1_[A-Za-z0-9_-]+#[redacted]#g' \
        -e 's#qlt_v1\.[A-Za-z0-9_.-]+#[redacted]#g' \
        -e 's#/Users/[^/[:space:]"]+#/Users/[redacted]#g'
}

have() { printf '  %-58s %s\n' "$1" "$2"; }

# ---------------------------------------------------------------------------------------------------- arguments

mode=prove
resume=0
compact=0
key="${QURANLAB_KEY:-}"
unset QURANLAB_KEY   # from here on the key is a variable of this shell only
clips=""
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        --check) mode=check ;;
        --rehearse) mode=rehearse ;;
        --resume) resume=1 ;;
        --compact) compact=1 ;;
        --*) stop "An option of this script is not known: run it with --help to see what it takes." ;;
        qlk_*) key="$arg" ;;
        *)
            if [ -d "$arg" ]; then
                clips="$(cd "$arg" && pwd)"
            else
                # never echoed: it may be a key with a typing mistake
                stop "An argument is neither a key (a key starts with qlk_v1_) nor a folder that exists: check it and run the script again."
            fi
            ;;
    esac
done

# the rehearsal downloads a test folder of a few megabytes, not the model
if [ "$mode" = "rehearse" ]; then NEED_FREE_GB=2; fi

here="$(cd "$(dirname "$0")/.." && pwd)" || stop "The script could not find its own checkout."
[ -f "$here/Package.swift" ] || stop "The script must stay in the scripts folder of the TajweedFormer checkout (Package.swift is not next to it)."

tmp="${TMPDIR:-/tmp}"
tmp="${tmp%/}"
if [ -n "${QURANLAB_PROVE_DIR:-}" ]; then
    work="${QURANLAB_PROVE_DIR%/}"
    shown="the folder QURANLAB_PROVE_DIR names"
else
    work="$tmp/tajweedformer-prove"
    shown="\$TMPDIR/tajweedformer-prove"
fi
case "$work" in
    /?*) ;;
    *) stop "QURANLAB_PROVE_DIR must be a full path (it starts with /)." ;;
esac

# ---------------------------------------------------------------------------------------------- step 0: this Mac

say "TajweedFormer for iOS and macOS: the proof on a Mac"
say ""
say "step 0  what the run needs, and what this Mac has"

[ "$(uname -s)" = "Darwin" ] || stop "This script runs on a Mac (macOS $NEED_MACOS or later, Apple silicon)."

macos="$(sw_vers -productVersion 2>/dev/null)"
macos_major="${macos%%.*}"
case "$macos_major" in
    ''|*[!0-9]*) stop "The macOS version could not be read (sw_vers): run the script in Terminal on the Mac itself." ;;
esac
have "macOS $NEED_MACOS or later" "macOS $macos"
[ "$macos_major" -ge "$NEED_MACOS" ] || stop "The Neural Engine's build needs macOS $NEED_MACOS or later and this Mac has $macos: update macOS (System Settings, General, Software Update) and run the script again."

if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != "1" ]; then
    stop "This Mac has an Intel processor: TajweedFormer runs on Apple silicon only, so the proof needs a Mac with an M-series chip."
fi
if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
    stop "This Terminal runs under Rosetta: in Finder, Get Info on Terminal, clear \"Open using Rosetta\", open a new window and run the script again."
fi
have "Apple silicon" "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo arm64)"

xcode="$(xcodebuild -version 2>/dev/null | head -1)"
case "$xcode" in
    Xcode\ [0-9]*) ;;
    *) stop "Xcode is needed (the Command Line Tools alone cannot run the tests): install Xcode $NEED_XCODE or later from the App Store, open it once, run \"sudo xcode-select -s /Applications/Xcode.app\" and then this script again." ;;
esac
xcode_major="${xcode#Xcode }"
xcode_major="${xcode_major%%.*}"
swiftv="$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1)"
[ -n "$swiftv" ] || stop "Swift does not start: open Xcode once and accept its licence (or run \"sudo xcodebuild -license accept\"), then run the script again."
case "$xcode_major" in
    ''|*[!0-9]*) xcode_major=0 ;;
esac
older=""
if [ "$xcode_major" -ge "$NEED_XCODE" ] && [ "$xcode_major" -lt "$CI_XCODE" ]; then
    older=" (the package's CI builds with Xcode $CI_XCODE: if the build fails here, update Xcode)"
fi
have "Xcode $NEED_XCODE or later, Swift $NEED_SWIFT or later" "$xcode, Swift $swiftv$older"
if [ "$xcode_major" -lt "$NEED_XCODE" ] || [ "${swiftv%%.*}" -lt "$NEED_SWIFT" ]; then
    stop "The package needs Xcode $NEED_XCODE or later (Swift $NEED_SWIFT) and this Mac has $xcode with Swift $swiftv: update Xcode from the App Store and run the script again."
fi

mkdir -p "$work" 2>/dev/null || stop "The work folder ($shown) could not be made: set QURANLAB_PROVE_DIR to a folder you can write to and run the script again."
chmod 700 "$work" 2>/dev/null
free_kb="$(df -k "$work" 2>/dev/null | awk 'NR==2 {print $4}')"
case "$free_kb" in
    ''|*[!0-9]*) free_kb=0 ;;
esac
free_gb=$((free_kb / 1048576))
have "$NEED_FREE_GB GB of free disk space" "$free_gb GB free"
[ "$free_gb" -ge "$NEED_FREE_GB" ] || stop "The run needs $NEED_FREE_GB GB of free disk space (the build, the model, the compiled Neural Engine builds) and this disk has $free_gb GB: free some space and run the script again."

# "lowpowermode 1", or "powermode 1" on a Mac that also has a High Power mode
lowpower="$(pmset -g 2>/dev/null | awk '$1 == "lowpowermode" || $1 == "powermode" {print $2}' | head -1)"
batt="$(pmset -g batt 2>/dev/null)"
percent="$(printf '%s\n' "$batt" | grep -Eo '[0-9]+%' | head -1 | tr -d '%')"
if [ "$lowpower" = "1" ]; then
    stop "Low Power Mode is on, and the SDK does not prepare the Neural Engine's build in it: turn it off (System Settings, Battery) and run the script again."
fi
if printf '%s\n' "$batt" | grep -q "'Battery Power'"; then
    if [ -n "$percent" ] && [ "$percent" -lt 20 ]; then
        stop "The battery is at $percent % with no charger connected, and the SDK waits below 20 %: connect the charger and run the script again."
    fi
    have "power: no Low Power Mode, the charger or 20 % of battery" "on battery at ${percent:-?} % (connect the charger if you can: the run is long)"
else
    have "power: no Low Power Mode, the charger or 20 % of battery" "on the charger"
fi

probe() { curl -s -o /dev/null -m 20 -w '%{http_code}' "$1" 2>/dev/null; }
api="$(probe "$API_URL")"
case "$api" in
    ''|000) stop "Quran Lab's API did not answer from this Mac: check the internet connection (and a VPN or firewall, if there is one) and run the script again." ;;
    5??) stop "Quran Lab's API answered its health check with a server error (HTTP $api): that is on Quran Lab's side, not this Mac's, so run the script again in a few minutes." ;;
    200) have "the network: Quran Lab's API answers" "yes" ;;
    *) have "the network: Quran Lab's API" "reachable (its health check answered HTTP $api)" ;;
esac
cdn="$(probe "$CDN_URL")"
case "$cdn" in
    ''|000) stop "Quran Lab's download server (the CDN) did not answer from this Mac: check the internet connection (and a VPN or firewall, if there is one) and run the script again." ;;
    5??) stop "Quran Lab's download server answered with a server error (HTTP $cdn): that is on Quran Lab's side, not this Mac's, so run the script again in a few minutes." ;;
    2??) have "the network: the download server" "reachable" ;;
    *) have "the network: the download server" "reachable (HTTP $cdn, as expected without a signed link)" ;;
esac

# The SDK downloads the Neural Engine's build only on a network that is not metered (not a personal hotspot, not Low
# Data Mode): asked of the system here, before the build. When the question cannot be asked, the run asks it again.
cat > "$work/network.swift" <<'SWIFT'
import Foundation
import Network

final class Kind: @unchecked Sendable { var name = "unknown" }
let kind = Kind()
let answered = DispatchSemaphore(value: 0)
let monitor = NWPathMonitor()
monitor.pathUpdateHandler = { path in
    if path.status != .satisfied {
        kind.name = "none"
    } else if path.isExpensive || path.isConstrained {
        kind.name = "metered"
    } else {
        kind.name = "unmetered"
    }
    answered.signal()
}
monitor.start(queue: DispatchQueue(label: "prove.network"))
_ = answered.wait(timeout: .now() + 5)
print("network:" + kind.name)
SWIFT
network="$(swift "$work/network.swift" 2>/dev/null | sed -n 's/^network://p' | tail -1)"
case "$network" in
    metered) stop "This network is metered (a personal hotspot, or Low Data Mode is on for it), and the SDK does not download the Neural Engine's build over it: join Wi-Fi or Ethernet that is not a hotspot, or turn Low Data Mode off for it, and run the script again." ;;
    none) stop "The system reports no usable network connection: connect to Wi-Fi or Ethernet and run the script again." ;;
    unmetered) have "the network: not metered" "yes" ;;
    *) have "the network: not metered" "not asked here (the run asks before it downloads)" ;;
esac

if [ "$mode" = "check" ]; then
    say ""
    say "This Mac can run the proof. Run the script again with the key: scripts/prove-on-mac.sh <key> [<clips folder>]"
    exit 0
fi

# ------------------------------------------------------------------------------------- the key and the clips folder

if [ "$mode" = "prove" ]; then
    if [ -z "$key" ]; then
        if [ -t 0 ]; then
            printf 'Paste the key (it is not shown) and press Return: '
            IFS= read -r -s key
            printf '\n'
        else
            stop "No key was given: pass it as the first argument or in QURANLAB_KEY (a desktop key from sdk.quranlab.ai)."
        fi
    fi
    case "$key" in
        qlk_v1_?*) ;;
        *) stop "That is not a Quran Lab key (a key starts with qlk_v1_): copy it whole from sdk.quranlab.ai and run the script again." ;;
    esac
fi

expected=""
if [ -n "$clips" ]; then
    count="$(ls "$clips/audio" 2>/dev/null | grep -c '\.pcm$')"
    [ "$count" -gt 0 ] || count="$(ls "$clips" 2>/dev/null | grep -c '\.pcm$')"
    [ "$count" -gt 0 ] || stop "The clips folder holds no .pcm files (audio/<clip>.pcm, 16 kHz mono float32): give the folder the conformance clips were unpacked into, or leave it out."
    for dir in "${QURANLAB_PROVE_EXPECTED:-}" "$clips/conformance" "$clips/expected" "$clips" "$here/engine/conformance"; do
        [ -n "$dir" ] || continue
        if ls "$dir" 2>/dev/null | grep -q '^v4_.*_audio_expected\.jsonl$'; then
            expected="$(cd "$dir" && pwd)"
            break
        fi
    done
    [ -n "$expected" ] || stop "A clips folder was given and the engine's expected rows for it were not found: run \"git submodule update --init engine\" in this checkout (they are in engine/conformance), or leave the clips folder out."
    have "step 5: the clips folder and the engine's expected rows" "$count clips"
elif [ "$mode" = "rehearse" ]; then
    have "step 5: a clips folder (optional)" "the rehearsal makes two clips of its own"
else
    have "step 5: a clips folder (optional)" "none given: step 5 will be skipped"
fi

# ------------------------------------------------------------------------------------------------------ the build

case "$work" in
    ''|/) stop "The work folder is not usable." ;;
esac
rm -f "$work/prove.out" "$work/prove.summary" "$work/prove.status" "$work/test.log"
if [ "$resume" != "1" ]; then rm -rf "$work/storage"; fi

say ""
say "Building the SDK and its tests (a few minutes the first time; the compiler's output goes to $shown/build.log)"
if ! (cd "$here" && swift build --build-tests) > "$work/build.log" 2>&1; then
    grep -E 'error' "$work/build.log" | head -12 | scrub
    if [ "$xcode_major" -lt "$CI_XCODE" ]; then
        stop "The build failed (the lines above; all of it is in $shown/build.log): this Mac has $xcode and the package's CI builds with Xcode $CI_XCODE, so update Xcode from the App Store and run the script again."
    fi
    stop "The build failed (the lines above; all of it is in $shown/build.log): check that the checkout is complete and unchanged, and run the script again."
fi

# -------------------------------------------------------------------------------------------------------- the run

# the builds the run takes through the pipeline: the fp16 one, and with --compact the compact one after it
builds="coreml"
if [ "$compact" = "1" ]; then builds="coreml coreml-compact"; fi
if [ "$mode" = "rehearse" ]; then
    filter="TajweedFormerTests.ProveOnMacTests/testARehearsalAgainstTheStubServer"
    say "The rehearsal: the same run over the test suite's stub server with stand-in engines"
else
    filter="TajweedFormerTests.ProveOnMacTests/testProveOnMac"
    say "The run, with the builds ${QURANLAB_PROVE_BUILDS:-$builds} (the downloads and the Neural Engine's compiles take most of the time; Control-C stops it)"
fi
say ""

testpid=""
tailpid=""
# a process and everything it started
killtree() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do killtree "$child"; done
    kill -TERM "$1" 2>/dev/null
}
interrupted() {
    [ -n "$tailpid" ] && kill "$tailpid" 2>/dev/null
    [ -n "$testpid" ] && killtree "$testpid"
    say ""
    say "Stopped. A run with --resume keeps what was downloaded."
    exit 130
}
trap interrupted INT TERM

# The key lives in this subshell's environment only, which becomes the test process. What that process prints goes to a
# log through the same scrubbing as everything shown, so the key cannot reach a file even in an error message.
(
    cd "$here" || exit 2
    export QURANLAB_PROVE_DIR="$work"
    export QURANLAB_PROVE_CLIPS="$clips"
    export QURANLAB_PROVE_EXPECTED="$expected"
    # no model version is expected unless the caller names one: the signed config says which version this key gets
    export QURANLAB_EXPECT_VERSION="${QURANLAB_EXPECT_VERSION:-any}"
    # no build id is expected unless the caller names one: the signed config says which build this SDK gets
    export QURANLAB_EXPECT_BUILD="${QURANLAB_EXPECT_BUILD:-any}"
    export QURANLAB_PROVE_BUILDS="${QURANLAB_PROVE_BUILDS:-$builds}"
    if [ "$mode" = "rehearse" ]; then
        export QURANLAB_PROVE_REHEARSAL_DIR="$work"
    else
        export QURANLAB_PROVE_KEY="$key"
    fi
    exec swift test --skip-build --filter "$filter"
) > >(scrub > "$work/test.log") 2>&1 &
testpid=$!

# the run's own lines, as it writes them
while [ ! -e "$work/prove.out" ] && kill -0 "$testpid" 2>/dev/null; do sleep 1; done
if [ -e "$work/prove.out" ]; then
    tail -n +1 -f "$work/prove.out" &
    tailpid=$!
fi
wait "$testpid"
teststatus=$?
sleep 2
if [ -n "$tailpid" ]; then
    kill "$tailpid" 2>/dev/null
    wait "$tailpid" 2>/dev/null
fi
trap - INT TERM

if [ ! -s "$work/prove.summary" ]; then
    say ""
    say "The run ended without a summary. The last lines of its log:"
    tail -n 15 "$work/test.log" | scrub
    stop "The run did not finish (its log is $shown/test.log): run the script again with --resume, and send the lines above if it happens twice."
fi
status="$(tr -d '[:space:]' < "$work/prove.status" 2>/dev/null)"
if [ "$mode" = "rehearse" ] && [ "$teststatus" != "0" ]; then
    say ""
    say "The rehearsal's own assertions failed:"
    grep -E 'error:' "$work/test.log" | head -12 | scrub
    status=1
fi

# the summary: the last thing printed, its last lines the ones to paste back
say ""
cat "$work/prove.summary"
[ "$status" = "0" ] && exit 0
exit 1
