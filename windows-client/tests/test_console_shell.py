"""Exercises the native console against shared models and geometry fixtures.
The tests verify action authority, correlated settings, canvas identity and keyboard navigation.
"""

import copy
import json
from pathlib import Path

import pytest
from PySide6.QtCore import Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QLabel, QLineEdit, QPushButton

from test_message_routing import win as window_fixture  # noqa: F401


ROOT = Path(__file__).resolve().parents[2]
MENU = json.loads((ROOT / "contracts/fixtures/console/chrome-console.json").read_text(encoding="utf-8"))
GEOMETRY = json.loads((ROOT / "contracts/fixtures/console/rote-console.json").read_text(encoding="utf-8"))["cases"]
CONNECTION = "33333333-3333-4333-8333-333333333333"
CHAT = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"
SELECTION = {"version": 1, "agent": None, "skills": [], "notes": [{"note_id": OTHER, "revision": 1}]}


@pytest.fixture
def win(request):
    window = request.getfixturevalue("window_fixture")
    window.client.connection_generation = CONNECTION
    window._resume_store.storage_key = "console-synthetic-owner"
    window._continuity.bind_connection(CONNECTION)
    window._on_message({"type": "chrome_menu", "model": copy.deepcopy(MENU)})
    window._on_message({"type": "rote_config", "device_profile": {"console": GEOMETRY[5]["presentation"]}})
    window.show()
    QApplication.processEvents()
    yield window


def controls(shell, property_name):
    return [control for control in shell.findChildren(QPushButton) if control.property(property_name) is not None]


def guidance_ready(win):
    sent = []
    retired = []
    win.client.send_current_guidance = lambda action, payload, generation, **kwargs: (
        sent.append((action, payload, generation, kwargs["is_current"])) or True)
    win.client.retire_guidance = retired.append
    return sent, retired


def surface(generation, **extra):
    return {"type": "chrome_surface", "surface_key": "guidance", "request_generation": generation,
            "title": "Advanced settings", "mode": "replace", "components": [], **extra}


def test_console_waits_for_both_validated_models(request):
    win = request.getfixturevalue("window_fixture")
    win._on_message({"type": "rote_config", "device_profile": {"console": GEOMETRY[0]["presentation"]}})
    assert win._console_shell is None
    win._on_message({"type": "chrome_menu", "model": MENU})
    assert win._console_shell is not None
    assert win._console_shell.presentation["navigation_mode"] == "drawer"


def test_connection_completion_refreshes_the_latest_logical_viewport(win):
    snapshots = []
    win.client.update_device = lambda value: snapshots.append(value)
    win.resize(834, 1194)
    win._on_status("connected")
    assert snapshots[-1]["viewport_width"] == 834
    assert snapshots[-1]["viewport_height"] == 1194
    assert snapshots[-1]["console_contract"] == "console/v2"
    win._on_status("device_update_failed")
    assert "resize the window to retry" in win._banner.text()
    assert win._banner_kind == "warning"


@pytest.mark.parametrize("geometry", GEOMETRY)
def test_rote_geometry_drives_columns_sidebar_and_keyboard_drawer(win, geometry):
    win.resize(*geometry["viewport"])
    win._on_message({"type": "rote_config", "device_profile": {"console": geometry["presentation"]}})
    QApplication.processEvents()
    shell = win._console_shell
    assert win.width() == geometry["viewport"][0]
    assert shell.sidebar.width() == round(geometry["presentation"]["sidebar_width"])
    assert shell.presentation["scenario_columns"] == geometry["presentation"]["scenario_columns"]
    assert shell.feed_layout.contentsMargins().left() == geometry["presentation"]["content_padding"]["left"]
    if geometry["presentation"]["navigation_mode"] == "drawer":
        win._input.setFocus()
        shell.toggle_drawer()
        assert shell.drawer_open and shell.sidebar.isVisible()
        assert shell.sidebar.isAncestorOf(QApplication.focusWidget())
        assert not shell.main.isEnabled()
        shell.dismiss()
        assert not shell.drawer_open and not shell.sidebar.isVisible()
        assert QApplication.focusWidget() == win._input
        assert shell.main.isEnabled()
        shell.toggle_drawer()
        shell.toggle_drawer()
        assert not shell.drawer_open
    else:
        assert shell.sidebar.isVisible() and not shell.drawer_button.isVisible()


