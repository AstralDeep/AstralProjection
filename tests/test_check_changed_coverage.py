"""Tests for scripts/check_changed_coverage.py against real diff-cover runs in throwaway git
repositories: not-applicable, pass and fail decisions over the exact base..HEAD range, and
fail-closed refusals of malformed or absent bases, missing reports and out-of-range thresholds.
"""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys

import pytest

from scripts import check_changed_coverage as checker

MODULE = "pkg/mod.py"


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=repo, check=True, capture_output=True, text=True
    ).stdout.strip()


def _repo(tmp_path: Path) -> tuple[Path, str]:
    repo = tmp_path / "repo"
    (repo / "pkg").mkdir(parents=True)
    (repo / MODULE).write_text("value = 1\n", encoding="utf-8")
    (repo / "README.md").write_text("# Fixture\n", encoding="utf-8")
    _git(repo, "init", "-q", "-b", "main")
    _git(repo, "config", "user.email", "fixture@example.invalid")
    _git(repo, "config", "user.name", "Fixture")
    _git(repo, "config", "commit.gpgsign", "false")
    _git(repo, "add", ".")
    _git(repo, "commit", "-q", "-m", "base")
    return repo, _git(repo, "rev-parse", "HEAD")


def _commit(repo: Path, path: str, text: str) -> str:
    (repo / path).write_text(text, encoding="utf-8")
    _git(repo, "add", path)
    _git(repo, "commit", "-q", "-m", f"change {path}")
    return _git(repo, "rev-parse", "HEAD")


def _report(repo: Path, hits: dict[int, int]) -> Path:
    lines = "".join(f'<line number="{line}" hits="{count}"/>' for line, count in hits.items())
    report = repo.parent / "coverage.xml"
    report.write_text(
        '<?xml version="1.0" ?><coverage version="7.15.2">'
        f"<sources><source>{repo}</source></sources><packages><package name=\"pkg\">"
        f'<classes><class name="mod.py" filename="{MODULE}"><methods/>'
        f"<lines>{lines}</lines></class></classes></package></packages></coverage>",
        encoding="utf-8",
    )
    return report


def _run(repo: Path, report: Path, base: str, threshold: str = "90") -> tuple[int, dict]:
    output = repo.parent / "decision.json"
    code = checker.main(
        [
            str(report),
            "--base-sha",
            base,
            "--fail-under",
            threshold,
            "--output",
            str(output),
            "--repo",
            str(repo),
        ]
    )
    return code, json.loads(output.read_text(encoding="utf-8"))


def test_documentation_only_change_is_recorded_not_applicable(tmp_path, capsys):
    repo, base = _repo(tmp_path)
    candidate = _commit(repo, "README.md", "# Fixture\n\nMore prose.\n")

    code, decision = _run(repo, _report(repo, {1: 1}), base)

    assert code == 0
    assert decision["status"] == "not-applicable"
    assert decision["reason"] == checker.NOT_APPLICABLE_REASON
    assert decision["base_sha"] == base
    assert decision["candidate_sha"] == candidate
    assert decision["range"] == f"{base}..{candidate}"
    assert decision["changed_paths"] == ["README.md"]
    assert decision["measured_paths"] == []
    assert decision["measured_lines"] == 0
    assert decision["percent_covered"] is None
    assert decision["fail_under"] == 90
    assert "changed-line coverage decision: not-applicable" in capsys.readouterr().out
    assert (repo.parent / "decision.diff-cover.json").is_file()


def test_change_with_no_executable_lines_is_not_applicable(tmp_path):
    repo, base = _repo(tmp_path)
    _commit(repo, MODULE, "# why this constant exists\nvalue = 1\n")

    code, decision = _run(repo, _report(repo, {2: 1}), base)

    assert code == 0
    assert decision["status"] == "not-applicable"
    assert decision["changed_paths"] == [MODULE]
    assert decision["measured_lines"] == 0


def test_covered_changed_lines_pass(tmp_path):
    repo, base = _repo(tmp_path)
    _commit(repo, MODULE, "value = 1\nother = 2\n")

    code, decision = _run(repo, _report(repo, {1: 1, 2: 1}), base)

    assert code == 0
    assert decision["status"] == "pass"
    assert decision["measured_paths"] == [MODULE]
    assert decision["measured_lines"] == 1
    assert decision["uncovered_lines"] == 0
    assert decision["percent_covered"] == 100


def test_uncovered_changed_lines_below_the_threshold_fail(tmp_path):
    repo, base = _repo(tmp_path)
    _commit(repo, MODULE, "value = 1\nother = 2\nthird = 3\n")

    code, decision = _run(repo, _report(repo, {1: 1, 2: 1, 3: 0}), base)

    assert code == 1
    assert decision["status"] == "fail"
    assert decision["reason"] == "below_threshold"
    assert decision["measured_lines"] == 2
    assert decision["uncovered_lines"] == 1
    assert decision["percent_covered"] == 50


