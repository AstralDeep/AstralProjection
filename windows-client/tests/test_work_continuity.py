"""Exercises explicit Work recovery through the displayed owner surface and current socket without replay."""

from uuid import uuid4

import pytest
from test_work_surface_088 import transport as transport, work_window as work_window, window_fixture as window_fixture, ready, frame, flush, CONNECTION
from astral_client.protocol import WindowsProtocolError


def command():
    return {"version": 1, "operation_id": str(uuid4()), "expected_revision": 7, "submission_id": str(uuid4())}


def offered(win):
    reads = ready(win)
    win._open_surface("work", "Recent work")
    payload = command()
    value = frame(reads[-1][1])
    value["components"] = [{"type": "button", "label": "Recheck completion", "action": "chrome_work_continuity", "payload": payload, "variant": "default", "disabled": False, "local": False}]
    win._on_chrome_surface(value)
    sent = []
    win.client.send_current_work_continuity = lambda value, generation, **kwargs: sent.append((value, generation, kwargs)) or True
    return payload, sent


def test_current_transport_preserves_command_and_correlation(transport):
    client, loop = transport
    payload, generation = command(), str(uuid4())
    seen = []
    client.submission.connect(seen.append)
    assert client.send_current_work_continuity(payload, generation)
    flush(loop)
    value = client._ws.frames[0]
    assert value == {"type": "ui_event", "action": "chrome_work_continuity", "session_id": None,
                     "submission_id": payload["submission_id"], "request_generation": generation,
                     "connection_generation": CONNECTION, "payload": payload}
    assert seen[0].submission_id == payload["submission_id"]
    assert not client._pending


@pytest.mark.parametrize("change", ["owner", "connection", "socket", "retired", "auth"])
def test_command_rechecks_before_actual_send(transport, change):
    client, loop = transport
    socket, generation, current = client._ws, str(uuid4()), [True]
    assert client.send_current_work_continuity(command(), generation, is_current=lambda: current[0])
    if change == "owner":
        current[0] = False
    elif change == "connection":
        client.connection_generation = str(uuid4())
    elif change == "socket":
        client._ws = type(socket)()
    elif change == "auth":
        client._auth_hold = True
    else:
        client.retire_work_read(generation)
    flush(loop)
    assert not socket.frames and not client._pending


def test_generic_command_is_never_retained(transport):
    client, loop = transport
    client._connected = False
    client.send_event("chrome_work_continuity", command())
    assert not client._pending
    with pytest.raises(WindowsProtocolError):
        client.send_current_work_continuity({**command(), "token": "forbidden"}, str(uuid4()))


@pytest.mark.parametrize("nested", [False, True])
def test_only_displayed_current_command_is_sent(win, nested):
    payload, sent = offered(win)
    if nested:
        win._surface_dialog._surface_payload = [{"type": "card", "content": win._surface_dialog._surface_payload}]
    win._emit("chrome_work_continuity", payload)
    assert len(sent) == 1
    assert sent[0][0] == payload
    assert sent[0][1] == win._work_read[3]
    assert win._surface_dialog._params == {"mode": "detail", "operation_id": payload["operation_id"]}
    assert win.client.sent == []


@pytest.mark.parametrize("change", ["owner", "connection", "closed", "not_offered", "auth", "mandatory", "busy", "invalid_body", "missing_sender", "send_refused"])
def test_retired_or_unoffered_command_never_uses_generic_queue(win, change):
    payload, sent = offered(win)
    if change == "owner":
        win._resume_store.storage_key = "new-owner"
    elif change == "connection":
        win.client.connection_generation = str(uuid4())
    elif change == "closed":
        win._surface_dialog.close()
    elif change == "auth":
        win._auth_stopped = True
    elif change == "mandatory":
        win._surface_dialog.set_mandatory(True)
    elif change == "busy":
        win._surface_dialog._timer.start()
    elif change == "invalid_body":
        payload = {**payload, "token": "forbidden"}
    elif change == "missing_sender":
        win.client.send_current_work_continuity = None
    elif change == "send_refused":
        win.client.send_current_work_continuity = lambda *_args, **_kwargs: False
    else:
        payload = {**payload, "expected_revision": 8}
    win._emit("chrome_work_continuity", payload)
    assert not sent and not win.client.sent


def test_work_surface_refuses_malformed_command_before_rendering(win):
    reads = ready(win)
    win._open_surface("work", "Recent work")
    payload = {**command(), "authority": "forbidden"}
    value = frame(reads[-1][1], "Malformed control")
    value["components"] = [{"type": "button", "label": "Recheck completion", "action": "chrome_work_continuity", "payload": payload,
                            "variant": "default", "disabled": False, "local": False}]
    win._on_chrome_surface(value)
    assert win._surface_dialog._title.text() == "Recent work"
    assert win._work_read is not None
