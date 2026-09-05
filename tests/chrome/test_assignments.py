"""Owner-supplied assignment views retain consent and cross-client semantics."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from astralprojection.chrome import render_html
from astralprojection.chrome.assignments import build_assignments_view
from astralprojection.chrome.personalization import build_personalization_view
from astralprojection.models import LayoutView, ThemeView

ASSIGNMENT_ID = "180cd30b-cc38-432d-8349-1851b0d3ad7e"
SUBMISSION_ID = "48873d61-2e9b-4f38-bc36-bbfa81d78580"
ACTION_ID = "fc5c2124-ce23-48d9-927b-9c004d950c10"
ACTIONS = {
    "chrome_assignment_create", "chrome_assignment_revise",
    "chrome_assignment_pause", "chrome_assignment_resume",
    "chrome_assignment_stop", "chrome_assignment_revoke",
    "chrome_assignment_run_now", "chrome_assignment_approval_decide",
}


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


def buttons(view):
    return [item for item in nodes(view.to_dict()) if item.get("type") == "button"]


def assignment(**overrides):
    return {
        "assignment_id": ASSIGNMENT_ID, "instruction_revision": 3,
        "control_epoch": 7, "lifecycle": "active", "phase": "waiting",
        "definition": {
            "name": "Release watch", "instructions": "Report security changes only.",
            "source_key": "public_page", "source_url": "https://example.org/releases",
            "allowed_tools": ["web-research-1:fetch_page"],
            "conversation_id": "chat-1", "completion_condition": "",
        },
        "next_wake_at": "2026-09-06T12:00:00Z", "wake_reason": "Next scheduled check",
        "last_check_at": "2026-09-05T12:00:00Z", "latest_result": "Baseline saved",
        "grant_summary": "Current, read only", "grant_expires_at": "2026-10-05T12:00:00Z",
        "limit_summary": [{"label": "Daily tool calls", "value": 10}],
        "usage_summary": [{"label": "Daily tool calls used", "value": 2}],
        "available_actions": sorted(ACTIONS),
        "submission_ids": {action: SUBMISSION_ID for action in ACTIONS},
        **overrides,
    }


def state(mode="detail", **overrides):
    return {
        "mode": mode, "enabled": True, "execution_enabled": True,
        "assignment": assignment(), "available_actions": sorted(ACTIONS),
        "submission_ids": {action: SUBMISSION_ID for action in ACTIONS},
        "source_options": ["public_page"],
        "tool_options": ["web-research-1:fetch_page"],
        "limit_fields": [
            {"name": "daily.tool_calls", "label": "Daily tool calls", "value": 10},
            {"name": "daily.tokens", "label": "Daily tokens", "value": 1000},
        ],
        **overrides,
    }


def test_list_is_bounded_and_has_no_mutations_without_host_controls():
    row = assignment(available_actions=[], submission_ids={})
    view = build_assignments_view(state("list", assignments=[row] * 60, next_cursor="next"))
    html = render_html(view)
    assert html.count("Baseline saved") == 50
    assert "More ongoing agents" in html
    assert all(item["action"] == "chrome_open" for item in buttons(view))
    assert "Scheduled tasks" not in html  # The existing scheduler remains a separate view.


@pytest.mark.parametrize("lifecycle,phase,label", [
    ("active", "waiting", "Waiting"), ("active", "checking", "Checking"),
    ("active", "investigating", "Investigating"), ("active", "delegating", "Delegating"),
    ("active", "waiting_approval", "Waiting for approval"),
    ("active", "waiting_authorization", "Authorization required"),
    ("active", "budget_exhausted", "Budget exhausted"),
    ("active", "reconciliation", "Reconciliation required"),
    ("active", "failed", "Failed"), ("paused", "checking", "Paused"),
    ("stopped", "checking", "Stopped"), ("completed", "waiting", "Completed"),
])
def test_status_and_terminal_control_dispositions(lifecycle, phase, label):
    view = build_assignments_view(state(assignment=assignment(lifecycle=lifecycle, phase=phase)))
    assert label in render_html(view)
    mutation_actions = {b["action"] for b in buttons(view)} & ACTIONS
    if lifecycle in {"stopped", "completed"}:
        assert mutation_actions == set()
    elif lifecycle == "paused":
        assert "chrome_assignment_resume" in mutation_actions
        assert "chrome_assignment_run_now" not in mutation_actions
    else:
        assert "chrome_assignment_pause" in mutation_actions
        assert "chrome_assignment_resume" not in mutation_actions


def test_payloads_use_owner_versions_not_worker_state_and_no_secrets():
    row = assignment(state_version=999, claim_token="SECRET_CLAIM", offline_grant_id="PRIVATE_GRANT")
    view = build_assignments_view(state(assignment=row, access_token="SECRET_ACCESS"))
    for button in buttons(view):
        if button["action"] in ACTIONS:
            assert button["payload"] == {
                "assignment_id": ASSIGNMENT_ID, "expected_instruction_revision": 3,
                "expected_control_epoch": 7, "submission_id": SUBMISSION_ID,
            }
    encoded = json.dumps(view.to_dict())
    assert all(value not in encoded for value in ["SECRET_CLAIM", "SECRET_ACCESS", "PRIVATE_GRANT", "state_version"])


@pytest.mark.parametrize("mode", ["create", "revise"])
def test_forms_are_explicit_consent_and_retain_complete_review(mode):
    view = build_assignments_view(state(mode))
    form = next(n for n in nodes(view.to_dict()) if n.get("type") == "param_picker")
    fields = {item["name"]: item for item in form["fields"]}
    assert fields["consent"]["default"] is False
    assert fields["instructions"]["default"] == "Report security changes only."
    assert fields["allowed_tools"]["default"] == ["web-research-1:fetch_page"]
    assert fields["limits.daily.tokens"]["default"] == 1000
    assert fields["currency_cap_enabled"]["default"] is False
    assert form["submit_action"] == f"chrome_assignment_{mode}"
    assert "consent" not in form["submit_payload"]
    assert "Unpriced/unknown" in render_html(view)
    assert "revocable" in render_html(view)
    assert '<option value="web-research-1:fetch_page" selected>' in render_html(view)


def test_form_denials_do_not_emit_action_or_prechecked_consent():
    for changes in [
        {"submission_ids": {}}, {"available_actions": []},
        {"limit_fields": []}, {"source_options": []},
        {"tool_options": []}, {"activation_error": "A trusted quote is required."},
    ]:
        view = build_assignments_view(state("create", **changes))
        assert not any(n.get("type") == "param_picker" for n in nodes(view.to_dict()))
        assert "chrome_assignment_create" not in json.dumps(view.to_dict())


def test_cost_does_not_claim_unknown_is_free_and_keeps_optional_cap_visible():
    html = render_html(build_assignments_view(state()))
    assert "Unpriced/unknown" in html
    assert "No currency cap" in html
    priced = assignment(monetary_cost_label="USD 0.003", currency_cap_label="USD 1.00 daily")
    html = render_html(build_assignments_view(state(assignment=priced)))
    assert "USD 0.003" in html and "USD 1.00 daily" in html


def test_exact_approval_does_not_copy_arguments_or_imply_execution():
    approval = {
        "action_id": ACTION_ID, "request_digest": "a" * 64,
        "state": "proposed", "tool_label": "Remote action", "target_label": "Test file",
        "arguments_summary": "Remove one test file", "consequence": "The file is removed",
        "preconditions_summary": "The file revision must still match",
        "expires_at": "2026-09-05T13:00:00Z", "interactive_only": True,
        "instruction_revision": 3, "control_epoch": 7,
        "submission_ids": {"approve": SUBMISSION_ID, "decline": SUBMISSION_ID},
        "raw_arguments": {"token": "SECRET_ARGUMENT"},
    }
    view = build_assignments_view(state(assignment=assignment(approvals=[approval])))
    decisions = [b for b in buttons(view) if b["action"] == "chrome_assignment_approval_decide"]
    assert {b["payload"]["decision"] for b in decisions} == {"approve", "decline"}
    assert all(b["payload"]["action_id"] == ACTION_ID for b in decisions)
    assert all(b["payload"]["request_digest"] == "a" * 64 for b in decisions)
    assert "SECRET_ARGUMENT" not in json.dumps(view.to_dict())
    assert "additional review" in render_html(view)
    assert "preconditions" in render_html(view).lower()
    approval["control_epoch"] = 6
    stale = build_assignments_view(state(assignment=assignment(approvals=[approval])))
    assert not any(b["action"] == "chrome_assignment_approval_decide" for b in buttons(stale))


def test_tasks_activity_and_inflight_outcomes_are_safe_and_bounded():
    row = assignment(
        tasks=[{"title": "Investigate", "state": "completed", "result": "Verified",
                "provenance_summary": "Web Research, owner authorized", "incorporated": True}] * 40,
        activity=[{"title": "Release observed", "summary": "<script>bad</script>",
                   "created_at": "now", "sequence": 1}] * 70,
        in_flight_summary="One already-issued request may finish.",
    )
    html = render_html(build_assignments_view(state(assignment=row)))
    assert "&lt;script&gt;bad&lt;/script&gt;" in html and "<script>" not in html
    assert html.count("Web Research, owner authorized") == 32
    assert html.count("<h3>Release observed</h3>") == 50
    assert "already-issued request" in html and "Incorporated" in html


@pytest.mark.parametrize("mode", ["list", "detail", "create", "revise"])
def test_watch_has_bounded_status_chat_controls_and_explicit_handoff(mode):
    view = build_assignments_view(state(mode, assignments=[assignment()] * 10), layout=LayoutView(mode="watch"))
    encoded = json.dumps(view.to_dict())
    assert not buttons(view)
    assert '"type": "param_picker"' not in encoded
    assert "phone or computer" in encoded
    assert "Pause Release watch" in encoded
    assert encoded.count("Baseline saved") <= 3
    assert view.layout.mode == "watch"


def test_disabled_error_unknown_and_malformed_views_fail_visibly():
    for changes, message in [
        ({"enabled": False}, "turned off"), ({"error": "Store unavailable"}, "Store unavailable"),
        ({"mode": "not-a-mode"}, "unavailable"), ({"assignment": {}}, "not available"),
    ]:
        view = build_assignments_view(state(**changes))
        assert message.lower() in render_html(view).lower()
        assert not buttons(view)
    view = build_assignments_view(state("list", assignments=[]), theme=ThemeView(name="daylight"))
    assert "No ongoing agents" in render_html(view)
    assert view.theme.name == "daylight"
    bad = assignment(instruction_revision=True, submission_ids={a: "bad" for a in ACTIONS})
    assert not ({b["action"] for b in buttons(build_assignments_view(state(assignment=bad)))} & ACTIONS)


def test_actions_are_manifested_without_new_primitives():
    manifest = json.loads((Path(__file__).resolve().parents[2] / "contracts/ui_protocol.json").read_text())
    assert ACTIONS <= set(manifest["accept_actions"])
    known = set(manifest["component_types"])
    for mode in ("list", "detail", "create", "revise"):
        view = build_assignments_view(state(mode, assignments=[assignment()]))
        assert {n["type"] for n in nodes(view.to_dict()) if "type" in n} <= known


def test_schedule_shell_combines_assignments_without_changing_legacy_default():
    original = build_personalization_view("schedule", execution_enabled=True)
    assert "Ongoing agents" not in render_html(original)
    combined = build_personalization_view("schedule", execution_enabled=True,
                                         assignment_state=state("list", assignments=[]))
    assert "Ongoing agents" in render_html(combined)
    assert "Scheduled tasks" in render_html(combined)
    watch = build_personalization_view("schedule", assignment_state=state(),
                                      layout=LayoutView(mode="watch"))
    assert not buttons(watch)


@pytest.mark.parametrize("limit_fields", [
    [{"name": "owner_id.bad.key", "value": 2}],
    [{"name": "daily.tokens", "value": -1}],
    [{"name": "daily.tokens", "value": True}],
    [{"name": "daily.tokens", "value": "secret"}],
    [{"name": "daily.tokens", "value": 1}] * 33,
])
def test_malformed_or_oversized_limit_review_never_becomes_partial_consent(limit_fields):
    view = build_assignments_view(state("create", limit_fields=limit_fields))
    assert not any(n.get("type") == "param_picker" for n in nodes(view.to_dict()))


def test_terminal_revision_is_not_offered_and_watch_text_is_bounded():
    terminal = build_assignments_view(state("revise", assignment=assignment(lifecycle="stopped")))
    assert not any(n.get("type") == "param_picker" for n in nodes(terminal.to_dict()))
    watch = build_assignments_view(state(assignment=assignment(latest_result="A" * 20000)), layout=LayoutView(mode="watch"))
    assert len(json.dumps(watch.to_dict())) < 5000


def test_remaining_empty_error_and_expired_control_states():
    proposal = {"state": "proposed", "expired": True, "action_id": ACTION_ID}
    row = assignment(approvals=[proposal], safe_error="budget_exhausted", activity_cursor="older")
    view = build_assignments_view(state(assignment=row, execution_enabled=False, notice="Paused by owner"))
    assert "Unattended execution is unavailable" in render_html(view)
    assert "Paused by owner" in render_html(view)
    assert "More activity" in render_html(view)
    assert not any(b["action"] in {"chrome_assignment_run_now", "chrome_assignment_approval_decide"} for b in buttons(view))
    assert "Unknown state" in render_html(build_assignments_view(state(assignment=assignment(lifecycle="unknown"))))
    assert "Unknown state" in render_html(build_assignments_view(state(assignment=assignment(phase="unknown"))))
    assert "No ongoing agents" in render_html(build_assignments_view(state("list", assignments="malformed")))
    bad = assignment(assignment_id="not-an-id")
    assert "View assignment" not in render_html(build_assignments_view(state("list", assignments=[bad])))
