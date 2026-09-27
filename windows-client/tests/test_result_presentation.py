"""Checks native result chrome against the shared responsive presentation contract.
The retained canvas and server-owned labels survive preview and full-screen transitions.
"""

import copy

import pytest
from PySide6.QtCore import QEvent
from PySide6.QtWidgets import QApplication, QLineEdit

from astral_client.app import Canvas
from astral_client.console_widgets import ResultPanel
from astral_client.renderer import RenderContext
from astral_client.rest import parse_chrome_menu
from webrender.chrome.menu_model import menu_model_dict
from test_composer_geometry import native_style, settle  # noqa: F401
from test_console_shell import GEOMETRY, MENU

WORKSPACE_ACTIONS = parse_chrome_menu(
    menu_model_dict(export_enabled=True, share_enabled=True, include_admin=False)
)["workspace_actions"]


@pytest.fixture
def panel(qapp):
    canvas = Canvas(RenderContext(emit=lambda *args: None))
    result = ResultPanel(canvas)
    result.set_workspace_actions(WORKSPACE_ACTIONS)
    result.show()
    yield result
    result.close()
    result.deleteLater()
    QApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)


@pytest.mark.parametrize("geometry", GEOMETRY)
@pytest.mark.parametrize("fullscreen", [False, True])
def test_responsive_header_keeps_labels_and_actions_inside_panel(panel, geometry, fullscreen):
    labels = MENU["console"]["labels"]
    compact = geometry["presentation"]["settings_navigation_axis"] == "horizontal"
    panel.fullscreen = fullscreen
    panel.configure(labels, geometry["presentation"])
    panel.set_metadata("Dice Roller", 1)
    panel.resize(geometry["viewport"][0], 700)
    settle()
    expected_height = (65 if compact else 70) if fullscreen else (60 if compact else 50)
    assert panel.header_widget.height() == expected_height
    assert panel.fullscreen_badge.isVisible() is (fullscreen and not compact)
    assert panel.escape_hint.isVisible() is (fullscreen and not compact)
    assert panel.turn_badge.isVisible() is (not fullscreen and not compact)
    assert panel.fullscreen_button.accessibleName() == labels["exit_fullscreen" if fullscreen else "fullscreen"]
    assert panel.fullscreen_button.text() == ("" if compact else labels["exit_fullscreen" if fullscreen else "fullscreen"])
    for index in range(panel.workspace_layout.count()):
        control = panel.workspace_layout.itemAt(index).widget()
        position = control.mapTo(panel.header_widget, control.rect().topLeft())
        assert position.x() >= panel.title.mapTo(panel.header_widget, panel.title.rect().topRight()).x()
        assert position.x() + control.width() <= panel.header_widget.width()
        assert control.height() >= (44 if compact else 30)
    if not fullscreen and not compact:
        assert 0 < panel.turn_badge.x() - panel.title.geometry().right() <= 10
    if fullscreen and not compact:
        assert panel.escape_hint.geometry().right() < panel.fullscreen_button.width()
        assert panel.escape_hint.geometry().left() > 0


def test_fullscreen_badge_uses_server_label_and_exit_returns_same_canvas(panel):
    labels = copy.deepcopy(MENU["console"]["labels"])
    labels["fullscreen"] = "Immersive view"
    labels["exit_fullscreen"] = "Return to conversation"
    panel.configure(labels, GEOMETRY[-1]["presentation"])
    canvas = panel.canvas
    canvas.set_components([{"type": "input", "component_id": "draft", "label": "Draft", "value": "initial"}])
    field = canvas.findChild(QLineEdit)
    field.setText("Retained result draft")
    calls = []

    def transition(value):
        calls.append(value)
        panel.fullscreen = value
        panel.apply_state()

    panel.fullscreen_requested.connect(transition)
    panel.fullscreen_button.click()
    settle()
    assert panel.fullscreen_badge.text() == "Immersive view"
    assert panel.fullscreen_button.accessibleName() == "Return to conversation"
    assert panel.canvas is canvas and canvas.findChild(QLineEdit) is field
    assert field.text() == "Retained result draft"
    panel.fullscreen_button.click()
    settle()
    assert calls == [True, False]
    assert panel.canvas is canvas and canvas.findChild(QLineEdit) is field
    assert field.text() == "Retained result draft" and not panel.escape_hint.isVisible()


def test_fullscreen_workspace_actions_precede_exit_and_dispatch_once(panel):
    panel.configure(MENU["console"]["labels"], GEOMETRY[1]["presentation"])
    operations = []
    panel.workspace_requested.connect(operations.append)
    panel.fullscreen = True
    panel.apply_state()
    panel.resize(390, 844)
    settle()
    for index in range(panel.workspace_layout.count()):
        control = panel.workspace_layout.itemAt(index).widget()
        assert control.geometry().right() < panel.fullscreen_button.x()
        control.click()
    assert operations == [action["operation"] for action in WORKSPACE_ACTIONS]


def test_long_preview_keeps_server_height_inside_short_parent_and_collapses(panel):
    panel.configure(MENU["console"]["labels"], GEOMETRY[1]["presentation"])
    panel.canvas.set_components([{"type": "text", "content": f"Result detail {index}"} for index in range(30)])
    panel.resize(390, 250)
    settle()
    assert panel.canvas.height() == GEOMETRY[1]["presentation"]["result_body_max_height"]
    assert panel.preview_button.geometry().bottom() < panel.canvas.height()
    panel.toggle_collapsed()
    settle()
    assert panel.canvas.isHidden() and panel.canvas.minimumHeight() == 0
    panel.toggle_collapsed()
    settle()
    assert panel.canvas.height() == GEOMETRY[1]["presentation"]["result_body_max_height"]
