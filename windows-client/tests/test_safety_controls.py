"""Exercises the shared owner stop and resume buttons in the actual Qt renderer.
The generic transport retains current owner and connection fencing.
"""

import json
import uuid
from pathlib import Path

import pytest
import test_console_capabilities
import test_console_shell
import test_message_routing
from PySide6.QtWidgets import QLabel, QPushButton

from astral_client.renderer import RenderContext, render
from test_console_capabilities import CONNECTION, Socket, flush


ROOT = Path(__file__).resolve().parents[2]
safety_transport_fixture = test_console_capabilities.transport
safety_window_fixture = test_console_shell.win
window_fixture = test_message_routing.win


def test_owner_safety_buttons_preserve_exact_offered_revision(qapp):
    fixture = json.loads((ROOT / "contracts/fixtures/safety/owner_stop.json").read_text(encoding="utf-8"))
    emitted = []
    widgets = []
    for component in fixture["buttons"]:
        widget = render(component, RenderContext(lambda action, payload: emitted.append((action, payload))))
        widgets.append(widget)
        button = widget if isinstance(widget, QPushButton) else widget.findChild(QPushButton)
        assert button.text() == component["label"]
        button.click()
    assert emitted == [(button["action"], button["payload"]) for button in fixture["buttons"]]


@pytest.mark.parametrize("action,payload", [("chrome_open", {"surface": "safety", "params": {}}),
    ("chrome_safety_stop", {"surface": "safety"}),
    ("chrome_safety_resume", {"surface": "safety", "expected_revision": 9007199254740991}),
    ("chrome_safety_verify", {"surface": "safety"})])
def test_safety_physical_wire_keeps_exact_payload_and_envelope_correlation(safety_transport_fixture, action, payload):
    client, loop = safety_transport_fixture
    generation = str(uuid.uuid4())
    assert client.send_current_settings("safety", action, payload, generation)
    flush(loop)
    frame = client._ws.frames[0]
    assert frame["payload"] == payload
    assert frame["request_generation"] == generation
    assert frame["connection_generation"] == CONNECTION
    assert uuid.UUID(frame["submission_id"]).version == 4
    assert frame["session_id"] is None and not client._pending


@pytest.mark.parametrize("surface,action,payload", [("safety", "save_theme", {"surface": "safety"}),
    ("theme", "chrome_safety_stop", {"surface": "safety"}),
    ("safety", "chrome_safety_stop", {"surface": "other"}),
    ("safety", "chrome_safety_stop", {"surface": "safety", "owner_id": "other"}),
    ("safety", "chrome_safety_stop", {"surface": "safety", "request_generation": "untrusted"}),
    ("safety", "chrome_open", {"surface": "safety", "params": []}),
    ("safety", "chrome_open", {"surface": "safety", "params": {"resume": True}})])
def test_invalid_safety_payload_cannot_be_sent(safety_transport_fixture, surface, action, payload):
    client, loop = safety_transport_fixture
    assert not client.send_current_settings(surface, action, payload, str(uuid.uuid4()))
    flush(loop)
    assert not client._ws.frames and not client._pending


@pytest.mark.parametrize("revision", [True, 0, -1, 1.5, "1", None, 9007199254740992])
def test_safety_resume_requires_a_portable_exact_revision(safety_transport_fixture, revision):
    client, loop = safety_transport_fixture
    assert not client.send_current_settings("safety", "chrome_safety_resume",
        {"surface": "safety", "expected_revision": revision}, str(uuid.uuid4()))
    flush(loop)
    assert not client._ws.frames


@pytest.mark.parametrize("action", ["chrome_open", "chrome_close", "chrome_safety_stop", "chrome_safety_resume", "chrome_safety_verify"])
def test_safety_generic_sender_and_old_queue_are_never_replayed(safety_transport_fixture, action):
    client, loop = safety_transport_fixture
    client._connected = False
    payload = {"surface": "safety", "expected_revision": 7}
    client.send_event(action, payload)
    assert not client._pending
    generation, submission = str(uuid.uuid4()), str(uuid.uuid4())
    payload.update(submission_id=submission, request_generation=generation)
    old = json.dumps({"type": "ui_event", "action": action, "session_id": None,
        "submission_id": submission, "request_generation": generation, "payload": payload})
    assert client._queued_submission_from_frame(old) is None
    client._queue_frame(old)
    client._connected = True
    flush(loop)
    assert not client._pending and not client._ws.frames


@pytest.mark.parametrize("changed", ["owner", "socket", "connection", "offline", "failure"])
def test_safety_rechecks_current_custody_and_never_queues_failed_writes(safety_transport_fixture, changed):
    client, loop = safety_transport_fixture
    socket = client._ws
    current = [True]
    assert client.send_current_settings("safety", "chrome_safety_resume",
        {"surface": "safety", "expected_revision": 7}, str(uuid.uuid4()), is_current=lambda: current[0])
    if changed == "owner":
        current[0] = False
    elif changed == "socket":
        client._ws = Socket()
    elif changed == "connection":
        client.connection_generation = str(uuid.uuid4())
    elif changed == "offline":
        client._connected = False
    else:
        socket.fail = True
    flush(loop)
    assert not socket.frames and not client._pending


