"""Feature 027 — server-rendered application chrome for the web target.

The chrome layer (top bar, settings menu, modal surfaces) is orchestrator
render-layer output for the web client (Constitution II: the orchestrator
renders). It is intentionally NOT expressed as astralprims primitives —
astralprims stays a general-purpose primitive library; app chrome is
web-specific HTML built with the same escape-by-default discipline as
``webrender.renderer`` (every text interpolation goes through ``esc()``).

Chrome HTML never enters the ROTE/astralprims pipeline; canvas/chat content
continues to flow astralprims → ROTE → ``render_for_target`` unchanged.
Surfaces MAY embed rendered primitives via ``render_one`` (e.g. color
pickers in the Theme surface) so client-side side effects stay wired.
"""
from webrender import esc, render_one, safe_url  # noqa: F401  (re-exported for surfaces)

from .topbar import render_topbar  # noqa: F401


def render_modal_shell(title: str, body_html: str, surface: str = "",
                       mandatory: bool = False, *, subtitle: str = "",
                       icon: str = "", sections: tuple = (),
                       footer_html: str = "") -> str:
    """Wrap a surface body in the standard chrome modal (overlay + card).

    ``body_html`` is trusted, already-escaped chrome output from a surface
    renderer; ``title``, ``subtitle``, ``icon`` and ``surface`` are escaped
    here.

    Feature 089 gives the dialog the a8p structure: an icon badge beside the
    title and a subtitle, an optional tab strip, a scrolling body and a footer
    for the surface's own actions. A surface that declares ``sections`` gets
    the tabs; one that does not is unchanged apart from its styling, so every
    existing caller keeps working without passing anything new.

    ``sections`` is a sequence of ``(key, label)`` pairs. The body is expected
    to carry one ``data-section="<key>"`` element per pair; ``client.js``
    shows the selected one. If the body carries no matching element the tab
    simply selects nothing, which is visible rather than broken.

    ``mandatory=True`` (feature 054 first-run gate): the ✕ button is
    omitted, ``data-mandatory="1"`` is stamped on the card so
    ``client.js closeModal()`` refuses every dismissal affordance, and a
    "Sign out" link is included — the one guaranteed escape hatch
    (spec FR-013).
    """
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

    return (
        f'<div class="astral-modal-backdrop astral-modal-overlay" '
        f'data-surface="{esc(surface)}">'
        f'<div class="astral-modal-card"{mandatory_attr} role="dialog" aria-modal="true" '
        f'aria-label="{esc(title)}" tabindex="-1">'
        f'<div class="astral-modal-header">'
        f'<span class="astral-modal-icon" aria-hidden="true">{glyph}</span>'
        f'<div class="astral-modal-heading">'
        f'<h2 class="astral-modal-title">{esc(title)}</h2>{subtitle_html}</div>'
        f"{close_btn}</div>"
        f"{tabs_html}"
        f'<div class="astral-modal-body">{body_html}</div>'
        f"{footer}"
        f"</div></div>"
    )



def chrome_error_block(message: str, retry_surface: str = "") -> str:
    """In-modal error notice (never a silent drop — contract failure section)."""
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
    """Inline success/error/info notice rendered at the top of a surface."""
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
