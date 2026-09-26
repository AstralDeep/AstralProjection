"""Verifies responsive native composition with controls emitted by the shared server builder.
The cases exercise narrow geometry, preserved authority, keyboard focus and bounded feedback.
"""

import copy
import importlib.util
import sys
from pathlib import Path

import pytest
from PySide6.QtCore import Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QLabel, QPushButton

from test_console_shell import CONNECTION, GEOMETRY, MENU
from test_console_shell import win as shell_window  # noqa: F401
from test_message_routing import win as window_fixture  # noqa: F401


ROOT = Path(__file__).resolve().parents[2]
DEVICE = "44444444-4444-4444-8444-444444444444"
SESSION = "55555555-5555-4555-8555-555555555555"
CHAT = "66666666-6666-4666-8666-666666666666"
OTHER_CHAT = "77777777-7777-4777-8777-777777777777"


@pytest.fixture(autouse=True)
def native_style(qapp):
    from astral_client import theme
    from astral_client.app import configure
    stylesheet, font = qapp.styleSheet(), qapp.font()
    loaded = qapp.property("astralOpenSansLoaded")
    palette = dict(theme.PALETTE)
    try:
        configure(qapp)
        yield
    finally:
        if theme.PALETTE != palette:
            theme.apply_theme({"colors": palette})
        qapp.setStyleSheet(stylesheet)
        qapp.setFont(font)
        qapp.setProperty("astralOpenSansLoaded", loaded)


