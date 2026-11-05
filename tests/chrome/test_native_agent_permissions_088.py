"""Tests for src/astralprojection/chrome/agents.py: native agent-permission rendering
and host-gated denials.
"""

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


@pytest.mark.parametrize("kind,agent_id,name,title,notice_key", [
    ("standard_mcp", "remote-mcp-1", "Remote MCP", "Standard MCP connection", "external_mcp_security"),
    ("standard_a2a", "imported-a2a-1", "External peer", "Standard A2A connection", "external_a2a_security"),
])
def test_standard_connection_warning_is_a_separate_accessible_action_in_list_and_detail(
    kind, agent_id, name, title, notice_key,
):
    agent = {"id": agent_id, "name": name, "connection_security": {
        "kind": kind, "title": title,
        "message": "Astral permissions still apply. The provider controls its data handling.",
    }}
    for view in (build_agents_view([agent]), build_agents_view(selected=agent)):
        nodes = list(walk(view.to_dict()))
        warning = next(node for node in nodes if node.get("id") == f"agent-security-warning-{agent_id}")
        assert warning["type"] == "button" and warning["label"] == "⚠"
        assert warning["aria-label"] == title
        assert warning["action"] == "chrome_open"
        assert warning["payload"] == {"surface": "remote_mcp", "params": {"notice": notice_key}}
        assert any(node.get("content") == name for node in nodes)


@pytest.mark.parametrize("agent", [
    {"id": "panatlas-1", "name": "PanAtlas", "url": "https://panatlas.net/agent"},
    {"id": "legacy", "url": "https://example.test/mcp"},
    {"id": "legacy", "url": "https://example.test/agent"},
    {"id": "legacy", "metadata": {"connection_security": {"kind": "standard_mcp"}}},
    {"id": "legacy", "metadata": {"connection_security": {"kind": "standard_a2a"}}},
    {"id": "imported-a2a-1", "connection_security": {"kind": "standard_a2a", "title": "A2A", "message": 5}},
    {"id": "remote-mcp-1", "connection_security": {"kind": "unknown", "title": "Warning", "message": "Text"}},
    {"id": "remote-mcp-1", "connection_security": {"kind": "standard_mcp", "title": "", "message": "Text"}},
    {"id": "remote-mcp-1", "connection_security": {"kind": "standard_mcp", "title": "x" * 121, "message": "Text"}},
    {"id": "remote-mcp-1", "connection_security": {"kind": "standard_mcp", "title": "Warning", "message": "x" * 2001}},
    {"id": "remote-mcp-1", "connection_security": {"kind": "standard_mcp", "title": "Warning", "message": "unsafe\0text"}},
])
def test_native_or_malformed_agent_metadata_does_not_create_a_warning(agent):
    for view in (build_agents_view([agent]), build_agents_view(selected=agent)):
        assert not any(node.get("id", "").startswith("agent-security-warning-") for node in walk(view.to_dict()))
