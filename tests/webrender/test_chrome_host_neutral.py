"""Tests confirming backend/webrender/chrome/menu_model.py, settings_nav.py, and
topbar.py render purely from caller-supplied host state, with no host-flag module of
their own.
"""

from __future__ import annotations

import pytest

from webrender.chrome.menu_model import build_menu_model
from webrender.chrome.settings_nav import render_settings_nav
from webrender.chrome.topbar import render_topbar


def _menu_keys(model) -> set[str]:
    return {item.key for group in model.menu for item in group.items}


def _topbar_keys(model) -> list[str]:
    return [control.key for control in model.topbar]


def test_menu_model_uses_only_explicit_host_feature_state() -> None:
    default = build_menu_model(["admin"])
    assert "pulse" not in _topbar_keys(default)
    assert "my-agents" not in _menu_keys(default)
    assert "remote-machines" not in _menu_keys(default)

    enabled = build_menu_model(
        ["admin"],
        pulse_enabled=True,
        byo_enabled=True,
        remote_enabled=True,
    )
    assert "pulse" in _topbar_keys(enabled)
    assert {"my-agents", "remote-machines"} <= _menu_keys(enabled)


def test_chrome_renders_supplied_state_without_host_imports() -> None:
    options = {"pulse_enabled": True, "byo_enabled": True, "remote_enabled": True}
    default_nav = render_settings_nav(build_menu_model(["user"]))
    assert "Pulse digest" not in default_nav
    assert "My agents" not in default_nav
    assert "Remote machines" not in default_nav

    enabled_nav = render_settings_nav(build_menu_model(["user"], **options))
    assert "Pulse digest" not in enabled_nav
    assert "My agents" in enabled_nav
    assert "Remote machines" in enabled_nav

    for html in (render_topbar(["user"]), render_topbar(["user"], **options)):
        assert "astral-pulse-btn" not in html
        assert "My agents" not in html
        assert "Remote machines" not in html


@pytest.mark.parametrize("enabled", [False, True])
def test_topbar_preserves_host_connections_availability_and_settings(monkeypatch, enabled):
    import webrender.chrome.topbar as topbar

    observed = []

    def build(roles, **options):
        model = build_menu_model(roles, **options)
        observed.append(model)
        return model

    monkeypatch.setattr(topbar, "build_menu_model", build)
    html = topbar.render_topbar(["user"], pulse_enabled=False, byo_enabled=False,
        remote_enabled=False, computer_enabled=False, skills_enabled=False,
        export_enabled=False, share_enabled=False, work_enabled=False,
        notes_enabled=False, connections_enabled=enabled)
    model, = observed
    assert ("connections" in _menu_keys(model)) is enabled
    assert 'id="astral-settings-btn"' in html and 'aria-label="Settings"' in html
    assert 'data-ui-action="chrome_open"' in html
    assert render_topbar(["user"]) == topbar.render_topbar(["user"], connections_enabled=False)
