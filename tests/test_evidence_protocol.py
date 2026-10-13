"""Checks the evidence inspection fixture against the shared modal and literal renderers.
The manifest binds each client's disposition without introducing presentation authority.
"""

import json
from pathlib import Path
from uuid import UUID

import pytest

from webrender import render
from webrender.chrome import render_modal_shell

ROOT = Path(__file__).resolve().parents[1]


def test_evidence_inspection_has_closed_existing_frames_actions_and_dispositions():
    manifest = json.loads((ROOT / "contracts/ui_protocol.json").read_text())
    contract = manifest["presentation_contracts"]["evidence_inspection"]
    fixture = json.loads((ROOT / contract["fixture"]).read_text())
    assert fixture["version"] == contract["version"] == 1
    assert contract["surface_key"] == "evidence"
    assert contract["navigation"]["action"] == fixture["request"]["action"] == "chrome_open"
    assert fixture["request"]["action"] in manifest["accept_actions"]
    frames = {item["name"] for item in manifest["push_types"]}
    assert contract["native_response"]["type"] in frames
    assert contract["web_response"]["type"] in frames
    assert set(contract["content"]["types"]) <= set(manifest["component_types"])
    assert contract["dispositions"] == {
        "browser": "correlated_modal", "windows": "correlated_modal",
        "android": "correlated_modal", "macos": "correlated_modal",
        "ios": "correlated_modal", "watchos": "phone_desktop_handoff",
    }
    request = fixture["request"]
    generation = request["request_generation"]
    assert str(UUID(generation)) == generation and UUID(generation).version == 4
    assert set(request["payload"]) == {"surface", "params"}
    assert request["payload"]["surface"] == contract["surface_key"]
    for name in ("native", "web"):
        frame = fixture[f"{name}_frame"]
        assert set(frame) == set(contract[f"{name}_response"]["exact_fields"])
        assert frame["surface_key"] == contract["surface_key"]
        assert frame["request_generation"] == generation
        assert frame["region"] == "modal" and frame["mode"] == "replace"


def test_evidence_fixture_uses_literal_sanitized_transient_text_and_watch_handoff():
    manifest = json.loads((ROOT / "contracts/ui_protocol.json").read_text())
    contract = manifest["presentation_contracts"]["evidence_inspection"]
    fixture = json.loads((ROOT / contract["fixture"]).read_text())
    frame = fixture["native_frame"]
    assert frame["admin_only"] is False
    components = frame["components"]
    assert components[1]["items"][0]["value"] == fixture["source_text"]
    html = render_modal_shell(frame["title"], render(components), frame["surface_key"])
    assert fixture["web_frame"]["html"] == html
    assert "<script>" not in html and "<strong>literal source</strong>" not in html
    assert "&lt;script&gt;" in html and "**literal source**" in html
    assert ">Permitted text</dt>" in html
    assert "href=\"https://example.org/inert\"" not in html
    watch = fixture["watch_components"]
    assert fixture["source_text"] not in json.dumps(watch)
    assert all(item["type"] != "button" for item in watch)
    assert any("phone or desktop" in item.get("message", "") for item in watch)
    assert contract["content"]["page_utf8_bytes"] == 16384
    assert contract["content"]["preview_utf8_bytes"] == 1024


@pytest.mark.parametrize("item,label", [
    ({"key": "Source SHA-256", "value": "a" * 64}, "Source SHA-256"),
    ({"key": "Observed input tokens", "value": "7"}, "Observed input tokens"),
    ({"label": "Explicit label", "value": "7"}, "Explicit label"),
    ({"label": "Explicit label", "key": "Fallback", "value": "7"}, "Explicit label"),
    ({"label": "", "key": "Fallback", "value": "7"}, ""),
    ({"value": "7"}, ""),
])
def test_keyvalue_retains_explicit_label_precedence_and_key_fallback(item, label):
    html = render([{"type": "keyvalue", "items": [item]}])
    assert f">{label}</dt>" in html
    assert "Fallback" not in html


def test_keyvalue_key_alias_uses_the_existing_label_sanitizer_and_literal_value():
    html = render([{"type": "keyvalue", "items": [{
        "key": '<script>alert("label")</script>',
        "value": '<script>alert("value")</script> **literal**',
    }]}])
    assert "<script>" not in html and "&lt;script&gt;" in html
    assert "&lt;script&gt;" in html.split("</dt>")[0]
    assert "**literal**" in html and "<strong>literal</strong>" not in html
