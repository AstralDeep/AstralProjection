"""Prove focused native and Markdown tests reject four maintained broken guards.
Runs isolate the actual source files and reject collection, import, skip, or execution errors.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


MUTATIONS = (
    (
        "native-result-guard",
        "scripts/ci_lanes.py",
        "if any(result != expected for result in results):",
        "if False:",
        "test_native_failures_and_skips_do_not_authorize",
    ),
    (
        "shared-path-classifier",
        "scripts/ci_lanes.py",
        "shared = any(path.startswith(SHARED) or path in SHARED_FILES for path in paths)",
        "shared = False",
        "test_shared_changes_require_every_native_lane",
    ),
    (
        "markdown-unsafe-url",
        "backend/webrender/sanitize.py",
        'return s if _ALLOWED_URL.match(s) else "#"',
        "return s",
        "test_markdown_unsafe_destinations_are_blocked",
    ),
    (
        "markdown-destination-length",
        "backend/webrender/sanitize.py",
        "if i - start > _MAX_LINK_DESTINATION_LENGTH:",
        "if False:",
        "test_markdown_destination_length_limit_is_exact",
    ),
)
ISOLATED_FILES = (
    "scripts/ci_lanes.py",
    "backend/webrender/sanitize.py",
    "tests/ci/test_regression_acceptance.py",
)


def classify_result(returncode, report, test_name, mutant):
    try:
        document = ET.parse(report)
    except (OSError, ET.ParseError) as error:
        raise ValueError("missing or malformed focused-test report") from error
    cases = document.findall(".//testcase")
    if len(cases) != 1 or cases[0].get("name") != test_name:
        raise ValueError("focused test was not collected exactly once")
    if document.findall(".//error") or document.findall(".//skipped"):
        raise ValueError("collection, execution error, or skip is not a mutation kill")
    failures = document.findall(".//failure")
    if not mutant:
        if returncode or failures:
            raise ValueError("unmodified acceptance control failed")
        return "passed"
    if returncode != 1 or len(failures) != 1:
        raise ValueError("mutation survived or pytest did not report a behavioral failure")
    failure = failures[0]
    kind, message = failure.get("type", ""), failure.get("message", "")
    if kind:
        behavioral = kind in {"AssertionError", "Failed", "_pytest.outcomes.Failed"}
    else:
        behavioral = message in {"AssertionError", "Failed"} or message.startswith(
            ("assert ", "AssertionError:", "Failed: ")
        )
    if not behavioral:
        raise ValueError("execution errors are not behavioral assertion kills")
    return "killed"


def run_case(root, mutation, mutant):
    name, source, original, replacement, test_name = mutation
    with tempfile.TemporaryDirectory(prefix="projection-mutation-") as directory:
        target = Path(directory)
        for path in ISOLATED_FILES:
            destination = target / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(root / path, destination)
        source_path = target / source
        text = source_path.read_text(encoding="utf-8")
        if text.count(original) != 1:
            raise ValueError(
                f"mutation {name} needs one maintained target, found {text.count(original)}"
            )
        if mutant:
            source_path.write_text(text.replace(original, replacement), encoding="utf-8")
        report = target / "result.xml"
        environment = dict(os.environ, PYTHONPATH=str(target), PYTEST_DISABLE_PLUGIN_AUTOLOAD="1")
        environment.pop("PYTEST_ADDOPTS", None)
        result = subprocess.run(
            [
                sys.executable,
                "-m",
                "pytest",
                "-q",
                "-p",
                "no:cacheprovider",
                f"tests/ci/test_regression_acceptance.py::{test_name}",
                f"--junitxml={report}",
            ],
            cwd=target,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
        try:
            return classify_result(result.returncode, report, test_name, mutant)
        except ValueError as error:
            raise ValueError(f"{name}: {error}\n{result.stdout}\n{result.stderr}") from error


def main():
    results = []
    try:
        for mutation in MUTATIONS:
            control = run_case(Path.cwd(), mutation, mutant=False)
            killed = run_case(Path.cwd(), mutation, mutant=True)
            results.append(
                {
                    "mutation": mutation[0],
                    "test": mutation[4],
                    "control": control,
                    "mutation_result": killed,
                }
            )
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"status": "error", "reason": str(error), "results": results}, indent=2))
        return 1
    print(json.dumps({"status": "pass", "mutations": len(results), "results": results}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
