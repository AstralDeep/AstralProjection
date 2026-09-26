"""Tests for astral_client/app.py and theme.py: inbound frame routing —
error/notification banners, connection status UX, settings/surface dialogs,
chrome_surface open/close/mandatory semantics, and the off-GUI-thread silent token
refresh.
"""

import os

import pytest

pytest.importorskip("PySide6")

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ["ASTRAL_WIN_AGENT"] = "0"

from astral_client import app as appmod  # noqa: E402
from astral_client.app import MainWindow, normalize_error  # noqa: E402


class _FakeClient:
    def __init__(self, *a, **k):
        self.sent = []
        self._sig = None
        self.connection_generation = None

    class _Sig:
        def connect(self, *_a):
            pass

    message = _Sig()
    status = _Sig()

    def start(self):
        pass

    def stop(self):
        pass

    def send_event(self, action, payload, session_id=None):
        self.sent.append((action, payload))

    def send_chat(self, *a, **k):
        pass


@pytest.fixture
def win(qapp, monkeypatch):
    monkeypatch.setattr(appmod, "OrchestratorClient", _FakeClient)
    monkeypatch.setattr(MainWindow, "_start_integrity_check", lambda self: None)
    monkeypatch.setattr(MainWindow, "_init_workspace", lambda self: None)
    w = MainWindow("ws://127.0.0.1:9/ws", "dev-token")
    yield w
    w.close()


def test_normalize_error_shapes():
    assert normalize_error({"message": "boom"}) == "boom"
    assert normalize_error({"payload": {"message": "deep boom"}}) == "deep boom"
    assert normalize_error({"code": "llm_config_invalid", "message": "bad"}) == "bad (llm_config_invalid)"
    assert normalize_error({"code": "internal", "message": "x"}) == "x"
    assert "wrong" in normalize_error({}).lower()


def test_error_frame_shows_banner_and_resolves_turn(win):
    win._turn_active = True
    win._on_message({"type": "error", "code": "internal", "message": "server fell over"})
    assert (not win._banner.isHidden())
    assert "server fell over" in win._banner.text()
    assert win._turn_active is False


def test_notification_frame_shows_banner(win):
    win._on_message({"type": "notification", "title": "Job done", "body": "report ready", "level": "info"})
    assert (not win._banner.isHidden())
    assert "Job done" in win._banner.text() and "report ready" in win._banner.text()


def test_unknown_frame_is_logged_not_crashing(win, caplog):
    import logging
    with caplog.at_level(logging.WARNING, logger="astral.client"):
        win._on_message({"type": "totally_new_server_frame"})
    assert any("unhandled frame type=totally_new_server_frame" in r.message for r in caplog.records)


def test_classified_ignore_is_info_not_warning(win, caplog):
    import logging
    with caplog.at_level(logging.INFO, logger="astral.client"):
        win._on_message({"type": "heartbeat"})
    assert any("ignored frame type=heartbeat" in r.message for r in caplog.records)
    assert not any(r.levelno >= logging.WARNING for r in caplog.records)


def test_progress_signals_and_terminal(win):
    chat_id = "00000000-0000-4000-8000-000000000001"
    submission_id = "00000000-0000-4000-8000-000000000002"
    request_generation = "00000000-0000-4000-8000-000000000003"
    connection_generation = "00000000-0000-4000-8000-000000000004"
    win.active_chat = chat_id
    win.client.connection_generation = connection_generation
    win._continuity.bind_connection(connection_generation)
    win._continuity.open_request("commit", request_generation)
    assert win._project_local_submission(
        appmod.LocalOperationSubmission(
            submission_id=submission_id,
            request_generation=request_generation,
            action="chat_message",
            chat_id=chat_id,
        )
    )
    win._on_message(
        {
            "type": "user_message_acked",
            "schema_version": "1",
            "chat_id": chat_id,
            "message_id": 1,
            "submission_id": submission_id,
            "request_generation": request_generation,
            "connection_generation": connection_generation,
            "voice_turn_id": None,
        }
    )
    assert win._turn_active is True
    win._on_message({"type": "chat_step", "step": {"name": "search", "status": "completed"}})
    win._on_message({"type": "tool_progress", "label": "fetching page 2"})
    win._on_message({"type": "task_started", "task_id": "t1"})
    assert (not win._banner.isHidden())
    win._on_message({"type": "task_completed", "task_id": "t1"})
    assert win._turn_active is False


