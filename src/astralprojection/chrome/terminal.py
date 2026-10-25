"""Builds the shared terminal panel from host-authorized session and output snapshots.
The panel exposes list/panel reads, streamed literal output, platform text selection and,
for interactive dispositions, the governed keyboard, resize, interrupt and session-close
controls; every button submits to the server-owned terminal action contract.
"""

from __future__ import annotations

import re
from collections.abc import Mapping, Sequence
from typing import Any

from astralprojection.models import ChromeViewModel, LayoutView, ThemeView
from webrender.terminal import (
    MAX_KEYBOARD_TEXT,
    bounded_terminal_output,
    decode_terminal_chunk,
    terminal_number,
    terminal_seconds,
)

from ._components import alert, badge, build_view, button, card, code_block, field, form, key_value, text

SURFACE = "terminal"
CONTRACT = "terminal_panel/v1"
TITLE = "Terminal panel"
LIST_TITLE = "Terminal sessions"
MAX_SESSIONS = 16
MAX_NODES = 1024
MAX_DEPTH = 8
MAX_OFFSET = 9007199254740991

_SESSION_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,63}")
_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
_STATES = {
    "running": ("Running", "info"),
    "open": ("Running", "info"),
    "exited": ("Exited", "warning"),
    "closed": ("Closed", "default"),
    "disconnected": ("Disconnected", "warning"),
    "unavailable": ("Unavailable", "warning"),
}
_STATUSES = (
    "ready",
    "loading",
    "unavailable",
    "stale",
    "wrong_owner",
    "disconnected",
    "account_changed",
    "denied",
    "expired",
    "error",
    "timeout",
)
_STATUS_ALIASES = {
    "denied": "wrong_owner",
    "expired": "stale",
    "error": "unavailable",
    "timeout": "unavailable",
}
_FAILURES = {
    "loading": ("Loading the terminal panel…", "info", False),
    "unavailable": (
        "The terminal panel is unavailable on this host. Refresh to check its current state.",
        "info",
        True,
    ),
    "stale": (
        "This terminal view is stale. Refresh to read the current owner session.",
        "warning",
        True,
    ),
    "wrong_owner": (
        "This terminal session is not available to the current account.",
        "warning",
        True,
    ),
    "disconnected": (
        "The connection ended. Reconnect before refreshing this terminal panel.",
        "warning",
        True,
    ),
    "account_changed": (
        "The signed-in account changed. This panel was closed; reopen the terminal "
        "from the current account.",
        "warning",
        False,
    ),
}
_READ_ONLY_HINT = (
    "Terminal output is read-only here. Select the text to copy it; terminal links and "
    "clipboard escape sequences are ignored."
)
_INTERACTIVE_HINT = (
    "Output is literal selectable text for copying. Terminal links and clipboard escape "
    "sequences are ignored; the host validates every submitted operation."
)
_WATCH_HANDOFF = (
    "This terminal panel continues on your phone or desktop. Session output and "
    "identifiers are not sent to the watch."
)


def _require(condition: bool) -> None:
    if not condition:
        raise ValueError("terminal_view_unavailable")


def _plain(value: object, maximum: int, *, empty: bool = False) -> str:
    _require(type(value) is str)
    _require(
        (empty or bool(value.strip()))
        and len(value) <= maximum
        and len(value.encode("utf-8", "replace")) <= maximum
        and _CONTROL.search(value) is None
    )
    return value


def _session_id(value: object) -> str:
    _require(type(value) is str and _SESSION_ID.fullmatch(value) is not None)
    return value


def _integer(value: object, minimum: int = 0, maximum: int = MAX_OFFSET) -> int:
    _require(type(value) is int and minimum <= value <= maximum)
    return value


def _boolean(value: object) -> bool:
    _require(type(value) is bool)
    return value


def _mapping(value: object) -> Mapping[str, Any]:
    _require(isinstance(value, Mapping))
    return value


def _target(value: object) -> str:
    if isinstance(value, Mapping):
        for key in ("label", "name", "machine_id", "host", "address"):
            candidate = value.get(key)
            if isinstance(candidate, str) and candidate.strip():
                return _plain(candidate, 200)
    return _plain(value, 200, empty=True) or "Target not reported"


