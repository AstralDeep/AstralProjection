"""The settings dialog's left rail — the menu model, rendered as navigation.

Before this, the gear dropped a dropdown and each entry opened a modal on its
own. The dropdown is gone: the gear opens the dialog directly and this rail is
the menu, always visible down the dialog's left side, so moving between
settings screens is one click instead of close-reopen-pick.

Nothing about *what* is on offer changed. The inventory is still the single
server-owned :func:`webrender.chrome.menu_model.build_menu_model` that every
client consumes (Constitution II/XII); this module is purely the web renderer
of that model in its new position, exactly as :mod:`webrender.chrome.topbar`
is the web renderer of it in the account row. Entries keep their
``chrome_open`` action, their ``data-menu-key`` and their
``data-tour-target="sidebar.<key>"`` anchors, so the tour and the existing
click delegation need no new vocabulary.

Top-bar ``action`` controls (Pulse, Recent work, Workspace timeline) render
here too. They used to be icon buttons beside the gear; the account row now
carries the gear alone, so the rail is where they live. Their model entry is
untouched — a native client still receives them in ``topbar``.
"""

import json

from webrender import esc

#: Where the top-bar action controls sit in the rail, as one leading group.
_ACTIONS_GROUP_LABEL = "Workspace"


def _nav_item(label: str, key: str, payload: dict, active: bool,
              extra_cls: str = "") -> str:
    """One rail entry — a ``chrome_open`` button that re-opens this dialog."""
    aria = ' aria-current="true"' if active else ""
    cls = "astral-settings-nav-item" + (f" {extra_cls}" if extra_cls else "")
    return (
        f'<button type="button" class="{cls}"{aria} data-menu-key="{esc(key)}" '
        f'data-tour-target="sidebar.{esc(key)}" data-ui-action="chrome_open" '
        f"data-ui-payload='{esc(json.dumps(payload))}'>{esc(label)}</button>"
    )


def _who_block(identity) -> str:
    """The account this dialog belongs to.

    The sidebar used to print the name and role next to the avatar; the
    account row is the gear alone now, so the identity is shown here instead
    of being dropped. Display only — it carries no id or address, and nothing
    is authorized by what it says.
    """
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
    """The rail for ``model``, with ``active_surface``'s entry marked current.

    Args:
        model: a :class:`webrender.chrome.menu_model.ChromeModel`.
        active_surface: the surface key the dialog is currently showing; its
            entry gets ``aria-current`` so the rail says where you are.
        identity: optional ``{"name", "role", "initials"}`` for the account
            block above the entries.

    Returns:
        Rail HTML, or ``""`` when the model offers nothing to navigate to —
        an empty rail would be a column of nothing, so the dialog renders
        without one instead.
    """
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
    # Sign out is a plain link so it still works with no JS behind it, and it
    # is pinned to the rail's bottom the way it was pinned to the dropdown's.
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
