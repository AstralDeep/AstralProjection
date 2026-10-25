"""Checks terminal monitor ROTE dispositions, native adaptation and the read-only action fence.
Unsupported or hostile controls fail closed before any renderer receives them.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile
from rote.terminal import (
    OMITTED,
    READ_ONLY_MONITOR,
    WATCH_HANDOFF,
    contract_dispositions,
    terminal_disposition,
    validate_terminal_components,
)

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = json.loads((ROOT / "contracts/ui_protocol.json").read_text(encoding="utf-8"))
FIXTURE = json.loads((ROOT / "contracts/fixtures/terminal/monitor_surface.json").read_text(encoding="utf-8"))
CONTRACT = MANIFEST["presentation_contracts"]["terminal_monitor"]
TYPES = ["text", "alert", "badge", "button", "card", "keyvalue", "code"]
WATCH_TYPES = ["text", "alert", "badge", "card", "keyvalue"]


def profile(device, supported=TYPES):
    return DeviceProfile.from_dict({
        "device_type": device,
        "supported_types": supported,
        "console_contract": "console/v2",
    })


def buttons(nodes, found=None):
    found = [] if found is None else found
    for node in nodes:
        if node.get("type") == "button":
            found.append(node)
        for key in ("content", "children"):
            if isinstance(node.get(key), list):
                buttons(node[key], found)
    return found


@pytest.mark.parametrize("device", ["browser", "windows", "android", "ios", "macos", "tablet"])
def test_each_supported_client_gets_the_complete_read_only_monitor(device):
    expected = FIXTURE["frames"]["monitor"]["components"]
    assert ComponentAdapter.adapt_terminal_surface(
        FIXTURE["states"]["monitor"], profile(device)
    ) == expected


def test_code_unsupported_client_retains_literal_output_as_text():
    adapted = ComponentAdapter.adapt_terminal_surface(
        FIXTURE["states"]["monitor"], profile("mobile")
    )
    card = next(node for node in adapted if node.get("title") == "Output")
    assert card["content"][0]["type"] == "text"
    assert "hello" in card["content"][0]["content"]
    assert "" not in card["content"][0]["content"]


def test_dispositions_are_closed_and_match_the_contract():
    assert contract_dispositions(monitor=True) == CONTRACT["dispositions"]
    for device in ("browser", "windows", "android", "ios", "macos", "tablet", "mobile"):
        assert terminal_disposition(profile(device), monitor=True) == READ_ONLY_MONITOR
    assert terminal_disposition(profile("watch", WATCH_TYPES)) == WATCH_HANDOFF
    assert terminal_disposition(profile("voice", [])) == OMITTED
    assert terminal_disposition("unknown") == OMITTED


def test_watch_gets_content_free_metadata_and_handoff_without_actions_or_output():
    adapted = ComponentAdapter.adapt_terminal_surface(
        FIXTURE["states"]["monitor"], profile("watch", WATCH_TYPES)
    )
    assert adapted == FIXTURE["watch_components"]
    assert [node["type"] for node in adapted] == ["badge", "alert"]
    assert not buttons(adapted)
    serialized = json.dumps(adapted)
    for private in ("term_01JABCDEF", "ops@staging.example", "/srv/astral/work", "hello"):
        assert private not in serialized
    assert any("phone or desktop" in node.get("message", "") for node in adapted)


def test_voice_is_omitted_and_missing_scoped_types_fail_closed():
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        ComponentAdapter.adapt_terminal_surface(
            FIXTURE["states"]["monitor"], profile("voice", [])
        )
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        ComponentAdapter.adapt_terminal_surface(
            FIXTURE["states"]["monitor"],
            profile("android", ["text", "alert", "badge", "button", "card", "keyvalue"]),
        )
    listed = ComponentAdapter.adapt_terminal_surface(
        FIXTURE["states"]["list"],
        profile("android", ["text", "alert", "badge", "button", "card", "keyvalue"]),
    )
    assert [node["type"] for node in listed] == ["card", "card", "button", "button"]


@pytest.mark.parametrize("mutation", [
    lambda rows: rows.append({"type": "param_picker", "fields": []}),
    lambda rows: rows.append({"type": "input", "name": "command"}),
    lambda rows: rows.append({"type": "text", "content": "x", "href": "https://evil.example"}),
    lambda rows: buttons(rows)[0].update({"action": "terminal_write"}),
    lambda rows: buttons(rows)[0].update({"local": True}),
    lambda rows: buttons(rows)[0]["payload"]["params"].update({"data": "rm -rf /"}),
    lambda rows: buttons(rows)[0]["payload"].update({"surface": "work"}),
    lambda rows: buttons(rows)[0].update({"action": "chrome_open", "payload": {
        "surface": "terminal", "params": {"mode": "monitor"}}}),
    lambda rows: buttons(rows)[0].update({"action": "chrome_close", "payload": {
        "surface": "terminal", "session_id": "term_01JABCDEF"}}),
    lambda rows: rows[0].update({"type": "code", "code": "\x1b]52;c;secret"}),
])
def test_hostile_or_interactive_controls_are_refused(mutation):
    rows = copy.deepcopy(FIXTURE["frames"]["monitor"]["components"])
    mutation(rows)
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components(rows, frozenset(TYPES))


def test_depth_node_and_payload_bounds_are_refused():
    nested = {"type": "text", "content": "leaf"}
    for _ in range(10):
        nested = {"type": "card", "title": "nested", "content": [nested]}
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components([nested], frozenset(TYPES))
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components(
            [{"type": "text", "content": "x"}] * 1025, frozenset(TYPES)
        )
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components(
            [{"type": "code", "code": "x" * 65537}], frozenset(TYPES)
        )


def test_prebuilt_and_mapping_inputs_are_supported_and_not_mutated():
    components = copy.deepcopy(FIXTURE["frames"]["monitor"]["components"])
    original = copy.deepcopy(components)
    assert ComponentAdapter.adapt_terminal_surface(components, profile("ios")) == components
    assert components == original
    wrapped = {"components": components}
    assert ComponentAdapter.adapt_terminal_surface(wrapped, profile("ios")) == components
    assert wrapped["components"] == original

def test_validator_covers_invalid_modes_offsets_types_and_oversized_trees():
    components = copy.deepcopy(FIXTURE["frames"]["monitor"]["components"])
    for params in (
        {"mode": "write", "session_id": "term_01JABCDEF"},
        {"mode": "monitor", "session_id": "bad id"},
        {"mode": "monitor", "session_id": "term_01JABCDEF", "offset": True},
        {"mode": "monitor", "session_id": "term_01JABCDEF", "offset": -1},
        {"mode": "monitor", "session_id": "term_01JABCDEF", "offset": 9007199254740992},
    ):
        changed = copy.deepcopy(components)
        buttons(changed)[0]["payload"]["params"] = params
        with pytest.raises(ValueError, match="terminal_surface_unavailable"):
            validate_terminal_components(changed, frozenset(TYPES))
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components("not a list", frozenset(TYPES))
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components([None], frozenset(TYPES))
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components([{"type": "text", "content": 3}], frozenset(TYPES))
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components([{"type": "card", "content": 3}], frozenset(TYPES))
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components(
            [{"type": "button", "action": "chrome_close"}], frozenset(TYPES)
        )
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components(
            [{"type": "button", "action": "chrome_close", "payload": {"surface": "terminal"}, "local": True}],
            frozenset(TYPES),
        )
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components(
            [{"type": "button", "action": "chrome_close", "payload": {"surface": "work"}}],
            frozenset(TYPES),
        )
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components(
            [{"type": "button", "action": "chrome_open", "payload": {"surface": "terminal", "params": {"mode": "list"}, "extra": 1}}],
            frozenset(TYPES),
        )
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components(
            [{"type": "button", "action": "chrome_open", "payload": {"surface": "terminal", "params": {"mode": "monitor"}}}],
            frozenset(TYPES),
        )
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components(
            [{"type": "button", "action": "chrome_open", "payload": {"surface": "work", "params": {"mode": "list"}}}],
            frozenset(TYPES),
        )
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components(
            [{"type": "button", "action": "chrome_close", "payload": {"surface": "terminal"}}],
            frozenset(TYPES),
            watch=True,
        )
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components(
            [{"type": "code", "code": "safe"}], frozenset(TYPES), watch=True
        )
    assert validate_terminal_components(
        [{"type": "button", "action": "chrome_close", "payload": {}}], frozenset(TYPES)
    ) == [{"type": "button", "action": "chrome_close", "payload": {}}]
    assert validate_terminal_components(
        [{"type": "text", "content": "list scoped"}], TYPES
    ) == [{"type": "text", "content": "list scoped"}]
    assert validate_terminal_components(
        [{"type": "button", "action": "chrome_open", "payload": {
            "surface": "terminal", "params": {"mode": "list"}}}], frozenset(TYPES)
    )
    assert validate_terminal_components(
        [{"type": "button", "action": "chrome_close", "payload": {"surface": None}}], frozenset(TYPES)
    )
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components(
            [{"type": "text", "content": "x" * 10000} for _ in range(105)], frozenset(TYPES)
        )
