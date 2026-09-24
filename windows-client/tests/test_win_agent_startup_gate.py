"""Tests for windows-client startup gating of the tools agent (astral_client/app.py,
win_agent/agent.py): the orchestrator learns a listener exists only after
start_agent_thread actually binds, keeping _win_agent_enabled truthful.
"""

from __future__ import annotations

import os
import sys

import pytest

pytest.importorskip("PySide6")

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from astral_client.app import MainWindow  # noqa: E402


@pytest.fixture(autouse=True)
def _contained_side_effects():
    import win_agent.agent as wa
    import win_agent.tools as wt

    started = []
    real = wa.start_agent_thread
    saved_workspace = wt._WORKSPACE_OVERRIDE

    def _tracking(*a, **k):
        thread = real(*a, **k)
        if thread is not None:
            started.append(thread)
        return thread

    wa.start_agent_thread = _tracking
    try:
        yield
    finally:
        wa.start_agent_thread = real
        wt._WORKSPACE_OVERRIDE = saved_workspace
        for thread in started:
            loop = getattr(thread, "_astral_loop", None)
            if loop is not None:
                loop.call_soon_threadsafe(loop.stop)
            thread.join(timeout=2)


def _window(monkeypatch, *, key: str | None):
    if key is None:
        monkeypatch.delenv("AGENT_API_KEY", raising=False)
    else:
        monkeypatch.setenv("AGENT_API_KEY", key)
    monkeypatch.setenv("ASTRAL_WIN_AGENT", "1")
    monkeypatch.setenv("ASTRAL_AGENT_BIND", "127.0.0.1")
    monkeypatch.setenv("WIN_AGENT_PORT", "0")
    return MainWindow("ws://127.0.0.1:8001/ws", "t", connect=False)


def test_no_key_disables_the_feature_entirely(qapp, monkeypatch):
    win = _window(monkeypatch, key=None)
    assert win._win_agent_thread is None
    assert win._win_agent_enabled is False, (
        "a refused listener must disable the feature, or _on_status will still "
        "send register_external_agent for a port nothing is serving"
    )


def test_weak_key_is_treated_as_no_key(qapp, monkeypatch):
    win = _window(monkeypatch, key="short")
    assert win._win_agent_thread is None
    assert win._win_agent_enabled is False


def test_usable_key_starts_the_listener(qapp, monkeypatch):
    win = _window(monkeypatch, key="startup-gate-key-0123456789ab")
    assert win._win_agent_thread is not None
    assert win._win_agent_enabled is True


def test_start_is_idempotent_across_deferred_first_run(qapp, monkeypatch):
    win = _window(monkeypatch, key="startup-gate-key-0123456789ab")
    first = win._win_agent_thread
    assert first is not None
    win.maybe_start_tools_agent()
    win.maybe_start_tools_agent()
    assert win._win_agent_thread is first


def test_key_arriving_after_construction_still_starts_the_listener(qapp, monkeypatch):
    win = _window(monkeypatch, key=None)
    assert win._win_agent_thread is None
    monkeypatch.setenv("AGENT_API_KEY", "late-arriving-key-0123456789")
    win.maybe_start_tools_agent()
    assert win._win_agent_thread is not None
    assert win._win_agent_enabled is True


def test_a_failed_bind_is_reported_as_a_failure(qapp, monkeypatch):
    import win_agent.agent as wa

    monkeypatch.setenv("AGENT_API_KEY", "bind-failure-key-0123456789ab")

    class _Boom:
        def __init__(self, *a, **k):
            pass

        async def start(self):
            raise OSError("address already in use")

    monkeypatch.setattr(wa.web, "TCPSite", _Boom)
    assert wa.start_agent_thread(host="127.0.0.1", port=0) is None


def test_the_deferred_call_site_exists_and_is_ordered_after_config(qapp):
    import inspect

    from astral_client import app as appmod

    src = inspect.getsource(appmod._launch)
    body = src.split("_after_first_paint", 1)[1]
    code = "\n".join(ln for ln in body.splitlines()
                     if not ln.lstrip().startswith("#"))
    assert "maybe_start_tools_agent()" in code
    assert code.index("_resolve_config(") < code.index("maybe_start_tools_agent()")


def test_refusal_is_surfaced_to_the_user(qapp, monkeypatch):
    shown = []
    monkeypatch.setattr(MainWindow, "_show_banner",
                        lambda self, text, kind="info", *a, **k: shown.append((text, kind)))
    _window(monkeypatch, key=None)
    assert shown == [], "the notice must not fire inside __init__"
    qapp.processEvents()
    assert shown, "no banner shown when the tools listener was refused"
    text, kind = shown[-1]
    assert "AGENT_API_KEY" in text
    assert kind == "warning"


def test_the_refusal_notice_fires_once_not_per_retry(qapp, monkeypatch):
    shown = []
    monkeypatch.setattr(MainWindow, "_show_banner",
                        lambda self, text, kind="info", *a, **k: shown.append((text, kind)))
    win = _window(monkeypatch, key=None)
    for _ in range(3):
        win.maybe_start_tools_agent()
        qapp.processEvents()
    assert len(shown) == 1, f"notice fired {len(shown)} times"


def test_a_later_success_cancels_the_pending_refusal_notice(qapp, monkeypatch):
    shown = []
    monkeypatch.setattr(MainWindow, "_show_banner",
                        lambda self, text, kind="info", *a, **k: shown.append((text, kind)))
    win = _window(monkeypatch, key=None)
    monkeypatch.setenv("AGENT_API_KEY", "late-arriving-key-0123456789")
    win.maybe_start_tools_agent()
    qapp.processEvents()
    assert win._win_agent_thread is not None
    assert shown == [], "told the user tools were off after they came up"
