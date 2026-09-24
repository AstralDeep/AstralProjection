#!/usr/bin/env python3
"""Substitutes ${NAME} placeholders in an Xcode ExportOptions.plist template from
environment variables so no Apple Team ID or provisioning-profile name is committed;
run by the apple-release workflow.
"""

from __future__ import annotations

import os
import pathlib
import string
import sys

PLACEHOLDERS = (
    "APPLE_TEAM_ID",
    "APPLE_PROFILE_IOS",
    "APPLE_PROFILE_MACOS",
    "APPLE_PROFILE_WATCH",
)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: render_export_options.py <template.plist> <output.plist>", file=sys.stderr)
        return 2
    src, dst = pathlib.Path(argv[1]), pathlib.Path(argv[2])
    template = string.Template(src.read_text())

    used = {n for n in PLACEHOLDERS if f"${{{n}}}" in template.template}
    missing = sorted(n for n in used if not os.environ.get(n))
    if missing:
        print(f"error: {src.name} needs these environment values: {', '.join(missing)}",
              file=sys.stderr)
        return 1

    dst.write_text(template.substitute({n: os.environ.get(n, "") for n in PLACEHOLDERS}))
    print(f"rendered {dst} ({len(used)} placeholder(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
