"""Tests for astral_client/app.py, win_agent/byo_host.py, and byo_worker.py: bundle
delivery/spawn, stdout/stdin tunnel framing, stop/reconnect/rehydrate lifecycle,
revision rollover, and MainWindow frame routing.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time

import pytest

from win_agent import byo_host
from win_agent.byo_host import ByoAgentHost


class _Pipe:
    def __init__(self):
        self._lines = []
        self._closed = False
        self._cv = threading.Condition()

    def feed(self, text: str) -> None:
        with self._cv:
            self._lines.append(text if text.endswith("\n") else text + "\n")
            self._cv.notify_all()

    def readline(self) -> str:
        with self._cv:
            while not self._lines and not self._closed:
                self._cv.wait(2)
            if self._lines:
                return self._lines.pop(0)
            return ""

    def close(self) -> None:
        with self._cv:
            self._closed = True
            self._cv.notify_all()


class _Stdin:
    def __init__(self):
        self.written = []
        self.closed = False

    def write(self, text):
        if self.closed:
            raise ValueError("closed")
        self.written.append(text)

    def flush(self):
        pass

    def close(self):
        self.closed = True


class _FakeProc:
    pid = 4242

    def __init__(self):
        self.stdin = _Stdin()
        self.stdout = _Pipe()
        self.stderr = _Pipe()
        self.terminated = False
        self._rc = None

    def poll(self):
        return self._rc

    def terminate(self):
        self.terminated = True
        self._rc = -15
        self.stdout.close()
        self.stderr.close()

    def exit(self, code=0):
        self._rc = code
        self.stdout.close()
        self.stderr.close()


class _Host:
    def __init__(self, tmp_path, register_timeout=5.0):
        self.sent = []
        self.notices = []
        self.procs = {}
        self.spawned = []

        def spawn(argv):
            proc = _FakeProc()
            self.spawned.append(argv)
            self.procs[argv[-1]] = proc
            return proc

        self.host = ByoAgentHost(
            send_event=lambda a, p: self.sent.append((a, p)),
            notify=lambda text, level="info": self.notices.append((text, level)),
            base_dir=str(tmp_path),
            spawn=spawn,
            register_timeout=register_timeout,
        )

    @property
    def proc(self) -> _FakeProc:
        return next(iter(self.procs.values()))

    def tunnelled(self):
        return [json.loads(p["frame"]) for a, p in self.sent if a == "agent_tunnel"]

    def wait_for(self, predicate, timeout=2.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if predicate():
                return True
            time.sleep(0.01)
        return False


BUNDLE = {
    "agent_main.py": "print('hi')\n",
    "mcp_tools.py": "TOOL_REGISTRY = {}\n",
    "manifest.json": '{"agent_id": "ua-notes-abc123"}\n',
}
AGENT = "ua-notes-abc123"
REG = {"type": "register_agent", "agent_card": {"agent_id": AGENT}}


@pytest.fixture
def host(tmp_path):
    h = _Host(tmp_path)
    yield h
    h.host.stop_all()


def test_bundle_is_written_and_a_child_spawned(host, tmp_path):
    directory = host.host.deliver(AGENT, BUNDLE)

    assert directory == str(tmp_path / AGENT)
    for name, source in BUNDLE.items():
        assert (tmp_path / AGENT / name).read_text(encoding="utf-8") == source
    assert host.spawned and host.spawned[0][-2:] == ["--byo-worker", directory]
    assert host.host.running() == [AGENT]


def test_bundle_entry_with_a_path_is_refused(host, tmp_path):
    host.host.deliver(AGENT, dict(BUNDLE, **{"../../evil.py": "boom"}))
    assert not (tmp_path.parent / "evil.py").exists()
    assert not (tmp_path / "evil.py").exists()
    assert (tmp_path / AGENT / "agent_main.py").exists()


# agent_id is a directory name; '..' would escape the root
@pytest.mark.parametrize("bad", ["../escape", "..", ".", ".hidden", "a/b", "", "x" * 129])
def test_unusable_agent_id_is_refused(host, tmp_path, bad):
    assert host.host.deliver(bad, BUNDLE) is None
    assert host.spawned == []
    assert not (tmp_path / "agent_main.py").exists()


def test_agent_dir_never_escapes_the_agents_root(host, tmp_path):
    assert host.host._agent_dir(AGENT) == str(tmp_path / AGENT)
    assert host.host._agent_dir("..") is None
    assert host.host._agent_dir("../../etc") is None


def test_child_stdout_line_becomes_an_agent_tunnel_event(host):
    host.host.deliver(AGENT, BUNDLE)
    host.proc.stdout.feed(json.dumps({"type": "register_agent", "agent_card": {"agent_id": AGENT}}))

    assert host.wait_for(lambda: host.tunnelled())
    action, payload = next(x for x in host.sent if x[0] == "agent_tunnel")
    assert payload["agent_id"] == AGENT
    assert payload["host_session_id"] == host.host.host_session_id
    assert isinstance(payload["frame"], str)
    assert json.loads(payload["frame"])["type"] == "register_agent"


def test_non_json_stdout_line_is_discarded(host):
    host.host.deliver(AGENT, BUNDLE)
    host.proc.stdout.feed("DEBUG: about to call the api")
    host.proc.stdout.feed("[1, 2, 3]")
    host.proc.stdout.feed(json.dumps({"type": "mcp_response", "request_id": "r1"}))

    assert host.wait_for(lambda: host.tunnelled())
    frames = host.tunnelled()
    assert [f["type"] for f in frames] == ["mcp_response"]


def test_inbound_tunnel_frame_reaches_child_stdin(host):
    host.host.deliver(AGENT, BUNDLE)
    inner = json.dumps({"type": "mcp_request", "request_id": "r1", "method": "tools/list"})

    consumed = host.host.handle_frame(
        {"type": "agent_tunnel", "agent_id": AGENT, "frame": inner}
    )

    assert consumed
    assert host.proc.stdin.written == [inner + "\n"]


def test_inbound_tunnel_frame_tolerates_a_nested_object(host):
    host.host.deliver(AGENT, BUNDLE)
    host.host.handle_frame({
        "type": "agent_tunnel", "agent_id": AGENT,
        "frame": {"type": "mcp_request", "request_id": "r2"},
    })
    written = host.proc.stdin.written[0]
    assert written.endswith("\n") and json.loads(written)["request_id"] == "r2"


def test_inbound_tunnel_for_unknown_agent_is_dropped(host):
    host.host.handle_frame({"type": "agent_tunnel", "agent_id": "ua-nope", "frame": "{}"})
    assert host.procs == {}


def test_register_agent_for_a_different_agent_id_is_dropped(host):
    host.host.deliver(AGENT, BUNDLE)
    host.proc.stdout.feed(json.dumps(
        {"type": "register_agent", "agent_card": {"agent_id": "ua-someone-else"}}))
    host.proc.stdout.feed(json.dumps({"type": "mcp_response", "request_id": "r1"}))

    assert host.wait_for(lambda: host.tunnelled())
    assert [f["type"] for f in host.tunnelled()] == ["mcp_response"]

    host.sent.clear()
    host.host.on_ui_connected()
    assert host.tunnelled() == []


def test_agent_stop_terminates_the_child_and_removes_the_bundle(host, tmp_path):
    host.host.deliver(AGENT, BUNDLE)
    proc = host.proc
    assert (tmp_path / AGENT / "agent_main.py").exists()

    host.host.handle_frame({"type": "agent_stop", "agent_id": AGENT})

    assert proc.terminated
    assert proc.stdin.closed
    assert host.host.running() == []
    assert not (tmp_path / AGENT).exists()


def test_client_shutdown_keeps_the_bundle_on_disk(host, tmp_path):
    host.host.deliver(AGENT, BUNDLE)
    host.host.stop_all()
    assert (tmp_path / AGENT / "agent_main.py").exists()


def test_stop_all_terminates_every_child(host):
    host.host.deliver(AGENT, BUNDLE)
    host.host.deliver("ua-other-abc123", BUNDLE)
    procs = list(host.procs.values())

    host.host.stop_all()

    assert all(p.terminated for p in procs)
    assert host.host.running() == []


def test_reconnect_resends_each_running_childs_registration(host):
    host.host.deliver(AGENT, BUNDLE)
    reg = {"type": "register_agent", "agent_card": {"agent_id": AGENT}}
    host.proc.stdout.feed(json.dumps(reg))
    assert host.wait_for(lambda: len(host.tunnelled()) == 1)
    host.host.on_agent_registered(AGENT)

    host.sent.clear()
    host.host.on_ui_connected()

    frames = host.tunnelled()
    assert len(frames) == 1 and frames[0]["type"] == "register_agent"
    assert frames[0]["agent_card"]["agent_id"] == AGENT


def test_reconnect_skips_a_dead_child(host):
    host.host.deliver(AGENT, BUNDLE)
    host.proc.stdout.feed(json.dumps(REG))
    assert host.wait_for(lambda: len(host.tunnelled()) == 1)
    host.proc.exit(1)
    assert host.wait_for(lambda: host.host.running() == [])

    host.sent.clear()
    host.host.on_ui_connected()
    assert host.tunnelled() == []
    assert host.host.running() == []


def test_first_connect_starts_the_bundles_already_on_disk(tmp_path):
    (tmp_path / AGENT).mkdir()
    (tmp_path / AGENT / "agent_main.py").write_text("x\n", encoding="utf-8")
    (tmp_path / "ua-other-abc123").mkdir()
    (tmp_path / "ua-other-abc123" / "agent_main.py").write_text("x\n", encoding="utf-8")
    (tmp_path / "not-an-agent").mkdir()

    h = _Host(tmp_path)
    h.host.on_ui_connected()

    assert sorted(h.host.running()) == ["ua-notes-abc123", "ua-other-abc123"]
    assert len(h.spawned) == 2
    h.host.stop_all()


def test_rehydrate_runs_once_and_does_not_duplicate_a_running_child(host, tmp_path):
    host.host.deliver(AGENT, BUNDLE)
    host.host.on_ui_connected()
    host.host.on_ui_connected()

    assert host.host.running() == [AGENT]
    assert len(host.spawned) == 1


def test_rehydrate_with_no_agents_root_is_a_no_op(tmp_path):
    h = _Host(tmp_path / "never-created")
    h.host.on_ui_connected()
    assert h.host.running() == []


def test_registration_timeout_reaps_the_child_and_surfaces_it(tmp_path):
    h = _Host(tmp_path, register_timeout=0.15)
    h.host.deliver(AGENT, BUNDLE)
    proc = h.proc
    proc.stdout.feed(json.dumps(REG))

    # Waits on the notice; `terminated` alone races the reaper
    assert h.wait_for(
        lambda: any(level == "error" and AGENT in text for text, level in h.notices),
        timeout=3,
    )
    assert proc.terminated
    assert h.host.running() == []


def test_agent_registered_disarms_the_timeout(tmp_path):
    h = _Host(tmp_path, register_timeout=0.15)
    h.host.deliver(AGENT, BUNDLE)
    proc = h.proc

    h.host.on_agent_registered(AGENT)
    time.sleep(0.35)

    assert not proc.terminated
    assert h.host.running() == [AGENT]
    h.host.stop_all()


def test_revision_keeps_the_old_child_until_the_new_one_registers(host, tmp_path):
    host.host.deliver(AGENT, BUNDLE)
    old = host.proc
    old.stdout.feed(json.dumps(REG))
    assert host.wait_for(lambda: host.tunnelled())
    host.host.on_agent_registered(AGENT)
    assert host.host.running() == [AGENT]
    host.sent.clear()

    v2 = dict(BUNDLE, **{"agent_main.py": "print('v2')\n"})
    host.host.deliver(AGENT, v2)

    assert not old.terminated
    assert host.host.running() == [AGENT]
    new = next(p for p in host.procs.values() if p is not old)
    assert new.poll() is None
    assert (tmp_path / AGENT / "agent_main.py").read_text(encoding="utf-8") == "print('hi')\n"

    new.stdout.feed(json.dumps(REG))
    assert host.wait_for(
        lambda: any(json.loads(p["frame"]).get("type") == "register_agent"
                    for a, p in host.sent if a == "agent_tunnel"))
    host.host.on_agent_registered(AGENT)

    assert old.terminated
    assert host.host.running() == [AGENT]
    assert (tmp_path / AGENT / "agent_main.py").read_text(encoding="utf-8") == "print('v2')\n"


def test_a_failed_revision_does_not_kill_the_running_agent(tmp_path):
    h = _Host(tmp_path, register_timeout=0.15)
    h.host.deliver(AGENT, BUNDLE)
    old = h.proc
    h.host.on_agent_registered(AGENT)
    assert h.host.running() == [AGENT]

    h.host.deliver(AGENT, dict(BUNDLE, **{"agent_main.py": "print('v2')\n"}))
    new = next(p for p in h.procs.values() if p is not old)

    assert h.wait_for(lambda: new.terminated, timeout=3)
    assert not old.terminated
    assert h.host.running() == [AGENT]
    assert (tmp_path / AGENT / "agent_main.py").read_text(encoding="utf-8") == "print('hi')\n"
    h.host.stop_all()


def test_client_close_stops_an_in_flight_revision_child(host, tmp_path):
    host.host.deliver(AGENT, BUNDLE)
    old = host.proc
    host.host.on_agent_registered(AGENT)
    host.host.deliver(AGENT, dict(BUNDLE, **{"agent_main.py": "print('v2')\n"}))
    new = next(p for p in host.procs.values() if p is not old)
    assert not old.terminated and not new.terminated

    host.host.stop_all()

    assert old.terminated and new.terminated
    assert host.host.running() == []
    assert not (tmp_path / (AGENT + ".pending")).exists()
    assert (tmp_path / AGENT / "agent_main.py").exists()


def test_rehydrate_ignores_a_stale_staging_dir(tmp_path):
    (tmp_path / AGENT).mkdir()
    (tmp_path / AGENT / "agent_main.py").write_text("x\n", encoding="utf-8")
    staging = tmp_path / (AGENT + ".pending")
    staging.mkdir()
    (staging / "agent_main.py").write_text("x\n", encoding="utf-8")

    h = _Host(tmp_path)
    h.host.on_ui_connected()

    assert h.host.running() == [AGENT]
    assert not staging.exists()
    h.host.stop_all()


def test_worker_argv_from_source_passes_the_script(monkeypatch):
    monkeypatch.setattr(sys, "frozen", False, raising=False)
    argv = byo_host.worker_argv("C:/agents/ua-x")
    assert argv[0] == sys.executable
    assert argv[1].endswith("main.py")
    assert argv[2:] == ["--byo-worker", "C:/agents/ua-x"]


def test_worker_argv_when_frozen_reinvokes_the_exe(monkeypatch):
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    argv = byo_host.worker_argv("C:/agents/ua-x")
    assert argv == [sys.executable, "--byo-worker", "C:/agents/ua-x"]


def test_worker_runs_a_delivered_bundle_over_real_stdio(tmp_path):
    agent_dir = tmp_path / AGENT
    agent_dir.mkdir()
    (agent_dir / "mcp_tools.py").write_text("TOOL_REGISTRY = {'ping': {}}\n", encoding="utf-8")
    (agent_dir / "agent_main.py").write_text(
        "import json, sys\n"
        "from mcp_tools import TOOL_REGISTRY\n"
        "def main():\n"
        "    print(json.dumps({'type': 'register_agent',\n"
        "                      'agent_card': {'agent_id': 'ua-notes-abc123',\n"
        "                                     'skills': list(TOOL_REGISTRY)}}), flush=True)\n"
        "    for line in sys.stdin:\n"
        "        req = json.loads(line)\n"
        "        print(json.dumps({'type': 'mcp_response',\n"
        "                          'request_id': req['request_id'], 'result': 'pong'}), flush=True)\n"
        "    return 0\n"
        "if __name__ == '__main__':\n"
        "    raise SystemExit(main())\n",
        encoding="utf-8",
    )

    root = os.path.dirname(os.path.dirname(os.path.abspath(byo_host.__file__)))
    proc = subprocess.Popen(
        [sys.executable, os.path.join(root, "main.py"), "--byo-worker", str(agent_dir)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", cwd=root,
    )
    try:
        reg = json.loads(proc.stdout.readline())
        assert reg["type"] == "register_agent"
        assert reg["agent_card"]["skills"] == ["ping"]

        proc.stdin.write(json.dumps({"type": "mcp_request", "request_id": "r9"}) + "\n")
        proc.stdin.flush()
        resp = json.loads(proc.stdout.readline())
        assert resp == {"type": "mcp_response", "request_id": "r9", "result": "pong"}

        proc.stdin.close()
        assert proc.wait(timeout=15) == 0
    finally:
        if proc.poll() is None:
            proc.kill()


def test_worker_reports_a_missing_bundle(tmp_path):
    from win_agent.byo_worker import run_worker

    assert run_worker(str(tmp_path / "nope")) == 2


def test_worker_registers_even_when_sys_stdout_is_none(tmp_path):
    agent_dir = tmp_path / AGENT
    agent_dir.mkdir()
    (agent_dir / "agent_main.py").write_text(
        "import json, sys\n"
        "def main():\n"
        "    print(json.dumps({'type': 'register_agent',\n"
        "                      'agent_card': {'agent_id': 'ua-notes-abc123'}}), flush=True)\n"
        "    return 0\n",
        encoding="utf-8",
    )

    root = os.path.dirname(os.path.dirname(os.path.abspath(byo_host.__file__)))
    proc = subprocess.Popen(
        [sys.executable, "-c",
         "import sys; sys.stdout = None; sys.stderr = None\n"
         "from win_agent.byo_worker import run_worker\n"
         f"raise SystemExit(run_worker({str(agent_dir)!r}))\n"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", cwd=root,
    )
    try:
        out, err = proc.communicate(timeout=20)
    finally:
        if proc.poll() is None:
            proc.kill()

    assert proc.returncode == 0, err
    frame = json.loads(out.strip().splitlines()[0])
    assert frame["type"] == "register_agent"
    assert frame["agent_card"]["agent_id"] == AGENT


class _FakeClient:
    def __init__(self, *a, **k):
        self.sent = []

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


@pytest.fixture
def win(qapp, monkeypatch, tmp_path):
    pytest.importorskip("PySide6")
    os.environ["ASTRAL_WIN_AGENT"] = "0"
    from astral_client import app as appmod

    monkeypatch.setattr(appmod, "OrchestratorClient", _FakeClient)
    monkeypatch.setattr(appmod.MainWindow, "_start_integrity_check", lambda self: None)
    monkeypatch.setattr(appmod.MainWindow, "_init_workspace", lambda self: None)
    monkeypatch.setenv("BYO_AGENTS_DIR", str(tmp_path))
    w = appmod.MainWindow("ws://127.0.0.1:9/ws", "dev-token")
    w._byo._base_dir = str(tmp_path)
    spawned = []
    w._byo._spawn = lambda argv: spawned.append(argv) or _FakeProc()
    w._spawned = spawned
    yield w
    w.close()


def test_window_routes_the_four_host_frames(win):
    assert win._on_message({"type": "agent_bundle_deliver", "agent_id": AGENT,
                            "files": BUNDLE}) is None
    assert win._byo.running() == [AGENT]
    assert win._spawned

    win._on_message({"type": "agent_tunnel", "agent_id": AGENT, "frame": '{"type":"x"}'})
    win._on_message({"type": "agent_offline", "agent_id": AGENT})
    win._on_message({"type": "agent_stop", "agent_id": AGENT})
    assert win._byo.running() == []


def test_window_reregisters_byo_agents_on_reconnect(win, monkeypatch):
    calls = []
    monkeypatch.setattr(win._byo, "on_ui_connected", lambda: calls.append(1))
    win._on_status("connected")
    assert calls == [1]


def test_window_close_stops_every_child(win):
    win._on_message({"type": "agent_bundle_deliver", "agent_id": AGENT, "files": BUNDLE})
    assert win._byo.running() == [AGENT]

    win.close()

    assert win._byo.running() == []


def test_sign_out_stops_every_child(win):
    win._on_message({"type": "agent_bundle_deliver", "agent_id": AGENT, "files": BUNDLE})
    procs = list(win._byo._children.values())
    assert procs and win._byo.running() == [AGENT]

    win._finish_sign_out("revoked")

    assert all(c.proc.terminated for c in procs)
    assert win._byo.running() == []


def test_application_shutdown_stops_every_child(win):
    from PySide6.QtWidgets import QApplication

    win._on_message({"type": "agent_bundle_deliver", "agent_id": AGENT, "files": BUNDLE})
    procs = list(win._byo._children.values())

    QApplication.instance().aboutToQuit.emit()

    assert all(c.proc.terminated for c in procs)
    assert win._byo.running() == []


def test_window_acks_registration_to_the_host(win):
    win._on_message({"type": "agent_bundle_deliver", "agent_id": AGENT, "files": BUNDLE})
    win._on_message({"type": "agent_registered", "agent_id": AGENT})
    assert win._byo.running() == [AGENT]
