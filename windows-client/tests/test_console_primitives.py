"""Exercise the native composite renderers with shared payload shapes and invalid data.
Checks include accessible values, action dispatch, responsive layout and painted output.
"""

import copy
import math

import pytest
from PySide6.QtCore import QRect, Qt
from PySide6.QtGui import QImage, QPainter
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QLabel, QPushButton, QWidget

from astral_client import theme as T
from astral_client.composites import FlowLayout, PrimitivePlot, StatGrid, _palette
from astral_client.renderer import RenderContext, render, supported_types


def _render(component, sink=None):
    return render(component, RenderContext(emit=sink or (lambda action, payload: None)))


def _labels(widget):
    return "\n".join(label.text() for label in widget.findChildren(QLabel))


def _paint(widget, width=320):
    widget.resize(width, widget.sizeHint().height())
    image = QImage(widget.size(), QImage.Format.Format_ARGB32)
    image.fill(Qt.GlobalColor.transparent)
    painter = QPainter(image)
    widget.render(painter, widget.rect().topLeft())
    painter.end()
    return image


def test_existing_composite_vocabulary_is_rendered(qapp):
    expected = {"action_group", "stat_group", "gauge", "pipeline_stepper", "donut_chart", "radar_chart"}
    assert expected <= set(supported_types())
    for kind in expected:
        widget = _render({"type": kind, "component_id": kind})
        assert widget.property("component_id") == kind
        assert "render error" not in _labels(widget)


def test_actions_dispatch_exact_server_actions_once_with_isolated_payload(qapp):
    seen = []
    source = {"type": "action_group", "label": "Actions", "buttons": [
        {"label": "Run & review", "action": "server.private.action", "payload": {"value": [1]}},
        {"label": "Disabled", "action": "unsafe", "disabled": True},
    ]}
    widget = _render(source, lambda action, payload: seen.append((action, payload)))
    assert widget.accessibleName() == "Actions"
    buttons = widget.findChildren(QPushButton)
    assert buttons[0].text() == "Run && review"
    assert buttons[0].accessibleName() == "Run & review"
    widget.show()
    buttons[0].setFocus()
    QTest.keyClick(buttons[0], Qt.Key.Key_Space)
    assert seen == [("server.private.action", {"value": [1]})]
    seen[0][1]["value"].append(2)
    buttons[0].click()
    buttons[1].click()
    assert seen[-1] == ("server.private.action", {"value": [1]})
    assert len(seen) == 2
    assert source["buttons"][0]["payload"] == {"value": [1]}
    widget.close()


@pytest.mark.parametrize("item", [{}, {"action": " "}, {"action": 42}, {"action": "valid", "payload": []}])
def test_malformed_actions_are_disabled_with_recovery(qapp, item):
    widget = _render({"type": "action_group", "buttons": [item]})
    button = widget.findChild(QPushButton)
    assert not button.isEnabled()
    assert "refreshed data" in button.accessibleDescription()


@pytest.mark.parametrize("variant", ["secondary", "ghost", "danger", "other"])
def test_action_variant_and_group_disable(qapp, variant):
    widget = _render({"type": "action_group", "disabled": True, "buttons": [
        {"label": "Test", "action": "test", "variant": variant}]})
    button = widget.findChild(QPushButton)
    assert not button.isEnabled()
    assert button.objectName() == (variant if variant != "other" else "primary")


@pytest.mark.parametrize("align", ["start", "center", "end", "between", "unknown"])
def test_actions_wrap_at_narrow_width_and_keep_alignment(qapp, align):
    parent = QWidget()
    layout = FlowLayout(parent, align)
    for name in ["First action", "Second action", "A" * 180]:
        layout.addWidget(QPushButton(name))
    assert layout.hasHeightForWidth()
    assert layout.expandingDirections() == Qt.Orientation(0)
    assert layout.minimumSize().width() == 0
    assert layout.sizeHint().width() == 320
    assert layout.heightForWidth(180) > layout.heightForWidth(2000)
    layout.setGeometry(QRect(0, 0, 180, 500))
    for index in range(layout.count()):
        rect = layout.itemAt(index).geometry()
        assert rect.left() >= 0 and rect.right() < 180
    layout.setGeometry(QRect(0, 0, 2000, 200))
    assert layout.itemAt(-1) is None and layout.itemAt(10) is None
    assert layout.takeAt(10) is None
    item = layout.takeAt(2)
    assert item is not None and layout.count() == 2


def test_empty_flow_layout(qapp):
    layout = FlowLayout()
    assert layout.heightForWidth(0) == 0
    assert layout.minimumSize().height() == 0
    assert layout.takeAt(-1) is None


