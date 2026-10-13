"""Exercises native applicability and fail-closed aggregates on immutable Git ranges.
The corpus preserves affected fixtures, deleted paths, and explicit nonapplicability.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

import pytest

from scripts.ci_lanes import classify, event_range, main, validate_lane


@pytest.mark.parametrize(
    "path,expected",
    [
        ("android-client/app/src/Main.kt", {"android": True, "apple": False}),
        ("apple-clients/AstralCore/Core.swift", {"android": False, "apple": True}),
        ("windows-client/client.py", {"android": False, "apple": False}),
        ("README.md", {"android": False, "apple": False}),
        ("backend/webrender/markdown.py", {"android": False, "apple": False}),
    ],
)
def test_independent_surface_applicability(path, expected):
    assert classify([path]) == expected


@pytest.mark.parametrize(
    "path",
    [
        "contracts/ui_protocol.json",
        "contracts/fixtures/voice_075/client_local_conformance.json",
        "contracts/assets/font.woff",
        "backend/rote/adapter.py",
        "src/astralprojection/__init__.py",
        "scripts/export_xccov_line_coverage.py",
        ".github/workflows/ci.yml",
        "tooling/python-ci/requirements.lock.txt",
        "tests/ci/test_workflows.py",
        "tests/test_android_coverage.py",
        "pyproject.toml",
        "uv.lock",
        "backend/webrender/static/vendor/plotly.min.js",
        "provenance/transformations.json",
        "backend/webrender/chrome/menu_model.py",
        "backend/webrender/chrome/console_model.py",
    ],
)
def test_shared_contract_and_gate_changes_require_both_native_lanes(path):
    assert classify([path]) == {"android": True, "apple": True}


@pytest.mark.parametrize(
    "applicable,results",
    [
        ("true", ["success", "failure"]),
        ("true", ["skipped"]),
        ("true", ["cancelled"]),
        ("true", ["timed_out"]),
        ("false", ["success"]),
        ("false", ["failure"]),
        ("", ["skipped"]),
        ("true", []),
        ("unknown", ["success"]),
    ],
)
def test_missing_failed_or_unexpected_results_never_authorize(applicable, results):
    with pytest.raises(ValueError):
        validate_lane(applicable, results)


def test_passed_and_nonapplicable_lanes_have_distinct_receipts():
    assert validate_lane("true", ["success", "success"]) == "passed"
    assert validate_lane("false", ["skipped", "skipped"]) == "not applicable"


def git(root, *args):
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()


def test_deleted_paths_and_cli_bind_to_exact_event_commits(tmp_path):
    git(tmp_path, "init", "-q")
    git(tmp_path, "config", "user.email", "synthetic@example.invalid")
    git(tmp_path, "config", "user.name", "Synthetic")
    path = tmp_path / "apple-clients" / "deleted.swift"
    path.parent.mkdir()
    path.write_text("old")
    git(tmp_path, "add", ".")
    git(tmp_path, "commit", "-qm", "baseline")
    base = git(tmp_path, "rev-parse", "HEAD")
    path.unlink()
    git(tmp_path, "add", "-u")
    git(tmp_path, "commit", "-qm", "candidate")
    head = git(tmp_path, "rev-parse", "HEAD")
    output = tmp_path / "nested" / "receipt.json"
    github_output = tmp_path / "github-output"
    script = Path(__file__).resolve().parents[2] / "scripts" / "ci_lanes.py"
    subprocess.run(
        [
            sys.executable,
            str(script),
            "--root",
            str(tmp_path),
            "--base",
            base,
            "--head",
            head,
            "--output",
            str(output),
            "--github-output",
            str(github_output),
        ],
        check=True,
    )
    main(
        [
            "--root",
            str(tmp_path),
            "--base",
            base,
            "--head",
            head,
            "--output",
            str(output),
            "--github-output",
            str(github_output),
        ]
    )
    main(["--root", str(tmp_path), "--base", base, "--head", head])
    main(["--applicable", "false", "--results", "skipped"])
    receipt = json.loads(output.read_text())
    assert receipt == {
        "base": base,
        "head": head,
        "paths": ["apple-clients/deleted.swift"],
        "android": False,
        "apple": True,
        "reason": "immutable event range",
    }
    assert github_output.read_text() == "android=false\napple=true\n" * 2
    assert event_range(tmp_path, "0" * 40, head)["android"] is True
    assert event_range(tmp_path, "", head)["apple"] is True
    for bad_base, bad_head in [("main", head), (base, "HEAD")]:
        with pytest.raises(ValueError):
            event_range(tmp_path, bad_base, bad_head)
    with pytest.raises(subprocess.CalledProcessError):
        event_range(tmp_path, "f" * 40, head)
    subprocess.run(
        [sys.executable, str(script), "--applicable", "false", "--results", "skipped"], check=True
    )
    subprocess.run(
        [sys.executable, str(script), "--base", base, "--head", head, "--root", str(tmp_path)],
        check=True,
    )


def test_workflow_guard_mutants_cannot_hide_failed_or_skipped_native_work():
    root = Path(__file__).resolve().parents[2]
    for lane, jobs in [
        ("android", ["build-test", "instrumented"]),
        (
            "apple",
            [
                "swift-lint",
                "core-tests",
                "core-ios-tests",
                "app-unit-tests",
                "first-login-ui",
                "watch-continuity",
            ],
        ),
    ]:
        text = (root / ".github/workflows" / f"{lane}-ci.yml").read_text()
        for job in jobs:
            block = re.split(r"(?m)^  [\w-]+:\s*$", text.split(f"  {job}:\n", 1)[1], maxsplit=1)[0]
            assert "    needs: [changes]\n" in block
            assert f"if: needs.changes.outputs.{lane} == 'true'" in block
        aggregate = text.split(f"  {lane}-required:\n", 1)[1]
        assert "      - changes\n" in aggregate
        assert "[[ '${{ needs.changes.result }}' == 'success' ]]" in aggregate
        assert (
            "python3 scripts/ci_lanes.py --applicable '${{ needs.changes.outputs." + lane + " }}'"
            in aggregate
        )
        assert all("needs." + job + ".result" in aggregate for job in jobs)
