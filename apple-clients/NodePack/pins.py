"""Reads pins.json for the shell scripts and for assemble_pack.py so every pinned revision has one source."""

import json
import sys
from pathlib import Path

PINS = Path(__file__).resolve().parent / "pins.json"


def load(path: Path = PINS) -> dict:
    return json.loads(path.read_text())


if __name__ == "__main__":
    pins = load()
    if sys.argv[1:] == ["kernel-commit"]:
        print(pins["kernel"]["commit"])
    else:
        raise SystemExit("usage: pins.py kernel-commit")
