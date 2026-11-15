"""Validates explicit local source checkouts before node-pack builds or committed-tree exports.
The builder still consumes pinned Git objects, so generated or uncommitted files cannot enter a pack.
"""

import re
import subprocess
import sys
from pathlib import Path


def require_full_pin(commit: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("a source pin must be a full lowercase Git commit SHA")


def validate(path: Path, commit: str) -> Path:
    require_full_pin(commit)
    source = path.resolve(strict=True)
    root = subprocess.check_output(["git", "-C", source, "rev-parse", "--show-toplevel"], text=True).strip()
    if Path(root).resolve() != source:
        raise ValueError("the local source must name the checkout root")
    head = subprocess.check_output(["git", "-C", source, "rev-parse", "HEAD"], text=True).strip()
    if head != commit:
        raise ValueError(f"local source is at {head}, expected {commit}")
    state = subprocess.check_output(
        ["git", "-C", source, "status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"], text=True,
    )
    if state:
        raise ValueError("the local source must be a clean checkout, including untracked files and submodules")
    return source


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: local_sources.py SOURCE COMMIT")
    try:
        print(validate(Path(sys.argv[1]), sys.argv[2]))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"local source: {error}") from error


if __name__ == "__main__":
    main()
