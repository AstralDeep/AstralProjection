"""Defines shared console copy and native chrome placement from host-authorized catalogs.
Deep supplies account-filtered data; shell label rendering and native clients consume this model.
"""

from copy import deepcopy
from html import escape
from typing import Any

CONSOLE_VERSION = 2
CONSOLE_CONTRACT = "console/v2"
LABELS = {
    "brand": "AstralDeep",
    "title": "AstralDeep Console",
    "subtitle": "Multi-agent orchestrator and server-driven UI workspace",
    "start_here": "Start here",
    "history": "History",
    "agent_directory": "Agent Directory",
    "search_agents": "Search agents",
    "dashboard": "Dashboard",
    "dashboard_suffix": " Overview",
    "new_chat": "New Chat",
    "all_categories": "All",
    "example": "Example",
    "run": "Run",
    "load_prompt": "Load prompt",
    "empty_title": "Your results appear here",
    "empty_subtitle": "Ask a question to get started.",
    "message_placeholder": "Ask anything…",
    "attach": "Attach files",
    "more": "More options",
    "send": "Send message",
    "background": "Run in background",
    "advanced": "Advanced settings",
    "fullscreen": "Full Screen",
    "exit_fullscreen": "Exit Full Screen",
    "collapse": "Collapse container",
    "expand": "Expand container",
    "clear_selection": "Clear the selection for this chat",
    "result_title": "{agent} Interface",
    "result_default_agent": "AstralDeep Specialist",
    "result_agent_role": "Active Specialist",
    "result_preview_action": "Click to interact in Full Screen",
    "turn_singular": "turn",
    "turn_plural": "turns",
}


def render_console_labels(shell: str) -> str:
    for key, label in LABELS.items():
        shell = shell.replace(f"%%CONSOLE:{key}%%", escape(label))
    return shell


def _text(row: dict, key: str, maximum: int, *, empty: bool = False) -> str:
    value = row.get(key, "" if empty else None)
    if not isinstance(value, str) or len(value) > maximum or (not empty and not value.strip()):
        raise ValueError(f"invalid console {key}")
    return value


def _rows(catalog: dict, key: str, maximum: int) -> list:
    value = catalog.get(key)
    if not isinstance(value, list) or len(value) > maximum:
        raise ValueError(f"invalid console {key}")
    return value


def _catalog(source: dict) -> dict:
    categories = _rows(source, "categories", 16)
    if any(not isinstance(value, str) or not value.strip() or len(value) > 80 for value in categories):
        raise ValueError("invalid console categories")
    if len(set(categories)) != len(categories):
        raise ValueError("duplicate console category")
    result: dict[str, Any] = {"categories": list(categories), "scenarios": [], "agents": []}
    for kind, maximum in (("scenarios", 64), ("agents", 60)):
        seen = set()
        for row in _rows(source, kind, maximum):
            if not isinstance(row, dict):
                raise ValueError(f"invalid console {kind}")
            identity = _text(row, "id", 200)
            if identity in seen:
                raise ValueError("duplicate console identity")
            seen.add(identity)
            item: dict[str, Any] = {"id": identity, "description": _text(row, "description", 2000, empty=True)}
            if kind == "scenarios":
                item.update(title=_text(row, "title", 200), prompt=_text(row, "prompt", 8000),
                            category=_text(row, "category", 80))
                if item["category"] not in categories:
                    raise ValueError("unknown console category")
            else:
                item.update(name=_text(row, "name", 200), state=row.get("state"),
                            owned=row.get("owned", False))
                if item["state"] not in ("ready", "offline") or not isinstance(item["owned"], bool):
                    raise ValueError("invalid console agent state")
            result[kind].append(item)
    return result


def build_console_model(catalog: dict, menu: dict, identity: dict) -> dict:
    actions = [
        {"key": "background", "kind": "toggle", "label": LABELS["background"], "icon": "clock"},
        {"key": "advanced", "kind": "action", "label": LABELS["advanced"], "icon": "sliders",
         "action": {"surface": "guidance", "params": {"view": "selection"}}},
    ]
    controls = {item["key"]: item for item in menu.get("topbar", [])}
    for key in ("timeline", "pulse", "work"):
        if key in controls:
            actions.append(deepcopy(controls[key]))
    defaults = {"name": "Signed in", "role": "Member", "initials": "A"}
    display = {}
    for key, fallback in defaults.items():
        value = identity.get(key)
        display[key] = value[:120 if key == "name" else 40] if isinstance(value, str) and value.strip() else fallback
    return {
        "version": CONSOLE_VERSION,
        "labels": dict(LABELS),
        "identity": display,
        "catalog": _catalog(catalog),
        "composer_actions": actions,
        "show_voice_availability_banner": False,
    }
