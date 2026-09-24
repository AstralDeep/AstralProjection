"""Tests for the web-profile presentation rules on the six additive primitive types
(backend/rote/adapter.py): layout narrows by viewport without losing content, and
non-web profiles never see the new types.
"""

from __future__ import annotations

import pytest

from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile

WEB_DEVICES = ("browser", "tablet", "mobile")
NATIVE_DEVICES = ("windows", "android", "ios", "macos", "watch", "tv", "voice")


def profile(device: str = "browser", width: int = 1440, height: int = 900) -> DeviceProfile:
    # nested capabilities key is ignored; use top-level
    return DeviceProfile.from_dict({
        "device_type": device, "viewport_width": width, "viewport_height": height,
    })


def adapt(component: dict, **kwargs) -> dict | None:
    out = ComponentAdapter.adapt([component], profile(**kwargs))
    return out[0] if out else None


@pytest.mark.parametrize("device,width,requested,expected", [
    ("browser", 1440, 4, 4),
    ("browser", 1440, 8, 6),
    ("tablet", 900, 4, 3),
    ("mobile", 390, 4, 1),
])
def test_stat_group_columns_follow_the_grid_cap(device, width, requested, expected) -> None:
    out = adapt({"type": "stat_group", "title": "Now", "columns": requested,
                 "items": [{"label": "A", "value": "1"}]}, device=device, width=width)
    assert out["columns"] == expected


def test_stat_group_keeps_every_item_when_the_columns_narrow() -> None:
    items = [{"label": f"L{i}", "value": str(i)} for i in range(7)]
    out = adapt({"type": "stat_group", "columns": 6, "items": items},
                device="mobile", width=390)
    assert out["items"] == items


def test_stat_group_with_an_unreadable_column_count_is_left_alone() -> None:
    comp = {"type": "stat_group", "columns": "four", "items": []}
    assert adapt(comp, device="mobile", width=390)["columns"] == "four"


def test_gauge_goes_compact_on_a_phone() -> None:
    out = adapt({"type": "gauge", "label": "Humidity", "value": 0.62,
                 "display_value": "62%"}, device="mobile", width=390)
    assert out["variant"] == "compact"
    assert out["display_value"] == "62%" and out["value"] == 0.62


def test_gauge_is_unchanged_at_desktop_width() -> None:
    comp = {"type": "gauge", "label": "Humidity", "value": 0.62}
    assert "variant" not in adapt(comp, device="browser", width=1440)


def test_a_gauge_that_is_already_compact_is_not_rebuilt() -> None:
    comp = {"type": "gauge", "label": "Load", "value": 0.4, "variant": "compact"}
    assert adapt(comp, device="mobile", width=390) == comp


def test_donut_becomes_a_table_below_700px_with_every_segment() -> None:
    out = adapt({
        "type": "donut_chart", "title": "Mix", "id": "mix",
        "segments": [{"label": "a", "value": 3}, {"label": "b", "value": 5}],
    }, device="mobile", width=390)
    assert out["type"] == "table"
    assert out["title"] == "Mix" and out["id"] == "mix"
    assert out["rows"] == [["a", 3], ["b", 5]]


def test_radar_becomes_a_table_that_keeps_every_axis_and_series() -> None:
    out = adapt({
        "type": "radar_chart", "title": "Quality", "component_id": "q",
        "axes": ["Latency", "Accuracy", "Cost"],
        "datasets": [
            {"label": "TypeSafe", "data": [88, 92, 68]},
            {"label": "Standard", "data": [62, 71, 84]},
        ],
    }, device="mobile", width=390)
    assert out["type"] == "table"
    assert out["columns"] == ["", "Latency", "Accuracy", "Cost"]
    assert out["rows"] == [["TypeSafe", 88, 92, 68], ["Standard", 62, 71, 84]]
    assert out["component_id"] == "q"


def test_a_short_radar_series_is_padded_rather_than_truncating_the_axes() -> None:
    out = adapt({
        "type": "radar_chart", "axes": ["A", "B", "C"],
        "datasets": [{"label": "partial", "data": [1, 2]}],
    }, device="mobile", width=390)
    assert out["rows"] == [["partial", 1, 2, ""]]


