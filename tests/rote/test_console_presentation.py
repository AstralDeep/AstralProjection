"""Verifies negotiated console presentation and capability aggregation at the ROTE boundary.
The fixtures mirror the web shell and keep unnegotiated native clients on legacy payloads.
"""

import json
from pathlib import Path

import pytest

from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile
from rote.rote import ROTE


NATIVE_CLIENTS = ("ios", "macos", "android")
CONSOLE_TYPES = (
    "action_group", "stat_group", "gauge", "pipeline_stepper", "donut_chart", "radar_chart",
)
SUPPORTED = [*CONSOLE_TYPES, "text", "container", "card", "button", "table", "tabs"]
COMPONENTS = [
    {"type": "action_group", "id": "actions", "component_id": "actions", "actions": [
        {"type": "button", "label": f"Action {i}", "action": f"action_{i}"} for i in range(5)
    ]},
    {"type": "stat_group", "component_id": "stats", "columns": 6,
     "items": [{"label": "Count", "value": "20"}]},
    {"type": "gauge", "component_id": "gauge", "label": "Load", "value": 0.7},
    {"type": "pipeline_stepper", "component_id": "steps", "steps": [
        {"label": "Start", "status": "done"}, {"label": "Finish", "status": "active"},
    ]},
    {"type": "donut_chart", "component_id": "donut", "labels": ["A", "B"], "data": [1, 2]},
    {"type": "radar_chart", "component_id": "radar", "axes": ["A", "B"],
     "datasets": [{"label": "Sample", "data": [1, 2]}]},
]


def descriptor(device="ios", width=1440, height=900, **updates):
    return {
        "device_type": device, "viewport_width": width, "viewport_height": height,
        "console_contract": "console/v2", "supported_types": SUPPORTED, **updates,
    }


@pytest.mark.parametrize("device", NATIVE_CLIENTS)
@pytest.mark.parametrize("case", json.loads(
    (Path(__file__).parents[2] / "contracts/fixtures/console/rote-console.json").read_text()
)["cases"], ids=lambda case: case["name"])
def test_console_presentation_matches_reference_dimensions(device, case):
    report = descriptor(case.get("device_type", device), case["viewport"][0], case["viewport"][1])
    profile = DeviceProfile.from_dict(report)
    assert profile.console_contract == "console/v2"
    assert profile.to_dict()["console_contract"] == "console/v2"
    assert profile.to_dict()["console"] == case["presentation"]


@pytest.mark.parametrize("width,mode,columns,settings", [
    (767, "drawer", 1, "sheet"), (768, "drawer", 2, "dialog"),
    (1023, "drawer", 2, "dialog"), (1024, "sidebar", 2, "dialog"),
    (1279, "sidebar", 2, "dialog"), (1280, "sidebar", 2, "dialog"),
])
def test_responsive_boundaries_are_server_owned(width, mode, columns, settings):
    console = DeviceProfile.from_dict(descriptor(width=width)).to_dict()["console"]
    assert console["navigation_mode"] == mode
    assert console["scenario_columns"] == columns
    assert console["settings_presentation"] == settings


@pytest.mark.parametrize("device", ("windows", "watch", "ios", "android", "macos", "browser"))
@pytest.mark.parametrize("contract", [None, "", "console/v1", "console/v3", "CONSOLE/v2", 2, [], {}])
def test_unnegotiated_profiles_retain_legacy_wire_shape(device, contract):
    data = descriptor(device, console_contract=contract)
    profile = DeviceProfile.from_dict(data)
    old_data = {key: value for key, value in data.items() if key != "console_contract"}
    assert profile.to_dict() == DeviceProfile.from_dict(old_data).to_dict()
    assert "console" not in profile.to_dict()
    assert "console_contract" not in profile.to_dict()


@pytest.mark.parametrize("value", [None, "390", True, -1, 20000, {}, [], float("inf"), float("nan")])
@pytest.mark.parametrize("field", ["viewport_width", "viewport_height", "screen_width", "screen_height"])
def test_malformed_dimensions_use_bounded_defaults(field, value):
    data = descriptor(**{field: value})
    profile = DeviceProfile.from_dict(data)
    fallback = DeviceProfile.default().capabilities
    assert getattr(profile.capabilities, field) == getattr(fallback, field)
    json.dumps(profile.to_dict(), allow_nan=False)


