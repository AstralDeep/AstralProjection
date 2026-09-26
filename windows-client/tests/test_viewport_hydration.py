"""Exercises native viewport hydration correlation, retirement, and state preservation.
Renderer identity tests reject reordered or ambiguous controls without positional restoration.
"""

import copy
import uuid
from types import SimpleNamespace

import pytest
from PySide6.QtWidgets import QApplication, QComboBox, QLabel, QLineEdit, QPlainTextEdit, QPushButton, QTabWidget, QWidget

from astral_client.protocol import LocalOperationSubmission, OrchestratorClient, WindowsProtocolError, device_caps
from astral_client.renderer import RenderContext, render
from astral_client.viewport import ControlIdentityError, capture_controls, restore_controls
from test_console_shell import CHAT, CONNECTION, GEOMETRY, MENU
from test_conversation_continuity_060 import HYDRATION, OTHER_CHAT, OTHER_CONNECTION, _snapshot
from test_message_routing import win as window_fixture  # noqa: F401
from test_console_capabilities import transport as transport_fixture, flush  # noqa: F401


def form(fields=None):
    return {"type": "param_picker", "component_id": "form", "fields": fields or [
        {"name": "first", "kind": "text", "default": "first default"},
        {"name": "second", "kind": "text", "default": "second default"},
    ]}


@pytest.fixture
def win(request):
    window = request.getfixturevalue("window_fixture")
    client = window.client
    client.connection_generation = CONNECTION
    client.authenticated = True
    window._resume_store.storage_key = "viewport-owner"
    window._continuity.bind_connection(CONNECTION)
    window._set_active_chat(CHAT, persist=False)
    window._continuity.open_request("hydration", HYDRATION)
    initial = _snapshot()
    initial["canvas"]["components"] = [form()]
    window._on_message(initial)
    window._on_message({"type": "chrome_menu", "model": copy.deepcopy(MENU)})
    window._on_message({"type": "rote_config", "viewport_snapshot_supported": True,
                        "device_profile": {"console": GEOMETRY[0]["presentation"]}})
    window._viewport.deferred.stop()
    sent = []
    client.update_device = lambda device, **kwargs: sent.append((device, kwargs)) or True

    def begin(purpose, chat, generation=None):
        generation = generation or str(uuid.uuid4())
        client.request_generation, client.request_purpose, client.request_chat_id = generation, purpose, chat
        return generation

    client.begin_conversation_request = begin
    window.viewport_sent = sent
    window.show()
    QApplication.processEvents()
    window._viewport_timer.stop()
    window._input.clearFocus()
    yield window


def start(win, width=390):
    win._viewport.observe(device_caps(width, 844, console=True))
    assert win._viewport.pending is not None
    return win._viewport.pending


def acknowledgment(ticket, **changes):
    frame = {"type": "rote_config", "viewport_snapshot_supported": True,
             "chat_id": ticket.chat, "connection_generation": ticket.connection,
             "request_generation": ticket.generation,
             "device_profile": {"console": copy.deepcopy(GEOMETRY[0]["presentation"])}}
    frame.update(changes)
    return frame


def snapshot(ticket, components=None, **changes):
    frame = _snapshot(request=ticket.generation, snapshot_id=str(uuid.uuid4()), revision=ticket.revision)
    frame["canvas"]["components"] = [form()] if components is None else components
    frame.update(changes)
    return frame


