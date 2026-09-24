"""Tests for the fallback ladders in backend/rote/fallback.py: every ladder terminates
in text, and each step down (gauge, stat_group, pipeline_stepper, donut, radar,
action_group) keeps the underlying data and component identity.
"""

from __future__ import annotations

import pytest

from rote import fallback
from rote.adapter import ComponentAdapter

NEW_TYPES = (
    "action_group",
    "stat_group",
    "gauge",
    "pipeline_stepper",
    "donut_chart",
    "radar_chart",
)

RICH = {
    "text", "list", "table", "container", "card", "grid", "keyvalue",
    "progress", "metric", "timeline", "pie_chart", "button",
}
TEXT_ONLY = {"text"}


def _degrade(component: dict, supported: set) -> dict:
    return ComponentAdapter._degrade_unsupported(component, supported)


@pytest.mark.parametrize(
    "wire_type,expected",
    [
        ("action_group", ("container", "text")),
        ("stat_group", ("grid", "keyvalue", "table", "text")),
        ("gauge", ("progress", "metric", "text")),
        ("pipeline_stepper", ("timeline", "list", "text")),
        ("donut_chart", ("pie_chart", "table", "list", "text")),
        ("radar_chart", ("table", "list", "text")),
    ],
)
def test_the_ladders_match_the_contract(wire_type: str, expected: tuple) -> None:
    assert fallback.FALLBACK_LADDER[wire_type] == expected


@pytest.mark.parametrize("wire_type", NEW_TYPES)
def test_every_ladder_terminates_in_text(wire_type: str) -> None:
    assert fallback.FALLBACK_LADDER[wire_type][-1] == fallback.TERMINAL


@pytest.mark.parametrize("wire_type", NEW_TYPES)
def test_a_supporting_target_keeps_the_type(wire_type: str) -> None:
    assert fallback.first_supported(wire_type, {wire_type}) == wire_type


def test_gauge_becomes_a_progress_bar_with_its_value() -> None:
    out = _degrade(
        {"type": "gauge", "label": "Humidity", "value": 0.62, "display_value": "62%"},
        RICH,
    )
    assert out["type"] == "progress"
    assert out["value"] == 0.62
    assert "Humidity" in out["label"] and "62%" in out["label"]
    assert out["show_percentage"] is False


def test_gauge_without_a_display_value_keeps_the_percentage() -> None:
    out = _degrade({"type": "gauge", "label": "Load", "value": 0.4}, RICH)
    assert out["show_percentage"] is True


def test_gauge_becomes_a_metric_when_progress_is_unsupported() -> None:
    out = _degrade(
        {"type": "gauge", "label": "Load", "value": 0.4, "display_value": "40%"},
        {"text", "metric"},
    )
    assert out["type"] == "metric"
    assert out["title"] == "Load"
    assert out["value"] == "40%"
    assert out["progress"] == 0.4


def test_stat_group_becomes_a_grid_of_metrics() -> None:
    out = _degrade(
        {
            "type": "stat_group",
            "title": "This week",
            "columns": 3,
            "items": [
                {"label": "Requests", "value": "1,284", "delta": "+12%"},
                {"label": "Errors", "value": "3", "variant": "success"},
            ],
        },
        RICH,
    )
    assert out["type"] == "grid"
    assert out["columns"] == 3
    assert [c["type"] for c in out["children"]] == ["metric", "metric"]
    assert out["children"][0]["title"] == "Requests"
    assert out["children"][0]["value"] == "1,284"
    assert out["children"][0]["subtitle"] == "+12%"
    assert out["children"][1]["variant"] == "success"


def test_stat_group_becomes_a_keyvalue_when_grid_is_unsupported() -> None:
    out = _degrade(
        {"type": "stat_group", "items": [{"label": "p95", "value": "412 ms"}]},
        {"text", "keyvalue"},
    )
    assert out["type"] == "keyvalue"
    assert out["items"][0] == {"label": "p95", "value": "412 ms", "hint": None}


def test_pipeline_stepper_becomes_a_timeline_with_mapped_variants() -> None:
    out = _degrade(
        {
            "type": "pipeline_stepper",
            "title": "Job",
            "steps": [
                {"label": "Queued", "status": "done", "detail": "3s"},
                {"label": "Running", "status": "active"},
                {"label": "Collect", "status": "pending"},
                {"label": "Failed", "status": "error"},
            ],
        },
        RICH,
    )
    assert out["type"] == "timeline"
    assert [i["variant"] for i in out["items"]] == [
        "success",
        "info",
        "default",
        "error",
    ]
    assert out["items"][0]["title"] == "Queued"
    assert out["items"][0]["description"] == "3s"


def test_an_unknown_step_status_maps_to_default() -> None:
    out = _degrade(
        {"type": "pipeline_stepper", "steps": [{"label": "x", "status": "sideways"}]},
        RICH,
    )
    assert out["items"][0]["variant"] == "default"


