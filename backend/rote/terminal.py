"""Defines the terminal monitor's closed client dispositions and validates its read-only
component tree before ROTE delivers it to web or native renderers.
"""

from __future__ import annotations

import json
import re
from collections.abc import Mapping, Sequence

TERMINAL_SURFACE = "terminal"
READ_ONLY_MONITOR = "read_only_monitor"
WATCH_HANDOFF = "phone_desktop_handoff"
OMITTED = "omitted_by_server"
_MAX_NODES = 1024
_MAX_DEPTH = 8
_MAX_BYTES = 1024 * 1024
_MAX_TEXT = 65536
_SESSION_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,63}")
_ALLOWED_TYPES = frozenset({"alert", "badge", "button", "card", "code", "keyvalue", "text"})
_MONITOR_DEVICES = frozenset(
    {"browser", "tablet", "mobile", "windows", "android", "ios", "macos", "tv"}
)
_DISPOSITIONS = {
    "browser": READ_ONLY_MONITOR,
    "windows": READ_ONLY_MONITOR,
    "android": READ_ONLY_MONITOR,
    "macos": READ_ONLY_MONITOR,
    "ios": READ_ONLY_MONITOR,
    "watchos": WATCH_HANDOFF,
    "voice": OMITTED,
}


def terminal_disposition(profile_or_device: object) -> str:
    device = getattr(getattr(profile_or_device, "device_type", None), "value", profile_or_device)
    if isinstance(device, str) and device in _MONITOR_DEVICES:
        return READ_ONLY_MONITOR
    if device == "watch":
        return WATCH_HANDOFF
    return OMITTED


def contract_dispositions() -> dict[str, str]:
    return dict(_DISPOSITIONS)


def _action(node: Mapping[str, object]) -> None:
    kind = node.get("type")
    if kind not in {"button"}:
        return
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
    if params.get("mode") not in {"list", "monitor"}:
        raise ValueError("terminal_surface_unavailable")
    if "session_id" in params and (
        type(params["session_id"]) is not str or _SESSION_ID.fullmatch(params["session_id"]) is None
    ):
        raise ValueError("terminal_surface_unavailable")
    if "offset" in params and (
        type(params["offset"]) is not int or not 0 <= params["offset"] <= 9007199254740991
    ):
        raise ValueError("terminal_surface_unavailable")
    if params["mode"] == "monitor" and "session_id" not in params:
        raise ValueError("terminal_surface_unavailable")


def validate_terminal_components(
    components: object,
    supported_types: object = None,
    *,
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
        if watch and kind in {"button", "code"}:
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
        _action(value)
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
    "OMITTED",
    "READ_ONLY_MONITOR",
    "TERMINAL_SURFACE",
    "WATCH_HANDOFF",
    "contract_dispositions",
    "terminal_disposition",
    "validate_terminal_components",
]