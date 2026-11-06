"""Verifies explicit macOS chat memory capability negotiation and compatible fallback."""

import json
from pathlib import Path

import pytest

from rote.capabilities import DeviceProfile


def test_chat_memory_acknowledgment_requires_exact_mac_console_opt_in():
    profile = DeviceProfile.from_dict({
        "device_type": "macos", "console_contract": "console/v2", "chat_memory_v1": True,
    })
    assert getattr(profile, "chat_memory_v1", False) is True
    assert profile.to_dict()["console"]["chat_memory"] == {"version": 1}


@pytest.mark.parametrize("change", [
    {"chat_memory_v1": value} for value in (False, None, "true", 1, [], {})
] + [{"device_type": value} for value in ("ios", "android", "windows", "browser", "watch")]
  + [{"console_contract": ""}])
def test_unsupported_or_unnegotiated_profiles_keep_legacy_conversation(change):
    profile = DeviceProfile.from_dict({
        "device_type": "macos", "console_contract": "console/v2", "chat_memory_v1": True, **change,
    })
    assert getattr(profile, "chat_memory_v1", False) is False
    assert "chat_memory" not in profile.to_dict().get("console", {})


def test_negotiated_profile_keeps_project_and_memory_acknowledgments_together():
    profile = DeviceProfile.from_dict({
        "device_type": "macos", "console_contract": "console/v2",
        "project_workspaces_v1": True, "chat_memory_v1": True,
    })
    console = profile.to_dict()["console"]
    assert console["project_workspaces"] == {"version": 1, "mode": "projects_only"}
    assert console["chat_memory"] == {"version": 1}


def test_manifest_declares_opt_in_and_all_client_dispositions():
    manifest = json.loads(
        (Path(__file__).parents[2] / "contracts/ui_protocol.json").read_text())
    contract = manifest["presentation_contracts"]["chat_memory_v1"]
    assert set(contract["clients"]) == {"macos", "browser", "windows", "android", "ios", "watch"}
    assert contract["bounds"] == {"summary_scalars": 512, "pending": "0-99"}
    actions = set(manifest["accept_actions"])
    assert {
        "chat_memory_use", "chat_memory_learn", "chat_memory_forget",
        "chat_memory_undo", "chat_memory_decide",
    } <= actions
    pushes = {item["name"] for item in manifest["push_types"]}
    assert {"chat_memory_state", "memory_change_recorded", "memory_change_refused"} <= pushes
    fields = {item["field"] for item in manifest["additive_fields"]}
    assert "memory_change" in fields
    for name in ("chat_memory_use", "chat_memory_learn", "chat_memory_forget"):
        assert "client_message_id" in contract["client_actions"][name]["exact_fields"]
    for name in ("chat_memory_undo", "chat_memory_decide"):
        assert "expected_revision" in contract["client_actions"][name]["exact_fields"]
    assert contract["server_events"]["memory_change_refused"]["codes"] == [
        "stale_revision", "not_found", "phi_protected", "unavailable",
    ]
