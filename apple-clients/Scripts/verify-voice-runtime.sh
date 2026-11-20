#!/usr/bin/env bash
# Checks that AstralVoiceRuntime/Artifacts holds the llama.cpp xcframework built at the revision pinned in build-voice-runtime.sh, with the expected architectures in every slice.
# Apple CI runs it on the artifact the voice-runtime job built and on every download of that artifact before any job builds the app against it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS="${1:-$HERE/../AstralVoiceRuntime/Artifacts}"
PINNED=$(sed -n 's/^REVISION=\([0-9a-f]\{40\}\)$/\1/p' "$HERE/build-voice-runtime.sh")
[ -n "$PINNED" ] || { echo "no pinned revision in build-voice-runtime.sh" >&2; exit 1; }

[ -f "$ARTIFACTS/llama.cpp-revision" ] || { echo "missing $ARTIFACTS/llama.cpp-revision" >&2; exit 1; }
BUILT=$(tr -d '[:space:]' < "$ARTIFACTS/llama.cpp-revision")
[ "$BUILT" = "$PINNED" ] || { echo "runtime built at $BUILT, pinned $PINNED" >&2; exit 1; }
[ -s "$ARTIFACTS/llama.cpp-LICENSE" ] || { echo "missing llama.cpp-LICENSE" >&2; exit 1; }

FRAMEWORK="$ARTIFACTS/LlamaRuntime.xcframework"
EXPECTED=(
  "ios-arm64|libllama-ios.a|arm64"
  "ios-arm64_x86_64-simulator|libllama-ios-simulator.a|arm64 x86_64"
  "macos-arm64_x86_64|libllama-macos.a|arm64 x86_64"
)
for entry in "${EXPECTED[@]}"; do
  IFS='|' read -r slice library archs <<<"$entry"
  file="$FRAMEWORK/$slice/$library"
  [ -f "$file" ] || { echo "missing slice $file" >&2; exit 1; }
  actual=$(lipo -archs "$file" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
  wanted=$(echo "$archs" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
  [ "$actual" = "$wanted" ] || { echo "$slice holds '$actual', expected '$wanted'" >&2; exit 1; }
  [ -d "$FRAMEWORK/$slice/Headers" ] || { echo "missing headers in $slice" >&2; exit 1; }
done
echo "voice runtime verified at llama.cpp $PINNED"
