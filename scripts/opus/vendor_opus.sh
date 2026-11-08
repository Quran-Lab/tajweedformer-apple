#!/bin/bash
# Sources/COpus from the pinned libopus release, compiled by SwiftPM as an ordinary C target.
#   scripts/opus/vendor_opus.sh
# scripts/opus/sources.txt lists the C files of a float build without the DNN features (DEEP_PLC, DRED and OSCE are
# decoder and network features that add megabytes of weights and do not change what the encoder writes at these
# settings). Sources/COpus/config.h, copus_shim.c and include/COpus/{COpus,copus_shim}.h are ours and stay.
set -euo pipefail
VERSION=1.6.1
SHA256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
URL=https://downloads.xiph.org/releases/opus/opus-$VERSION.tar.gz
HERE=$(cd "$(dirname "$0")" && pwd)
D=$(cd "$HERE/../.." && pwd)/Sources/COpus
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
curl -sfL -o "$T/o.tar.gz" "$URL"
echo "$SHA256  $T/o.tar.gz" | shasum -a 256 -c - >/dev/null
tar -xzf "$T/o.tar.gz" -C "$T"
S=$T/opus-$VERSION
rm -rf "$D/celt" "$D/silk" "$D/src"
mkdir -p "$D/include/COpus"
cp "$S/COPYING" "$D/"
cp "$S"/include/*.h "$D/include/COpus/"
while read -r f; do mkdir -p "$D/$(dirname "$f")"; cp "$S/$f" "$D/$f"; done < "$HERE/sources.txt"
(cd "$S" && find celt silk src -name '*.h' -not -path '*/x86/*' -not -path '*/mips/*' -not -path '*/tests/*') |
  while read -r f; do mkdir -p "$D/$(dirname "$f")"; cp "$S/$f" "$D/$f"; done
# SwiftPM cannot select files by architecture: the NEON files compile to nothing elsewhere.
grep '/arm/' "$HERE/sources.txt" | while read -r f; do
  { echo '#if defined(__aarch64__)'; cat "$D/$f"; echo '#endif'; } > "$D/$f.new" && mv "$D/$f.new" "$D/$f"
done