def test_donut_becomes_a_pie_with_identical_data() -> None:
    out = _degrade(
        {
            "type": "donut_chart",
            "title": "Storage",
            "labels": ["Used", "Free"],
            "data": [62.0, 38.0],
        },
        RICH,
    )
    assert out["type"] == "pie_chart"
    assert out["labels"] == ["Used", "Free"]
    assert out["data"] == [62.0, 38.0]


def test_radar_becomes_a_table_with_axes_as_headers() -> None:
    out = _degrade(
        {
            "type": "radar_chart",
            "title": "Models",
            "axes": ["accuracy", "recall", "latency"],
            "datasets": [
                {"label": "Baseline", "data": [0.82, 0.71, 0.9]},
                {"label": "Candidate", "data": [0.88, 0.79, 0.74]},
            ],
        },
        {"text", "table"},
    )
    assert out["type"] == "table"
    assert out["headers"] == ["", "accuracy", "recall", "latency"]
    assert out["rows"][0][0] == "Baseline"
    assert out["rows"][1][0] == "Candidate"
    assert out["rows"][0][1:] == ["0.82", "0.71", "0.9"]


def test_a_short_radar_row_is_padded_rather_than_misaligned() -> None:
    out = _degrade(
        {
            "type": "radar_chart",
            "axes": ["a", "b", "c"],
            "datasets": [{"label": "s", "data": [1]}],
        },
        {"text", "table"},
    )
    assert out["rows"][0] == ["s", "1", "", ""]


def test_action_group_becomes_a_container_of_buttons() -> None:
    out = _degrade(
        {
            "type": "action_group",
            "label": "Result actions",
            "buttons": [{"type": "button", "label": "Save", "action": "save_result"}],
        },
        RICH,
    )
    assert out["type"] == "container"
    assert out["title"] == "Result actions"
    assert out["content"][0]["action"] == "save_result"


@pytest.mark.parametrize(
    "component,expected_fragments",
    [
        (
            {"type": "gauge", "label": "Humidity", "value": 0.62,
             "display_value": "62%"},
            ["Humidity", "62%"],
        ),
        (
            {"type": "stat_group", "title": "Week",
             "items": [{"label": "p95", "value": "412 ms"}]},
            ["Week", "p95", "412 ms"],
        ),
        (
            {"type": "pipeline_stepper",
             "steps": [{"label": "Queued", "status": "done"}]},
            ["Queued", "done"],
        ),
        (
            {"type": "donut_chart", "labels": ["Used", "Free"], "data": [62, 38]},
            ["Used", "62", "Free", "38"],
        ),
        (
            {"type": "radar_chart", "axes": ["accuracy"],
             "datasets": [{"label": "Baseline", "data": [0.82]}]},
            ["Baseline", "accuracy", "0.82"],
        ),
        (
            {"type": "action_group", "label": "Actions",
             "buttons": [{"type": "button", "label": "Save", "action": "s"}]},
            ["Actions", "Save"],
        ),
    ],
    ids=["gauge", "stat_group", "pipeline_stepper", "donut", "radar", "action_group"],
)
def test_a_text_only_target_still_gets_the_numbers(
    component: dict, expected_fragments: list
) -> None:
    out = _degrade(component, TEXT_ONLY)
    assert out["type"] == "text"
    for fragment in expected_fragments:
        assert fragment in out["content"], f"{fragment!r} missing from {out['content']!r}"


@pytest.mark.parametrize("wire_type", NEW_TYPES)
def test_no_new_type_ever_degrades_to_an_empty_node(wire_type: str) -> None:
    components = {
        "gauge": {"type": "gauge", "label": "L", "value": 0.5},
        "stat_group": {"type": "stat_group", "items": [{"label": "a", "value": "1"}]},
        "pipeline_stepper": {"type": "pipeline_stepper",
                             "steps": [{"label": "s", "status": "done"}]},
        "donut_chart": {"type": "donut_chart", "labels": ["a"], "data": [1]},
        "radar_chart": {"type": "radar_chart", "axes": ["a"],
                        "datasets": [{"label": "s", "data": [1]}]},
        "action_group": {"type": "action_group", "label": "A", "buttons": []},
    }
    out = _degrade(components[wire_type], TEXT_ONLY)
    assert out["content"].strip() != ""


@pytest.mark.parametrize("wire_type", NEW_TYPES)
def test_component_identity_survives_substitution(wire_type: str) -> None:
    components = {
        "gauge": {"type": "gauge", "value": 0.5},
        "stat_group": {"type": "stat_group", "items": []},
        "pipeline_stepper": {"type": "pipeline_stepper", "steps": []},
        "donut_chart": {"type": "donut_chart", "labels": ["a"], "data": [1]},
        "radar_chart": {"type": "radar_chart", "axes": ["a", "b", "c"],
                        "datasets": [{"label": "s", "data": [1, 2, 3]}]},
        "action_group": {"type": "action_group", "buttons": []},
    }
    component = dict(components[wire_type], id="cmp-089")
    assert _degrade(component, TEXT_ONLY).get("id") == "cmp-089"
    assert _degrade(component, RICH).get("id") == "cmp-089"
