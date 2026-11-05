"""Checks the outcome-unknown contract: the manifest declares the host incarnation and retained-job inventory
on the announce descriptor and the single-intent outcome_ack event on the existing computer_event action, the
shared fixture stays conformant, and the frozen accept_action and client_local_action vocabularies are intact.
"""

import json
from pathlib import Path

import pytest

from astralprojection import protocol

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = protocol.read_protocol_manifest()
FIXTURE = json.loads(
    (ROOT / "contracts/fixtures/computer_outcome/announce_and_ack.json").read_text("utf-8")
)
JOB_STATES = {"running", "exited", "interrupted", "timed_out", "uncertain"}


def additive_field(name: str) -> dict:
    matches = [item for item in MANIFEST["additive_fields"] if item["field"] == name]
    assert len(matches) == 1
    return matches[0]


def test_descriptor_declares_incarnation_and_retained_job_inventory() -> None:
    shape = additive_field("computer_host")["shape"]
    assert shape["incarnation_id"] == "canonical lowercase uuid4, fresh per host process launch"
    jobs = shape["retained_jobs"]
    assert isinstance(jobs, list) and len(jobs) == 1
    description = jobs[0]
    for declared in ("job_id", "state", "exit_code", "signal", "output_bytes", "at most 64"):
        assert declared in description
    assert additive_field("computer_host")["carried_on"] == [
        "register_ui",
        "ui_event.computer_event (event=announce, under host)",
    ]
    scope = additive_field("computer_host")["scope"]
    assert "incarnation" in scope and "never output content" in scope


def test_outcome_ack_rides_the_existing_computer_event_action_without_new_vocabulary() -> None:
    entry = additive_field("outcome_ack")
    assert entry["carried_on"] == [
        "ui_event.computer_event (event=outcome_ack)",
        "computer_host (success receipt after audit acceptance)",
    ]
    assert set(entry["shape"]) == {"event", "decision", "incarnation_id", "success_receipt"}
    assert entry["shape"]["decision"] == "acknowledge | discard"
    assert entry["shape"]["event"] == "outcome_ack"
    receipt = entry["shape"]["success_receipt"]
    assert receipt["type"] == "computer_host"
    assert set(receipt["outcome_ack"]) == {"decision", "incarnation_id", "connection_generation"}
    assert "idempotently replayed" in entry["scope"]
    assert "bounded timeout" in entry["scope"]
    assert "computer_event" in MANIFEST["accept_actions"]
    assert "outcome_ack" not in MANIFEST["accept_actions"]
    assert "outcome_unknown" not in {item["name"] for item in MANIFEST["push_types"]}
    assert len(MANIFEST["accept_actions"]) == len(set(MANIFEST["accept_actions"]))


def test_shared_fixture_announce_and_acknowledgment_stay_conformant() -> None:
    announce = FIXTURE["announce"]
    assert announce["type"] == "ui_event" and announce["action"] == "computer_event"
    host = announce["payload"]["host"]
    assert announce["payload"]["host_id"] == host["host_id"]
    incarnation = host["incarnation_id"]
    assert len(incarnation) == 36 and incarnation == incarnation.lower()
    jobs = host["retained_jobs"]
    assert 1 <= len(jobs) <= 64
    assert len({job["job_id"] for job in jobs}) == len(jobs)
    for job in jobs:
        assert set(job) == {"job_id", "state", "exit_code", "signal", "output_bytes"}
        assert job["state"] in JOB_STATES
        assert isinstance(job["output_bytes"], int) and job["output_bytes"] >= 0
        if job["state"] == "running":
            assert job["exit_code"] is None and job["signal"] is None
    ack = FIXTURE["outcome_ack"]
    assert ack["action"] == "computer_event"
    assert set(ack["payload"]) == {"host_id", "event", "decision", "incarnation_id"}
    assert ack["payload"]["event"] == "outcome_ack"
    assert ack["payload"]["decision"] in {"acknowledge", "discard"}
    assert ack["payload"]["incarnation_id"] == incarnation
    receipt = FIXTURE["outcome_ack_receipt"]
    assert receipt["type"] == "computer_host"
    assert receipt["host_id"] == host["host_id"]
    assert set(receipt["outcome_ack"]) == {"decision", "incarnation_id", "connection_generation"}
    assert receipt["outcome_ack"]["decision"] == ack["payload"]["decision"]
    assert receipt["outcome_ack"]["incarnation_id"] == incarnation
    assert len(receipt["outcome_ack"]["connection_generation"]) == 36
    assert "output text never travels" in FIXTURE["never_on_the_wire"]["stdout"]
    assert "output_bytes" in FIXTURE["never_on_the_wire"]["stderr"]
    descriptor_shape = additive_field("computer_host")["shape"]
    assert descriptor_shape["incarnation_id"].startswith("canonical lowercase uuid4")
    for declared in ("job_id", "state", "exit_code", "signal", "output_bytes"):
        assert declared in descriptor_shape["retained_jobs"][0]


def test_frozen_client_local_vocabulary_is_unchanged() -> None:
    assert MANIFEST["client_local_actions"] == [
        "attach_existing",
        "computer_host_consent",
        "compose_prompt",
        "chrome_mesh_identity",
        "chrome_mesh_redeem",
    ]
    matrix = MANIFEST["presentation_contracts"]["disposition_matrix_088"]
    assert (
        matrix["vocabulary"]
        == "no new push type, component type, accept_action or client_local_action"
    )


@pytest.mark.parametrize(
    "field",
    [
        ("computer_host", "specs/076-remote-computer-control/contracts/transport.md"),
        ("outcome_ack", "accept_actions.computer_event"),
    ],
)
def test_entries_keep_their_declared_contract_binding(field: tuple[str, str]) -> None:
    assert additive_field(field[0])["contract"] == field[1]
