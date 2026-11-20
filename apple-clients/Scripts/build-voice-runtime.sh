#!/usr/bin/env bash
# Builds the pinned llama.cpp with libmtmd for iPhone, iPhone simulator and Mac, then assembles AstralVoiceRuntime/Artifacts/LlamaRuntime.xcframework.
# The Mac and iPhone simulator slices are universal (arm64 and x86_64) because the app's Release build links both architectures; --arm64-only builds just arm64 of every slice for quick local package tests.
# Usage: Scripts/build-voice-runtime.sh [--jobs N] [--slices ios,ios-simulator,macos] [--arm64-only]; reruns reuse the cached source and per-arch builds, and a checkout at any other revision stops the script.
set -euo pipefail

REVISION=8af68d486a9473820d24d00af8f33334ca80124d
IOS_TARGET=17.0
MACOS_TARGET=14.0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE="$HERE/../AstralVoiceRuntime"
ARTIFACTS="$PACKAGE/Artifacts"
WORK="$ARTIFACTS/work"
SOURCE="$WORK/llama.cpp"
JOBS=$(sysctl -n hw.ncpu)
WANTED=ios,ios-simulator,macos
ARM64_ONLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs) [ "$#" -ge 2 ] || { echo "missing --jobs value" >&2; exit 64; }; JOBS=$2; shift 2 ;;
    --slices) [ "$#" -ge 2 ] || { echo "missing --slices value" >&2; exit 64; }; WANTED=$2; shift 2 ;;
    --arm64-only) ARM64_ONLY=1; shift ;;
    --help) echo "Scripts/build-voice-runtime.sh [--jobs N] [--slices ios,ios-simulator,macos] [--arm64-only]"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

for tool in git cmake ninja xcodebuild xcrun libtool lipo; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 69; }
done

mkdir -p "$WORK"
if [ ! -d "$SOURCE/.git" ]; then
  git init -q "$SOURCE"
fi
if [ "$(git -C "$SOURCE" rev-parse --verify -q HEAD 2>/dev/null || true)" != "$REVISION" ]; then
  git -C "$SOURCE" fetch -q --depth=1 https://github.com/ggml-org/llama.cpp.git "$REVISION"
  git -C "$SOURCE" checkout -q --force FETCH_HEAD
fi
ACTUAL=$(git -C "$SOURCE" rev-parse HEAD)
if [ "$ACTUAL" != "$REVISION" ]; then
  echo "llama.cpp is at $ACTUAL, expected $REVISION" >&2
  exit 1
fi
if [ -n "$(git -C "$SOURCE" status --porcelain)" ]; then
  echo "llama.cpp checkout has local changes; remove $SOURCE and rerun" >&2
  exit 1
fi

KNOWN=(
  "ios|iphoneos|$IOS_TARGET|ON|arm64"
  "ios-simulator|iphonesimulator|$IOS_TARGET|OFF|arm64 x86_64"
  "macos|macosx|$MACOS_TARGET|ON|arm64 x86_64"
)
SLICES=()
IFS=',' read -r -a requested <<<"$WANTED"
[ "${#requested[@]}" -gt 0 ] || { echo "no slices requested" >&2; exit 64; }
for name in "${requested[@]}"; do
  match=""
  for entry in "${KNOWN[@]}"; do
    [ "${entry%%|*}" = "$name" ] && match=$entry
  done
  [ -n "$match" ] || { echo "unknown slice: $name" >&2; exit 64; }
  SLICES+=("$match")
done

build_arch() {
  local name=$1 sysroot=$2 target=$3 metal=$4 arch=$5
  local build="$WORK/build-$name-$arch"
  local system=()
  if [ "$sysroot" != macosx ]; then system=(-DCMAKE_SYSTEM_NAME=iOS); fi
  local metal_target=()
  if [ "$sysroot" = iphoneos ]; then metal_target=(-DGGML_METAL_TARGET_OS=ios); fi
  local cpu=()
  if [ "$arch" = arm64 ]; then cpu=(-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod); fi
  cmake -S "$SOURCE" -B "$build" -G Ninja ${system[@]+"${system[@]}"} ${metal_target[@]+"${metal_target[@]}"} \
    -DCMAKE_OSX_SYSROOT="$sysroot" -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$target" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF -DGGML_METAL="$metal" -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF ${cpu[@]+"${cpu[@]}"} \
    -DGGML_BLAS=OFF -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF \
    -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_MTMD=ON -DLLAMA_BUILD_APP=OFF \
    -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF
  cmake --build "$build" --target mtmd -j "$JOBS"
  find "$build" -name '*.a' -print | sort > "$build/archives.txt"
  libtool -static -o "$WORK/libllama-$name-$arch.a" -filelist "$build/archives.txt"
}

build_slice() {
  local name=$1 sysroot=$2 target=$3 metal=$4 archs=$5
  local built=()
  for arch in $archs; do
    if [ "$ARM64_ONLY" = 1 ] && [ "$arch" != arm64 ]; then continue; fi
    echo "== building $name $arch"
    build_arch "$name" "$sysroot" "$target" "$metal" "$arch"
    built+=("$WORK/libllama-$name-$arch.a")
  done
  lipo -create "${built[@]}" -output "$WORK/libllama-$name.a"
}

for entry in "${SLICES[@]}"; do
  IFS='|' read -r name sysroot target metal archs <<<"$entry"
  build_slice "$name" "$sysroot" "$target" "$metal" "$archs"
done

HEADERS="$WORK/Headers"
rm -rf "$HEADERS"
mkdir -p "$HEADERS"
cp "$SOURCE/include/llama.h" "$SOURCE/tools/mtmd/mtmd.h" "$SOURCE/tools/mtmd/mtmd-helper.h" "$SOURCE"/ggml/include/*.h "$HEADERS/"
cp "$SOURCE/LICENSE" "$ARTIFACTS/llama.cpp-LICENSE"

OUT="$ARTIFACTS/LlamaRuntime.xcframework"
rm -rf "$OUT"
args=()
for entry in "${SLICES[@]}"; do
  IFS='|' read -r name _ <<<"$entry"
  args+=(-library "$WORK/libllama-$name.a" -headers "$HEADERS")
done
xcodebuild -create-xcframework "${args[@]}" -output "$OUT"
printf '%s\n' "$REVISION" > "$ARTIFACTS/llama.cpp-revision"
echo "wrote $OUT at llama.cpp $REVISION"