def test_only_the_pushed_range_after_the_base_is_gated(tmp_path):
    repo, root = _repo(tmp_path)
    earlier = _commit(repo, MODULE, "value = 1\nother = 2\n")
    _commit(repo, "README.md", "# Fixture\n\nPushed prose.\n")
    report = _report(repo, {1: 1, 2: 0})

    whole_code, whole = _run(repo, report, root)
    pushed_code, pushed = _run(repo, report, earlier)

    assert (whole_code, whole["status"]) == (1, "fail")
    assert (pushed_code, pushed["status"]) == (0, "not-applicable")
    assert pushed["changed_paths"] == ["README.md"]


def test_uncommitted_changes_are_part_of_the_considered_paths(tmp_path):
    repo, base = _repo(tmp_path)
    (repo / "README.md").write_text("# Fixture\n\nStaged prose.\n", encoding="utf-8")
    _git(repo, "add", "README.md")
    (repo / "notes.txt").write_text("untracked\n", encoding="utf-8")

    code, decision = _run(repo, _report(repo, {1: 1}), base)

    assert code == 0
    assert decision["base_sha"] == decision["candidate_sha"] == base
    assert decision["changed_paths"] == ["README.md"]


def test_diff_cover_compares_the_exact_base_with_two_dot_notation(tmp_path, monkeypatch):
    repo, base = _repo(tmp_path)
    real_run = subprocess.run
    calls = []

    def record(args, **kwargs):
        if args[0] == "git":
            return real_run(args, **kwargs)
        calls.append(args)
        raw = Path(args[args.index("--format") + 1].split(":", 1)[1])
        raw.write_text(
            '{"src_stats": {}, "total_num_lines": 0, "total_num_violations": 0}',
            encoding="utf-8",
        )
        return subprocess.CompletedProcess(args, 0, "", "")

    monkeypatch.setattr(checker.subprocess, "run", record)

    code, _ = _run(repo, _report(repo, {1: 1}), base)

    assert code == 0
    (argv,) = calls
    assert argv[argv.index("--compare-branch") + 1] == base
    assert argv[argv.index("--diff-range-notation") + 1] == ".."


@pytest.mark.parametrize(
    "base",
    ["", "0" * 40, "abc123", "A" * 40, "g" * 40, "1" * 41],
)
def test_malformed_or_zero_base_revisions_fail_closed(tmp_path, base):
    repo, _ = _repo(tmp_path)

    code, decision = _run(repo, _report(repo, {1: 1}), base)

    assert code == 1
    assert decision["status"] == "error"
    assert "40-hex commit SHA" in decision["reason"]


def test_base_revision_missing_from_history_fails_closed(tmp_path):
    repo, _ = _repo(tmp_path)

    code, decision = _run(repo, _report(repo, {1: 1}), "1" * 40)

    assert code == 1
    assert decision["status"] == "error"
    assert "cat-file" in decision["reason"]


def test_missing_report_fails_closed(tmp_path):
    repo, base = _repo(tmp_path)

    code, decision = _run(repo, repo.parent / "absent.xml", base)

    assert code == 1
    assert decision["status"] == "error"
    assert "does not exist" in decision["reason"]


@pytest.mark.parametrize("threshold", ["-1", "101"])
def test_threshold_outside_zero_to_one_hundred_is_refused(tmp_path, threshold):
    repo, base = _repo(tmp_path)

    code, decision = _run(repo, _report(repo, {1: 1}), base, threshold)

    assert code == 1
    assert decision["status"] == "error"


def test_diff_cover_without_a_report_fails_closed(tmp_path, monkeypatch):
    repo, base = _repo(tmp_path)
    real_run = subprocess.run

    def refuse_diff_cover(args, **kwargs):
        if args[0] == "git":
            return real_run(args, **kwargs)
        return subprocess.CompletedProcess(args, 2, "", "boom")

    monkeypatch.setattr(checker.subprocess, "run", refuse_diff_cover)

    code, decision = _run(repo, _report(repo, {1: 1}), base)

    assert code == 1
    assert decision["status"] == "error"
    assert "without a report" in decision["reason"]


def test_report_path_with_a_comma_is_refused(tmp_path):
    repo, base = _repo(tmp_path)

    with pytest.raises(checker.CoverageDecisionError, match="comma"):
        checker.evaluate(repo, _report(repo, {1: 1}), base, 90, tmp_path / "a,b.json")


def test_command_line_entry_point_writes_the_decision(tmp_path):
    repo, base = _repo(tmp_path)
    _commit(repo, "README.md", "# Fixture\n\nCommand line.\n")
    output = tmp_path / "cli" / "decision.json"

    completed = subprocess.run(
        [
            sys.executable,
            str(Path(checker.__file__).resolve()),
            str(_report(repo, {1: 1})),
            "--base-sha",
            base,
            "--fail-under=90",
            "--output",
            str(output),
        ],
        cwd=repo,
        capture_output=True,
        text=True,
        check=False,
    )

    assert completed.returncode == 0, completed.stderr
    assert json.loads(output.read_text(encoding="utf-8"))["status"] == "not-applicable"
