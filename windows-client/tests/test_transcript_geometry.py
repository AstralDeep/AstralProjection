"""Check narrow result and transcript geometry through native resize cycles.
Semantic message metadata comes only from the shared labels and persisted timestamps.
"""

import copy

import pytest
from PySide6.QtCore import QDateTime, QEvent, Qt
from PySide6.QtGui import QTextDocument
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QLabel, QPushButton

from astral_client import app as appmod, theme
from astral_client.app import ChatRail, MainWindow, configure
from astral_client.protocol import SemanticMessage, SemanticPart
from test_composer_geometry import settle
from test_console_shell import CHAT, CONNECTION, GEOMETRY, MENU
from test_message_routing import _FakeClient
from test_result_presentation import WORKSPACE_ACTIONS


PROMPT = "Roll exactly six six-sided dice and show the normalized results."
ANSWER = "Rolled 6d6: **5, 3, 3, 2, 2, 1** — total **16** pips (normalized range 6–36, so 16 is just under the median)."
STAMP = "2026-09-26T14:41:00Z"


@pytest.fixture
def window(qapp, monkeypatch):
    stylesheet, font = qapp.styleSheet(), qapp.font()
    loaded, palette = qapp.property("astralOpenSansLoaded"), dict(theme.PALETTE)
    configure(qapp)
    monkeypatch.setattr(appmod, "OrchestratorClient", _FakeClient)
    monkeypatch.setattr(MainWindow, "_start_integrity_check", lambda self: None)
    monkeypatch.setattr(MainWindow, "_init_workspace", lambda self: None)
    window = MainWindow("ws://127.0.0.1:9/ws", "dev-token")
    window.client.connection_generation = CONNECTION
    window._resume_store.storage_key = "transcript-synthetic-owner"
    window._continuity.bind_connection(CONNECTION)
    window._on_message({"type": "chrome_menu", "model": copy.deepcopy(MENU)})
    window._on_message({"type": "rote_config", "device_profile": {"console": GEOMETRY[5]["presentation"]}})
    window.show()
    settle()
    yield window
    window.close()
    window.deleteLater()
    QApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
    if theme.PALETTE != palette:
        theme.apply_theme({"colors": palette})
    qapp.setStyleSheet(stylesheet)
    qapp.setFont(font)
    qapp.setProperty("astralOpenSansLoaded", loaded)


def messages():
    return [SemanticMessage("user", "user", STAMP, (SemanticPart("text", text=PROMPT),), ()),
            SemanticMessage("assistant", "assistant", STAMP, (SemanticPart("text", text=ANSWER),), ())]


def test_narrow_result_and_bubbles_preserve_content_and_all_actions_across_resize(window):
    window._set_active_chat(CHAT, persist=False)
    window.canvas.set_components([{"type": "card", "component_id": "dice", "title": "Dice results",
                                   "content": [{"type": "text", "content": "Total: 16"}]}])
    window.rail.replace_semantic(messages(), window.canvas.ctx)
    shell = window._console_shell
    panel = shell.results
    panel.set_workspace_actions(WORKSPACE_ACTIONS)
    original_canvas = window.canvas._by_id["dice"]
    wraps = [window.rail._lay.itemAt(index).widget() for index in range(2)]
    user, assistant = [wrap._conversation_bubble for wrap in wraps]
    for width, height in [(1440, 900), (320, 740), (1440, 900)]:
        geometry = next(case for case in GEOMETRY if case["viewport"] == [width, height])
        window.resize(width, height)
        window._on_message({"type": "rote_config", "device_profile": {"console": geometry["presentation"]}})
        panel.set_metadata("Dice Roller", 1)
        settle()
        assert window.width() == width
        assert panel.width() <= shell.scroll.viewport().width()
        for control in panel.header_widget.findChildren(QPushButton):
            if control.isVisible():
                origin = control.mapTo(window, control.rect().topLeft())
                assert 0 <= origin.x() < width
                assert origin.x() + control.width() <= width
        for bubble in (user, assistant):
            origin = bubble.mapTo(window, bubble.rect().topLeft())
            assert 0 <= origin.x() < width
            assert origin.x() + bubble.width() <= width
            assert bubble.minimumWidth() == 0
        assert assistant.width() == min(window.rail.width(), 708)
        assert user.findChild(QLabel).property("conversationText") == PROMPT
        assert assistant.findChild(QLabel).property("conversationText") == ANSWER
        assert window.canvas._by_id["dice"] is original_canvas
        assert panel.title.accessibleName() == "Dice Roller Interface"
        assert panel.title.toolTip() == panel.title.accessibleName()
        if width == 320:
            assert panel.title.text().endswith("…")
            assert panel.title.text() != panel.title.accessibleName()
            assert user.width() <= round(window.rail.width() * 0.92)
        else:
            assert panel.title.text() == panel.title.accessibleName()


def test_semantic_metadata_uses_shared_turn_label_and_server_time_only(window):
    rail = window.rail
    rail.replace_semantic(messages() + [SemanticMessage(
        "second-user", "user", "2026-09-26T15:42:00Z", (SemanticPart("text", text="Again"),), ())], window.canvas.ctx)
    rail.configure_console({"turn_singular": "runde"})
    settle()
    turns = rail.findChildren(QLabel, "conversationTurn")
    times = rail.findChildren(QLabel, "conversationTime")
    assert [label.text() for label in turns] == ["Runde 1", "Runde 2"]
    assert [label.accessibleName() for label in times] == [STAMP, "2026-09-26T15:42:00Z"]
    for label in times:
        date = QDateTime.fromString(label.accessibleName(), Qt.DateFormat.ISODateWithMs)
        assert label.text() == date.toLocalTime().toString("HH:mm")
    rail.clear()
    rail.add("user", "Pending local text")
    settle()
    assert not any(label.isVisible() for label in rail.findChildren(QLabel, "conversationTime"))
    assert not any(label.text() for label in rail.findChildren(QLabel, "conversationTime"))


def test_metadata_waits_for_shared_labels_without_inventing_server_time(window):
    rail = ChatRail()
    rail.setParent(window)
    rail.use_feed_layout()
    rail.replace_semantic(messages(), window.canvas.ctx)
    wrap = rail._lay.itemAt(0).widget()
    assert wrap._metadata.isHidden()
    rail.configure_console({"turn_singular": "turn"})
    assert not wrap._metadata.isHidden()
    wrap._conversation_bubble.setProperty("conversationCreatedAt", "")
    rail.configure_console({"turn_singular": "turn"})
    assert wrap._metadata.isHidden()


def test_assistant_line_boxes_keep_native_markdown_selection_and_accessibility(window, qapp):
    window.rail.replace_semantic(messages(), window.canvas.ctx)
    bubble = window.rail._lay.itemAt(1).widget()._conversation_bubble
    label = bubble.findChild(QLabel)
    document = QTextDocument()
    document.setHtml(label.text())
    assert document.firstBlock().blockFormat().lineHeight() == pytest.approx(24.288)
    assert 'font-weight:700' in label.text()
    assert label.accessibleName() == document.toPlainText()
    assert label.textInteractionFlags() & Qt.TextInteractionFlag.TextSelectableByMouse
    assert label.textInteractionFlags() & Qt.TextInteractionFlag.TextSelectableByKeyboard
    window.rail.show()
    settle()
    label.setFocus()
    QTest.keyClick(label, Qt.Key.Key_A, Qt.KeyboardModifier.ControlModifier)
    QTest.keyClick(label, Qt.Key.Key_C, Qt.KeyboardModifier.ControlModifier)
    assert qapp.clipboard().text() == document.toPlainText()
