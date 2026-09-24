"""Serializes the component tree to a role/name/state AOM (accessibility object model)
document, not markup, that voice navigation and assistive tech can walk; registered
as the 'aom' render target in webrender.registry, behind FF_AOM_RENDERER.
"""

from __future__ import annotations

import os
from typing import Any, Dict, List

_MAX_DEPTH = 12
_NAME_CAP = 120

_CHILD_KEYS = ("children", "content")

_HEADING_LEVELS = {"h1": 1, "h2": 2, "h3": 3, "h4": 4, "h5": 5, "h6": 6}


_ROLE_MAP: Dict[str, str] = {
    "card": "group",
    "container": "group",
    "collapsible": "group",
    "grid": "group",
    "table": "table",
    "list": "list",
    "alert": "status",
    "button": "button",
    "input": "textbox",
    "image": "img",
    "metric": "figure",
    "text": "text",
    "tabs": "tablist",
    "hero": "banner",
    "timeline": "list",
    "badge": "note",
}


def aom_enabled() -> bool:
    return os.getenv("FF_AOM_RENDERER", "false").strip().lower() in (
        "1",
        "true",
        "yes",
        "on",
    )


def _type_of(component: Dict[str, Any]) -> str:
    return str(component.get("type", "") or "").strip().lower()


def _heading_level(component: Dict[str, Any]) -> int | None:
    variant = str(component.get("variant", "") or "").strip().lower()
    return _HEADING_LEVELS.get(variant)


def _role(component: Dict[str, Any]) -> str:
    t = _type_of(component)
    if t == "text" and _heading_level(component) is not None:
        return "heading"
    return _ROLE_MAP.get(t, "generic")


def _short(value: Any) -> str:
    text = "" if value is None else str(value)
    text = " ".join(text.split())
    if len(text) > _NAME_CAP:
        text = text[: _NAME_CAP - 1].rstrip() + "…"
    return text


def semantic_name(component: Any) -> str:
    if not isinstance(component, dict):
        return ""
    for key in ("title", "label"):
        value = component.get(key)
        if value not in (None, ""):
            return _short(value)
    for key in ("text", "content", "value"):
        value = component.get(key)
        if isinstance(value, (str, int, float, bool)) and str(value) != "":
            return _short(value)
    return _short(_type_of(component) or "")


def semantic_state(component: Any) -> Dict[str, Any]:
    state: Dict[str, Any] = {}
    if not isinstance(component, dict):
        return state
    if component.get("variant") not in (None, ""):
        state["variant"] = component["variant"]
    if component.get("value") not in (None, ""):
        state["value"] = component["value"]
    if "selected" in component:
        state["selected"] = component["selected"]
    if "disabled" in component:
        state["disabled"] = component["disabled"]
    level = _heading_level(component) if _type_of(component) == "text" else None
    if level is not None:
        state["level"] = level
    return state


def _child_components(component: Dict[str, Any]) -> List[Dict[str, Any]]:
    kids: List[Dict[str, Any]] = []
    for key in _CHILD_KEYS:
        value = component.get(key)
        if isinstance(value, list):
            kids.extend(c for c in value if isinstance(c, dict))
    return kids


def _truncated_leaf() -> Dict[str, Any]:
    return {"role": "generic", "name": "…", "state": {}, "children": []}


def _table_summary_child(component: Dict[str, Any]) -> Dict[str, Any]:
    rows = component.get("rows")
    n_rows = len(rows) if isinstance(rows, list) else 0
    cols = component.get("columns")
    if not isinstance(cols, list):
        cols = component.get("headers")
    if isinstance(cols, list):
        n_cols = len(cols)
    elif isinstance(rows, list) and rows and isinstance(rows[0], list):
        n_cols = len(rows[0])
    else:
        n_cols = 0
    return {
        "role": "text",
        "name": _short(f"{n_rows} rows, {n_cols} columns"),
        "state": {},
        "children": [],
    }


def _tab_children(component: Dict[str, Any]) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for tab in component.get("tabs") or []:
        if isinstance(tab, dict):
            label = tab.get("label", tab.get("title"))
            out.append(
                {
                    "role": "tab",
                    "name": _short("" if label is None else label),
                    "state": {},
                    "children": [],
                }
            )
    return out


def to_semantic_node(component: Any, _depth: int = 0) -> Dict[str, Any]:
    if not isinstance(component, dict):
        return {"role": "generic", "name": "", "state": {}, "children": []}
    if _depth >= _MAX_DEPTH:
        return _truncated_leaf()

    t = _type_of(component)
    if t == "table":
        children = [_table_summary_child(component)]
    elif t == "tabs":
        children = _tab_children(component)
    else:
        children = [
            to_semantic_node(child, _depth + 1)
            for child in _child_components(component)
        ]

    return {
        "role": _role(component),
        "name": semantic_name(component),
        "state": semantic_state(component),
        "children": children,
    }


def render_aom(components: List[Dict[str, Any]], device: Any = None) -> Dict[str, Any]:
    name = device if isinstance(device, str) and device else "canvas"
    children = [
        to_semantic_node(c) for c in (components or []) if isinstance(c, dict)
    ]
    return {"role": "document", "name": name, "children": children}
