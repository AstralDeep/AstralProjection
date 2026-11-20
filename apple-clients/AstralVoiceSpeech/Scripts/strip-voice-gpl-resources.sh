#!/bin/bash
# Deletes FluidAudio's LuxTtsG2pResources bundles, whose eSpeak NG derived data is GPL-3.0-or-later, from a built product directory.
# An Xcode run-script build phase calls it for every target that links AstralVoiceSpeech, and it exits non-zero if any bundle survives.
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    echo "usage: strip-voice-gpl-resources.sh <app bundle or build products directory>" >&2
    exit 2
fi

root="$1"
removed=0
while IFS= read -r -d '' bundle; do
    rm -rf "$bundle"
    echo "removed $bundle"
    removed=$((removed + 1))
done < <(find "$root" -name '*LuxTtsG2pResources*.bundle' -prune -print0)

remaining="$(find "$root" -name '*LuxTtsG2pResources*.bundle' -print)"
if [ -n "$remaining" ]; then
    echo "error: GPL voice resources are still present:" >&2
    echo "$remaining" >&2
    exit 1
fi

echo "strip-voice-gpl-resources: removed $removed bundle(s), none remain"