@pytest.mark.parametrize("geometry", GEOMETRY)
def test_dashboard_navigation_survives_rote_and_catalog_refresh(win, geometry):
    shell = win._console_shell
    win.active_chat = CHAT
    win._sync_console_conversation()
    assert shell.landing.isHidden()
    shell.show_dashboard()
    win.resize(*geometry["viewport"])
    win._on_message({"type": "rote_config", "device_profile": {"console": geometry["presentation"]}})
    updated = copy.deepcopy(MENU)
    updated["console"]["labels"]["title"] = "Updated dashboard"
    win._on_message({"type": "chrome_menu", "model": updated})
    assert not shell.landing.isHidden()
    assert shell.rail.isHidden() and shell.results.isHidden()
    assert win.active_chat == CHAT
    win._sync_console_conversation()
    assert shell.landing.isHidden() and not shell.rail.isHidden()


def test_dynamic_controls_retain_shared_touch_target_after_filter_and_refresh(win):
    shell = win._console_shell
    presentation = GEOMETRY[0]["presentation"]
    win._on_message({"type": "rote_config", "device_profile": {"console": presentation}})
    shell.select_category(MENU["console"]["catalog"]["scenarios"][0]["category"])
    targets = controls(shell, "scenarioId")
    assert targets and all(item.minimumHeight() >= presentation["minimum_control_height"] for item in targets)
    updated = copy.deepcopy(MENU)
    updated["console"]["labels"]["title"] = "Refreshed catalog"
    win._on_message({"type": "chrome_menu", "model": updated})
    shell.set_history([{"id": CHAT, "title": "Synthetic conversation"}])
    targets = [*controls(shell, "scenarioId"), *controls(shell, "category"),
               *shell.history_body.findChildren(QPushButton)]
    assert all(item.minimumHeight() >= presentation["minimum_control_height"] for item in targets)


def test_scenario_load_preserves_draft_until_run_dispatches_once(win):
    sent = []
    win.client.send_chat = lambda message, chat_id, **kwargs: sent.append((message, kwargs))
    shell = win._console_shell
    row = MENU["console"]["catalog"]["scenarios"][0]
    load = next(item for item in controls(shell, "scenarioId") if not item.property("runScenario"))
    load.click()
    assert win._input.text() == row["prompt"] and sent == []
    win._input.setText("A different unsent prompt")
    run = next(item for item in controls(shell, "scenarioId") if item.property("runScenario"))
    run.click()
    assert len(sent) == 1 and sent[0][0] == row["prompt"]
    assert win._input.text() == row["prompt"]
    win._scenario("unlisted", True)
    win._set_composer_enabled(False)
    win._scenario(row["id"], True)
    win._send()
    win._emit("chat_message", {"message": "blocked"})
    assert len(sent) == 1
    win._set_composer_enabled(True)
    assert win._input.placeholderText() == MENU["console"]["labels"]["message_placeholder"]


def test_categories_agent_search_and_intro_use_shared_catalog(win):
    shell = win._console_shell
    shell.select_category("Utilities")
    assert shell.scenario_layout.count() == 1
    shell.select_category("missing")
    assert shell.scenario_layout.count() == 0
    shell.select_category(None)
    assert shell.scenario_layout.count() == 1
    shell.search.setText("no matching agent")
    assert controls(shell, "agentId") == []
    shell.search.setText("DICE")
    agent = controls(shell, "agentId")[0]
    assert agent.accessibleDescription().startswith("ready")
    agent.click()
    assert win.client.sent[-1] == ("chrome_open", {"surface": "agent_intro", "params": {"agent_id": "dice"}})


