"""Tests for src/astralprojection/chrome/admin.py: audit, feedback, onboarding and
diagnostics view states, including role gating and bounded diagnostic samples.
"""

from __future__ import annotations

import json
from pathlib import Path

from astralprojection.chrome import render_html
import pytest

from astralprojection.chrome.admin import (
    build_admin_view,
    build_audit_view,
    build_diagnostics_view,
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
    fixture = Path(__file__).resolve().parents[2] / "contracts/fixtures/workspace_088/audit-empty.json"
    assert view.to_dict() == json.loads(fixture.read_text())
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


def test_diagnostics_renders_only_bounded_samples_and_offers_no_action() -> None:
    view = build_diagnostics_view(
        {
            "metrics": [
                {"name": "work_admission_active", "value": 3, "labels": {"phase": "running"}},
                {"name": "work_admission_active", "value": 0, "labels": {"phase": "queued"}},
                {"name": "voice_sessions", "value": 1.5, "labels": {}},
            ]
        }
    )
    html = render_html(view)
    assert view.surface == "admin_tools" and view.title == "Runtime diagnostics"
    assert "work_admission_active" in html and "phase=running" in html
    assert "no labels" in html and "<dd>0</dd>" in html and "1.5" in html
    assert _actions(view) == set()


@pytest.mark.parametrize(
    "sample",
    [
        {"name": "Work_Admission", "value": 1, "labels": {}},
        {"name": "work admission", "value": 1, "labels": {}},
        {"name": "work_admission", "value": True, "labels": {}},
        {"name": "work_admission", "value": "3", "labels": {}},
        {"name": "work_admission", "value": float("inf"), "labels": {}},
        {"name": "work_admission", "value": float("nan"), "labels": {}},
        {"name": "work_admission", "value": 1, "labels": {"phase": "https://leak.invalid/x"}},
        {"name": "work_admission", "value": 1, "labels": {"Phase": "running"}},
        {"name": "work_admission", "value": 1, "labels": {"phase": 3}},
        {"name": "work_admission", "value": 1, "labels": "running"},
        {"name": "work_admission", "value": 1, "labels": {}, "owner_id": "leak"},
        {"name": "work_admission", "labels": {}},
        "work_admission",
    ],
)
def test_diagnostics_drops_every_sample_outside_the_collectors_own_bounds(sample) -> None:
    view = build_diagnostics_view({"metrics": [sample]})
    assert "No runtime samples" in render_html(view)
    assert "leak" not in json.dumps(view.to_dict())


def test_diagnostics_accepts_a_bare_sequence_and_refuses_an_unknown_snapshot_shape() -> None:
    samples = [{"name": "work_admission", "value": 2, "labels": {}}]
    assert "work_admission" in render_html(build_diagnostics_view(samples))
    for snapshot in ({}, {"samples": samples}, "work_admission", None, {"metrics": {"a": 1}}):
        assert "No runtime samples" in render_html(build_diagnostics_view(snapshot))


def test_diagnostics_empty_denied_and_error_states_are_distinct() -> None:
    assert "No runtime samples" in render_html(build_diagnostics_view(()))
    denied = build_diagnostics_view({"metrics": [{"name": "m_a", "value": 1, "labels": {}}]},
                                    denied=True)
    assert "Admin role required" in render_html(denied) and "m_a" not in json.dumps(denied.to_dict())
    failed = build_diagnostics_view((), error="Diagnostics are unavailable.")
    assert "Diagnostics are unavailable." in render_html(failed)
    assert _actions(denied) == _actions(failed) == set()


def test_diagnostics_groups_and_orders_samples_deterministically() -> None:
    samples = [
        {"name": "b_metric", "value": 1, "labels": {"phase": "b"}},
        {"name": "a_metric", "value": 2, "labels": {"phase": "b"}},
        {"name": "a_metric", "value": 3, "labels": {"phase": "a"}},
    ]
    view = build_diagnostics_view({"metrics": samples})
    cards = [item.to_dict() for item in view.components if item.to_dict()["type"] == "card"]
    assert [card["title"] for card in cards] == ["a_metric", "b_metric"]
    assert [row["label"] for row in cards[0]["content"][0]["items"]] == ["phase=a", "phase=b"]


def test_diagnostics_carries_theme_and_layout() -> None:
    view = build_diagnostics_view(
        (), theme=ThemeView("midnight"), layout=LayoutView("compact")
    )
    assert view.theme.name == "midnight" and view.layout.mode == "compact"
