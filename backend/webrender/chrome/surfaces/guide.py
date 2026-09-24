"""Renders the User Guide settings surface, in both web HTML and native SDUI, from
guide_content's static sections; gates the admin-only section server-side and routes
navigation through chrome_open.
"""

import html as _html
import json
import re

from webrender.chrome import esc
# Aliased: a bare SECTIONS name here reads as the dialog's tab strip
from webrender.chrome.guide_content import SECTIONS as GUIDE_SECTIONS

TITLE = "User guide"

_TOC_BASE_CLS = (
    "astral-guide-toc-item w-full text-left px-2 py-1.5 rounded-md text-xs "
    "focus:outline-none focus:bg-white/10"
)
_TOC_ACTIVE_CLS = "bg-astral-primary/15 text-astral-text"
_TOC_IDLE_CLS = "text-astral-muted hover:text-astral-text hover:bg-white/5"


def _visible_sections(roles):
    is_admin = "admin" in (roles or [])
    return [s for s in GUIDE_SECTIONS if not s.get("admin_only") or is_admin]


def _toc_button(section, active: bool) -> str:
    payload = json.dumps({"surface": "guide", "params": {"section": section["slug"]}})
    state_cls = _TOC_ACTIVE_CLS if active else _TOC_IDLE_CLS
    aria = ' aria-current="true"' if active else ""
    title = esc(section["title"])
    return (
        f'<button type="button" class="{_TOC_BASE_CLS} {state_cls}"{aria} '
        f"data-ui-action=\"chrome_open\" data-ui-payload='{esc(payload)}'>{title}</button>"
    )


async def render(orch, user_id, roles, params) -> str:
    sections = _visible_sections(roles)
    requested = str((params or {}).get("section") or "")
    selected = next((s for s in sections if s["slug"] == requested), sections[0])
    toc = "".join(_toc_button(s, s["slug"] == selected["slug"]) for s in sections)
    body = selected["body_html"]
    return (
        '<div class="astral-guide flex flex-col sm:flex-row gap-4 items-start">'
        '<nav class="astral-guide-toc w-full sm:w-44 flex-shrink-0 space-y-0.5 '
        'sm:border-r sm:border-white/5 sm:pr-3" aria-label="User guide sections">'
        f"{toc}</nav>"
        f'<article class="astral-guide-article flex-1 min-w-0">{body}</article>'
        "</div>"
    )


_TAG_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"[ \t]+")


def _html_to_text(body_html: str) -> str:
    s = re.sub(r"(?i)<li[^>]*>", "\n• ", body_html or "")
    s = re.sub(r"(?i)<br\s*/?>", "\n", s)
    s = re.sub(r"(?i)</(p|div|li|h[1-6]|section|article|ul|ol)>", "\n\n", s)
    s = _html.unescape(_TAG_RE.sub("", s))
    lines = [_WS_RE.sub(" ", ln).strip() for ln in s.split("\n")]
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()


async def components(orch, user_id, roles, params):
    from webrender.chrome.surfaces import _sdui
    sections = _visible_sections(roles)
    requested = str((params or {}).get("section") or "")
    selected = next((s for s in sections if s["slug"] == requested), sections[0])
    toc = [
        _sdui.button(
            s["title"], "chrome_open",
            {"surface": "guide", "params": {"section": s["slug"]}},
            variant="primary" if s["slug"] == selected["slug"] else "secondary")
        for s in sections
    ]
    paras = [p for p in _html_to_text(selected["body_html"]).split("\n\n") if p.strip()]
    out = [_sdui.text(selected["title"], "h2")]
    out.extend(_sdui.text(p, "body") for p in (paras or ["…"]))
    out.append(_sdui.text("Sections", "h3"))
    out.append(_sdui.container(toc, direction="column"))
    return out
