"""Tests binding guidance frames and menu entries to one shared source
(backend/webrender/chrome/menu_model.py, src/astralprojection/chrome/guidance.py):
fixture shapes and per-device adaptation of the notes surface.
"""

import json
from pathlib import Path

import pytest

from astralprojection.chrome import render_html
from astralprojection.chrome.guidance import (
    GUIDANCE_VIEWS, build_declarative_agents_view, build_guidance_view, build_notes_view,
    build_selection_form, build_skills_view,
)
from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile
from webrender.chrome import render_modal_shell
from webrender.chrome.menu_model import (
    build_menu_model,
    menu_model_dict,
    project_watch_menu_model,
)
from webrender.chrome.topbar import render_topbar

ROOT = Path(__file__).resolve().parents[1]
GUIDANCE_CONTRACTS = {
    "guidance_notes_088": ("guidance_notes_v1", build_notes_view),
    "guidance_skills_088": ("guidance_skills_v1", build_skills_view),
    "guidance_agents_088": ("guidance_agents_v1", build_declarative_agents_view),
    "guidance_selection_088": ("guidance_selection_v1", build_selection_form),
}
NEW_088_ACTIONS = {"chrome_declarative_view", "chrome_declarative_command", "chrome_turn_selection_set"}
CLOSED_TYPES = {"text", "alert", "badge", "card", "button", "param_picker"}


def manifest():
    return json.loads((ROOT / "contracts/ui_protocol.json").read_text(encoding="utf-8"))


def fixture(contract):
    return json.loads((ROOT / contract["fixture"]).read_text(encoding="utf-8"))


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


@pytest.mark.parametrize("name", sorted(GUIDANCE_CONTRACTS))
def test_exact_guidance_fixtures_match_shared_forms_and_safe_html(name):
    document = manifest()
    contract = document["presentation_contracts"][name]
    capability, builder = GUIDANCE_CONTRACTS[name]
    document_fixture = fixture(contract)
    assert contract["client_capability"] == capability
    assert contract["surface_key"] == "guidance"
    assert set(contract["actions"]) <= set(document["accept_actions"])
    assert contract["navigation"]["action"] in document["accept_actions"]
    assert set(contract["content"]["types"]) == CLOSED_TYPES <= set(document["component_types"])
    assert document_fixture["states"], name
    for mode, state in document_fixture["states"].items():
        view = builder(state)
        frame = document_fixture["frames"][mode]
        assert set(frame) == set(contract["native_response"]["exact_fields"])
        assert frame["components"] == [item.to_dict() for item in view.components]
        assert frame["surface_key"] == "guidance" and frame["mode"] == "replace"
        assert frame["admin_only"] is False and frame["region"] == "modal"
        assert "unavailable" not in render_html(view)
        assert document_fixture["web_frames"][mode]["html"] == render_modal_shell(
            view.title, render_html(view), "guidance")
        used = {item["type"] for item in nodes(frame["components"]) if "type" in item}
        assert used <= CLOSED_TYPES
        actions = {item["action"] for item in nodes(frame["components"]) if "action" in item}
        actions |= {item["submit_action"] for item in nodes(frame["components"]) if "submit_action" in item}
        assert actions <= set(contract["actions"]) | {contract["navigation"]["action"]}


def test_new_088_actions_are_manifested_once_and_nowhere_else():
    document = manifest()
    actions = document["accept_actions"]
    assert NEW_088_ACTIONS <= set(actions) and len(actions) == len(set(actions)) == 138
    declared = set()
    for name, (_, _) in GUIDANCE_CONTRACTS.items():
        contract = document["presentation_contracts"][name]
        declared |= set(contract["actions"]) | {contract["navigation"]["action"]}
    assert NEW_088_ACTIONS <= declared
    for other, contract in document["presentation_contracts"].items():
        if other not in GUIDANCE_CONTRACTS:
            assert not (set(contract.get("actions", [])) & NEW_088_ACTIONS), other


def test_guidance_capabilities_are_distinct_and_the_dispatcher_covers_every_new_contract():
    document = manifest()
    capabilities = [document["presentation_contracts"][name]["client_capability"] for name in GUIDANCE_CONTRACTS]
    assert len(set(capabilities)) == len(capabilities)
    for name, contract in document["presentation_contracts"].items():
        if name in GUIDANCE_CONTRACTS and name != "guidance_notes_088":
            view = contract["navigation"].get("view") or "agents"
            assert view in GUIDANCE_VIEWS
            for mode, state in fixture(contract)["states"].items():
                dispatched = build_guidance_view({"view": view, **state})
                assert dispatched.to_dict() == GUIDANCE_CONTRACTS[name][1](state).to_dict()


