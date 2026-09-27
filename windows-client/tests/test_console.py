"""Exercises the native decoder against shared fixtures and malformed server data.
Copies and strict bounds keep shell state isolated from incoming frames.
"""

import copy
import json
from pathlib import Path

import pytest

from astral_client.console import (
    parse_console_model,
    parse_console_presentation,
    parse_turn_selection,
)


FIXTURES = Path(__file__).parents[2] / "contracts" / "fixtures" / "console"


def model():
    return json.loads((FIXTURES / "chrome-console.json").read_text())["console"]


def presentation():
    return json.loads((FIXTURES / "rote-console.json").read_text())["cases"][0]["presentation"]


def selection():
    return {"version": 1, "agent": {"agent_id": "dice",
            "revision_id": "3c4d5e6f-7a8b-4c9d-8e1f-2a3b4c5d6e09"},
            "skills": [{"skill_id": "0d9c2f9a-3e5b-4c7d-8a1f-6b2e4d8c0a13", "revision": 4}],
            "notes": [{"note_id": "8b9c0d1e-2f3a-4b4c-9d6e-7f8a9b0c1d54", "revision": 9}]}


def set_at(value, path, replacement):
    parts = path.split(".")
    for part in parts[:-1]:
        value = value[int(part)] if isinstance(value, list) else value[part]
    key = int(parts[-1]) if isinstance(value, list) else parts[-1]
    value[key] = replacement


def test_shared_model_preserves_data_and_is_detached():
    source = model()
    parsed = parse_console_model(source)
    assert parsed == source
    source["catalog"]["scenarios"][0]["prompt"] = "changed"
    source["composer_actions"][1]["action"]["params"]["view"] = "changed"
    assert parsed == model()


@pytest.mark.parametrize("path,value", [
    ("version", True), ("version", 3), ("labels", []), ("labels", {}),
    ("labels.brand", ""), ("labels.brand", "A\x00B"), ("labels.brand", "a" * 501),
    ("identity", None), ("identity.name", "a" * 121), ("identity.role", 7),
    ("catalog", []), ("catalog.categories", "All"),
    ("catalog.categories", ["a"] * 17), ("catalog.categories", ["a", "a"]),
    ("catalog.scenarios.0", None), ("catalog.scenarios.0.category", "unknown"),
    ("catalog.scenarios.0.prompt", "a" * 8001), ("catalog.agents.0.state", "ready-ish"),
    ("catalog.agents.0.owned", 1), ("composer_actions", {}),
    ("composer_actions.0.key", "unknown"), ("composer_actions.0.kind", "script"),
    ("composer_actions.1.action", []), ("composer_actions.1.action.surface", "../secret"),
    ("composer_actions.1.action.params", []),
    ("composer_actions.1.action.params", {"x": "a" * 16384}),
    ("composer_actions.1.action.params", {"x": float("nan")}),
    ("show_voice_availability_banner", True), ("show_voice_availability_banner", 0),
])
def test_invalid_model_is_rejected(path, value):
    source = model()
    set_at(source, path, value)
    assert parse_console_model(source) is None


@pytest.mark.parametrize("key", ["scenarios", "agents"])
def test_duplicate_catalog_identity_rejected(key):
    source = model()
    source["catalog"][key].append(copy.deepcopy(source["catalog"][key][0]))
    assert parse_console_model(source) is None


def test_duplicate_actions_and_unknown_toggle_target_rejected():
    source = model()
    source["composer_actions"].append(copy.deepcopy(source["composer_actions"][0]))
    assert parse_console_model(source) is None
    source = model()
    source["composer_actions"][0]["action"] = {}
    assert parse_console_model(source) is None


def test_oversized_labels_and_deep_parameters_rejected():
    source = model()
    source["labels"].update({str(i): "label" for i in range(65)})
    assert parse_console_model(source) is None
    source = model()
    recursive = {}
    recursive["self"] = recursive
    source["composer_actions"][1]["action"]["params"] = recursive
    assert parse_console_model(source) is None


def test_empty_catalog_is_valid_and_untrusted_text_is_not_markup():
    source = model()
    source["catalog"] = {"categories": [], "scenarios": [], "agents": []}
    source["identity"]["name"] = "<b>user</b>"
    assert parse_console_model(source) == source


@pytest.mark.parametrize("case", json.loads((FIXTURES / "rote-console.json").read_text())["cases"])
def test_shared_geometry_is_not_recomputed(case):
    source = case["presentation"]
    assert parse_console_presentation(source) == source


@pytest.mark.parametrize("path,value", [
    ("version", 2.0), ("navigation_mode", "unknown"), ("navigation_mode", "stack"),
    ("sidebar_width", 0), ("sidebar_width", True), ("sidebar_width", -1),
    ("settings_presentation", "unknown"), ("settings_navigation_axis", "unknown"),
    ("settings_width", float("inf")), ("dialog_width", 0),
    ("settings_max_height", 0), ("scenario_columns", 1.5), ("scenario_columns", 65),
    ("scenario_columns", float("nan")), ("content_padding", None),
    ("content_padding.left", 16385), ("composer_padding.top", None),
])
def test_invalid_geometry_is_rejected(path, value):
    source = presentation()
    set_at(source, path, value)
    assert parse_console_presentation(source) is None


def test_stack_geometry_can_be_parsed_without_windows_policy():
    source = presentation()
    source.update(navigation_mode="stack", sidebar_width=0, settings_presentation="push")
    assert parse_console_presentation(source) == source


def test_exact_selection_preserved_and_detached():
    source = selection()
    parsed = parse_turn_selection(source)
    assert parsed == source
    source["notes"].clear()
    assert parsed == selection()
    empty = {"version": 1, "agent": None, "skills": [], "notes": []}
    assert parse_turn_selection(empty) == empty


@pytest.mark.parametrize("path,value", [
    ("version", True), ("version", 2), ("agent", []), ("agent", {}),
    ("agent.agent_id", " dice"), ("agent.agent_id", "a" * 256),
    ("agent.revision_id", 1), ("agent.revision_id", "not-a-uuid"),
    ("agent.revision_id", "00000000-0000-1000-8000-000000000001"),
    ("skills", [None]), ("skills", [{}]), ("skills.0.revision", 1.1),
    ("skills.0.revision", 0), ("skills.0.revision", True),
    ("notes.0.revision", 9007199254740992), ("notes.0.note_id", None),
])
def test_invalid_selection_rejected(path, value):
    source = selection()
    set_at(source, path, value)
    assert parse_turn_selection(source) is None


def test_selection_rejects_unknown_fields_duplicates_and_oversize():
    source = selection()
    source["owner"] = "other"
    assert parse_turn_selection(source) is None
    source = selection()
    source["skills"].append(copy.deepcopy(source["skills"][0]))
    assert parse_turn_selection(source) is None
    source["skills"] *= 11
    assert parse_turn_selection(source) is None


@pytest.mark.parametrize("value", [None, [], "console/v2", True, 2])
def test_non_objects_fail_closed(value):
    assert parse_console_model(value) is None
    assert parse_console_presentation(value) is None
    assert parse_turn_selection(value) is None