@pytest.mark.parametrize("geometry", [GEOMETRY[0], GEOMETRY[5]])
def test_agent_cards_keep_labels_inside_visible_bounds_after_rote_resize(win, geometry):
    win.resize(*geometry["viewport"])
    win._on_message({"type": "rote_config", "device_profile": {"console": geometry["presentation"]}})
    shell = win._console_shell
    if geometry["presentation"]["navigation_mode"] == "drawer":
        shell.toggle_drawer()
    QApplication.processEvents()
    card = controls(shell, "agentId")[0]
    assert card.height() >= 90
    for child in card.findChildren(QLabel):
        assert child.isVisible()
        assert card.rect().contains(child.geometry())
        assert child.height() >= child.fontMetrics().height()
    shell.history_new_button.click()
    assert not shell.drawer_open and win.active_chat is None


def test_empty_catalog_and_malformed_update_do_not_keep_actionable_catalog(win):
    model = copy.deepcopy(MENU)
    model["console"]["catalog"] = {"categories": [], "scenarios": [], "agents": []}
    win._on_message({"type": "chrome_menu", "model": model})
    assert win._console_shell.scenario_layout.count() == 0
    assert controls(win._console_shell, "agentId") == []
    model["console"]["version"] = 91
    win._on_message({"type": "chrome_menu", "model": model})
    assert win._console_model is None and not win._console_shell.isEnabled()
    win._scenario("dice", True)
    win._console_open_surface("llm", "LLM", {})
    assert win.client.sent == []
    win._accept_console(None)
    win._on_message({"type": "rote_config", "device_profile": {"console": {"version": 2}}})
    win._on_message({"type": "chrome_menu", "model": MENU})
    assert win._console_shell.isEnabled()


def test_collapsible_history_loads_server_identity(win):
    shell = win._console_shell
    shell.history_button.click()
    assert win.client.sent[-1] == ("get_history", {})
    win._on_message({"type": "history_list", "chats": [{"id": CHAT, "title": "My conversation"}, None, {}]})
    item = shell.history_body.findChild(QPushButton)
    assert item.text() == "My conversation"
    item.click()
    assert win.active_chat == CHAT
    assert win.client.sent[-1][0] == "load_chat"
    shell.history_button.click()
    assert not shell.history_scroll.isVisible()
    win._open_history()
    assert shell.history_scroll.isVisible()
    shell.set_history(None)
    assert shell.history_layout.count() == 1


def test_more_menu_background_and_server_settings_params(win):
    shell = win._console_shell
    actions = shell.more_menu.actions()
    assert [action.text() for action in actions] == [item["label"] for item in MENU["console"]["composer_actions"]]
    actions[0].trigger()
    assert win._background_mode
    sent, _ = guidance_ready(win)
    actions[1].trigger()
    assert sent[-1][:2] == ("chrome_open", {"surface": "guidance", "params": {"view": "selection"}})
    assert win._surface_dialog._params == {"view": "selection"}
    menu_action = next(action for action in shell.account_menu.actions() if action.text() == "Private notes")
    menu_action.trigger()
    assert sent[-1][1]["params"] == {"mode": "list"}


def test_fullscreen_collapse_and_escape_keep_one_canvas_and_edited_component(win):
    component = {"type": "input", "component_id": "field", "label": "Value", "name": "value", "value": "initial"}
    win.canvas.set_components([component])
    shell = win._console_shell
    field = win.canvas._by_id["field"].findChild(QLineEdit)
    field.setText("retained")
    identity = win.canvas._by_id["field"]
    shell.results.preview_button.setFocus()
    shell.set_fullscreen(True)
    assert shell.results.canvas is win.canvas
    assert win.canvas._by_id["field"] is identity
    assert shell.results.fullscreen and not shell.results.preview_cover.isVisible()
    shell.set_fullscreen(True)
    shell.results.toggle_collapsed()
    assert not win.canvas.isVisible()
    shell.results.toggle_collapsed()
    win.canvas.set_components([component])
    assert win.canvas._by_id["field"] is identity
    shell.dismiss()
    assert not shell.results.fullscreen and shell.results.preview_cover.isVisible()
    assert win.canvas._by_id["field"].findChild(QLineEdit).text() == "retained"
    assert QApplication.focusWidget() == shell.results.preview_button
    shell.results.toggle_fullscreen()
    assert shell.results.fullscreen
    shell.set_fullscreen(False)