def test_selection_fixture_commands_are_exact_version_one_shapes_without_private_text():
    document = manifest()
    document_fixture = fixture(document["presentation_contracts"]["guidance_selection_088"])
    for mode, frame in document_fixture["frames"].items():
        encoded = json.dumps(frame, ensure_ascii=False)
        assert "\"value\"" not in encoded and "instructions" not in encoded, mode
        for item in nodes(frame["components"]):
            if item.get("action") == "chrome_turn_selection_set":
                payload = item["payload"]
                assert set(payload) == {"version", "agent", "skills", "notes"} and payload["version"] == 1
                assert len(payload["skills"]) <= 20 and len(payload["notes"]) <= 8


def test_skill_and_agent_fixture_commands_carry_identities_only():
    document = manifest()
    for name in ("guidance_skills_088", "guidance_agents_088"):
        document_fixture = fixture(document["presentation_contracts"][name])
        for frame in document_fixture["frames"].values():
            for item in nodes(frame["components"]):
                payload = item.get("payload") if item.get("type") == "button" else item.get("submit_payload")
                if payload is None:
                    continue
                encoded = json.dumps(payload, ensure_ascii=False)
                assert "instructions" not in encoded and "definition" not in encoded
                assert "<script>" not in encoded


@pytest.mark.parametrize("enabled", [False, True])
def test_notes_entry_has_one_shared_label_and_action(enabled):
    model = menu_model_dict(notes_enabled=enabled, work_enabled=True)
    notes = [item for group in model["menu"] for item in group["items"]
             if item["surface"] == "guidance"]
    assert len(notes) == int(enabled)
    from webrender.chrome.settings_nav import render_settings_nav

    web = render_settings_nav(build_menu_model(notes_enabled=enabled))
    assert ("Private notes" in web) is enabled
    assert "Private notes" not in render_topbar(notes_enabled=enabled)
    watch = project_watch_menu_model(model)
    assert [item["key"] for item in watch["topbar"]] == (["work", "guidance"] if enabled else ["work"])
    if enabled:
        assert watch["topbar"][-1]["label"] == notes[0]["label"] == "Private notes"
        assert watch["topbar"][-1]["action"] == {"surface": "guidance", "params": {"mode": "list"}}
    assert watch["menu"] == [] and watch["signout"] == {}


def test_menu_model_exposes_no_entry_for_the_unwired_088_views():
    model = menu_model_dict(notes_enabled=True, work_enabled=True)
    params = [item.get("params", {}) for group in model["menu"] for item in group["items"]]
    params += [item.get("action", {}).get("params", {}) for item in model["topbar"] if item.get("action")]
    assert not any("view" in item for item in params)


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
    document_fixture = json.loads((ROOT / "contracts/fixtures/guidance_088/notes_surface.json").read_text())
    profile = DeviceProfile.from_dict({"device_type": device, "viewport_width": 205 if device == "watch" else 390})
    for mode, frame in document_fixture["frames"].items():
        assert ComponentAdapter.adapt_guidance_surface(document_fixture["states"][mode], profile) == frame["components"]


@pytest.mark.parametrize("constraint", ["unsupported", "read_only", "actions"])
def test_host_constraints_refuse_a_partial_notes_form(constraint):
    document_fixture = json.loads((ROOT / "contracts/fixtures/guidance_088/notes_surface.json").read_text())
    profile = DeviceProfile.default()
    if constraint == "unsupported":
        profile.supported_types = frozenset({"text", "button", "badge"})
    elif constraint == "read_only":
        profile.supports_interactivity = False
    else:
        profile.max_actions = 1
    with pytest.raises(ValueError, match="guidance_surface_unavailable"):
        ComponentAdapter.adapt_guidance_surface(document_fixture["states"]["edit"], profile)


@pytest.mark.parametrize("name", ["guidance_skills_088", "guidance_agents_088", "guidance_selection_088"])
def test_rote_guidance_adapter_still_serves_notes_only_for_new_view_states(name):
    document_fixture = fixture(manifest()["presentation_contracts"][name])
    profile = DeviceProfile.default()
    view = "agents" if name == "guidance_agents_088" else name.split("_")[1]
    for state in document_fixture["states"].values():
        adapted = ComponentAdapter.adapt_guidance_surface({"view": view, **state}, profile)
        assert [item["type"] for item in adapted] == ["alert"]
        assert "unavailable" in adapted[0]["message"]
