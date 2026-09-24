"""Renders the chrome shell (modal wrapper, error/notice blocks) from settings_nav and
topbar for orchestrator/chrome_events.py and the projection surfaces; stays outside
the astralprims/ROTE primitive pipeline.
"""

from webrender import esc, render_one, safe_url  # noqa: F401

from .settings_nav import render_settings_nav  # noqa: F401
from .topbar import render_topbar  # noqa: F401


def render_modal_shell(title: str, body_html: str, surface: str = "",
                       mandatory: bool = False, *, subtitle: str = "",
                       icon: str = "", sections: tuple = (),
                       footer_html: str = "", nav_html: str = "") -> str:
    if mandatory:
        close_btn = (
            '<a href="/auth/logout" class="astral-modal-signout text-xs text-astral-muted '
            'hover:text-astral-text underline underline-offset-2">Sign out</a>'
        )
        mandatory_attr = ' data-mandatory="1"'
    else:
        close_btn = (
            '<button type="button" class="astral-modal-close" aria-label="Close">'
            '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
            'stroke-width="2" aria-hidden="true"><path d="M18 6L6 18M6 6l12 12"/></svg></button>'
        )
        mandatory_attr = ""

    glyph = esc(icon) if icon else "\u2726"
    subtitle_html = (
        f'<div class="astral-modal-subtitle">{esc(subtitle)}</div>' if subtitle else
        '<div class="astral-modal-subtitle"></div>'
    )

    tabs_html = ""
    if sections:
        buttons = []
        for index, entry in enumerate(sections):
            key, label = (entry if isinstance(entry, (tuple, list)) and len(entry) == 2
                          else (entry, entry))
            active = " active" if index == 0 else ""
            selected = "true" if index == 0 else "false"
            buttons.append(
                f'<button type="button" class="astral-modal-tab{active}" role="tab" '
                f'aria-selected="{selected}" data-section-target="{esc(str(key))}">'
                f"{esc(str(label))}</button>"
            )
        tabs_html = (
            '<div class="astral-modal-tabs" role="tablist" aria-label="Sections">'
            + "".join(buttons) + "</div>"
        )

    footer = (
        f'<div class="astral-modal-footer">{footer_html}</div>' if footer_html else ""
    )

    body = f'<div class="astral-modal-body">{body_html}</div>'
    card_cls = "astral-modal-card"
    pane_tabs = ""
    if nav_html:
        card_cls += " has-nav"
        pane_tabs, tabs_html = tabs_html, ""
        body = (f'<div class="astral-modal-split">{nav_html}'
                f'<div class="astral-modal-pane">{pane_tabs}{body}</div></div>')

    return (
        f'<div class="astral-modal-backdrop astral-modal-overlay" '
        f'data-surface="{esc(surface)}">'
        f'<div class="{card_cls}"{mandatory_attr} role="dialog" aria-modal="true" '
        f'aria-label="{esc(title)}" tabindex="-1">'
        f'<div class="astral-modal-header">'
        f'<span class="astral-modal-icon" aria-hidden="true">{glyph}</span>'
        f'<div class="astral-modal-heading">'
        f'<h2 class="astral-modal-title">{esc(title)}</h2>{subtitle_html}</div>'
        f"{close_btn}</div>"
        f"{tabs_html}"
        f"{body}"
        f"{footer}"
        f"</div></div>"
    )



def chrome_error_block(message: str, retry_surface: str = "") -> str:
    retry = ""
    if retry_surface:
        retry = (
            f'<button type="button" class="mt-2 px-3 py-1.5 rounded-lg text-xs font-medium '
            f'bg-astral-primary/20 text-astral-primary border border-astral-primary/30" '
            f'data-ui-action="chrome_open" '
            f"data-ui-payload='{{\"surface\": \"{esc(retry_surface)}\"}}'>Retry</button>"
        )
    return (
        f'<div class="astral-chrome-error border border-red-500/20 bg-red-500/10 rounded-lg p-3">'
        f'<div class="text-sm text-red-400">{esc(message)}</div>{retry}</div>'
    )


def notice_block(kind: str, message: str) -> str:
    styles = {
        "success": "border-green-500/20 bg-green-500/10 text-green-400",
        "error": "border-red-500/20 bg-red-500/10 text-red-400",
        "info": "border-astral-primary/20 bg-astral-primary/10 text-astral-primary",
    }
    cls = styles.get(kind, styles["info"])
    return (
        f'<div class="astral-chrome-notice border rounded-lg p-3 text-sm {cls}" role="status">'
        f"{esc(message)}</div>"
    )