def test_canvas_multi_ops_update_every_identity_and_empty_is_safe(win):
    rows = [{"type": "text", "content": str(index), "component_id": str(index)} for index in range(2)]
    win.canvas.apply_ops([{"component_id": row["component_id"], "component": row} for row in rows])
    assert win.canvas._rendered == {row["component_id"]: row for row in rows}
    win.canvas.apply_ops([])
    win.canvas.apply_ops([{"op": "remove", "component_id": "0"}])
    assert set(win.canvas._rendered) == {"1"}


@pytest.mark.parametrize("geometry", [GEOMETRY[0], GEOMETRY[5]])
def test_settings_navigation_uses_rote_axis_and_server_menu(win, geometry):
    win._on_message({"type": "rote_config", "device_profile": {"console": geometry["presentation"]}})
    win._open_surface("llm", "LLM settings")
    dialog = win._surface_dialog
    assert dialog.width() == geometry["presentation"]["settings_width"]
    controls = dialog._navigation_inner.findChildren(QPushButton)
    assert [control.accessibleName() for control in controls] == [item["label"] for section in MENU["menu"] for item in section["items"]]
    win._on_chrome_surface({"surface_key": "llm", "title": "Providers", "components": [{"type": "text", "content": "Configured"}]})
    assert dialog._title.text() == "Providers"
    controls = dialog._navigation_inner.findChildren(QPushButton)
    next(control for control in controls if control.accessibleName() == "Theme").click()
    assert win.client.sent[-1] == ("chrome_open", {"surface": "theme", "params": {}})
    win._retry_surface("theme", {})
    assert win.client.sent[-1][1]["surface"] == "theme"


def test_guidance_only_accepts_current_correlated_selection(win):
    sent, retired = guidance_ready(win)
    win._console_open_surface("guidance", "Advanced", {"view": "selection"})
    first = sent[-1][2]
    win._emit("chrome_turn_selection_set", SELECTION)
    second = sent[-1][2]
    assert first in retired and second != first
    win._on_chrome_surface(surface(first, selection=SELECTION))
    assert win._turn_selection is None
    win._on_chrome_surface(surface(second, selection={"version": 1}))
    assert win._turn_selection is None
    win._on_chrome_surface(surface(second, selection=SELECTION))
    assert win._turn_selection == SELECTION and second in retired
    assert win._console_shell.selection_button.isVisible()
    win._on_chrome_surface(surface(second, selection={"version": 1, "agent": None, "skills": [], "notes": []}))
    assert win._turn_selection == SELECTION
    win._console_shell.selection_button.click()
    assert win._turn_selection is None


@pytest.mark.parametrize("change", ["owner", "connection", "chat", "closed", "action"])
def test_selection_reply_cannot_cross_scope(win, change):
    sent, _ = guidance_ready(win)
    win._console_open_surface("guidance", "Advanced", {"view": "selection"})
    if change != "action":
        win._emit("chrome_turn_selection_set", SELECTION)
    generation = sent[-1][2]
    if change == "owner":
        win._resume_store.storage_key = "another-owner"
    elif change == "connection":
        win.client.connection_generation = OTHER
    elif change == "chat":
        win.active_chat = OTHER
    elif change == "closed":
        win._surface_dialog.close()
    win._on_chrome_surface(surface(generation, selection=SELECTION))
    assert win._turn_selection is None


def test_guidance_timeout_failure_and_disconnection_are_actionable(win):
    win._console_open_surface("guidance", "Advanced", {"view": "selection"})
    assert win._guidance_ticket is None
    QApplication.processEvents()
    assert win._surface_dialog._retry_btn.isVisible()
    sent, _ = guidance_ready(win)
    win._surface_dialog._retry()
    generation = sent[-1][2]
    win._on_status("guidance_failed:" + OTHER)
    assert win._guidance_ticket is not None
    win._on_status("guidance_failed:" + generation)
    assert win._guidance_ticket is None
    win._surface_dialog._retry()
    win._surface_dialog._on_timeout()
    assert win._guidance_ticket is None
    win.client.send_current_guidance = lambda *args, **kwargs: False
    win._surface_dialog._retry()
    assert win._guidance_ticket is None


