"""Renders the web top bar's status and action controls from menu_model's shared
ChromeModel; the settings gear opens the dialog directly via chrome_open.
"""

import json

from webrender import esc
from webrender.chrome.menu_model import build_menu_model

_GEAR_SVG = (
    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
    'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
    '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 '
    "0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 "
    "1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 "
    "1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 "
    "1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 "
    "0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 "
    "2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 "
    "0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 "
    '2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>'
)


_PLUS_SVG = (
    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
    'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
    '<path d="M12 5v14M5 12h14"/></svg>'
)

_CHATS_SVG = (
    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
    'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
    '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>'
)


_EXPORT_SVG = (
    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
    'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
    '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>'
    '<polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>'
)
_SHARE_SVG = (
    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
    'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
    '<circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/>'
    '<line x1="8.59" y1="13.51" x2="15.42" y2="17.49"/>'
    '<line x1="15.41" y1="6.51" x2="8.59" y2="10.49"/></svg>'
)


def _workspace_action_button(control) -> str:
    hook, title, svg, extra = {
        "export_canvas": ("astral-export-canvas", "Export page — download this canvas as HTML",
                          _EXPORT_SVG, ""),
        "share_canvas": ("astral-share-btn", "Share page — create a link to this canvas",
                         _SHARE_SVG, ' data-share-scope="canvas"'),
    }[control.operation]
    return (
        f'<button type="button" id="astral-{esc(control.key)}-page-btn" hidden{extra} '
        f'class="{hook} astral-page-action items-center justify-center '
        'p-1.5 rounded-lg text-astral-muted hover:text-astral-text hover:bg-white/5" '
        f'aria-label="{esc(control.label)}" title="{title}">{svg}</button>'
    )

def _settings_html(model) -> str:
    payload = json.dumps({"surface": settings_entry_surface(model)})
    return (
        '<button type="button" id="astral-settings-btn" data-tour-target="topbar.settings" '
        'class="flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-sm text-astral-muted '
        'hover:text-astral-text hover:bg-white/5" aria-haspopup="dialog" '
        'aria-label="Settings" title="Settings" data-ui-action="chrome_open" '
        f"data-ui-payload='{esc(payload)}'>{_GEAR_SVG}"
        '<span class="hidden sm:inline">Settings</span></button>'
    )


def settings_entry_surface(model) -> str:
    for group in model.menu:
        for item in group.items:
            return item.surface
    return "agents"


def render_topbar(
    roles=None,
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
) -> str:
    model = build_menu_model(
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
    )

    new_chat_btn = (
        '<button type="button" id="astral-newchat-btn" data-tour-target="topbar.new-chat" '
        'class="flex items-center justify-center p-1.5 rounded-lg '
        "bg-astral-primary/20 border border-astral-primary/30 text-astral-text "
        'hover:bg-astral-primary/30" aria-label="New chat" title="Start a new chat">'
        f'{_PLUS_SVG}<span class="astral-sr-only">New chat</span></button>'
    )
    recent_chats_btn = (
        '<button type="button" id="astral-chats-btn" data-tour-target="topbar.chats" '
        'class="astral-chats-btn items-center justify-center p-1.5 rounded-lg '
        'text-astral-muted hover:text-astral-text hover:bg-white/5" '
        'aria-label="Recent chats" title="Recent chats" aria-expanded="false">'
        f"{_CHATS_SVG}</button>"
    )
    right_parts = []
    for control in model.topbar:
        if control.kind == "brand":
            continue
        if control.kind == "status":
            right_parts.append(
                '<span id="astral-status" class="text-xs text-astral-muted" role="status"></span>'
            )
            right_parts.append(new_chat_btn)
            right_parts.append(recent_chats_btn)
        elif control.kind == "workspace_action":
            right_parts.append(_workspace_action_button(control))
        elif control.kind == "action":
            continue
        elif control.kind == "menu":
            right_parts.append(_settings_html(model))

    return (
        '<div class="astral-chrome-row flex items-center gap-1.5">'
        + "".join(right_parts)
        + "</div>"
    )
