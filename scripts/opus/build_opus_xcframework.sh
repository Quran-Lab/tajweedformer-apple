#!/bin/bash
# Opus.xcframework (module COpus): libopus, pinned release and checksum, as one static library per
# platform: iOS device arm64, iOS Simulator arm64 + x86_64, macOS arm64 + x86_64.
#
#   scripts/opus/build_opus_xcframework.sh      writes build/opus/Opus.xcframework and its zip (OUT=dir elsewhere)
#   OPUS_QEXT=1 ./build_opus_xcframework.sh     also compiles the Opus HD quality extension (default 0; not shipped)
#
# The SDK's `COpus` binary target is this zip, attached to the GitHub release libopus-1.6.1-1; its
# SHA-256 is the SwiftPM checksum in Package.swift. The build is reproducible (no timestamps or
# build paths in the archives, sorted plist and zip): any checkout, any directory, the same zip,
# 7729c0e3e06d86956c2d3dc066a0e3863a84e86ea0fee618cbaf42f6b9cfd48d with Xcode 26.
# shim/ holds copus_shim.c: Swift cannot call the variadic opus_encoder_ctl, so one-argument
# wrappers are compiled into the same archives.
#
# Build choices, each measured in the opus-bench study (README.md, "Sharing"):
# * float build (FIXED_POINT off): better quality per bit and faster on Apple CPUs.
# * NEON intrinsics presumed on arm64. CMAKE_SYSTEM_PROCESSOR is set explicitly: when it is left to
#   CMake, a cross build (iOS, or macOS arm64 from a different host) never sees an ARM CPU and
#   silently drops every NEON kernel, and a native macOS build sees "arm64" (not "aarch64"), which
#   compiles the kernels without presuming NEON, so the plain C versions are the ones called. Both
#   cases are checked below: the archive must define the NEON kernels and the build must presume them.
# * no DNN features (DEEP_PLC, DRED, OSCE all off): they are decoder/network features, add ~1-4 MB of
#   weights, and do not change what the encoder writes at these settings.
set -euo pipefail
VERSION=1.6.1
SHA256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
URL=https://downloads.xiph.org/releases/opus/opus-$VERSION.tar.gz
QEXT=${OPUS_QEXT:-0}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$(cd "$HERE/../.." && pwd)/build/opus}
mkdir -p "$OUT" && OUT=$(cd "$OUT" && pwd)
WORK=$OUT/work
mkdir -p "$WORK"
TAR=$WORK/opus-$VERSION.tar.gz
[ -f "$TAR" ] || curl -sfL -o "$TAR" "$URL"
echo "$SHA256  $TAR" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch for $TAR" >&2; exit 1; }
rm -rf "$WORK/opus-$VERSION" && tar -xzf "$TAR" -C "$WORK"
SRC=$WORK/opus-$VERSION

# reproducible archives: no member timestamps, no build paths in the objects
export ZERO_AR_DATE=1
CFLAGS_COMMON="-fno-common -ffile-prefix-map=$SRC=opus-$VERSION -ffile-prefix-map=$WORK=."
# the same paths as the compiler may see them without macOS's /private prefix (/tmp, /var)
[ "${WORK#/private/}" != "$WORK" ] && CFLAGS_COMMON="$CFLAGS_COMMON -ffile-prefix-map=${SRC#/private}=opus-$VERSION -ffile-prefix-map=${WORK#/private}=."
[ "$QEXT" = 1 ] && CFLAGS_COMMON="$CFLAGS_COMMON -DENABLE_QEXT"

