"""Decides whether a server-pushed chrome_render frame needs a native-client notice
(only for a non-empty modal region); app.py calls this since the desktop reimplements
chrome as Qt dialogs instead of rendering the pushed HTML.
"""

from __future__ import annotations

from typing import Optional


def chrome_render_notice(frame: dict) -> Optional[str]:
    if (frame.get("region") or "modal") != "modal":
        return None
    if not str(frame.get("html") or "").strip():
        return None
    return "This settings panel isn't available in the desktop app yet"
