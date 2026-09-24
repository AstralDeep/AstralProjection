"""Validates and renders a model-composed widget against a small closed grammar so an
agent can build a novel layout without emitting raw HTML; gated by
FF_GENERATIVE_PRIMITIVES, falls back to a safe notice.
"""

from __future__ import annotations

import html
import os
from typing import Any, Dict, List, Tuple

_CONTAINERS = {"col", "row", "group"}
_LEAVES = {"text", "label", "value", "badge", "bar", "divider", "spacer"}
_ALLOWED_TYPES = _CONTAINERS | _LEAVES

_VARIANTS = {"default", "muted", "strong", "success", "warning", "danger", "info"}

_MAX_NODES = 120
_MAX_DEPTH = 6
_MAX_CHILDREN = 24
_MAX_TEXT = 2000


def generative_enabled() -> bool:
    return os.getenv("FF_GENERATIVE_PRIMITIVES", "false").strip().lower() in (
        "1", "true", "yes", "on")


def validate(spec: Any) -> Tuple[bool, List[str]]:
    errors: List[str] = []
    count = [0]

    def walk(node: Any, depth: int) -> None:
        if len(errors) > 20:
            return
        if depth > _MAX_DEPTH:
            errors.append(f"max depth {_MAX_DEPTH} exceeded")
            return
        if not isinstance(node, dict):
            errors.append(f"node is not an object: {type(node).__name__}")
            return
        count[0] += 1
        if count[0] > _MAX_NODES:
            errors.append(f"max node count {_MAX_NODES} exceeded")
            return
        t = node.get("t")
        if t not in _ALLOWED_TYPES:
            errors.append(f"disallowed node type: {t!r}")
            return
        variant = node.get("variant")
        if variant is not None and variant not in _VARIANTS:
            errors.append(f"disallowed variant: {variant!r}")
        for field in ("text", "label", "value"):
            v = node.get(field)
            if isinstance(v, str) and len(v) > _MAX_TEXT:
                errors.append(f"{field} exceeds {_MAX_TEXT} chars")
        if t == "bar":
            bv = node.get("value")
            if not isinstance(bv, (int, float)) or isinstance(bv, bool) or not (0 <= bv <= 1):
                errors.append("bar.value must be a number in [0,1]")
        if t in _CONTAINERS:
            children = node.get("children")
            if not isinstance(children, list):
                errors.append(f"{t} requires a children list")
            elif len(children) > _MAX_CHILDREN:
                errors.append(f"{t} exceeds {_MAX_CHILDREN} children")
            else:
                for ch in children:
                    walk(ch, depth + 1)

    walk(spec, 0)
    return (not errors), errors


def _esc(value: Any) -> str:
    return html.escape(str(value), quote=True)


def _render_node(node: Dict[str, Any]) -> str:
    t = node.get("t")
    variant = node.get("variant") if node.get("variant") in _VARIANTS else "default"
    vclass = f" gen-{_esc(variant)}"
    if t == "divider":
        return '<hr class="gen-divider"/>'
    if t == "spacer":
        return '<div class="gen-spacer"></div>'
    if t in ("text", "label", "value", "badge"):
        text = _esc(node.get("text") or node.get("label") or node.get("value") or "")
        cls = {"text": "gen-text", "label": "gen-label", "value": "gen-value",
               "badge": "gen-badge"}[t]
        return f'<span class="{cls}{vclass}">{text}</span>'
    if t == "bar":
        pct = max(0.0, min(1.0, float(node.get("value", 0)))) * 100
        return (f'<div class="gen-bar{vclass}"><div class="gen-bar-fill" '
                f'style="width:{pct:.1f}%"></div></div>')
    if t in _CONTAINERS:
        inner = "".join(_render_node(ch) for ch in node.get("children", [])
                        if isinstance(ch, dict))
        return f'<div class="gen-{_esc(t)}{vclass}">{inner}</div>'
    return ""


def render(spec: Any) -> str:
    ok, errors = validate(spec)
    if not ok:
        return ('<div class="gen-invalid">This generated widget could not be '
                f'safely displayed ({_esc(errors[0])}).</div>')
    return f'<div class="astral-generative">{_render_node(spec)}</div>'
