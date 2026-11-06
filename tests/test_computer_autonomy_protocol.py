"""Checks the computer autonomy contract: the manifest declares the closed mode vocabulary, the mode frame
and verdict fields on existing push types, the exact retry action, the shared fixture stays conformant, and
the frozen accept_action vocabulary count moved with the two new actions.
"""

import json
from pathlib import Path

import pytest

from astralprojection import protocol

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = protocol.read_protocol_manifest()
FIXTURE = json.loads((ROOT / "contracts/fixtures/computer_autonomy/modes.json").read_text("utf-8"))
CONTRACT = MANIFEST["presentation_contracts"]["computer_autonomy_v1"]
MODES = {"ask", "auto_review", "bypass"}
DECISIONS = {"allow", "deny", "escalate"}


def additive_field(name: str) -> dict:
    matches = [item for item in MANIFEST["additive_fields"] if item["field"] == name]
    assert len(matches) == 1
    return matches[0]


def test_autonomy_contract_declares_closed_modes_and_every_client() -> None:
    assert CONTRACT["version"] == 1
    assert set(CONTRACT["modes"]) == MODES
    assert set(CONTRACT["clients"]) == {"macos", "browser", "windows", "android", "ios", "watch"}
    assert "owner-only" in CONTRACT["modes"]["bypass"]
    assert "auto_review" in CONTRACT["negotiation"]
    assert "absent field" in CONTRACT["negotiation"]


def test_mode_and_verdict_fields_ride_existing_push_types_without_new_vocabulary() -> None:
    mode = additive_field("computer_mode")
    assert set(mode["shape"]) == {"mode", "supported", "breaker"}
    assert mode["shape"]["mode"] == (
        "ask | auto_review | bypass: the server's confirmed authoritative autonomy mode for this host; "
        "never a client guess"
    )
    assert mode["carried_on"] == ["computer_host", "computer_session"]
    assert mode["contract"] == "accept_actions.chrome_computer_mode_set"
    assert "no auto-review stage" in mode["scope"]

    verdict = additive_field("review_verdict")
    assert set(verdict["shape"]) == {"event_id", "decision", "reason", "card_raised"}
    assert verdict["shape"]["decision"] == "allow | deny | escalate"
    assert verdict["shape"]["event_id"].startswith("the server audit event identity")
    assert verdict["carried_on"] == ["chat_step step (tool_call)"]
    assert verdict["contract"] == "accept_actions.chrome_computer_review_retry"
    assert "retry once with ui_event chrome_computer_review_retry" in verdict["scope"]

    names = {item["name"] for item in MANIFEST["push_types"]}
    assert {"computer_host", "computer_session", "chat_step"} <= names
    assert not any("autonomy" in name or "review" in name for name in names)


def test_retry_and_mode_actions_are_closed_and_bound_in_the_contract() -> None:
    actions = set(MANIFEST["accept_actions"])
    assert {"chrome_computer_mode_set", "chrome_computer_review_retry"} <= actions
    assert actions == set(MANIFEST["accept_actions"])
    assert len(MANIFEST["accept_actions"]) == len(set(MANIFEST["accept_actions"]))
    declared = set(CONTRACT["client_actions"])
    assert {"chrome_computer_mode_set", "chrome_computer_review_retry"} <= declared
    for action, spec in CONTRACT["client_actions"].items():
        assert action in actions
        assert set(spec["exact_fields"]) == {
            "host_id", "mode"} if action == "chrome_computer_mode_set" else {
            "chat_id", "event_id", "client_message_id"}


def test_confirmation_retry_breaker_and_audit_language_is_pinned() -> None:
    assert "only a server-sent computer_mode settles the selector" in CONTRACT["negotiation"]
    assert "never changes it optimistically" in CONTRACT["negotiation"]
    assert "normal banner" in CONTRACT["retry"] and "normal receipt" in CONTRACT["retry"]
    assert "executing the action once" in CONTRACT["retry"]
    for refusal in ("unknown", "stale", "expired", "already-retried"):
        assert refusal in CONTRACT["retry"]
    assert "pins the confirmed mode to ask" in CONTRACT["breaker"]
    assert "visible notice" in CONTRACT["breaker"]
    assert "review.auto.*" in CONTRACT["audit"] and "audit entry" in CONTRACT["audit"]
    assert set(CONTRACT["bounds"]) == {
        "event_id_scalars", "reason_scalars", "breaker_reason_scalars", "blocked_entries"}
    assert CONTRACT["bounds"]["blocked_entries"] == 40


def test_fixture_frames_stay_conformant_with_the_declared_shapes() -> None:
    assert FIXTURE["version"] == 1
    assert set(FIXTURE["modes"]) == MODES
    assert set(FIXTURE["supported_frames"]) == {"auto_review", "legacy", "breaker_open"}
    for name, frame in FIXTURE["supported_frames"].items():
        assert frame["type"] in {"computer_host", "computer_session"}
        if name == "legacy":
            assert "computer_mode" not in frame
            continue
        mode = frame["computer_mode"]
        assert mode["mode"] in MODES
        assert set(mode["supported"]) <= MODES and mode["supported"]
        if "breaker" in mode:
            assert mode["mode"] == "ask" and mode["breaker"]["open"] is True
    assert set(FIXTURE["verdict_frames"]) == {"allow", "deny", "escalate"}
    for name, frame in FIXTURE["verdict_frames"].items():
        verdict = frame["step"]["review_verdict"]
        assert verdict["decision"] == name
        assert verdict["event_id"].startswith("review.auto.")
        assert verdict["card_raised"] is (name == "escalate")
    for name, frame in FIXTURE["client_actions"].items():
        assert frame["type"] == "ui_event" and frame["action"] == name
        assert frame["action"] in MANIFEST["accept_actions"]
    assert set(FIXTURE["invalid"]) == {"unknown_mode", "breaker_not_ask", "verdict_without_event"}


@pytest.mark.parametrize(
    "name,expectation",
    [
        ("unknown_mode", "yolo"),
        ("breaker_not_ask", "auto_review"),
    ],
)
def test_fixture_records_the_refused_shapes(name: str, expectation: str) -> None:
    frame = FIXTURE["invalid"][name]
    assert frame["computer_mode"]["mode"] == expectation
    if name == "breaker_not_ask":
        assert frame["computer_mode"]["breaker"]["open"] is True


def test_fixture_records_a_verdict_refused_for_its_missing_event_identity() -> None:
    step = FIXTURE["invalid"]["verdict_without_event"]["step"]
    assert "event_id" not in step["review_verdict"]
    assert set(step["review_verdict"]) == {"decision", "card_raised"}
