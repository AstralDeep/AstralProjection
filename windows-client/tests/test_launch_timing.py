"""Tests for astral_client/app.py: window-first launch timing — a visible MainWindow
appears before auth resolution completes, the --token fast path stays synchronous,
and login cancellation unblocks into a retry state.
"""

import os
import threading
import time
import types

import pytest

pytest.importorskip("PySide6")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ["ASTRAL_WIN_AGENT"] = "0"

from astral_client import app as appmod  # noqa: E402
from astral_client.app import MainWindow  # noqa: E402


class _FakeSettings:
    def __init__(self, d=None):
        self.d = dict(d or {})

    def value(self, key, default="", type=str):
        return self.d.get(key, default)

    def setValue(self, key, val):
        self.d[key] = val


class _FakeSig:
    def connect(self, *_a):
        pass

    def disconnect(self, *_a):
        pass


class _FakeClient:
    message = _FakeSig()
    status = _FakeSig()

    def __init__(self, url, token, caps=None, *, work_reads=False):
        self.url = url
        self.token = token
        self.work_reads = work_reads
        self.running = False

    def start(self):
        self.running = True

    def stop(self):
        self.running = False

    def send_event(self, *_a, **_k):
        pass


def _args(token=""):
    return types.SimpleNamespace(
        token=token,
        authority="https://kc.example/realms/R",
        url="ws://127.0.0.1:9/ws",
        client_id="astral-desktop",
        bff=False,
    )


def _pump_until(qapp, predicate, timeout=5.0):
    deadline = time.monotonic() + timeout
    while not predicate() and time.monotonic() < deadline:
        qapp.processEvents()
        time.sleep(0.01)
    return predicate()


@pytest.fixture
def launch_env(qapp, monkeypatch):
    monkeypatch.setattr(appmod, "OrchestratorClient", _FakeClient)
    monkeypatch.setattr(MainWindow, "_start_integrity_check", lambda self: None)
    monkeypatch.setattr(MainWindow, "_init_workspace", lambda self: None)
    monkeypatch.setenv("ASTRAL_WIN_AGENT", "0")
    monkeypatch.delenv("KEYCLOAK_AUTHORITY", raising=False)
    monkeypatch.delenv("ASTRAL_WS_URL", raising=False)
    monkeypatch.delenv("AGENT_API_KEY", raising=False)
    return qapp


def test_window_visible_within_1s_and_before_auth_resolves(launch_env, monkeypatch):
    qapp = launch_env
    gate = threading.Event()
    auth_started = threading.Event()
    auth_resolved = threading.Event()

    def blocking_resolve_auth(args, cancel_event=None):
        auth_started.set()
        gate.wait(10)
        auth_resolved.set()
        return "tok-after-gate", None

    monkeypatch.setattr(appmod, "resolve_auth", blocking_resolve_auth)
    settings = _FakeSettings({"config/authority": "https://kc.example/realms/R",
                              "config/ws_url": "ws://127.0.0.1:9/ws"})
    t0 = time.monotonic()
    win = appmod._launch(_args(), settings=settings)
    elapsed = time.monotonic() - t0
    try:
        assert win.isVisible()
        assert elapsed < 1.0
        assert not auth_resolved.is_set()

        assert _pump_until(qapp, auth_started.is_set)
        assert win.isVisible() and not auth_resolved.is_set()
        assert win._login_active

        gate.set()
        assert _pump_until(qapp, lambda: win._token == "tok-after-gate")
        assert win.client.token == "tok-after-gate"
        assert win.client.running
        assert not win._login_active
    finally:
        gate.set()
        win.close()


def test_token_fast_path_is_synchronous_and_fast(launch_env):
    t0 = time.monotonic()
    win = appmod._launch(_args(token="dev-token"), settings=_FakeSettings())
    try:
        assert win.isVisible()
        assert time.monotonic() - t0 < 1.0
        assert win._token == "dev-token"
        assert win.client.running
        assert not win._login_active
    finally:
        win.close()


def test_cancel_login_unblocks_and_reaches_retry_state(launch_env, monkeypatch):
    qapp = launch_env
    prompts = []
    monkeypatch.setattr(MainWindow, "_login_retry_prompt",
                        lambda self, verb: prompts.append(verb))
    win = MainWindow("ws://127.0.0.1:9/ws", "", login_params={}, connect=False)
    try:
        def resolver(cancel_event):
            cancel_event.wait(10)
            raise appmod.LoginCancelled("cancelled")

        win.begin_login(resolver)
        assert win._login_active
        win.cancel_login()
        assert _pump_until(qapp, lambda: bool(prompts))
        assert prompts == ["cancelled"]
        assert not win._login_active
    finally:
        win.close()