@pytest.mark.parametrize("snapshot_first", [False, True])
def test_exact_snapshot_and_layout_commit_together_preserving_state(win, snapshot_first):
    edits = win.canvas.findChildren(QLineEdit)
    edits[0].setText("edited first")
    edits[1].setText("edited second")
    edits[0].setSelection(2, 4)
    win._input.setPlainText("composer draft")
    win._attachments = [{"attachment_id": "kept", "status": "staged"}]
    selection = win._turn_selection = {"version": 1, "agent": None, "notes": [], "skills": []}
    win._console_shell.results.toggle_collapsed()
    old = win._rendered_snapshot
    old_layout = win._console_presentation
    ticket = start(win)
    reordered = form(list(reversed(form()["fields"])))
    frames = [acknowledgment(ticket), snapshot(ticket, [reordered])]
    if snapshot_first:
        frames.reverse()
    win._on_message(frames[0])
    assert win._rendered_snapshot is old and win._console_presentation is old_layout
    win._on_message(frames[1])
    assert win._viewport.pending is None
    assert win._continuity.request_completed
    assert win._rendered_snapshot.render_revision == old.render_revision
    assert [edit.text() for edit in win.canvas.findChildren(QLineEdit)] == ["edited second", "edited first"]
    assert win.canvas.findChildren(QLineEdit)[1].selectedText() == "ited"
    assert win._input.toPlainText() == "composer draft"
    assert win._attachments == [{"attachment_id": "kept", "status": "staged"}]
    assert win._turn_selection is selection
    assert win._console_shell.results.collapsed
    assert win._console_presentation["navigation_mode"] == "drawer"
    assert not any(action == "load_chat" for action, _ in win.client.sent)
    assert win._continuity.reduce_transient({
        "type": "ui_render", "chat_id": CHAT, "connection_generation": CONNECTION,
        "request_generation": ticket.generation, "base_render_revision": ticket.revision,
        "frame_sequence": 1, "components": [],
    }) == "transient_frame_ignored"


def test_coalesces_waiting_viewports_and_allocates_fresh_requests(win):
    first = start(win)
    win._viewport.observe(device_caps(320, 740, console=True))
    assert len(win.viewport_sent) == 1
    win._on_message(acknowledgment(first))
    win._on_message(snapshot(first))
    win._viewport.flush()
    second = win._viewport.pending
    assert second.generation != first.generation and second.submission != first.submission
    assert second.device["viewport_width"] == 320
    assert not win.viewport_sent[0][1]["is_current"]()


@pytest.mark.parametrize("field,value", [("render_revision", 8), ("snapshot_purpose", "commit"),
                                           ("schema_version", 99), ("canvas", {})])
def test_invalid_snapshot_retains_committed_content_and_offers_explicit_retry(win, field, value):
    old = win._rendered_snapshot
    ticket = start(win)
    win._on_message(snapshot(ticket, **{field: value}))
    assert win._viewport.pending is None and win._viewport.retry_required
    assert win._rendered_snapshot is old
    assert win._banner.property("viewport_retry")
    win._viewport.observe(device_caps(320, 740, console=True))
    assert len(win.viewport_sent) == 1
    win._on_banner_clicked()
    assert win._viewport.pending.generation != ticket.generation


@pytest.mark.parametrize("failure", ["timeout", "refusal", "admission", "send", "layout", "unsupported"])
def test_failure_retires_only_exact_refresh(win, failure):
    ticket = start(win)
    if failure == "timeout":
        win._viewport.timeout.timeout.emit()
    elif failure == "refusal":
        win._on_message({**acknowledgment(ticket), "type": "error", "code": "viewport_snapshot_retryable"})
    elif failure == "admission":
        win._on_message({"type": "error", "accepted": False, "submission_id": ticket.submission})
    elif failure == "send":
        win._on_status("viewport_update_failed:" + ticket.generation)
    elif failure == "layout":
        win._on_message(acknowledgment(ticket, device_profile={}))
    else:
        win._on_message(acknowledgment(ticket, viewport_snapshot_supported=1))
    assert win._viewport.retry_required and win._viewport.pending is None
    assert not win._viewport.timeout.isActive()
    assert win._continuity.request_generation is None
    assert win.client.request_generation is None
    win._viewport.retry()
    current = win._viewport.pending
    win._on_status("viewport_update_failed:" + ticket.generation)
    win._on_message({**acknowledgment(ticket), "type": "error", "code": "viewport_snapshot_rejected"})
    assert win._viewport.pending is current


