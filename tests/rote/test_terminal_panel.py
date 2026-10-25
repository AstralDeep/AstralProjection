"""Tests the terminal panel's ROTE adaptation: closed per-device dispositions, the
interactive/read-only split, bounded fail-closed validation and the code-to-text fallback.
"""

from __future__ import annotations

import pytest

from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile
from rote.terminal import validate_terminal_components

PANEL_STATE = {
    "mode": "panel",
    "status": "ready",
    "session": {
        "session_id": "term_01JABCDEF",
        "target": "ops@staging.example",
        "directory": "/srv/astral/work",
        "state": "running",
        "cols": 120,
        "rows": 32,
        "ring_start": 0,
        "ring_end": 12,
    },
    "output": {"text": "$ ls\nfile\n", "offset": 0, "next_offset": 12,
               "truncated": False, "eof": False},
}


def _profile(device: str) -> DeviceProfile:
    return DeviceProfile.from_dict({"device_type": device})


def _types(components):
    return [component["type"] for component in components]


def test_interactive_dispositions_receive_the_terminal_controls():
    for device in ("browser", "windows"):
        adapted = ComponentAdapter.adapt_terminal_surface(PANEL_STATE, _profile(device))
        actions = {node.get("action", node.get("submit_action"))
                   for node in ComponentAdapter._terminal_text_fallback([{"type": "code", "code": ""}])
                   } if False else {
            node.get("action") or node.get("submit_action")
            for component in adapted
            for node in _walk(component)
            if node.get("type") in {"button", "param_picker"}
            and (node.get("action") or node.get("submit_action"))
        }
        assert {"chrome_terminal_input", "chrome_terminal_resize",
                "chrome_terminal_interrupt", "chrome_terminal_close"} <= actions, device


def _walk(node, found=None):
    found = [] if found is None else found
    found.append(node)
    for key in ("content", "children"):
        child = node.get(key)
        if isinstance(child, list):
            for item in child:
                _walk(item, found)
    return found


def test_read_only_dispositions_never_receive_terminal_controls():
    for device in ("android", "ios", "macos", "tablet", "mobile"):
        adapted = ComponentAdapter.adapt_terminal_surface(PANEL_STATE, _profile(device))
        actions = {
            node.get("action") or node.get("submit_action")
            for component in adapted
            for node in _walk(component)
            if node.get("type") in {"button", "param_picker"}
            and (node.get("action") or node.get("submit_action"))
        }
        assert actions == {"chrome_open", "chrome_close"}, device
        assert not any(node.get("type") == "param_picker" for component in adapted
                       for node in _walk(component)), device


def test_watch_receives_only_the_content_free_handoff():
    adapted = ComponentAdapter.adapt_terminal_surface(PANEL_STATE, _profile("watch"))
    assert _types(adapted) == ["badge", "alert"]
    serialized = repr(adapted)
    for private in ("term_01JABCDEF", "ops@staging.example", "/srv/astral/work", "$ ls"):
        assert private not in serialized


def test_voice_is_omitted_by_the_server():
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        ComponentAdapter.adapt_terminal_surface(PANEL_STATE, _profile("voice"))


def test_mobile_falls_back_from_code_to_bounded_text():
    adapted = ComponentAdapter.adapt_terminal_surface(PANEL_STATE, _profile("mobile"))
    assert "code" not in _types(adapted)
    texts = [node["content"] for node in _walk(adapted[2])
             if node.get("type") == "text"]
    assert any("$ ls" in content for content in texts)


def test_prebuilt_components_are_validated_against_the_device_disposition():
    interactive = [
        {"type": "button", "label": "Send interrupt", "action": "chrome_terminal_interrupt",
         "payload": {"surface": "terminal", "session_id": "term_01JABCDEF"}},
    ]
    adapted = ComponentAdapter.adapt_terminal_surface(
        {"components": interactive}, _profile("windows"))
    assert _types(adapted) == ["button"]
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        ComponentAdapter.adapt_terminal_surface({"components": interactive}, _profile("android"))