@pytest.mark.parametrize("ratio", [
    None, "2", True, 0, -1, 20, 10 ** 1024, float("inf"), float("nan"), {}, [],
])
def test_malformed_scale_uses_default(ratio):
    profile = DeviceProfile.from_dict(descriptor(pixel_ratio=ratio))
    assert profile.capabilities.pixel_ratio == 1.0


@pytest.mark.parametrize("data", [None, [], "console/v2", 1, True])
def test_non_object_descriptors_use_default_profile(data):
    assert DeviceProfile.from_dict(data) == DeviceProfile.default()


def test_zero_viewport_uses_screen_dimensions_and_touch_sets_control_floor():
    console = DeviceProfile.from_dict(descriptor(
        width=0, height=0, screen_width=390, screen_height=844, has_touch=True,
    )).to_dict()["console"]
    assert console["sidebar_width"] == 320
    assert console["settings_width"] == 390
    assert console["settings_max_height"] == 844
    assert console["minimum_control_height"] == 44
    touch = DeviceProfile.from_dict(descriptor(has_touch=True)).to_dict()["console"]
    assert touch["minimum_control_height"] == 44


def test_zero_screen_dimensions_use_defaults():
    profile = DeviceProfile.from_dict(descriptor(
        width=0, height=0, screen_width=0, screen_height=0,
    ))
    assert profile.capabilities.screen_width == 1920
    assert profile.capabilities.screen_height == 1080
    assert profile.to_dict()["console"]["settings_max_height"] == 860


def test_valid_scale_and_nested_voice_report_are_retained():
    profile = DeviceProfile.from_dict(descriptor(pixel_ratio=2.5, voice={
        "has_microphone": True, "transport": "livekit", "microphone_permission": "authorized",
    }))
    assert profile.capabilities.pixel_ratio == 2.5
    assert profile.capabilities.has_microphone
    assert profile.capabilities.voice_transport == "livekit"
    assert profile.capabilities.microphone_permission == "authorized"


@pytest.mark.parametrize("voice", [{"transport": []}, {"transport": {}}, []])
def test_malformed_nested_voice_transport_fails_closed(voice):
    profile = DeviceProfile.from_dict(descriptor(voice=voice))
    assert profile.capabilities.voice_transport == ""


@pytest.mark.parametrize("field", [
    "device_type", "pointer_type", "has_touch", "reduced_motion", "user_agent",
    "voice_transport", "microphone_permission", "recognition_permission", "recognition_processing",
    "recognition_locale", "recognition_installation", "synthesis_processing", "synthesis_locale",
])
def test_malformed_capability_values_are_not_echoed_or_used(field):
    profile = DeviceProfile.from_dict(descriptor(**{field: {"untrusted": [1]}}))
    fallback = DeviceProfile.default().capabilities
    assert getattr(profile.capabilities, field) == getattr(fallback, field)


@pytest.mark.parametrize("device", NATIVE_CLIENTS)
def test_negotiated_native_delivers_every_advertised_console_type(device):
    profile = DeviceProfile.from_dict(descriptor(device))
    assert [node["type"] for node in ComponentAdapter.adapt(COMPONENTS, profile)] == list(CONSOLE_TYPES)


@pytest.mark.parametrize("device", NATIVE_CLIENTS)
@pytest.mark.parametrize("width", [390, 480, 699, 700, 767, 768, 1024, 1440])
def test_native_console_adaptation_matches_web_components(device, width):
    native = DeviceProfile.from_dict(descriptor(device, width))
    web = DeviceProfile.from_dict(descriptor("browser", width))
    assert ComponentAdapter.adapt(COMPONENTS, native) == ComponentAdapter.adapt(COMPONENTS, web)


@pytest.mark.parametrize("component", COMPONENTS, ids=lambda item: item["type"])
@pytest.mark.parametrize("advertisement", [None, [], "all", {}, [None, 1, {}], [" Gauge ", "GAUGE"]])
def test_missing_exact_supported_type_keeps_fallback(component, advertisement):
    profile = DeviceProfile.from_dict(descriptor(supported_types=advertisement))
    adapted = ComponentAdapter.adapt([component], profile)
    assert adapted and adapted[0]["type"] != component["type"]
    assert adapted[0]["component_id"] == component["component_id"]


