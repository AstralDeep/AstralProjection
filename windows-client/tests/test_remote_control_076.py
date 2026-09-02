"""Feature 076 — this desktop as a computer host: executor + controller tests.

Offscreen and platform-neutral: the Windows-only injector/system are replaced
by fakes, screen capture by a stub, and the banner by a recording double. What
is pinned (spec FR-007/FR-008/FR-013/FR-014 + contracts/transport.md §2-4):

- chord parsing, coordinate mapping through the last capture, app/path
  validation, file verbs in a temp dir, command execution bounds;
- the controller answers a request only for the active session id, refuses
  while paused or with consent off, executes screenshots inline and other verbs
  on a worker thread (one at a time), and always answers with a typed
  ``computer_response``;
- consent on/off announces/withdraws; a session frame shows the banner and
  sends the heartbeat acknowledgement; local input pauses; socket loss ends
  the mirrored session; Stop is the kill switch.
"""
from __future__ import annotations

import json
import os
import sys
import uuid

import pytest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from win_agent import computer_use as cu  # noqa: E402

pytest.importorskip("PySide6")
from PySide6.QtCore import QCoreApplication, QSettings  # noqa: E402

from astral_client import remote_control as rc  # noqa: E402


# ── fakes ──────────────────────────────────────────────────────────────────────

class FakeInjector:
    def __init__(self):
        self.calls = []
        self.last_injected_tick = 0

    def move(self, px, py):
        self.calls.append(("move", px, py))
        self.last_injected_tick = 1000

    def click(self, px, py, button="left", count=1):
        self.calls.append(("click", px, py, button, count))
        self.last_injected_tick = 1000

    def drag(self, x1, y1, x2, y2):
        self.calls.append(("drag", x1, y1, x2, y2))

    def scroll(self, px, py, dx, dy):
        self.calls.append(("scroll", px, py, dx, dy))

    def type_text(self, text):
        self.calls.append(("type", text))

    def press(self, mods, vk):
        self.calls.append(("press", tuple(mods), vk))


class FakeSystem:
    def __init__(self):
        self.locked = False
        self.input_tick = 0
        self.now = 5000
        self.focused = []
        self.opened = []
        self.windows = [
            {"hwnd": 11, "title": "Untitled - Notepad", "process": "notepad.exe",
             "rect": [0, 0, 800, 600], "focused": False, "minimized": False},
            {"hwnd": 22, "title": "Book1 - Excel", "process": "EXCEL.EXE",
             "rect": [10, 10, 900, 700], "focused": True, "minimized": False},
        ]

    def screen_locked(self):
        return self.locked

    foreground = "notepad.exe"

    def foreground_process(self):
        return self.foreground

    def last_input_tick(self):
        return self.input_tick

    def tick(self):
        return self.now

    def list_windows(self, exclude_titles=()):
        return [w for w in self.windows if w["title"] not in exclude_titles]

    def focus_window(self, hwnd):
        self.focused.append(hwnd)
        return True

    def open_app(self, app, args, is_path):
        self.opened.append((app, list(args), is_path))
        return 4242 if is_path else None


def fake_capture(screen_index=0, max_width=1280):
    geometry = cu.CaptureGeometry(screen_index=screen_index, width=1280, height=720, scale=0.5,
                                  phys_x=0, phys_y=0, phys_w=2560, phys_h=1440)
    return ({"screen_index": screen_index, "width": 1280, "height": 720, "scale": 0.5,
             "media_type": "image/jpeg", "base64": "/9j/QUJD"}, geometry)


def make_executor():
    return cu.Executor(injector=FakeInjector(), system=FakeSystem(), capture_fn=fake_capture)


# ── pure helpers ──────────────────────────────────────────────────────────────

def test_parse_chord_variants():
    assert cu.parse_chord("ctrl+shift+s") == ([0x11, 0x10], ord("S"))
    assert cu.parse_chord("Enter") == ([], 0x0D)
    assert cu.parse_chord("alt+f4") == ([0x12], 0x73)
    assert cu.parse_chord("win+r") == ([0x5B, ], ord("R"))
    assert cu.parse_chord("win") == ([], 0x5B)
    for bad in ("", "ctrl+", "ctrl+a+b", "ctrl+nosuchkey", "rm -rf"):
        with pytest.raises(cu.VerbError) as exc:
            cu.parse_chord(bad)
        assert exc.value.code == "out_of_range"


