#!/usr/bin/env bash
# Builds the macOS arm64 kernel Python wheel and the astral-mailbox binary from a pinned AstralKernel commit, in a private clone so no kernel checkout is touched.
# Its outputs feed assemble_pack.py. Usage: build_kernel.sh [--out DIR] [--source DIR]; a local source must be clean and match the full commit pin.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/AstralDeep/AstralKernel.git}"
KERNEL_COMMIT="${KERNEL_COMMIT:-$(python3 -I "$HERE/pins.py" kernel-commit)}"
OUT="${HERE}/build/kernel"
WORK="${NODEPACK_WORK:-$HOME/Library/Caches/AstralNodePack}"
DEPLOYMENT_TARGET="14.0"
LOCAL_SOURCE="${NODEPACK_KERNEL_SOURCE:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --source) LOCAL_SOURCE="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export CARGO_TARGET_DIR="$WORK/kernel-target"
SRC="$WORK/kernel-src"
if [ -z "$LOCAL_SOURCE" ] && [ -d "$KERNEL_REPO" ]; then LOCAL_SOURCE="$KERNEL_REPO"; fi
if [ -n "$LOCAL_SOURCE" ]; then
  KERNEL_REPO="$(python3 -I "$HERE/local_sources.py" "$LOCAL_SOURCE" "$KERNEL_COMMIT")"
  LOCAL_SOURCE="$KERNEL_REPO"
  SRC="$WORK/kernel-src-$KERNEL_COMMIT"
elif ! [[ "$KERNEL_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "the kernel pin must be a full lowercase Git commit SHA" >&2
  exit 1
fi

mkdir -p "$WORK" "$OUT"
if [ ! -d "$SRC/.git" ]; then
  git clone --quiet --no-checkout --no-hardlinks "$KERNEL_REPO" "$SRC"
fi
git -C "$SRC" fetch --quiet origin "$KERNEL_COMMIT" 2>/dev/null || git -C "$SRC" fetch --quiet origin
git -C "$SRC" checkout --quiet --force --detach "$KERNEL_COMMIT"
head="$(git -C "$SRC" rev-parse HEAD)"
if [ "$head" != "$KERNEL_COMMIT" ]; then echo "checked out $head, expected $KERNEL_COMMIT" >&2; exit 1; fi

cd "$SRC"
cargo build --release --locked --target aarch64-apple-darwin \
  -p astral-kernel-ffi -p astral-mailbox -p uniffi-bindgen
TARGET="$CARGO_TARGET_DIR/aarch64-apple-darwin/release"

STAGE="$WORK/kernel-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
"$TARGET/uniffi-bindgen" generate --library "$TARGET/libastral_kernel_ffi.dylib" \
  --language python --out-dir "$STAGE"
cp "$TARGET/libastral_kernel_ffi.dylib" "$STAGE/"
install_name_tool -id "@loader_path/libastral_kernel_ffi.dylib" "$STAGE/libastral_kernel_ffi.dylib"

version="$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)"
python3 -I "$HERE/package_kernel_wheel.py" --stage "$STAGE" --out "$OUT" --version "$version" \
  --platform-tag "macosx_14_0_arm64"
cp "$TARGET/astral-mailbox" "$OUT/astral-mailbox-macos-aarch64"
printf '%s\n' "$head" >"$OUT/kernel-commit.txt"
if [ -n "$LOCAL_SOURCE" ]; then
  python3 -I "$HERE/local_sources.py" "$LOCAL_SOURCE" "$KERNEL_COMMIT" >/dev/null
fi
echo "kernel $head built into $OUT"
