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


@pytest.mark.parametrize("lifecycle", ["stopped", "completed"])
@pytest.mark.parametrize("mode", ["list", "detail"])
def test_terminal_watch_guidance_preserves_status_and_history_without_restart_commands(lifecycle, mode):
    row = assignment(lifecycle=lifecycle, safe_error="assignment_phi_refused")
    view = build_assignments_view(state(mode, assignment=row, assignments=[row]),
                                  layout=LayoutView(mode="watch"))
    encoded = json.dumps(view.to_dict())
    assert "Status of Release watch" in encoded
    assert "assignment_phi_refused" in encoded
    assert "Baseline saved" in encoded
    assert "phone or computer" in encoded
    assert all(f"{command} Release watch" not in encoded for command in ("Pause", "Resume", "Stop"))
    assert not buttons(view)


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


# ── Feature 088 T044: recurring work (scheduled jobs + typed monitoring outcomes) ──

from astralprojection.chrome.assignments import build_recurring_work_view  # noqa: E402

JOB_ID = "2b7e1d4c-9a3f-4b8e-9c1d-5e6f7a8b9c0d"
JOB_ACTIONS = {"chrome_job_pause", "chrome_job_resume", "chrome_job_stop"}


def job(**overrides):
    return {
        "job_id": JOB_ID, "name": "Release notes watch", "kind": "cron", "expression": "0 7 * * *",
        "timezone": "UTC", "status": "active", "terminal_stop": False,
        "next_run_at": "2026-09-13T07:00:00+00:00", "last_run_at": "2026-09-12T07:00:00+00:00",
        "policy_version": 2, "allowance": {"admitted": 3, "max": 10},
        "assignment": {"assignment_id": ASSIGNMENT_ID, "name": "Release notes watch",
                       "lifecycle": "active", "phase": "waiting"},
        "observation": {"kind": "unchanged", "finding": "", "observed_at": "2026-09-12T07:00:05+00:00",
                        "sequence": 4, "reason": None, "complete_source_set": True},
        "runs": [{"started_at": "2026-09-12T07:00:00+00:00", "outcome": "completed",
                  "summary": "Unchanged; no run allowance spent."}],
        "available_actions": sorted(JOB_ACTIONS),
        "submission_ids": {action: SUBMISSION_ID for action in JOB_ACTIONS},
        **overrides,
    }


def rstate(mode="detail", **overrides):
    return {"mode": mode, "enabled": True, "execution_enabled": True, "job": job(), **overrides}


def job_buttons(view):
    return [b for b in buttons(view) if b["action"] in JOB_ACTIONS]


def test_recurring_list_is_bounded_and_has_no_mutations_without_host_controls():
    row = job(available_actions=[], submission_ids={})
    view = build_recurring_work_view(rstate("list", jobs=[row] * 60, next_cursor="older"))
    html = render_html(view)
    assert html.count("<h3>Release notes watch</h3>") == 50
    assert "More recurring work" in html
    assert all(item["action"] == "chrome_open" for item in buttons(view))
    assert view.title == "Recurring work"
    nav = [b["payload"]["params"] for b in buttons(view) if b["label"] == "More recurring work"]
    assert nav == [{"tab": "schedule", "view": "recurring", "job_cursor": "older"}]


def test_recurring_controls_carry_owner_policy_versions_and_stop_is_terminal():
    view = build_recurring_work_view(rstate())
    controls = {b["action"]: b for b in job_buttons(view)}
    assert set(controls) == {"chrome_job_pause", "chrome_job_stop"}
    for button in controls.values():
        assert button["payload"] == {"job_id": JOB_ID, "submission_id": SUBMISSION_ID,
                                     "expected_policy_version": 2}
    assert controls["chrome_job_stop"]["label"] == "Stop permanently"
    assert controls["chrome_job_stop"]["variant"] == "danger"
    paused = build_recurring_work_view(rstate(job=job(status="paused")))
    assert {b["action"] for b in job_buttons(paused)} == {"chrome_job_resume", "chrome_job_stop"}
    assert "Paused" in render_html(paused)
    offline = build_recurring_work_view(rstate(job=job(status="paused"), execution_enabled=False))
    assert {b["action"] for b in job_buttons(offline)} == {"chrome_job_stop"}
    assert "Unattended execution is unavailable" in render_html(offline)


@pytest.mark.parametrize("changes,label", [
    ({"terminal_stop": True}, "Stopped permanently"),
    ({"status": "completed"}, "Completed"),
    ({"status": "expired"}, "Expired"),
    ({"status": "disabled"}, "Disabled"),
    ({"status": "unknown"}, "Unknown state"),
    ({"status": None}, "Unknown state"),
])
def test_terminal_or_unknown_jobs_offer_no_controls(changes, label):
    for mode in ("list", "detail"):
        row = job(**changes)
        view = build_recurring_work_view(rstate(mode, job=row, jobs=[row]))
        assert label in render_html(view)
        assert not job_buttons(view)


