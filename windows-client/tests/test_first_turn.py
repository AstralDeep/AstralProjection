"""Tests for astral_client/app.py and Canvas (renderer.py): the welcome purge and
loading skeleton armed at turn start, skeleton lifecycle across empty renders, and
live in-turn upsert/stream handling.
"""

import os

import pytest

pytest.importorskip("PySide6")

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ["ASTRAL_WIN_AGENT"] = "0"

from astral_client import app as appmod  # noqa: E402
from astral_client.app import Canvas, MainWindow  # noqa: E402
from astral_client.renderer import RenderContext  # noqa: E402


def _ctx():
    return RenderContext(emit=lambda *a: None, download=lambda *a: None)


def _card(cid):
    return {"type": "card", "component_id": cid, "content": []}


def _welcome():
    return [
        {"type": "hero", "id": "wel_hero", "component_id": "wel_hero"},
        {"type": "card", "id": "wel_ex_weather", "component_id": "wel_ex_weather"},
        {"type": "text", "id": "wel_hint", "component_id": "wel_hint"},
    ]


class _FakeClient:
    def __init__(self, *a, **k):
        self.sent = []
        self.chats = []

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

    def send_chat(self, *a, **k):
        self.chats.append((a, k))


@pytest.fixture
def win(qapp, monkeypatch):
    monkeypatch.setattr(appmod, "OrchestratorClient", _FakeClient)
    monkeypatch.setattr(MainWindow, "_start_integrity_check", lambda self: None)
    monkeypatch.setattr(MainWindow, "_init_workspace", lambda self: None)
    w = MainWindow("ws://127.0.0.1:9/ws", "dev-token")
    yield w
    w.close()


def test_typed_send_arms_skeleton(win):
    win._input.setText("hello")
    win._send()
    assert win.client.chats, "typed send never reached the transport"
    assert win.canvas._skeleton is not None
    assert win.canvas.turn_active is True


def test_typed_send_purges_welcome(win):
    win.canvas.set_components(_welcome())
    win._input.setText("what's the weather")
    win._send()
    assert win.canvas._last_components == []
    assert not any(k.startswith("wel_") for k in win.canvas._by_id)
    assert win.canvas._skeleton is not None
    assert win.canvas._empty is None


def test_emit_chat_message_purges_welcome(win):
    win.canvas.set_components(_welcome())
    win._emit("chat_message", {"message": "roll 2d6"})
    assert win.canvas._last_components == []
    assert win.canvas._skeleton is not None
    assert win.canvas._empty is None


def test_purge_keeps_non_welcome_components(win):
    win.canvas.set_components([_card("A")] + _welcome())
    win._input.setText("again")
    win._send()
    assert list(win.canvas._by_id) == ["A"]
    assert win.canvas._last_components == [_card("A")]


def test_timeline_mode_suppresses_arming_and_purge(win):
    win.canvas.set_components(_welcome())
    win._timeline_mode = True
    win._input.setText("hi")
    win._send()
    assert win.canvas._skeleton is None
    assert len(win.canvas._last_components) == 3


def test_purge_is_noop_for_idless_welcome(qapp):
    c = Canvas(_ctx())
    idless = [{"type": "hero"}, {"type": "card", "content": []}]
    c.set_components(idless)
    before = c._last_components
    c.purge_welcome()
    assert c._last_components is before


def test_empty_render_mid_turn_keeps_skeleton_no_hint(qapp):
    c = Canvas(_ctx())
    c.set_components([_card("A")])
    c.turn_active = True
    c.show_skeleton()
    c.set_components([])
    assert c._skeleton is not None
    assert c._empty is None
    assert c._by_id == {}


def test_empty_render_mid_turn_on_empty_canvas_keeps_skeleton(qapp):
    c = Canvas(_ctx())
    c.turn_active = True
    c.show_skeleton()
    c.set_components([])
    assert c._skeleton is not None
    assert c._empty is None


def test_empty_render_out_of_turn_clears_and_shows_hint(qapp):
    c = Canvas(_ctx())
    c.set_components([_card("A")])
    assert c.turn_active is False
    c.set_components([])
    assert c._by_id == {}
    assert c._empty is not None
    assert c._skeleton is None


def test_done_resolves_text_only_turn_to_hint(win):
    win.canvas.set_components(_welcome())
    win._input.setText("just say hi")
    win._send()
    assert win.canvas._skeleton is not None
    win._on_message({"type": "chat_status", "status": "done"})
    assert win._turn_active is False
    assert win.canvas.turn_active is False
    assert win.canvas._skeleton is None
    assert win.canvas._empty is not None


def test_done_after_content_keeps_canvas_no_hint(win):
    win._input.setText("build a table")
    win._send()
    win.canvas.set_components([_card("A")])
    assert win.canvas._skeleton is None
    win._on_message({"type": "chat_status", "status": "done"})
    assert "A" in win.canvas._by_id
    assert win.canvas._empty is None


def test_in_turn_upsert_renders_immediately_and_clears_skeleton(win):
    win._input.setText("build a table")
    win._send()
    assert win.canvas._skeleton is not None
    win._on_message({"type": "ui_upsert", "ops": [
        {"op": "upsert", "component_id": "A", "component": _card("A")}]})
    assert "A" in win.canvas._by_id
    assert win.canvas._lay.indexOf(win.canvas._by_id["A"]) != -1
    assert win.canvas._skeleton is None
    assert win.canvas.turn_active is True


def test_done_after_live_upserts_commits_visible_canvas(win):
    win._input.setText("build a table")
    win._send()
    win._on_message({"type": "ui_upsert", "ops": [
        {"op": "upsert", "component_id": "A", "component": _card("A")}]})
    wa = win.canvas._by_id["A"]
    win._on_message({"type": "chat_status", "status": "done"})
    assert win.canvas._by_id["A"] is wa
    assert win.canvas._empty is None
    assert win.canvas._skeleton is None


def test_in_turn_stream_frame_applies_live(win):
    win._input.setText("stream something")
    win._send()
    win._on_message({"type": "ui_stream_data", "stream_id": "s1", "seq": 1,
                     "components": [{"type": "text", "content": "partial"}]})
    assert "stream-s1" in win.canvas._by_id
    assert win.canvas._skeleton is None


def test_mid_stream_join_guard_reads_live_canvas(win):
    win._input.setText("stream something")
    win._send()
    win._on_message({"type": "ui_stream_data", "stream_id": "s1", "seq": 1,
                     "components": [{"type": "text", "content": "partial"}]})
    w = win.canvas._by_id["stream-s1"]
    win._on_message({"type": "stream_subscribed", "stream_id": "s1",
                     "tool_name": "ticker"})
    assert win.canvas._by_id["stream-s1"] is w
    assert win.canvas._rendered["stream-s1"] == {
        "type": "text", "content": "partial"}
