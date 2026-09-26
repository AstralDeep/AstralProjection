"""Checks the shared console vocabulary, bounded catalog and chrome action placement.
The host supplies account-filtered data; this model never adds authority.
"""

from copy import deepcopy

import pytest

from webrender.chrome.console_model import build_console_model, render_console_labels
from webrender.chrome.menu_model import menu_model_dict


def catalog():
    return {
        "categories": ["Utilities"],
        "scenarios": [{"id": "dice", "title": "Roll dice", "description": "Six rolls",
                       "prompt": "Roll six dice", "category": "Utilities"}],
        "agents": [{"id": "dice", "name": "Dice Roller", "description": "Rolls dice",
                    "state": "ready", "owned": True}],
    }


def model(**flags):
    menu = menu_model_dict(include_admin=False, include_tour=False, **flags)
    return build_console_model(catalog(), menu, {"name": "Operator", "role": "Member",
                                                "initials": "O"})


def test_console_contains_shared_catalog_identity_and_ordered_actions():
    console = model(pulse_enabled=True, work_enabled=True)
    assert console["version"] == 2
    assert console["catalog"] == catalog()
    assert console["identity"] == {"name": "Operator", "role": "Member", "initials": "O"}
    assert [item["key"] for item in console["composer_actions"]] == [
        "background", "advanced", "timeline", "pulse", "work"]
    advanced = console["composer_actions"][1]
    assert advanced["action"] == {"surface": "guidance", "params": {"view": "selection"}}
    assert console["labels"]["title"] == "AstralDeep Console"
    assert console["show_voice_availability_banner"] is False


def test_unavailable_actions_are_omitted_and_inputs_are_not_mutated():
    source = catalog()
    original = deepcopy(source)
    menu = menu_model_dict(include_admin=False, include_tour=False)
    console = build_console_model(source, menu, {})
    assert [item["key"] for item in console["composer_actions"]] == [
        "background", "advanced", "timeline"]
    assert source == original
    console["catalog"]["agents"][0]["name"] = "Changed"
    assert source == original
    assert console["identity"] == {"name": "Signed in", "role": "Member", "initials": "A"}
    assert "console" not in menu


@pytest.mark.parametrize("key", ["scenarios", "agents", "categories"])
@pytest.mark.parametrize("bad", [None, {}, "text", [None]])
def test_malformed_catalog_fails_closed(key, bad):
    source = catalog()
    source[key] = bad
    with pytest.raises(ValueError):
        build_console_model(source, {}, {})


@pytest.mark.parametrize("mutate", [
    lambda c: c["agents"].append(c["agents"][0]),
    lambda c: c["scenarios"].append(c["scenarios"][0]),
    lambda c: c["categories"].append("Utilities"),
    lambda c: c["scenarios"][0].update(prompt="x" * 8001),
    lambda c: c["scenarios"][0].update(category="unknown"),
    lambda c: c["agents"][0].update(state="unknown"),
    lambda c: c["agents"][0].update(owned="yes"),
    lambda c: c["agents"][0].update(id=""),
    lambda c: c.update(agents=c["agents"] * 61),
    lambda c: c.update(scenarios=c["scenarios"] * 65),
    lambda c: c.update(categories=c["categories"] * 17),
])
def test_invalid_or_unbounded_catalog_fails_closed(mutate):
    source = catalog()
    mutate(source)
    with pytest.raises(ValueError):
        build_console_model(source, {}, {})


def test_identity_is_display_only_bounded_and_has_no_private_claims():
    console = build_console_model(catalog(), {}, {
        "name": "x" * 200, "role": None, "initials": 42, "email": "private@example.com"})
    assert console["identity"] == {"name": "x" * 120, "role": "Member", "initials": "A"}


def test_shell_labels_share_console_vocabulary_without_changing_other_tokens():
    result = render_console_labels("%%CONSOLE:title%% / %%CONSOLE:search_agents%% / %%ASTRAL_NONCE%%")
    assert result == "AstralDeep Console / Search agents / %%ASTRAL_NONCE%%"


def test_empty_catalog_and_missing_optional_agent_fields_are_valid():
    assert build_console_model({"categories": [], "scenarios": [], "agents": []}, {}, {})["catalog"] == {
        "categories": [], "scenarios": [], "agents": []}
    source = catalog()
    del source["agents"][0]["description"]
    del source["agents"][0]["owned"]
    value = build_console_model(source, {}, {})["catalog"]["agents"][0]
    assert value["description"] == "" and value["owned"] is False
