"""Regenerates the service worker's pinned public offline asset list from packaged
bytes; run after editing an offline resource, with --check used in CI to catch drift.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATIC = ROOT / "backend/webrender/static"
PUBLIC_ASSETS = {
    "offline.html": "text/html",
    "offline.css": "text/css",
    "astral.css": "text/css",
    "fonts/open-sans-latin.woff2": "font/woff2",
    "img/astra-fav.png": "image/png",
    "manifest.webmanifest": "application/manifest+json",
}
# Hash after LF-normalizing: a CRLF checkout must match the Linux server
TEXT_ASSETS = frozenset({"offline.html", "offline.css", "astral.css",
                         "manifest.webmanifest"})
BEGIN = "// BEGIN GENERATED PUBLIC ASSETS"
END = "// END GENERATED PUBLIC ASSETS"


def render_worker() -> str:
    assets = []
    for name, content_type in PUBLIC_ASSETS.items():
        data = (STATIC / name).read_bytes()
        if name in TEXT_ASSETS:
            data = data.replace(b'\r\n', b'\n')
        assets.append({"path": f"/static/{name}", "type": content_type,
                       "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    serialized = json.dumps(assets, indent=2)
    version = hashlib.sha256(serialized.encode()).hexdigest()[:24]
    before, rest = (STATIC / "service-worker.js").read_text(encoding="utf-8").split(BEGIN)
    _, after = rest.split(END)
    return (f'{before}{BEGIN}\nconst CACHE_NAME = CACHE_PREFIX + "{version}";\n'
            f"const PUBLIC_ASSETS = {serialized};\n{END}{after}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    worker = STATIC / "service-worker.js"
    rendered = render_worker()
    if args.check:
        if worker.read_text(encoding="utf-8") != rendered:
            parser.exit(1, "offline asset hashes are stale; run scripts/build_offline_assets.py\n")
    else:
        worker.write_text(rendered, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
