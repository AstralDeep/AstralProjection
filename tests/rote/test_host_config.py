"""Tests for backend/rote/capabilities.py's per-target host config: env-override
merging/validation, and enforcement of max_actions and supports_interactivity bounds
on rendered output.
"""

from __future__ import annotations

import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from rote import capabilities as cap  # noqa: E402
from rote.adapter import ComponentAdapter  # noqa: E402
from rote.capabilities import DeviceProfile, load_host_config  # noqa: E402


def _btn(label, action="do"):
    return {"type": "button", "label": label, "action": action, "payload": {}}


def test_base_config_has_all_device_types_and_new_fields():
    cfg = load_host_config()
    for dt in ("browser", "tablet", "mobile", "watch", "tv", "voice"):
        assert dt in cfg
        assert "max_actions" in cfg[dt]
        assert "supports_interactivity" in cfg[dt]
    assert cfg["browser"]["supports_interactivity"] is True
    assert cfg["voice"]["supports_interactivity"] is False
    assert cfg["browser"]["max_actions"] == 0


def test_env_override_merges_partial(monkeypatch):
    monkeypatch.setenv("ROTE_HOST_CONFIG", '{"watch": {"max_actions": 2}}')
    cfg = load_host_config()
    assert cfg["watch"]["max_actions"] == 2
    assert cfg["watch"]["supports_charts"] is False
    assert cfg["browser"]["max_actions"] == 0


def test_env_override_ignores_bad_json(monkeypatch):
    monkeypatch.setenv("ROTE_HOST_CONFIG", "{not valid json")
    cfg = load_host_config()
    assert cfg == cap._BASE_HOST_CONFIG


def test_env_override_rejects_unknown_keys_and_types(monkeypatch):
    monkeypatch.setenv(
        "ROTE_HOST_CONFIG",
        '{"watch": {"evil": 1, "max_actions": 3}, "fridge": {"max_actions": 9}}',
    )
    cfg = load_host_config()
    assert "evil" not in cfg["watch"]
    assert cfg["watch"]["max_actions"] == 3
    assert "fridge" not in cfg


def test_profile_reflects_config_and_defaults():
    browser = DeviceProfile.from_dict({"device_type": "browser"})
    assert browser.max_actions == 0 and browser.supports_interactivity is True
    voice = DeviceProfile.from_dict({"device_type": "voice"})
    assert voice.supports_interactivity is False
    assert "max_actions" in browser.to_dict()


def test_env_override_flows_into_profile(monkeypatch):
    monkeypatch.setenv("ROTE_HOST_CONFIG", '{"tv": {"supports_interactivity": false}}')
    tv = DeviceProfile.from_dict({"device_type": "tv"})
    assert tv.supports_interactivity is False


def test_default_browser_keeps_all_actions():
    comps = [_btn("a"), _btn("b"), _btn("c")]
    out = ComponentAdapter.adapt(comps, DeviceProfile.from_dict({"device_type": "browser"}))
    assert sum(1 for c in out if c.get("type") == "button") == 3


def test_max_actions_caps_buttons(monkeypatch):
    monkeypatch.setenv("ROTE_HOST_CONFIG", '{"browser": {"max_actions": 2}}')
    comps = [_btn("a"), _btn("b"), _btn("c"), _btn("d")]
    out = ComponentAdapter.adapt(comps, DeviceProfile.from_dict({"device_type": "browser"}))
    assert sum(1 for c in out if c.get("type") == "button") == 2


def test_max_actions_counts_nested_buttons(monkeypatch):
    monkeypatch.setenv("ROTE_HOST_CONFIG", '{"browser": {"max_actions": 1}}')
    comps = [{"type": "container", "children": [_btn("a"), _btn("b")]}, _btn("c")]
    out = ComponentAdapter.adapt(comps, DeviceProfile.from_dict({"device_type": "browser"}))
    n = 0

    def count(node):
        nonlocal n
        if isinstance(node, dict):
            if node.get("type") == "button":
                n += 1
            for k in ("children", "content"):
                for ch in node.get(k, []) or []:
                    count(ch)
    for c in out:
        count(c)
    assert n == 1


def test_read_only_surface_strips_action_buttons(monkeypatch):
    monkeypatch.setenv("ROTE_HOST_CONFIG", '{"mobile": {"supports_interactivity": false}}')
    comps = [{"type": "text", "content": "hi", "variant": "body"}, _btn("a")]
    out = ComponentAdapter.adapt(comps, DeviceProfile.from_dict({"device_type": "mobile"}))
    assert all(c.get("type") != "button" for c in out)
    assert any(c.get("type") == "text" for c in out)


def test_non_action_buttons_are_not_stripped(monkeypatch):
    monkeypatch.setenv("ROTE_HOST_CONFIG", '{"mobile": {"supports_interactivity": false}}')
    comps = [{"type": "button", "label": "inert"}]
    out = ComponentAdapter.adapt(comps, DeviceProfile.from_dict({"device_type": "mobile"}))
    assert len(out) == 1
