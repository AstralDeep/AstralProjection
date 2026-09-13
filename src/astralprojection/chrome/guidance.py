"""Shared private-note views over a closed, already-authorized host snapshot.

Projection neither reads notes nor grants access. The host rechecks the exact
displayed revisions immediately before delivery and authorizes every command.
Plaintext appears only in the owner's ephemeral view, never in action payloads.
All layouts retain the same fields; native interaction qualification is separate.
"""

from __future__ import annotations

from collections.abc import Mapping
from datetime import datetime, timedelta, timezone
import unicodedata
from uuid import UUID

from astralprojection.models import ChromeViewModel, LayoutView, ThemeView

from ._components import alert, badge, build_view, button, card, field, form, text

NOTE_CATEGORY_LABELS = {
    "profession": "Profession", "goal": "Goal", "preference": "Preference",
    "workflow_tag": "Workflow tag", "context": "Context",
}
_NOTICES = {"saved": "Note saved.", "enabled": "Note enabled.",
            "disabled": "Note disabled.", "forgotten": "Note forgotten."}
_MAX = 2**53 - 1


def _require(condition):
    if not condition:
        raise ValueError("notes_view_unavailable")


def _identity(value):
    _require(type(value) is str)
    parsed = UUID(value)
    _require(parsed.version == 4 and str(parsed) == value)
    return value


def _integer(value, minimum=0, maximum=_MAX):
    _require(type(value) is int and minimum <= value <= maximum)


def _string(value, maximum, *, empty=False):
    _require(type(value) is str and (empty or bool(value)))
    _require(len(value.encode("utf-8")) <= maximum)
    _require(not any(unicodedata.category(char) in {"Cc", "Cs"} and char not in "\n\t"
                     for char in value))


def _note(value):
    _require(isinstance(value, Mapping) and set(value) == {
        "note_id", "revision", "category", "value", "enabled", "expires_at"})
    _identity(value["note_id"])
    _integer(value["revision"], 1, _MAX - 1)
    _require(type(value["category"]) is str and value["category"] in NOTE_CATEGORY_LABELS)
    _require(type(value["enabled"]) is bool)
    _string(value["value"], 4096)
    if value["expires_at"] is not None:
        _integer(value["expires_at"])
    return value


def _date(value):
    if value is None:
        return ""
    try:
        instant = datetime(1970, 1, 1, tzinfo=timezone.utc) + timedelta(milliseconds=value)
        return instant.isoformat(timespec="milliseconds").replace("+00:00", "Z")
    except OverflowError:
        # The storage range exceeds datetime's. Keeping the existing expiry
        # always preserves its exact integer, even when it cannot be displayed.
        return ""


def _nav(label, mode="list", **params):
    return button(label, "chrome_open", {"surface": "guidance", "params": {"mode": mode, **params}})


def _key(note):
    return {"note_id": note["note_id"], "expected_revision": note["revision"]}


def _summary(note):
    expiry = note["expires_at"]
    label = "No expiry" if expiry is None else ("Expires " + _date(expiry) if _date(expiry) else "Expiry is set")
    return [badge("Enabled" if note["enabled"] else "Disabled"),
            text(note["value"]), text(label, "caption")]


def _list(state):
    notes, search, cursor = state["notes"], state["search"], state["next_cursor"]
    _require(type(notes) in {tuple, list} and len(notes) <= 100)
    _string(search, 256, empty=True)
    if cursor is not None:
        _identity(cursor)
    for note in notes:
        _note(note)
    _require(len({note["note_id"] for note in notes}) == len(notes))
    components = [text("Private notes are guidance you can select for your work."),
                  _nav("Add note", "new"),
                  form([field("search", "Search notes", default=search)],
                       submit_action="chrome_note_search", submit_label="Search")]
    if not notes:
        components.append(text("No matching notes on this page." if search or cursor
                               else "No private notes yet."))
    for note in notes:
        components.append(card(NOTE_CATEGORY_LABELS[note["category"]], [*_summary(note),
            _nav("Edit", "edit", **_key(note)),
            button("Disable" if note["enabled"] else "Enable", "chrome_note_toggle",
                   {**_key(note), "enabled": not note["enabled"]}),
            _nav("Forget", "forget", **_key(note))]))
    if cursor is not None:
        components.append(_nav("Next page", after_id=cursor, search=search))
    components.append(_nav("Refresh", search=search))
    return components


def _editor(state):
    new = state["mode"] == "new"
    note = ({"note_id": _identity(state["note_id"]), "revision": 0, "category": "context",
             "value": "", "enabled": True, "expires_at": None} if new else _note(state["note"]))
    expiry_options = ["No expiry", "Set a date"] if new else ["Keep current expiry", "No expiry", "Set a date"]
    components = [_nav("Back to notes")]
    if not new:
        components.extend([text("Current note", "h3"), *_summary(note)])
    components.append(form([
        field("category", "Category", "select", default=NOTE_CATEGORY_LABELS[note["category"]],
              options=list(NOTE_CATEGORY_LABELS.values())),
        field("value", "Note", "textarea", default=note["value"],
              help_text="Describe your preferences or context. Do not include patient information."),
        field("enabled", "Enabled", "boolean", default=note["enabled"]),
        field("expiry", "Expiry", "select", default=expiry_options[0], options=expiry_options),
        field("expiry_date", "Expiry date (UTC)", default=_date(note["expires_at"]),
              help_text="Use a UTC date and time, for example 2026-12-31T23:59:00Z.",
              visible_when={"expiry": "Set a date"}),
    ], title="Add note" if new else "Edit note", submit_action="chrome_note_save",
        submit_label="Save note", submit_payload=_key(note)))
    return components


def _forget(state):
    note = _note(state["note"])
    return [_nav("Keep note"), card(NOTE_CATEGORY_LABELS[note["category"]], _summary(note)),
            alert("Forget permanently erases this note's current value. This cannot be undone.", "warning"),
            button("Forget note", "chrome_note_forget", _key(note), variant="danger")]


def build_notes_view(state: Mapping[str, object], *, theme: ThemeView | None = None,
                     layout: LayoutView | None = None) -> ChromeViewModel:
    """Build list/new/edit/forget views; malformed snapshots disclose no rows."""
    try:
        _require(isinstance(state, Mapping))
        status = state.get("status")
        _require(type(status) is str and status in {"ready", "loading", "unavailable"})
        if status != "ready":
            components = [text("Loading private notes…") if status == "loading" else
                          alert("Private notes are unavailable. Refresh to try again.", "error")]
        else:
            mode = state.get("mode")
            _require(type(mode) is str and mode in {"list", "new", "edit", "forget"})
            expected = ({"notes", "search", "next_cursor"} if mode == "list" else
                        {"note_id"} if mode == "new" else {"note"})
            _require(set(state) - {"notice"} == {"mode", "status", *expected})
            notice = state.get("notice")
            _require(notice is None or (type(notice) is str and notice in _NOTICES))
            components = (_list(state) if mode == "list" else
                          _forget(state) if mode == "forget" else _editor(state))
            if notice is not None:
                components.insert(0, alert(_NOTICES[notice], "success"))
    except (ValueError, TypeError, KeyError, AttributeError, UnicodeError):
        components = [alert("Private notes are unavailable. Refresh to try again.", "error")]
    return build_view("guidance", "Private notes", components, theme=theme, layout=layout)
