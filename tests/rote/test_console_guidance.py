"""Verifies console negotiation selects the shared guidance picker without weakening host limits.
Legacy profiles retain their notes-only adaptation.
"""

import json
from pathlib import Path

import pytest

from astralprojection.chrome.guidance import build_guidance_view
from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile


FIXTURE = json.loads((Path(__file__).parents[2]
    / "contracts/fixtures/guidance_088/selection_surface.json").read_text())


@pytest.mark.parametrize("device", ["ios", "macos", "android"])
@pytest.mark.parametrize("state", list(FIXTURE["states"].values()))
def test_console_picker_is_identical_to_shared_web_components(device, state):
    profile = DeviceProfile.from_dict({"device_type": device, "console_contract": "console/v2"})
    tagged = {"view": "selection", **state}
    expected = [component.to_dict() for component in build_guidance_view(tagged).components]
    assert ComponentAdapter.adapt_guidance_surface(tagged, profile) == expected


@pytest.mark.parametrize("device", ["windows", "watch", "ios", "android"])
def test_unnegotiated_picker_does_not_change_legacy_notes_surface(device):
    profile = DeviceProfile.from_dict({"device_type": device})
    state = {"view": "selection", **next(iter(FIXTURE["states"].values()))}
    components = ComponentAdapter.adapt_guidance_surface(state, profile)
    assert len(components) == 1 and components[0]["type"] == "alert"


@pytest.mark.parametrize("restriction", ["supported", "interactivity", "actions"])
def test_console_picker_rejects_partial_host_dispositions(restriction):
    profile = DeviceProfile.from_dict({"device_type": "ios", "console_contract": "console/v2"})
    if restriction == "supported":
        profile.supported_types = frozenset({"text", "button"})
    elif restriction == "interactivity":
        profile.supports_interactivity = False
    else:
        profile.max_actions = 1
    state = {"view": "selection", **next(iter(FIXTURE["states"].values()))}
    with pytest.raises(ValueError, match="guidance_surface_unavailable"):
        ComponentAdapter.adapt_guidance_surface(state, profile)


@pytest.mark.parametrize("changes", [
    {"view": []}, {"view": {}}, {"selected": {}}, {"status": "untrusted"},
    {"agents": "private"}, {"selected": {"agent": None, "skills": ["private"], "notes": []}},
])
def test_malformed_console_guidance_returns_no_partial_private_controls(changes):
    profile = DeviceProfile.from_dict({"device_type": "ios", "console_contract": "console/v2"})
    state = {"view": "selection", **next(iter(FIXTURE["states"].values())), **changes}
    components = ComponentAdapter.adapt_guidance_surface(state, profile)
    assert len(components) == 1 and components[0]["type"] == "alert"
    assert "private" not in json.dumps(components)


def test_confirmation_fixture_uses_the_shared_components_and_exact_selection():
    fixture = json.loads((Path(__file__).parents[2]
        / "contracts/fixtures/console/guidance-confirmation.json").read_text())
    profile = DeviceProfile.from_dict({"device_type": "ios", "console_contract": "console/v2"})
    for case in fixture["cases"]:
        assert ComponentAdapter.adapt_guidance_surface(case["state"], profile) == case["frame"]["components"]
        assert case["frame"]["selection"] == {"version": 1, **case["state"]["selected"]}


@pytest.mark.parametrize("mode", ["list", "new", "edit", "forget"])
def test_watch_notes_form_is_scoped_to_the_qualified_guidance_renderer(mode):
    fixture = json.loads((Path(__file__).parents[2]
        / "contracts/fixtures/guidance_088/notes_surface.json").read_text())
    profile = DeviceProfile.from_dict({"device_type": "watch", "console_contract": "console/v2",
        "supported_types": ["text", "alert", "badge", "card", "button"]})
    state = fixture["states"][mode]
    expected = [component.to_dict() for component in build_guidance_view(state).components]
    assert ComponentAdapter.adapt_guidance_surface(
        state, profile, surface_capabilities=["guidance_notes_v1"]) == expected
    assert "param_picker" not in profile.supported_types


@pytest.mark.parametrize("capabilities", [[], None, "guidance_notes_v1", ["guidance_selection_v1"]])
def test_missing_notes_surface_capability_does_not_admit_watch_forms(capabilities):
    profile = DeviceProfile.from_dict({"device_type": "watch", "console_contract": "console/v2",
        "supported_types": ["text", "alert", "badge", "card", "button"]})
    state = {"status": "ready", "mode": "new", "note_id": "0fe0d7ba-812a-4881-9f61-77e23327d492"}
    with pytest.raises(ValueError, match="guidance_surface_unavailable"):
        ComponentAdapter.adapt_guidance_surface(state, profile, surface_capabilities=capabilities)
