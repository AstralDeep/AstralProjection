"""Verifies the shared notification settings/inbox builder emits only owner-authorized source actions and strict revision controls."""

import pytest

from astralprojection.chrome import render_html
from astralprojection.chrome.notifications import build_notifications_view

ENTRY = "48873d61-2e9b-4f38-bc36-bbfa81d78580"
ROUTING = [f"{channel}_{kind}" for channel in ("in_app", "inbox", "push") for kind in ("completion", "failure", "required_action")]


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def state():
    entry = {"entry_id": ENTRY, "event_kind": "completion", "revision": 3, "acknowledged_at": None,
             "deleted_at": None, "content": {"title": "<script>bad</script>", "body": "Work completed", "chat_id": "untrusted-source"}}
    return {"routing": {**dict.fromkeys(ROUTING, True), "revision": 4},
            "quiet_hours": {"version": 1, "quiet_enabled": False, "quiet_start_minute": 1320,
                            "quiet_end_minute": 480, "tz_offset_minutes": -240, "updated_at": 5},
            "entries": [entry], "selected_entry": entry, "source": {"chat_id": "authorized-chat"}}


def test_complete_view_has_exact_revisioned_actions_and_authorized_source():
    view = build_notifications_view(state())
    nodes = list(walk(view.to_dict()))
    forms = [x for x in nodes if x.get("type") == "param_picker"]
    assert len(forms) == 2
    routing = next(x for x in forms if x["submit_action"] == "chrome_notification_preferences")
    assert routing["submit_payload"] == {"expected_revision": 4}
    assert {x["name"] for x in routing["fields"]} == set(ROUTING)
    assert all(x["kind"] == "boolean" and x["default"] is True for x in routing["fields"])
    quiet = next(x for x in forms if x["submit_action"] == "chrome_notification_quiet_hours")
    assert quiet["submit_payload"] == {"expected_revision": 5}
    assert {x["name"] for x in quiet["fields"]} == {"enabled", "start_minute", "end_minute", "tz_offset_minutes"}
    actions = [x for x in nodes if x.get("type") == "button"]
    assert next(x for x in actions if x["action"] == "load_chat")["payload"] == {"chat_id": "authorized-chat"}
    assert next(x for x in actions if x["action"] == "chrome_notification_open")["payload"] == {"entry_id": ENTRY}
    for action in ("chrome_notification_acknowledge", "chrome_notification_delete"):
        assert next(x for x in actions if x["action"] == action)["payload"] == {"entry_id": ENTRY, "expected_revision": 3}
    html = render_html(view)
    assert "<script>" not in html and "&lt;script&gt;" in html
    assert "untrusted-source" not in html


@pytest.mark.parametrize("invalid", [None, [], {}, {"revision": True}, {"revision": -1}, {**dict.fromkeys(ROUTING, "true"), "revision": 1}])
def test_bad_routing_never_emits_mutation_form(invalid):
    data = state()
    data["routing"] = invalid
    nodes = list(walk(build_notifications_view(data).to_dict()))
    assert not any(x.get("submit_action") == "chrome_notification_preferences" for x in nodes)


@pytest.mark.parametrize("key,value", [("quiet_enabled", "true"), ("quiet_start_minute", 1440), ("quiet_end_minute", -1), ("tz_offset_minutes", 841), ("updated_at", True), ("version", 2), ("version", True)])
def test_invalid_quiet_policy_has_no_save(key, value):
    data = state()
    data["quiet_hours"][key] = value
    assert not any(x.get("submit_action") == "chrome_notification_quiet_hours" for x in walk(build_notifications_view(data).to_dict()))


@pytest.mark.parametrize("entry", [None, {}, {"entry_id": "bad", "revision": 1}, {"entry_id": ENTRY, "revision": True}, {"entry_id": ENTRY, "revision": 1, "deleted_at": 2}])
def test_invalid_entry_and_unavailable_source_never_create_navigation(entry):
    data = state()
    data.update(entries=[entry], selected_entry=entry, source={"chat_id": ""})
    actions = [x.get("action") for x in walk(build_notifications_view(data).to_dict())]
    assert "load_chat" not in actions and "chrome_notification_open" not in actions


def test_empty_and_error_states_remain_refreshable_without_raw_errors():
    view = build_notifications_view(None, error="notification_store_unavailable")
    html = render_html(view)
    assert "Refresh" in html and "Notifications are unavailable" in html
    assert "No notifications" in html
    data = state()
    data["selected_entry"]["acknowledged_at"] = 8
    data["source"] = None
    actions = [x.get("action") for x in walk(build_notifications_view(data).to_dict())]
    assert "chrome_notification_acknowledge" not in actions and "load_chat" not in actions


def test_fresh_revision_zero_entry_is_visible_and_actionable():
    data = state()
    data["selected_entry"]["revision"] = 0
    buttons = [x for x in walk(build_notifications_view(data).to_dict()) if x.get("type") == "button"]
    assert next(x for x in buttons if x["action"] == "chrome_notification_acknowledge")["payload"]["expected_revision"] == 0


def test_notifications_menu_and_web_topbar_share_the_host_flag():
    from webrender.chrome.menu_model import build_menu_model, menu_model_dict
    from webrender.chrome.topbar import render_topbar

    def items(model):
        return [item for group in model["menu"] for item in group["items"]]

    assert not any(x["surface"] == "notifications" for x in items(menu_model_dict()))
    for model in [menu_model_dict(notifications_enabled=True), build_menu_model(notifications_enabled=True).to_dict()]:
        assert next(x for x in items(model) if x["surface"] == "notifications")["label"] == "Notifications"
    assert "Settings" in render_topbar(notifications_enabled=True)


def test_unstructured_error_uses_the_safe_unavailable_message():
    html = render_html(build_notifications_view({}, error={"raw": "secret"}))
    assert "Notifications are unavailable" in html and "secret" not in html
