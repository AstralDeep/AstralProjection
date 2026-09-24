"""Tests for astral_client/app.py and renderer.py's Canvas: the query-start loading
skeleton — appended on show, cleared by the first full render or upsert, kept through
no-op ops, and idempotent hide at turn end.
"""

import os

import pytest

pytest.importorskip("PySide6")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from astral_client.app import Canvas  # noqa: E402
from astral_client.renderer import RenderContext, render  # noqa: E402


def _ctx():
    return RenderContext(emit=lambda *a: None, download=lambda *a: None)


def _card(cid):
    return {"type": "card", "component_id": cid, "content": []}


def test_show_skeleton_appends_placeholder(qapp):
    c = Canvas(_ctx())
    assert c._skeleton is None
    c.show_skeleton()
    assert c._skeleton is not None
    assert c._lay.indexOf(c._skeleton) != -1
    first = c._skeleton
    c.show_skeleton()
    assert c._skeleton is first


def test_full_render_clears_skeleton(qapp):
    c = Canvas(_ctx())
    c.show_skeleton()
    c.set_components([_card("A")])
    assert c._skeleton is None
    assert "A" in c._by_id


def test_upsert_clears_skeleton(qapp):
    c = Canvas(_ctx())
    c.show_skeleton()
    c.apply_ops([{"op": "upsert", "component_id": "A", "component": _card("A")}])
    assert c._skeleton is None
    assert "A" in c._by_id


def test_empty_ops_keep_skeleton(qapp):
    c = Canvas(_ctx())
    c.show_skeleton()
    c.apply_ops([])
    assert c._skeleton is not None


def test_hide_skeleton_is_idempotent(qapp):
    c = Canvas(_ctx())
    c.hide_skeleton()
    c.show_skeleton()
    c.hide_skeleton()
    assert c._skeleton is None
    c.hide_skeleton()


def test_skeleton_appends_below_existing_components(qapp):
    c = Canvas(_ctx())
    c.set_components([_card("A")])
    c.show_skeleton()
    assert c._lay.indexOf(c._skeleton) > c._lay.indexOf(c._by_id["A"])


def test_skeleton_card_variant_renders_blocks(qapp):
    w = render({"type": "skeleton", "variant": "card", "count": 3}, _ctx())
    assert w.layout().count() == 3
    bar = w.layout().itemAt(0).widget()
    assert bar.height() >= 40 or bar.minimumHeight() >= 40
