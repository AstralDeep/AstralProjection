"""Equivalent viewports share grid arrangement without losing native capabilities."""

import json

import pytest

from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile, DeviceType, load_host_config


@pytest.mark.parametrize("native", ["android", "ios", "macos"])
@pytest.mark.parametrize("width,expected", [(200, 1), (393, 1), (480, 1), (481, 3), (1024, 3), (1025, 6)])
def test_native_grid_density_matches_web_at_viewport_boundaries(native, width, expected):
    profile = DeviceProfile.from_dict({"device_type": native, "viewport_width": width})
    web = DeviceProfile.from_dict({"device_type": "browser", "viewport_width": width})
    assert profile.max_grid_columns == web.max_grid_columns == expected
    assert profile.device_type is DeviceType(native)
    assert profile.supports_code and profile.supports_tables and profile.supports_charts
    assert profile.supports_interactivity
    assert profile.max_table_cols == profile.max_table_rows == profile.max_text_chars == 0


@pytest.mark.parametrize("native", ["android", "ios", "macos"])
def test_phone_rich_grid_stacks_without_losing_content_or_identity(native):
    profile = DeviceProfile.from_dict({"device_type": native, "viewport_width": 393})
    table = {"type": "table", "headers": [f"Column {i}" for i in range(7)],
             "rows": [[f"Cell {i}" for i in range(7)] for _ in range(25)]}
    code = {"type": "code", "content": "print('complete native content')", "language": "python"}
    grid = {"type": "grid", "columns": 2, "id": "result", "component_id": "result",
            "children": [table, code]}
    adapted = ComponentAdapter.adapt([grid], profile)[0]
    assert adapted["type"] == "container"
    assert adapted["id"] == adapted["component_id"] == "result"
    assert adapted["children"][0]["headers"] == table["headers"]
    assert adapted["children"][0]["rows"] == table["rows"]
    assert adapted["children"][1] == code


def test_operator_limits_bound_density_without_mutating_other_profiles(monkeypatch):
    monkeypatch.setenv("ROTE_HOST_CONFIG", json.dumps({
        "ios": {"max_grid_columns": 2, "supports_code": False},
        "mobile": {"max_grid_columns": 1}, "tablet": {"max_grid_columns": 4},
        "browser": {"max_grid_columns": 5},
    }))
    for width, expected in [(393, 1), (900, 2), (1200, 2)]:
        profile = DeviceProfile.from_dict({"device_type": "ios", "viewport_width": width})
        assert profile.max_grid_columns == expected
        assert profile.supports_code is False
    assert DeviceProfile.from_dict({"device_type": "android", "viewport_width": 900}).max_grid_columns == 4
    assert DeviceProfile.from_dict({"device_type": "macos", "viewport_width": 1200}).max_grid_columns == 5
    assert load_host_config()["ios"]["max_grid_columns"] == 2
    assert load_host_config()["android"]["max_grid_columns"] == 6


def test_absent_viewport_keeps_wide_default_and_zero_uses_screen_width():
    assert DeviceProfile.from_dict({"device_type": "ios"}).max_grid_columns == 6
    assert DeviceProfile.from_dict({"device_type": "ios", "viewport_width": 0, "screen_width": 393}).max_grid_columns == 1
    assert DeviceProfile.from_dict({"device_type": "windows", "viewport_width": 393}).max_grid_columns == 6
