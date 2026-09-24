#!/usr/bin/env python3
"""Regenerates windows-client/assets/astraldeep.ico from the shared brand master
(android-client's AppIcon.png) via PySide6 scaling; run after editing the brand mark,
and CI runs it with --check.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import struct
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QBuffer, QIODevice, QSize, Qt  # noqa: E402
from PySide6.QtGui import QGuiApplication, QIcon, QImage  # noqa: E402

REPO = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_MASTER = REPO / "android-client" / "Android Raw Assets" / "AppIcon.png"
ICO_PATH = REPO / "windows-client" / "assets" / "astraldeep.ico"

SIZES = (16, 24, 32, 48, 64, 128, 256)

BRAND_BG = (0x17, 0x19, 0x40)
BG_TOLERANCE = 24


def _app() -> QGuiApplication:
    return QGuiApplication.instance() or QGuiApplication([])


def _png_bytes(img: QImage, size: int) -> bytes:
    frame = img.scaled(
        QSize(size, size),
        Qt.AspectRatioMode.IgnoreAspectRatio,
        Qt.TransformationMode.SmoothTransformation,
    )
    # No-arg only — a bound temp QByteArray gets freed under Qt
    buf = QBuffer()
    buf.open(QIODevice.OpenModeFlag.WriteOnly)
    if not frame.save(buf, "PNG"):
        raise RuntimeError(f"PNG encode failed for the {size}px frame")
    buf.close()
    return bytes(buf.data())


def build_ico(master: pathlib.Path, sizes=SIZES) -> bytes:
    _app()
    img = QImage(str(master))
    if img.isNull():
        raise ValueError(f"could not decode master: {master}")
    if img.width() != img.height():
        raise ValueError(f"master must be square, got {img.width()}x{img.height()}")

    frames = [(s, _png_bytes(img, s)) for s in sizes]
    header = struct.pack("<HHH", 0, 1, len(frames))
    offset = len(header) + 16 * len(frames)
    entries, blobs = b"", b""
    for size, png in frames:
        dim = 0 if size >= 256 else size
        entries += struct.pack(
            "<BBBBHHII", dim, dim, 0, 0, 1, 32, len(png), offset
        )
        blobs += png
        offset += len(png)
    return header + entries + blobs


def _frames(path: pathlib.Path) -> list[tuple[int, bytes]]:
    data = path.read_bytes()
    reserved, kind, count = struct.unpack("<HHH", data[:6])
    if reserved != 0 or kind != 1:
        raise ValueError(f"{path}: not an ICO (reserved={reserved} type={kind})")
    out = []
    for i in range(count):
        w, _h, _c, _r, _p, _bpp, nbytes, off = struct.unpack(
            "<BBBBHHII", data[6 + 16 * i:22 + 16 * i]
        )
        out.append((w or 256, data[off:off + nbytes]))
    return out


def check(path: pathlib.Path = ICO_PATH) -> int:
    problems: list[str] = []
    if not path.exists():
        print(f"  FAIL missing {path}", file=sys.stderr)
        return 1

    declared = _frames(path)
    got = sorted(s for s, _ in declared)
    if got != sorted(SIZES):
        problems.append(f"frames {got} != {sorted(SIZES)}")
    for size, blob in declared:
        if blob[:8] != b"\x89PNG\r\n\x1a\n":
            problems.append(f"{size}px frame is not PNG-compressed")

    _app()
    icon = QIcon(str(path))
    avail = {(s.width(), s.height()) for s in icon.availableSizes()}
    for size in SIZES:
        if (size, size) not in avail:
            problems.append(f"Qt cannot load the {size}px frame")

    big = icon.pixmap(256, 256).toImage()
    px = big.pixelColor(0, 0)
    if px.alpha() != 255:
        problems.append(f"256px background is transparent (alpha={px.alpha()})")
    delta = max(abs(c - b) for c, b in zip((px.red(), px.green(), px.blue()), BRAND_BG))
    if delta > BG_TOLERANCE:
        problems.append(
            f"256px background rgb({px.red()},{px.green()},{px.blue()}) is not the "
            f"brand navy rgb{BRAND_BG} — is this generated from the master?"
        )

    for msg in problems:
        print(f"  FAIL {msg}", file=sys.stderr)
    if problems:
        return 1
    print(f"  OK: {path.name} — frames {got}, PNG-compressed, brand-navy field")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--master", type=pathlib.Path, default=DEFAULT_MASTER)
    ap.add_argument("--out", type=pathlib.Path, default=ICO_PATH)
    ap.add_argument("--check", action="store_true",
                    help="verify the committed icon, don't regenerate")
    args = ap.parse_args()
    if args.check:
        return check(args.out)
    if not args.master.exists():
        print(f"master not found: {args.master}", file=sys.stderr)
        return 2
    print(f"master: {args.master}")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(build_ico(args.master))
    print(f"  wrote {args.out} ({args.out.stat().st_size:,} bytes, frames {list(SIZES)})")
    return check(args.out)


if __name__ == "__main__":
    raise SystemExit(main())