def test_coordinates_map_through_the_last_capture():
    geo = cu.CaptureGeometry(0, 1280, 720, 0.5, 100, 200, 2560, 1440)
    assert geo.to_physical(0, 0) == (100, 200)
    assert geo.to_physical(640, 360) == (1380, 920)
    assert geo.to_physical(1280, 720) == (100 + 2559, 200 + 1439)  # clamped inside the screen
    with pytest.raises(cu.VerbError):
        geo.to_physical(1281, 10)
    assert cu.to_physical(None, 5, 6, (0, 0, 1920, 1080)) == (5, 6)
    with pytest.raises(cu.VerbError):
        cu.to_physical(None, 5000, 6, (0, 0, 1920, 1080))
    assert cu.to_physical(None, 7, 8, None) == (7, 8)


def test_validate_app_names_and_paths():
    assert cu.validate_app("notepad") == ("notepad", False)
    assert cu.validate_app("Visual Studio Code") == ("Visual Studio Code", False)
    assert cu.validate_app(r"C:\Program Files\Foo\foo.exe") == (r"C:\Program Files\Foo\foo.exe", True)
    for bad in ("", "cmd /c del *", r"C:\x|y.exe", r"..\evil.exe", "app; rm", r"C:\notes.txt", "x" * 81):
        with pytest.raises(cu.VerbError):
            cu.validate_app(bad)


# ── executor ──────────────────────────────────────────────────────────────────

def test_executor_input_verbs_use_the_capture_geometry():
    ex = make_executor()
    assert ex.screenshot({"screen_index": 0, "max_width": 1280})["width"] == 1280
    assert ex.run("click", {"x": 640, "y": 360, "button": "left", "count": 1}) == {
        "x": 640, "y": 360, "button": "left", "count": 1}
    assert ex.injector.calls[-1] == ("click", 1280, 720, "left", 1)
    ex.run("double_click", {"x": 10, "y": 10})
    assert ex.injector.calls[-1][4] == 2
    ex.run("right_click", {"x": 10, "y": 10})
    assert ex.injector.calls[-1][3] == "right"
    ex.run("drag", {"x1": 0, "y1": 0, "x2": 100, "y2": 50})
    assert ex.injector.calls[-1] == ("drag", 0, 0, 200, 100)
    ex.run("scroll", {"x": 5, "y": 5, "dy": -3})
    assert ex.injector.calls[-1] == ("scroll", 10, 10, 0, -3)
    ex.run("type_text", {"text": "hello\nworld"})
    assert ex.injector.calls[-1] == ("type", "hello\nworld")
    ex.run("press_keys", {"keys": "ctrl+s"})
    assert ex.injector.calls[-1] == ("press", (0x11,), ord("S"))
    for verb, args in (("click", {"x": 2000, "y": 1}), ("scroll", {"x": 1, "y": 1, "dy": 99}),
                       ("type_text", {"text": ""}), ("click", {"x": 1, "y": 1, "button": "sideways"})):
        with pytest.raises(cu.VerbError) as exc:
            ex.run(verb, args)
        assert exc.value.code == "out_of_range"
    with pytest.raises(cu.VerbError) as exc:
        ex.run("format_disk", {})
    assert exc.value.code == "unsupported"


def test_keyboard_into_a_terminal_needs_the_owners_approval():
    ex = make_executor()
    ex.system.foreground = "powershell.exe"
    for verb, args in (("type_text", {"text": "Get-Date"}), ("press_keys", {"keys": "enter"})):
        with pytest.raises(cu.VerbError) as exc:
            ex.run(verb, args)
        assert exc.value.code == "confirmation_required" and "confirm_action" in exc.value.message
    assert ex.injector.calls == []
    # the server passes the owner's approval as terminal_ok → allowed
    assert ex.run("type_text", {"text": "Get-Date", "terminal_ok": True}) == {"chars": 8}
    assert ex.run("press_keys", {"keys": "enter", "terminal_ok": True}) == {"keys": "enter"}
    # a spoofed truthy-but-not-True value is not an approval
    with pytest.raises(cu.VerbError):
        ex.run("type_text", {"text": "x", "terminal_ok": "yes"})
    # clicking a terminal window is still fine (it does not run anything)
    ex.run("click", {"x": 1, "y": 1})
    ex.system.foreground = "notepad.exe"
    assert ex.run("type_text", {"text": "hi"}) == {"chars": 2}
    with pytest.raises(cu.VerbError) as exc:
        ex.run("run_command", {"command": "dir"})
    assert exc.value.code == "unsupported"


