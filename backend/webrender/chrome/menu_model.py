"""Single source of truth for the top bar and settings menu: builds the role-filtered,
flag-resolved ChromeModel that every client (web topbar, native REST/WS) serializes
and renders identically.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

# Bump only on wire-shape change; clients ignore unknown fields
MODEL_VERSION = 2


@dataclass(frozen=True)
class SurfaceRef:
    surface: str
    params: Dict = field(default_factory=dict)

    def to_dict(self) -> Dict:
        return {"surface": self.surface, "params": dict(self.params)}


@dataclass(frozen=True)
class TopBarControl:
    key: str
    kind: str
    label: Optional[str] = None
    icon: Optional[str] = None
    action: Optional[SurfaceRef] = None
    operation: Optional[str] = None
    context: Optional[str] = None

    def __post_init__(self):
        if self.kind == "workspace_action":
            if (self.operation not in ("export_canvas", "share_canvas")
                    or self.context != "live_canvas" or self.action is not None
                    or not all(isinstance(value, str) and value.strip()
                               for value in (self.key, self.label, self.icon))):
                raise ValueError("invalid workspace action descriptor")
        elif self.operation is not None or self.context is not None:
            raise ValueError("workspace fields require workspace_action kind")

    def to_dict(self) -> Dict:
        d: Dict = {"key": self.key, "kind": self.kind}
        if self.label is not None:
            d["label"] = self.label
        if self.icon is not None:
            d["icon"] = self.icon
        if self.action is not None:
            d["action"] = self.action.to_dict()
        if self.operation is not None:
            d["operation"] = self.operation
            d["context"] = self.context
        return d


@dataclass(frozen=True)
class MenuItem:
    key: str
    label: str
    surface: str
    params: Dict = field(default_factory=dict)
    admin_only: bool = False

    def to_dict(self) -> Dict:
        return {
            "key": self.key,
            "label": self.label,
            "surface": self.surface,
            "params": dict(self.params),
            "admin_only": self.admin_only,
        }


@dataclass(frozen=True)
class MenuGroup:
    key: str
    label: str
    items: Tuple[MenuItem, ...]
    admin_only: bool = False

    def to_dict(self) -> Dict:
        return {
            "key": self.key,
            "label": self.label,
            "admin_only": self.admin_only,
            "items": [i.to_dict() for i in self.items],
        }


@dataclass(frozen=True)
class SignOutItem:
    key: str = "signout"
    label: str = "Sign out"
    style: str = "danger"
    action: str = "logout"

    def to_dict(self) -> Dict:
        return {"key": self.key, "label": self.label, "style": self.style, "action": self.action}


@dataclass(frozen=True)
class ChromeModel:
    topbar: Tuple[TopBarControl, ...]
    menu: Tuple[MenuGroup, ...]
    signout: SignOutItem
    version: int = MODEL_VERSION

    def to_dict(self) -> Dict:
        return {
            "version": self.version,
            "topbar": [c.to_dict() for c in self.topbar],
            "menu": [g.to_dict() for g in self.menu],
            "signout": self.signout.to_dict(),
        }


_ACCOUNT_ITEMS: Tuple[MenuItem, ...] = (
    MenuItem("agents", "Agents & permissions", "agents"),
    MenuItem("llm", "LLM settings", "llm"),
    MenuItem("personalization", "Personalization", "personalization"),
    MenuItem("audit", "Audit log", "audit"),
    MenuItem("theme", "Theme", "theme"),
)
_BYO_AGENTS_ITEM = MenuItem("my-agents", "My agents & skills", "agent_authoring")
_SKILLS_ONLY_ITEM = MenuItem("my-agents", "My skills", "agent_authoring")
_NOTES_ITEM = MenuItem("guidance", "Private notes", "guidance", {"mode": "list"})
_CONNECTIONS_ITEM = MenuItem("connections", "Connections", "connections")
_REMOTE_MACHINES_ITEM = MenuItem("remote-machines", "Remote machines", "remote_machines")
_MY_COMPUTERS_ITEM = MenuItem("my-computers", "My computers", "my_computers")
_HELP_ITEMS: Tuple[MenuItem, ...] = (
    MenuItem("tour", "Take the tour", "tour"),
    MenuItem("guide", "User guide", "guide"),
)
_ADMIN_ITEMS: Tuple[MenuItem, ...] = (
    MenuItem("tool-quality", "Tool quality", "admin_tools", {"tab": "quality"}, admin_only=True),
    MenuItem(
        "tutorial-admin", "Tutorial admin", "admin_tools", {"tab": "tutorial"}, admin_only=True
    ),
    MenuItem("system-llm", "System LLM", "llm_system", admin_only=True),
)


def build_menu_model(
    roles: Optional[List[str]] = None,
    *,
    pulse_enabled: bool = False,
    byo_enabled: bool = False,
    remote_enabled: bool = False,
    computer_enabled: bool = False,
    skills_enabled: bool = False,
    export_enabled: bool = False,
    share_enabled: bool = False,
    work_enabled: bool = False,
    notes_enabled: bool = False,
    connections_enabled: bool = False,
    include_admin: bool = True,
    include_tour: bool = True,
) -> ChromeModel:
    roles = roles or []
    is_admin = "admin" in roles and include_admin
    show_pulse = bool(pulse_enabled)
    show_byo = bool(byo_enabled)
    show_remote = bool(remote_enabled)
    show_computer = bool(computer_enabled)
    show_skills = bool(skills_enabled)

    topbar: List[TopBarControl] = [
        TopBarControl("brand", "brand"),
        TopBarControl("status", "status"),
    ]
    if export_enabled:
        topbar.append(TopBarControl(
            "export", "workspace_action", label="Export page", icon="download",
            operation="export_canvas", context="live_canvas"))
    if share_enabled:
        topbar.append(TopBarControl(
            "share", "workspace_action", label="Share page", icon="share",
            operation="share_canvas", context="live_canvas"))
    if show_pulse:
        topbar.append(
            TopBarControl(
                "pulse", "action", label="Pulse digest", icon="sparkle", action=SurfaceRef("pulse")
            )
        )
    if work_enabled:
        topbar.append(TopBarControl(
            "work", "action", label="Recent work", icon="briefcase",
            action=SurfaceRef("work", {"mode": "list"})))
    topbar.append(
        TopBarControl(
            "timeline",
            "action",
            label="Workspace timeline",
            icon="history",
            action=SurfaceRef("workspace_timeline"),
        )
    )
    topbar.append(TopBarControl("settings", "menu", label="Settings", icon="gear"))

    help_items = (
        _HELP_ITEMS if include_tour else tuple(i for i in _HELP_ITEMS if i.surface != "tour")
    )
    account_items = (
        _ACCOUNT_ITEMS
        + ((_NOTES_ITEM,) if notes_enabled else ())
        + ((_BYO_AGENTS_ITEM,) if show_byo else ((_SKILLS_ONLY_ITEM,) if show_skills else ()))
        + ((_REMOTE_MACHINES_ITEM,) if show_remote else ())
        + ((_MY_COMPUTERS_ITEM,) if show_computer else ())
        + ((_CONNECTIONS_ITEM,) if connections_enabled else ())
    )
    groups: List[MenuGroup] = [
        MenuGroup("account", "Account", account_items),
        MenuGroup("help", "Help", help_items),
    ]
    if is_admin:
        groups.append(MenuGroup("admin", "Admin tools", _ADMIN_ITEMS, admin_only=True))

    return ChromeModel(topbar=tuple(topbar), menu=tuple(groups), signout=SignOutItem())


def menu_model_dict(
    roles: Optional[List[str]] = None,
    *,
    pulse_enabled: bool = False,
    byo_enabled: bool = False,
    remote_enabled: bool = False,
    computer_enabled: bool = False,
    skills_enabled: bool = False,
    export_enabled: bool = False,
    share_enabled: bool = False,
    work_enabled: bool = False,
    notes_enabled: bool = False,
    connections_enabled: bool = False,
    include_admin: bool = True,
    include_tour: bool = True,
) -> Dict:
    return build_menu_model(
        roles,
        pulse_enabled=pulse_enabled,
        byo_enabled=byo_enabled,
        remote_enabled=remote_enabled,
        computer_enabled=computer_enabled,
        skills_enabled=skills_enabled,
        export_enabled=export_enabled,
        share_enabled=share_enabled,
        work_enabled=work_enabled,
        notes_enabled=notes_enabled,
        connections_enabled=connections_enabled,
        include_admin=include_admin,
        include_tour=include_tour,
    ).to_dict()


def project_watch_menu_model(model: Dict, *, profile=None, client_capabilities=()) -> Dict:
    from copy import deepcopy
    from rote.console import CONSOLE_CONTRACT, watch_availability

    if (getattr(getattr(profile, "device_type", None), "value", None) == "watch"
            and getattr(profile, "console_contract", None) == CONSOLE_CONTRACT):
        result = deepcopy(model)
        for control in result["topbar"]:
            action = control.get("action")
            if isinstance(action, dict):
                control["availability"] = watch_availability(
                    action.get("surface"), action.get("params"), profile, client_capabilities)
        for group in result["menu"]:
            for item in group["items"]:
                item["availability"] = watch_availability(
                    item.get("surface"), item.get("params"), profile, client_capabilities)
        return result

    canonical = next(control.to_dict() for control in build_menu_model(
        work_enabled=True).topbar if control.key == "work")
    controls = model.get("topbar", []) if isinstance(model, dict) else []
    if not isinstance(controls, list):
        controls = []
    selected = [control for control in controls if control == canonical]
    selected = selected if len(selected) == 1 else []
    groups = model.get("menu", []) if isinstance(model, dict) else []
    notes = [item for group in groups if isinstance(group, dict) and group.get("key") == "account"
             for item in (group.get("items") if isinstance(group.get("items"), list) else [])
             if item == _NOTES_ITEM.to_dict()] if isinstance(groups, list) else []
    if len(notes) == 1:
        selected.append(TopBarControl(
            _NOTES_ITEM.key, "action", label=_NOTES_ITEM.label,
            action=SurfaceRef(_NOTES_ITEM.surface, dict(_NOTES_ITEM.params)),
        ).to_dict())
    return {
        "version": MODEL_VERSION,
        "topbar": deepcopy(selected),
        "menu": [],
        "signout": {},
    }
