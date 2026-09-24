"""Reasoning panels have no server-owned component actions, including after adaptation or forged metadata."""

from types import SimpleNamespace

import pytest

from webrender.chrome.component_model import (
    build_component_chrome,
    renderer_component_actions,
    stamp_component_chrome,
)
from webrender.renderer import render_component_fragment


def profile(device="browser"):
    return SimpleNamespace(device_type=SimpleNamespace(value=device), supports_interactivity=True)


def reasoning(**changes):
    return {"type": "collapsible", "component_id": "wc_reasoning", "title": "Reasoning",
            "children": [{"type": "text", "content": "Brief explanation"}], **changes}


@pytest.fixture(autouse=True)
def all_actions_enabled(monkeypatch):
    for flag in ("FF_COMPONENT_REFINE", "FF_ARTIFACT_EXPORT", "FF_ARTIFACT_SHARING"):
        monkeypatch.setenv(flag, "true")


@pytest.mark.parametrize("title", ["Reasoning", "reasoning", "REASONING", " Reasoning ", "\nReasoning\t"])
@pytest.mark.parametrize("device", ["browser", "windows", "android", "macos", "ios"])
def test_reasoning_has_no_actions_on_any_interactive_receiver(title, device):
    assert build_component_chrome(reasoning(title=title), profile(device)) == {"version": 1, "actions": []}


def test_reasoning_policy_returns_before_consulting_action_flags():
    def unexpected_flag(_name):
        pytest.fail("Reasoning must not consult action feature flags")

    assert build_component_chrome(reasoning(type=" Collapsible "), profile(), enabled=unexpected_flag)["actions"] == []


def test_forged_action_inventory_cannot_restore_reasoning_controls():
    forged = build_component_chrome({"type": "table", "component_id": "wc_table"}, profile())
    assert {action["kind"] for action in forged["actions"]} == {"refine", "history", "csv", "share"}
    component = reasoning(component_chrome=forged, versions=[{"version_no": 1, "title": "Old reasoning"}])
    assert renderer_component_actions(component, profile()) == []
    html = render_component_fragment(component, profile())
    assert "astral-reasoning" in html
    assert "Brief explanation" in html
    for marker in ("astral-component-chrome", "astral-refine-btn", "astral-vhistory-btn", "astral-export-csv", "astral-share-btn"):
        assert marker not in html


@pytest.mark.parametrize("title", [" Reasoning ", "  rEaSoNiNg  ", "\nREASONING\t"])
def test_normalized_reasoning_markup_has_marker_without_component_actions(title):
    component = reasoning(title=title)
    component["component_chrome"] = build_component_chrome(
        {"type": "table", "component_id": "wc_table"}, profile(),
    )
    html = render_component_fragment(component, profile())
    assert 'class="astral-collapsible astral-reasoning ' in html
    assert "Brief explanation" in html
    assert "astral-component-chrome" not in html
    assert renderer_component_actions(component, profile()) == []


@pytest.mark.parametrize("adapted_type", ["collapsible", "text", "table"])
def test_canonical_reasoning_denial_survives_device_fallback(adapted_type):
    original = reasoning()
    adapted = reasoning(type=adapted_type, title="Adapted panel", content="Brief explanation")
    adapted["component_chrome"] = build_component_chrome({"type": "table", "component_id": "wc_table"}, profile())
    stamped = stamp_component_chrome(original, adapted, profile("android"))
    assert stamped["component_chrome"] == {"version": 1, "actions": []}
    assert renderer_component_actions(adapted, profile(), canonical=original) == []
    assert "astral-component-chrome" not in render_component_fragment(stamped, profile(), canonical=original)


@pytest.mark.parametrize("title", ["Details", "Reasoning results", "Clinical reasoning", "", None, 42])
def test_other_collapsibles_keep_normal_actions(title):
    component = reasoning(title=title)
    expected = ["refine", "history", "share"]
    assert [action["kind"] for action in build_component_chrome(component, profile())["actions"]] == expected
    assert [action["kind"] for action in renderer_component_actions(component, profile())] == expected
    assert "astral-component-chrome" in render_component_fragment(component, profile())


def test_reasoning_title_alone_does_not_suppress_other_component_types():
    component = {"type": "table", "component_id": "wc_table", "title": "Reasoning", "headers": ["Reason"], "rows": [["Example"]]}
    assert [action["kind"] for action in build_component_chrome(component, profile())["actions"]] == ["refine", "history", "csv", "share"]
