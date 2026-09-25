"""Checks fullscreen focus after Qt reparents the retained native result canvas.
Tests process queued events and keyboard cycles using the production stylesheet.
"""

import copy

import pytest
from PySide6.QtCore import Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QLineEdit

from test_composer_geometry import native_style, settle  # noqa: F401
from test_console_shell import GEOMETRY, MENU
from test_console_shell import win as shell_window  # noqa: F401
from test_message_routing import win as window_fixture  # noqa: F401


@pytest.mark.parametrize("geometry", [GEOMETRY[1], GEOMETRY[6]])
@pytest.mark.parametrize("opener_name", ["preview_button", "fullscreen_button", "preview_cover"])
def test_fullscreen_escape_restores_visible_opener_after_tab_cycle(request, geometry, opener_name):
    window = request.getfixturevalue("shell_window")
    shell = window._console_shell
    window.resize(*geometry["viewport"])
    window._on_message({"type": "rote_config", "device_profile": {"console": geometry["presentation"]}})
    menu = copy.deepcopy(MENU)
    menu["console"]["catalog"]["categories"] += [f"Category {index}" for index in range(12)]
    window._on_message({"type": "chrome_menu", "model": menu})
    settle()
    window._on_message({"type": "chrome_menu", "model": copy.deepcopy(MENU)})
    window.canvas.set_components([
        {"type": "action_group", "component_id": "actions", "buttons": [
            {"label": "Synthetic action", "action": "example"},
            {"label": "Unavailable action", "action": "unavailable", "disabled": True}]},
        {"type": "input", "component_id": "field", "label": "Value", "value": "initial"},
    ])
    field = window.canvas._by_id["field"].findChild(QLineEdit)
    field.setText("Retained edited value")
    window._input.setText("Retained composer draft")
    identity = window.canvas._by_id["field"]
    settle()
    shell.search.setFocus()
    opener = getattr(shell.results, opener_name)
    opener.click()
    settle()
    assert shell.results.fullscreen
    assert window.canvas._by_id["field"] is identity
    for _ in range(12):
        focus = QApplication.focusWidget()
        assert focus is not None and shell.results.isAncestorOf(focus)
        QTest.keyClick(focus, Qt.Key.Key_Tab)
        settle()
    QTest.keyClick(QApplication.focusWidget(), Qt.Key.Key_Escape)
    settle()
    expected = shell.results.fullscreen_button if opener_name == "preview_cover" else opener
    assert not shell.results.fullscreen
    assert QApplication.focusWidget() is expected
    assert expected.isVisible() and expected.isEnabled()
    assert window.canvas._by_id["field"] is identity
    assert field.text() == "Retained edited value"
    assert window._input.text() == "Retained composer draft"


def test_direct_fullscreen_transition_preserves_keyboard_preview_focus(request):
    window = request.getfixturevalue("shell_window")
    shell = window._console_shell
    window.canvas.set_components([{"type": "input", "component_id": "field", "label": "Value"}])
    settle()
    shell.results.preview_button.setFocus()
    shell.set_fullscreen(True)
    settle()
    shell.dismiss()
    settle()
    assert QApplication.focusWidget() is shell.results.preview_button