def test_client_local_ack_must_be_accepted_by_voice_correlation_before_ui_mutates(win):
    ack = {
        "type": "user_message_acked",
        "schema_version": "1",
        "chat_id": "00000000-0000-4000-8000-000000000001",
        "message_id": 1,
        "submission_id": "00000000-0000-4000-8000-000000000002",
        "request_generation": "00000000-0000-4000-8000-000000000003",
        "connection_generation": "00000000-0000-4000-8000-000000000004",
        "voice_turn_id": "00000000-0000-4000-8000-000000000005",
    }
    accepted: list[dict] = []
    finished: list[str] = []
    win._voice_controller.speech_backend = "client_local"
    win._voice_controller.owns_local_message_ack = lambda _frame: True
    win._voice_controller.accept_frame = lambda frame: accepted.append(frame) or False
    win._finish_local_submission_by_id = finished.append
    win._turn_active = False

    win._on_message(ack)

    assert accepted == [ack]
    assert finished == []
    assert win._turn_active is False

    win._voice_controller.accept_frame = lambda frame: accepted.append(frame) or True
    win._scoped_status_matches = lambda _frame: True
    win._on_message(ack)

    assert accepted == [ack, ack]
    assert finished == []
    assert win._turn_active is True


@pytest.mark.parametrize("voice_turn_id", [pytest.param(None, id="null"), pytest.param("missing", id="missing")])
def test_malformed_ack_claiming_pending_local_final_cannot_mutate_generic_ui(
    win, voice_turn_id
):
    ack = {
        "type": "user_message_acked",
        "schema_version": "1",
        "chat_id": "00000000-0000-4000-8000-000000000001",
        "message_id": 1,
        "submission_id": "00000000-0000-4000-8000-000000000002",
        "request_generation": "00000000-0000-4000-8000-000000000003",
        "connection_generation": "00000000-0000-4000-8000-000000000004",
    }
    if voice_turn_id != "missing":
        ack["voice_turn_id"] = voice_turn_id
    finished: list[str] = []
    win._voice_controller.speech_backend = "client_local"
    win._voice_controller.owns_local_message_ack = lambda _frame: True
    win._voice_controller.accept_frame = lambda _frame: False
    win._finish_local_submission_by_id = finished.append
    win._turn_active = False

    win._on_message(ack)

    assert finished == []
    assert not win._turn_active


def test_duplicate_remote_voice_ack_cannot_resurrect_generic_working_state(win):
    submission = appmod.LocalOperationSubmission(
        submission_id="00000000-0000-4000-8000-000000000002",
        request_generation="00000000-0000-4000-8000-000000000003",
        action="chat_message",
        chat_id="00000000-0000-4000-8000-000000000001",
        voice_turn_id="00000000-0000-4000-8000-000000000005",
    )
    assert win._project_local_submission(submission)
    ack = {
        "type": "user_message_acked",
        "schema_version": "1",
        "chat_id": submission.chat_id,
        "message_id": 1,
        "submission_id": submission.submission_id,
        "request_generation": submission.request_generation,
        "connection_generation": "00000000-0000-4000-8000-000000000004",
        "voice_turn_id": "00000000-0000-4000-8000-000000000005",
    }
    win._voice_controller.speech_backend = "llm_factory"
    win._voice_controller.owns_local_message_ack = lambda _frame: False
    win._voice_controller.accept_frame = lambda _frame: False
    win._continuity.bind_connection(ack["connection_generation"])
    win.client.connection_generation = ack["connection_generation"]
    win._scoped_status_matches = lambda _frame: True

    win._on_message(ack)
    assert win._turn_active

    win._turn_active = False
    win._on_message(ack)

    assert not win._turn_active


