"""Top bar + static settings menu (server-rendered, role-gated).

The gear opens the settings dialog directly. It used to drop a static
dropdown rendered here at ``GET /``; the menu that dropdown carried is now
the dialog's own left rail (:mod:`webrender.chrome.settings_nav`), which is
built from the same model and is on screen for every settings surface rather
than only while a popover is open. Role gating is unchanged and still
UX-only: the Admin tools group is absent from the rail for a non-admin, and
server-side ``chrome_open`` checks stay authoritative either way.

The model's ``action`` controls (Pulse, Recent work, Workspace timeline) moved
with it. The account row at the sidebar's bottom carries the gear alone, so
those controls render as rail entries; a native client still receives them in
``topbar`` exactly as before, because the MODEL did not change.

Feature 042: the menu structure is NOT defined here — it comes from the single
server-owned :func:`webrender.chrome.menu_model.build_menu_model`, the same
model the native clients consume over ``chrome_menu`` / ``GET /api/chrome/menu``
(Constitution II/XII: one definition, every client renders it). This module is
purely the *web renderer* of that model — it owns the HTML/CSS + web-specific
presentation details (DOM ids, tooltips, tour targets, icon SVGs), not the
inventory.

Menu markup follows the WAI-ARIA menu pattern; the keyboard and open/close
behavior lives in ``webrender/static/client.js``.
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


# "plus" glyph for the New-chat button — the same core affordance the native
# clients hardcode in their top bars (Windows "＋ New", Android's New-chat
# action). Client-local behavior lives in client.js (#astral-newchat-btn).
_PLUS_SVG = (
    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
    'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
    '<path d="M12 5v14M5 12h14"/></svg>'
)

# "speech bubble" glyph for the Recent-chats button — the same affordance
# Android hardcodes in its top bar (RootScaffold ic_chat). Only shown by the
# stylesheet on stacked (compact-width) layouts, where the persistent history
# rail is hidden and recent chats open full-screen instead.
_CHATS_SVG = (
    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
    'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
    '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>'
)


# Page-scoped canvas actions (066): export the whole canvas, share the whole
# canvas. These used to live in a sticky bar pinned above the canvas content,
# which cost a permanent strip of the primary surface for two rarely-used
# controls. They now sit in the top bar and are revealed by client.js only
# while the rendered canvas actually carries the matching workspace flag
# (`data-astral-export` / `data-astral-share`), so an unflagged or empty canvas
# shows nothing at all. The native clients expose the same two actions from the
# component context menu (Windows `component_menu`, Android `ArtifactChrome`) —
# neither ever had a persistent bar.
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
    """Render a model-owned canvas operation using its existing web hooks."""
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
    """The gear — a ``chrome_open`` button, not a popover toggle.

    ``model`` decides only whether a gear is offered at all; where it lands is
    :func:`settings_entry_surface`, the first entry of the rail it opens, so
    the dialog and its rail can never disagree about what "settings" means.
    """
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
    """The surface the gear opens: the first entry the rail will show.

    Falls back to ``"agents"`` only if a model somehow carries no menu groups
    at all — a gear that opens nothing would be worse than one that opens the
    surface every deployment has.
    """
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
    """Inner HTML for ``<header id="astral-topbar">`` — status and controls.

    Targets the web client only, but is rendered FROM the shared
    :func:`build_menu_model` so it can never diverge from what the native
    clients receive. ``roles`` comes from the server session at shell-render
    time. Feature availability is supplied by the authenticated host; this
    renderer never imports host flag or policy implementations.
    """
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

    # One cluster: status + New chat + the page actions + the gear, in model
    # order. It sits inside the sidebar's account row, which now carries the
    # gear and nothing else visible: status is hidden by the stylesheet, New
    # chat and Recent chats are re-homed by client.js into the Recent-work
    # header, the page actions are hidden until a live canvas flags them (and
    # then move into that canvas's card), and the model's action controls
    # render in the dialog's rail.
    # New chat is core client chrome, not a settings surface — every native
    # client hardcodes it in its top bar (Windows TopBar.new_btn, Android
    # RootScaffold onNewChat); this is the web twin of that button.
    # Icon only. The plus beside the History heading says "new chat" on its
    # own, and the word next to it was the second of two adjacent buttons that
    # both read as "start a chat". The name stays for assistive tech.
    new_chat_btn = (
        '<button type="button" id="astral-newchat-btn" data-tour-target="topbar.new-chat" '
        'class="flex items-center justify-center p-1.5 rounded-lg '
        "bg-astral-primary/20 border border-astral-primary/30 text-astral-text "
        'hover:bg-astral-primary/30" aria-label="New chat" title="Start a new chat">'
        f'{_PLUS_SVG}<span class="astral-sr-only">New chat</span></button>'
    )
    # Recent chats — like New chat this is core client chrome the native
    # clients hardcode (Android RootScaffold's speech-bubble button). The
    # stylesheet keeps it hidden except on stacked (compact-width) layouts,
    # where it replaces the always-visible history rail (#astral-chats-btn).
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
            continue  # brand is the left cluster (below)
        if control.kind == "status":
            right_parts.append(
                '<span id="astral-status" class="text-xs text-astral-muted" role="status"></span>'
            )
            right_parts.append(new_chat_btn)
            right_parts.append(recent_chats_btn)
        elif control.kind == "workspace_action":
            # client.js retains its existing live-canvas flag/visibility rule.
            right_parts.append(_workspace_action_button(control))
        elif control.kind == "action":
            # Pulse / Recent work / Workspace timeline render in the settings
            # dialog's rail now (settings_nav), not beside the gear. The model
            # entry is untouched, so native clients are unaffected.
            continue
        elif control.kind == "menu":  # the Settings gear + dropdown
            right_parts.append(_settings_html(model))

    # Feature 089: the brand moved to the sidebar's own #astral-brand block,
    # which is what returns to the landing view. Emitting it here too would
    # put a second logo and a second data-tour-target="topbar.brand" in the
    # DOM, so this renderer now emits only the control cluster.
    return (
        '<div class="astral-chrome-row flex items-center gap-1.5">'
        + "".join(right_parts)
        + "</div>"
    )
