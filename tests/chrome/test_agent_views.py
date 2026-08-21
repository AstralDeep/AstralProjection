from __future__ import annotations

from astralprojection.chrome import render_html
from astralprojection.chrome.agents import (
    build_agents_view,
    build_attachments_view,
    build_authoring_view,
    build_drafts_view,
)


def _actions(view) -> list[str]:
    found: list[str] = []

    def visit(value) -> None:
        if isinstance(value, dict):
            if isinstance(value.get("action"), str):
                found.append(value["action"])
            if isinstance(value.get("submit_action"), str):
                found.append(value["submit_action"])
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(view.to_dict())
    return found


def test_agent_lists_empty_populated_denied_and_error() -> None:
    assert "Agent access was denied" in render_html(build_agents_view(denied=True))
    assert _actions(build_agents_view(denied=True)) == []
    assert "Agent service offline" in render_html(build_agents_view(error="Agent service offline"))
    assert "own any agents" in render_html(build_agents_view())
    assert "No public agents" in render_html(build_agents_view(tab="public"))
    view = build_agents_view(
        [
            {
                "id": "agent-1",
                "name": "Research <script>",
                "description": "Finds evidence",
                "owned": True,
                "is_public": True,
                "disabled": False,
                "status": "connected",
            },
            {
                "agent_id": "agent-2",
                "name": "Offline",
                "description": "Unavailable",
                "disabled": True,
                "status": "offline",
            },
        ],
        tab="public",
    )
    html = render_html(view)
    assert "<script>" not in html
    assert "Yours" in html and "Public" in html and "Disabled by you" in html
    assert _actions(view).count("chrome_agent_enabled") == 2
    assert "chrome_open" in _actions(view)


def test_agent_detail_enforces_management_affordance_boundary() -> None:
    missing = build_agents_view(selected={})
    assert "Agent not found" in render_html(missing)
    agent = {
        "id": "agent-1",
        "name": "Writer",
        "description": "Writes safely",
        "owner_email": "owner@example.com",
        "owned": True,
        "is_public": False,
        "is_safe": False,
        "disabled": False,
    }
    readonly = build_agents_view(selected=agent, can_manage=False)
    readonly_actions = set(_actions(readonly))
    assert "chrome_agent_enabled" in readonly_actions
    assert "chrome_perms_save" not in readonly_actions
    assert "chrome_visibility_set" not in readonly_actions
    assert "Only the owner" in render_html(readonly)
    managed_empty = build_agents_view(selected=agent, can_manage=True)
    managed_html = render_html(managed_empty)
    assert "This agent exposes no tools" in managed_html
    assert "requires no user credentials" in managed_html
    assert {"chrome_visibility_set", "chrome_safe_set"} <= set(_actions(managed_empty))
    managed = build_agents_view(
        selected={**agent, "is_public": True, "is_safe": True, "disabled": True},
        can_manage=True,
        permissions=[
            {
                "field_name": "search_web::tools:search",
                "tool_name": "search_web",
                "scope": "tools:search",
                "enabled": True,
                "description": "Search the web",
                "destructive": "never",
            },
            {
                "field_name": "delete_file::tools:files",
                "tool_name": "delete_file",
                "scope": "tools:files",
                "enabled": False,
                "destructive": "always",
            },
            {"tool_name": "unconfigurable"},
        ],
        credentials=[
            {"key": "API_TOKEN", "label": "API token", "stored": True},
            {"key": "OPTIONAL", "optional": True, "stored": False},
            {"label": "invalid"},
        ],
    )
    actions = set(_actions(managed))
    assert {
        "chrome_perms_save",
        "chrome_visibility_set",
        "chrome_safe_set",
        "chrome_credentials_save",
        "chrome_credential_delete",
    } <= actions
    html = render_html(managed)
    assert "Sometimes destructive" not in html
    assert "always" in html
    assert "Make private" in html and "Unmark safe" in html
    assert "API_TOKEN" in html
    assert 'type="password"' in html


def test_agent_permissions_with_no_portable_fields_degrade_explicitly() -> None:
    view = build_agents_view(
        selected={"id": "a", "name": "Agent"},
        can_manage=True,
        permissions=[{"tool_name": "tool", "field_name": ""}],
    )
    assert "not configurable" in render_html(view)
    assert "chrome_perms_save" not in _actions(view)


