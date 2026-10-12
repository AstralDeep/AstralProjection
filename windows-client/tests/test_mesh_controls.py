"""Checks Mesh management at the physical Windows WebSocket boundary.
Strict action bodies remain separate from correlation, and retired owner or transport
requests never enter the offline queue or reach a replacement connection.
"""

import base64
import copy
import json
import uuid

import pytest
import test_console_capabilities

from astral_client.protocol import WindowsProtocolError
from test_console_capabilities import CONNECTION, Socket, flush


mesh_transport_fixture = test_console_capabilities.transport
IDENTITY = "a" * 32
PUBLIC = {"kty": "OKP", "crv": "Ed25519", "x": base64.urlsafe_b64encode(bytes(range(32))).rstrip(b"=").decode()}
CREATE = {"surface": "mesh", "fields": {
    "label": "Synthetic device", "device_key": json.dumps(PUBLIC),
    "scopes": "ui.read,tools.read", "ttl_seconds": "3600",
}}
CONTROLS = [
    ("chrome_mesh_create", CREATE),
    ("chrome_mesh_confirm", {"surface": "mesh", "invite_id": IDENTITY}),
    ("chrome_mesh_reject", {"surface": "mesh", "invite_id": IDENTITY}),
    ("chrome_mesh_rename", {"surface": "mesh", "member_id": IDENTITY, "fields": {"label": "Renamed device"}}),
    ("chrome_mesh_revoke", {"surface": "mesh", "member_id": IDENTITY}),
    ("chrome_mesh_remove_invitation", {"surface": "mesh", "invite_id": IDENTITY}),
]
NAVIGATION = [("chrome_open", {"surface": "mesh", "params": {}}), ("chrome_close", {"surface": "mesh"})]


@pytest.mark.parametrize("action,body", CONTROLS + NAVIGATION)
def test_mesh_physical_wire_has_exact_body_and_outer_correlation(mesh_transport_fixture, action, body):
    client, loop = mesh_transport_fixture
    payload = copy.deepcopy(body)
    generation = str(uuid.uuid4())
    assert client.send_current_settings("mesh", action, payload, generation)
    payload["surface"] = "changed"
    if "fields" in payload:
        payload["fields"]["label"] = "changed"
    flush(loop)
    frame = client._ws.frames[0]
    assert frame["payload"] == body
    assert frame["request_generation"] == generation
    assert frame["connection_generation"] == CONNECTION
    assert uuid.UUID(frame["submission_id"]).version == 4
    assert frame["session_id"] is None and not client._pending


@pytest.mark.parametrize("surface,action,body", [
    ("other", "chrome_mesh_confirm", {"surface": "mesh", "invite_id": IDENTITY}),
    ("mesh", "save_theme", {"surface": "mesh"}),
    ("mesh", "chrome_mesh_redeem", {"surface": "mesh", "fields": {"link": "private-link"}}),
    ("mesh", "chrome_mesh_identity", {"surface": "mesh"}),
    ("mesh", "chrome_mesh_unknown", {"surface": "mesh"}),
    ("mesh", "chrome_mesh_confirm", {"surface": "other", "invite_id": IDENTITY}),
    ("mesh", "chrome_mesh_confirm", {"invite_id": IDENTITY}),
    ("mesh", "chrome_mesh_confirm", {"surface": "mesh", "invite_id": IDENTITY, "owner_id": "foreign"}),
    ("mesh", "chrome_mesh_confirm", {"surface": "mesh", "invite_id": IDENTITY, "request_generation": "untrusted"}),
    ("mesh", "chrome_mesh_confirm", {"surface": "mesh", "invite_id": "../foreign"}),
    ("mesh", "chrome_mesh_confirm", {"surface": "mesh", "invite_id": True}),
    ("mesh", "chrome_open", {"surface": "mesh", "params": {"owner_id": "foreign"}}),
    ("mesh", "chrome_open", {"surface": "mesh", "params": []}),
    ("mesh", "chrome_close", {"surface": "mesh", "fields": {}}),
    ("mesh", "chrome_mesh_rename", {"surface": "mesh", "member_id": IDENTITY, "fields": {}}),
    ("mesh", "chrome_mesh_rename", {"surface": "mesh", "member_id": IDENTITY, "fields": {"label": ""}}),
    ("mesh", "chrome_mesh_rename", {"surface": "mesh", "member_id": IDENTITY, "fields": {"label": "é" * 129}}),
    ("mesh", "chrome_mesh_rename", {"surface": "mesh", "member_id": IDENTITY, "fields": {"label": "\ud800"}}),
])
def test_invalid_mesh_controls_never_reach_wire(mesh_transport_fixture, surface, action, body):
    client, loop = mesh_transport_fixture
    assert not client.send_current_settings(surface, action, body, str(uuid.uuid4()))
    flush(loop)
    assert not client._ws.frames and not client._pending


