"""Verifies the Windows terminal panel fixture stays correlated, renders literal terminal
output through the existing generic chrome surface and code primitive, and submits only the
governed terminal operations on the interactive desktop disposition.
"""

from __future__ import annotations

import json
from pathlib import Path
import uuid

import pytest

pytest.importorskip("PySide6.QtWidgets", exc_type=ImportError)

from PySide6.QtWidgets import QPlainTextEdit  # noqa: E402

from astral_client.app import SurfaceDialog  # noqa: E402
from astral_client.renderer import RenderContext, render  # noqa: E402
from test_message_routing import win as window_fixture  # noqa: E402, F401

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = json.loads(
    (ROOT / "contracts/fixtures/terminal/panel_surface.json").read_text(encoding="utf-8")
)
MANIFEST = json.loads((ROOT / "contracts/ui_protocol.json").read_text(encoding="utf-8"))
INTERACTIVE = {"chrome_terminal_input", "chrome_terminal_resize",
               "chrome_terminal_interrupt", "chrome_terminal_close"}


def _walk(nodes):
    for node in nodes:
        yield node
        for key in ("content", "children", "fields"):
            if isinstance(node.get(key), list):
                yield from _walk(node[key])


def _actions(components):
    return [(node.get("action") or node.get("submit_action"), node)
            for node in _walk(components)
            if node.get("type") in {"button", "param_picker"} and
            (node.get("action") or node.get("submit_action"))]


def _code(components):
    return next(node for node in _walk(components) if node.get("type") == "code")


def test_manifest_declares_the_governed_terminal_operations():
    contract = MANIFEST["presentation_contracts"]["terminal_panel"]
    actions = set(MANIFEST["accept_actions"])
    assert INTERACTIVE <= actions
    assert set(contract["actions"]) == INTERACTIVE
    assert contract["dispositions"]["windows"] == "interactive_panel"
    assert contract["dispositions"]["browser"] == "interactive_panel"
    assert contract["dispositions"]["android"] == "read_only_monitor"
    assert contract["dispositions"]["watchos"] == "phone_desktop_handoff"
    assert contract["dispositions"]["voice"] == "omitted_by_server"


def test_interactive_fixture_submits_only_governed_operations():
    frame = FIXTURE["native_frame"]
    assert frame["surface_key"] == "terminal"
    assert set(frame) == set(
        MANIFEST["presentation_contracts"]["terminal_panel"]["native_response"]["exact_fields"])
    assert frame["request_generation"] == FIXTURE["request"]["request_generation"]
    used = {action for action, _ in _actions(frame["components"])}
    assert used <= {"chrome_open", "chrome_close"} | INTERACTIVE
    assert INTERACTIVE <= used
    for action, node in _actions(frame["components"]):
        if action in INTERACTIVE and node["type"] == "button":
            assert set(node["payload"]) == {"surface", "session_id"}
            assert node["payload"]["surface"] == "terminal"
    for node in _walk(frame["components"]):
        if node.get("type") == "param_picker":
            assert set(node["submit_payload"]) == {"surface", "session_id"}
            if node["submit_action"] == "chrome_terminal_input":
                assert [f["name"] for f in node["fields"]] == ["data"]
            else:
                assert [f["name"] for f in node["fields"]] == ["cols", "rows"]


def test_read_only_fixture_frames_never_carry_interactive_controls():
    for name in ("list", "panel", "malicious", "closed"):
        frame = FIXTURE["read_only_frames"][name]
        used = {action for action, _ in _actions(frame["components"])}
        assert used == {"chrome_open", "chrome_close"}, name
        assert not any(node.get("type") == "param_picker" for node in _walk(frame["components"]))


def test_terminal_output_renders_as_exact_read_only_text(qapp):
    frame = FIXTURE["frames"]["malicious"]
    expected = FIXTURE["expected_sanitized_text"]
    widget = render(_code(frame["components"]), RenderContext(emit=lambda _action, _payload: None))
    edit = widget.findChild(QPlainTextEdit)
    assert edit is not None and edit.isReadOnly()
    assert edit.toPlainText() == expected
    assert "\x1b" not in edit.toPlainText()
    assert "evil.example" not in edit.toPlainText()
    assert "clipboard theft" not in edit.toPlainText()


@pytest.fixture(name="win")
def terminal_window(request):
    return request.getfixturevalue("window_fixture")


def _pending_terminal(win):
    connection = "22222222-2222-4222-8222-222222222222"
    win.client.connection_generation = connection
    win._resume_store.storage_key = "synthetic-owner"
    dialog = SurfaceDialog(win, emit=win._emit)
    dialog.begin_load("terminal", {}, "Terminal panel")
    dialog.show()
    win._surface_dialog = dialog
    ticket = (win.client, connection, "synthetic-owner", str(uuid.uuid4()), "terminal", win.active_chat)
    win._settings_ticket = ticket
    frame = dict(FIXTURE["native_frame"])
    frame["request_generation"] = ticket[3]
    return dialog, ticket, frame


def test_terminal_reply_is_correlated_exact_and_rejects_extra_fields(win):
    dialog, ticket, frame = _pending_terminal(win)
    win._on_chrome_surface(frame)
    assert win._settings_ticket is None
    assert dialog._title.text() == frame["title"]
    assert dialog._surface == "terminal"
    stale = dict(frame)
    stale["request_generation"] = str(uuid.uuid4())
    win._on_chrome_surface(stale)
    assert dialog._title.text() == frame["title"]
    dialog, ticket, frame = _pending_terminal(win)
    invalid = dict(frame)
    invalid["extra"] = "untrusted"
    win._on_chrome_surface(invalid)
    assert win._settings_ticket is ticket
    assert not dialog.isVisible() or dialog._title.text() == "Terminal panel"
    win._on_chrome_surface(frame)
    assert win._settings_ticket is None


def test_terminal_close_and_disconnect_retire_the_panel_locally(win):
    dialog, ticket, frame = _pending_terminal(win)
    win._on_chrome_surface(frame)
    assert dialog._surface == "terminal"
    win._emit("chrome_close", {"surface": "terminal"})
    assert not dialog.isVisible()
    dialog, ticket, frame = _pending_terminal(win)
    win._on_chrome_surface(frame)
    assert dialog._surface == "terminal"
    win._on_status("closed")
    assert not dialog.isVisible()


@pytest.mark.parametrize("transition", ["new", "load", "send"])
@pytest.mark.parametrize("delivered", [False, True])
def test_terminal_navigation_and_send_retire_pending_and_displayed_output(win, transition, delivered):
    win._set_active_chat("44444444-4444-4444-8444-444444444444", persist=False)
    dialog, ticket, frame = _pending_terminal(win)
    if delivered:
        win._on_chrome_surface(frame)
        assert dialog._surface_payload
    if transition == "new":
        win._new_chat()
    elif transition == "load":
        win._load_chat("55555555-5555-4555-8555-555555555555")
    else:
        win._input.setText("Synthetic terminal retirement")
        win._send()
    assert not win._settings_current(ticket)
    assert win._settings_ticket is None
    assert not dialog.isVisible()
    frame["title"] = "Retired terminal output"
    win._on_chrome_surface(frame)
    assert dialog._title.text() != frame["title"]
    assert not dialog._surface_payload