@pytest.mark.parametrize("field,value", [("chat_id", OTHER_CHAT), ("connection_generation", OTHER_CONNECTION),
                                           ("request_generation", HYDRATION)])
def test_wrong_scope_snapshot_and_layout_are_ignored(win, field, value):
    ticket = start(win)
    before = win._rendered_snapshot
    win._on_message(acknowledgment(ticket, **{field: value}))
    win._on_message(snapshot(ticket, **{field: value}))
    assert ticket.layout is None and ticket.snapshot is None
    assert win._rendered_snapshot is before


@pytest.mark.parametrize("reason", ["turn", "phase", "upload", "voice", "download", "surface", "work", "export", "editing"])
def test_defers_until_work_or_editing_finishes(win, reason):
    def reset():
        return None
    if reason in {"turn", "phase"}:
        attribute = "_turn_active" if reason == "turn" else "_turn_phase_active"
        setattr(win, attribute, True)
        def reset():
            return setattr(win, attribute, False)
    elif reason == "upload":
        win._attachments = [{"status": "uploading"}]
        reset = win._attachments.clear
    elif reason == "voice":
        win._voice_controller.session_id = "active"
        def reset():
            return setattr(win._voice_controller, "session_id", None)
    elif reason == "download":
        win._viewport_downloads = 1
        def reset():
            return setattr(win, "_viewport_downloads", 0)
    elif reason == "surface":
        win._surface_dialog = QWidget()
        win._surface_dialog.show()
        def reset():
            return (win._surface_dialog.close(), setattr(win, "_surface_dialog", None))
    elif reason == "work":
        win._work_read = ("pending",)
        def reset():
            return setattr(win, "_work_read", None)
    elif reason == "export":
        win._workspace_actions = SimpleNamespace(_active={"export": "ticket"}, invalidate_stale=lambda: None)
        def reset():
            return setattr(win, "_workspace_actions", None)
    else:
        win.canvas.findChildren(QLineEdit)[0].setFocus()
        def reset():
            return win.canvas.findChildren(QLineEdit)[0].clearFocus()
    win._viewport.observe(device_caps(390, 844, console=True))
    assert win._viewport.pending is None and not win.viewport_sent
    reset()
    win._viewport.flush()
    assert win._viewport.pending is not None


@pytest.mark.parametrize("transition", ["chat", "connection", "owner", "commit", "disconnect"])
def test_scope_transitions_retire_authority_without_replay(win, transition):
    ticket = start(win)
    guard = win.viewport_sent[0][1]["is_current"]
    if transition == "chat":
        win._set_active_chat(OTHER_CHAT, persist=False)
    elif transition == "connection":
        win.client.connection_generation = OTHER_CONNECTION
        win._sync_transport_scope()
    elif transition == "owner":
        win._resume_store.storage_key = "another-owner"
        win._viewport.flush()
    elif transition == "commit":
        win._begin_conversation_request("commit", CHAT)
    else:
        win._on_status("closed:server")
    assert not guard() and win._viewport.pending is None
    win._on_message(acknowledgment(ticket))
    assert win._viewport.pending is None


def test_changed_or_ambiguous_control_identity_refuses_snapshot(win):
    ticket = start(win)
    original = win.canvas.findChildren(QLineEdit)[0]
    original.setText("private draft")
    win._on_message(acknowledgment(ticket))
    win._on_message(snapshot(ticket, [form([{"name": "other", "kind": "text"}])]))
    assert win._viewport.retry_required and original.text() == "private draft"
    assert win.canvas.findChildren(QLineEdit)[0] is original


