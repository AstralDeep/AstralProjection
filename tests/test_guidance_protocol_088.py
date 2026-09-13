"""Notes frames and negotiated menu entries come from the same shared source."""
import json
from pathlib import Path

import pytest

from astralprojection.chrome import render_html
from astralprojection.chrome.guidance import build_notes_view
from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile
from webrender.chrome import render_modal_shell
from webrender.chrome.menu_model import menu_model_dict, project_watch_menu_model
from webrender.chrome.topbar import render_topbar

ROOT = Path(__file__).resolve().parents[1]


def test_exact_notes_fixture_matches_shared_forms_and_safe_html():
    manifest = json.loads((ROOT / "contracts/ui_protocol.json").read_text())
    contract = manifest["presentation_contracts"]["guidance_notes_088"]
    fixture = json.loads((ROOT / contract["fixture"]).read_text())
    assert contract["client_capability"] == "guidance_notes_v1"
    assert set(contract["actions"]) <= set(manifest["accept_actions"])
    for mode, state in fixture["states"].items():
        view = build_notes_view(state)
        frame = fixture["frames"][mode]
        assert set(frame) == set(contract["native_response"]["exact_fields"])
        assert frame["components"] == [item.to_dict() for item in view.components]
        assert frame["surface_key"] == "guidance"
        assert fixture["web_frames"][mode]["html"] == render_modal_shell(
            view.title, render_html(view), "guidance")


@pytest.mark.parametrize("enabled", [False, True])
def test_notes_entry_has_one_shared_label_and_action(enabled):
    model = menu_model_dict(notes_enabled=enabled, work_enabled=True)
    notes = [item for group in model["menu"] for item in group["items"]
             if item["surface"] == "guidance"]
    assert len(notes) == int(enabled)
    web = render_topbar(notes_enabled=enabled)
    assert ("Private notes" in web) is enabled
    watch = project_watch_menu_model(model)
    assert [item["key"] for item in watch["topbar"]] == (["work", "guidance"] if enabled else ["work"])
    if enabled:
        assert watch["topbar"][-1]["label"] == notes[0]["label"] == "Private notes"
        assert watch["topbar"][-1]["action"] == {"surface": "guidance", "params": {"mode": "list"}}
    assert watch["menu"] == [] and watch["signout"] == {}


def test_watch_refuses_modified_or_duplicate_notes_affordance():
    model = menu_model_dict(notes_enabled=True)
    account = model["menu"][0]["items"]
    item = next(item for item in account if item["surface"] == "guidance")
    account.append(dict(item))
    assert project_watch_menu_model(model)["topbar"] == []
    account.pop()
    item["params"]["owner_id"] = "foreign"
    assert project_watch_menu_model(model)["topbar"] == []


@pytest.mark.parametrize("device", ["browser", "android", "ios", "macos", "watch"])
def test_device_adaptation_retains_every_exact_note_and_form(device):
    fixture = json.loads((ROOT / "contracts/fixtures/guidance_088/notes_surface.json").read_text())
    profile = DeviceProfile.from_dict({"device_type": device, "viewport_width": 205 if device == "watch" else 390})
    for mode, frame in fixture["frames"].items():
        assert ComponentAdapter.adapt_guidance_surface(fixture["states"][mode], profile) == frame["components"]


@pytest.mark.parametrize("constraint", ["unsupported", "read_only", "actions"])
def test_host_constraints_refuse_a_partial_notes_form(constraint):
    fixture = json.loads((ROOT / "contracts/fixtures/guidance_088/notes_surface.json").read_text())
    profile = DeviceProfile.default()
    if constraint == "unsupported":
        profile.supported_types = frozenset({"text", "button", "badge"})
    elif constraint == "read_only":
        profile.supports_interactivity = False
    else:
        profile.max_actions = 1  # Back and Save both count.
    with pytest.raises(ValueError, match="guidance_surface_unavailable"):
        ComponentAdapter.adapt_guidance_surface(fixture["states"]["edit"], profile)
