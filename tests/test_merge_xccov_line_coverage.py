from __future__ import annotations

import json
from pathlib import Path
import subprocess

import pytest

from scripts.merge_xccov_line_coverage import MergeError, merge_xccov_reports


SOURCE = "apple-clients/AstralApp/AstralApp/App.swift"


def _repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    source = repo / SOURCE
    source.parent.mkdir(parents=True)
    source.write_text("let one = 1\nlet two = 2\n", encoding="utf-8")
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(["git", "-C", str(repo), "add", SOURCE], check=True)
    (repo / "build").mkdir()
    return repo


def _observations(first: int = 1, second: int = 0) -> list[dict[str, object]]:
    return [
        {"line": 1, "isExecutable": True, "executionCount": first},
        {"line": 2, "isExecutable": True, "executionCount": second},
    ]


def _report(repo: Path, name: str, document: object) -> Path:
    path = repo / "build" / name
    path.write_text(json.dumps(document, separators=(",", ":")) + "\n", encoding="utf-8")
    return path


def test_unit_and_ui_reports_merge_deterministically_for_one_platform(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    unit = _report(repo, "unit.json", {SOURCE: _observations(2, 0)})
    ui = _report(repo, "ui.json", {SOURCE: _observations(1, 3)})
    output = repo / "build" / "ios.json"

    merged = merge_xccov_reports(
        repo=repo,
        inputs=[unit, ui],
        output=output,
        platform="ios",
    )

    assert merged == {SOURCE: _observations(3, 3)}
    assert output.read_text(encoding="utf-8") == (
        json.dumps(merged, sort_keys=True, separators=(",", ":")) + "\n"
    )


def test_relative_inputs_and_output_are_resolved_under_explicit_repo(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    _report(repo, "unit.json", {SOURCE: _observations(2, 0)})

    merged = merge_xccov_reports(
        repo=repo,
        inputs=[Path("build/unit.json")],
        output=Path("build/ios.json"),
        platform="ios",
    )

    assert merged == {SOURCE: _observations(2, 0)}
    assert (repo / "build/ios.json").is_file()


@pytest.mark.parametrize(
    "document",
    (
        {"../App.swift": _observations()},
        {"apple-clients/AstralWatch/Watch.swift": _observations()},
        {"apple-clients/AstralApp/AstralApp/Untracked.swift": _observations()},
        {SOURCE: [{"line": 2, "isExecutable": True, "executionCount": 1}]},
        {SOURCE: [{"line": 1, "isExecutable": True, "executionCount": True}]},
        {SOURCE: [{"line": 1, "isExecutable": True, "executionCount": 1, "extra": 0}]},
    ),
)
def test_path_source_and_observation_shape_fail_closed(
    tmp_path: Path,
    document: object,
) -> None:
    repo = _repo(tmp_path)
    report = _report(repo, "input.json", document)

    with pytest.raises(MergeError):
        merge_xccov_reports(
            repo=repo,
            inputs=[report],
            output=repo / "build" / "output.json",
            platform="ios",
        )


def test_duplicate_json_keys_and_duplicate_input_files_fail_closed(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    duplicate_key = repo / "build" / "duplicate.json"
    encoded = json.dumps(_observations(), separators=(",", ":"))
    duplicate_key.write_text(f'{{"{SOURCE}":{encoded},"{SOURCE}":{encoded}}}\n')

    with pytest.raises(MergeError, match="duplicate"):
        merge_xccov_reports(
            repo=repo,
            inputs=[duplicate_key],
            output=repo / "build" / "output.json",
            platform="ios",
        )

    report = _report(repo, "input.json", {SOURCE: _observations()})
    with pytest.raises(MergeError, match="duplicate"):
        merge_xccov_reports(
            repo=repo,
            inputs=[report, report],
            output=repo / "build" / "output.json",
            platform="ios",
        )


def test_incompatible_executable_masks_and_count_overflow_fail_closed(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    first = _report(repo, "first.json", {SOURCE: _observations((1 << 63) - 1, 0)})
    incompatible = _report(
        repo,
        "incompatible.json",
        {
            SOURCE: [
                {"line": 1, "isExecutable": False},
                {"line": 2, "isExecutable": True, "executionCount": 0},
            ]
        },
    )
    overflowing = _report(repo, "overflowing.json", {SOURCE: _observations(1, 0)})

    with pytest.raises(MergeError, match="executable"):
        merge_xccov_reports(
            repo=repo,
            inputs=[first, incompatible],
            output=repo / "build" / "incompatible-output.json",
            platform="ios",
        )
    with pytest.raises(MergeError, match="overflow"):
        merge_xccov_reports(
            repo=repo,
            inputs=[first, overflowing],
            output=repo / "build" / "overflow-output.json",
            platform="ios",
        )
