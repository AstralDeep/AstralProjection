from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "apple_build_number.py"


_SPEC = importlib.util.spec_from_file_location("apple_build_number", SCRIPT)
assert _SPEC is not None and _SPEC.loader is not None
apple_build_number = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(apple_build_number)


def test_projection_run_one_starts_at_protected_base() -> None:
    assert (
        apple_build_number.calculate_build_number(
            base=1_000,
            run_number=1,
            last_submitted_build=41,
        )
        == 1_000
    )


def test_successive_projection_runs_are_strictly_monotonic() -> None:
    values = [
        apple_build_number.calculate_build_number(
            base="1000",
            run_number=str(run),
            last_submitted_build="41",
        )
        for run in (1, 2, 3)
    ]
    assert values == [1_000, 1_001, 1_002]


@pytest.mark.parametrize("base", ["41", "40"])
def test_base_must_exceed_last_submitted_build(base: str) -> None:
    with pytest.raises(ValueError, match="greater than"):
        apple_build_number.calculate_build_number(
            base=base,
            run_number="1",
            last_submitted_build="41",
        )


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("base", "0"),
        ("base", "+42"),
        ("base", " 42"),
        ("run_number", "01"),
        ("run_number", "-1"),
        ("last_submitted_build", True),
    ],
)
def test_noncanonical_inputs_fail_closed(field: str, value: object) -> None:
    inputs: dict[str, object] = {
        "base": 1_000,
        "run_number": 1,
        "last_submitted_build": 41,
    }
    inputs[field] = value
    with pytest.raises(ValueError, match="positive decimal"):
        apple_build_number.calculate_build_number(**inputs)  # type: ignore[arg-type]


def test_build_number_overflow_refuses() -> None:
    with pytest.raises(ValueError, match="exceeds"):
        apple_build_number.calculate_build_number(
            base=9_999,
            run_number=2,
            last_submitted_build=41,
        )


def test_individual_value_above_supported_range_refuses() -> None:
    with pytest.raises(ValueError, match="at most"):
        apple_build_number.calculate_build_number(
            base=10_000,
            run_number=1,
            last_submitted_build=41,
        )


def test_cli_uses_protected_environment(capsys: pytest.CaptureFixture[str]) -> None:
    assert (
        apple_build_number.main(
            [],
            environment={
                apple_build_number.BUILD_NUMBER_BASE_ENV: "1000",
                apple_build_number.LAST_SUBMITTED_BUILD_ENV: "41",
                apple_build_number.RUN_NUMBER_ENV: "7",
            },
        )
        == 0
    )
    assert capsys.readouterr().out == "1006\n"


def test_cli_uses_process_environment(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setenv(apple_build_number.BUILD_NUMBER_BASE_ENV, "1000")
    monkeypatch.setenv(apple_build_number.LAST_SUBMITTED_BUILD_ENV, "41")
    monkeypatch.setenv(apple_build_number.RUN_NUMBER_ENV, "3")
    assert apple_build_number.main([]) == 0
    assert capsys.readouterr().out == "1002\n"


def test_explicit_cli_values_override_environment(
    capsys: pytest.CaptureFixture[str],
) -> None:
    assert (
        apple_build_number.main(
            [
                "--base",
                "2000",
                "--last-submitted-build",
                "58",
                "--run-number",
                "2",
            ],
            environment={
                apple_build_number.BUILD_NUMBER_BASE_ENV: "1000",
                apple_build_number.LAST_SUBMITTED_BUILD_ENV: "41",
                apple_build_number.RUN_NUMBER_ENV: "7",
            },
        )
        == 0
    )
    assert capsys.readouterr().out == "2001\n"


def test_missing_offset_fails_closed_in_main(
    capsys: pytest.CaptureFixture[str],
) -> None:
    with pytest.raises(SystemExit) as caught:
        apple_build_number.main([], environment={})
    assert caught.value.code == 2
    captured = capsys.readouterr()
    assert apple_build_number.BUILD_NUMBER_BASE_ENV in captured.err
    assert captured.out == ""


def test_missing_offset_refuses_without_output() -> None:
    completed = subprocess.run(
        [sys.executable, str(SCRIPT)],
        cwd=ROOT,
        env={},
        capture_output=True,
        text=True,
        check=False,
    )
    assert completed.returncode == 2
    assert apple_build_number.BUILD_NUMBER_BASE_ENV in completed.stderr
    assert completed.stdout == ""


def test_apple_product_and_signing_identities_remain_stable() -> None:
    project = (
        ROOT / "apple-clients" / "AstralApp" / "AstralApp.xcodeproj" / "project.pbxproj"
    ).read_text(encoding="utf-8")
    base_config = (ROOT / "apple-clients" / "Config" / "Base.xcconfig").read_text(encoding="utf-8")

    assert "PRODUCT_BUNDLE_IDENTIFIER = com.personalailabs.astraldeep;" in project
    assert "PRODUCT_BUNDLE_IDENTIFIER = com.personalailabs.astraldeep.watch;" in project
    assert '"PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]" = "$(ASTRAL_PROFILE_IOS)";' in project
    assert '"PROVISIONING_PROFILE_SPECIFIER[sdk=macosx*]" = "$(ASTRAL_PROFILE_MACOS)";' in project
    assert '"PROVISIONING_PROFILE_SPECIFIER[sdk=watchos*]" = "$(ASTRAL_PROFILE_WATCH)";' in project
    assert "DEVELOPMENT_TEAM = $(ASTRAL_DEVELOPMENT_TEAM)" in base_config


def test_release_docs_do_not_restore_pre_migration_counters_or_alias_authority() -> None:
    apple_readme = (ROOT / "apple-clients" / "README.md").read_text(encoding="utf-8")
    android_runbook = (ROOT / "android-client" / "docs" / "play-store-release.md").read_text(
        encoding="utf-8"
    )
    android_continuity = (ROOT / "docs" / "android-release-continuity.md").read_text(
        encoding="utf-8"
    )

    assert "CURRENT_PROJECT_VERSION = $GITHUB_RUN_NUMBER" not in apple_readme
    assert "scripts/apple_build_number.py" in apple_readme
    assert "versionCode = 2" not in android_runbook
    assert "expected local layout remains" not in android_continuity
    assert "historically documented alias" in android_continuity
