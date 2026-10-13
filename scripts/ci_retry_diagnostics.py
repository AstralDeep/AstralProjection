"""Discloses per-test retry outcomes from xcresulttool's structured test tree.
It preserves the original test verdict and reports unavailable diagnostics explicitly.
"""

import argparse
import json
from pathlib import Path


def descendants(node):
    for child in node.get("children", []):
        yield child
        yield from descendants(child)


def report(payload):
    rows = []
    for root in payload["testNodes"]:
        for node in [root, *descendants(root)]:
            if node.get("nodeType") != "Test Case":
                continue
            runs = [
                child.get("result", "unknown")
                for child in descendants(node)
                if child.get("nodeType") == "Test Case Run"
            ]
            if not runs:
                runs = [node.get("result", "unknown")]
            passed = node.get("result") == "Passed"
            disposition = (
                "passed after retry"
                if passed and len(runs) > 1 and "Failed" in runs
                else "first attempt passed"
                if passed and len(runs) == 1
                else "inspect attempts"
            )
            rows.append(
                {
                    "test": node.get("nodeIdentifier", node["name"]),
                    "result": node.get("result", "unknown"),
                    "attempt_results": runs,
                    "disposition": disposition,
                }
            )
    return {
        "diagnostic_only": True,
        "tests": rows,
        "passed_after_retry": sum(row["disposition"] == "passed after retry" for row in rows),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Record and validate bounded owner CI diagnostics."
    )
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        receipt = report(json.loads(args.input.read_text(encoding="utf-8")))
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        receipt = {
            "diagnostic_only": True,
            "status": "unavailable; inspect original xcresult and job logs",
        }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
