"""SVG top-bar icon glyphs for the Windows client, drawn from the same stroked paths as
the web top bar (webrender/chrome/topbar.py) so both clients render identically
instead of via emoji fonts; used by app.py's TopBar.
"""

from __future__ import annotations

from typing import Dict, Optional

_PATHS: Dict[str, str] = {
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
