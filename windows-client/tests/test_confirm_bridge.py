"""Tests for astral_client/confirm.py: the cross-thread confirmation bridge's
request/reply correlation, timeout and not-attached fail-closed paths, and the
directory-picker round trip, driven without a Qt display.
"""

from __future__ import annotations

import os
import sys
import threading

import pytest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import astral_client.confirm as confirm  # noqa: E402


@pytest.fixture(autouse=True)
def _restore_bridge_singleton():
    saved = confirm.BRIDGE
    yield
    confirm.BRIDGE = saved


def _drain_in_thread(b):
    def gui_tick():
        try:
            req = b._q.get(timeout=5)
        except Exception:  # noqa: BLE001
            return
        b._show_and_reply(req)

    t = threading.Thread(target=gui_tick)
    t.start()
    return t


def _make_bridge(monkeypatch, show_fn, *, attach=True):
    monkeypatch.setenv("ASTRAL_CONFIRM_TIMEOUT", "3")
    b = confirm._Bridge()
    if attach:
        b.attach(show_fn)
    return b


def test_request_confirm_allow(monkeypatch):
    b = _make_bridge(monkeypatch, lambda req: {"accepted": True, "choice": None})
    t = _drain_in_thread(b)
    reply = b.request_confirm(
        {"kind": "action", "tool": "write_file", "preview": "x=1"}
    )
    t.join(timeout=2)
    assert reply["accepted"] is True


def test_request_confirm_deny(monkeypatch):
    b = _make_bridge(monkeypatch, lambda req: {"accepted": False, "choice": None})
    t = _drain_in_thread(b)
    reply = b.request_confirm({"kind": "action", "tool": "write_file"})
    t.join(timeout=2)
    assert reply["accepted"] is False


def test_timeout_fail_closed(monkeypatch):
    b = _make_bridge(monkeypatch, lambda req: {"accepted": True, "choice": None})
    reply = b.request_confirm({"kind": "action", "tool": "write_file"})
    assert reply["accepted"] is False
    assert reply.get("reason") == "timeout"


def test_not_attached_fail_closed(monkeypatch):
    b = _make_bridge(monkeypatch, lambda req: {"accepted": True}, attach=False)
    reply = b.request_confirm({"kind": "action", "tool": "write_file"})
    assert reply["accepted"] is False
    assert reply.get("reason") == "no_gui"


def test_dialog_error_fail_closed(monkeypatch):
    def boom(req):
        raise RuntimeError("qt exploded")

    b = _make_bridge(monkeypatch, boom)
    t = _drain_in_thread(b)
    reply = b.request_confirm({"kind": "action", "tool": "write_file"})
    t.join(timeout=2)
    assert reply["accepted"] is False
    assert reply.get("reason") == "dialog_error"


def test_stale_reply_never_approves_the_next_request(monkeypatch):
    monkeypatch.setenv("ASTRAL_CONFIRM_TIMEOUT", "1")
    b = confirm._Bridge()
    b.attach(lambda req: {"accepted": True, "choice": None})

    first = b.request_confirm({"kind": "action", "tool": "write_file"})
    assert first["accepted"] is False and first.get("reason") == "timeout"

    stale_req = b._q.get(timeout=2)
    b._show_and_reply(stale_req)

    def deny_second(req):
        return {"accepted": False, "choice": None}

    b._show_fn = deny_second
    t = _drain_in_thread(b)
    second = b.request_confirm({"kind": "action", "tool": "delete_file"})
    t.join(timeout=3)
    assert second["accepted"] is False


def test_directory_pick_returns_choice(monkeypatch):
    b = _make_bridge(
        monkeypatch, lambda req: {"accepted": True, "choice": "C:/Users/me/Workspace"}
    )
    confirm.BRIDGE = b
    t = _drain_in_thread(b)
    path = confirm.pick_directory()
    t.join(timeout=2)
    assert path == "C:/Users/me/Workspace"


def test_directory_pick_cancelled_returns_none(monkeypatch):
    b = _make_bridge(monkeypatch, lambda req: {"accepted": False, "choice": None})
    confirm.BRIDGE = b
    t = _drain_in_thread(b)
    path = confirm.pick_directory()
    t.join(timeout=2)
    assert path is None
