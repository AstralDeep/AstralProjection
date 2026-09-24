"""Tests for astral_client/app.py's top bar: cross-client widget order (brand, New,
Recent, server-model actions, Settings), icon-only controls with accessible names,
and that every server action icon name maps to a glyph.
"""

from __future__ import annotations

import pytest

pytest.importorskip("PySide6")


def _bar(qapp):
    from astral_client.app import TopBar

    return TopBar("u", lambda: None, lambda: None, lambda s, ln: None, lambda: None)


def _order(tb):
    lay = tb.layout()
    out = []
    for i in range(lay.count()):
        item = lay.itemAt(i)
        w = item.widget()
        out.append(w if w is not None else "stretch")
    return out


def test_topbar_widget_order_matches_the_shared_model(qapp):
    tb = _bar(qapp)
    order = _order(tb)

    assert order[0] is tb._mark
    assert order[1] is tb.brand_label
    assert order[2] == "stretch"
    assert order[3:] == [tb.new_btn, tb.recent_btn, tb._actions_holder, tb.settings_btn]


def test_server_model_actions_sit_between_recent_and_settings(qapp):
    tb = _bar(qapp)
    order = _order(tb)

    assert order.index(tb._actions_holder) > order.index(tb.recent_btn)
    assert order.index(tb._actions_holder) > order.index(tb.new_btn)
    assert order.index(tb._actions_holder) < order.index(tb.settings_btn)


def test_recent_chats_does_not_use_the_clock_glyph(qapp):
    tb = _bar(qapp)
    assert "🕓" not in tb.recent_btn.text()
    assert tb.recent_btn.accessibleName() == "Recent chats"
    assert tb.recent_btn.toolTip() == "Recent chats"


def test_topbar_controls_are_icon_only_with_names(qapp):
    tb = _bar(qapp)
    tb._rebuild_topbar_actions(
        [{"surface": "workspace_timeline", "label": "Workspace timeline",
          "icon": "clock"}]
    )

    for btn, name in (
        (tb.recent_btn, "Recent chats"),
        (tb.settings_btn, "Settings"),
        (tb._action_buttons[0], "Workspace timeline"),
    ):
        assert len(btn.text()) <= 2, f"{name} still renders a text label"
        assert btn.accessibleName() == name
        assert btn.toolTip() == name

    assert "New" in tb.new_btn.text()


def test_every_server_action_icon_name_has_a_glyph(qapp):
    from astral_client.app import TopBar

    for name in ("sparkle", "history", "gear"):
        assert TopBar._ACTION_ICONS.get(name), f"no Windows glyph for icon {name!r}"
