"""Tests retry disclosure against structured xcresult test cases and unavailable inputs.
The diagnostic cannot change the original qualification verdict.
"""

import json

from scripts.ci_retry_diagnostics import main, report


def case(name, result, runs):
    return {
        "nodeType": "Test Case",
        "name": name,
        "result": result,
        "children": [
            {"nodeType": "Test Case Run", "name": str(index), "result": run}
            for index, run in enumerate(runs)
        ],
    }


def test_retry_disclosure_keeps_first_pass_retry_pass_and_failed_distinct():
    receipt = report(
        {
            "testNodes": [
                {
                    "nodeType": "Test Suite",
                    "children": [
                        case("first", "Passed", ["Passed"]),
                        case("retried", "Passed", ["Failed", "Passed"]),
                        case("failed", "Failed", ["Failed", "Failed"]),
                        case("skipped", "Skipped", []),
                        case("plain", "Passed", []),
                        case("repeated", "Passed", ["Passed", "Passed"]),
                    ],
                }
            ]
        }
    )
    assert receipt["passed_after_retry"] == 1
    assert [row["disposition"] for row in receipt["tests"]] == [
        "first attempt passed",
        "passed after retry",
        "inspect attempts",
        "inspect attempts",
        "first attempt passed",
        "inspect attempts",
    ]
    assert receipt["tests"][2]["result"] == "Failed"


def test_cli_retains_receipts_and_marks_unavailable_without_changing_test_verdict(tmp_path):
    source = tmp_path / "input.json"
    output = tmp_path / "nested" / "receipt.json"
    source.write_text(json.dumps({"testNodes": [case("retried", "Passed", ["Failed", "Passed"])]}))
    main(["--input", str(source), "--output", str(output)])
    assert json.loads(output.read_text())["passed_after_retry"] == 1
    for payload in ("{}", "invalid", '{"testNodes": null}', '{"testNodes": [null]}'):
        source.write_text(payload)
        main(["--input", str(source), "--output", str(output)])
        assert "unavailable" in json.loads(output.read_text())["status"]
    source.unlink()
    main(["--input", str(source), "--output", str(output)])
    assert "unavailable" in json.loads(output.read_text())["status"]