def test_state_mapping_uses_names_and_values_not_field_or_option_order(qapp):
    ctx = RenderContext(emit=lambda *args: None)
    fields = [{"name": "text", "kind": "textarea", "default": "draft"},
              {"name": "choose", "kind": "select", "options": ["a", "b"]},
              {"name": "checked", "kind": "boolean", "default": True},
              {"name": "options", "kind": "checklist", "options": ["x", "y"], "default": ["y"]}]
    first = render(form(fields), ctx)
    first.findChild(QComboBox).setCurrentText("b")
    text = first.findChild(QPlainTextEdit)
    cursor = text.textCursor()
    cursor.setPosition(1)
    cursor.setPosition(4, cursor.MoveMode.KeepAnchor)
    text.setTextCursor(cursor)
    saved = capture_controls(first, strict=True)
    fields[1]["options"].reverse()
    fields.reverse()
    second = render(form(fields), ctx)
    restore_controls(second, saved, strict=True)
    assert second.findChild(QComboBox).currentText() == "b"
    assert second.findChild(QPlainTextEdit).textCursor().selectedText() == "raf"
    assert [button.text() for button in second.findChildren(QPushButton) if button.isCheckable() and button.isChecked()] == ["y"]
    first.deleteLater()
    second.deleteLater()


def test_unidentified_and_duplicate_controls_never_restore_positionally(qapp):
    root = QWidget()
    QLineEdit(root)
    assert capture_controls(root) == {}
    with pytest.raises(ControlIdentityError):
        capture_controls(root, strict=True)
    root.setProperty("component_id", "duplicate")
    QLineEdit(root)
    assert capture_controls(root) == {}
    with pytest.raises(ControlIdentityError):
        capture_controls(root, strict=True)
    root.deleteLater()


def test_scoped_transport_uses_current_delivery_and_validates_all_fields(monkeypatch):
    client = OrchestratorClient("ws://127.0.0.1:9/ws", "unused", device_caps())
    client.connection_generation = CONNECTION
    captured = []
    monkeypatch.setattr(client, "_send_current_frame", lambda frame, **kwargs: captured.append((frame, kwargs)) or True)
    generation, submission = str(uuid.uuid4()), str(uuid.uuid4())
    assert client.update_device(device_caps(390, 844), chat_id=CHAT, base_render_revision=7,
                                request_generation=generation, submission_id=submission)
    frame, delivery = captured[0]
    assert frame["payload"]["snapshot_purpose"] == "hydration"
    assert frame["payload"]["connection_generation"] == CONNECTION
    assert frame["payload"]["base_render_revision"] == 7
    assert frame["submission_id"] == submission and frame["request_generation"] == generation
    assert delivery["is_current"]() and not client._pending
    client.update_device(device_caps(320, 740))
    assert not delivery["is_current"]()
    with pytest.raises(WindowsProtocolError):
        client.update_device(device_caps(), chat_id=CHAT)
    with pytest.raises(WindowsProtocolError):
        client.update_device(device_caps(), chat_id=CHAT, base_render_revision=True,
                             request_generation=generation, submission_id=submission)


def test_edits_started_after_request_hold_snapshot_until_focus_leaves(win):
    ticket = start(win)
    field = win.canvas.findChildren(QLineEdit)[0]
    field.setFocus()
    field.setText("latest local edit")
    win._on_message(acknowledgment(ticket))
    win._on_message(snapshot(ticket))
    assert win._viewport.pending is ticket
    field.clearFocus()
    win._viewport.flush()
    assert win._viewport.pending is None
    assert win.canvas.findChildren(QLineEdit)[0].text() == "latest local edit"


def test_renegotiation_and_missing_transport_keep_legacy_updates(win):
    win._on_message({"type": "rote_config", "viewport_snapshot_supported": "true"})
    assert not win._viewport.supported
    win._viewport.observe(device_caps(390, 844))
    assert win._viewport.pending is None
    assert win.viewport_sent[-1][1] == {}
    win._viewport.observe(device_caps(390, 844))
    assert len(win.viewport_sent) == 1
    win.client.update_device = None
    win._viewport.observe(device_caps(320, 740))
    assert len(win.viewport_sent) == 1


