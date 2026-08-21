from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys

import pytest

from scripts import merge_xccov_line_coverage as merger
from scripts.export_xccov_line_coverage import ExportError
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
        inputs={"unit": unit, "ui": ui},
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
    _report(repo, "ui.json", {SOURCE: _observations(0, 3)})

    merged = merge_xccov_reports(
        repo=repo,
        inputs={
            "unit": Path("build/unit.json"),
            "ui": Path("build/ui.json"),
        },
        output=Path("build/ios.json"),
        platform="ios",
    )

    assert merged == {SOURCE: _observations(2, 3)}
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
    ui = _report(repo, "ui.json", {SOURCE: _observations()})

    with pytest.raises(MergeError):
        merge_xccov_reports(
            repo=repo,
            inputs={"unit": report, "ui": ui},
            output=repo / "build" / "output.json",
            platform="ios",
        )


def test_duplicate_json_keys_and_duplicate_input_files_fail_closed(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    duplicate_key = repo / "build" / "duplicate.json"
    encoded = json.dumps(_observations(), separators=(",", ":"))
    duplicate_key.write_text(f'{{"{SOURCE}":{encoded},"{SOURCE}":{encoded}}}\n')
    ui = _report(repo, "ui.json", {SOURCE: _observations()})

    with pytest.raises(MergeError, match="duplicate"):
        merge_xccov_reports(
            repo=repo,
            inputs={"unit": duplicate_key, "ui": ui},
            output=repo / "build" / "output.json",
            platform="ios",
        )

    report = _report(repo, "input.json", {SOURCE: _observations()})
    with pytest.raises(MergeError, match="duplicate"):
        merge_xccov_reports(
            repo=repo,
            inputs={"unit": report, "ui": report},
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
            inputs={"unit": first, "ui": incompatible},
            output=repo / "build" / "incompatible-output.json",
            platform="ios",
        )
    with pytest.raises(MergeError, match="overflow"):
        merge_xccov_reports(
            repo=repo,
            inputs={"unit": first, "ui": overflowing},
            output=repo / "build" / "overflow-output.json",
            platform="ios",
        )


@pytest.mark.parametrize(
    "inputs",
    (
        {},
        {"unit": "unit"},
        {"ui": "ui"},
        {"unit": "unit", "first-login": "ui"},
        {"unit": "unit", "ui": "ui", "integration": "other"},
    ),
)
def test_exact_unit_and_ui_producer_labels_are_required(
    tmp_path: Path,
    inputs: dict[str, str],
) -> None:
    repo = _repo(tmp_path)
    paths = {
        name: _report(repo, f"{name}.json", {SOURCE: _observations()})
        for name in {"unit", "ui", "other"}
    }

    with pytest.raises(MergeError, match="producer"):
        merge_xccov_reports(
            repo=repo,
            inputs={label: paths[name] for label, name in inputs.items()},
            output=repo / "build" / "output.json",
            platform="ios",
        )


def test_cli_requires_one_explicit_unit_and_ui_input(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    unit = _report(repo, "unit.json", {SOURCE: _observations(2, 0)})
    ui = _report(repo, "ui.json", {SOURCE: _observations(1, 3)})
    script = Path(__file__).resolve().parents[1] / "scripts" / "merge_xccov_line_coverage.py"

    def run(arguments: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(script), *arguments],
            cwd=repo,
            check=False,
            capture_output=True,
            text=True,
        )

    base = [
        "--repo",
        str(repo),
        "--platform",
        "ios",
        "--unit-input",
        str(unit),
        "--ui-input",
        str(ui),
        "--output",
        str(repo / "build" / "output.json"),
    ]
    assert run(base).returncode == 0
    (repo / "build" / "output.json").unlink()

    for arguments, expected in (
        (
            [value for index, value in enumerate(base) if index not in {4, 5}],
            "required",
        ),
        ([*base[:6], "--unit-input", str(unit), *base[6:]], "exactly one"),
        ([*base[:4], "--first-login-input", str(unit), *base[6:]], "required"),
    ):
        result = run(arguments)
        assert result.returncode != 0
        assert expected in result.stderr


def test_watchos_is_not_a_unit_ui_union_platform(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    unit = _report(repo, "unit.json", {SOURCE: _observations()})
    ui = _report(repo, "ui.json", {SOURCE: _observations()})

    with pytest.raises(MergeError, match="platform"):
        merge_xccov_reports(
            repo=repo,
            inputs={"unit": unit, "ui": ui},
            output=repo / "build" / "output.json",
            platform="watchos",
        )


@pytest.mark.parametrize(
    ("content", "code"),
    (
        (b"", "input_too_large"),
        (b"\xff", "invalid_json"),
        (b"{", "invalid_json"),
        (b"[]", "invalid_document"),
        (b"{}", "invalid_document"),
        (b'{"source":NaN}', "invalid_json"),
    ),
)
def test_malformed_or_unbounded_input_bytes_fail_closed(
    tmp_path: Path,
    content: bytes,
    code: str,
) -> None:
    repo = _repo(tmp_path)
    unit = repo / "build" / "unit.json"
    unit.write_bytes(content)
    ui = _report(repo, "ui.json", {SOURCE: _observations()})

    with pytest.raises(MergeError) as raised:
        merge_xccov_reports(
            repo=repo,
            inputs={"unit": unit, "ui": ui},
            output=repo / "build" / "output.json",
            platform="ios",
        )
    assert raised.value.code == code


@pytest.mark.parametrize(
    "observations",
    (
        [],
        [1, {"line": 2, "isExecutable": True, "executionCount": 0}],
        [
            {"line": 1, "isExecutable": "yes", "executionCount": 0},
            {"line": 2, "isExecutable": True, "executionCount": 0},
        ],
        [
            {"line": 1, "isExecutable": False, "extra": 0},
            {"line": 2, "isExecutable": True, "executionCount": 0},
        ],
    ),
)
def test_additional_observation_shape_failures_are_rejected(
    tmp_path: Path,
    observations: object,
) -> None:
    repo = _repo(tmp_path)
    unit = _report(repo, "unit.json", {SOURCE: observations})
    ui = _report(repo, "ui.json", {SOURCE: _observations()})

    with pytest.raises(MergeError):
        merge_xccov_reports(
            repo=repo,
            inputs={"unit": unit, "ui": ui},
            output=repo / "build" / "output.json",
            platform="ios",
        )


def test_repository_output_and_input_filesystem_boundaries_fail_closed(
    tmp_path: Path,
) -> None:
    missing_repo = tmp_path / "missing"
    with pytest.raises(MergeError) as missing:
        merge_xccov_reports(
            repo=missing_repo,
            inputs={},
            output=Path("output.json"),
            platform="ios",
        )
    assert missing.value.code == "missing_repo"

    regular_file = tmp_path / "regular"
    regular_file.write_text("not a repository", encoding="utf-8")
    with pytest.raises(MergeError) as invalid:
        merge_xccov_reports(
            repo=regular_file,
            inputs={},
            output=Path("output.json"),
            platform="ios",
        )
    assert invalid.value.code == "invalid_repo"

    repo = _repo(tmp_path / "nested")
    unit = _report(repo, "unit.json", {SOURCE: _observations()})
    ui = _report(repo, "ui.json", {SOURCE: _observations()})
    occupied = repo / "build" / "occupied.json"
    occupied.write_text("occupied", encoding="utf-8")
    with pytest.raises(MergeError) as existing:
        merge_xccov_reports(
            repo=repo,
            inputs={"unit": unit, "ui": ui},
            output=occupied,
            platform="ios",
        )
    assert existing.value.code == "output_exists"

    with pytest.raises(MergeError) as wrong_type:
        merge_xccov_reports(
            repo=repo,
            inputs={"unit": unit, "ui": "build/ui.json"},  # type: ignore[dict-item]
            output=repo / "build" / "output.json",
            platform="ios",
        )
    assert wrong_type.value.code == "invalid_producer_input"

    with pytest.raises(MergeError) as missing_input:
        merge_xccov_reports(
            repo=repo,
            inputs={"unit": repo / "build" / "missing.json", "ui": ui},
            output=repo / "build" / "output.json",
            platform="ios",
        )
    assert missing_input.value.code == "missing_input"

    directory_input = repo / "build" / "directory-input"
    directory_input.mkdir()
    with pytest.raises(MergeError) as unsafe_input:
        merge_xccov_reports(
            repo=repo,
            inputs={"unit": directory_input, "ui": ui},
            output=repo / "build" / "output.json",
            platform="ios",
        )
    assert unsafe_input.value.code == "unsafe_input"


def test_cumulative_bounds_and_output_write_failure_are_enforced(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repo = _repo(tmp_path)
    unit = _report(repo, "unit.json", {SOURCE: _observations()})
    ui = _report(repo, "ui.json", {SOURCE: _observations()})

    monkeypatch.setattr(merger, "MAX_TOTAL_INPUT_BYTES", unit.stat().st_size)
    with pytest.raises(MergeError) as input_budget:
        merge_xccov_reports(
            repo=repo,
            inputs={"unit": unit, "ui": ui},
            output=repo / "build" / "input-budget.json",
            platform="ios",
        )
    assert input_budget.value.code == "input_budget_exceeded"

    monkeypatch.setattr(merger, "MAX_TOTAL_INPUT_BYTES", 64 * 1024 * 1024)
    monkeypatch.setattr(merger, "MAX_TOTAL_OBSERVATIONS", 1)
    with pytest.raises(MergeError) as observation_budget:
        merge_xccov_reports(
            repo=repo,
            inputs={"unit": unit, "ui": ui},
            output=repo / "build" / "observation-budget.json",
            platform="ios",
        )
    assert observation_budget.value.code == "observation_budget_exceeded"

    monkeypatch.setattr(merger, "MAX_TOTAL_OBSERVATIONS", 2_000_000)
    monkeypatch.setattr(merger, "MAX_OUTPUT_BYTES", 1)
    with pytest.raises(MergeError) as output_budget:
        merge_xccov_reports(
            repo=repo,
            inputs={"unit": unit, "ui": ui},
            output=repo / "build" / "output-budget.json",
            platform="ios",
        )
    assert output_budget.value.code == "output_too_large"

    monkeypatch.setattr(merger, "MAX_OUTPUT_BYTES", 64 * 1024 * 1024)

    def reject_write(_output: Path, _content: bytes) -> None:
        raise ExportError("output_write_failed", "refused")

    monkeypatch.setattr(merger, "_write_new_output", reject_write)
    with pytest.raises(MergeError) as write_failure:
        merge_xccov_reports(
            repo=repo,
            inputs={"unit": unit, "ui": ui},
            output=repo / "build" / "write-failure.json",
            platform="ios",
        )
    assert write_failure.value.code == "output_write_failed"


def test_non_executable_lines_remain_non_executable_in_the_union(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    observations = [
        {"line": 1, "isExecutable": False},
        {"line": 2, "isExecutable": True, "executionCount": 1},
    ]
    unit = _report(repo, "unit.json", {SOURCE: observations})
    ui = _report(repo, "ui.json", {SOURCE: observations})

    merged = merge_xccov_reports(
        repo=repo,
        inputs={"unit": unit, "ui": ui},
        output=repo / "build" / "output.json",
        platform="ios",
    )

    assert merged[SOURCE] == [
        {"line": 1, "isExecutable": False},
        {"line": 2, "isExecutable": True, "executionCount": 2},
    ]


def test_main_reports_success_duplicate_producers_and_merge_failures(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo = _repo(tmp_path)
    unit = _report(repo, "unit.json", {SOURCE: _observations()})
    ui = _report(repo, "ui.json", {SOURCE: _observations()})

    def arguments(output: str) -> list[str]:
        return [
            "--repo",
            str(repo),
            "--platform",
            "ios",
            "--unit-input",
            str(unit),
            "--ui-input",
            str(ui),
            "--output",
            str(repo / "build" / output),
        ]

    assert merger.main(arguments("success.json")) == 0
    duplicate = arguments("duplicate.json")
    duplicate[6:6] = ["--unit-input", str(unit)]
    assert merger.main(duplicate) == 2
    assert "exactly one unit" in capsys.readouterr().err

    monkeypatch.setattr(
        merger,
        "merge_xccov_reports",
        lambda **_kwargs: (_ for _ in ()).throw(MergeError("forced", "refused")),
    )
    assert merger.main(arguments("merge-error.json")) == 2
    assert "[forced]" in capsys.readouterr().err

    monkeypatch.setattr(
        merger,
        "merge_xccov_reports",
        lambda **_kwargs: (_ for _ in ()).throw(OSError("hidden")),
    )
    assert merger.main(arguments("filesystem-error.json")) == 2
    assert "[filesystem_error]" in capsys.readouterr().err
