"""Feature 044 — desktop protocol-coverage drift guard.

The committed manifest ``contracts/ui_protocol.json`` is the single source
of the server->client frame vocabulary. The desktop classification table must
cover it exactly: no unclassified frame, no stale entry. A new server frame
type therefore fails this suite until the desktop deliberately classifies it.
"""

import json
from pathlib import Path

from astral_client.protocol_manifest import (
    CLASSIFICATION,
    CLIENT_LOCAL_ACTIONS,
    HANDLED,
    IGNORED,
    is_classified,
    is_handled,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST = REPO_ROOT / "contracts" / "ui_protocol.json"
ADMISSION_REFUSAL_CODES = [
    "capacity_exceeded",
    "registration_required",
    "registration_timeout",
    "idempotency_conflict",
    "connection_closing",
    "service_draining",
    "invalid_input",
    "registration_queue_full",
    "operation_failed",
]


def _manifest_push_types() -> set[str]:
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    return {entry["name"] for entry in data["push_types"]}


def _manifest() -> dict:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


def test_classification_covers_manifest_exactly():
    push = _manifest_push_types()
    classified = set(CLASSIFICATION)
    missing = sorted(push - classified)
    stale = sorted(classified - push)
    assert not missing, f"server frame types the desktop has not classified: {missing}"
    assert not stale, f"desktop classifies frame types the server no longer sends: {stale}"


def test_client_local_actions_matches_manifest():
    """The committed CLIENT_LOCAL_ACTIONS constant (a packaged build has no repo
    tree to probe at import time) must mirror the manifest's
    ``client_local_actions`` exactly."""
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    assert CLIENT_LOCAL_ACTIONS == frozenset(data["client_local_actions"])


def test_persistent_assignment_actions_use_existing_generic_surface():
    expected = {
        "chrome_assignment_create", "chrome_assignment_revise",
        "chrome_assignment_pause", "chrome_assignment_resume",
        "chrome_assignment_stop", "chrome_assignment_revoke",
        "chrome_assignment_run_now", "chrome_assignment_approval_decide",
    }
    assert {a for a in _manifest()["accept_actions"] if a.startswith("chrome_assignment_")} == expected
    assert is_handled("chrome_surface")
    assert is_handled("ui_render")
    assert is_handled("notification")


def test_feature_088_guidance_actions_are_closed_and_not_desktop_frames():
    """Feature 088 T037 drift pin: the shared skills/agents/selection views add three closed
    actions (129 -> 132) and NO push type; the desktop never advertises the capabilities that
    would make a host send one, so its frame classification is unaffected (Windows redesign
    remains deferred, T059)."""
    data = _manifest()
    actions = data["accept_actions"]
    # 132 T037 actions + the two T043/T044 actions and the two T048 Connections
    # actions pinned by the tests below.
    assert len(actions) == len(set(actions)) == 136
    assert {"chrome_declarative_view", "chrome_declarative_command", "chrome_turn_selection_set"} <= set(actions)
    guidance = ["guidance_notes_088", "guidance_skills_088", "guidance_agents_088", "guidance_selection_088"]
    contracts = data["presentation_contracts"]
    assert [contracts[name]["client_capability"] for name in guidance] == [
        "guidance_notes_v1", "guidance_skills_v1", "guidance_agents_v1", "guidance_selection_v1"]
    assert all(contracts[name]["surface_key"] == "guidance" for name in guidance)
    assert not {name for name in _manifest_push_types() if name.startswith(("guidance", "declarative"))}
    assert not {name for name in CLASSIFICATION if name.startswith(("guidance", "declarative"))}


def test_feature_088_save_recurring_and_saved_results_are_closed_and_not_desktop_frames():
    """Feature 088 T043/T044 drift pin: the exact Save command and the terminal job Stop add two
    closed actions (132 -> 134) and NO push type; the desktop never advertises work_save_v1,
    recurring_work_v1 or saved_results_v1, so it keeps its compatible Work/Schedule views
    (Windows redesign remains deferred, T059)."""
    data = _manifest()
    actions = data["accept_actions"]
    assert len(actions) == len(set(actions)) == 136
    assert {"chrome_work_result_save", "chrome_job_stop"} <= set(actions)
    contracts = data["presentation_contracts"]
    names = ["work_save_088", "recurring_work_088", "saved_results_088"]
    assert [contracts[name]["client_capability"] for name in names] == [
        "work_save_v1", "recurring_work_v1", "saved_results_v1"]
    assert [contracts[name]["surface_key"] for name in names] == ["work", "personalization", "saved_results"]
    assert all(contracts[name]["native_response"]["type"] == "chrome_surface" for name in names)
    assert set(contracts["work_save_088"]["commands"]) == {"propose", "save"}
    assert not {name for name in _manifest_push_types()
                if name.startswith(("work_save", "recurring_work", "saved_result"))}
    assert not {name for name in CLASSIFICATION
                if name.startswith(("work_save", "recurring_work", "saved_result"))}


def test_client_local_voice_contract_is_pinned_to_closed_v2_dispositions():
    contract = _manifest()["frame_contracts"]["voice_075"]
    assert contract["schema_version"] == "2"
    assert contract["local_frame_contract"] == "client_local/v1"
    assert contract["required_dispositions"] == [
        "ready",
        "typed_fallback",
        "rejected",
        "permission_denied",
        "final",
        "speaking",
        "finished",
    ]


def test_classification_values_are_valid():
    assert set(CLASSIFICATION.values()) <= {HANDLED, IGNORED}


def test_core_loop_frames_are_handled():
    for frame in (
        "ui_render",
        "ui_upsert",
        "chat_status",
        "error",
        "auth_required",
        "chrome_menu",
        "chrome_surface",
        "user_message_acked",
        "chat_step",
        "tool_progress",
        "task_started",
        "task_completed",
        "notification",
        "user_preferences",
        "workspace_timeline_mode",
        "conversation_snapshot",
        "operation_status",
        "agent_lifecycle",
        "agent_host_inventory_reconciled",
        "agent_host_registered",
        "agent_host_registration_refused",
    ):
        assert is_handled(frame), f"{frame} must be handled per the parity matrix"


def test_voice_frames_are_explicitly_handled_and_unknowns_remain_unclassified():
    voice_frames = {
        "composer_state",
        "voice_announcement_media",
        "voice_local_announcement",
        "voice_local_final_rejected",
        "voice_local_session_ready",
        "voice_local_turn_bound",
        "voice_control_binding",
        "voice_session_state",
        "voice_submission_rejected",
        "voice_transcript",
        "voice_turn_state",
    }

    assert all(is_handled(frame) for frame in voice_frames)
    assert not is_classified("voice_unknown")


def test_manifest_declares_structured_host_registration():
    registrations = [
        entry
        for entry in _manifest()["additive_fields"]
        if entry.get("field") == "agent_host" and entry.get("carried_on") == ["register_ui"]
    ]
    assert len(registrations) == 1
    assert set(registrations[0]["shape"]) == {
        "host_id",
        "supported_runtime_contract_versions",
        "runtime_lock_sha256",
        "platform",
        "client_version",
    }


def test_manifest_declares_exact_admission_refusal_contract():
    assert _manifest()["frame_contracts"]["admission_refusal"] == {
        "type": "error",
        "exact_fields": [
            "type",
            "submission_id",
            "accepted",
            "code",
            "message",
            "retryable",
            "retry_after_ms",
        ],
        "submission_id": "canonical_lowercase_uuid4",
        "accepted": False,
        "additional_fields": False,
        "codes": ADMISSION_REFUSAL_CODES,
    }