def test_disconnected_or_unsettled_conversation_never_starts_hydration(win):
    win.client.authenticated = False
    win._viewport.observe(device_caps(390, 844))
    assert win._viewport.pending is None
    win.client.authenticated = True
    win._rendered_snapshot = None
    win._viewport.flush()
    assert win._viewport.deferred.isActive() and win._viewport.pending is None


def test_snapshot_conflicts_and_layout_conflicts_fail_closed(win):
    ticket = start(win)
    win._on_message(snapshot(ticket))
    win._on_message(snapshot(ticket))
    assert win._viewport.retry_required
    win._viewport.retry()
    ticket = win._viewport.pending
    win._on_message(acknowledgment(ticket))
    win._on_message(acknowledgment(ticket, device_profile={"console": GEOMETRY[5]["presentation"]}))
    assert win._viewport.retry_required


def test_late_owner_change_is_retired_before_frame_reduction(win):
    ticket = start(win)
    old = win._rendered_snapshot
    win._resume_store.storage_key = "new-owner"
    win._on_message(snapshot(ticket))
    assert win._viewport.pending is None and win._rendered_snapshot is old


def test_transport_send_refusal_and_snapshot_replay_leave_view_unchanged(win):
    win.client.update_device = lambda *args, **kwargs: False
    old = win._rendered_snapshot
    win._viewport.observe(device_caps(390, 844))
    assert win._viewport.retry_required and win._rendered_snapshot is old
    win.client.update_device = lambda *args, **kwargs: True
    win._viewport.retry()
    ticket = win._viewport.pending
    win._on_message(acknowledgment(ticket))
    win._on_message(snapshot(ticket, snapshot_id=old.snapshot_id))
    assert win._viewport.retry_required and win._rendered_snapshot is old


def test_transcript_adaptation_preserves_selection_and_fullscreen(win):
    label = next(label for label in win.rail.findChildren(QLabel) if "The result" in label.text())
    label.setSelection(4, 6)
    win._console_shell.set_fullscreen(True)
    ticket = start(win)
    update = snapshot(ticket)
    update["transcript"][0]["parts"].append({"type": "components", "components": [{"type": "text", "content": "Additional detail"}]})
    win._on_message(acknowledgment(ticket))
    win._on_message(update)
    assert win._viewport.pending is None
    assert win._console_shell.results.fullscreen
    assert any(label.selectedText() == "result" for label in win.rail.findChildren(QLabel))
    QApplication.processEvents()


def test_tabs_collapsible_and_named_control_identity_survive_reordering(qapp):
    ctx = RenderContext(emit=lambda *args: None)
    data = {"type": "tabs", "component_id": "tabs", "tabs": [
        {"id": "first", "label": "First", "children": []},
        {"id": "second", "label": "Second", "children": []}]}
    first = render(data, ctx)
    first.setCurrentIndex(1)
    saved = capture_controls(first, strict=True)
    data["tabs"].reverse()
    second = render(data, ctx)
    restore_controls(second, saved, strict=True)
    assert second.currentIndex() == 0
    assert second.findChildren(QTabWidget) == []
    data = {"type": "collapsible", "component_id": "fold", "title": "Details", "children": []}
    first = render(data, ctx)
    first.findChild(QPushButton).setChecked(True)
    second = render(data, ctx)
    restore_controls(second, capture_controls(first, strict=True), strict=True)
    assert second.findChild(QPushButton).isChecked()
    assert second.findChild(QPushButton).text().startswith("▾")
    named = {"type": "input", "label": "Unique setting", "value": "initial"}
    first, second = render(named, ctx), render(named, ctx)
    first.findChild(QLineEdit).setText("retained")
    restore_controls(second, capture_controls(first, strict=True), strict=True)
    assert second.findChild(QLineEdit).text() == "retained"


