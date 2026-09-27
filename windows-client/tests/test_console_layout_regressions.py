"""Verify responsive console layout ownership through desktop and drawer transitions.
The cases prevent a visible sidebar from being covered by the main content pane.
"""

import copy

import pytest
from PySide6.QtGui import QColor
from PySide6.QtWidgets import QApplication

from test_console_shell import CONNECTION, GEOMETRY, MENU
from test_console_shell import win as shell_window  # noqa: F401
from test_message_routing import win as window_fixture  # noqa: F401
from astral_client.typography import Paragraph
from astral_client import theme as T


@pytest.mark.parametrize("width", [1440, 1280, 1024, 834, 768, 390, 320])
def test_more_menu_profile_height_and_new_chat_accent_follow_reference(request, monkeypatch, width):
    window = request.getfixturevalue("shell_window")
    shell = window._console_shell
    geometry = next(row for row in GEOMETRY if row["viewport"][0] == width)
    window.resize(*geometry["viewport"])
    window._on_message({"type": "rote_config", "device_profile": {"console": geometry["presentation"]}})
    for _ in range(8):
        QApplication.processEvents()
    popup = shell.more_menu.popup
    positions = []
    monkeypatch.setattr(shell.more_menu, "popup", lambda point: (positions.append(point), popup(point)))
    shell._show_more()
    QApplication.processEvents()
    item_height = 44 if width < 1024 else 39
    actions = shell.more_menu.actions()
    assert all(shell.more_menu.actionGeometry(action).height() == item_height for action in actions)
    assert shell.more_menu.size().toTuple() == (220, item_height * len(actions) + 12)
    compact = geometry["presentation"]["settings_navigation_axis"] == "horizontal"
    anchor = shell.composer if compact else shell.more_button
    right_inset = shell.composer.layout().contentsMargins().right() if compact else 0
    assert anchor.mapFromGlobal(positions[0]).x() + shell.more_menu.width() == anchor.width() - right_inset
    image = shell.new_button.icon().pixmap(18, 18).toImage()
    assert any(image.pixelColor(x, y) == QColor(T.ACCENT)
               for x in range(image.width()) for y in range(image.height()))
    shell.more_menu.hide()


@pytest.mark.parametrize("viewport", [(390, 844), (320, 740)])
def test_initial_phone_landing_fits_without_resize_or_control_interaction(request, viewport):
    window = request.getfixturevalue("window_fixture")
    menu = copy.deepcopy(MENU)
    menu["console"]["catalog"]["categories"] = ["Dashboards", "Research", "Live data", "Utilities"]
    window.client.connection_generation = CONNECTION
    window._continuity.bind_connection(CONNECTION)
    window._on_message({"type": "chrome_menu", "model": menu})
    window.resize(*viewport)
    geometry = next(row for row in GEOMETRY if tuple(row["viewport"]) == viewport)
    window._on_message({"type": "rote_config", "device_profile": {"console": geometry["presentation"]}})
    window.show()
    for _ in range(16):
        QApplication.processEvents()
    shell = window._console_shell
    padding = geometry["presentation"]["content_padding"]
    expected_width = viewport[0] - padding["left"] - padding["right"]
    assert window.width() == viewport[0]
    assert shell.scroll.viewport().width() == viewport[0]
    assert shell.subtitle.width() == shell.scenarios.width() == expected_width
    assert shell.categories_scroll.width() <= expected_width
    assert shell.scenarios.mapTo(window, shell.scenarios.rect().topRight()).x() < viewport[0]


@pytest.mark.parametrize("viewport", [(1440, 900), (1280, 800), (1024, 768)])
def test_desktop_sidebar_and_main_have_nonoverlapping_full_height_bounds(request, viewport):
    window = request.getfixturevalue("shell_window")
    shell = window._console_shell
    desktop = next(case for case in GEOMETRY if tuple(case["viewport"]) == viewport)
    for geometry in (desktop, GEOMETRY[0], desktop):
        window.resize(*geometry["viewport"])
        window._on_message({"type": "rote_config", "device_profile": {"console": geometry["presentation"]}})
        for _ in range(8):
            QApplication.processEvents()
        if geometry is desktop:
            assert shell.sidebar.isVisible()
            assert shell.sidebar.geometry().right() + 1 == shell.main.x()
            assert not shell.sidebar.geometry().intersects(shell.main.geometry())
            assert shell.main.width() + shell.sidebar.width() == viewport[0]
            assert shell.sidebar.height() == shell.main.height() == viewport[1]
        else:
            assert shell.sidebar.isHidden()
            assert shell.main.x() == 0
            assert shell.main.width() == geometry["viewport"][0]


def test_result_card_padding_and_metric_line_height_follow_server_presentation(request):
    window = request.getfixturevalue("shell_window")
    window.canvas.set_components([{"type": "card", "component_id": "result", "content": [
        {"type": "metric", "title": "Total", "value": "42"},
    ]}])
    card = window.canvas.findChildren(Paragraph)[0].parentWidget().parentWidget()
    while not card.property("astralCard"):
        card = card.parentWidget()
    value = next(label for label in card.findChildren(Paragraph) if label.text() == "42")
    assert value.line_height == 33.6
    for width, padding in ((1440, 16), (390, 12), (834, 16)):
        case = next(row for row in GEOMETRY if row["viewport"][0] == width)
        window.resize(*case["viewport"])
        window._on_message({"type": "rote_config", "device_profile": {"console": case["presentation"]}})
        QApplication.processEvents()
        margins = card.layout().contentsMargins()
        assert (margins.left(), margins.top(), margins.right(), margins.bottom()) == (padding,) * 4
        assert value.text() == "42"


@pytest.mark.parametrize("width", [1440, 1280, 1024, 834, 768, 390, 320])
def test_multiline_composer_scrolls_without_covering_the_result(request, width):
    window = request.getfixturevalue("shell_window")
    geometry = next(row for row in GEOMETRY if row["viewport"][0] == width)
    window.resize(*geometry["viewport"])
    window._on_message({"type": "rote_config", "device_profile": {"console": geometry["presentation"]}})
    QApplication.processEvents()
    original_height = window._input.height()
    text = "A long draft with many wrapped words.\n" * 10
    window._input.setText(text)
    QApplication.processEvents()
    assert window._input.height() == original_height == (44 if width < 768 else 50)
    assert window._input.verticalScrollBar().maximum() > 0
    assert window._input.toPlainText() == text
