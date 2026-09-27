"""Check agent settings rows against the shared desktop and phone reference geometry.
The cases exercise wrapping, rendering and action preservation through the native adapter.
"""

from copy import deepcopy

import pytest
from PySide6.QtCore import Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QLabel, QPushButton, QVBoxLayout, QWidget

from astral_client import theme as T
from astral_client.renderer import RenderContext
from astral_client.surface_widgets import adapt_settings_component


AGENTS = (
    ("Claude Connectors Agent", "Builds the office documents you ask for — spreadsheets, decks, letters, email drafts and pitch templates — and more."),
    ("Dice Roller", "Rolls dice and reports every roll and the total — the smallest honest end-to-end test of routing, permissions and rendering."),
)


def agent_component(index=0):
    title, description = AGENTS[index]
    return {
        "type": "card", "title": title, "component_id": "agent-row", "content": [
            {"type": "container", "direction": "row", "children": [
                {"type": "badge", "label": "Yours", "variant": "accent"},
                {"type": "badge", "label": "Public", "variant": "default"},
                {"type": "badge", "label": "Connected", "variant": "success"},
            ]},
            {"type": "text", "content": description},
            {"type": "container", "direction": "row", "children": [
                {"type": "button", "label": "Open", "action": "chrome_open", "payload": {
                    "surface": "agents", "params": {"agent_id": "agent", "tab": "mine"},
                }},
                {"type": "button", "label": "Disable", "action": "chrome_agent_enabled", "payload": {
                    "agent_id": "agent", "tab": "mine", "enabled": False,
                }},
            ]},
        ],
    }


@pytest.fixture
def render_row(qapp):
    original_font, original_style = qapp.font(), qapp.styleSheet()
    loaded = qapp.property("astralOpenSansLoaded")
    qapp.setProperty("astralOpenSansLoaded", False)
    assert T.configure_fonts(qapp)
    qapp.setStyleSheet(T.APP_STYLESHEET)
    hosts = []

    def render(source, width, sent=None):
        host = QWidget()
        layout = QVBoxLayout(host)
        layout.setContentsMargins(0, 0, 0, 0)
        row = adapt_settings_component("agents", {}, source, RenderContext(
            lambda *args: sent.append(args) if sent is not None else None))
        layout.addWidget(row)
        layout.addStretch(1)
        host.resize(width, 800)
        host.show()
        qapp.processEvents()
        hosts.append(host)
        return row

    yield render
    for host in hosts:
        host.close()
        host.deleteLater()
    qapp.setFont(original_font)
    qapp.setStyleSheet(original_style)
    qapp.setProperty("astralOpenSansLoaded", loaded)


@pytest.mark.parametrize("width,index,height,title_lines,badge_rows", [
    (682, 0, 81, 1, (0, 0)),
    (682, 1, 81, 1, (0, 0)),
    (358, 0, 141, 1, (28, 28)),
    (358, 1, 113, 1, (0, 0)),
    (288, 0, 245, 3, (68, 68)),
    (288, 1, 205, 1, (28, 28)),
])
def test_agent_rows_match_reference_wrapping_and_height(render_row, width, index, height, title_lines, badge_rows):
    row = render_row(agent_component(index), width)
    title = row.findChild(QLabel, "settingsAgentTitle")
    summary = row.findChild(QLabel, "settingsAgentDescription")
    badges = row.findChildren(QLabel, "settingsAgentBadge")
    assert row.size().toTuple() == (width, height)
    assert title.heightForWidth(title.width()) == title_lines * 20
    assert [badge.width() for badge in badges] == [41, 43]
    assert tuple(badge.y() for badge in badges) == badge_rows
    assert summary.height() == summary.heightForWidth(summary.width())
    assert summary.height() % 16 == 0
    assert title.textFormat() == summary.textFormat() == Qt.TextFormat.PlainText
    rendered = summary.grab().toImage()
    assert any(rendered.pixelColor(x, y).alpha() and rendered.pixelColor(x, y).lightness() > 80
               for y in range(rendered.height()) for x in range(rendered.width()))


def test_narrow_row_preserves_click_targets_context_and_full_description(render_row):
    source = agent_component()
    original = deepcopy(source)
    sent = []
    row = render_row(source, 288, sent)
    opener = row.findChild(QPushButton, "settingsAgentOpen")
    toggle = row.findChild(QPushButton, "settingsAgentToggle")
    title = row.findChild(QLabel, "settingsAgentTitle")
    assert opener.accessibleDescription() == original["content"][1]["content"]
    assert opener.toolTip() == opener.accessibleDescription()
    assert row.property("component_id") == "agent-row"
    QTest.mouseClick(opener, Qt.MouseButton.LeftButton, pos=title.mapTo(opener, title.rect().center()))
    QTest.mouseClick(toggle, Qt.MouseButton.LeftButton)
    assert sent == [(action["action"], action["payload"]) for action in original["content"][2]["children"]]
    sent[0][1]["params"]["agent_id"] = "changed"
    opener.click()
    assert sent[-1][1]["params"]["agent_id"] == "agent"
    assert source == original


@pytest.mark.parametrize("disable_row", [True, False])
def test_narrow_row_disabled_controls_do_not_emit(render_row, disable_row):
    source = agent_component()
    if disable_row:
        source["disabled"] = True
    else:
        for action in source["content"][2]["children"]:
            action["disabled"] = True
    sent = []
    row = render_row(source, 288, sent)
    for button in row.findChildren(QPushButton):
        assert not button.isEnabled()
        button.click()
    assert not sent
