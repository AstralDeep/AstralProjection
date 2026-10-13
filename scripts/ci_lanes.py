"""Classifies immutable Git event ranges for native owner CI and validates lane results.
The native workflows use its explicit applicability receipt before running their aggregates.
"""

import argparse
import json
import re
import subprocess
from pathlib import Path


SHARED = (
    "contracts/",
    "backend/rote/",
    "backend/webrender/chrome/",
    "src/",
    "scripts/",
    ".github/",
    "tooling/",
    "tests/ci/",
    "provenance/",
    "backend/webrender/static/vendor/",
    "tests/test_android",
)
SHARED_FILES = {
    "pyproject.toml",
    "uv.lock",
    "global.json",
    ".gitattributes",
    ".specify/memory/constitution.md",
}


def classify(paths):
    shared = any(path.startswith(SHARED) or path in SHARED_FILES for path in paths)
    return {
        "android": shared or any(path.startswith("android-client/") for path in paths),
        "apple": shared or any(path.startswith("apple-clients/") for path in paths),
    }


def event_range(root, base, head):
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise ValueError("head must be an immutable commit SHA")
    subprocess.run(
        ["git", "cat-file", "-e", head + "^{commit}"], cwd=root, check=True, capture_output=True
    )
    if base == "0" * 40 or not base:
        return {
            "base": base,
            "head": head,
            "paths": [],
            "android": True,
            "apple": True,
            "reason": "no predecessor; all lanes required",
        }
    if not re.fullmatch(r"[0-9a-f]{40}", base):
        raise ValueError("base must be an immutable commit SHA")
    subprocess.run(
        ["git", "cat-file", "-e", base + "^{commit}"], cwd=root, check=True, capture_output=True
    )
    result = subprocess.run(
        ["git", "diff", "--no-renames", "--name-only", "-z", base, head, "--"],
        cwd=root,
        check=True,
        capture_output=True,
    )
    paths = sorted(path.decode("utf-8") for path in result.stdout.split(b"\0") if path)
    return {
        "base": base,
        "head": head,
        "paths": paths,
        **classify(paths),
        "reason": "immutable event range",
    }


def validate_lane(applicable, results):
    if applicable not in ("true", "false") or not results:
        raise ValueError("missing or invalid applicability/results")
    expected = "success" if applicable == "true" else "skipped"
    if any(result != expected for result in results):
        raise ValueError(f"lane requires {expected}, received {results}")
    return "passed" if applicable == "true" else "not applicable"


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Record and validate bounded owner CI diagnostics."
    )
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--base", default="")
    parser.add_argument("--head")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--applicable", choices=("true", "false"))
    parser.add_argument("--results", nargs="+")
    args = parser.parse_args(argv)
    if args.applicable is not None:
        print(validate_lane(args.applicable, args.results))
        return
    receipt = event_range(args.root, args.base, args.head)
    payload = json.dumps(receipt, indent=2) + "\n"
    print(payload, end="")
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload, encoding="utf-8")
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as output:
            for lane in ("android", "apple"):
                output.write(f"{lane}={str(receipt[lane]).lower()}\n")


if __name__ == "__main__":
    main()
