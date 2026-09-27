"""Validates shared console content, ROTE geometry and current-chat selections.
The native shell consumes these bounded copies without defining product content.
"""

from __future__ import annotations

import copy
import json
import math
import re
import uuid


CONSOLE_CONTRACT = "console/v2"
_LABELS = frozenset(
    "brand title subtitle start_here history agent_directory search_agents dashboard "
    "dashboard_suffix new_chat all_categories example run load_prompt empty_title "
    "empty_subtitle message_placeholder attach more send background advanced fullscreen "
    "exit_fullscreen collapse expand clear_selection result_title result_default_agent "
    "result_agent_role result_preview_action turn_singular turn_plural".split()
)
_NAME = re.compile(r"^[a-z][a-z0-9_]*$")


def _object(value):
    if not isinstance(value, dict):
        raise ValueError("Expected an object")
    return value


def _text(value, maximum, *, empty=False):
    if (not isinstance(value, str) or len(value) > maximum or "\x00" in value
            or not empty and not value.strip()):
        raise ValueError("Invalid console text")
    return value


def _rows(value, maximum):
    if not isinstance(value, list) or len(value) > maximum:
        raise ValueError("Invalid console list")
    return value


def _number(value, minimum=0, maximum=16384):
    if (type(value) not in (int, float) or not math.isfinite(value)
            or not minimum <= value <= maximum):
        raise ValueError("Invalid console dimension")
    return value


def _unique(rows, key):
    if len({row[key] for row in rows}) != len(rows):
        raise ValueError("Duplicate console identity")


def _catalog(value):
    value = _object(value)
    categories = [_text(item, 80) for item in _rows(value.get("categories"), 16)]
    if len(set(categories)) != len(categories):
        raise ValueError("Duplicate category")
    result = {"categories": categories}
    for kind, maximum in (("scenarios", 64), ("agents", 60)):
        result[kind] = []
        for row in _rows(value.get(kind), maximum):
            row = _object(row)
            item = {"id": _text(row.get("id"), 200),
                    "description": _text(row.get("description"), 2000, empty=True)}
            if kind == "scenarios":
                item.update(title=_text(row.get("title"), 200),
                            prompt=_text(row.get("prompt"), 8000),
                            category=_text(row.get("category"), 80))
                if item["category"] not in categories:
                    raise ValueError("Unknown category")
            else:
                item.update(name=_text(row.get("name"), 200),
                            state=row.get("state"), owned=row.get("owned"))
                if item["state"] not in ("ready", "offline") or type(item["owned"]) is not bool:
                    raise ValueError("Invalid agent state")
            result[kind].append(item)
        _unique(result[kind], "id")
    return result


def _composer_action(value):
    value = _object(value)
    item = {key: _text(value.get(key), limit)
            for key, limit in (("key", 80), ("kind", 80), ("label", 200), ("icon", 80))}
    if item["kind"] == "toggle":
        if item["key"] != "background" or "action" in value:
            raise ValueError("Unknown console toggle")
    elif item["kind"] == "action":
        action = _object(value.get("action"))
        surface = _text(action.get("surface"), 80)
        params = _object(action.get("params"))
        if not _NAME.fullmatch(surface):
            raise ValueError("Invalid surface name")
        if len(json.dumps(params, ensure_ascii=False, allow_nan=False).encode("utf-8")) > 16384:
            raise ValueError("Console action too large")
        item["action"] = {"surface": surface, "params": copy.deepcopy(params)}
    else:
        raise ValueError("Unknown console action")
    return item


def parse_console_model(value):
    try:
        value = _object(value)
        if type(value.get("version")) is not int or value["version"] != 2:
            return None
        labels = _object(value.get("labels"))
        if len(labels) > 64 or not _LABELS <= labels.keys():
            return None
        labels = {_text(key, 80): _text(label, 500) for key, label in labels.items()}
        identity = _object(value.get("identity"))
        identity = {key: _text(identity.get(key), limit)
                    for key, limit in (("name", 120), ("role", 40), ("initials", 40))}
        actions = [_composer_action(row) for row in _rows(value.get("composer_actions"), 16)]
        _unique(actions, "key")
        if value.get("show_voice_availability_banner") is not False:
            return None
        return {"version": 2, "labels": labels, "identity": identity,
                "catalog": _catalog(value.get("catalog")), "composer_actions": actions,
                "show_voice_availability_banner": False}
    except (ValueError, TypeError, OverflowError, RecursionError):
        return None


def parse_console_presentation(value):
    try:
        value = _object(value)
        if type(value.get("version")) is not int or value["version"] != 2:
            return None
        result = {"version": 2}
        for key, allowed in (
            ("navigation_mode", ("sidebar", "drawer", "stack")),
            ("settings_presentation", ("dialog", "sheet", "push")),
            ("settings_navigation_axis", ("horizontal", "vertical")),
        ):
            if value.get(key) not in allowed:
                return None
            result[key] = value[key]
        for key in ("sidebar_width", "settings_navigation_width", "fullscreen_inset",
                    "minimum_control_height"):
            result[key] = _number(value.get(key))
        if (result["sidebar_width"] == 0) != (result["navigation_mode"] == "stack"):
            return None
        for key in ("settings_width", "dialog_width", "result_preview_max_height",
                    "result_body_max_height"):
            result[key] = _number(value.get(key), 1)
        result["settings_max_height"] = _number(value.get("settings_max_height"), 0.1)
        columns = _number(value.get("scenario_columns"), 1, 64)
        if int(columns) != columns:
            return None
        result["scenario_columns"] = int(columns)
        for key in ("content_padding", "composer_padding"):
            insets = _object(value.get(key))
            result[key] = {edge: _number(insets.get(edge)) for edge in ("top", "right", "bottom", "left")}
        return result
    except (ValueError, TypeError, OverflowError):
        return None


def _uuid(value):
    if not isinstance(value, str):
        raise ValueError("Invalid revision identity")
    parsed = uuid.UUID(value)
    if parsed.version != 4 or str(parsed) != value:
        raise ValueError("Invalid revision identity")
    return value


def parse_turn_selection(value):
    try:
        value = _object(value)
        if (set(value) != {"version", "agent", "skills", "notes"}
                or type(value["version"]) is not int or value["version"] != 1):
            return None
        agent = value["agent"]
        if agent is not None:
            agent = _object(agent)
            if set(agent) != {"agent_id", "revision_id"}:
                return None
            identity = _text(agent["agent_id"], 255)
            if identity.strip() != identity:
                return None
            agent = {"agent_id": identity, "revision_id": _uuid(agent["revision_id"])}
        result = {"version": 1, "agent": agent}
        for kind, identity_key, maximum in (("skills", "skill_id", 20), ("notes", "note_id", 8)):
            result[kind] = []
            for row in _rows(value[kind], maximum):
                row = _object(row)
                if set(row) != {identity_key, "revision"}:
                    return None
                revision = _number(row["revision"], 1, 9007199254740991)
                if int(revision) != revision:
                    return None
                result[kind].append({identity_key: _uuid(row[identity_key]), "revision": int(revision)})
            _unique(result[kind], identity_key)
        return result
    except (ValueError, TypeError, OverflowError, AttributeError):
        return None