def test_selection_and_background_are_forwarded_without_mutation_and_clear_on_chat_change(win):
    sent = []
    def send(message, chat_id, *, attachments=None, request_generation=None, selection=None, background=False):
        sent.append((message, selection, background))
    win.client.send_chat = send
    win._turn_selection = copy.deepcopy(SELECTION)
    win._set_background_mode(True)
    win._input.setText("Use my exact notes")
    win._send()
    assert sent == [("Use my exact notes", SELECTION, True)]
    win._set_active_chat(CHAT)
    assert win._turn_selection == SELECTION
    win._set_active_chat(OTHER)
    assert win._turn_selection is None
    win._turn_selection = copy.deepcopy(SELECTION)
    win._new_chat()
    assert win._turn_selection is None
    assert win._console_shell.landing.isVisible()


def test_compose_prompt_is_local_and_only_matches_current_authorized_surface(win):
    payload = {"message": "Try this example"}
    win._emit("compose_prompt", payload)
    assert win._input.text() == ""
    win._console_open_surface("agent_intro", "Dice", {"agent_id": "dice"})
    win._on_chrome_surface({"surface_key": "agent_intro", "title": "Dice", "components": [
        {"type": "card", "content": [{"type": "button", "label": "Load", "action": "compose_prompt", "payload": payload}]}]})
    count = len(win.client.sent)
    win._emit("compose_prompt", {"message": "unlisted"})
    assert win._input.text() == ""
    win._emit("compose_prompt", payload)
    assert win._input.text() == payload["message"]
    assert len(win.client.sent) == count and not win._surface_dialog.isVisible()
    win._input.clear()
    win._emit("compose_prompt", payload)
    assert win._input.text() == ""


def test_resize_reports_actual_dimensions_and_preserves_voice(win):
    snapshots = []
    win.client.update_device = lambda device: snapshots.append(device)
    win.resize(834, 1194)
    win._refresh_device()
    assert snapshots[-1]["viewport_width"] == win.width()
    assert snapshots[-1]["viewport_height"] == win.height()
    assert snapshots[-1]["console_contract"] == "console/v2"
    assert snapshots[-1]["voice"] == win._voice_audio.capability()
    win._queue_device_refresh()
    assert win._viewport_timer.isActive()


def test_keyboard_operates_scenario_and_composer_without_web_availability_banner(win):
    load = next(item for item in controls(win._console_shell, "scenarioId") if not item.property("runScenario"))
    load.setFocus()
    QTest.keyClick(load, Qt.Key.Key_Space)
    assert win._input.text() == "Roll six dice"
    assert win._voice_widget.parentWidget() == win._composer
    assert not win._voice_widget.status_label.isVisible()
    win._restyle_all()
    assert win._console_shell.isVisible()


def test_legacy_welcome_never_replaces_negotiated_landing_but_real_result_does(win):
    win._on_message({"type": "ui_render", "components": [
        {"type": "card", "component_id": "wel_hero", "title": "How can I help?", "content": []},
        {"type": "card", "component_id": "wel_examples", "content": []}]})
    assert win._console_shell.landing.isVisible()
    assert not win._console_shell.results.isVisible()
    win._on_message({"type": "ui_render", "components": [
        {"type": "text", "component_id": "result", "content": "A real result", "source_agent": "dice"}]})
    assert not win._console_shell.landing.isVisible()
    assert win._console_shell.results.title.text() == "Dice Roller Interface"
    assert win._console_shell.results.role.text() == "Active Specialist"
    win._console_shell.heading.click()
    assert win._console_shell.landing.isVisible()
    assert win.canvas._by_id["result"] is not None


def test_multiline_composer_shift_enter_edits_and_enter_sends(win):
    sent = []
    win.client.send_chat = lambda message, chat_id, **kwargs: sent.append(message)
    win._input.setFocus()
    QTest.keyClicks(win._input, "first")
    QTest.keyClick(win._input, Qt.Key.Key_Return, Qt.KeyboardModifier.ShiftModifier)
    QTest.keyClicks(win._input, "second")
    assert win._input.text() == "first\nsecond" and sent == []
    QTest.keyClick(win._input, Qt.Key.Key_Return)
    assert sent == ["first\nsecond"]