def test_legacy_job_without_a_policy_has_no_stop_and_a_null_policy_version():
    view = build_recurring_work_view(rstate(job=job(policy_version=None, allowance=None)))
    controls = {b["action"]: b for b in job_buttons(view)}
    assert set(controls) == {"chrome_job_pause"}
    assert controls["chrome_job_pause"]["payload"]["expected_policy_version"] is None
    assert "No run limit" in render_html(view)
    for bad in (True, 0, -1, "2"):
        assert not job_buttons(build_recurring_work_view(rstate(job=job(policy_version=bad))))
    for changes in ({"submission_ids": {}}, {"available_actions": []}, {"job_id": "not-a-uuid"},
                    {"submission_ids": {a: "bad" for a in JOB_ACTIONS}}):
        row = job(**changes)
        assert not job_buttons(build_recurring_work_view(rstate("list", jobs=[row])))


@pytest.mark.parametrize("kind,label,default", [
    ("initial", "Initial observation", "Initial observation recorded."),
    ("unchanged", "Unchanged", "Unchanged since the prior complete observation. No new finding."),
    ("changed", "Changed", "The source changed since the prior observation."),
    ("insufficient_evidence", "Insufficient evidence",
     "Insufficient evidence to compare with the prior observation."),
])
def test_all_four_monitoring_outcomes_have_distinct_labels_and_honest_defaults(kind, label, default):
    row = job(observation={"kind": kind, "finding": "", "observed_at": "now", "sequence": 2,
                           "reason": None, "complete_source_set": True})
    html = render_html(build_recurring_work_view(rstate(job=row)))
    assert f">{label}</span>" in html and default in html and "Complete" in html
    row["observation"].update(finding="Safe finding text", reason="extraction_incomplete",
                              complete_source_set=False)
    html = render_html(build_recurring_work_view(rstate(job=row)))
    assert "Safe finding text" in html and default not in html
    assert "extraction_incomplete" in html and "Incomplete" in html


def test_unknown_or_missing_observation_is_explicit():
    html = render_html(build_recurring_work_view(rstate(job=job(observation=None))))
    assert "No observation yet." in html
    row = job(observation={"kind": "guessed", "finding": None, "complete_source_set": "yes"})
    html = render_html(build_recurring_work_view(rstate(job=row)))
    assert "Unknown outcome" in html and "No finding recorded." in html
    assert "<dd>Unknown</dd>" in html
    html = render_html(build_recurring_work_view(rstate(job=job(observation="malformed"))))
    assert "Unknown outcome" in html


@pytest.mark.parametrize("allowance,expected", [
    (None, "No run limit"),
    ({"admitted": None, "max": 10}, "Unknown"),
    ({"admitted": 3, "max": None}, "Unknown"),
    ({"admitted": True, "max": 10}, "Unknown"),
    ({"admitted": -1, "max": 10}, "Unknown"),
    ("malformed", "Unknown"),
    ({"admitted": 0, "max": 5}, "0 of 5 runs admitted; 5 remaining"),
    ({"admitted": 5, "max": 5}, "5 of 5 runs admitted; 0 remaining"),
    ({"admitted": 7, "max": 5}, "7 of 5 runs admitted; 0 remaining"),
])
def test_allowance_unknown_is_never_zero_and_known_zero_is_shown(allowance, expected):
    html = render_html(build_recurring_work_view(rstate(job=job(allowance=allowance))))
    assert f"<dt>Run allowance</dt><dd>{expected}</dd>" in html


@pytest.mark.parametrize("changes,expected", [
    ({"kind": "cron"}, "Repeats on a cron schedule"),
    ({"kind": "interval"}, "Repeats on an interval"),
    ({"kind": "one_shot"}, "Runs once"),
    ({"kind": "weekly"}, "Unknown schedule"),
    ({"next_run_at": None}, "No run scheduled"),
    ({"last_run_at": None}, "Never run"),
    ({"expression": None}, "Unavailable"),
    ({"timezone": None}, "Unknown"),
])
def test_schedule_facts_are_labelled_without_guessing(changes, expected):
    html = render_html(build_recurring_work_view(rstate(job=job(**changes))))
    assert expected in html