def test_typed_ack_during_local_pending_final_settles_only_typed_projection(win):
    local_pending = {
        "submission_id": "00000000-0000-4000-8000-000000000009",
        "connection_generation": "00000000-0000-4000-8000-000000000004",
    }
    win._voice_controller.speech_backend = "client_local"
    win._voice_controller._local_pending_final = local_pending
    typed = appmod.LocalOperationSubmission(
        submission_id="00000000-0000-4000-8000-000000000002",
        request_generation="00000000-0000-4000-8000-000000000003",
        action="chat_message",
        chat_id="00000000-0000-4000-8000-000000000001",
    )
    assert win._project_local_submission(typed)
    connection = "00000000-0000-4000-8000-000000000004"
    win.client.connection_generation = connection
    win._continuity.bind_connection(connection)
    win._continuity.open_request("commit", typed.request_generation)
    win.active_chat = typed.chat_id
    ack = {
        "type": "user_message_acked",
        "schema_version": "1",
        "chat_id": typed.chat_id,
        "message_id": 1,
        "submission_id": typed.submission_id,
        "request_generation": typed.request_generation,
        "connection_generation": connection,
        "voice_turn_id": None,
    }

    win._on_message(ack)

    assert win._voice_controller._local_pending_final is local_pending
    assert typed.submission_id not in win._pending_submissions_by_id
    assert win._turn_active


@pytest.mark.parametrize("wrong_field", ["request_generation", "connection_generation"])
def test_wrong_typed_ack_during_local_pending_final_is_inert(win, wrong_field):
    local_pending = {
        "submission_id": "00000000-0000-4000-8000-000000000009",
        "connection_generation": "00000000-0000-4000-8000-000000000004",
    }
    win._voice_controller.speech_backend = "client_local"
    win._voice_controller._local_pending_final = local_pending
    typed = appmod.LocalOperationSubmission(
        submission_id="00000000-0000-4000-8000-000000000002",
        request_generation="00000000-0000-4000-8000-000000000003",
        action="chat_message",
        chat_id="00000000-0000-4000-8000-000000000001",
    )
    assert win._project_local_submission(typed)
    connection = "00000000-0000-4000-8000-000000000004"
    win.client.connection_generation = connection
    win._continuity.bind_connection(connection)
    win.active_chat = typed.chat_id
    ack = {
        "type": "user_message_acked",
        "schema_version": "1",
        "chat_id": typed.chat_id,
        "message_id": 1,
        "submission_id": typed.submission_id,
        "request_generation": typed.request_generation,
        "connection_generation": connection,
        "voice_turn_id": None,
        wrong_field: "00000000-0000-4000-8000-000000000010",
    }

    win._on_message(ack)

    assert win._voice_controller._local_pending_final is local_pending
    assert typed.submission_id in win._pending_submissions_by_id
    assert not win._turn_active


def test_reconnecting_status_shows_banner(win):
    win._connected_once = True
    win._on_status("reconnecting:3")
    assert (not win._banner.isHidden())
    assert "attempt 3" in win._banner.text()


def test_connected_hides_banner(win):
    win._on_status("reconnecting:1")
    assert (not win._banner.isHidden())
    win._on_status("connected")
    assert not (not win._banner.isHidden())


def test_send_dropped_is_visible(win):
    win._on_status("send_dropped:chat_message")
    assert (not win._banner.isHidden())
    assert "chat_message" in win._banner.text()


def test_expired_dev_session_does_not_dead_end(win):
    win._auth_session = None
    win._login_params = {}
    win._on_status("auth_required:expired")
    assert (not win._banner.isHidden())
    assert "expired" in win._banner.text().lower()


