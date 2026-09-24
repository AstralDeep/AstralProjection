"""Renders the settings dialog's left rail as navigation over menu_model's shared
ChromeModel, keeping every settings screen one click away via the dialog's
always-visible menu.
"""

import json

from webrender import esc

_ACTIONS_GROUP_LABEL = "Workspace"


def _nav_item(label: str, key: str, payload: dict, active: bool,
              extra_cls: str = "") -> str:
    aria = ' aria-current="true"' if active else ""
    cls = "astral-settings-nav-item" + (f" {extra_cls}" if extra_cls else "")
    return (
        f'<button type="button" class="{cls}"{aria} data-menu-key="{esc(key)}" '
        f'data-tour-target="sidebar.{esc(key)}" data-ui-action="chrome_open" '
        f"data-ui-payload='{esc(json.dumps(payload))}'>{esc(label)}</button>"
    )


def _who_block(identity) -> str:
    if not identity:
        return ""
    name = str(identity.get("name") or "").strip()
    role = str(identity.get("role") or "").strip()
    initials = str(identity.get("initials") or "").strip()
    if not name:
        return ""
    return (
        '<div class="astral-settings-who">'
        f'<span class="astral-settings-who-avatar" aria-hidden="true">{esc(initials)}</span>'
        '<span class="astral-settings-who-id">'
        f'<span class="astral-settings-who-name">{esc(name)}</span>'
        f'<span class="astral-settings-who-role">{esc(role)}</span>'
        "</span></div>"
    )


def render_settings_nav(model, active_surface: str = "", *, identity=None) -> str:
    parts = []
    for group in model.menu:
        parts.append(
            f'<div class="astral-settings-nav-group" role="presentation">'
            f"{esc(group.label)}</div>"
        )
        for item in group.items:
            parts.append(_nav_item(
                item.label, item.key, {"surface": item.surface, "params": item.params},
                item.surface == active_surface))
    if not parts:
        return ""
    signout = model.signout
    parts.append('<div class="astral-settings-nav-spacer" aria-hidden="true"></div>')
    parts.append('<div class="astral-settings-nav-rule" role="presentation"></div>')
    parts.append(
        '<a href="/auth/logout" class="astral-settings-nav-item is-danger" '
        f'data-menu-key="{esc(signout.key)}">{esc(signout.label)}</a>'
    )
    return (
        '<nav class="astral-settings-nav" aria-label="Settings sections">'
        f"{_who_block(identity)}{''.join(parts)}</nav>"
    )