def test_recurring_detail_has_bound_agent_runs_and_back_navigation():
    row = job(runs=[{"started_at": f"2026-09-{i:02}T07:00:00+00:00", "outcome": "completed",
                     "summary": "<script>bad</script>"} for i in range(1, 31)])
    view = build_recurring_work_view(rstate(job=row))
    html = render_html(view)
    assert html.count("&lt;script&gt;bad&lt;/script&gt;") == 20 and "<script>" not in html
    assert "Ongoing agent" in html and "Waiting" in html
    nav = {b["label"]: b["payload"]["params"] for b in buttons(view) if b["action"] == "chrome_open"}
    assert nav["View ongoing agent"] == {"tab": "schedule", "assignment_id": ASSIGNMENT_ID}
    assert nav["Back to recurring work"] == {"tab": "schedule", "view": "recurring"}
    empty = render_html(build_recurring_work_view(rstate(job=job(runs=[], assignment=None))))
    assert "No runs yet" in empty and "View ongoing agent" not in empty
    listed = build_recurring_work_view(rstate("list", jobs=[job()]))
    assert any(b["payload"]["params"] == {"tab": "schedule", "view": "recurring", "job_id": JOB_ID}
               for b in buttons(listed))


def test_recurring_disabled_error_malformed_empty_and_notice_states():
    for changes, message in [
        ({"enabled": False}, "turned off"), ({"error": "Scheduler unavailable"}, "Scheduler unavailable"),
        ({"mode": "not-a-mode"}, "unavailable"), ({"job": {}}, "not available"),
        ({"job": job(job_id="bad")}, "not available"),
    ]:
        view = build_recurring_work_view(rstate(**changes))
        assert message.lower() in render_html(view).lower()
        assert not buttons(view)
    empty = build_recurring_work_view(rstate("list", jobs=[]), theme=ThemeView(name="daylight"))
    assert "No recurring work yet" in render_html(empty) and empty.theme.name == "daylight"
    assert "No recurring work yet" in render_html(build_recurring_work_view(rstate("list", jobs="malformed")))
    assert "No recurring work yet" in render_html(build_recurring_work_view(rstate("list", jobs=["bad", 3])))
    noticed = render_html(build_recurring_work_view(rstate(notice="Paused by owner", execution_enabled=False)))
    assert "Paused by owner" in noticed and "Unattended execution is unavailable" in noticed
    assert "turned off" in render_html(build_recurring_work_view(None))
    flagged = job(safe_error="assignment_phi_refused", in_flight_summary="One issued request may finish.")
    html = render_html(build_recurring_work_view(rstate(job=flagged)))
    assert "assignment_phi_refused" in html and "issued request may finish" in html


@pytest.mark.parametrize("mode", ["list", "detail"])
def test_recurring_watch_is_bounded_with_handoff_and_no_controls(mode):
    long = job(observation={"kind": "changed", "finding": "A" * 20000})
    view = build_recurring_work_view(rstate(mode, job=long, jobs=[long] * 10), layout=LayoutView(mode="watch"))
    encoded = json.dumps(view.to_dict())
    assert not buttons(view)
    assert encoded.count("Release notes watch") <= 3
    assert "phone or computer" in encoded and "Changed" in encoded
    assert len(encoded) < 5000 and "Observation number" not in encoded
    empty = build_recurring_work_view(rstate("list", jobs=[]), layout=LayoutView(mode="watch"))
    assert "No recurring work yet" in render_html(empty)


def test_recurring_rows_forward_no_secrets_or_raw_records():
    row = job(offline_grant_id="PRIVATE_GRANT", consented_scopes=["SECRET_SCOPE"],
              instruction="SECRET_INSTRUCTION", claim_token="SECRET_CLAIM", state_version=99,
              expression={"cron": "SECRET_RAW"})
    view = build_recurring_work_view(rstate("list", jobs=[row], access_token="SECRET_ACCESS"))
    encoded = json.dumps(view.to_dict())
    for value in ("PRIVATE_GRANT", "SECRET_SCOPE", "SECRET_INSTRUCTION", "SECRET_CLAIM",
                  "SECRET_ACCESS", "SECRET_RAW", "state_version"):
        assert value not in encoded
    assert "Unavailable" in encoded


def test_recurring_actions_are_manifested_without_new_primitives():
    manifest = json.loads((Path(__file__).resolve().parents[2] / "contracts/ui_protocol.json").read_text(encoding="utf-8"))
    assert JOB_ACTIONS <= set(manifest["accept_actions"])
    known = set(manifest["component_types"])
    for mode in ("list", "detail"):
        view = build_recurring_work_view(rstate(mode, jobs=[job(), job(status="paused")]))
        assert {n["type"] for n in nodes(view.to_dict()) if "type" in n} <= known
    assert "chrome_work_result_save" not in json.dumps(view.to_dict())
