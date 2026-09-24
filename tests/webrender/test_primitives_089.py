"""Tests for the six composite renderers and multi-dataset bar charts in
backend/webrender/renderer.py: no unescaped text or attribute injection,
clamped/coerced values, screen-reader semantics, and theme-only colors.
"""

from __future__ import annotations

import re

import pytest

from webrender.renderer import (
    PRIMITIVE_RENDERERS,
    allowed_primitive_types,
    render_action_group,
    render_bar_chart,
    render_donut_chart,
    render_gauge,
    render_pipeline_stepper,
    render_radar_chart,
    render_stat_group,
)

NEW_TYPES = (
    "action_group",
    "stat_group",
    "gauge",
    "pipeline_stepper",
    "donut_chart",
    "radar_chart",
)

XSS = '<img src=x onerror="alert(1)">'
XSS_ATTR = '" onmouseover="alert(1)'


def _render(component: dict) -> str:
    return PRIMITIVE_RENDERERS[component["type"]](component)


@pytest.mark.parametrize("wire_type", NEW_TYPES)
def test_every_new_type_is_registered_and_allowed(wire_type: str) -> None:
    assert wire_type in PRIMITIVE_RENDERERS
    assert wire_type in allowed_primitive_types()


@pytest.mark.parametrize(
    "component",
    [
        {"type": "action_group", "label": XSS, "buttons": [
            {"type": "button", "label": XSS, "action": "go"}
        ]},
        {"type": "stat_group", "title": XSS, "items": [
            {"label": XSS, "value": XSS, "delta": XSS, "hint": XSS, "variant": XSS}
        ]},
        {"type": "gauge", "label": XSS, "display_value": XSS, "subtitle": XSS,
         "value": 0.5, "thresholds": [{"at": 0.1, "variant": XSS}]},
        {"type": "pipeline_stepper", "title": XSS, "steps": [
            {"label": XSS, "status": XSS, "detail": XSS}
        ]},
        {"type": "donut_chart", "title": XSS, "labels": [XSS], "data": [1.0],
         "center_label": XSS, "center_value": XSS},
        {"type": "radar_chart", "title": XSS, "axes": [XSS, "b", "c"],
         "datasets": [{"label": XSS, "data": [1, 2, 3]}]},
    ],
    ids=NEW_TYPES,
)
def test_no_raw_script_vector_survives(component: dict) -> None:
    html = _render(component)
    assert "<img" not in html
    assert '<img src=x onerror="alert(1)">' not in html
    if "alert(1)" in html:
        assert "&lt;img" in html or "&quot;alert(1)&quot;" in html


@pytest.mark.parametrize(
    "component",
    [
        {"type": "action_group", "label": XSS_ATTR, "buttons": []},
        {"type": "gauge", "label": XSS_ATTR, "value": 0.5},
        {"type": "donut_chart", "title": XSS_ATTR, "labels": ["a"], "data": [1.0]},
        {"type": "radar_chart", "title": XSS_ATTR, "axes": ["a", "b", "c"],
         "datasets": [{"label": "s", "data": [1, 2, 3]}]},
    ],
)
def test_attribute_breakout_is_escaped(component: dict) -> None:
    html = _render(component)
    assert '" onmouseover="' not in html
    assert "&quot; onmouseover=&quot;" in html or "onmouseover" not in html


@pytest.mark.parametrize("wire_type", NEW_TYPES)
def test_no_component_value_reaches_a_dangerous_attribute(wire_type: str) -> None:
    poison = "POISON_VALUE_12345"
    components = {
        "action_group": {"type": "action_group", "label": poison, "align": poison,
                         "buttons": []},
        "stat_group": {"type": "stat_group", "title": poison, "columns": poison,
                       "items": [{"label": poison, "value": poison,
                                  "variant": poison, "trend": poison}]},
        "gauge": {"type": "gauge", "label": poison, "value": poison,
                  "display_value": poison,
                  "thresholds": [{"at": poison, "variant": poison}]},
        "pipeline_stepper": {"type": "pipeline_stepper", "title": poison,
                             "orientation": poison,
                             "steps": [{"label": poison, "status": poison}]},
        "donut_chart": {"type": "donut_chart", "title": poison, "labels": [poison],
                        "data": [1.0], "center_value": poison},
        "radar_chart": {"type": "radar_chart", "title": poison,
                        "axes": ["a", "b", "c"], "max_value": poison,
                        "datasets": [{"label": poison, "data": [1, 2, 3]}]},
    }
    html = _render(components[wire_type])
    for attribute in ("style=", "href=", "src=", "onclick=", "onload="):
        if attribute in html:
            for match in re.finditer(re.escape(attribute) + r'"([^"]*)"', html):
                assert poison not in match.group(1)
    for match in re.finditer(r'class="([^"]*)"', html):
        assert poison not in match.group(1)


@pytest.mark.parametrize("value,expected_fraction", [
    (-5, 0.0), (0, 0.0), (0.5, 0.5), (1, 1.0), (42, 1.0), ("nope", 0.0), (None, 0.0),
])
def test_gauge_clamps_its_value(value, expected_fraction) -> None:
    html = render_gauge({"type": "gauge", "value": value})
    assert f"{round(expected_fraction * 100)}%" in html
    for match in re.finditer(r'stroke-dasharray="([\d.]+)', html):
        assert float(match.group(1)) <= 126.0 + 1e-6


@pytest.mark.parametrize("columns,expected", [(0, 1), (1, 1), (4, 4), (6, 6), (99, 6),
                                              ("x", 4), (None, 4)])
def test_stat_group_clamps_columns(columns, expected) -> None:
    html = render_stat_group({"type": "stat_group", "columns": columns, "items": []})
    assert f'data-columns="{expected}"' in html