def test_timeline_mode_banner(win):
    win._on_message({"type": "workspace_timeline_mode", "active": True})
    assert win._timeline_mode is True
    assert (not win._banner.isHidden())
    win._on_message({"type": "workspace_timeline_mode", "active": False})
    assert win._timeline_mode is False


def test_timeline_mode_disables_composer(win):
    assert win._input.isEnabled() and win._send_btn.isEnabled()
    win._on_message({"type": "workspace_timeline_mode", "active": True})
    assert win._input.isEnabled() is False
    assert win._send_btn.isEnabled() is False
    win._on_message({"type": "workspace_timeline_mode", "active": False})
    assert win._input.isEnabled() is True
    assert win._send_btn.isEnabled() is True


def test_history_target_render_populates_dialog(win, caplog):
    import logging

    from astral_client.app import HistoryDialog

    win._history_dialog = HistoryDialog(win, lambda cid: None)
    with caplog.at_level(logging.INFO, logger="astral.client"):
        win._on_message({"type": "ui_render", "target": "history", "components": [
            {"type": "chat_history", "title": "Recent chats", "items": [
                {"chat_id": "c1", "title": "First"},
                {"chat_id": "c2", "title": "Second"}]}]})
    assert win._history_dialog._listlay.count() == 3
    assert any("history surface rendered" in r.message for r in caplog.records)


def test_history_target_render_without_dialog_is_logged(win, caplog):
    import logging

    win._history_dialog = None
    with caplog.at_level(logging.INFO, logger="astral.client"):
        win._on_message({"type": "ui_render", "target": "history", "components": [
            {"type": "chat_history", "items": [{"chat_id": "c1", "title": "X"}]}]})
    assert any("history surface rendered" in r.message for r in caplog.records)


def test_topbar_renders_and_routes_action_buttons(qapp):
    from astral_client.app import TopBar

    opened = []
    tb = TopBar("user", lambda: None, lambda: None,
                lambda s, ln: opened.append((s, ln)), lambda: None)
    tb.set_menu_model({
        "topbar": [
            {"key": "brand", "kind": "brand"},
            {"key": "timeline", "kind": "action", "label": "Workspace timeline",
             "icon": "history", "action": {"surface": "workspace_timeline", "params": {}}},
            {"key": "pulse", "kind": "action", "label": "Pulse",
             "icon": "pulse", "action": {"surface": "pulse", "params": {}}},
            {"key": "settings", "kind": "menu", "label": "Settings", "icon": "gear"},
        ],
        "menu": [],
        "signout": {"label": "Sign out", "action": "logout"},
    })
    assert len(tb._action_buttons) == 2
    assert any(b.accessibleName() == "Workspace timeline" for b in tb._action_buttons)
    tb._action_buttons[0].click()
    assert opened and opened[0][0] == "workspace_timeline"


def test_topbar_actions_rebuilt_and_cleared(qapp):
    from astral_client.app import TopBar

    tb = TopBar("u", lambda: None, lambda: None, lambda s, ln: None, lambda: None)
    tb.set_menu_model({"topbar": [
        {"kind": "action", "label": "T", "action": {"surface": "workspace_timeline"}}]})
    assert len(tb._action_buttons) == 1
    tb.set_menu_model({"topbar": [], "menu": []})
    assert tb._action_buttons == []


def test_settings_menu_shows_group_headers_and_literal_ampersand(qapp):
    from PySide6.QtWidgets import QLabel, QWidgetAction

    from astral_client.app import TopBar

    tb = TopBar("u", lambda: None, lambda: None, lambda s, ln: None, lambda: None)
    tb.set_menu_model({
        "topbar": [],
        "menu": [
            {"key": "account", "label": "Account", "items": [
                {"key": "agents", "label": "Agents & permissions", "surface": "agents"},
                {"key": "theme", "label": "Theme", "surface": "theme"}]},
            {"key": "help", "label": "Help", "items": [
                {"key": "guide", "label": "User guide", "surface": "guide"}]},
        ],
        "signout": {"label": "Sign out", "action": "logout"},
    })
    header_texts = [
        wa.defaultWidget().text()
        for wa in tb._menu.actions()
        if isinstance(wa, QWidgetAction) and isinstance(wa.defaultWidget(), QLabel)
    ]
    assert "ACCOUNT" in header_texts and "HELP" in header_texts
    assert "Sign out" in header_texts
    item_texts = [a.text() for a in tb._menu.actions() if a.text()]
    assert "Agents && permissions" in item_texts
    assert {"Theme", "User guide"} <= set(item_texts)