def test_safety_current_response_and_uncertain_resume_retry_reload_status(safety_window_fixture):
    win = safety_window_fixture
    win._open_surface("safety", "Emergency stop")
    ticket = win._settings_ticket
    components = json.loads((ROOT / "contracts/fixtures/safety/owner_stop.json").read_text(encoding="utf-8"))["engaged"]
    response = {"surface_key": "safety", "components": components, "mode": "replace"}
    for generation in (None, str(uuid.uuid4())):
        win._on_chrome_surface(response | {"request_generation": generation})
        assert win._settings_ticket is ticket
    win._on_chrome_surface(response | {"request_generation": ticket[3]})
    assert win._settings_ticket is None
    resume = next(button for button in win._surface_dialog._inner.findChildren(QPushButton) if button.text() == "Resume explicitly")
    resume.click()
    pending = win._settings_ticket
    assert pending is not None
    win._on_status("settings_failed:" + pending[3])
    assert win._settings_ticket is None
    assert win._surface_dialog._retry_btn is not None
    assert any("Reload status" in label.text() for label in win._surface_dialog._inner.findChildren(QLabel))
    win._surface_dialog._retry_btn.click()
    assert win.client.sent[-1][0] == "chrome_open"
    assert win.client.sent[-1][1] == {"surface": "safety", "params": {}}
    assert win._settings_ticket[3] != pending[3]


def _settled_safety(win, state):
    win._open_surface("safety", "Emergency stop")
    ticket = win._settings_ticket
    components = json.loads((ROOT / "contracts/fixtures/safety/owner_stop.json").read_text(encoding="utf-8"))[state]
    response = {"surface_key": "safety", "components": components, "mode": "replace",
                "request_generation": ticket[3]}
    win._on_chrome_surface(response)
    assert win._settings_ticket is None
    return response, components[0]["action"], components[0]["payload"]


@pytest.mark.parametrize("state", ["running", "engaged"])
@pytest.mark.parametrize("status", ["closed:1006", "connecting", "reconnecting:1", "auth_required"])
def test_settled_safety_disconnect_requires_fresh_status_before_controls(safety_window_fixture, state, status):
    win = safety_window_fixture
    response, action, payload = _settled_safety(win, state)
    dialog = win._surface_dialog
    before = len(win.client.sent)
    win._on_status(status)
    assert dialog._surface_payload is None
    assert dialog._retained_controls is None
    assert not any(button.text() in {"Stop everything now", "Resume explicitly"}
                   for button in dialog._inner.findChildren(QPushButton))
    win.client.connection_generation = str(uuid.uuid4())
    win._on_status("connected")
    assert not any(name.startswith("chrome_safety_") for name, _ in win.client.sent[before:])
    before = len(win.client.sent)
    win._on_chrome_surface(response)
    assert win._emit(action, payload) is False
    assert len(win.client.sent) == before
    dialog._retry_btn.click()
    assert win.client.sent[-1] == ("chrome_open", {"surface": "safety", "params": {}})
    fresh = win._settings_ticket
    assert fresh is not None and fresh[3] != response["request_generation"]
    win._on_chrome_surface(response)
    assert win._settings_ticket is fresh and dialog._surface_payload is None
    win._on_chrome_surface(response | {"request_generation": fresh[3]})
    assert win._settings_ticket is None and dialog._surface_payload is not None
    button = next(button for button in dialog._inner.findChildren(QPushButton)
                  if button.text() in {"Stop everything now", "Resume explicitly"})
    button.click()
    assert win.client.sent[-1] == (action, payload)


@pytest.mark.parametrize("state", ["running", "engaged"])
@pytest.mark.parametrize("changed", ["owner", "connection", "socket"])
def test_settled_safety_controls_cannot_adopt_changed_custody(safety_window_fixture, state, changed):
    win = safety_window_fixture
    _, action, payload = _settled_safety(win, state)
    sent = win.client.sent
    before = len(sent)
    if changed == "owner":
        win._resume_store.storage_key = "different-synthetic-owner"
    elif changed == "connection":
        win.client.connection_generation = str(uuid.uuid4())
    else:
        from types import SimpleNamespace

        original = win.client
        win.client = SimpleNamespace(connection_generation=original.connection_generation,
            send_current_settings=original.send_current_settings)
    try:
        assert win._emit(action, payload) is False
        assert len(sent) == before and win._settings_ticket is None
        assert win._surface_dialog._surface_payload is None
    finally:
        if changed == "socket":
            win.client = original
