"""Defines the terminal panel's closed client dispositions and validates its component
tree before ROTE delivers it to web or native renderers; interactive controls are refused
for every read-only disposition and the watch receives only the content-free handoff.
"""

from __future__ import annotations

import json
import re
from collections.abc import Mapping, Sequence

TERMINAL_SURFACE = "terminal"
INTERACTIVE_PANEL = "interactive_panel"
READ_ONLY_MONITOR = "read_only_monitor"
WATCH_HANDOFF = "phone_desktop_handoff"
OMITTED = "omitted_by_server"

NAVIGATION_ACTIONS = frozenset({"chrome_open", "chrome_close"})
_ALLOWED_TYPES = frozenset(
    {"alert", "badge", "button", "card", "code", "keyvalue", "param_picker", "text"}
)
_MAX_NODES = 1024
_MAX_DEPTH = 8
_MAX_BYTES = 1024 * 1024
_MAX_TEXT = 65536
_MAX_SESSION_ID = 64
_MAX_OFFSET = 9007199254740991
_MAX_INPUT = 512
_COLS_RANGE = (2, 1000)
_ROWS_RANGE = (2, 300)
_SESSION_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,63}")
_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")

_MONITOR_DEVICES = frozenset({"android", "ios", "macos", "tablet", "mobile", "tv"})
_DISPOSITIONS = {
    "browser": INTERACTIVE_PANEL,
    "windows": INTERACTIVE_PANEL,
    "android": READ_ONLY_MONITOR,
    "macos": READ_ONLY_MONITOR,
    "ios": READ_ONLY_MONITOR,
    "watchos": WATCH_HANDOFF,
    "voice": OMITTED,
}


def terminal_disposition(profile_or_device: object, *, monitor: bool = False) -> str:
    device = getattr(getattr(profile_or_device, "device_type", None), "value", profile_or_device)
    if isinstance(device, str):
        if device in {"browser", "windows"}:
            return READ_ONLY_MONITOR if monitor else INTERACTIVE_PANEL
        if device in _MONITOR_DEVICES:
            return READ_ONLY_MONITOR
    if device == "watch":
        return WATCH_HANDOFF
    return OMITTED


def contract_dispositions(*, monitor: bool = False) -> dict[str, str]:
    result = dict(_DISPOSITIONS)
    if monitor:
        result.update(browser=READ_ONLY_MONITOR, windows=READ_ONLY_MONITOR)
    return result


def _session_id(value: object) -> str:
    if type(value) is not str or len(value) > _MAX_SESSION_ID:
        raise ValueError("terminal_surface_unavailable")
    if _SESSION_ID.fullmatch(value) is None:
        raise ValueError("terminal_surface_unavailable")
    return value


def _offset(value: object) -> int:
    if type(value) is not int or isinstance(value, bool) or not 0 <= value <= _MAX_OFFSET:
        raise ValueError("terminal_surface_unavailable")
    return value


def _keyboard(value: object) -> str:
    if type(value) is not str or not value.strip() or len(value) > _MAX_INPUT:
        raise ValueError("terminal_surface_unavailable")
    if _CONTROL.search(value) is not None:
        raise ValueError("terminal_surface_unavailable")
    return value


def _dimension(value: object, bounds: tuple[int, int]) -> int:
    if type(value) is not int or isinstance(value, bool) or not bounds[0] <= value <= bounds[1]:
        raise ValueError("terminal_surface_unavailable")
    return value


def _navigation(node: Mapping[str, object]) -> None:
    action = node.get("action")
    payload = node.get("payload")
    if node.get("local") is True or not isinstance(payload, Mapping):
        raise ValueError("terminal_surface_unavailable")
    if action == "chrome_close":
        if set(payload) - {"surface"} or payload.get("surface") not in (None, TERMINAL_SURFACE):
            raise ValueError("terminal_surface_unavailable")
        return
    if action != "chrome_open" or set(payload) != {"surface", "params"}:
        raise ValueError("terminal_surface_unavailable")
    if payload.get("surface") != TERMINAL_SURFACE or not isinstance(payload.get("params"), Mapping):
        raise ValueError("terminal_surface_unavailable")
    params = payload["params"]
    if set(params) - {"mode", "session_id", "offset"}:
        raise ValueError("terminal_surface_unavailable")
    if params.get("mode") not in {"list", "panel", "monitor"}:
        raise ValueError("terminal_surface_unavailable")
    if "session_id" in params:
        _session_id(params["session_id"])
    if "offset" in params:
        _offset(params["offset"])
    if params["mode"] in {"panel", "monitor"} and "session_id" not in params:
        raise ValueError("terminal_surface_unavailable")