def test_oversized_supported_types_and_capability_strings_are_bounded():
    profile = DeviceProfile.from_dict(descriptor(
        supported_types=["gauge"] * 257, user_agent="x" * 1025, pointer_type="x" * 65,
    ))
    assert not profile.supported_types
    assert profile.capabilities.user_agent == ""
    assert profile.capabilities.pointer_type == "fine"
    assert ComponentAdapter.adapt([COMPONENTS[2]], profile)[0]["type"] != "gauge"


def test_capability_change_at_same_width_readapts_cached_components():
    runtime = ROTE()
    connection = object()
    initial = descriptor(supported_types=["progress", "text"])
    runtime.register_device(connection, initial)
    assert runtime.adapt(connection, [COMPONENTS[2]])[0]["type"] == "progress"
    profile, components, changed = runtime.update_device(connection, descriptor())
    assert changed and profile.console_contract == "console/v2"
    assert components == [COMPONENTS[2]]
    _, components, changed = runtime.update_device(connection, initial)
    assert changed and components[0]["type"] == "progress"


@pytest.mark.parametrize("updates", [
    {"pixel_ratio": 2}, {"has_touch": True}, {"pointer_type": "coarse"},
    {"reduced_motion": True}, {"has_camera": True}, {"has_file_system": False},
    {"voice_transport": "livekit", "has_microphone": True},
    {"console_contract": ""},
])
def test_rendering_capability_changes_trigger_update_without_resize(updates):
    runtime = ROTE()
    connection = object()
    runtime.register_device(connection, descriptor())
    runtime.adapt(connection, [COMPONENTS[2]])
    _, adapted, changed = runtime.update_device(connection, descriptor(**updates))
    assert changed and adapted
    _, adapted, changed = runtime.update_device(connection, descriptor(**updates))
    assert not changed and adapted is None


def test_reordering_supported_types_does_not_trigger_redundant_adaptation():
    runtime = ROTE()
    connection = object()
    runtime.register_device(connection, descriptor())
    runtime.adapt(connection, [COMPONENTS[2]])
    _, adapted, changed = runtime.update_device(
        connection, descriptor(supported_types=list(reversed(SUPPORTED))),
    )
    assert not changed and adapted is None


def test_nested_console_types_keep_identity_and_unadvertised_types_fall_back():
    node = {"type": "tabs", "tabs": [{"label": "Result", "content": [{
        "type": "card", "content": COMPONENTS[1:3],
    }]}]}
    profile = DeviceProfile.from_dict(descriptor(
        supported_types=[name for name in SUPPORTED if name != "gauge"],
    ))
    output = ComponentAdapter.adapt([node], profile)[0]["tabs"][0]["content"][0]["content"]
    assert output[0]["type"] == "stat_group"
    assert output[1]["type"] != "gauge"
    assert [item["component_id"] for item in output] == ["stats", "gauge"]


@pytest.mark.parametrize("host", [{"max_actions": 1}, {"supports_interactivity": False}])
def test_console_action_groups_obey_host_action_limits(monkeypatch, host):
    monkeypatch.setenv("ROTE_HOST_CONFIG", json.dumps({"ios": host}))
    profile = DeviceProfile.from_dict(descriptor())
    output = ComponentAdapter.adapt([COMPONENTS[0]], profile)[0]
    buttons = output.get("actions", []) + output.get("overflow_actions", [])
    assert len(buttons) == (0 if host.get("supports_interactivity") is False else 1)


def test_operator_chart_restrictions_are_preserved_with_console_negotiation(monkeypatch):
    monkeypatch.setenv("ROTE_HOST_CONFIG", json.dumps({"ios": {"supports_charts": False}}))
    profile = DeviceProfile.from_dict(descriptor())
    assert all(node["type"] not in {"donut_chart", "radar_chart"}
               for node in ComponentAdapter.adapt(COMPONENTS[-2:], profile))