def test_executor_refuses_input_while_locked():
    ex = make_executor()
    ex.system.locked = True
    with pytest.raises(cu.VerbError) as exc:
        ex.run("click", {"x": 1, "y": 1})
    assert exc.value.code == "screen_locked"
    with pytest.raises(cu.VerbError) as exc:
        ex.screenshot({})
    assert exc.value.code == "screen_locked"


def test_executor_windows_focus_and_open_app():
    ex = make_executor()
    wins = ex.run("list_windows", {})["windows"]
    assert [w["hwnd"] for w in wins] == [11, 22]
    assert ex.run("focus_window", {"title": "notepad"}) == {"hwnd": 11, "title": "Untitled - Notepad"}
    assert ex.run("focus_window", {"hwnd": 22})["hwnd"] == 22
    with pytest.raises(cu.VerbError) as exc:
        ex.run("focus_window", {"title": "nothing like this"})
    assert exc.value.code == "window_not_found"
    assert ex.run("open_app", {"app": "notepad"}) == {"launched": True, "pid": None, "app": "notepad"}
    assert ex.run("open_app", {"app": r"C:\Tools\x.exe", "args": ["--flag"]})["pid"] == 4242
    assert ex.system.opened[-1] == (r"C:\Tools\x.exe", ["--flag"], True)
    with pytest.raises(cu.VerbError):
        ex.run("open_app", {"app": "notepad", "args": "not-a-list"})


def test_executor_file_verbs(tmp_path):
    ex = make_executor()
    target = tmp_path / "note.txt"
    assert ex.run("write_file", {"path": str(target), "content": "hi"}) == {"path": str(target), "bytes": 2}
    with pytest.raises(cu.VerbError) as exc:
        ex.run("write_file", {"path": str(target), "content": "again"})
    assert exc.value.code == "exists"
    assert ex.run("write_file", {"path": str(target), "content": "again", "if_exists": "overwrite"})["bytes"] == 5
    read = ex.run("read_file", {"path": str(target), "max_bytes": 3})
    assert read["text"] == "aga" and read["truncated"] is True and read["size"] == 5
    listing = ex.run("list_dir", {"path": str(tmp_path)})
    assert listing["entries"][0]["name"] == "note.txt"
    assert ex.run("delete_path", {"path": str(target)})["deleted"] is True
    with pytest.raises(cu.VerbError) as exc:
        ex.run("read_file", {"path": str(target)})
    assert exc.value.code == "not_found"
    with pytest.raises(cu.VerbError) as exc:
        ex.run("read_file", {"path": "relative.txt"})
    assert exc.value.code == "out_of_range"
    sub = tmp_path / "sub"
    sub.mkdir()
    (sub / "f").write_text("x")
    with pytest.raises(cu.VerbError):
        ex.run("delete_path", {"path": str(sub)})  # not empty


# ── settings + descriptor ─────────────────────────────────────────────────────

def _settings(tmp_path):
    return rc.RemoteControlSettings(QSettings(str(tmp_path / "rc.ini"), QSettings.Format.IniFormat))


def test_settings_persist_consent_and_mint_a_stable_host_id(tmp_path):
    s = _settings(tmp_path)
    assert s.enabled is False
    first = s.host_id
    assert str(uuid.UUID(first)) == first and uuid.UUID(first).version == 4
    s.enabled = True
    s.name = "  MY PC  "
    again = _settings(tmp_path)
    assert again.enabled is True and again.host_id == first and again.name == "MY PC"


def test_descriptor_matches_the_transport_contract(tmp_path):
    s = _settings(tmp_path)
    d = rc.build_descriptor(s, screens=[{"index": 0, "width": 2560, "height": 1440, "scale": 1.0, "primary": True}])
    assert set(d) == {"host_id", "name", "platform", "client_version", "screens", "verbs", "protocol"}
    assert d["platform"] == "windows" and d["protocol"] == 1
    assert d["verbs"] == list(cu.VERBS) and len(d["verbs"]) == 19
    assert d["screens"][0]["primary"] is True


# ── controller ────────────────────────────────────────────────────────────────

class FakeBanner:
    def __init__(self, on_pause, on_resume, on_stop):
        self.on_pause, self.on_resume, self.on_stop = on_pause, on_resume, on_stop
        self.visible = False
        self.states = []

    def set_state(self, label, paused, reason):
        self.states.append((label, paused, reason))

    def show(self):
        self.visible = True

    def hide(self):
        self.visible = False