def _interactive_action(node: Mapping[str, object]) -> None:
    action = node.get("action")
    payload = node.get("payload")
    if node.get("local") is True or action not in {"chrome_terminal_interrupt", "chrome_terminal_close"}:
        raise ValueError("terminal_surface_unavailable")
    if not isinstance(payload, Mapping) or set(payload) != {"surface", "session_id"}:
        raise ValueError("terminal_surface_unavailable")
    if payload.get("surface") != TERMINAL_SURFACE:
        raise ValueError("terminal_surface_unavailable")
    _session_id(payload.get("session_id"))


def _form_field(node: object, name: object, kind: object) -> None:
    if not isinstance(node, Mapping) or node.get("name") != name or node.get("kind") != kind:
        raise ValueError("terminal_surface_unavailable")
    if set(node) - {"name", "label", "kind", "default", "help"}:
        raise ValueError("terminal_surface_unavailable")
    if kind == "number":
        _dimension(node.get("default", 80 if name == "cols" else 24),
                   _COLS_RANGE if name == "cols" else _ROWS_RANGE)
    else:
        default = node.get("default")
        if default is not None:
            _keyboard(default)


def _form(node: Mapping[str, object]) -> None:
    submit = node.get("submit_action")
    payload = node.get("submit_payload")
    if not isinstance(payload, Mapping) or payload.get("surface") != TERMINAL_SURFACE:
        raise ValueError("terminal_surface_unavailable")
    _session_id(payload.get("session_id"))
    fields = node.get("fields")
    if submit == "chrome_terminal_input":
        if set(payload) != {"surface", "session_id"} or not isinstance(fields, list) or len(fields) != 1:
            raise ValueError("terminal_surface_unavailable")
        if node.get("actions"):
            raise ValueError("terminal_surface_unavailable")
        _form_field(fields[0], "data", "text")
        return
    if submit == "chrome_terminal_resize":
        if set(payload) != {"surface", "session_id"} or not isinstance(fields, list) or len(fields) != 2:
            raise ValueError("terminal_surface_unavailable")
        if node.get("actions"):
            raise ValueError("terminal_surface_unavailable")
        _form_field(fields[0], "cols", "number")
        _form_field(fields[1], "rows", "number")
        return
    raise ValueError("terminal_surface_unavailable")


def validate_terminal_components(
    components: object,
    supported_types: object = None,
    *,
    interactive: bool = False,
    watch: bool = False,
) -> list[dict]:
    if not isinstance(components, Sequence) or isinstance(components, (str, bytes, bytearray)):
        raise ValueError("terminal_surface_unavailable")
    supported = (
        frozenset(item for item in supported_types if isinstance(item, str))
        if isinstance(supported_types, (set, frozenset, list, tuple))
        else None
    )

    def walk(value: object, depth: int, counter: list[int]) -> None:
        counter[0] += 1
        if counter[0] > _MAX_NODES or depth > _MAX_DEPTH:
            raise ValueError("terminal_surface_unavailable")
        if not isinstance(value, Mapping):
            raise ValueError("terminal_surface_unavailable")
        kind = value.get("type")
        if kind not in _ALLOWED_TYPES or (supported is not None and kind not in supported):
            raise ValueError("terminal_surface_unavailable")
        if watch and kind not in {"badge", "alert"}:
            raise ValueError("terminal_surface_unavailable")
        if kind == "param_picker" and not interactive:
            raise ValueError("terminal_surface_unavailable")
        for key in ("href", "src", "url"):
            if key in value:
                raise ValueError("terminal_surface_unavailable")
        if kind == "code":
            code = value.get("code")
            if type(code) is not str or len(code.encode("utf-8")) > _MAX_TEXT:
                raise ValueError("terminal_surface_unavailable")
            if "\x1b" in code or "\x00" in code:
                raise ValueError("terminal_surface_unavailable")
        if kind == "text" and type(value.get("content")) is not str:
            raise ValueError("terminal_surface_unavailable")
        if kind == "button":
            if interactive:
                action = value.get("action")
                if action in NAVIGATION_ACTIONS:
                    _navigation(value)
                else:
                    _interactive_action(value)
            else:
                _navigation(value)
        elif kind == "param_picker":
            _form(value)
        for key in ("content", "children"):
            children = value.get(key)
            if children is None or isinstance(children, (str, bytes, bytearray)):
                continue
            if not isinstance(children, Sequence):
                raise ValueError("terminal_surface_unavailable")
            for child in children:
                walk(child, depth + 1, counter)

    counter = [0]
    for component in components:
        walk(component, 0, counter)
    if len(json.dumps(components, ensure_ascii=False).encode("utf-8")) > _MAX_BYTES:
        raise ValueError("terminal_surface_unavailable")
    return [dict(component) for component in components]


__all__ = [
    "INTERACTIVE_PANEL",
    "OMITTED",
    "READ_ONLY_MONITOR",
    "TERMINAL_SURFACE",
    "WATCH_HANDOFF",
    "contract_dispositions",
    "terminal_disposition",
    "validate_terminal_components",
]
