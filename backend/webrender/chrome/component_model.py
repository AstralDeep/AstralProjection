"""Server-owned component action presentation; descriptors never grant authority.

Build from the original canonical component before device fallback changes its
type, then stamp an outbound copy after adaptation. Never persist this receiver-
specific field or accept an agent's proposed action inventory as host policy.
"""
from __future__ import annotations

import os
from collections.abc import Callable, Mapping
from typing import Any

_ACTIONS = (
    ("refine", "refine", "✎", "Refine this component with an instruction", "live_canvas"),
    ("history", "history", "⟲", "Version history", "live_canvas"),
    ("csv", "csv", "⬇", "Download the full table as CSV", "owned_chat"),
    ("share", "share", "↗", "Create a revocable read-only share link", "owned_chat"),
)
_FIELDS = ("kind", "label", "icon", "title", "context")
_CONTEXTS = {row[0]: row[-1] for row in _ACTIONS}
_FLAGS = {
    "component_refine": ("FF_COMPONENT_REFINE", True),
    "artifact_export": ("FF_ARTIFACT_EXPORT", True),
    "artifact_sharing": ("FF_ARTIFACT_SHARING", False),
}


def _enabled(name: str) -> bool:
    variable, default = _FLAGS[name]
    return os.getenv(variable, str(default)).lower() in ("true", "1", "yes")


def component_versions(component: Mapping[str, Any]) -> list[dict[str, Any]]:
    """Retain at most five metadata rows; no archived body or arbitrary keys."""
    raw = component.get("versions")
    if not isinstance(raw, list):
        return []
    result = []
    seen: set[int] = set()
    duplicates: set[int] = set()
    for value in raw[:5]:
        if not isinstance(value, dict):
            continue
        number = value.get("version_no")
        # JSON consumers must address the same exact version number.
        if (type(number) not in (int, float) or not 1 <= number <= 9007199254740991
                or int(number) != number):
            continue
        if number in seen:
            duplicates.add(int(number))
        seen.add(int(number))
        if any(value.get(key) is not None and not isinstance(value[key], str)
               for key in ("reason", "created_at", "title")):
            continue
        result.append({
            "version_no": int(number),
            "reason": str(value.get("reason") or "")[:32],
            "created_at": str(value.get("created_at") or "")[:64],
            "title": str(value.get("title") or "")[:120],
        })
    return [row for row in result if row["version_no"] not in duplicates]


def build_component_chrome(
    component: Mapping[str, Any], profile: Any, *,
    enabled: Callable[[str], bool] | None = None,
) -> dict[str, Any]:
    """One fixed inventory for web and native consumers of an owned component."""
    empty: dict[str, Any] = {"version": 1, "actions": []}
    dtype = getattr(getattr(profile, "device_type", None), "value", "")
    cid = component.get("component_id")
    ctype = str(component.get("type", "")).strip().lower()
    if (profile is None or not getattr(profile, "supports_interactivity", True)
            or dtype in ("watch", "voice") or not isinstance(cid, str) or not cid
            or cid.startswith(("dg_", "ly_", "wel_"))
            or ctype in ("divider", "skeleton")):
        return empty
    resolve = enabled or _enabled

    def flag(name: str) -> bool:
        try:
            return resolve(name) is True
        except Exception:
            return False

    refine = flag("component_refine")
    allowed = {"refine": refine, "history": refine,
               "csv": ctype == "table" and flag("artifact_export"),
               "share": flag("artifact_sharing")}
    return {"version": 1, "actions": [dict(zip(_FIELDS, row))
                                      for row in _ACTIONS if allowed[row[0]]]}


def component_action_descriptors(value: object) -> list[dict[str, str]]:
    """Parse the bounded additive wire field. Ignore unsupported entries safely."""
    if (not isinstance(value, dict) or set(value) != {"version", "actions"}
            or type(value.get("version")) not in (int, float) or value["version"] != 1
            or not isinstance(value.get("actions"), list) or len(value["actions"]) > 16):
        return []
    result: dict[str, dict[str, str]] = {}
    seen: set[str] = set()
    duplicates: set[str] = set()
    for action in value["actions"]:
        if not isinstance(action, dict):
            continue
        kind = action.get("kind")
        if not isinstance(kind, str) or kind not in _CONTEXTS:
            continue
        if kind in seen:
            duplicates.add(kind)
        seen.add(kind)
        if (set(action) != set(_FIELDS) or action.get("context") != _CONTEXTS[kind]
                or any(not isinstance(action.get(key), str)
                       or not action[key] or len(action[key]) > limit
                       for key, limit in (("label", 96), ("icon", 8), ("title", 160)))):
            continue
        result[kind] = dict(action)
    return [result[kind] for kind in _CONTEXTS if kind in result and kind not in duplicates]


def renderer_component_actions(
    component: Mapping[str, Any], profile: Any, *,
    canonical: Mapping[str, Any] | None = None,
) -> list[dict[str, str]]:
    """Render host flags plus an optional restrictive stamped inventory.

    Direct legacy renderer callers lack the new field. A supplied field can
    only remove actions allowed by current host policy, never enable one. Deep
    overwrites it using original canonical facts, including pre-fallback type.
    """
    source = component if canonical is None else canonical
    if source.get("component_id") != component.get("component_id"):
        return []
    actions = build_component_chrome(source, profile)["actions"]
    if "component_chrome" in component:
        kinds = {row["kind"] for row in component_action_descriptors(component["component_chrome"])}
        actions = [row for row in actions if row["kind"] in kinds]
    return actions


def stamp_component_chrome(
    original: Mapping[str, Any] | None, adapted: dict[str, Any], profile: Any, *,
    enabled: Callable[[str], bool] | None = None,
) -> dict[str, Any]:
    """Return an outbound copy; remove spoofed metadata even when identity fails."""
    output = dict(adapted)
    output.pop("component_chrome", None)
    output.pop("versions", None)
    canonical = original if isinstance(original, Mapping) else {}
    cid = canonical.get("component_id")
    if not isinstance(cid, str) or not cid or cid != adapted.get("component_id"):
        canonical = {}
    dtype = getattr(getattr(profile, "device_type", None), "value", "")
    if profile is not None and dtype not in ("watch", "voice"):
        output["component_chrome"] = build_component_chrome(canonical, profile, enabled=enabled)
        versions = component_versions(canonical)
        if versions:
            output["versions"] = versions
    return output


def stamp_canvas_component_chrome(
    originals: list[dict[str, Any]], adapted: list[dict[str, Any]], profile: Any, *,
    enabled: Callable[[str], bool] | None = None,
) -> list[dict[str, Any]]:
    """Match by unambiguous canonical identity, never by adaptation list position."""
    by_id = canonical_components_by_id(originals)
    result = []
    for component in adapted:
        if not isinstance(component, dict):
            result.append(component)
            continue
        cid = component.get("component_id")
        original = by_id.get(cid) if isinstance(cid, str) else None
        result.append(stamp_component_chrome(original, component, profile, enabled=enabled))
    return result


def canonical_components_by_id(
    originals: list[dict[str, Any]],
) -> dict[str, dict[str, Any] | None]:
    """Duplicate IDs have no unambiguous original and cannot acquire actions."""
    by_id: dict[str, dict[str, Any] | None] = {}
    for original in originals:
        if not isinstance(original, dict):
            continue
        cid = original.get("component_id")
        if isinstance(cid, str) and cid:
            by_id[cid] = None if cid in by_id else original
    return by_id