def make_controller(tmp_path, enabled=True):
    sent = []
    settings = _settings(tmp_path)
    settings.enabled = enabled
    executor = make_executor()
    controller = rc.RemoteControlController(
        send_event=lambda action, payload: sent.append((action, json.loads(json.dumps(payload)))),
        settings=settings, executor=executor, banner_factory=FakeBanner, system=executor.system)
    return controller, sent


def _session_frame(controller, session_id="cs_1", state="active", **over):
    frame = {"type": "computer_session", "session_id": session_id, "host_id": controller.host_id,
             "state": state, "reason": None, "controller_label": "Android phone"}
    frame.update(over)
    return frame


def _pump(ms=50):
    QCoreApplication.processEvents()
    from PySide6.QtCore import QEventLoop, QTimer
    loop = QEventLoop()
    QTimer.singleShot(ms, loop.quit)
    loop.exec()


def test_session_frame_shows_banner_and_acks_with_a_heartbeat(qapp, tmp_path):
    controller, sent = make_controller(tmp_path)
    assert controller.handle_frame(_session_frame(controller)) is True
    assert controller.session["session_id"] == "cs_1"
    assert sent[-1] == ("computer_event", {"host_id": controller.host_id, "event": "heartbeat", "session_id": "cs_1"})
    assert controller._banner.visible and controller._banner.states[-1] == ("Android phone", False, None)
    # a frame about ANOTHER of the owner's computers is ignored
    controller.handle_frame(_session_frame(controller, session_id="cs_other", host_id=str(uuid.uuid4())))
    assert controller.session["session_id"] == "cs_1"
    controller.handle_frame(_session_frame(controller, state="ended", reason="idle_timeout"))
    assert controller.session is None and controller._banner.visible is False


def test_requests_are_gated_by_session_and_consent(qapp, tmp_path):
    controller, sent = make_controller(tmp_path)
    controller.handle_frame({"type": "computer_request", "request_id": "r1", "session_id": "cs_1",
                             "verb": "screenshot", "args": {}})
    assert sent[-1][0] == "computer_response" and sent[-1][1]["error"]["code"] == "no_session"
    controller.handle_frame(_session_frame(controller))
    controller.handle_frame({"type": "computer_request", "request_id": "r2", "session_id": "cs_WRONG",
                             "verb": "screenshot", "args": {}})
    assert sent[-1][1]["error"]["code"] == "no_session"
    controller.handle_frame({"type": "computer_request", "request_id": "r3", "session_id": "cs_1",
                             "verb": "screenshot", "args": {"max_width": 1280}})
    assert sent[-1][1]["ok"] is True and sent[-1][1]["result"]["media_type"] == "image/jpeg"
    controller.handle_frame({"type": "computer_request", "request_id": "r4", "session_id": "cs_1",
                             "verb": "format_disk", "args": {}})
    assert sent[-1][1]["error"]["code"] == "unsupported"
    # worker verb → answered on the GUI thread after the thread finishes
    controller.handle_frame({"type": "computer_request", "request_id": "r5", "session_id": "cs_1",
                             "verb": "click", "args": {"x": 10, "y": 10}})
    for _ in range(40):
        _pump(25)
        if any(p.get("request_id") == "r5" for _a, p in sent):
            break
    reply = next(p for _a, p in sent if p.get("request_id") == "r5")
    assert reply["ok"] is True and reply["result"]["button"] == "left"
    assert controller.executor.injector.calls[-1][0] == "click"
    # paused → typed refusal without touching the executor
    controller.pause_locally("local_input")
    assert sent[-1] == ("computer_event", {"host_id": controller.host_id, "event": "paused",
                                           "session_id": "cs_1", "reason": "local_input"})
    n = len(controller.executor.injector.calls)
    controller.handle_frame({"type": "computer_request", "request_id": "r6", "session_id": "cs_1",
                             "verb": "click", "args": {"x": 1, "y": 1}})
    assert sent[-1][1]["error"]["code"] == "paused" and len(controller.executor.injector.calls) == n
    controller.resume_locally()
    assert sent[-1][1]["event"] == "resumed" and controller.session["state"] == "active"


def test_consent_off_refuses_and_withdraws(qapp, tmp_path):
    controller, sent = make_controller(tmp_path, enabled=True)
    controller.handle_frame(_session_frame(controller))
    controller.set_enabled(False)
    assert controller.session is None
    assert sent[-1] == ("computer_event", {"host_id": controller.host_id, "event": "withdraw"})
    controller.handle_frame({"type": "computer_request", "request_id": "r1", "session_id": "cs_1",
                             "verb": "screenshot", "args": {}})
    assert sent[-1][1]["error"]["code"] == "no_session"
    controller.set_enabled(True)
    action, payload = sent[-1]
    assert action == "computer_event" and payload["event"] == "announce"
    assert payload["host"]["host_id"] == controller.host_id and payload["host"]["verbs"] == list(cu.VERBS)
    assert controller.descriptor()["protocol"] == 1
    controller.set_enabled(False)
    assert controller.descriptor() is None


