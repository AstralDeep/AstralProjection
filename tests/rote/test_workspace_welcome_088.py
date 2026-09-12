"""Welcome placement survives real capability fallback without losing actions."""
from copy import deepcopy

import pytest

from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile


@pytest.mark.parametrize("identity", [None, "wel_examples"])
@pytest.mark.parametrize("device", ["browser", "android", "ios", "watch"])
def test_welcome_slots_keep_identity_role_and_exact_actions(device, identity):
    """Narrow/watch transformations retain the server's selection and labels."""
    source = {"type": "grid", "data-welcome": "examples", "columns": 3,
              "children": [{"type": "button", "data-welcome": "example",
                            "label": "Research brief", "action": "chat_message",
                            "payload": {"message": "Read the requested public sources"}}]}
    if identity is not None:
        source.update(id=identity, component_id=identity)
    original = deepcopy(source)
    profile = DeviceProfile.from_dict({"device_type": device, "viewport_width": 320})
    result = ComponentAdapter.adapt([source], profile)[0]
    assert result["data-welcome"] == "examples"
    assert result.get("component_id") == identity
    assert result["children"][0] == source["children"][0]
    assert source == original


@pytest.mark.parametrize("role", ["intro", "permission", "examples", "example", "more"])
def test_supported_type_fallback_retains_welcome_role(role):
    """An unsupported native type remains addressable in the same slot."""
    profile = DeviceProfile.default()
    profile.supported_types = frozenset({"text"})
    source = {"type": "hero", "title": "How can I help?",
              "component_id": "wel_hero", "data-welcome": role}
    result = ComponentAdapter.adapt([source], profile)[0]
    assert result["type"] == "text"
    assert result["data-welcome"] == role
    assert result["component_id"] == "wel_hero"
    assert "How can I help?" in result["content"]


@pytest.mark.parametrize("identity,role", [
    ("result_1", "intro"), (False, "intro"), (3, "intro"),
    ("", "intro"), ("wel_hero", "unexpected"), (None, []), (None, None),
])
def test_fallback_does_not_promote_result_or_malformed_hint(identity, role):
    profile = DeviceProfile.default()
    profile.supported_types = frozenset({"text"})
    result = ComponentAdapter.adapt([
        {"type": "hero", "title": "A real result", "component_id": identity,
         "data-welcome": role},
    ], profile)[0]
    assert "data-welcome" not in result
    assert "A real result" in result["content"]


def test_watch_more_examples_keep_group_and_effect_review():
    source = {"type": "collapsible", "title": "More examples", "data-welcome": "more",
              "component_id": "wel_more", "content": [
                  {"type": "button", "label": "Review", "action": "authorize_action",
                   "payload": {"request_id": "opaque-owner-bound-request"}},
              ]}
    profile = DeviceProfile.from_dict({"device_type": "watch"})
    result = ComponentAdapter.adapt([source], profile)[0]
    assert result["data-welcome"] == "more"
    assert result["content"] == source["content"]
    assert result["component_id"] == "wel_more"


@pytest.mark.parametrize("identity", [None, "wel_ex_research"])
def test_watch_keeps_secondary_prompt_shortcut_and_normal_host_denial(identity):
    button = {"type": "button", "variant": "secondary", "label": "Research brief",
              "data-welcome": "example", "component_id": identity,
              "action": "chat_message", "payload": {"message": "Research this topic"}}
    profile = DeviceProfile.from_dict({"device_type": "watch", "supported_types": ["button", "text"]})
    assert ComponentAdapter.adapt([button], profile) == [button]
    profile.supports_interactivity = False
    assert ComponentAdapter.adapt([button], profile) == []


@pytest.mark.parametrize("change", [
    {"component_id": "real_result"}, {"component_id": False},
    {"data-welcome": "intro"}, {"action": "authorize_action"},
    {"payload": None}, {"payload": {"message": " "}},
    {"payload": {"message": 42}},
])
def test_watch_does_not_enable_unrelated_secondary_action(change):
    button = {"type": "button", "variant": "secondary", "label": "Shortcut",
              "data-welcome": "example", "component_id": "wel_ex_research",
              "action": "chat_message", "payload": {"message": "Research this topic"},
              **change}
    profile = DeviceProfile.from_dict({"device_type": "watch", "supported_types": ["button", "text"]})
    assert ComponentAdapter.adapt([button], profile) == []


def test_watch_prompt_shortcuts_still_obey_action_budget():
    button = {"type": "button", "variant": "secondary", "label": "Shortcut",
              "data-welcome": "example", "action": "chat_message",
              "payload": {"message": "Research this topic"}}
    profile = DeviceProfile.from_dict({"device_type": "watch", "supported_types": ["button", "text"]})
    profile.max_actions = 1
    assert ComponentAdapter.adapt([button, button], profile) == [button]
