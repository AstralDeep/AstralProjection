"""Builds the shared notification routing, quiet-hours and inbox surface from host-authorized state using existing chrome primitives."""

from collections.abc import Mapping
from uuid import UUID

from ._components import alert, badge, build_view, button, card, container, field, form, text

ROUTING_FIELDS = tuple(f"{channel}_{kind}" for channel in ("in_app", "inbox", "push")
                       for kind in ("completion", "failure", "required_action"))
_LABELS = {"in_app": "In app", "inbox": "Inbox", "push": "Phone notifications"}
_KINDS = {"completion": "Completed work", "failure": "Failures", "required_action": "Action required"}
_ERRORS = {
    "notification_store_unavailable": "Notifications are unavailable. Try again.",
    "notification_entry_not_found": "This notification is no longer available.",
    "notification_policy_invalid": "Check the notification settings and try again.",
    "notification_policy_conflict": "Settings changed. Refresh before saving.",
    "notification_entry_conflict": "This notification changed. Refresh before trying again.",
}


def _map(value):
    return value if isinstance(value, Mapping) else {}


def _integer(value, minimum=0, maximum=2**53 - 1):
    return type(value) is int and minimum <= value <= maximum


def _entry(value):
    row = _map(value)
    try:
        identity = str(UUID(row.get("entry_id", "")))
    except (ValueError, AttributeError, TypeError):
        return None
    if identity != row.get("entry_id") or not _integer(row.get("revision")) or row.get("deleted_at") is not None:
        return None
    return row


def _entry_card(row, *, detail=False):
    content = _map(row.get("content"))
    identity = row["entry_id"]
    controls = [button("Open", "chrome_notification_open", {"entry_id": identity})]
    payload = {"entry_id": identity, "expected_revision": row["revision"]}
    if row.get("acknowledged_at") is None:
        controls.append(button("Mark read", "chrome_notification_acknowledge", payload))
    controls.append(button("Delete", "chrome_notification_delete", payload, variant="danger"))
    children = [badge("Read" if row.get("acknowledged_at") is not None else "Unread"),
                text(str(content.get("body") or "")[:8192]), container(controls, direction="row")]
    return card(str(content.get("title") or ("Notification detail" if detail else "Notification"))[:256], children)


def build_notifications_view(state, error=None):
    state = _map(state)
    components = []
    if error:
        components.append(alert(_ERRORS.get(error if isinstance(error, str) else None, "Notifications are unavailable. Try again."), "error"))
    routing = _map(state.get("routing"))
    if _integer(routing.get("revision")) and all(type(routing.get(key)) is bool for key in ROUTING_FIELDS):
        fields = []
        for channel, channel_label in _LABELS.items():
            for kind, kind_label in _KINDS.items():
                name = f"{channel}_{kind}"
                fields.append(field(name, f"{channel_label}: {kind_label.lower()}", "boolean", default=routing[name]))
        components.append(form(fields, title="Notification routing", submit_action="chrome_notification_preferences",
                               submit_payload={"expected_revision": routing["revision"]}, submit_label="Save routing"))
    quiet = _map(state.get("quiet_hours"))
    valid_quiet = (type(quiet.get("version")) is int and quiet["version"] == 1 and type(quiet.get("quiet_enabled")) is bool
                   and _integer(quiet.get("quiet_start_minute"), 0, 1439)
                   and _integer(quiet.get("quiet_end_minute"), 0, 1439)
                   and _integer(quiet.get("tz_offset_minutes"), -840, 840)
                   and _integer(quiet.get("updated_at")))
    if valid_quiet:
        components.append(form([
            field("enabled", "Quiet hours", "boolean", default=quiet["quiet_enabled"]),
            field("start_minute", "Start minute after midnight", "number", default=quiet["quiet_start_minute"]),
            field("end_minute", "End minute after midnight", "number", default=quiet["quiet_end_minute"]),
            field("tz_offset_minutes", "UTC offset in minutes", "number", default=quiet["tz_offset_minutes"]),
        ], title="Quiet hours", submit_action="chrome_notification_quiet_hours",
            submit_payload={"expected_revision": quiet["updated_at"]}, submit_label="Save quiet hours"))
    selected = _entry(state.get("selected_entry"))
    if selected:
        components.append(_entry_card(selected, detail=True))
        source = _map(state.get("source")).get("chat_id")
        if isinstance(source, str) and source.strip() and len(source) <= 128:
            components.append(button("Open conversation", "load_chat", {"chat_id": source}, variant="primary"))
    rows = state.get("entries")
    rows = rows[:200] if isinstance(rows, (list, tuple)) else []
    entries = [row for item in rows if (row := _entry(item)) is not None]
    components.extend(_entry_card(row) for row in entries if not selected or row["entry_id"] != selected["entry_id"])
    if not entries and not selected:
        components.append(text("No notifications."))
    components.append(button("Refresh", "chrome_open", {"surface": "notifications"}))
    return build_view("notifications", "Notifications", components)