@pytest.mark.parametrize("columns", [4, 0, 99, None, math.inf, "invalid"])
def test_statistics_reflow_and_preserve_values_and_trends(qapp, columns):
    source = {"type": "stat_group", "title": "Performance", "columns": columns, "items": [
        {"label": "p95", "value": "412 ms", "delta": "-5%", "trend": "down", "variant": "success", "hint": "Last hour"},
        {"label": "Load", "value": 0, "delta": 0, "trend": "flat", "variant": []},
        {"label": "Count", "value": "3", "trend": "up"},
        {"label": "Next", "value": "4"},
    ]}
    widget = _render(source)
    grid = widget.findChild(StatGrid)
    assert grid is not None
    widget.resize(1100, 400)
    widget.show()
    qapp.processEvents()
    assert grid.current_columns == min(grid.columns, 6)
    widget.resize(260, 600)
    qapp.processEvents()
    assert grid.current_columns == 1
    assert "412 ms" in _labels(widget)
    assert "▼ -5%" in _labels(widget) and "– 0" in _labels(widget)
    assert "Last hour" in grid.cells[0].accessibleName()
    grid._reflow(260)
    widget.close()


@pytest.mark.parametrize("orientation", ["vertical", "horizontal"])
def test_pipeline_status_details_and_single_current_step(qapp, orientation):
    widget = _render({"type": "pipeline_stepper", "title": "Processing", "orientation": orientation, "steps": [
        {"label": "Fetch", "status": "done"},
        {"label": "Review", "status": "active", "detail": "Checking inputs"},
        {"label": "Persist", "status": "active"},
        {"label": "Recover", "status": "error"},
        {"label": "Next", "status": "unknown"},
    ]})
    steps = [child for child in widget.findChildren(QWidget) if child.property("status")]
    assert [step.property("status") for step in steps] == ["done", "active", "active", "error", "pending"]
    assert sum(bool(step.property("current_step")) for step in steps) == 1
    assert steps[1].accessibleDescription() == "Checking inputs"
    assert "Next" in _labels(widget)
    assert steps[-1].accessibleName() == "Next: pending"
    assert not _paint(widget).isNull()


@pytest.mark.parametrize("value,expected", [(-1, 0), (0.75, 0.75), (5, 1)])
def test_gauge_clamps_finite_values_and_uses_thresholds(qapp, value, expected):
    widget = _render({"type": "gauge", "label": "Utilization", "value": value,
                      "display_value": "Observed", "subtitle": "Right now", "thresholds": [
                          {"at": 0, "variant": "success"}, {"at": 0.7, "variant": "warning"}]})
    plot = widget.findChild(PrimitivePlot)
    assert plot.values == [expected]
    assert plot.variant == ("warning" if expected >= 0.7 else "success")
    assert widget.accessibleName() == "Utilization: Observed"
    assert "Right now" in _labels(widget)
    assert plot.sizeHint().width() == 128
    assert not _paint(widget).isNull()


def test_gauge_default_display_and_theme_painting(qapp):
    widget = _render({"type": "gauge", "value": 0.42})
    assert widget.accessibleName() == "42%"
    plot = widget.findChild(PrimitivePlot)
    before = _paint(plot)
    palette = dict(T.PALETTE)
    try:
        T.apply_theme("daylight")
        after = _paint(plot)
        assert before != after
    finally:
        T.apply_theme({"colors": palette})


def test_donut_values_centers_labels_and_export_capture(qapp):
    source = {"type": "donut_chart", "title": "Distribution", "labels": ["Alpha", ""],
              "data": [3, 1, -1], "center_value": "4", "center_label": "Total"}
    snapshot = copy.deepcopy(source)
    widget = _render(source)
    plot = widget.findChild(PrimitivePlot)
    assert plot.values == [3, 1, 0]
    assert plot.accessibleDescription() == "Alpha: 3; series 2: 1; series 3: 0"
    assert "4\nTotal" in _labels(widget)
    assert not _paint(widget).isNull()
    assert source == snapshot


@pytest.mark.parametrize("values", [[0, 0], [1e308, 1e308], [1]])
def test_donut_zero_or_large_finite_totals_paint_safely(qapp, values):
    widget = _render({"type": "donut_chart", "data": values})
    assert widget.findChild(PrimitivePlot) is not None
    assert not _paint(widget, 180).isNull()
    assert ("Total is zero." in _labels(widget)) == (not any(values))


