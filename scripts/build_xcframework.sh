#!/bin/bash
# TajweedFormerCore.xcframework from the pinned engine (engine/, the tajweedformer-sdk submodule; ZF_ENGINE_DIR
# overrides it): the exact engine, its ONNX-Runtime-free graph runner, the stream API and the V4 tajweed
# library, inference only (zf_tajweed.h, target zf_tajweed_inference), and the CoreML sidecar rebuild (zf/zfs.h,
# zf/vfs.h) as one static library per platform,
# with the C headers and a module map, for the Swift package (Package.swift).
#   iOS device arm64, iOS Simulator arm64, macOS arm64
# Built with ZF_RELEASE=ON: the exact configuration is fixed at compile time and the ZF_* environment
# switches are ignored, so no setting in the host app can move a bit.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ENG=${ZF_ENGINE_DIR:-$ROOT/engine}
OUT=$ROOT/build/xcf
ORT_INC=$ENG/third_party/onnxruntime/include
if [ ! -f "$ORT_INC/onnxruntime_c_api.h" ]; then
  mkdir -p "$ORT_INC"
  for h in onnxruntime_c_api.h onnxruntime_error_code.h onnxruntime_ep_c_api.h onnxruntime_float16.h; do
    curl -sfL -o "$ORT_INC/$h" "https://raw.githubusercontent.com/microsoft/onnxruntime/v1.28.2/include/onnxruntime/core/session/$h"
  done
fi
rm -rf "$OUT" && mkdir -p "$OUT"
CC=$(xcrun -f clang)
build() { # name sdk system deployment
  local name=$1 sdk=$2 system=$3 target=$4
  local B=$OUT/build-$name
  cmake -S "$ENG" -B "$B" -DCMAKE_BUILD_TYPE=Release -DZF_RELEASE=ON -DCMAKE_SYSTEM_NAME=$system \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=$sdk -DCMAKE_OSX_DEPLOYMENT_TARGET=$target \
    -DCMAKE_C_FLAGS=-DZF_QUANT_DIVIDE=1 -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$(xcrun -f clang++) \
    -DCMAKE_ASM_COMPILER=$CC >/dev/null
  cmake --build "$B" --target zf_engine zf_ort_ops zf_rt zf_stream zf_tajweed_inference -j 8 >/dev/null
  mkdir -p "$OUT/$name"
  libtool -static -o "$OUT/$name/libTajweedFormerCore.a" "$B/engine/libzf_engine.a" \
    "$B/accel/libzf_ort_ops.a" "$B/accel/libzf_rt.a" "$B/accel/libzf_stream.a" "$B/tajweed/libzf_tajweed_inference.a" 2>/dev/null
}
build ios iphoneos iOS 15.0
build sim iphonesimulator iOS 15.0
build mac macosx Darwin 12.0
H=$OUT/Headers
rm -rf "$H" && mkdir -p "$H/zf" "$H/TajweedFormerCore"
cp "$ENG"/accel/include/zf/stream.h "$ENG"/engine/include/zf/decode.h "$ENG"/engine/include/zf/fbank.h \
  "$ENG"/engine/include/zf/resample.h "$ENG"/engine/include/zf/zfs.h "$ENG"/engine/include/zf/vfs.h "$H/zf/"
cp "$ENG"/tajweed/include/zf_tajweed.h "$H/"
printf '#include "zf/stream.h"\n#include "zf/fbank.h"\n#include "zf/resample.h"\n#include "zf/zfs.h"\n#include "zf/vfs.h"\n#include "zf_tajweed.h"\n' > "$H/TajweedFormerCore.h"
# the module map in its own folder: Xcode copies every static xcframework's headers into one
# include/ directory, where a second top-level module.modulemap (COpus's) would collide
printf 'module TajweedFormerCore {\n  header "../TajweedFormerCore.h"\n  export *\n}\n' > "$H/TajweedFormerCore/module.modulemap"
rm -rf "$ROOT/TajweedFormerCore.xcframework"
xcodebuild -create-xcframework \
  -library "$OUT/ios/libTajweedFormerCore.a" -headers "$H" \
  -library "$OUT/sim/libTajweedFormerCore.a" -headers "$H" \
  -library "$OUT/mac/libTajweedFormerCore.a" -headers "$H" \
  -output "$ROOT/TajweedFormerCore.xcframework" >/dev/null
# the engine core's privacy manifest next to each slice's library (the package's own is a resource of its target)
for s in "$ROOT"/TajweedFormerCore.xcframework/*/; do
  [ -f "$s/libTajweedFormerCore.a" ] && cp "$ROOT/scripts/xcframework/PrivacyInfo.xcprivacy" "$s/PrivacyInfo.xcprivacy"
done
(cd "$ROOT" && rm -f TajweedFormerCore.xcframework.zip && zip -qry TajweedFormerCore.xcframework.zip TajweedFormerCore.xcframework)
echo "$ROOT/TajweedFormerCore.xcframework ($(du -sh "$ROOT/TajweedFormerCore.xcframework" | cut -f1)); zip checksum $(swift package compute-checksum "$ROOT/TajweedFormerCore.xcframework.zip")"