def test_surface_dialog_timeout_shows_retry_and_arrival_cancels(qapp):
    from PySide6.QtWidgets import QPushButton

    from astral_client.app import SurfaceDialog

    retried = []
    dlg = SurfaceDialog(None, emit=lambda a, p: None,
                        on_retry=lambda s, p: retried.append((s, p)))
    dlg.begin_load("theme", {}, title="Theme")
    assert dlg._timer.isActive()
    dlg._on_timeout()
    assert dlg._timer.isActive() is False
    retry = [b for b in dlg.findChildren(QPushButton) if b.text() == "Retry"]
    assert retry, "no Retry affordance after the load timeout"
    retry[0].click()
    assert dlg._timer.isActive()
    assert retried and retried[0][0] == "theme"
    dlg.set_surface("Theme", [{"type": "text", "content": "hi"}])
    assert dlg._timer.isActive() is False
    dlg.close()


def test_surface_dialog_chrome_submit_shows_in_flight(qapp):
    from astral_client.app import SurfaceDialog

    sent = []
    dlg = SurfaceDialog(None, emit=lambda a, p: sent.append((a, p)))
    dlg.set_surface("LLM", [])
    dlg._emit_from_surface("chrome_llm_save", {"fields": {}})
    assert sent == [("chrome_llm_save", {"fields": {}})]
    assert not dlg._status.isHidden()
    dlg.set_surface("LLM", [])
    assert dlg._status.isHidden()
    dlg.close()


def test_surface_dialog_switch_removes_stale_widgets_immediately(qapp):
    from PySide6.QtWidgets import QLabel

    from astral_client.app import SurfaceDialog

    dlg = SurfaceDialog(None, emit=lambda a, p: None)
    dlg.set_surface("Personalization", [{"type": "text", "content": "SOUL-TAB"}])
    assert any("SOUL-TAB" in (w.text() or "") for w in dlg._inner.findChildren(QLabel))
    dlg.set_surface("Theme", [{"type": "text", "content": "PRESETS"}])
    texts = [(w.text() or "") for w in dlg._inner.findChildren(QLabel)]
    assert any("PRESETS" in t for t in texts)
    assert not any("SOUL-TAB" in t for t in texts), (
        "previous surface's widgets still attached after set_surface switch"
    )
    assert dlg._lay.count() == 2
    dlg.close()


def test_chrome_surface_close_frame_closes_open_dialog(win):
    win._on_message({"type": "chrome_surface", "surface_key": "theme",
                     "title": "Theme",
                     "components": [{"type": "text", "content": "PRESETS"}]})
    assert win._surface_dialog is not None
    assert not win._surface_dialog.isHidden()
    win._on_message({"type": "chrome_surface", "surface_key": "", "title": "",
                     "components": []})
    assert win._surface_dialog.isHidden()


def test_chrome_surface_close_frame_does_not_create_dialog(win):
    assert win._surface_dialog is None
    win._on_message({"type": "chrome_surface", "surface_key": "", "title": "",
                     "components": []})
    assert win._surface_dialog is None


_MANDATORY_FRAME = {
    "type": "chrome_surface", "surface_key": "llm",
    "title": "Set up your AI provider",
    "components": [{"type": "text", "content": "provider form"}],
    "mode": "mandatory",
}

_CLOSE_FRAME = {"type": "chrome_surface", "surface_key": "", "title": "",
                "components": [], "mode": "replace"}