@pytest.mark.parametrize("comp_type", ["donut_chart", "radar_chart"])
def test_donut_and_radar_survive_at_700px_and_above(comp_type) -> None:
    comp = {"type": comp_type, "title": "t", "segments": [], "axes": [], "datasets": []}
    assert adapt(comp, device="tablet", width=700)["type"] == comp_type


def test_stepper_goes_vertical_on_a_narrow_viewport() -> None:
    out = adapt({"type": "pipeline_stepper", "steps": [
        {"label": "One", "status": "done"}, {"label": "Two", "status": "active"}]},
        device="mobile", width=390)
    assert out["orientation"] == "vertical"
    assert [s["label"] for s in out["steps"]] == ["One", "Two"]


def test_stepper_stays_horizontal_on_a_wide_viewport() -> None:
    comp = {"type": "pipeline_stepper", "steps": [{"label": "One", "status": "done"}]}
    assert "orientation" not in adapt(comp, device="browser", width=1440)


def _actions(n: int) -> list[dict]:
    return [{"type": "button", "label": f"B{i}", "action": "noop"} for i in range(n)]


def test_action_group_wraps_on_mobile() -> None:
    out = adapt({"type": "action_group", "actions": _actions(2)},
                device="mobile", width=390)
    assert out["wrap"] is True
    assert len(out["actions"]) == 2


def test_more_than_three_actions_move_behind_an_overflow() -> None:
    out = adapt({"type": "action_group", "actions": _actions(5)},
                device="mobile", width=390)
    assert [a["label"] for a in out["actions"]] == ["B0", "B1"]
    assert [a["label"] for a in out["overflow_actions"]] == ["B2", "B3", "B4"]


def test_no_action_is_lost_to_the_overflow_split() -> None:
    original = _actions(5)
    out = adapt({"type": "action_group", "actions": original}, device="browser", width=1440)
    assert out["actions"] + out["overflow_actions"] == original


def test_three_actions_on_a_desktop_are_left_exactly_as_they_were() -> None:
    comp = {"type": "action_group", "title": "Next", "actions": _actions(3)}
    assert adapt(comp, device="browser", width=1440) == comp


@pytest.mark.parametrize("device", NATIVE_DEVICES)
@pytest.mark.parametrize("comp_type,expected", [
    ("stat_group", {"grid", "keyvalue", "table", "text", "container", "card"}),
    ("gauge", {"progress", "metric", "text"}),
    ("pipeline_stepper", {"timeline", "list", "text", "container", "card"}),
    ("donut_chart", {"pie_chart", "table", "list", "text", "metric"}),
    ("radar_chart", {"table", "list", "text", "metric"}),
    ("action_group", {"container", "text", "card", "grid"}),
])
def test_a_non_web_profile_never_sees_an_089_type(device, comp_type, expected) -> None:
    comp = {
        "type": comp_type, "title": "t", "label": "l", "value": 0.5,
        "columns": 4, "items": [{"label": "A", "value": "1"}],
        "steps": [{"label": "One", "status": "done"}],
        "segments": [{"label": "a", "value": 1}],
        "axes": ["A"], "datasets": [{"label": "d", "data": [1]}],
        "actions": _actions(2),
    }
    out = ComponentAdapter.adapt([comp], profile(device=device, width=1440))
    assert out, f"{device} lost the component entirely"
    assert out[0]["type"] != comp_type
    assert out[0]["type"] in expected, (device, comp_type, out[0]["type"])


@pytest.mark.parametrize("device", WEB_DEVICES)
def test_a_web_profile_keeps_drawing_the_type_it_can_draw(device) -> None:
    comp = {"type": "stat_group", "columns": 2, "items": [{"label": "A", "value": "1"}]}
    out = adapt(comp, device=device, width=1440 if device == "browser" else 800)
    assert out["type"] == "stat_group"


@pytest.mark.parametrize("comp_type,extra", [
    ("stat_group", {"columns": 8, "items": []}),
    ("gauge", {"value": 0.5}),
    ("donut_chart", {"segments": []}),
    ("radar_chart", {"axes": [], "datasets": []}),
    ("pipeline_stepper", {"steps": []}),
    ("action_group", {"actions": _actions(5)}),
])
def test_identity_survives_so_canvas_morphs_still_find_the_component(comp_type, extra) -> None:
    comp = {"type": comp_type, "id": "c1", "component_id": "c1", **extra}
    out = adapt(comp, device="mobile", width=390)
    assert out.get("component_id") == "c1"