def test_composer_slash_discovery_preserves_keyboard_completion(win):
    win._input.setFocus()
    QTest.keyClicks(win._input, "/sum")
    assert win._input._completer.completionCount() == 1
    win._input._completer.activated[str].emit("/summarize ")
    assert win._input.text() == "/summarize "
    win._input._completer.popup().hide()
    QTest.keyClick(win._input, Qt.Key.Key_End)
    QTest.keyClicks(win._input, "text")
    assert win._input.text() == "/summarize text"


def test_server_disables_passive_voice_banner_but_errors_and_control_feedback_remain(win):
    voice = win._voice_widget
    control = QPushButton("Voice")
    control.setAccessibleName("Start voice")
    voice._buttons["voice-start"] = control
    voice.set_voice_status("unavailable", "Connect a microphone to use voice")
    assert voice.status_label.isHidden()
    assert "microphone" in voice.accessibleDescription()
    assert "microphone" in control.accessibleDescription()
    assert "microphone" in control.toolTip()
    voice.set_voice_status("listening", "Listening")
    assert not voice.status_label.isHidden()
    voice.set_speech_error("The audio device disconnected")
    assert not voice.status_label.isHidden() and not voice.request_notice_label.isHidden()
    voice.set_availability_banner(True)
    voice.set_voice_status("unavailable", "Connect a microphone")
    assert not voice.status_label.isHidden()


def test_voice_transport_error_is_visible_and_unavailability_remains_control_feedback(win):
    win._hide_banner()
    win._on_voice_status("unavailable", "Connect a microphone to use voice")
    assert not win._banner.isVisible()
    win._on_voice_status("error", "Could not connect to the voice worker. End voice and retry.")
    assert win._banner.isVisible()
    assert "End voice and retry" in win._banner.text()
    assert win._banner_kind == "error"


def test_theme_rebuild_keeps_current_input_choices_and_upserted_values(win):
    components = [{"type": "input", "component_id": "field", "label": "Value", "value": "old"}]
    win.canvas.set_components(components)
    win.canvas.apply_ops([{"component_id": "field", "component": {"type": "input", "label": "New label", "value": "new"}}])
    field = win.canvas._by_id["field"].findChild(QLineEdit)
    field.setText("unsent user edit")
    field.setCursorPosition(4)
    win._console_shell.set_fullscreen(True)
    field.setFocus()
    win.canvas.restyle()
    restored = win.canvas._by_id["field"].findChild(QLineEdit)
    assert restored.text() == "unsent user edit" and restored.cursorPosition() == 4
    assert win.canvas._last_components[0]["label"] == "New label"
    assert QApplication.focusWidget() is restored


def test_theme_transition_restyles_shell_and_open_settings_without_losing_draft(win):
    from astral_client import theme
    from astral_client.app import SurfaceDialog
    original = dict(theme.PALETTE)
    dialog = SurfaceDialog(win, emit=lambda *_: None)
    win._surface_dialog = dialog
    dialog.set_surface("Settings", [{"type": "input", "label": "Draft", "value": "initial"}])
    field = dialog._inner.findChild(QLineEdit)
    field.setText("unsaved setting")
    field.setCursorPosition(3)
    win._input.setText("unsent prompt")
    dialog._emit_from_surface("chrome_note_save", {})
    try:
        theme.apply_theme("daylight")
        win._restyle_all()
        assert theme.TEXT in win._console_shell.brand.styleSheet()
        assert theme.TEXT in win._console_shell.title.styleSheet()
        assert theme.MUTED in win._console_shell.subtitle.styleSheet()
        assert theme.SURFACE_2 in dialog.styleSheet()
        assert theme.TEXT in dialog._title.styleSheet()
        restored = dialog._inner.findChild(QLineEdit)
        assert restored.text() == "unsaved setting"
        assert restored.cursorPosition() == 3
        assert win._input.text() == "unsent prompt"
        assert dialog._timer.isActive()
        assert dialog._status.text() == "Applying…"
        assert not dialog._status.isHidden()
        dialog.begin_load("theme", {}, title="Theme")
        dialog.restyle()
        assert dialog._status.isHidden() is False
    finally:
        theme.apply_theme({"colors": original})
        win._restyle_all()