def test_chrome_surface_mode_absent_is_replace(win):
    win._on_message({"type": "chrome_surface", "surface_key": "theme",
                     "title": "Theme",
                     "components": [{"type": "text", "content": "PRESETS"}]})
    dlg = win._surface_dialog
    assert dlg is not None and not dlg.isHidden()
    assert dlg._mandatory is False
    assert dlg.isModal() is False
    assert dlg._signout_btn.isHidden()
    assert dlg.close() is True
    assert dlg.isHidden()


def test_chrome_surface_mandatory_pins_modal_and_suppresses_dismissal(win):
    from PySide6.QtCore import Qt

    win._on_message(dict(_MANDATORY_FRAME))
    dlg = win._surface_dialog
    assert dlg is not None and not dlg.isHidden()
    assert dlg._mandatory is True
    assert dlg.windowModality() == Qt.WindowModality.ApplicationModal
    assert dlg.windowFlags() & Qt.WindowType.CustomizeWindowHint
    assert not (dlg.windowFlags() & Qt.WindowType.WindowCloseButtonHint)
    assert not dlg._signout_btn.isHidden()
    dlg.reject()
    assert not dlg.isHidden()
    assert dlg.close() is False
    assert not dlg.isHidden()


def test_mandatory_signout_button_invokes_sign_out_routine(qapp):
    from astral_client.app import SurfaceDialog

    signed_out = []
    dlg = SurfaceDialog(None, emit=lambda a, p: None,
                        on_sign_out=lambda: signed_out.append(True))
    assert dlg._signout_btn.isHidden()
    dlg.set_mandatory(True)
    assert not dlg._signout_btn.isHidden()
    dlg._signout_btn.click()
    assert signed_out == [True]
    dlg.set_mandatory(False)
    assert dlg._signout_btn.isHidden()
    dlg.close()


def test_blank_close_clears_mandatory_pin_then_plain_surfaces_unchanged(win):
    win._on_message(dict(_MANDATORY_FRAME))
    dlg = win._surface_dialog
    assert dlg._mandatory is True
    win._on_message(dict(_CLOSE_FRAME))
    assert dlg._mandatory is False
    assert dlg.isHidden()
    win._on_message({"type": "chrome_surface", "surface_key": "theme",
                     "title": "Theme",
                     "components": [{"type": "text", "content": "PRESETS"}]})
    assert not dlg.isHidden()
    assert dlg.isModal() is False
    assert dlg._signout_btn.isHidden()
    assert dlg.close() is True


def test_workspace_timeline_routes_to_sdui_surface(win):
    win.client.sent.clear()
    win._open_surface("workspace_timeline", "Workspace timeline")
    assert ("chrome_open",
            {"surface": "workspace_timeline", "params": {}}) in win.client.sent
    assert win._surface_dialog is not None
    assert win._history_dialog is None
    assert ("get_history", {}) not in win.client.sent


def test_surface_dialog_client_local_action_does_not_arm_timer(qapp):
    from astral_client.app import SurfaceDialog

    sent = []
    dlg = SurfaceDialog(None, emit=lambda a, p: sent.append((a, p)))
    dlg.set_surface("Your files", [])
    assert dlg._timer.isActive() is False
    dlg._emit_from_surface("attach_existing", {"attachment_id": "att-1"})
    assert sent == [("attach_existing", {"attachment_id": "att-1"})]
    assert dlg._timer.isActive() is False
    assert dlg._status.isHidden()
    dlg.close()


def test_client_local_actions_includes_attach_existing():
    from astral_client.app import _CLIENT_LOCAL_ACTIONS

    assert "attach_existing" in _CLIENT_LOCAL_ACTIONS


def test_chat_status_done_does_not_clear_banner_or_resync(win):
    win._turn_active = True
    win._on_message({"type": "error", "code": "internal", "message": "server fell over"})
    assert not win._banner.isHidden()
    win.client.sent.clear()
    win._on_message({"type": "chat_status", "status": "done"})
    assert not win._banner.isHidden()
    assert "server fell over" in win._banner.text()
    actions = [a for a, _ in win.client.sent]
    assert "discover_agents" not in actions
    assert "get_history" not in actions
    assert win._turn_active is False