@pytest.mark.parametrize("maximum", [None, 5, 0, -1])
def test_radar_preserves_accessible_actual_values_and_bounds_plot(qapp, maximum):
    widget = _render({"type": "radar_chart", "title": "Quality", "axes": ["A", "B", ""],
                      "datasets": [{"label": "Measured", "data": [2, 8]}, {"data": [-1, 0, 4]}],
                      "max_value": maximum})
    plot = widget.findChild(PrimitivePlot)
    assert plot.values == [[2, 8, 0], [0, 0, 4]]
    assert plot.scale == (5 if maximum == 5 else 8)
    assert "Measured: A 2, B 8, axis 3 0" in plot.accessibleDescription()
    assert "series 2: A 0, B 0, axis 3 4" in plot.accessibleDescription()
    assert "A 0, B 0" not in _labels(widget)
    assert not _paint(widget).isNull()


def test_radar_zero_values_use_finite_scale(qapp):
    widget = _render({"type": "radar_chart", "axes": ["a", "b", "c"], "datasets": [{}]})
    assert widget.findChild(PrimitivePlot).scale == 1
    assert not _paint(widget).isNull()


def test_composite_series_palette_uses_shared_pastels_and_legends_keep_values_accessible(qapp):
    colors = [T.PRIMARY, T.SECONDARY, T.ACCENT]
    assert _palette() == colors + [T._mix(color, "#FFFFFF", 0.45) for color in colors]
    widget = _render({"type": "donut_chart", "data": [3, 2], "labels": ["Accepted", "Waiting"]})
    assert "Accepted: 3" not in _labels(widget)
    assert "Accepted: 3" in widget.findChild(PrimitivePlot).accessibleDescription()


def test_gauge_uses_shared_compact_spacing_and_info_accent(qapp):
    widget = _render({"type": "gauge", "value": 0.4, "thresholds": [{"at": 0, "variant": "info"}]})
    assert widget.layout().spacing() == 4
    assert widget.findChild(PrimitivePlot).variant == "info"
    assert not _paint(widget).isNull()


@pytest.mark.parametrize("component", [
    {"type": "gauge", "value": math.nan},
    {"type": "gauge", "value": math.inf},
    {"type": "gauge", "value": True},
    {"type": "gauge", "value": "bad"},
    {"type": "gauge", "thresholds": [False]},
    {"type": "gauge", "thresholds": [{"at": math.inf}]},
    {"type": "donut_chart", "data": [math.nan]},
    {"type": "donut_chart", "data": [math.inf]},
    {"type": "donut_chart", "data": [None]},
    {"type": "donut_chart", "data": "bad"},
    {"type": "donut_chart", "data": [1] * 129},
    {"type": "radar_chart", "axes": ["a", "b", "c"], "datasets": [1]},
    {"type": "radar_chart", "axes": ["a", "b", "c"], "datasets": [{"data": [math.inf]}]},
    {"type": "radar_chart", "axes": ["a", "b", "c"], "datasets": [{}], "max_value": math.inf},
    {"type": "stat_group", "items": ["bad"]},
    {"type": "action_group", "buttons": ["bad"]},
    {"type": "pipeline_stepper", "steps": ["bad"]},
])
def test_invalid_data_never_appears_as_valid_zero(qapp, component):
    widget = _render(component)
    assert "data is invalid" in _labels(widget)
    assert "refreshed data" in widget.accessibleDescription()
    assert widget.findChild(PrimitivePlot) is None


@pytest.mark.parametrize("kind,expected", [
    ("action_group", "No actions"), ("stat_group", "No statistics"),
    ("pipeline_stepper", "No steps"), ("donut_chart", "No chart data"),
    ("radar_chart", "three axes"),
])
def test_empty_data_has_truthful_feedback(qapp, kind, expected):
    assert expected in _labels(_render({"type": kind}))


def test_untrusted_text_is_literal_in_composites(qapp):
    widget = _render({"type": "stat_group", "title": "<b>Title</b>",
                      "items": [{"label": "<img src='file:///secret'>", "value": "<script>alert(1)</script>"}]})
    labels = widget.findChildren(QLabel)
    assert all(label.textFormat() == Qt.TextFormat.PlainText for label in labels)
    assert "<script>alert(1)</script>" in _labels(widget)


@pytest.mark.parametrize("component", [
    {"type": "stat_group", "items": [{"label": "Long label " * 20, "value": "x" * 200}]},
    {"type": "pipeline_stepper", "steps": [{"label": "Very long step name " * 20}]},
    {"type": "donut_chart", "labels": ["Very long series name " * 20], "data": [1]},
    {"type": "radar_chart", "axes": ["First " * 20, "Second", "Third"], "datasets": [{"data": [1, 2, 3]}]},
])
def test_long_content_can_still_fit_narrow_window(qapp, component):
    widget = _render(component)
    widget.resize(320, 600)
    widget.show()
    qapp.processEvents()
    assert widget.width() == 320
    widget.close()