def test_validator_refuses_malformed_interactive_payloads():
    identity = {"surface": "terminal", "session_id": "term_01JABCDEF"}
    refused = [
        {"type": "button", "label": "x", "action": "chrome_terminal_interrupt",
         "payload": {"surface": "terminal", "session_id": "term_01JABCDEF", "extra": 1}},
        {"type": "button", "label": "x", "action": "chrome_terminal_interrupt",
         "payload": {"surface": "other", "session_id": "term_01JABCDEF"}},
        {"type": "button", "label": "x", "action": "chrome_terminal_interrupt",
         "payload": {"surface": "terminal", "session_id": "bad session id"}},
        {"type": "button", "label": "x", "action": "chrome_terminal_interrupt",
         "payload": {"surface": "terminal"}},
        {"type": "button", "label": "x", "action": "chrome_terminal_resize", "payload": {
            "surface": "terminal", "session_id": "term_01JABCDEF",
            "cols": 0, "rows": 24}},
        {"type": "button", "label": "x", "action": "chrome_terminal_resize", "payload": {
            "surface": "terminal", "session_id": "term_01JABCDEF",
            "cols": 1001, "rows": 24}},
        {"type": "button", "label": "x", "action": "chrome_terminal_resize", "payload": {
            "surface": "terminal", "session_id": "term_01JABCDEF",
            "cols": True, "rows": 24}},
        {"type": "button", "label": "x", "action": "chrome_terminal_unknown",
         "payload": identity},
        {"type": "button", "label": "x", "action": "chrome_terminal_close",
         "payload": identity, "local": True},
        {"type": "button", "label": "x", "action": "chrome_open",
         "payload": {"surface": "terminal", "params": {"mode": "panel"}}},
        {"type": "button", "label": "x", "action": "chrome_open",
         "payload": {"surface": "terminal", "params": {"mode": "monitor", "session_id": "t"}}},
        {"type": "button", "label": "x", "action": "chrome_open",
         "payload": {"surface": "terminal", "params": {"mode": "list", "offset": -1}}},
        {"type": "button", "label": "x", "action": "chrome_open",
         "payload": {"surface": "terminal", "params": {"mode": "list"}, "extra": 1}},
        {"type": "button", "label": "x", "action": "chrome_close", "payload": {"surface": "mesh"}},
    ]
    for node in refused:
        with pytest.raises(ValueError, match="terminal_surface_unavailable"):
            validate_terminal_components([node], interactive=True)


def test_validator_refuses_malformed_forms_and_content():
    identity = {"surface": "terminal", "session_id": "term_01JABCDEF"}
    refused = [
        {"type": "param_picker", "fields": [{"name": "data", "label": "d", "kind": "password"}],
         "submit_action": "chrome_terminal_input", "submit_payload": identity},
        {"type": "param_picker", "fields": [{"name": "data", "label": "d", "kind": "password"}],
         "submit_action": "chrome_terminal_input", "submit_payload": identity},
        {"type": "param_picker", "fields": [{"name": "data", "label": "d", "kind": "text"}],
         "submit_action": "chrome_terminal_input",
         "submit_payload": {**identity, "fields": {}}},
        {"type": "param_picker", "fields": [{"name": "data", "label": "d", "kind": "text"}],
         "submit_action": "chrome_terminal_input",
         "submit_payload": {**identity, "session_id": "bad id"}},
        {"type": "param_picker",
         "fields": [{"name": "cols", "label": "c", "kind": "number", "default": 1},
                    {"name": "rows", "label": "r", "kind": "number", "default": 24}],
         "submit_action": "chrome_terminal_resize", "submit_payload": identity},
        {"type": "param_picker", "fields": [{"name": "cols", "label": "c", "kind": "number"}],
         "submit_action": "chrome_terminal_resize", "submit_payload": identity},
        {"type": "code", "code": "escape\x1b[31m"},
        {"type": "code", "code": "null\x00byte"},
        {"type": "code", "code": "x" * 70000},
        {"type": "text", "content": 12},
        {"type": "card", "title": "x", "content": [{"type": "text", "href": "https://x"}]},
        {"type": "table"},
        [{"type": "text", "content": "deep"}],
        {"type": "button", "label": "x", "action": "chrome_open",
         "payload": {"surface": "terminal", "params": {"mode": "list", "session_id": None}}},
    ]
    for node in refused:
        with pytest.raises(ValueError, match="terminal_surface_unavailable"):
            validate_terminal_components([node], interactive=True)


def test_validator_enforces_structure_bounds_and_supported_types():
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components("not a list", interactive=True)
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components([{"type": "badge", "label": "x"}],
                                     supported_types={"card"}, interactive=True)
    deep = {"type": "card", "title": "t", "content": []}
    cursor = deep
    for _ in range(10):
        cursor["content"] = [{"type": "card", "title": "t", "content": []}]
        cursor = cursor["content"][0]
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components([deep], interactive=True)
    watch_refused = [
        {"type": "badge", "label": "Running", "variant": "info"},
        {"type": "text", "content": "handoff"},
    ]
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components(watch_refused, watch=True)
    assert validate_terminal_components(
        [{"type": "badge", "label": "Running", "variant": "info"}], watch=True)


def test_validator_accepts_the_exact_offered_interactive_vocabulary():
    identity = {"surface": "terminal", "session_id": "term_01JABCDEF"}
    allowed = [
        {"type": "button", "label": "Interrupt", "action": "chrome_terminal_interrupt",
         "payload": dict(identity)},
        {"type": "button", "label": "Close session", "action": "chrome_terminal_close",
         "payload": dict(identity)},
        {"type": "button", "label": "Back", "action": "chrome_open",
         "payload": {"surface": "terminal", "params": {"mode": "list"}}},
        {"type": "button", "label": "Panel", "action": "chrome_open",
         "payload": {"surface": "terminal",
                     "params": {"mode": "panel", "session_id": "term_01JABCDEF", "offset": 12}}},
        {"type": "param_picker", "fields": [{"name": "data", "label": "d", "kind": "text"}],
         "submit_action": "chrome_terminal_input", "submit_payload": dict(identity)},
        {"type": "param_picker",
         "fields": [{"name": "cols", "label": "c", "kind": "number", "default": 80},
                    {"name": "rows", "label": "r", "kind": "number", "default": 24}],
         "submit_action": "chrome_terminal_resize", "submit_payload": dict(identity)},
        {"type": "code", "code": "literal output\n"},
    ]
    assert validate_terminal_components(allowed, interactive=True) == allowed