def test_theme_rebuild_preserves_multiline_combo_tabs_and_checkbox(win):
    from PySide6.QtWidgets import QCheckBox, QComboBox, QPlainTextEdit, QTabWidget
    components = [{"type": "tabs", "component_id": "form", "tabs": [
        {"label": "Input", "content": [{"type": "param_picker", "fields": [
            {"name": "choice", "kind": "select", "options": ["first", "second"]},
            {"name": "enabled", "kind": "boolean", "label": "Enabled"},
            {"name": "notes", "kind": "textarea", "label": "Notes"}]}]},
        {"label": "Preview", "content": [{"type": "text", "content": "Preview"}]}]}]
    win.canvas.set_components(components)
    root = win.canvas._by_id["form"]
    root.findChild(QComboBox).setCurrentIndex(1)
    root.findChild(QCheckBox).setChecked(True)
    root.findChild(QPlainTextEdit).setPlainText("long notes")
    tabs = root if isinstance(root, QTabWidget) else root.findChild(QTabWidget)
    tabs.setCurrentIndex(1)
    win.canvas.restyle()
    root = win.canvas._by_id["form"]
    assert root.findChild(QComboBox).currentIndex() == 1
    assert root.findChild(QCheckBox).isChecked()
    assert root.findChild(QPlainTextEdit).toPlainText() == "long notes"
    tabs = root if isinstance(root, QTabWidget) else root.findChild(QTabWidget)
    assert tabs.currentIndex() == 1


def test_workspace_controls_use_current_authority_and_removal_revokes_action(win, monkeypatch):
    from astral_client import workspace_actions
    calls = []
    class Controller:
        def __init__(self, **kwargs):
            calls.append(kwargs)
        def perform(self, operation):
            calls.append(operation)
        def clear(self):
            calls.append("clear")
        def invalidate_stale(self):
            calls.append("invalidate")
    monkeypatch.setattr(workspace_actions, "WorkspaceActions", Controller)
    model = copy.deepcopy(MENU)
    model["topbar"].extend([
        {"key": "export", "kind": "workspace_action", "label": "Export page", "icon": "download", "operation": "export_canvas", "context": "live_canvas"},
        {"key": "share", "kind": "workspace_action", "label": "Share page", "icon": "share", "operation": "share_canvas", "context": "live_canvas"}])
    win._on_message({"type": "chrome_menu", "model": model})
    widgets = controls(win._console_shell, "workspaceOperation")
    assert len(widgets) == 2 and all(not widget.isEnabled() for widget in widgets)
    win._perform_workspace_action("export_canvas")
    assert calls[1] == "export_canvas"
    assert calls[0]["context_provider"]()["owner"] == "console-synthetic-owner"
    win._perform_workspace_action("share_canvas")
    win._clear_workspace_actions()
    win._sync_console_conversation()
    assert calls[-2:] == ["clear", "invalidate"]
    win._on_message({"type": "chrome_menu", "model": MENU})
    assert controls(win._console_shell, "workspaceOperation") == []


def test_private_shell_state_is_erased_at_owner_boundary(win):
    shell = win._console_shell
    shell.set_history([{"id": CHAT, "title": "Private chat"}])
    shell.search.setText("Dice")
    shell.set_selection(SELECTION)
    shell.clear_private_state()
    assert shell.account_button.text() == ""
    assert shell.account_menu.isEmpty() and shell.more_menu.isEmpty()
    assert shell.model is None and not shell.isEnabled()
    assert shell.history_layout.count() == 1
    assert shell.scenario_layout.count() == 0


