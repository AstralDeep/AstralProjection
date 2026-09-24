"""Tests for astral_client/streaming.py and Canvas (renderer.py, app.py): the
stream-to-workspace identity bridge, so a component_id-bearing frame's terminal
persisted upsert replaces its node in place instead of double-rendering.
"""

import pytest

from astral_client.streaming import (
    stream_frame_to_ops,
    stream_node_id,
    subscribe_ack_ops,
)


def _frame(**kw):
    base = {"type": "ui_stream_data", "stream_id": "s1", "seq": 1}
    base.update(kw)
    return base


def test_component_id_keys_node_from_first_frame():
    ops = stream_frame_to_ops(
        _frame(component_id="wc_abc", components=[{"type": "text", "content": "hi"}]),
        active_chat=None, seq_state={},
    )
    assert ops[0]["component_id"] == "wc_abc"
    assert not ops[0]["component_id"].startswith("stream-")


def test_absent_field_keeps_stream_node():
    ops = stream_frame_to_ops(
        _frame(components=[{"type": "text", "content": "hi"}]),
        active_chat=None, seq_state={},
    )
    assert ops[0]["component_id"] == stream_node_id("s1")


def test_subscribed_placeholder_keyed_by_component_id():
    ops = subscribe_ack_ops(
        {"stream_id": "s1", "tool_name": "ticker", "component_id": "wc_abc"}
    )
    assert ops[0]["component_id"] == "wc_abc"
    assert "ticker" in ops[0]["component"]["content"]


def test_subscribed_placeholder_without_field_keeps_stream_node():
    ops = subscribe_ack_ops({"stream_id": "s1", "tool_name": "ticker"})
    assert ops[0]["component_id"] == stream_node_id("s1")


def test_subscribed_placeholder_skipped_when_identity_present():
    ops = subscribe_ack_ops(
        {"stream_id": "s1", "tool_name": "ticker", "component_id": "wc_abc"},
        existing_ids={"wc_abc"},
    )
    assert ops == []


def test_subscribed_placeholder_applied_when_identity_absent():
    ops = subscribe_ack_ops(
        {"stream_id": "s1", "tool_name": "ticker", "component_id": "wc_abc"},
        existing_ids={"wc_other"},
    )
    assert ops[0]["component_id"] == "wc_abc"


def test_subscribed_placeholder_skipped_for_existing_stream_node():
    ops = subscribe_ack_ops(
        {"stream_id": "s1", "tool_name": "ticker"},
        existing_ids={stream_node_id("s1")},
    )
    assert ops == []


def test_seq_dedupe_still_keyed_on_stream_id():
    seq: dict = {}
    stream_frame_to_ops(
        _frame(component_id="wc_abc", seq=5, components=[{"type": "text", "content": "a"}]),
        active_chat=None, seq_state=seq,
    )
    assert seq == {"s1": 5}
    stale = stream_frame_to_ops(
        _frame(component_id="wc_abc", seq=4, components=[{"type": "text", "content": "b"}]),
        active_chat=None, seq_state=seq,
    )
    assert stale == []


def test_terminal_forgets_stream_by_stream_id():
    seq = {"s1": 1}
    ops = stream_frame_to_ops(
        _frame(component_id="wc_abc", seq=2, terminal=True,
               components=[{"type": "text", "content": "final"}]),
        active_chat=None, seq_state=seq,
    )
    assert ops[0]["component_id"] == "wc_abc"
    assert "s1" not in seq


def test_error_frame_lands_under_identity_node():
    ops = stream_frame_to_ops(
        _frame(component_id="wc_abc", error={"code": "tool_error", "message": "boom"}),
        active_chat=None, seq_state={},
    )
    assert ops[0]["component_id"] == "wc_abc"
    assert ops[0]["component"]["type"] == "alert"


def test_session_filter_still_applies_with_component_id():
    ops = stream_frame_to_ops(
        _frame(component_id="wc_abc", session_id="chatB",
               components=[{"type": "text", "content": "x"}]),
        active_chat="chatA", seq_state={},
    )
    assert ops == []


@pytest.fixture
def canvas(qapp):
    from astral_client.app import Canvas
    from astral_client.renderer import RenderContext
    return Canvas(RenderContext(emit=lambda *a: None, download=lambda *a: None))


def test_no_double_render_on_terminal_persist_upsert(canvas):
    canvas.apply_ops(subscribe_ack_ops(
        {"stream_id": "s1", "tool_name": "ticker", "component_id": "wc_abc"}))
    assert list(canvas._by_id) == ["wc_abc"]
    seq: dict = {}
    canvas.apply_ops(stream_frame_to_ops(
        _frame(component_id="wc_abc", seq=1,
               components=[{"type": "text", "content": "interim"}]),
        active_chat=None, seq_state=seq))
    canvas.apply_ops(stream_frame_to_ops(
        _frame(component_id="wc_abc", seq=2, terminal=True,
               components=[{"type": "text", "content": "final"}]),
        active_chat=None, seq_state=seq))
    canvas.apply_ops([{"op": "upsert", "component_id": "wc_abc",
                       "component": {"type": "text", "content": "persisted"}}])
    assert list(canvas._by_id) == ["wc_abc"]
    assert canvas._rendered["wc_abc"] == {"type": "text", "content": "persisted"}


def test_late_join_ack_keeps_retained_component(canvas):
    canvas.apply_ops([{"op": "upsert", "component_id": "wc_abc",
                       "component": {"type": "text", "content": "retained"}}])
    canvas.apply_ops(subscribe_ack_ops(
        {"stream_id": "s1", "tool_name": "ticker", "component_id": "wc_abc"},
        existing_ids=canvas._by_id))
    assert canvas._rendered["wc_abc"] == {"type": "text", "content": "retained"}


def test_absent_field_keeps_todays_two_node_shape(canvas):
    canvas.apply_ops(stream_frame_to_ops(
        _frame(components=[{"type": "text", "content": "interim"}]),
        active_chat=None, seq_state={}))
    canvas.apply_ops([{"op": "upsert", "component_id": "wc_abc",
                       "component": {"type": "text", "content": "persisted"}}])
    assert set(canvas._by_id) == {stream_node_id("s1"), "wc_abc"}
