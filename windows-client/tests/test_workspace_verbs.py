"""Tests for windows-client component-verb acks (astral_client/app.py):
delete/combine/condense frames apply canvas remove/replace ops and drive
banner/status surfaces, ahead of the server's authoritative ui_render reconcile.
"""

import logging
import os

import pytest

pytest.importorskip("PySide6")

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ["ASTRAL_WIN_AGENT"] = "0"

from astral_client import app as appmod  # noqa: E402
from astral_client.app import MainWindow, replacement_ops  # noqa: E402


def _card(cid, title="Card"):
    return {"type": "card", "component_id": cid, "title": title, "content": []}


def _row(row_id, chat_id="c1", data=None):
    return {
        "id": row_id,
        "chat_id": chat_id,
        "component_data": data if data is not None else {"type": "card", "title": "Result", "content": []},
        "component_type": "combined",
        "title": "Combined Component",
        "created_at": 1,
    }


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

    def send_chat(self, *a, **k):
        pass


@pytest.fixture
def win(qapp, monkeypatch):
    monkeypatch.setattr(appmod, "OrchestratorClient", _FakeClient)
    monkeypatch.setattr(MainWindow, "_start_integrity_check", lambda self: None)
    monkeypatch.setattr(MainWindow, "_init_workspace", lambda self: None)
    w = MainWindow("ws://127.0.0.1:9/ws", "dev-token")
    yield w
    w.close()


def test_replacement_ops_removes_consumed_and_upserts_results():
    ops = replacement_ops({
        "removed_ids": ["row-a", "row-b"],
        "new_components": [_row("row-new", data={"type": "card", "component_id": "wc_new", "content": []})],
    })
    assert ops[0] == {"op": "remove", "component_id": "row-a"}
    assert ops[1] == {"op": "remove", "component_id": "row-b"}
    assert ops[2]["op"] == "upsert" and ops[2]["component_id"] == "wc_new"
    assert ops[2]["component"]["component_id"] == "wc_new"


def test_replacement_ops_identity_falls_back_to_row_id():
    ops = replacement_ops({"removed_ids": [], "new_components": [_row("row-new")]})
    assert ops == [{
        "op": "upsert", "component_id": "row-new",
        "component": {"type": "card", "title": "Result", "content": [],
                      "component_id": "row-new"},
    }]


def test_replacement_ops_skips_malformed_rows():
    ops = replacement_ops({
        "removed_ids": ["row-a", None],
        "new_components": ["junk", {"id": "r2", "component_data": "not-a-dict"}, {}],
    })
    assert ops == [{"op": "remove", "component_id": "row-a"}]


def test_component_deleted_removes_identity_from_canvas(win):
    win.canvas.set_components([_card("wc_a"), _card("wc_b")])
    assert set(win.canvas._by_id) == {"wc_a", "wc_b"}
    win._on_message({"type": "component_deleted", "component_id": "wc_a"})
    assert set(win.canvas._by_id) == {"wc_b"}


def test_component_deleted_unknown_id_is_safe_noop(win):
    win.canvas.set_components([_card("wc_a")])
    win._on_message({"type": "component_deleted", "component_id": "wc_nope"})
    assert set(win.canvas._by_id) == {"wc_a"}
    win._on_message({"type": "component_deleted"})
    assert set(win.canvas._by_id) == {"wc_a"}


@pytest.mark.parametrize("frame_type", ["components_combined", "components_condensed"])
def test_replacement_frame_applies_remove_and_result(win, frame_type):
    win.active_chat = "c1"
    win.canvas.set_components([_card("row-a"), _card("row-b"), _card("wc_keep")])
    win._on_message({
        "type": frame_type,
        "removed_ids": ["row-a", "row-b"],
        "new_components": [_row("row-new", chat_id="c1")],
    })
    assert set(win.canvas._by_id) == {"wc_keep", "row-new"}
    assert win.canvas._rendered["row-new"]["title"] == "Result"
    assert win.topbar._mark.toolTip() == "Connected"


def test_replacement_frame_for_other_chat_leaves_canvas_alone(win):
    win.active_chat = "c1"
    win.canvas.set_components([_card("row-a")])
    win._on_message({
        "type": "components_combined",
        "removed_ids": ["row-a"],
        "new_components": [_row("row-new", chat_id="OTHER")],
    })
    assert set(win.canvas._by_id) == {"row-a"}


def test_component_saved_shows_banner_with_title(win):
    win._on_message({"type": "component_saved", "component": {"id": "x", "title": "Q3 Revenue"}})
    assert not win._banner.isHidden()
    assert "Q3 Revenue" in win._banner.text()


def test_component_saved_without_title_still_visible(win):
    win._on_message({"type": "component_saved", "component": {}})
    assert not win._banner.isHidden()
    assert "saved" in win._banner.text().lower()


def test_component_save_error_shows_error_banner(win):
    win._on_message({"type": "component_save_error", "error": "Component not found"})
    assert not win._banner.isHidden()
    assert "Component not found" in win._banner.text()


def test_combine_status_sets_status_line(win):
    win._on_message({"type": "combine_status", "status": "combining",
                     "message": "Combining A with B..."})
    assert win.topbar._mark.toolTip() == "Combining A with B..."
    win._on_message({"type": "combine_status", "status": "condensing"})
    assert win.topbar._mark.toolTip() == "condensing"


def test_combine_error_resets_status_and_shows_banner(win):
    win._on_message({"type": "combine_status", "status": "combining", "message": "Combining…"})
    win._on_message({"type": "combine_error", "error": "LLM unavailable"})
    assert win.topbar._mark.toolTip() == "Connected"
    assert not win._banner.isHidden()
    assert "LLM unavailable" in win._banner.text()


def test_saved_components_list_hits_refresh_hook(win, caplog):
    with caplog.at_level(logging.INFO, logger="astral.client"):
        win._on_message({"type": "saved_components_list",
                         "components": [{"id": "a"}, {"id": "b"}]})
    assert any("saved components list received (2 items)" in r.message
               for r in caplog.records)


_MINIMAL_FRAMES = [
    {"type": "component_saved", "component": {"id": "x", "title": "T"}},
    {"type": "component_save_error", "error": "boom"},
    {"type": "saved_components_list", "components": []},
    {"type": "component_deleted", "component_id": "wc_x"},
    {"type": "combine_status", "status": "combining", "message": "m"},
    {"type": "combine_error", "error": "boom"},
    {"type": "components_combined", "removed_ids": [], "new_components": []},
    {"type": "components_condensed", "removed_ids": [], "new_components": []},
]


@pytest.mark.parametrize("frame", _MINIMAL_FRAMES, ids=lambda f: f["type"])
def test_verb_frames_route_without_drift_log(win, caplog, frame):
    with caplog.at_level(logging.INFO, logger="astral.client"):
        win._on_message(dict(frame))
    assert not any("frame type=" in r.message for r in caplog.records)