def test_authoring_disabled_list_and_session_phases() -> None:
    disabled = build_authoring_view(enabled=False)
    assert "not enabled" in render_html(disabled)
    empty = build_authoring_view(host_online=False)
    empty_html = render_html(empty)
    assert "desktop host is offline" in empty_html
    assert "No agents yet" in empty_html
    assert "chrome_author_start" in _actions(empty)
    listing = build_authoring_view(
        agents=[
            {
                "id": "a1",
                "name": "Assistant",
                "status": "running",
                "revalidation_required": True,
            }
        ],
        sessions=[{"id": "d1", "agent_name": "Draft Agent", "phase": "plan"}],
    )
    assert {"chrome_author_revise", "chrome_author_delete", "chrome_open"} <= set(_actions(listing))
    assert "rules changed" in render_html(listing)
    assert "not available" in render_html(build_authoring_view(selected={}))
    not_checked = build_authoring_view(
        selected={"id": "d1", "agent_name": "Draft", "phase": "analyze", "state_revision": 2}
    )
    assert "Not checked yet" in render_html(not_checked)
    passed = build_authoring_view(
        selected={
            "id": "d1",
            "agent_name": "Draft",
            "phase": "analyze",
            "state_revision": 2,
            "analyze_passed": True,
        }
    )
    assert "Analyze passed" in render_html(passed)
    violations = build_authoring_view(
        selected={
            "id": "d1",
            "phase": "analyze",
            "violations": [{"plain_language": "Unsafe", "principle": "VII"}],
        }
    )
    assert "Unsafe" in render_html(violations)
    generate = build_authoring_view(selected={"id": "d1", "phase": "generate", "state_revision": 3})
    assert {"chrome_author_generate", "chrome_author_analyze"} <= set(_actions(generate))
    specify_empty = build_authoring_view(selected={"id": "d1", "phase": "specify"})
    assert "Nothing drafted yet" in render_html(specify_empty)
    specify = build_authoring_view(
        selected={
            "id": "d1",
            "phase": "specify",
            "state_revision": 4,
            "fields": [{"name": "purpose", "label": "Purpose", "kind": "textarea"}],
        }
    )
    assert {"chrome_author_edit", "chrome_author_advance", "chrome_author_draft"} <= set(
        _actions(specify)
    )
    clarify = build_authoring_view(
        selected={
            "id": "d1",
            "phase": "clarify",
            "fields": [{"name": "answer", "label": "Answer", "kind": "text"}],
        }
    )
    assert "chrome_author_clarify" in _actions(clarify)


def test_draft_list_detail_refinement_and_terminal_states() -> None:
    assert "Draft storage offline" in render_html(build_drafts_view(error="Draft storage offline"))
    empty = build_drafts_view()
    assert "No drafts yet" in render_html(empty)
    assert "chrome_draft_create" in _actions(empty)
    listing = build_drafts_view(
        [
            {
                "id": "d1",
                "agent_name": "Draft one",
                "origin": "auto_chat",
                "status": "pending_review",
                "self_test_status": "passed",
                "self_test_summary": "all checks",
            },
            {"id": "d2", "agent_name": "Draft two", "status": "error"},
        ]
    )
    assert "self-test passed" in render_html(listing)
    assert "not self-tested" in render_html(listing)
    missing = build_drafts_view(selected={})
    assert "Draft not found" in render_html(missing)
    live = build_drafts_view(
        selected={"id": "d1", "agent_name": "Live", "status": "live"},
        show_refine=True,
    )
    assert "manage it under Agents" in render_html(live)
    assert "draft_refine" not in _actions(live)
    draft = build_drafts_view(
        selected={
            "id": "d2",
            "agent_name": "Revision",
            "status": "rejected",
            "revises_agent_id": "a1",
            "error_message": "Needs work <unsafe>",
        },
        show_refine=True,
    )
    actions = set(_actions(draft))
    assert {"revision_apply", "revision_discard", "draft_refine"} <= actions
    html = render_html(draft)
    assert "Needs work &lt;unsafe&gt;" in html
    ordinary = build_drafts_view(selected={"id": "d3", "status": "draft"})
    assert {"draft_approve", "draft_discard"} <= set(_actions(ordinary))


def test_attachments_empty_error_sizes_and_client_local_action() -> None:
    assert "Attachment storage offline" in render_html(
        build_attachments_view(error="Attachment storage offline")
    )
    assert "No uploads yet" in render_html(build_attachments_view())
    view = build_attachments_view(
        [
            {"id": "a1", "filename": "small.txt", "category": "text", "size_bytes": 12},
            {"id": "a2", "filename": "medium.csv", "category": "data", "size_bytes": 2048},
            {
                "id": "a3",
                "filename": "large.bin",
                "category": "archive",
                "size_bytes": 2 * 1024 * 1024,
            },
            {"id": "a4", "filename": "unknown", "size_bytes": "bad"},
            {"id": "a5", "filename": "negative", "size_bytes": -1},
        ]
    )
    html = render_html(view)
    assert "12 B" in html and "2 KB" in html and "2.0 MB" in html and "0 B" in html
    assert _actions(view).count("attach_existing") == 5
    assert _actions(view).count("chrome_attachment_delete") == 5
    attach = next(
        component
        for component in view.to_dict()["components"][1]["content"][1]["children"]
        if component["action"] == "attach_existing"
    )
    assert attach["local"] is True