def test_prebuilt_component_lists_pass_through_and_package_exports_resolve():
    from astralprojection import chrome

    passthrough = [{"type": "badge", "label": "Running", "variant": "info"}]
    adapted = ComponentAdapter.adapt_terminal_surface(passthrough, _profile("windows"))
    assert _types(adapted) == ["badge"]
    assert chrome.build_terminal_view is not None
    assert chrome.build_terminal_panel_view is chrome.build_terminal_view
    assert chrome.sanitize_terminal_output("a\x1b[31mb") == "ab"
    assert chrome.code_block("x").to_dict()["type"] == "code"
    import pytest as _pytest

    with _pytest.raises(AttributeError):
        chrome.not_a_real_export


def test_validator_covers_the_remaining_closed_branches():
    identity = {"surface": "terminal", "session_id": "term_01JABCDEF"}
    refused = [
        {"type": "param_picker",
         "fields": [{"name": "data", "label": "d", "kind": "text", "default": "bad\nline",
                     "extra": 1}],
         "submit_action": "chrome_terminal_input", "submit_payload": identity},
        {"type": "param_picker",
         "fields": [{"name": "data", "label": "d", "kind": "text", "default": "x" * 513}],
         "submit_action": "chrome_terminal_input", "submit_payload": identity},
        {"type": "param_picker",
         "fields": [{"name": "data", "label": "d", "kind": "text", "default": "ok"}],
         "submit_action": "chrome_terminal_input",
         "submit_payload": {"surface": "other", "session_id": "term_01JABCDEF"}},
        {"type": "param_picker", "fields": [],
         "submit_action": "chrome_terminal_unknown", "submit_payload": identity},
        {"type": "button", "label": "x", "action": "chrome_open",
         "payload": {"surface": "mesh", "params": {}}},
        {"type": "button", "label": "x", "action": "chrome_open",
         "payload": {"surface": "terminal", "params": "not a mapping"}},
        {"type": "button", "label": "x", "action": "chrome_open",
         "payload": {"surface": "terminal", "params": {"mode": "list", "scope": 1}}},
        {"type": "button", "label": "x", "action": "chrome_close", "payload": 12},
        {"type": "button", "label": "x", "action": "chrome_close",
         "payload": {"surface": "terminal", "unexpected": 1}},
    ]
    for node in refused:
        with pytest.raises(ValueError, match="terminal_surface_unavailable"):
            validate_terminal_components([node], interactive=True)
    allowed = [
        {"type": "button", "label": "Close panel", "action": "chrome_close", "payload": {}},
        {"type": "button", "label": "Close panel", "action": "chrome_close",
         "payload": {"surface": "terminal"}},
        {"type": "button", "label": "List", "action": "chrome_open",
         "payload": {"surface": "terminal", "params": {"mode": "list"}}},
        {"type": "param_picker",
         "fields": [{"name": "data", "label": "d", "kind": "text", "default": "ok"}],
         "submit_action": "chrome_terminal_input", "submit_payload": dict(identity)},
    ]
    assert validate_terminal_components(allowed, interactive=True) == allowed


def test_validator_refuses_form_action_lists_bad_fields_and_oversized_trees():
    identity = {"surface": "terminal", "session_id": "term_01JABCDEF"}
    refused = [
        {"type": "param_picker",
         "fields": [{"name": "data", "label": "d", "kind": "text"}],
         "actions": [{"action": "chrome_terminal_close", "label": "x", "payload": identity}],
         "submit_action": "chrome_terminal_input", "submit_payload": identity},
        {"type": "param_picker",
         "fields": [{"name": "cols", "label": "c", "kind": "number"},
                    {"name": "rows", "label": "r", "kind": "number"}],
         "actions": [{"action": "chrome_terminal_close", "label": "x", "payload": identity}],
         "submit_action": "chrome_terminal_resize", "submit_payload": identity},
        {"type": "param_picker",
         "fields": [{"name": "cols", "label": "c", "kind": "number"}, "bad"],
         "submit_action": "chrome_terminal_resize", "submit_payload": identity},
    ]
    for node in refused:
        with pytest.raises(ValueError, match="terminal_surface_unavailable"):
            validate_terminal_components([node], interactive=True)
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components([{"type": "param_picker", "fields": []}], interactive=False)
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components(
            [{"type": "card", "title": "t", "content": ["not a node"]}], interactive=True)
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components([{"type": "code", "code": "x" * 1048576}], interactive=True)
