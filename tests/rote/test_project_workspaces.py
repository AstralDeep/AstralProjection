"""Verifies explicit macOS project presentation selection and compatible fallback."""

import pytest

from rote.capabilities import DeviceProfile


def test_project_presentation_requires_exact_mac_console_opt_in():
    profile = DeviceProfile.from_dict({
        "device_type": "macos", "console_contract": "console/v2", "project_workspaces_v1": True,
    })
    assert getattr(profile, "project_workspaces_v1", False) is True
    assert profile.to_dict()["console"]["project_workspaces"] == {"version": 1, "mode": "projects_only"}


@pytest.mark.parametrize("change", [
    {"project_workspaces_v1": value} for value in (False, None, "true", 1, [], {})
] + [{"device_type": value} for value in ("ios", "android", "windows", "browser", "watch")]
  + [{"console_contract": ""}])
def test_unsupported_or_unnegotiated_profiles_keep_legacy_presentation(change):
    profile = DeviceProfile.from_dict({
        "device_type": "macos", "console_contract": "console/v2", "project_workspaces_v1": True, **change,
    })
    assert getattr(profile, "project_workspaces_v1", False) is False
    assert "project_workspaces" not in profile.to_dict().get("console", {})


def test_manifest_declares_opt_in_and_all_client_dispositions():
    import json
    from pathlib import Path

    manifest = json.loads((Path(__file__).parents[2] / "contracts/ui_protocol.json").read_text())
    contract = manifest["presentation_contracts"]["project_workspaces_v1"]
    assert set(contract["clients"]) == {"macos", "browser", "windows", "android", "ios", "watch"}
    assert contract["manifest"]["bounds"] == {
        "projects": 64, "roots_per_project": 16, "total_roots": 256, "encoded_bytes": 262144,
    }
    fields = {item["field"] for item in manifest["additive_fields"]}
    assert {"project_manifest", "project_context", "project_manifest_ack", "project_id", "projects_changed"} <= fields
