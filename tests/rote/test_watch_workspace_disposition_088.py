"""088 retains the server-owned 055 wrist export/share capability boundary."""

import json

import pytest

from astralprojection.resources import protocol_manifest_path
from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile
from webrender.renderer import render_workspace


@pytest.fixture(autouse=True)
def host_defaults(monkeypatch):
    monkeypatch.delenv("ROTE_HOST_CONFIG", raising=False)
    monkeypatch.setenv("FF_ARTIFACT_EXPORT", "true")
    monkeypatch.setenv("FF_ARTIFACT_SHARING", "true")


def test_manifest_declares_existing_watch_bounds_without_disabling_chat():
    contract = json.loads(protocol_manifest_path().read_text())["presentation_contracts"]
    disposition = contract["chrome_menu"]["workspace_action"]["watch_disposition"]
    assert disposition["source_feature"] == "055-uniform-artifacts"
    assert disposition["disposition"] == "omitted_by_server"
    assert disposition["chrome_menu_delivery"] is False
    assert disposition["workspace_capability_attributes"] is False
    assert disposition["supports_file_io"] is False
    # A client declaration cannot widen the server's existing file-IO bound.
    profile = DeviceProfile.from_dict({
        "device_type": "watch", "viewport_width": 205, "supports_file_io": True,
    })
    assert profile.supports_file_io is disposition["supports_file_io"]
    assert profile.supports_interactivity is True
    primary = {"type": "button", "label": "Continue", "action": "chat_message",
               "payload": {"message": "Continue"}, "variant": "primary"}
    assert ComponentAdapter.adapt([primary], profile) == [primary]


@pytest.mark.parametrize("device_type", ["watch", "ios", "android", "macos"])
def test_real_profiles_keep_artifact_chrome_and_file_io_only_on_supported_hosts(device_type):
    profile = DeviceProfile.from_dict({"device_type": device_type, "viewport_width": 390})
    table = {"type": "table", "component_id": "wc_export_fixture",
             "headers": ["Name", "Value"], "rows": [["Alpha", 2], ["Beta", 5]]}
    download = {"type": "file_download", "label": "Download result",
                "url": "/api/export/canvas/fixture.html"}
    adapted = ComponentAdapter.adapt([table, download], profile)
    html = render_workspace(adapted, profile)
    capable = device_type != "watch"
    assert profile.supports_file_io is capable
    assert ('data-astral-export="1"' in html) is capable
    assert ('data-astral-share="1"' in html) is capable
    assert ("astral-component-chrome" in html) is capable
    assert ("astral-export-csv" in html) is capable
    assert ("astral-share-btn" in html) is capable
    assert (download in adapted) is capable
    if not capable:
        assert all(component["type"] not in ("button", "file_download") for component in adapted)
        assert "/api/export/" not in html and "/api/share" not in html
        assert "Alpha" in html and "Beta" in html


def test_watch_omission_preserves_existing_server_handoff_text():
    profile = DeviceProfile.from_dict({"device_type": "watch", "viewport_width": 205})
    guidance = {"type": "text", "content": "Open this chat on your phone or the web to export."}
    adapted = ComponentAdapter.adapt([guidance], profile)
    assert adapted == [guidance]
    html = render_workspace(adapted, profile)
    assert guidance["content"] in html
    assert "<button" not in html and "href=" not in html
    assert "data-astral-export" not in html and "data-astral-share" not in html
