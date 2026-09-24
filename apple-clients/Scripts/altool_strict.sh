#!/usr/bin/env bash
# Wraps xcrun altool so an upload failure actually fails the build: altool can print an error and
# still exit 0, so this checks the exit code plus failure/success markers in its output; used by the
# Apple release workflow.
set -uo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <label> <altool args...>" >&2
    exit 2
fi

label="$1"
shift

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

xcrun altool "$@" 2>&1 | tee "$out"
rc="${PIPESTATUS[0]}"

if [ "$rc" -ne 0 ]; then
    echo "::error::${label}: altool exited ${rc}"
    exit 1
fi

if grep -qE '(UPLOAD|VERIFY) FAILED|ERROR: \[altool' "$out"; then
    echo "::error::${label}: altool reported a failure (and exited 0 anyway)"
    detail="$(grep -m1 -oE 'Validation failed \([0-9-]+\) .*' "$out" || true)"
    [ -n "$detail" ] && echo "::error::${label}: ${detail}"
    exit 1
fi

if ! grep -qE '(UPLOAD|VERIFY) SUCCEEDED' "$out"; then
    echo "::error::${label}: altool printed no success line — refusing to treat this as done"
    exit 1
fi

echo "${label}: ok"