@pytest.mark.parametrize("next_subject", ["alice", "bob", "unreadable"])
def test_reauthentication_preserves_only_current_owner_composer_and_uploads(win, tmp_path, next_subject):
    from PySide6.QtCore import QSettings
    from astral_client.protocol import ConversationResumeStore
    from test_workspace_actions import _token

    win._resume_store = ConversationResumeStore(QSettings(
        str(tmp_path / "resume.ini"), QSettings.Format.IniFormat))
    win._resume_store.bind_token(_token("alice"))
    win._token = _token("alice")
    win._input.setText("Alice private draft")
    win._attachments = [
        {"chip_id": "ready-alice", "attachment_id": "alice-file", "filename": "alice-ready.txt",
         "category": "text", "parser_status": "covered", "status": "staged"},
        {"chip_id": "uploading-alice", "attachment_id": None, "filename": "alice-pending.txt",
         "category": "file", "parser_status": None, "status": "uploading"},
    ]
    win._render_chips()
    win._reconnect("unreadable-token" if next_subject == "unreadable" else _token(next_subject))
    if next_subject == "alice":
        assert win._input.text() == "Alice private draft"
        assert len(win._attachments) == 2
    else:
        assert win._input.text() == ""
        assert win._attachments == []
        assert win._chips_bar.isHidden()
    win._on_attachment_uploaded({"chip_id": "uploading-alice", "error": None, "result": {
        "attachment_id": "alice-late-file", "filename": "alice-pending.txt", "category": "text"}})
    if next_subject == "alice":
        assert win._attachments[1]["attachment_id"] == "alice-late-file"
    else:
        win._on_message({"type": "chrome_menu", "model": copy.deepcopy(MENU)})
        assert win._input.text() == ""
        assert win._sendable_attachments() == []
        assert win._attachments == []
        assert win._chips_bar.isHidden()


@pytest.mark.parametrize("operation", ["export_canvas", "share_canvas"])
@pytest.mark.parametrize("target", [CHAT, OTHER], ids=["same-chat", "cached-other-chat"])
def test_cached_chat_workspace_actions_wait_for_matching_rendered_hydration(win, operation, target):
    import uuid
    from astral_client.protocol import ConversationResumeStore
    from astral_client.workspace_actions import WorkspaceActions
    from test_conversation_continuity_060 import _snapshot
    from test_workspace_actions import Transport, _token

    win._token = _token()
    win._resume_store.storage_key = ConversationResumeStore.account_key("https://identity.test", "alice")
    model = copy.deepcopy(MENU)
    model["topbar"].append({"key": "workspace", "kind": "workspace_action", "label": "Workspace",
                            "operation": operation, "context": "live_canvas"})
    win._on_message({"type": "chrome_menu", "model": model})

    def hydrate(chat, text):
        win._load_chat(chat)
        frame = _snapshot(chat=chat, request=win._continuity.request_generation,
                          snapshot_id=str(uuid.uuid4()), text=text)
        win._on_message(frame)
        assert win.canvas._last_components == frame["canvas"]["components"]

    hydrate(OTHER, "Cached B canvas")
    hydrate(CHAT, "Visible A canvas")
    assert win.canvas._last_components == [{"type": "text", "content": "Visible A canvas"}]
    win._load_chat(target)
    assert win._continuity.committed_snapshot.chat_id == target
    queued = []
    controller = WorkspaceActions(parent=win, context_provider=win._workspace_context,
                                  token_provider=win._current_token, http_base="https://server.test",
                                  notify=lambda *_: None, transport=Transport(), start_worker=queued.append)
    assert not win._workspace_context()["operations"]
    assert all(not control.isEnabled() for control in controls(win._console_shell, "workspaceOperation"))
    assert controller.perform(operation) is False
    assert not queued
    win._on_message({"type": "error", "message": "The conversation could not be restored."})
    assert not win._workspace_context()["operations"]
    assert controller.perform(operation) is False
    win._load_chat(target)
    assert not win._workspace_context()["operations"]
    win._on_message(_snapshot(chat=target, request=win._continuity.request_generation,
                              snapshot_id=str(uuid.uuid4()), text="Hydrated requested canvas"))
    assert win.canvas._last_components == [{"type": "text", "content": "Hydrated requested canvas"}]
    assert operation in win._workspace_context()["operations"]
    assert controller.perform(operation) is True
    assert len(queued) == 1
    controller.clear()
    win.client.connection_generation = str(uuid.uuid4())
    assert not win._workspace_context()["operations"]
    assert controller.perform(operation) is False
    assert len(queued) == 1
