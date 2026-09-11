"""Host-gated native agent settings use ordinary chrome actions."""

import json

import pytest

from astralprojection.chrome.agents import build_agents_view


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


@pytest.mark.parametrize("visibility,safe", [(False, False), (True, False), (False, True), (True, True)])
def test_personal_configuration_is_independent_of_agent_ownership(visibility, safe):
    result = build_agents_view(
        selected={"id": "a", "name": "A"},
        can_configure=True,
        can_set_visibility=visibility,
        can_set_safe=safe,
        permissions=[{"field_name": "lookup::read", "tool_name": "lookup", "scope": "read"}],
        credentials=[{"key": "TOKEN", "stored": True, "value": "must-not-render"}],
    ).to_dict()
    nodes = list(walk(result))
    actions = {node.get("action") or node.get("submit_action") for node in nodes}
    assert {"chrome_perms_save", "chrome_credentials_save", "chrome_credential_delete"} <= actions
    assert ("chrome_visibility_set" in actions) is visibility
    assert ("chrome_safe_set" in actions) is safe
    assert "must-not-render" not in json.dumps(result)
    assert all("default" not in node for node in nodes if node.get("kind") == "password")


def test_permission_masters_and_unconfigurable_tools_preserve_host_snapshots():
    condition = {"field": "__scope::read", "equals": True, "default": False}
    result = build_agents_view(
        selected={"id": "a"}, can_configure=True,
        permissions=[
            {"field_name": "__scope::read", "label": "Enable all read tools", "enabled": False},
            {"field_name": "lookup::read", "tool_name": "lookup", "scope": "read",
             "enabled": False, "visible_when": condition},
            {"tool_name": "custom", "scope": "custom", "description": "A visible unconfigurable tool"},
        ],
    ).to_dict()
    fields = {node["name"]: node for node in walk(result) if "kind" in node and "name" in node}
    assert fields["__scope::read"]["label"] == "Enable all read tools"
    assert fields["lookup::read"]["visible_when"] == condition
    assert fields["lookup::read"]["default"] is False
    assert "custom — Not configurable" in json.dumps(result, ensure_ascii=False)
    assert "__scope::custom" not in json.dumps(result)


def test_unconfigurable_tools_remain_named_when_no_permission_fields_exist():
    result = build_agents_view(selected={"id": "a"}, can_configure=True,
                               permissions=[{"tool_name": "custom"}]).to_dict()
    assert "custom" in json.dumps(result)
    assert "chrome_perms_save" not in json.dumps(result)


@pytest.mark.parametrize("identity,expected", [
    ({"provider": "orcid", "subject": "0000-test"}, "Connected: 0000-test"),
    ({"provider": "orcid"}, "Connect ORCID in the web client"),
    ({"provider": "orcid", "url": "/api/agents/a/external-identities/orcid/start"}, "Connect ORCID"),
])
def test_external_identity_has_verified_state_or_explicit_handoff(identity, expected):
    result = build_agents_view(selected={"id": "a", "external_identity": identity},
                               can_configure=True).to_dict()
    assert expected in json.dumps(result)
    assert "chrome_safe_set" not in json.dumps(result)


def test_unknown_external_identity_does_not_create_controls():
    result = build_agents_view(selected={"id": "a", "external_identity": {"provider": "unknown"}},
                               can_configure=True).to_dict()
    assert "ORCID" not in json.dumps(result)


def test_explicit_host_denials_override_legacy_manage_flag():
    result = build_agents_view(selected={"id": "a"}, can_manage=True,
                               can_configure=False, can_set_visibility=False, can_set_safe=False).to_dict()
    assert "chrome_perms_save" not in json.dumps(result)
    assert "chrome_visibility_set" not in json.dumps(result)
    assert "chrome_safe_set" not in json.dumps(result)
