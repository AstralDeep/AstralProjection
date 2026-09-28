#!/usr/bin/env python3
"""Runs diff-cover on one coverage report over the event's exact base..HEAD range and records an
explicit pass, fail or not-applicable decision naming both revisions and the changed paths.
The python, windows-tests and windows-package jobs in .github/workflows/ci.yml call it instead of
bare diff-cover, and tests/test_check_changed_coverage.py pins its outcomes.
"""

from __future__ import annotations

import argparse
from collections.abc import Sequence
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Any

NOT_APPLICABLE_REASON = "no_measurable_changed_lines"
RANGE_NOTATION = ".."
_SHA = re.compile(r"[0-9a-f]{40}")


class CoverageDecisionError(RuntimeError):
    pass


def _git(repo: Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", *args], cwd=repo, capture_output=True, text=True, check=False
    )
    if completed.returncode:
        raise CoverageDecisionError(f"git {args[0]} failed: {completed.stderr.strip()}")
    return completed.stdout


def _base_revision(repo: Path, base_sha: str) -> str:
    if not _SHA.fullmatch(base_sha) or not base_sha.strip("0"):
        raise CoverageDecisionError(f"base revision {base_sha!r} is not a 40-hex commit SHA")
    _git(repo, "cat-file", "-e", f"{base_sha}^{{commit}}")
    return base_sha


def _changed_paths(repo: Path, base_sha: str) -> list[str]:
    # The three diffs diff-cover measures; deleted files have no lines to measure.
    names: set[str] = set()
    for scope in ((f"{base_sha}{RANGE_NOTATION}HEAD",), ("--cached",), ()):
        listed = _git(repo, "diff", "--name-only", "--diff-filter=d", "-z", *scope)
        names.update(name for name in listed.split("\0") if name)
    return sorted(names)


def _diff_cover(
    repo: Path, report: Path, base_sha: str, fail_under: float, raw: Path
) -> tuple[int, dict[str, Any]]:
    raw = raw.resolve()
    if "," in str(raw):
        raise CoverageDecisionError("the diff-cover report path must not contain a comma")
    raw.unlink(missing_ok=True)
    completed = subprocess.run(
        [
            sys.executable,
            "-m",
            "diff_cover.diff_cover_tool",
            str(report.resolve()),
            "--compare-branch",
            base_sha,
            "--diff-range-notation",
            RANGE_NOTATION,
            "--fail-under",
            str(fail_under),
            "--format",
            f"json:{raw}",
        ],
        cwd=repo,
        capture_output=True,
        text=True,
        check=False,
    )
    sys.stdout.write(completed.stdout)
    sys.stderr.write(completed.stderr)
    if completed.returncode not in (0, 1) or not raw.is_file():
        raise CoverageDecisionError(f"diff-cover exited {completed.returncode} without a report")
    return completed.returncode, json.loads(raw.read_text(encoding="utf-8"))


def evaluate(
    repo: Path, report: Path, base_sha: str, fail_under: float, raw: Path
) -> dict[str, Any]:
    if not 0 <= fail_under <= 100:
        raise CoverageDecisionError("fail-under must be between 0 and 100")
    if not report.is_file():
        raise CoverageDecisionError(f"coverage report {report} does not exist")
    base = _base_revision(repo, base_sha)
    candidate = _git(repo, "rev-parse", "HEAD").strip()
    decision: dict[str, Any] = {
        "report": report.as_posix(),
        "base_sha": base,
        "candidate_sha": candidate,
        "range": f"{base}{RANGE_NOTATION}{candidate}",
        "changed_paths": _changed_paths(repo, base),
        "fail_under": fail_under,
    }
    returncode, result = _diff_cover(repo, report, base, fail_under, raw)
    measured = int(result["total_num_lines"])
    uncovered = int(result["total_num_violations"])
    decision.update(
        measured_paths=sorted(result["src_stats"]),
        measured_lines=measured,
        uncovered_lines=uncovered,
        percent_covered=round((measured - uncovered) * 100 / measured, 2) if measured else None,
    )
    if returncode:
        below = measured and decision["percent_covered"] < fail_under
        decision.update(status="fail", reason="below_threshold" if below else "diff_cover_failed")
    elif measured:
        decision.update(status="pass", reason="at_or_above_threshold")
    else:
        decision.update(status="not-applicable", reason=NOT_APPLICABLE_REASON)
    return decision


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--base-sha", required=True)
    parser.add_argument("--fail-under", type=float, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    raw = args.output.with_name(args.output.stem + ".diff-cover.json")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        decision = evaluate(args.repo, args.report, args.base_sha, args.fail_under, raw)
    except CoverageDecisionError as error:
        decision = {
            "report": args.report.as_posix(),
            "base_sha": args.base_sha,
            "fail_under": args.fail_under,
            "status": "error",
            "reason": str(error),
        }
    rendered = json.dumps(decision, indent=2, sort_keys=True)
    args.output.write_text(rendered + "\n", encoding="utf-8")
    print(f"changed-line coverage decision: {decision['status']} ({decision['reason']})")
    print(rendered)
    return 0 if decision["status"] in {"pass", "not-applicable"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
