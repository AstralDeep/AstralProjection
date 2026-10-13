"""Qualify bounded mutations and reject collection, import, skip, or missing-report kills.
The real isolated runs exercise native applicability and Markdown acceptance tests.
"""

import json
from pathlib import Path

import pytest


def test_named_behavior_failure_is_required_to_kill_a_mutation(tmp_path):
    from scripts.check_regression_effectiveness import classify_result

    report = tmp_path / "result.xml"
    report.write_text(
        '<testsuites><testsuite><testcase name="test_guard"><failure message="AssertionError: accepted denial"/></testcase></testsuite></testsuites>'
    )
    assert classify_result(1, report, "test_guard", mutant=True) == "killed"
    with pytest.raises(ValueError, match="control failed"):
        classify_result(1, report, "test_guard", mutant=False)
    report.write_text(
        '<testsuites><testsuite><testcase name="test_guard"/></testsuite></testsuites>'
    )
    assert classify_result(0, report, "test_guard", mutant=False) == "passed"
    with pytest.raises(ValueError, match="survived"):
        classify_result(0, report, "test_guard", mutant=True)


@pytest.mark.parametrize(
    "body",
    [
        '<error message="collection error"/>',
        '<failure message="ImportError: missing"/>',
        '<failure message="ModuleNotFoundError: missing"/>',
        '<failure message="SyntaxError: invalid"/>',
        '<failure message="NameError: missing"/>',
        '<failure message="AttributeError: missing"/>',
        "<skipped/>",
    ],
)
def test_collection_import_or_execution_errors_and_skips_are_not_kills(tmp_path, body):
    from scripts.check_regression_effectiveness import classify_result

    report = tmp_path / "result.xml"
    report.write_text(
        '<testsuites><testsuite><testcase name="test_guard">'
        + body
        + "</testcase></testsuite></testsuites>"
    )
    with pytest.raises(ValueError):
        classify_result(1, report, "test_guard", mutant=True)


def test_missing_or_wrong_test_reports_fail(tmp_path):
    from scripts.check_regression_effectiveness import classify_result

    report = tmp_path / "missing.xml"
    with pytest.raises(ValueError):
        classify_result(1, report, "test_guard", mutant=True)
    report.write_text('<testsuites><testsuite><testcase name="wrong"/></testsuite></testsuites>')
    with pytest.raises(ValueError):
        classify_result(0, report, "test_guard", mutant=False)


def test_real_isolated_controls_and_mutants(monkeypatch, capsys):
    from scripts.check_regression_effectiveness import main

    monkeypatch.chdir(Path(__file__).resolve().parents[2])
    assert main() == 0
    receipt = json.loads(capsys.readouterr().out)
    assert receipt["mutations"] == 4
    assert all(
        case["control"] == "passed" and case["mutation_result"] == "killed"
        for case in receipt["results"]
    )


def test_stale_mutation_and_failed_run_fail_closed(monkeypatch, capsys):
    import scripts.check_regression_effectiveness as gate

    root = Path(__file__).resolve().parents[2]
    mutation = ("stale", "scripts/ci_lanes.py", "missing target", "", "test_guard")
    with pytest.raises(ValueError, match="maintained target"):
        gate.run_case(root, mutation, mutant=True)
    monkeypatch.chdir(root)
    monkeypatch.setattr(gate, "MUTATIONS", [mutation])
    assert gate.main() == 1
    assert json.loads(capsys.readouterr().out)["status"] == "error"
    monkeypatch.undo()
    mutation = (*gate.MUTATIONS[0][:4], "missing_test")
    with pytest.raises(ValueError, match="not collected"):
        gate.run_case(root, mutation, mutant=False)