def test_local_input_pauses_and_socket_loss_ends(qapp, tmp_path):
    controller, sent = make_controller(tmp_path)
    system = controller.executor.system
    system.now = 5000
    controller.handle_frame(_session_frame(controller))
    # input older than the session start (or our own injection) is not a person
    system.input_tick = 4000
    controller._poll_presence()
    assert controller.session["state"] == "active"
    controller.executor.injector.last_injected_tick = 6000
    system.input_tick = 6300  # within the grace window after our own click
    controller._poll_presence()
    assert controller.session["state"] == "active"
    system.input_tick = 7000  # a real person
    controller._poll_presence()
    assert controller.session["state"] == "paused" and controller.session["pause_reason"] == "local_input"
    assert controller._banner.states[-1] == ("Android phone", True, "local_input")
    controller.on_transport_status("reconnecting:1")
    assert controller.session is None and controller._banner.visible is False


def test_remote_resume_rebaselines_presence_like_a_local_one(qapp, tmp_path):
    """A remote resume (a ``computer_session`` frame flipping paused → active)
    must re-baseline the presence detector, or the very input that caused the
    pause re-pauses the session on the next poll, forever."""
    controller, sent = make_controller(tmp_path)
    system = controller.executor.system
    system.now = 5000
    controller.handle_frame(_session_frame(controller))
    system.input_tick = 7000  # a person
    controller._poll_presence()
    assert controller.session["state"] == "paused"
    system.now = 9000
    controller.handle_frame(_session_frame(controller, state="active"))
    assert controller.session["state"] == "active"
    controller._poll_presence()  # last input (7000) predates the resume (9000)
    assert controller.session["state"] == "active"
    system.input_tick = 9500  # the person is still there
    controller._poll_presence()
    assert controller.session["state"] == "paused"
    assert sent[-1][1]["event"] == "paused"


@pytest.mark.skipif(sys.platform != "win32", reason="user32 synthesis is Windows-only")
def test_focus_window_alt_tap_counts_as_our_own_input(monkeypatch):
    """focus_window lifts the SetForegroundWindow lock with a synthetic ALT tap;
    that tap must be stamped as OUR input or the presence detector pauses the
    session as 'someone is using this computer' right after every focus."""
    class _U32:
        def IsIconic(self, hwnd): return 0
        def ShowWindow(self, hwnd, cmd): return 1
        def SetForegroundWindow(self, hwnd): return 1
        def GetForegroundWindow(self): return 42
        def SendInput(self, n, arr, size): return n
    class _K32:
        def GetTickCount(self): return 777_000
    monkeypatch.setattr(cu, "_user32", _U32())
    monkeypatch.setattr(cu, "_kernel32", _K32())
    monkeypatch.setattr(cu, "_last_injected_tick", 0)
    injector = cu.WindowsInjector()
    assert injector.last_injected_tick == 0
    assert cu.WindowsSystem.focus_window(42) is True
    assert injector.last_injected_tick == 777_000


def test_stop_is_the_kill_switch(qapp, tmp_path):
    controller, sent = make_controller(tmp_path)
    controller.handle_frame(_session_frame(controller))
    controller._banner.on_stop()
    assert sent[-1] == ("computer_event", {"host_id": controller.host_id, "event": "stopped",
                                           "session_id": "cs_1", "reason": "local_stop"})
    assert controller.session is None
    controller.stop_all()  # idempotent
    assert sent[-1][1]["event"] == "stopped"


def test_register_frame_carries_the_descriptor_and_capability(qapp, tmp_path):
    from astral_client.protocol import OrchestratorClient
    client = OrchestratorClient("ws://localhost:1/ws", "tok")
    frame = client._register_frame()
    assert "computer_host" not in frame and "computer_host_capable" not in frame["capabilities"]
    client.computer_host_capable = True
    client.computer_host = rc.build_descriptor(_settings(tmp_path), screens=[
        {"index": 0, "width": 1920, "height": 1080, "scale": 1.0, "primary": True}])
    frame = client._register_frame()
    assert "computer_host_capable" in frame["capabilities"]
    assert frame["computer_host"]["platform"] == "windows"