def test_radar_chart_refuses_fewer_than_three_axes() -> None:
    assert render_radar_chart({
        "type": "radar_chart", "axes": ["a", "b"],
        "datasets": [{"label": "s", "data": [1, 2]}],
    }) == ""


def test_charts_with_no_data_render_nothing() -> None:
    assert render_donut_chart({"type": "donut_chart", "data": []}) == ""
    assert render_radar_chart({"type": "radar_chart", "axes": ["a", "b", "c"],
                               "datasets": []}) == ""
    assert render_bar_chart({"type": "bar_chart", "datasets": []}) == ""


def test_donut_segments_never_exceed_the_circumference() -> None:
    html = render_donut_chart({
        "type": "donut_chart", "labels": ["a", "b", "c"], "data": [5, 3, 2],
    })
    lengths = [
        float(m.group(1))
        for m in re.finditer(r'stroke-dasharray="([\d.]+) ', html)
    ]
    assert lengths and sum(lengths) <= 251.5


def test_negative_chart_values_are_floored_at_zero() -> None:
    html = render_donut_chart({"type": "donut_chart", "labels": ["a", "b"],
                               "data": [-10, 10]})
    assert "-" not in re.search(r'stroke-dasharray="([^"]*)"', html).group(1)


def test_stat_group_uses_a_definition_list() -> None:
    html = render_stat_group({
        "type": "stat_group",
        "items": [{"label": "p95", "value": "412 ms"}],
    })
    assert "<dl" in html and "<dt" in html and "<dd" in html


def test_pipeline_stepper_uses_an_ordered_list() -> None:
    html = render_pipeline_stepper({
        "type": "pipeline_stepper",
        "steps": [{"label": "Queued", "status": "done"}],
    })
    assert "<ol" in html and "<li" in html


def test_only_the_first_active_step_is_current() -> None:
    html = render_pipeline_stepper({
        "type": "pipeline_stepper",
        "steps": [
            {"label": "One", "status": "active"},
            {"label": "Two", "status": "active"},
        ],
    })
    assert html.count('aria-current="step"') == 1


def test_gauge_and_donut_expose_an_image_role_with_a_label() -> None:
    gauge = render_gauge({"type": "gauge", "label": "Load", "value": 0.4,
                          "display_value": "40%"})
    assert 'role="img"' in gauge
    assert 'aria-label="Load: 40%"' in gauge

    donut = render_donut_chart({"type": "donut_chart", "title": "Storage",
                                "labels": ["Used"], "data": [1.0]})
    assert 'role="img"' in donut
    assert "Storage" in donut


def test_radar_chart_emits_a_hidden_data_table() -> None:
    html = render_radar_chart({
        "type": "radar_chart",
        "title": "Models",
        "axes": ["accuracy", "recall", "latency"],
        "datasets": [{"label": "Baseline", "data": [0.8, 0.7, 0.9]}],
    })
    assert "astral-sr-only" in html
    assert "<table" in html and "<caption>" in html
    assert 'scope="col"' in html and 'scope="row"' in html
    for axis in ("accuracy", "recall", "latency"):
        assert axis in html
    assert "Baseline" in html


def test_action_group_is_a_labelled_group() -> None:
    html = render_action_group({
        "type": "action_group",
        "label": "Result actions",
        "buttons": [{"type": "button", "label": "Save", "action": "save_result"}],
    })
    assert 'role="group"' in html
    assert 'aria-label="Result actions"' in html
    assert 'data-action="save_result"' in html
    assert "astral-action" in html


@pytest.mark.parametrize("wire_type", NEW_TYPES)
def test_no_renderer_emits_a_color_literal(wire_type: str) -> None:
    components = {
        "action_group": {"type": "action_group", "buttons": []},
        "stat_group": {"type": "stat_group",
                       "items": [{"label": "a", "value": "1", "variant": "success"}]},
        "gauge": {"type": "gauge", "value": 0.9,
                  "thresholds": [{"at": 0.8, "variant": "warning"}]},
        "pipeline_stepper": {"type": "pipeline_stepper",
                             "steps": [{"label": "x", "status": "error"}]},
        "donut_chart": {"type": "donut_chart", "labels": ["a", "b"], "data": [1, 1]},
        "radar_chart": {"type": "radar_chart", "axes": ["a", "b", "c"],
                        "datasets": [{"label": "s", "data": [1, 2, 3]}]},
    }
    html = _render(components[wire_type])
    assert not re.search(r"#[0-9a-fA-F]{3,8}\b", html)
    assert "rgb(" not in html and "rgba(" not in html


def test_series_colors_cycle_through_theme_classes() -> None:
    html = render_donut_chart({
        "type": "donut_chart",
        "labels": [str(i) for i in range(8)],
        "data": [1] * 8,
    })
    used = set(re.findall(r"astral-series-(\d)", html))
    assert used <= {"1", "2", "3", "4", "5", "6"}
    assert len(used) == 6


def test_bar_chart_renders_every_dataset() -> None:
    html = render_bar_chart({
        "type": "bar_chart",
        "labels": ["a", "b"],
        "datasets": [
            {"label": "Baseline", "data": [1, 2]},
            {"label": "Candidate", "data": [3, 4]},
        ],
    })
    assert "Baseline" in html
    assert "Candidate" in html


def test_a_single_dataset_bar_chart_keeps_its_original_payload() -> None:
    html = render_bar_chart({
        "type": "bar_chart", "labels": ["a"], "datasets": [{"label": "x", "data": [1]}],
    })
    assert "datasets" not in html


def test_bar_chart_ignores_non_dict_datasets() -> None:
    assert render_bar_chart({"type": "bar_chart", "datasets": ["not-a-dict"]}) == ""
