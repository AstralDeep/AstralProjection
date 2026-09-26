"""SVG top-bar icon glyphs for the Windows client, drawn from the same stroked paths as
the web top bar (webrender/chrome/topbar.py) so both clients render identically
instead of via emoji fonts; used by app.py's TopBar.
"""

from __future__ import annotations

from typing import Dict, Optional

_PATHS: Dict[str, str] = {
    "search": '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
    "back": '<path d="M19 12H5m6-6-6 6 6 6"/>',
    "chevron_down": '<path d="m6 9 6 6 6-6"/>',
    "chevron_right": '<path d="m9 6 6 6-6 6"/>',
    "microphone": '<path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"></path><path d="M19 10v2a7 7 0 0 1-14 0v-2"></path><line x1="12" y1="19" x2="12" y2="23"></line><line x1="8" y1="23" x2="16" y2="23"></line>',
    "device-transfer": '<polyline points="23 4 23 10 17 10"></polyline><polyline points="1 20 1 14 7 14"></polyline><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"></path>',
    "stop": '<rect x="6" y="6" width="12" height="12" rx="2"></rect>',
    "speaker-stop": '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"></polygon><line x1="23" y1="9" x2="17" y2="15"></line><line x1="17" y1="9" x2="23" y2="15"></line>',
    "speaker-muted": '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"></polygon><line x1="22" y1="3" x2="3" y2="22"></line>',
    "chat": '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"></path>',
    "speaker-consent": '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"></polygon><path d="M15.54 8.46a5 5 0 0 1 0 7.07"></path><path d="M19.07 4.93a10 10 0 0 1 0 14.14"></path>',
    "menu": '<path d="M4 6h16M4 12h16M4 18h16"/>',
    "more": '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
    "send": '<path d="M12 20V4m-6 6 6-6 6 6"/>',
    "add": '<path d="M12 5v14M5 12h14"/>',
    "collapse": '<path d="M5 12h14"/>',
    "expand": '<path d="M12 5v14M5 12h14"/>',
    "fullscreen": '<path d="M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5"/>',
    "exit_fullscreen": '<path d="M3 8h5V3m8 0v5h5M8 21v-5H3m13 5v-5h5"/>',
    "download": '<path d="M12 3v12m-5-5 5 5 5-5M5 17v4h14v-4"/>',
    "share": '<circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><path d="m8.6 10.5 6.8-4m-6.8 7 6.8 4"/>',
    "chats": '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>',
    "sparkle": (
        '<path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1'
        'M18.4 5.6l-2.1 2.1M7.7 16.3l-2.1 2.1"/><circle cx="12" cy="12" r="3"/>'
    ),
    "history": (
        '<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/>'
        '<path d="M3 3v5h5"/><path d="M12 7v5l4 2"/>'
    ),
    "gear": (
        '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 '
        "0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 "
        "1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 "
        "1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 "
        "1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 "
        "0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 "
        "2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 "
        "0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 "
        '2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/>'
    ),
    "paperclip": (
        '<path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66'
        'l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"/>'
    ),
}

ACTION_ICON_NAMES: Dict[str, str] = {
    "sparkle": "sparkle", "pulse": "sparkle", "activity": "sparkle",
    "history": "history", "clock": "history",
    "gear": "gear",
}

GLYPH_FALLBACK: Dict[str, str] = {
    "chats": "💬", "sparkle": "✦", "history": "🕓", "gear": "⚙", "paperclip": "📎",
}

_CACHE: Dict[tuple, object] = {}


def svg_markup(name: str, color: str, size: int = 18) -> str:
    body = _PATHS[name]
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 24 24" '
        f'fill="none" stroke="{color}" stroke-width="2" stroke-linecap="round" '
        f'stroke-linejoin="round">{body}</svg>'
    )


def _render(name: str, color: str, size: int, ratio: float):
    from PySide6.QtCore import QByteArray, Qt
    from PySide6.QtGui import QPainter, QPixmap
    from PySide6.QtSvg import QSvgRenderer

    renderer = QSvgRenderer(QByteArray(svg_markup(name, color, size).encode("utf-8")))
    if not renderer.isValid():
        return None
    px = int(round(size * ratio))
    pixmap = QPixmap(px, px)
    pixmap.fill(Qt.GlobalColor.transparent)
    painter = QPainter(pixmap)
    try:
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        renderer.render(painter)
    finally:
        painter.end()
    pixmap.setDevicePixelRatio(ratio)
    return pixmap


def icon(name: str, muted: str, text: str, size: int = 18, ratio: float = 2.0):
    if name not in _PATHS:
        return None
    key = (name, muted, text, size, ratio)
    cached = _CACHE.get(key)
    if cached is not None:
        return cached
    try:
        from PySide6.QtGui import QIcon
        normal = _render(name, muted, size, ratio)
        active = _render(name, text, size, ratio)
    except Exception:  # noqa: BLE001
        return None
    if normal is None or active is None:
        return None
    result = QIcon()
    result.addPixmap(normal, QIcon.Mode.Normal)
    result.addPixmap(active, QIcon.Mode.Active)
    result.addPixmap(active, QIcon.Mode.Selected)
    _CACHE[key] = result
    return result


def apply(button, name: str, muted: str, text: str, size: int = 18) -> bool:
    ratio = 2.0
    try:
        screen = button.screen() if hasattr(button, "screen") else None
        if screen is not None:
            ratio = max(1.0, float(screen.devicePixelRatio()))
    except Exception:  # noqa: BLE001
        ratio = 2.0
    result = icon(name, muted, text, size, ratio)
    if result is None:
        return False
    from PySide6.QtCore import QSize
    button.setIcon(result)
    button.setIconSize(QSize(size, size))
    button.setText("")
    return True


def name_for_action(icon_name: Optional[str]) -> Optional[str]:
    return ACTION_ICON_NAMES.get(str(icon_name or ""))
