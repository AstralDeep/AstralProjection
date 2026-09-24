"""Accessibility render helpers: landmark_role/landmark_label wrap each top-level canvas
component as a labelled ARIA landmark in render_component_fragment, and a11y_audit is
a pure WCAG-issue scanner usable as a CI gate.
"""

from __future__ import annotations

import os
from typing import Any, Dict, List, Optional

_LANDMARK_ROLES = {
    "card": "region", "container": "region", "collapsible": "region",
    "tabs": "region", "hero": "region", "timeline": "region", "list": "region",
    "table": "region", "grid": "group", "keyvalue": "group", "metric": "group",
    "alert": "status",
}


def a11y_enabled() -> bool:
    return os.getenv("FF_A11Y", "true").strip().lower() not in ("0", "false", "no", "off")


def landmark_role(component: Dict[str, Any]) -> Optional[str]:
    if not isinstance(component, dict):
        return None
    return _LANDMARK_ROLES.get(str(component.get("type", "")).strip().lower())


# Caller must HTML-escape this; it is not escaped here
def landmark_label(component: Dict[str, Any]) -> str:
    if not isinstance(component, dict):
        return "section"
    title = component.get("title")
    if isinstance(title, str) and title.strip():
        return title.strip()
    t = str(component.get("type", "")).strip().lower()
    if t == "metric":
        val = component.get("value")
        return f"metric: {val}" if val not in (None, "") else "metric"
    if t == "alert":
        return f"{component.get('variant', 'info')} alert"
    if t == "hero":
        sub = component.get("subtitle")
        if isinstance(sub, str) and sub.strip():
            return sub.strip()
    return (t.replace("_", " ") or "section")


def _label_present(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def a11y_audit(components: List[Dict[str, Any]]) -> List[Dict[str, str]]:
    issues: List[Dict[str, str]] = []

    def walk(c: Any) -> None:
        if not isinstance(c, dict):
            return
        t = str(c.get("type", "")).strip().lower()
        if t == "image" and not _label_present(c.get("alt")):
            issues.append({"type": "image", "issue": "image is missing alt text"})
        if t == "button" and not (_label_present(c.get("label"))
                                  or _label_present(c.get("aria_label"))):
            issues.append({"type": "button", "issue": "action has no accessible label"})
        if t in ("card", "collapsible", "tabs", "table") and not _label_present(c.get("title")):
            issues.append({"type": t, "issue": "landmark has no label (title)"})
        if t == "text" and str(c.get("variant", "")).lower() in ("h1", "h2", "h3") \
                and not _label_present(c.get("content")):
            issues.append({"type": "text", "issue": "empty heading"})
        for key in ("content", "children"):
            kids = c.get(key)
            if isinstance(kids, list):
                for ch in kids:
                    walk(ch)
        tabs = c.get("tabs")
        if isinstance(tabs, list):
            for tab in tabs:
                if isinstance(tab, dict):
                    if not _label_present(tab.get("label")):
                        issues.append({"type": "tab", "issue": "tab has no label"})
                    for ch in (tab.get("content") or []):
                        walk(ch)

    for c in (components or []):
        walk(c)
    return issues
