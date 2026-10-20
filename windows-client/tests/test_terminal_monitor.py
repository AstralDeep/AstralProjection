"""Verifies the Windows terminal monitor fixture stays read-only and renders literal
terminal output through the existing generic chrome surface and code primitive.
"""

from __future__ import annotations

import json
from pathlib import Path
import uuid

import pytest
from test_message_routing import win as window_fixture  # noqa: F401

pytest.importorskip("PySide6")

from PySide6.QtWidgets import QPlainTextEdit  # noqa: E402

from astral_client.app import SurfaceDialog  # noqa: E402
from astral_client.renderer import RenderContext, render  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = json.loads(
    (ROOT / "contracts/fixtures/terminal/monitor_surface.json").read_text(encoding="utf-8")
)
MANIFEST = json.loads((ROOT / "contracts/ui_protocol.json").read_text(encoding="utf-8"))


def _walk(nodes):
    for node in nodes:
        yield node
        for key in ("content", "children"):
            if isinstance(node.get(key), list):
                yield from _walk(node[key])


def _actions(components):
    return [(node["action"], node["payload"]) for node in _walk(components)
            if node.get("type") == "button"]


def _code(components):
    return next(node for node in _walk(components) if node.get("type") == "code")


def test_terminal_fixture_is_read_only_and_correlated(qapp):
    contract = MANIFEST["presentation_contracts"]["terminal_monitor"]
    frame = FIXTURE["native_frame"]
    assert frame["surface_key"] == contract["surface_key"] == "terminal"
    assert set(frame) == set(contract["native_response"]["exact_fields"])
    assert frame["request_generation"] == FIXTURE["request"]["request_generation"]
    assert {action for action, _ in _actions(frame["components"])} == {"chrome_open", "chrome_close"}
    assert all(action in MANIFEST["accept_actions"] for action, _ in _actions(frame["components"]))
    assert not any(node["type"] in {"param_picker", "input"} for node in _walk(frame["components"]))


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
    dialog.begin_load("terminal", {}, "Terminal monitor")
    dialog.show()
    win._surface_dialog = dialog
    ticket = (win.client, connection, "synthetic-owner", str(uuid.uuid4()), "terminal", None)
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
    assert not dialog.isVisible() or dialog._title.text() == "Terminal monitor"
    win._on_chrome_surface(frame)
    assert win._settings_ticket is None


def test_terminal_close_and_disconnect_retire_the_monitor_locally(win):
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
