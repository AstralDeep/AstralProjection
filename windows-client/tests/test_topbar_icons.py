"""Tests for astral_client/icons.py and app.py: the top bar's SVG line icons matching
the web vocabulary, rendered at the device pixel ratio, with the text glyph kept only
as a fallback when Qt SVG support is unavailable.
"""

import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("PySide6")
from PySide6.QtWidgets import QApplication, QPushButton  # noqa: E402

from astral_client import icons, theme as T  # noqa: E402


@pytest.fixture(scope="module")
def qapp():
    app = QApplication.instance() or QApplication([])
    yield app


def test_icons_mirror_the_web_vocabulary_and_render(qapp):
    for name in ("chats", "sparkle", "history", "gear", "paperclip"):
        markup = icons.svg_markup(name, "#abcdef")
        assert 'stroke="#abcdef"' in markup and "currentColor" not in markup
        assert 'viewBox="0 0 24 24"' in markup and 'stroke-width="2"' in markup
    assert icons.name_for_action("sparkle") == "sparkle"
    assert icons.name_for_action("pulse") == "sparkle"
    assert icons.name_for_action("history") == "history"
    assert icons.name_for_action("mystery") is None
    btn = QPushButton("✨")
    assert icons.apply(btn, "sparkle", T.MUTED, T.TEXT) is True
    assert btn.text() == "" and not btn.icon().isNull()
    assert btn.iconSize().width() == 18
    other = QPushButton("?")
    assert icons.apply(other, "nope", T.MUTED, T.TEXT) is False and other.text() == "?"


def test_topbar_buttons_are_svg_icons_with_text_only_as_fallback(qapp, monkeypatch):
    from astral_client.app import TopBar

    bar = TopBar("sam", lambda: None, lambda: None, lambda *a: None, lambda: None)
    assert not bar.recent_btn.icon().isNull() and bar.recent_btn.text() == ""
    assert not bar.settings_btn.icon().isNull() and bar.settings_btn.text() == ""
    model = {"sections": [], "signout": {"label": "Sign out", "action": "logout"},
             "topbar": [
                 {"kind": "action", "key": "pulse", "label": "Pulse digest", "icon": "sparkle",
                  "action": {"surface": "pulse"}},
                 {"kind": "action", "key": "timeline", "label": "Workspace timeline", "icon": "history",
                  "action": {"surface": "workspace_timeline"}},
                 {"kind": "action", "key": "odd", "label": "Odd thing", "icon": "mystery",
                  "action": {"surface": "odd"}}]}
    bar.set_menu_model(model)
    pulse, timeline, odd = bar._action_buttons
    assert pulse.text() == "" and not pulse.icon().isNull() and pulse.toolTip() == "Pulse digest"
    assert timeline.text() == "" and not timeline.icon().isNull()
    assert odd.text() == "Odd thing" and odd.icon().isNull()

    monkeypatch.setattr(icons, "icon", lambda *a, **k: None)
    bar.set_menu_model(model)
    pulse = bar._action_buttons[0]
    assert pulse.text() == icons.GLYPH_FALLBACK["sparkle"] and pulse.objectName() == "iconGhost"
    assert bar.recent_btn.text() == icons.GLYPH_FALLBACK["chats"]