@pytest.mark.parametrize("field,value", [
    ("label", ""), ("label", True), ("scopes", "a" * 257), ("ttl_seconds", "1" * 17),
    ("device_key", ""), ("device_key", "{"), ("device_key", "a" * 2049),
    ("device_key", json.dumps(PUBLIC | {"d": "private"})),
    ("device_key", json.dumps(PUBLIC | {"x": PUBLIC["x"] + "="})),
])
def test_invalid_create_identity_or_fields_fail_closed(mesh_transport_fixture, field, value):
    client, loop = mesh_transport_fixture
    body = copy.deepcopy(CREATE)
    body["fields"][field] = value
    assert not client.send_current_settings("mesh", "chrome_mesh_create", body, str(uuid.uuid4()))
    flush(loop)
    assert not client._ws.frames and not client._pending


@pytest.mark.parametrize("changed", ["owner", "socket", "loop", "connection", "offline", "stopped", "auth_hold", "failure"])
def test_retired_mesh_write_cannot_reach_replacement_transport(mesh_transport_fixture, changed):
    client, loop = mesh_transport_fixture
    socket = client._ws
    current = [True]
    assert client.send_current_settings("mesh", "chrome_mesh_revoke", CONTROLS[4][1], str(uuid.uuid4()),
        is_current=lambda: current[0])
    if changed == "owner":
        current[0] = False
    elif changed == "socket":
        client._ws = Socket()
    elif changed == "loop":
        client._loop = None
    elif changed == "connection":
        client.connection_generation = str(uuid.uuid4())
    elif changed == "offline":
        client._connected = False
    elif changed == "stopped":
        client._stop = True
    elif changed == "auth_hold":
        client._auth_hold = True
    else:
        socket.fail = True
    flush(loop)
    assert not socket.frames and not client._pending


@pytest.mark.parametrize("action,body", CONTROLS + NAVIGATION)
def test_mesh_generic_sender_and_old_queue_are_never_replayed(mesh_transport_fixture, action, body):
    client, loop = mesh_transport_fixture
    client._connected = False
    client.send_event(action, body)
    assert not client._pending
    generation, submission = str(uuid.uuid4()), str(uuid.uuid4())
    legacy_body = copy.deepcopy(body) | {"submission_id": submission, "request_generation": generation}
    old = json.dumps({"type": "ui_event", "action": action, "session_id": None,
        "submission_id": submission, "request_generation": generation, "payload": legacy_body})
    assert client._queued_submission_from_frame(old) is None
    client._queue_frame(old)
    client._connected = True
    flush(loop)
    assert not client._pending and not client._ws.frames


def test_mesh_not_current_before_submission_and_invalid_generation(mesh_transport_fixture):
    client, loop = mesh_transport_fixture
    assert not client.send_current_settings("mesh", "chrome_mesh_create", CREATE, str(uuid.uuid4()), is_current=lambda: False)
    with pytest.raises(WindowsProtocolError):
        client.send_current_settings("mesh", "chrome_mesh_create", CREATE, "stale")
    flush(loop)
    assert not client._pending and not client._ws.frames
