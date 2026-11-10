"""Tests for src/astralprojection/chrome/admin.py's chat-scoped audit view: the scope is shown,
kept by paging, filters and detail navigation, and dropped only by All chats or All activity.
"""

import json
from pathlib import Path

from astralprojection.chrome import render_html
from astralprojection.chrome.admin import build_audit_view

CHAT = "6f1c1d1e-2b9a-4f0e-9a51-0c1d2e3f4a5b"


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


def actions(view, label):
    return [node for node in nodes(view.to_dict()) if node.get("label") == label and "action" in node]


def fields(view):
    return {node["name"]: node for node in nodes(view.to_dict()) if "kind" in node and "name" in node}


def test_scoped_view_names_the_chat_and_offers_all_chats_in_the_filter_form():
    view = build_audit_view(filters={"conversation_id": CHAT}, chat_title="Sourdough <research>")
    payload = view.to_dict()
    assert {"type": "text", "content": "Chat: Sourdough <research>", "variant": "h3"} in payload["components"]
    chat = fields(view)["conversation_id"]
    assert list(fields(view)) == ["conversation_id", "event_class", "outcome", "q", "from", "to"]
    assert chat["kind"] == "select" and chat["default"] == CHAT
    assert chat["options"] == [{"value": "", "label": "All chats"},
                               {"value": CHAT, "label": "Sourdough <research>"}]
    html = render_html(view)
    assert "Sourdough <research>" not in html
    assert "Sourdough &lt;research&gt;" in html


def test_scoped_quick_filters_reset_paging_and_details_keep_the_chat():
    active = {"conversation_id": CHAT, "outcome": "failure", "cursor": "second",
              "history": json.dumps([""])}
    entry = {"event_id": "event", "description": "Denied", "recorded_at": "2026-11-09 12:00:00",
             "outcome": "failure", "action_type": "tool.invoke"}
    view = build_audit_view([entry], filters=active, next_cursor="third", chat_title="Plan")
    assert actions(view, "Reset")[0]["payload"]["fields"] == {"conversation_id": CHAT}
    assert actions(view, "Failures")[0]["payload"]["fields"] == {"conversation_id": CHAT,
                                                                 "outcome": "failure"}
    assert actions(view, "Tool calls")[0]["payload"]["fields"] == {
        "conversation_id": CHAT, "event_class": "agent_tool_call"}
    assert actions(view, "Sign ins")[0]["payload"]["fields"] == {"conversation_id": CHAT,
                                                                 "event_class": "auth"}
    assert actions(view, "All activity")[0]["payload"]["fields"] == {}
    for label in ("Previous", "Newest", "Next"):
        assert actions(view, label)[0]["payload"]["fields"]["conversation_id"] == CHAT
    params = actions(view, "View details")[0]["payload"]["params"]
    assert params["return_to"] == active
    detail = build_audit_view(selected=entry, filters=params["return_to"])
    assert actions(detail, "Back to audit log")[0]["payload"]["params"] == active


def test_unknown_chat_falls_back_to_its_identifier_and_refused_queries_keep_the_scope():
    view = build_audit_view(filters={"conversation_id": CHAT, "q": "needle"}, loaded=False)
    assert fields(view)["conversation_id"]["options"][1] == {"value": CHAT, "label": CHAT}
    assert {"type": "text", "content": f"Chat: {CHAT}", "variant": "h3"} in view.to_dict()["components"]
    assert fields(view)["q"]["default"] == "needle"


def test_unscoped_view_is_unchanged_by_a_title_without_a_chat():
    fixture = Path(__file__).resolve().parents[2] / "contracts/fixtures/workspace_088/audit-empty.json"
    assert build_audit_view(chat_title="Ignored").to_dict() == json.loads(fixture.read_text())
    assert "conversation_id" not in fields(build_audit_view(filters={"conversation_id": "  "}))