def _session(value: object) -> dict[str, Any]:
    source = _mapping(value)
    identity = _session_id(source.get("session_id", source.get("id")))
    state = source.get("state", source.get("status", "running"))
    _require(type(state) is str and state in _STATES)
    target = _target(source.get("target", source.get("machine", "")))
    directory = _plain(
        source.get("directory", source.get("cwd", "")), 1024, empty=True
    ) or "Directory not reported"
    result = {
        "session_id": identity,
        "target": target,
        "directory": directory,
        "state": state,
        "cols": _integer(source.get("cols", 80), 2, 1000),
        "rows": _integer(source.get("rows", 24), 2, 300),
        "idle_seconds": terminal_seconds(source.get("idle_seconds", 0)),
        "ring_start": _integer(source.get("ring_start", 0)),
        "ring_end": _integer(source.get("ring_end", source.get("ring_start", 0))),
    }
    _require(result["ring_start"] <= result["ring_end"])
    created = source.get("created_at")
    if created is not None:
        result["created_at"] = _plain(created, 48)
    return result


def _output(state: Mapping[str, Any]) -> tuple[str, bool, int, int, bool]:
    raw = state.get("output")
    read = state.get("read")
    read = read if isinstance(read, Mapping) else {}
    source = raw if isinstance(raw, Mapping) else state
    text_value = raw if isinstance(raw, str) else source.get("text", source.get("content", ""))
    encoded = source.get("data_b64")
    if encoded is None:
        encoded = state.get("data_b64")
    if encoded is not None:
        _require(type(encoded) is str)
        raw_text = decode_terminal_chunk(encoded)
    else:
        _require(type(text_value) is str)
        raw_text = text_value
    bounded, truncated = bounded_terminal_output(raw_text)
    offset = terminal_number(source.get("offset", read.get("offset", state.get("offset", 0))))
    next_offset = terminal_number(
        source.get("next_offset", read.get("next_offset", state.get("next_offset", offset)))
    )
    _require(next_offset >= offset)
    reported_truncated = source.get("truncated", read.get("truncated", state.get("truncated", False)))
    reported_eof = source.get("eof", read.get("eof", state.get("eof", False)))
    return (
        bounded,
        truncated or _boolean(reported_truncated),
        offset,
        next_offset,
        _boolean(reported_eof),
    )


def _open(label: str, mode: str, **params: object):
    return button(
        label,
        "chrome_open",
        {"surface": SURFACE, "params": {"mode": mode, **params}},
    )


def _close_monitor():
    return button("Close panel", "chrome_close", {"surface": SURFACE})


def _session_badge(state: str):
    label, variant = _STATES[state]
    return badge(label, variant)


def _session_rows(session: Mapping[str, Any]) -> list[tuple[str, str]]:
    rows = [
        ("Session", session["session_id"]),
        ("Target", session["target"]),
        ("Directory", session["directory"]),
        ("State", _STATES[session["state"]][0]),
        ("Size", f"{session['cols']} × {session['rows']}"),
        ("Output bytes", f"{session['ring_start']}..{session['ring_end']}"),
    ]
    if "created_at" in session:
        rows.append(("Created", session["created_at"]))
    return rows


def _list(state: Mapping[str, Any]) -> tuple[str, list]:
    sessions = state.get("sessions", [])
    _require(
        isinstance(sessions, Sequence)
        and not isinstance(sessions, (str, bytes, bytearray))
        and len(sessions) <= MAX_SESSIONS
    )
    rows = [_session(value) for value in sessions]
    identities = [row["session_id"] for row in rows]
    _require(len(set(identities)) == len(identities))
    components = [
        card(
            row["target"],
            [
                _session_badge(row["state"]),
                key_value(_session_rows(row)[2:]),
                _open("Open terminal panel", "panel", session_id=row["session_id"]),
            ],
        )
        for row in rows
    ]
    if not rows:
        components.append(text("No terminal sessions are open for this account."))
    components.extend([_open("Refresh terminal list", "list"), _close_monitor()])
    return LIST_TITLE, components


def _input_form(session_id: str):
    return form(
        [
            field(
                "data",
                "Keyboard input",
                "text",
                help_text=(
                    f"Up to {MAX_KEYBOARD_TEXT} characters without control characters; "
                    "the host submits this one governed line to the terminal."
                ),
            )
        ],
        title="Keyboard input",
        description="Submitted through the governed terminal contract; never replayed or queued.",
        submit_action="chrome_terminal_input",
        submit_payload={"surface": SURFACE, "session_id": session_id},
        submit_label="Send to terminal",
    )


def _resize_form(session: Mapping[str, Any]):
    return form(
        [
            field("cols", "Columns", "number", default=session["cols"]),
            field("rows", "Rows", "number", default=session["rows"]),
        ],
        title="Resize terminal",
        description="Columns 2–1000, rows 2–300; the host applies the new size to the session.",
        submit_action="chrome_terminal_resize",
        submit_payload={"surface": SURFACE, "session_id": session["session_id"]},
        submit_label="Apply resize",
    )


