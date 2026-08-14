"""Host-neutral compatibility contracts for the extracted web chrome."""

from __future__ import annotations

from webrender.chrome.menu_model import build_menu_model
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


def test_topbar_renders_supplied_state_without_host_imports() -> None:
    default = render_topbar(["user"])
    assert "astral-pulse-btn" not in default
    assert "My agents" not in default
    assert "Remote machines" not in default

    enabled = render_topbar(
        ["user"],
        pulse_enabled=True,
        byo_enabled=True,
        remote_enabled=True,
    )
    assert "astral-pulse-btn" in enabled
    assert "My agents" in enabled
    assert "Remote machines" in enabled