def test_missing_or_ambiguous_choice_fails_without_overwriting_other_controls(qapp):
    ctx = RenderContext(emit=lambda *args: None)
    first = render(form([{"name": "select", "kind": "select", "options": ["one", "two"]}]), ctx)
    first.findChild(QComboBox).setCurrentText("two")
    saved = capture_controls(first, strict=True)
    second = render(form([{"name": "select", "kind": "select", "options": ["one"]}]), ctx)
    with pytest.raises(ControlIdentityError):
        restore_controls(second, saved, strict=True)
    restore_controls(second, saved)
    assert second.findChild(QComboBox).currentText() == "one"
    restore_controls(QWidget(), saved)


@pytest.mark.parametrize("kind", ["ui_render", "ui_update", "ui_upsert", "ui_append", "ui_stream_data"])
def test_retired_refresh_never_falls_through_to_legacy_rendering(win, kind):
    ticket = start(win)
    old_components = copy.deepcopy(win.canvas._last_components)
    win._viewport.fail()
    win._on_message({"type": kind, "chat_id": CHAT, "connection_generation": CONNECTION,
                     "request_generation": ticket.generation, "base_render_revision": ticket.revision,
                     "frame_sequence": 1, "components": [{"type": "text", "content": "stale replacement"}]})
    assert win.canvas._last_components == old_components
    assert win.canvas._transient_overlay is None


@pytest.mark.parametrize("retirement", ["connection", "owner", "none"])
def test_scoped_frame_cannot_cross_async_transport_retirement(request, retirement):
    client, loop = request.getfixturevalue("transport_fixture")
    current = [True]
    generation, submission = str(uuid.uuid4()), str(uuid.uuid4())
    assert client.update_device(device_caps(390, 844), chat_id=CHAT, base_render_revision=7,
                                request_generation=generation, submission_id=submission,
                                is_current=lambda: current[0])
    if retirement == "connection":
        client.connection_generation = OTHER_CONNECTION
    elif retirement == "owner":
        current[0] = False
    flush(loop)
    assert len(client._ws.frames) == (1 if retirement == "none" else 0)
    assert not client._pending


def test_result_text_selection_survives_refresh_and_refuses_missing_target(win):
    text = {"type": "text", "component_id": "selected", "content": "Selected result text"}
    win.canvas.set_components([text])
    label = next(label for label in win.canvas.findChildren(QLabel) if label.text() == text["content"])
    label.setSelection(9, 6)
    ticket = start(win)
    win._on_message(acknowledgment(ticket))
    win._on_message(snapshot(ticket, [text]))
    assert any(label.selectedText() == "result" for label in win.canvas.findChildren(QLabel))
    ticket = start(win, 320)
    win._on_message(acknowledgment(ticket))
    win._on_message(snapshot(ticket, [{**text, "component_id": "replaced"}]))
    assert win._viewport.retry_required
    assert any(label.selectedText() == "result" for label in win.canvas.findChildren(QLabel))


def test_result_action_focus_survives_hydration(win):
    action = {"type": "button", "component_id": "action", "label": "Run", "action": "run"}
    win.canvas.set_components([action])
    win._console_shell.set_fullscreen(True)
    win.activateWindow()
    QApplication.processEvents()
    original = next(button for button in win.canvas.findChildren(QPushButton) if button.text() == "Run")
    original.setFocus()
    assert QApplication.focusWidget() is original
    ticket = start(win)
    win._on_message(acknowledgment(ticket))
    win._on_message(snapshot(ticket, [action]))
    assert win._viewport.pending is None
    focused = QApplication.focusWidget()
    assert focused is not original and focused.text() == "Run"
    assert win.canvas.isAncestorOf(focused)


def test_competing_operation_retires_then_resumes_coalesced_viewport(win):
    ticket = start(win)
    operation = LocalOperationSubmission(str(uuid.uuid4()), str(uuid.uuid4()), "save_theme", CHAT)
    win._project_local_submission(operation)
    assert win._viewport.pending is None and win._viewport.deferred.isActive()
    win._viewport.flush()
    assert win._viewport.pending is None
    win._finish_local_submission_by_id(operation.submission_id)
    win._viewport.flush()
    assert win._viewport.pending is not None
    assert win._viewport.pending.generation != ticket.generation
