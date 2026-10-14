"""Regression guards for the mobile voice qualification added for the voice conversation feature.

They pin the deterministic Apple interruption and recovery scenario, the evidence producer hygiene
boundaries, and the bounded offline runtime of the coverage that ships in required lanes.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

APPLE_UNIT = ROOT / "apple-clients/AstralApp/AstralAppTests/VoiceSessionController065Tests.swift"
APPLE_UI = ROOT / "apple-clients/AstralApp/AstralAppUITests/VoiceConversationUITests.swift"
APPLE_EVIDENCE = ROOT / "apple-clients/AstralApp/AstralAppUITests/ReleaseEvidenceUITests.swift"
ANDROID_EVIDENCE = (
    ROOT / "android-client/app/src/androidTest/kotlin/com/personalailabs/astraldeep/app"
    "/ReleaseEvidenceInstrumentedTest.kt"
)

RUNTIME_DIGEST_FIELDS = (
    "voice_worker_image_sha256",
    "livekit_image_sha256",
    "livekit_config_sha256",
    "speech_profile_sha256",
)
TRANSCRIPT_PAYLOADS = ("Review the result", "check my schedule", "Please review")
CREDENTIAL_MARKERS = ("join_token", "joinToken", "Bearer ", "access_token=")


def section(source: str, start: str, stop: tuple[str, ...] = ()) -> str:
    begin = source.index(start)
    if not stop:
        return source[begin:]
    ends = [end for end in (source.find(token, begin + len(start)) for token in stop) if end != -1]
    assert ends, f"no section terminator found after {start!r}"
    return source[begin : min(ends)]


def category_labels(labels: list[str]) -> None:
    assert labels, "outcome category vocabulary must not be empty"
    for label in labels:
        assert re.fullmatch(r"[a-z0-9_]+", label), f"category label is not a closed token: {label!r}"


def test_apple_unit_scenario_proves_single_accepted_turn_and_fenced_stale_output():
    source = APPLE_UNIT.read_text(encoding="utf-8")
    scenario = section(
        source,
        "func testInterruptionDuringSpeechRecoversIntoExactlyOneAcceptedTurnWithFencedStaleOutput",
        ("func testTerminalRequestNoticeSurvivesChurnAndClearsForANewerActiveTurn",),
    )
    assert "greetingAnnouncement(sequence: 1)" in scenario
    assert 'phase: "started"' in scenario
    assert '"speaking_progress"' in scenario
    assert "media.emit(.failed)" in scenario
    assert 'waitForVoicePhase(controller, "listening")' in scenario
    assert "finalTranscript(revision: 3)" in scenario
    assert "Set(submissions).count, 1" in scenario
    assert "controller.awaitingAcceptance, 1" in scenario
    assert "ack(connection: connection)" in scenario
    assert "controller.awaitingAcceptance, 0" in scenario
    assert 'announcement(sequence: 5, sid: "TR_result_recovered", revision: 3)' in scenario
    assert '"speaking_result"' in scenario
    assert scenario.count("finalTranscript(revision: 2)") == 1
    assert scenario.count("acceptedSubmissionCount") == 3
    assert "XCTAssertNil(controller.terminalNotice)" in scenario


def test_apple_evidence_check_records_only_identities_and_outcome_categories():
    source = APPLE_EVIDENCE.read_text(encoding="utf-8")
    assert 'runCheck("voice_terminal_failure_and_typed_fallback", recorder: recorder)' in source

    producer = section(
        source,
        "private func runVoiceTerminalFailureEvidence(",
        ("private func macOSPersonalAgentHostProduction(",),
    )
    assert '"fixture_count":' in producer
    assert '"component_identity":' in producer
    assert '"runtime_identity":' in producer
    assert '"outcome_categories":' in producer
    assert '"duration_ms":' in producer
    for digest in RUNTIME_DIGEST_FIELDS:
        assert f'"{digest}"' in source

    labels = re.findall(r'"([a-z0-9_]+)",\n', producer)
    category_labels(
        [label for label in labels if label.startswith(("voice_", "typed_", "server_"))]
    )


def test_apple_evidence_check_uses_only_proven_fixture_scenarios():
    source = APPLE_EVIDENCE.read_text(encoding="utf-8")
    producer = section(
        source,
        "private func runVoiceTerminalFailureEvidence(",
        ("private func macOSPersonalAgentHostProduction(",),
    )
    assert '"voice-composer"' in producer
    assert '"voice-terminal"' in producer
    ui = APPLE_UI.read_text(encoding="utf-8")
    for scenario in ("voice-composer", "voice-terminal"):
        assert f'"{scenario}"' in ui, f"{scenario} must stay a proven UI fixture scenario"


def test_evidence_producers_record_no_transcript_audio_or_credential_content():
    for path in (APPLE_EVIDENCE, ANDROID_EVIDENCE):
        source = path.read_text(encoding="utf-8")
        for payload in TRANSCRIPT_PAYLOADS:
            assert payload not in source, f"{path.name} must not record transcript content"
        for marker in CREDENTIAL_MARKERS:
            assert marker not in source, f"{path.name} must not record credential material"


def test_android_evidence_producer_keeps_voice_runtime_identity_framework():
    source = ANDROID_EVIDENCE.read_text(encoding="utf-8")
    assert '"voice_runtime"' in source
    for digest in RUNTIME_DIGEST_FIELDS[:3]:
        assert f'"{digest}"' in source
    assert "worker_paths" in source
    assert "voice" in source


def test_new_mobile_coverage_stays_bounded_without_soak_loops():
    for path in (APPLE_UNIT, APPLE_UI, APPLE_EVIDENCE):
        source = path.read_text(encoding="utf-8")
        assert "while (true)" not in source
        assert "while true" not in source

    poll = section(
        APPLE_UNIT.read_text(encoding="utf-8"),
        "private func waitForVoicePhase(",
        ("private func restStartResponse(",),
    )
    assert "for _ in 0..<200" in poll
    assert "nanoseconds: 5_000_000" in poll