@pytest.fixture
def composer_model():
    spec = importlib.util.spec_from_file_location(
        "server_composer_geometry", ROOT / "backend/webrender/chrome/composer_model.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    yield module
    sys.modules.pop(spec.name)


def frame(model, *, active=False, revision=1, available=True):
    values = dict(revision=revision, connection_generation=CONNECTION, local_device_id=DEVICE,
                  available=available, state="off", reason="ready")
    if active:
        values.update(state="speaking_result", session_id=SESSION, generation=1,
                      media_grant_revision=1, visible_chat_id=CHAT, selected_chat_id=OTHER_CHAT,
                      owner_device=model.VoiceOwner(DEVICE, "windows", 1),
                      foreground_active=True, microphone_enabled=True,
                      chat_context_revision=1, applied_chat_context_revision=1,
                      sensitive_recap_pending=True)
    return model.build_composer_state(model.VoiceComposerContext(**values))


def settle():
    for _ in range(8):
        QApplication.processEvents()


def resize(win, geometry):
    win.resize(*geometry["viewport"])
    win._on_message({"type": "rote_config", "device_profile": {"console": geometry["presentation"]}})
    settle()


@pytest.mark.parametrize("geometry", GEOMETRY)
def test_long_attachment_names_keep_narrow_window_and_remove_targets(request, geometry):
    win = request.getfixturevalue("shell_window")
    for index in range(10):
        win._stage_existing({"attachment_id": f"synthetic-{index}",
                             "filename": f"{index}-" + "long-filename-" * 20 + ".csv"})
    resize(win, geometry)
    win.activateWindow()
    settle()
    assert (win.width(), win.height()) == tuple(geometry["viewport"])
    buttons = win._chips_bar.findChildren(QPushButton)
    assert len(buttons) == 10
    for button in buttons:
        assert button.accessibleName().startswith("Remove attachment ")
        assert button.width() >= 32 and button.height() >= 32
        assert button.width() >= geometry["presentation"]["minimum_control_height"]
        assert button.height() >= geometry["presentation"]["minimum_control_height"]
        button.setFocus()
        settle()
        assert QApplication.focusWidget() is button
        assert button.visibleRegion().boundingRect().contains(button.rect())
    QTest.keyClick(buttons[-1], Qt.Key.Key_Space)
    settle()
    assert len(win._attachments) == 9
    assert win._chips_bar.isAncestorOf(QApplication.focusWidget())


def test_attachment_refresh_retains_focus_and_plain_filename(request):
    win = request.getfixturevalue("shell_window")
    filename = "<b>synthetic.csv</b>"
    win._stage_existing({"attachment_id": "synthetic", "filename": filename})
    resize(win, GEOMETRY[0])
    button = win._chips_bar.findChild(QPushButton)
    button.setFocus()
    settle()
    identity = button.property("attachmentChipId")
    win._render_chips()
    settle()
    assert QApplication.focusWidget().property("attachmentChipId") == identity
    label = win._chips_bar.findChild(QLabel)
    assert label.textFormat() == Qt.TextFormat.PlainText
    assert label.accessibleName() == filename
    assert filename in label.toolTip()
    QTest.keyClick(QApplication.focusWidget(), Qt.Key.Key_Space)
    settle()
    assert win._attachments == [] and QApplication.focusWidget() is win._attach_btn


@pytest.mark.parametrize("geometry", GEOMETRY)
def test_category_labels_fit_styled_controls_including_desktop_zero_minimum(request, geometry):
    win = request.getfixturevalue("shell_window")
    resize(win, geometry)
    shell = win._console_shell
    for control in shell.categories_body.findChildren(QPushButton):
        shell.categories_scroll.ensureWidgetVisible(control, 0, 0)
        settle()
        assert control.visibleRegion().boundingRect().contains(control.rect())
        assert control.height() >= control.sizeHint().height()


@pytest.mark.parametrize("geometry", [GEOMETRY[0], GEOMETRY[1], GEOMETRY[5]])
def test_active_server_voice_controls_fit_without_clamping_window(request, composer_model, geometry):
    win = request.getfixturevalue("shell_window")
    voice = win._voice_widget
    voice.action_requested.disconnect()
    actions = []
    voice.action_requested.connect(actions.append)
    win._input.setText("Unsent typed draft")
    assert voice.apply_composer_state(frame(composer_model, active=True), CONNECTION)
    resize(win, geometry)
    assert win.width() == geometry["viewport"][0]
    assert len(voice._buttons) == 6
    minimum = geometry["presentation"]["minimum_control_height"]
    assert win._input.width() >= 80
    for control in (win._attach_btn, win._console_shell.more_button, win._send_btn):
        assert control.isVisible() and control.height() >= minimum
        assert win._composer.rect().contains(control.geometry())
    for button in voice._buttons.values():
        assert button.isVisible() and button.isEnabled()
        assert not button.icon().isNull()
        assert button.height() >= minimum
        assert voice.rect().contains(button.geometry())
        assert button.accessibleName()
        button.setFocus()
        QTest.keyClick(button, Qt.Key.Key_Space)
    assert actions == [button.property("voiceAction") for button in voice._buttons.values()]
    assert win._input.text() == "Unsent typed draft"
    assert voice.status_label.isVisible()
    assert win._composer.rect().contains(voice.geometry())
    assert win._composer.voice_stacked == (geometry["viewport"][0] < 500)


def test_idle_and_ended_voice_return_to_single_composer_row(request, composer_model):
    win = request.getfixturevalue("shell_window")
    voice = win._voice_widget
    resize(win, GEOMETRY[1])
    assert voice.apply_composer_state(frame(composer_model), CONNECTION)
    settle()
    assert not win._composer.voice_stacked
    assert voice.geometry().center().y() == win._input.geometry().center().y()
    microphone = voice._buttons["voice-start"]
    microphone_center = microphone.mapTo(win._composer, microphone.rect().center()).y()
    attachment_center = win._attach_btn.mapTo(win._composer, win._attach_btn.rect().center()).y()
    assert abs(microphone_center - attachment_center) <= 1
    assert not voice.status_label.isVisible()
    assert voice.apply_composer_state(frame(composer_model, active=True, revision=2), CONNECTION)
    settle()
    assert win._composer.voice_stacked
    assert voice.apply_composer_state(frame(composer_model, revision=3), CONNECTION)
    settle()
    assert not win._composer.voice_stacked
    assert win.width() == 390
    assert len(voice._buttons) == 1
    microphone = voice._buttons["voice-start"]
    assert abs(microphone.mapTo(win._composer, microphone.rect().center()).y() - attachment_center) <= 1


def test_active_voice_reflows_on_resize_and_feedback_remains_readable(request, composer_model):
    win = request.getfixturevalue("shell_window")
    voice = win._voice_widget
    assert voice.apply_composer_state(frame(composer_model, active=True), CONNECTION)
    resize(win, GEOMETRY[5])
    assert not win._composer.voice_stacked
    resize(win, GEOMETRY[0])
    assert win._composer.voice_stacked
    voice.set_speech_error("Audio output disconnected. Reconnect it or use typed chat.")
    voice.set_transcript("A long pending transcript with readable wrapping. " * 120, False)
    settle()
    assert win.width() == 320
    assert voice.feedback_scroll.isVisible()
    assert voice.feedback_scroll.height() <= 192
    assert voice.feedback_scroll.verticalScrollBar().maximum() > 0
    assert voice.request_notice_label.isVisible()
    assert "Reconnect" in voice.request_notice_label.text()
    assert voice.status_label.isVisible()
    assert win._composer.rect().contains(voice.geometry())
    assert win._input.isVisible() and win._send_btn.isEnabled()
    voice.clear_request_notice()
    voice.set_transcript("", True)
    resize(win, GEOMETRY[5])
    assert not win._composer.voice_stacked


def test_voice_revision_keeps_focus_and_respects_composer_denial(request, composer_model):
    win = request.getfixturevalue("shell_window")
    voice = win._voice_widget
    assert voice.apply_composer_state(frame(composer_model, active=True), CONNECTION)
    resize(win, GEOMETRY[0])
    voice._buttons["voice-mute"].setFocus()
    previous = dict(voice._buttons)
    assert voice.apply_composer_state(frame(composer_model, active=True, revision=2), CONNECTION)
    settle()
    assert all(button.isHidden() and button.parent() is None for button in previous.values())
    assert QApplication.focusWidget() is voice._buttons["voice-mute"]
    win._set_composer_enabled(False)
    assert voice.apply_composer_state(frame(composer_model, active=True, revision=3), CONNECTION)
    assert all(not control.isEnabled() for control in voice._buttons.values())
    win._set_composer_enabled(True)
    assert all(control.isEnabled() for control in voice._buttons.values())
    denied = frame(composer_model, revision=4, available=False)
    assert voice.apply_composer_state(denied, CONNECTION)
    settle()
    assert not voice._buttons["voice-start"].isEnabled()


def test_loading_empty_suspended_and_unknown_icon_preserve_accessible_fallback(request, composer_model):
    from astral_client.console_widgets import ResponsiveComposer
    from astral_client.voice import VoiceComposerWidget
    pending = ResponsiveComposer()
    pending.set_control_minimum(44)
    pending.reflow()
    empty = VoiceComposerWidget()
    assert empty.inline_width() == 0
    empty.set_voice_status("not-a-voice-state", "Try typed chat")
    assert empty.status_label.text() == "Voice: error"
    empty.close()
    pending.close()
    win = request.getfixturevalue("shell_window")
    voice = win._voice_widget
    resize(win, GEOMETRY[0])
    assert voice.apply_composer_state(frame(composer_model, active=True), CONNECTION)
    settle()
    voice._buttons["voice-mute"].setFocus()
    suspended = frame(composer_model, active=True, revision=2)
    suspended["voice"].update(state="suspended", foreground_active=False, microphone_enabled=False)
    for control in suspended["voice"]["controls"]:
        control["visible"] = False
    assert voice.apply_composer_state(suspended, CONNECTION)
    settle()
    assert voice._buttons == {}
    assert voice.status_label.isVisible()
    assert win.width() == 320 and win._input.isEnabled()
    fallback = frame(composer_model, revision=3)
    fallback["voice"]["controls"][0]["icon"] = "future-icon"
    assert voice.apply_composer_state(fallback, CONNECTION)
    settle()
    start = voice._buttons["voice-start"]
    assert start.text() == start.accessibleName() == "Start voice conversation"
    assert not start.property("iconOnly")
    assert start.height() >= 44
    voice.restyle()
    assert voice._buttons["voice-start"].text() == "Start voice conversation"
    assert not voice.apply_composer_state(fallback, CONNECTION)
    assert not voice.apply_composer_state(frame(composer_model, revision=4), "wrong-connection")


def test_voice_focus_returns_to_remaining_control_when_previous_action_disappears(request, composer_model):
    win = request.getfixturevalue("shell_window")
    voice = win._voice_widget
    assert voice.apply_composer_state(frame(composer_model, active=True), CONNECTION)
    resize(win, GEOMETRY[1])
    voice._buttons["voice-mute"].setFocus()
    assert voice.apply_composer_state(frame(composer_model, revision=2), CONNECTION)
    settle()
    assert QApplication.focusWidget() is voice._buttons["voice-start"]
    assert not win._composer.voice_stacked


def test_voice_icons_match_authoritative_web_paths():
    import re
    from astral_client import icons
    source = (ROOT / "backend/webrender/static/client.js").read_text(encoding="utf-8")
    block = source.split("var VOICE_ICONS = {", 1)[1].split("\n  };", 1)[0]
    for name, markup in re.findall(r'"([a-z-]+)": \'([^\']+)\'', block):
        path = markup.split(">", 1)[1].removesuffix("</svg>")
        assert path in icons.svg_markup(name, "#FFFFFF")


@pytest.mark.parametrize("geometry", GEOMETRY)
def test_overflowing_categories_keep_complete_touch_targets_visible(request, geometry):
    win = request.getfixturevalue("shell_window")
    resize(win, geometry)
    menu = copy.deepcopy(MENU)
    menu["console"]["catalog"]["categories"] += [f"Category {index}" for index in range(12)]
    win._on_message({"type": "chrome_menu", "model": menu})
    settle()
    shell = win._console_shell
    viewport = shell.categories_scroll.viewport()
    assert shell.categories_scroll.horizontalScrollBar().isVisible()
    for button in shell.categories_body.findChildren(QPushButton):
        top = button.mapTo(viewport, button.rect().topLeft()).y()
        assert top >= 0
        assert top + button.height() <= viewport.height()
        assert button.height() >= geometry["presentation"]["minimum_control_height"]
        assert button.height() >= button.sizeHint().height()


def test_new_result_controls_and_fullscreen_keep_targets_and_keyboard_scope(request):
    win = request.getfixturevalue("shell_window")
    resize(win, GEOMETRY[0])
    win.canvas.set_components([{"type": "action_group", "component_id": "actions", "buttons": [
        {"label": "Synthetic action", "action": "example"},
        {"label": "Unavailable action", "action": "unavailable", "disabled": True}]}])
    win._sync_console_conversation()
    settle()
    shell = win._console_shell
    actions = win.canvas._by_id["actions"].findChildren(QPushButton)
    assert actions and all(button.height() >= 44 for button in actions)
    assert not next(button for button in actions if button.text() == "Unavailable action").isEnabled()
    shell.results.preview_button.setFocus()
    shell.set_fullscreen(True)
    settle()
    assert not shell.main.isEnabled() and not shell.sidebar.isEnabled()
    for _ in range(12):
        QTest.keyClick(QApplication.focusWidget(), Qt.Key.Key_Tab)
        settle()
        focus = QApplication.focusWidget()
        assert not shell.main.isAncestorOf(focus)
        assert not shell.sidebar.isAncestorOf(focus)
    shell.dismiss()
    settle()
    assert shell.main.isEnabled() and shell.sidebar.isEnabled()
    assert QApplication.focusWidget() == shell.results.preview_button
    assert not next(button for button in actions if button.text() == "Unavailable action").isEnabled()