def _controls(session: Mapping[str, Any]) -> list:
    identity = session["session_id"]
    scope = {"surface": SURFACE, "session_id": identity}
    return [
        _input_form(identity),
        button("Send interrupt", "chrome_terminal_interrupt", dict(scope)),
        _resize_form(session),
        button("Close terminal session", "chrome_terminal_close", dict(scope)),
    ]


def _panel(state: Mapping[str, Any], *, interactive: bool) -> tuple[str, list]:
    output, truncated, offset, next_offset, eof = _output(state)
    session_value = state.get("session")
    if session_value is None:
        session_value = {
            "session_id": state.get("session_id"),
            "target": state.get("target", ""),
            "directory": state.get("directory", state.get("cwd", "")),
            "state": state.get("state", "exited" if eof else "running"),
            "cols": state.get("cols", 80),
            "rows": state.get("rows", 24),
            "idle_seconds": state.get("idle_seconds", 0),
            "ring_start": state.get("ring_start", offset),
            "ring_end": state.get("ring_end", next_offset),
        }
    session = _session(session_value)
    if eof and session["state"] in {"running", "open"}:
        session["state"] = "exited"
    components = [
        _session_badge(session["state"]),
        key_value(_session_rows(session), title="Session"),
    ]
    if truncated:
        components.append(
            alert(
                "The retained output window is truncated. Earlier bytes are no longer "
                "available in this panel.",
                "warning",
            )
        )
    if eof:
        components.append(
            alert("The terminal has exited. Retained output remains read-only.", "info")
        )
    output_content = [code_block(output, "terminal")] if output else [
        text("No output is available yet.", "caption")
    ]
    output_content.append(
        text(_INTERACTIVE_HINT if interactive else _READ_ONLY_HINT, "caption")
    )
    components.append(card("Output", output_content))
    components.append(
        key_value(
            [("Read from byte", str(offset)), ("Next byte", str(next_offset))],
            title="Output window",
        )
    )
    components.append(
        _open("Refresh output", "panel", session_id=session["session_id"], offset=next_offset)
    )
    if offset > 0:
        components.append(
            _open("Reload retained output", "panel", session_id=session["session_id"])
        )
    if interactive and session["state"] in {"running", "open"}:
        components.append(card("Terminal controls", _controls(session)))
    components.extend([_open("Back to terminals", "list"), _close_monitor()])
    return f"Terminal panel · {session['target']}", components


def _failure(status: str, *, interactive: bool) -> list:
    del interactive
    canonical = _STATUS_ALIASES.get(status, status)
    message, variant, recover = _FAILURES.get(canonical, _FAILURES["unavailable"])
    components = [alert(message, variant)]
    if recover:
        components.append(_open("Refresh terminal list", "list"))
    components.append(_close_monitor())
    return components


def _watch(state: object) -> list:
    components = []
    if isinstance(state, Mapping):
        session = state.get("session")
        selected = (
            session.get("state", session.get("status"))
            if isinstance(session, Mapping)
            else state.get("state", "exited" if state.get("eof") is True else None)
        )
        if isinstance(selected, str) and selected in _STATES:
            components.append(_session_badge(selected))
    components.append(alert(_WATCH_HANDOFF, "info"))
    return components


def build_terminal_view(
    state: Mapping[str, object],
    *,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
    watch: bool = False,
    interactive: bool = False,
) -> ChromeViewModel:
    title = TITLE
    if watch:
        components = _watch(state)
    else:
        try:
            _require(isinstance(state, Mapping))
            mode = state.get("mode", "panel")
            status = state.get("status", "ready")
            _require(type(mode) is str and mode in ("list", "panel"))
            _require(type(status) is str and status in _STATUSES)
            if status != "ready":
                components = _failure(status, interactive=interactive)
                title = LIST_TITLE if mode == "list" else TITLE
            elif mode == "list":
                title, components = _list(state)
            else:
                title, components = _panel(state, interactive=interactive)
        except (ValueError, TypeError, AttributeError, KeyError, OverflowError):
            title = LIST_TITLE
            components = _failure("unavailable", interactive=interactive)
    return build_view(SURFACE, title, components, theme=theme, layout=layout)


build_terminal_panel_view = build_terminal_view


__all__ = [
    "CONTRACT",
    "LIST_TITLE",
    "MAX_DEPTH",
    "MAX_NODES",
    "MAX_SESSIONS",
    "SURFACE",
    "TITLE",
    "build_terminal_panel_view",
    "build_terminal_view",
]
