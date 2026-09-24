"""Tests for astral_client/app.py's Canvas (renderer.py, streaming.py):
identity-reconciled rendering — full re-renders keep matching ids in place, upserts
merge by id, and restyle rebuilds retained components.
"""

import os

import pytest

pytest.importorskip("PySide6")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from astral_client.app import Canvas  # noqa: E402
from astral_client.renderer import RenderContext  # noqa: E402
from astral_client.streaming import stream_frame_to_ops, stream_node_id  # noqa: E402


def _ctx():
    return RenderContext(emit=lambda *a: None, download=lambda *a: None)


def _card(cid):
    return {"type": "card", "component_id": cid, "content": []}


def test_identity_preserved_across_full_renders(qapp):
    c = Canvas(_ctx())
    c.set_components([_card("A"), _card("B")])
    wa = c._by_id["A"]
    c.set_components([_card("A"), _card("C")])
    assert "A" in c._by_id and c._by_id["A"] is wa
    assert "C" in c._by_id
    assert "B" not in c._by_id


def test_clobber_sequence_upsert_then_full_render(qapp):
    c = Canvas(_ctx())
    c.apply_ops([{"op": "upsert", "component_id": "A", "component": _card("A")}])
    wa = c._by_id["A"]
    c.set_components([_card("A"), _card("B")])
    assert "A" in c._by_id and "B" in c._by_id
    assert c._by_id["A"] is wa


def test_out_of_turn_render_updates_a_matching_id_in_place(qapp):
    from PySide6.QtWidgets import QLabel

    c = Canvas(_ctx())
    c.set_components([{"type": "card", "component_id": "A",
                       "title": "Live data", "content": []}])
    w1 = c._by_id["A"]
    c.set_components([{"type": "alert", "component_id": "A",
                       "variant": "info", "message": "SNAPSHOT"}])
    w2 = c._by_id["A"]
    assert w2 is not w1
    texts = [(lab.text() or "") for lab in w2.findChildren(QLabel)]
    assert any("SNAPSHOT" in t for t in texts)
    assert not any("Live data" in t for t in texts)


def test_full_render_removes_absent_id(qapp):
    c = Canvas(_ctx())
    c.set_components([_card("A")])
    assert "A" in c._by_id
    c.set_components([_card("B")])
    assert "A" not in c._by_id and "B" in c._by_id


def test_unkeyed_components_rebuild_positionally(qapp):
    c = Canvas(_ctx())
    c.set_components([{"type": "text", "content": "one"},
                      {"type": "text", "content": "two"}])
    assert c._by_id == {}
    assert c._lay.count() - 1 == 2
    c.set_components([{"type": "text", "content": "solo"}])
    assert c._lay.count() - 1 == 1


def test_apply_ops_upsert_and_remove(qapp):
    c = Canvas(_ctx())
    c.apply_ops([{"op": "upsert", "component_id": "X",
                  "component": {"type": "text", "content": "x"}}])
    assert "X" in c._by_id
    c.apply_ops([{"op": "remove", "component_id": "X"}])
    assert "X" not in c._by_id


def test_apply_ops_upsert_replaces_in_place(qapp):
    c = Canvas(_ctx())
    c.apply_ops([{"op": "upsert", "component_id": "X",
                  "component": {"type": "text", "content": "v1"}}])
    w1 = c._by_id["X"]
    idx = c._lay.indexOf(w1)
    c.apply_ops([{"op": "upsert", "component_id": "X",
                  "component": {"type": "text", "content": "v2"}}])
    w2 = c._by_id["X"]
    assert w2 is not w1
    assert c._lay.indexOf(w2) == idx


def test_restyle_rerenders_retained_components(qapp):
    c = Canvas(_ctx())
    c.set_components([_card("A"), _card("B")])
    wa = c._by_id["A"]
    c.restyle()
    assert set(c._by_id) == {"A", "B"}
    assert c._by_id["A"] is not wa
    assert c._lay.count() - 1 == 2


def test_restyle_empty_canvas_is_safe(qapp):
    c = Canvas(_ctx())
    c.restyle()
    assert c._by_id == {}


def test_duplicate_id_in_one_payload_not_inserted_twice(qapp):
    c = Canvas(_ctx())
    c.set_components([_card("A")])
    c.set_components([_card("A"), _card("A"), _card("B")])
    assert set(c._by_id) == {"A", "B"}
    widgets = [c._lay.itemAt(i).widget() for i in range(c._lay.count() - 1)]
    assert len(widgets) == 3
    assert len(set(id(w) for w in widgets)) == 3


def test_unchanged_full_render_early_exits(qapp):
    c = Canvas(_ctx())
    comps = [{"type": "text", "content": "one"}, _card("A")]
    c.set_components(comps)
    unkeyed_before = c._lay.itemAt(0).widget()
    wa = c._by_id["A"]
    c.set_components(comps)
    assert c._lay.itemAt(0).widget() is unkeyed_before
    c.set_components([{"type": "text", "content": "one"}, _card("A")])
    assert c._lay.itemAt(0).widget() is unkeyed_before
    assert c._by_id["A"] is wa


def test_equal_render_after_upsert_still_reconciles(qapp):
    c = Canvas(_ctx())
    c.set_components([_card("A")])
    c.apply_ops([{"op": "upsert", "component_id": "B", "component": _card("B")}])
    assert "B" in c._by_id
    c.set_components([_card("A")])
    assert "B" not in c._by_id
    assert c._lay.count() - 1 == 1


def test_early_exit_still_clears_skeleton(qapp):
    c = Canvas(_ctx())
    c.set_components([_card("A")])
    c.show_skeleton()
    c.set_components([_card("A")])
    assert c._skeleton is None


def test_restyle_bypasses_early_exit(qapp):
    c = Canvas(_ctx())
    c.set_components([_card("A")])
    wa = c._by_id["A"]
    c.restyle()
    assert c._by_id["A"] is not wa


def test_stream_seq_dedupe_drops_dup_and_stale(qapp):
    seq: dict = {}
    frame = {"type": "ui_stream_data", "stream_id": "s1", "seq": 2,
             "components": [{"type": "text", "content": "v2"}]}
    ops = stream_frame_to_ops(frame, active_chat=None, seq_state=seq)
    assert ops and ops[0]["component_id"] == stream_node_id("s1")
    assert stream_frame_to_ops(dict(frame), active_chat=None, seq_state=seq) == []
    stale = dict(frame)
    stale["seq"] = 1
    assert stream_frame_to_ops(stale, active_chat=None, seq_state=seq) == []
