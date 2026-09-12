"""Native audit filters, grouped events, and cursor continuity share server state."""
import json

import pytest

from astralprojection.chrome.admin import build_audit_view


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


def test_native_audit_preserves_exact_dates_filters_and_back_navigation():
    active = {"q": "<private query>", "from": "2026-09-01", "to": "2026-09-11",
              "cursor": "second", "history": json.dumps([""]), "outcome": "failure"}
    entry = {"event_id": "event", "description": "Denied", "recorded_at": "2026-09-11 12:00:00",
             "outcome": "failure", "action_type": "tool.invoke"}
    view = build_audit_view([entry], filters=active, next_cursor="third")
    assert actions(view, "Previous")[0]["payload"]["fields"] == {**active, "cursor": "", "history": "[]"}
    assert actions(view, "Newest")[0]["payload"]["fields"] == {
        key: value for key, value in active.items() if key not in ("cursor", "history")}
    next_fields = actions(view, "Next")[0]["payload"]["fields"]
    assert next_fields["cursor"] == "third"
    assert json.loads(next_fields["history"]) == ["", "second"]
    assert next_fields["from"] == active["from"]
    params = actions(view, "View details")[0]["payload"]["params"]
    assert params == {"event_id": "event", "return_to": active}
    detail = build_audit_view(selected=entry, filters=params["return_to"])
    assert actions(detail, "Back to audit log")[0]["payload"]["params"] == active
    missing = build_audit_view(selected={}, filters=active)
    assert actions(missing, "Back to audit log")[0]["payload"]["params"] == active


def test_native_audit_discloses_repeated_navigation_without_grouping_failures():
    nav = {"event_id": "1", "recorded_at": "2026-09-11 10:00:00",
           "outcome": "success", "action_type": "audit_view.list"}
    view = build_audit_view([nav, {**nav, "event_id": "2"},
                             {**nav, "event_id": "3", "outcome": "failure"}])
    groups = [n for n in nodes(view.to_dict()) if n.get("type") == "collapsible"]
    assert len(groups) == 1 and groups[0]["default_open"] is False
    assert groups[0]["title"] == "2 navigation and audit views"
    assert len(groups[0]["content"]) == 2
    assert len(actions(view, "View details")) == 3


@pytest.mark.parametrize("history", ["broken", "null", "{}", "[5]", json.dumps([""] * 101), json.dumps(["x" * 513])])
def test_malformed_cursor_history_is_bounded_without_discarding_filters(history):
    view = build_audit_view(filters={"history": history, "cursor": "current", "q": "filter"}, next_cursor="next")
    previous = actions(view, "Previous")[0]["payload"]["fields"]
    assert previous["cursor"] == "" and previous["history"] == "[]"
    assert previous["q"] == "filter"
    assert json.loads(actions(view, "Next")[0]["payload"]["fields"]["history"]) == ["current"]


def test_first_page_has_no_inert_previous_and_filter_controls_are_complete():
    view = build_audit_view()
    assert not actions(view, "Previous") and not actions(view, "Next")
    field_names = [n["name"] for n in nodes(view.to_dict()) if "kind" in n and "name" in n]
    assert field_names == ["event_class", "outcome", "q", "from", "to"]
    assert actions(view, "Failures")[0]["payload"]["fields"] == {"outcome": "failure"}
    assert actions(view, "Tool calls")[0]["payload"]["fields"] == {"event_class": "agent_tool_call"}
    assert actions(view, "Sign ins")[0]["payload"]["fields"] == {"event_class": "auth"}
    assert actions(view, "Reset")[0]["payload"]["fields"] == {}


def test_refused_query_keeps_editable_filters_without_false_empty_success():
    view = build_audit_view(filters={"q": "needle", "from": "2026-02-30"}, loaded=False)
    fields = {n["name"]: n.get("default") for n in nodes(view.to_dict()) if "kind" in n and "name" in n}
    assert fields["q"] == "needle" and fields["from"] == "2026-02-30"
    assert "No audit entries" not in json.dumps(view.to_dict())
    assert not actions(view, "Next")