def test_stream_unsubscribed_does_not_resync(win):
    win.client.sent.clear()
    win._on_message({"type": "stream_unsubscribed", "stream_id": "s1"})
    actions = [a for a, _ in win.client.sent]
    assert "discover_agents" not in actions and "get_history" not in actions


def test_real_connected_still_resyncs(win):
    win.client.sent.clear()
    win._on_status("connected")
    actions = [a for a, _ in win.client.sent]
    assert "discover_agents" in actions and "get_history" in actions


def test_theme_apply_component_triggers_app_restyle(win, qapp, monkeypatch):
    import astral_client.theme as T

    restyled = []
    monkeypatch.setattr(win, "_restyle_all", lambda: restyled.append(True))
    snap = dict(T.PALETTE)
    try:
        win.canvas.set_components([{"type": "theme_apply", "preset": "forest"}])
        assert T.PALETTE["primary"] == T.PRESETS["forest"]["primary"]
        assert restyled == []
        for _ in range(100):
            qapp.processEvents()
            if restyled:
                break
        assert restyled == [True]
    finally:
        T.PALETTE.clear()
        T.PALETTE.update(snap)
        T._derive()
        T.APP_STYLESHEET = T.build_stylesheet()


def test_silent_refresh_done_reconnects_on_token(win, monkeypatch):
    from types import SimpleNamespace

    reconnected = []
    monkeypatch.setattr(win, "_reconnect", lambda tok: reconnected.append(tok))
    win._silent_refresh_active = True
    win._auth_session = SimpleNamespace(access_token="OLDTOKEN")
    win._on_silent_refresh_done(win._auth_generation,
                               (win._auth_session, SimpleNamespace(access_token="NEWTOKEN"), "NEWTOKEN"))
    assert reconnected == ["NEWTOKEN"]
    assert win._silent_refresh_active is False


def test_silent_refresh_done_prompts_on_failure(win, monkeypatch):
    prompted = []
    monkeypatch.setattr(win, "_prompt_reauth", lambda: prompted.append(True))
    win._silent_refresh_active = True
    win._on_silent_refresh_done(win._auth_generation, (win._auth_session, win._auth_session, None))
    assert prompted == [True]
    assert win._silent_refresh_active is False


def test_auth_required_runs_refresh_off_gui_thread(win, qapp, monkeypatch):
    import threading

    reconnected = []
    monkeypatch.setattr(win, "_reconnect", lambda tok: reconnected.append(tok))
    seen = {}
    done = threading.Event()
    main_thread = threading.current_thread()

    class _Sess:
        access_token = "old"
        refresh_token = "r"
        client_id = "astral-desktop"
        token_url = ""

        def refresh(self):
            seen["thread"] = threading.current_thread()
            done.set()
            return "NEWTOKEN"

    win._auth_session = _Sess()
    win._reauth_tries = 0
    win._on_status("auth_required:expired")
    assert win._silent_refresh_active is True
    assert done.wait(3.0), "the refresh worker never ran"
    assert seen["thread"] is not main_thread
    for _ in range(100):
        qapp.processEvents()
        if reconnected:
            break
    assert reconnected == ["NEWTOKEN"]
    assert win._silent_refresh_active is False


def test_auth_required_bound_exhausted_prompts(win, monkeypatch):
    prompted = []
    monkeypatch.setattr(win, "_prompt_reauth", lambda: prompted.append(True))

    class _Sess:
        access_token = "old"
        refresh_token = "r"
        client_id = "c"
        token_url = ""

        def refresh(self):  # pragma: no cover
            raise AssertionError("refresh attempted past the retry bound")

    win._auth_session = _Sess()
    win._reauth_tries = 2
    win._on_status("auth_required:expired")
    assert prompted == [True]
    assert win._silent_refresh_active is False