build() { # name sdk system arch deployment
  local name=$1 sdk=$2 system=$3 arch=$4 target=$5
  local B=$WORK/build-$name-$arch flags="$CFLAGS_COMMON" minflag proc=$arch
  [ "$arch" = arm64 ] && proc=aarch64
  case $sdk in iphoneos) minflag=-mios-version-min=;; iphonesimulator) minflag=-mios-simulator-version-min=;; *) minflag=-mmacosx-version-min=;; esac
  cmake -S "$SRC" -B "$B" -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=$system -DCMAKE_SYSTEM_PROCESSOR=$proc \
    -DCMAKE_OSX_ARCHITECTURES=$arch -DCMAKE_OSX_SYSROOT=$sdk -DCMAKE_OSX_DEPLOYMENT_TARGET=$target \
    -DCMAKE_C_COMPILER="$(xcrun -f clang)" "-DCMAKE_C_FLAGS=$flags" \
    -DOPUS_FIXED_POINT=OFF \
    -DOPUS_DRED=OFF -DOPUS_OSCE=OFF -DOPUS_DEEP_PLC=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF \
    -DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF >/dev/null 2>&1
  cmake --build "$B" -j 8 >/dev/null
  # the Swift-callable ctl shim goes into the same archive
  "$(xcrun -f clang)" -c -O2 -arch $arch -isysroot "$(xcrun --sdk $sdk --show-sdk-path)" $minflag$target \
    -I"$SRC/include" -ffile-prefix-map="$HERE"=. -o "$B/copus_shim.o" "$HERE/shim/copus_shim.c"
  libtool -static -o "$B/libopus_all.a" "$B/libopus.a" "$B/copus_shim.o" 2>/dev/null
  # the NEON kernels must be linked in and called, not just compiled
  if [ "$arch" = arm64 ]; then
    grep -q OPUS_ARM_PRESUME_NEON_INTR "$B/CMakeFiles/opus.dir/flags.make" || { echo "NEON not presumed in $name" >&2; exit 1; }
    nm "$B/libopus.a" 2>/dev/null | grep -q ' T _celt_pitch_xcorr_float_neon' || { echo "NEON kernels missing in $name" >&2; exit 1; }
  fi
  echo "$B/libopus_all.a"
}
lipo_to() { mkdir -p "$(dirname "$1")"; shift_out=$1; shift; lipo -create "$@" -output "$shift_out"; }

IOS=$(build ios iphoneos iOS arm64 15.0)
SIM_A=$(build sim iphonesimulator iOS arm64 15.0)
SIM_X=$(build sim iphonesimulator iOS x86_64 15.0)
MAC_A=$(build mac macosx Darwin arm64 12.0)
MAC_X=$(build mac macosx Darwin x86_64 12.0)
mkdir -p "$OUT/ios" && cp "$IOS" "$OUT/ios/libopus.a"
lipo_to "$OUT/sim/libopus.a" "$SIM_A" "$SIM_X"
lipo_to "$OUT/mac/libopus.a" "$MAC_A" "$MAC_X"

H=$OUT/Headers
rm -rf "$H" && mkdir -p "$H"
cp "$SRC"/include/opus.h "$SRC"/include/opus_defines.h "$SRC"/include/opus_types.h "$HERE/shim/copus_shim.h" "$H/"
printf 'module COpus {\n  header "opus.h"\n  header "copus_shim.h"\n  export *\n}\n' > "$H/module.modulemap"
XCF=$OUT/Opus.xcframework
rm -rf "$XCF"
xcodebuild -create-xcframework \
  -library "$OUT/ios/libopus.a" -headers "$H" \
  -library "$OUT/sim/libopus.a" -headers "$H" \
  -library "$OUT/mac/libopus.a" -headers "$H" \
  -output "$XCF" >/dev/null
# xcodebuild lists the libraries in a random order: sort them so the plist (and the zip) are stable
python3 - "$XCF/Info.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]; d = plistlib.load(open(p, "rb"))
d["AvailableLibraries"].sort(key=lambda l: l["LibraryIdentifier"])
plistlib.dump(d, open(p, "wb"), sort_keys=True)
PY
(cd "$OUT" && rm -f Opus.xcframework.zip && export TZ=UTC && find Opus.xcframework -exec touch -h -t 202001010000 {} + \
  && find Opus.xcframework | LC_ALL=C sort | zip -qX -@ Opus.xcframework.zip)
echo "libopus $VERSION (sha256 $SHA256) QEXT=$QEXT"
echo "$XCF ($(du -sh "$XCF" | cut -f1)); zip sha256 $(shasum -a 256 "$OUT/Opus.xcframework.zip" | cut -d' ' -f1)"
