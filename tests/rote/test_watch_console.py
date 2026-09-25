"""Checks negotiated watch presentation and surface-specific native capability claims.
Legacy projection and generic component fallback remain independent of watch forms.
"""

from copy import deepcopy

import pytest

from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile
from rote.console import watch_availability
from rote.rote import ROTE
from webrender.chrome.menu_model import menu_model_dict, project_watch_menu_model


TYPES = ["text", "alert", "badge", "card", "container", "button", "list", "keyvalue"]
CAPABILITIES = ["guidance_notes_v1", "guidance_selection_v1", "work_read_v1"]


def watch(**changes):
    return DeviceProfile.from_dict({"device_type": "watch", "console_contract": "console/v2",
        "viewport_width": 205, "viewport_height": 251, "supported_types": TYPES, **changes})


@pytest.mark.parametrize("width,height", [(162, 197), (205, 251), (0, 0)])
def test_watch_console_uses_stack_and_fullscreen_pushed_settings(width, height):
    profile = watch(viewport_width=width, viewport_height=height, screen_width=205, screen_height=251)
    value = profile.to_dict()["console"]
    assert value["navigation_mode"] == "stack" and value["sidebar_width"] == 0
    assert value["scenario_columns"] == 1 and value["settings_presentation"] == "push"
    assert value["settings_navigation_axis"] == "vertical" and value["settings_navigation_width"] == 0
    assert value["settings_width"] == value["dialog_width"] == (width or 205)
    assert value["settings_max_height"] == (height or 251)
    assert value["content_padding"] == value["composer_padding"] == dict.fromkeys(
        ("top", "right", "bottom", "left"), 8)
    assert value["minimum_control_height"] == 44


@pytest.mark.parametrize("width,expected", [(390, 390), (768, 640), (1280, 640)])
def test_intro_and_selection_dialogs_use_the_shared_narrow_width(width, expected):
    value = DeviceProfile.from_dict({"device_type": "ios", "console_contract": "console/v2",
        "viewport_width": width}).to_dict()["console"]
    assert value["dialog_width"] == expected


@pytest.mark.parametrize("surface,params", [("guidance", {}),
    ("guidance", {"view": "selection"}), ("work", {}), ("agent_intro", {})])
def test_watch_surface_availability_requires_scoped_capabilities(surface, params):
    assert watch_availability(surface, params, watch(), CAPABILITIES) == {"mode": "native"}
    if surface != "agent_intro":
        assert watch_availability(surface, params, watch(), [])["mode"] == "handoff"


@pytest.mark.parametrize("restriction", ["legacy", "missing", "empty", "interactivity", "actions"])
def test_partial_watch_rendering_does_not_claim_native_surfaces(restriction):
    profile = watch()
    if restriction == "legacy":
        profile.console_contract = ""
    elif restriction == "missing":
        profile.supported_types = None
    elif restriction == "empty":
        profile.supported_types = frozenset()
    elif restriction == "interactivity":
        profile.supports_interactivity = False
    else:
        profile.max_actions = 1
    assert watch_availability("guidance", {}, profile, CAPABILITIES)["mode"] == "handoff"


@pytest.mark.parametrize("surface", ["llm", "theme", "workspace_timeline", "pulse", "background", "unknown", None, []])
def test_unsupported_settings_have_explicit_server_handoff(surface):
    assert watch_availability(surface, {}, watch(), CAPABILITIES) == {
        "mode": "handoff", "message": "Continue on your phone or desktop."}


@pytest.mark.parametrize("capabilities", [None, {}, "guidance_notes_v1", [[], {}]])
def test_malformed_surface_capabilities_never_admit_private_notes(capabilities):
    assert watch_availability("guidance", {}, watch(), capabilities)["mode"] == "handoff"


def test_negotiated_menu_keeps_inventory_and_adds_availability_without_mutation():
    source = menu_model_dict(include_admin=False, include_tour=False, notes_enabled=True,
        work_enabled=True, connections_enabled=True, pulse_enabled=True)
    original = deepcopy(source)
    result = project_watch_menu_model(source, profile=watch(), client_capabilities=CAPABILITIES)
    assert source == original and result["signout"] == source["signout"]
    items = {item["key"]: item for group in result["menu"] for item in group["items"]}
    assert set(items) == {item["key"] for group in source["menu"] for item in group["items"]}
    assert items["guidance"]["availability"] == {"mode": "native"}
    assert items["connections"]["availability"]["mode"] == "handoff"
    controls = {item["key"]: item for item in result["topbar"]}
    assert controls["work"]["availability"] == {"mode": "native"}
    assert controls["timeline"]["availability"]["mode"] == "handoff"


def test_non_watch_or_unnegotiated_menu_retains_exact_legacy_projection():
    source = menu_model_dict(notes_enabled=True, work_enabled=True)
    expected = project_watch_menu_model(source)
    for profile in (watch(console_contract=""), watch(device_type="windows")):
        assert project_watch_menu_model(source, profile=profile, client_capabilities=CAPABILITIES) == expected


def test_watch_type_aggregation_readapts_at_the_same_dimensions():
    rote = ROTE()
    client = object()
    report = {"device_type": "watch", "console_contract": "console/v2", "viewport_width": 205,
              "supported_types": TYPES}
    rote.register_device(client, report)
    assert rote.update_device(client, {**report, "supported_types": [*TYPES, "param_picker"]})[2]
    assert not rote.update_device(client, {**report, "supported_types": [*TYPES, "param_picker"]})[2]


def test_surface_scoped_param_picker_does_not_enable_generic_watch_forms():
    component = {"type": "param_picker", "title": "Generic", "fields": [
        {"name": "value", "type": "text", "label": "Value"}], "submit_action": "untrusted"}
    assert ComponentAdapter.adapt([component], watch())[0]["type"] != "param_picker"
