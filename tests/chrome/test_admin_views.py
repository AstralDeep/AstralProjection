from __future__ import annotations

from astralprojection.chrome import render_html
from astralprojection.chrome.admin import (
    build_admin_view,
    build_audit_view,
    build_feedback_view,
    build_onboarding_view,
)
from astralprojection.models import LayoutView, ThemeView


def _actions(view) -> set[str]:
    found: set[str] = set()

    def visit(value) -> None:
        if isinstance(value, dict):
            if isinstance(value.get("action"), str):
                found.add(value["action"])
            if isinstance(value.get("submit_action"), str):
                found.add(value["submit_action"])
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(view.to_dict())
    return found


def test_audit_empty_state_is_a_stable_accessible_golden() -> None:
    view = build_audit_view()
    assert view.to_dict() == {
        "surface": "audit",
        "title": "Audit log",
        "components": [
            {
                "type": "param_picker",
                "title": "Filter audit entries",
                "description": "",
                "fields": [
                    {
                        "name": "event_class",
                        "label": "Event class",
                        "kind": "select",
                        "default": "",
                        "options": [""],
                    },
                    {
                        "name": "outcome",
                        "label": "Outcome",
                        "kind": "select",
                        "default": "",
                        "options": ["", "success", "failure", "in_progress", "interrupted"],
                    },
                    {"name": "q", "label": "Search", "kind": "text", "default": ""},
                ],
                "submit_label": "Apply",
                "submit_action": "chrome_audit_page",
                "submit_payload": {},
            },
            {
                "type": "alert",
                "message": "No audit entries match the current filters.",
                "variant": "info",
            },
        ],
        "theme": {
            "name": "midnight",
            "colors": {},
            "color_scheme": "dark",
            "contrast": "normal",
        },
        "layout": {"mode": "standard", "columns": 1, "density": "comfortable", "areas": []},
        "degradation": {
            "active": False,
            "reason": "",
            "unsupported_components": [],
            "fallback": "alert",
        },
    }
    html = render_html(view)
    assert 'aria-labelledby="chrome-audit-title"' in html
    assert 'role="status"' in html
    assert 'data-ui-action="chrome_audit_page"' in html


def test_audit_list_detail_denial_and_error_states() -> None:
    denied = build_audit_view(denied=True)
    assert "Access denied" in render_html(denied)
    assert _actions(denied) == set()
    offline = build_audit_view(error="Audit storage is offline.")
    assert "Audit storage is offline" in render_html(offline)
    entry = {
        "event_id": 'evt"><script>bad</script>',
        "recorded_at": "2026-08-13 12:00:00",
        "event_class": "tool",
        "action_type": "execute",
        "outcome": "success",
        "description": "x" * 140,
    }
    listed = build_audit_view(
        [entry, {**entry, "event_id": "evt-2", "outcome": "custom", "description": ""}],
        filters={"event_class": "tool", "outcome": "success", "q": "needle"},
        event_classes=("tool", "agent"),
        next_cursor="next-token",
        theme=ThemeView("ocean"),
        layout=LayoutView("wide", 2),
    )
    html = render_html(listed)
    assert "<script>" not in html
    assert "..." in html
    assert "Showing 2 entries" in html
    assert "Next" in html
    assert _actions(listed) == {"chrome_audit_page", "chrome_open"}
    missing = build_audit_view(selected={})
    assert "Audit event not found" in render_html(missing)
    detail = build_audit_view(
        selected={
            **entry,
            "correlation_id": "corr-1",
            "agent_id": None,
            "conversation_id": None,
            "started_at": None,
            "completed_at": None,
            "outcome_detail": "All good",
            "inputs_meta": {"query": "<unsafe>"},
            "outputs_meta": {"count": 1},
            "artifacts": [
                {"store": "blob", "artifact_id": "a1", "available": True},
                {"store": "blob", "artifact_id": "a2", "available": False},
                "bad",
            ],
        }
    )
    detail_html = render_html(detail)
    assert "All good" in detail_html
    assert "no longer available" in detail_html
    assert "&lt;unsafe&gt;" in detail_html


def test_feedback_golden_empty_populated_denied_and_failed() -> None:
    empty = build_feedback_view()
    html = render_html(empty)
    assert "No underperforming tools" in html
    assert "No pending knowledge-update proposals" in html
    assert build_feedback_view(denied=True).components[0].to_dict()["variant"] == "error"
    assert "failed" in render_html(build_feedback_view(error="Feedback load failed"))
    populated = build_feedback_view(
        [
            {
                "tool_name": "search_web",
                "agent_id": "research",
                "failure_rate": 0.125,
                "negative_feedback_rate": "bad",
                "dispatch_count": 8,
                "pending_proposal_id": "p1",
            },
            {
                "tool_name": "write_file",
                "agent_id": "writer",
                "failure_rate": None,
                "negative_feedback_rate": 0,
                "dispatch_count": 0,
            },
        ],
        [
            {
                "id": "p1",
                "tool_name": "search_web",
                "agent_id": "research",
                "artifact_path": "knowledge/tool.md",
                "diff_payload": "</textarea><script>boom()</script>",
            }
        ],
    )
    html = render_html(populated)
    assert "12.5%" in html
    assert "n/a" in html
    assert "<script>" not in html
    assert {"chrome_admin_proposal_decide"} == _actions(populated)


def test_onboarding_tour_and_admin_variants() -> None:
    offline = build_onboarding_view(offline=True)
    assert "unavailable" in render_html(offline)
    empty = build_onboarding_view()
    assert "No tour steps" in render_html(empty)
    steps = [
        {
            "id": 1,
            "slug": "open-settings",
            "title": "Open <settings>",
            "body": "Click the gear.",
            "target_kind": "selector",
            "target_key": "#settings",
            "display_order": 1,
            "audience": "user",
        }
    ]
    tour = build_onboarding_view(steps)
    assert "Open &lt;settings&gt;" in render_html(tour)
    assert _actions(tour) == {"chrome_tour_event"}
    admin_empty = build_onboarding_view(admin=True)
    assert "No tutorial steps" in render_html(admin_empty)
    archived = build_onboarding_view([{**steps[0], "archived": True}], admin=True)
    assert "chrome_admin_step_restore" in _actions(archived)
    active = build_onboarding_view(steps, admin=True, edit_step={"id": "new"})
    assert "chrome_admin_step_archive" in _actions(active)
    assert "chrome_admin_step_save" in _actions(active)
    edited = build_onboarding_view(steps, admin=True, edit_step=steps[0])
    fields = edited.to_dict()["components"][-1]["fields"]
    assert all(item["name"] != "slug" for item in fields)


def test_admin_shell_is_role_gated_and_selects_only_one_tab() -> None:
    denied = build_admin_view("quality", is_admin=False)
    assert _actions(denied) == set()
    quality = build_admin_view("bogus", is_admin=True)
    assert "Underperforming tools" in render_html(quality)
    assert quality.components[0].component_type == "container"
    tutorial = build_admin_view("tutorial", is_admin=True, steps=[])
    html = render_html(tutorial)
    assert "Tutorial admin" in html
    assert "No tutorial steps" in html
