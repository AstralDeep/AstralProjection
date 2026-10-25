"""Qualifies opt-in server-owned Mac workbench geometry and legacy client fallback."""

import json
from pathlib import Path

import pytest

from rote.capabilities import DeviceProfile


def profile(width=1440, **updates):
    return DeviceProfile.from_dict({
        "device_type": "macos", "console_contract": "console/v2",
        "viewport_width": width, "viewport_height": 900,
        "mac_workbench_v1": True, **updates,
    }).to_dict()


@pytest.mark.parametrize("device", ["ios", "android", "windows", "browser", "watch"])
def test_other_clients_retain_console_without_workbench_geometry(device):
    assert "mac_workbench" not in profile(device_type=device)["console"]


@pytest.mark.parametrize("value", [False, "true", 1, None, {}, []])
def test_exact_capability_opt_in_is_required(value):
    actual = profile(mac_workbench_v1=value)["console"]
    legacy = DeviceProfile.from_dict({
        "device_type": "macos", "console_contract": "console/v2",
        "viewport_width": 1440, "viewport_height": 900,
    }).to_dict()["console"]
    assert actual == legacy
    assert "console" not in profile(console_contract="")


def test_server_selects_split_and_widths_for_navigation_and_full_window():
    workbench = profile(1440)["console"]["mac_workbench"]
    assert workbench == {
        "version": 1,
        "with_sidebar": {"split": True, "conversation_width": 468.7, "compact_toolbar": False},
        "without_sidebar": {"split": True, "conversation_width": 520, "compact_toolbar": False},
        "composer_max_width": 860,
        "transcript_max_width": 720,
    }


def test_compact_panes_and_sidebar_toggle_are_resolved_by_server():
    compact = profile(390)["console"]["mac_workbench"]
    assert compact["with_sidebar"] == {"split": False, "conversation_width": 390, "compact_toolbar": True}
    assert compact["without_sidebar"] == compact["with_sidebar"]
    medium = profile(1024)["console"]["mac_workbench"]
    assert medium["with_sidebar"] == {"split": False, "conversation_width": 736, "compact_toolbar": False}
    assert medium["without_sidebar"] == {"split": True, "conversation_width": 440.32, "compact_toolbar": False}


@pytest.mark.parametrize("case", json.loads(
    (Path(__file__).parents[2] / "contracts/fixtures/console/mac-workbench.json").read_text()
)["cases"], ids=lambda case: case["name"])
def test_shared_fixture_is_exact_current_server_profile(case):
    assert profile(case["viewport"][0])["console"] == case["presentation"]
