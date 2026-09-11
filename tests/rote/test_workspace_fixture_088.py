"""Cross-client fixture preserves all server welcome content and prompt payloads."""
import json
from pathlib import Path

import pytest

from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = json.loads((ROOT / "contracts/ui_protocol.json").read_text())
CONTRACT = MANIFEST["presentation_contracts"]["workspace_088"]
FIXTURE = json.loads((ROOT / CONTRACT["fixture"]).read_text())


def _buttons(components):
    for component in components:
        if component.get("type") == "button":
            yield component
        yield from _buttons(component.get("children", []))
        yield from _buttons(component.get("content", []) if isinstance(component.get("content"), list) else [])


@pytest.mark.parametrize("device", ["browser", "android", "ios", "macos", "watch"])
def test_actual_welcome_fixture_survives_native_adaptation(device):
    profile = DeviceProfile.from_dict({"device_type": device, "viewport_width": 320})
    if device == "watch":
        profile.supported_types = frozenset({"text", "button", "card", "container"})
    adapted = ComponentAdapter.adapt(FIXTURE["components"], profile)
    assert [c[CONTRACT["welcome_attribute"]] for c in adapted] == FIXTURE["expected_roles"]
    original_prompts = [c for c in _buttons(FIXTURE["components"]) if c.get("action") == "chat_message"]
    adapted_prompts = [c for c in _buttons(adapted) if c.get("action") == "chat_message"]
    assert len(adapted_prompts) == 6
    assert adapted_prompts == original_prompts


def test_fixture_has_reviewable_permission_and_no_invented_authority():
    permissions = [c for c in FIXTURE["components"] if c.get("data-welcome") == "permission"]
    assert len(permissions) == 1
    actions = list(_buttons(permissions))
    assert [c["action"] for c in actions] == ["enable_recommended_agents", "chrome_open"]
    assert actions[0]["payload"] == {"source": "welcome"}
    assert actions[1]["payload"] == {"surface": "agents"}


def test_fixture_contains_identified_and_nested_result_counterexamples():
    assert FIXTURE["result"]["component_id"].startswith("result_")
    assert FIXTURE["result"]["data-welcome"] in CONTRACT["welcome_roles"]
    assert "data-welcome" not in FIXTURE["nested_result"]
    assert FIXTURE["nested_result"]["children"][0]["data-welcome"] in CONTRACT["welcome_roles"]
