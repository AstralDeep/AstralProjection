"""Tests confirming the first-login UI transport fixture is compiled only into Debug
builds, never Release.
"""

from pathlib import Path


def test_first_login_fixture_and_completion_gate_are_entirely_debug_only() -> None:
    source = (
        Path(__file__).resolve().parents[1]
        / "apple-clients/AstralApp/AstralApp/FirstLoginUITestFixture.swift"
    ).read_text()
    assert "ASTRAL_UI_FIRST_LOGIN_GATE_PORT" in source
    lines = source.splitlines()
    assert lines[0] == "#if DEBUG"
    depth = 0
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("#if "):
            depth += 1
        elif stripped == "#endif":
            depth -= 1
            assert depth >= 0
        elif stripped.startswith(("#else", "#elseif")):
            assert depth > 1, "The fixture must not have a Release branch"
        elif stripped:
            assert depth > 0, "Fixture declaration escaped its DEBUG conditional"
    assert depth == 0
