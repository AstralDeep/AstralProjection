"""Regression guards for the bounded mobile voice interruption and recovery qualification.

They pin the deterministic Apple and Android scenario wiring, the single-accepted-turn fencing
assertions, and the evidence hygiene and bounded offline runtime of the extended producers.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

APPLE_FIXTURE = ROOT / "apple-clients/AstralApp/AstralApp/FirstLoginUITestFixture.swift"
APPLE_UNIT = ROOT / "apple-clients/AstralApp/AstralAppTests/VoiceSessionController065Tests.swift"
APPLE_UI = ROOT / "apple-clients/AstralApp/AstralAppUITests/VoiceConversationUITests.swift"
APPLE_EVIDENCE = ROOT / "apple-clients/AstralApp/AstralAppUITests/ReleaseEvidenceUITests.swift"
ANDROID_SCENARIO = (
    ROOT / "android-client/app/src/androidTest/kotlin/com/personalailabs/astraldeep/app"
    "/VoiceInterruptionRecovery065InstrumentedTest.kt"
)
ANDROID_EVIDENCE = (
    ROOT / "android-client/app/src/androidTest/kotlin/com/personalailabs/astraldeep/app"
    "/ReleaseEvidenceInstrumentedTest.kt"
)

SCENARIO_NAMES = ("voice-interruption", "voice-recovery")
ACCEPTED_TURN = "00000000-0000-4000-8000-000000000015"
INTERRUPTED_TURN = "00000000-0000-4000-8000-000000000005"
TRANSCRIPT_PAYLOADS = ("Review the result", "check my schedule", "Please review")
CREDENTIAL_MARKERS = ("join_token", "joinToken", "api_key", "Bearer ", "access_token=")
RUNTIME_DIGEST_FIELDS = (
    "voice_worker_image_sha256",
    "livekit_image_sha256",
    "livekit_config_sha256",
    "speech_profile_sha256",
)


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


def test_apple_fixture_installs_deterministic_interruption_and_recovery_scenarios():
    source = APPLE_FIXTURE.read_text(encoding="utf-8")
    assert 'case voiceInterruption = "voice-interruption"' in source
    assert 'case voiceRecovery = "voice-recovery"' in source
    assert "case .voiceComposer, .voiceTerminal, .voiceInterruption, .voiceRecovery:" in source
    assert "if scenario == .voiceInterruption { installVoiceInterruption(on: model) }" in source
    assert "if scenario == .voiceRecovery { installVoiceRecovery(on: model) }" in source

    interruption = section(
        source,
        "private static func installVoiceInterruption",
        ("private static func installVoiceRecovery",),
    )
    assert "revision: 8" in interruption
    assert "model.voiceDeviceId" in interruption
    assert "preconditionFailure" in interruption

    recovery = section(
        source,
        "private static func installVoiceRecovery",
        ("private static func fixtureVoiceConnection",),
    )
    assert "revision: 8" in recovery and "revision: 9" in recovery
    assert "owned: false" in recovery
    frames = recovery[recovery.index("let turnFrames = [") :]
    assert f'let acceptedTurn = "{ACCEPTED_TURN}"' in recovery
    assert frames.index(f'turnId: "{INTERRUPTED_TURN}"') < frames.index("turnId: acceptedTurn")
    assert frames.count("turnId: acceptedTurn") == 2
    assert "installTerminalNoticeForUITesting(turn)" in recovery

    composer = section(
        source,
        "private static func ownedActiveComposer",
        ("private static func interruptionTurn",),
    )
    for field in (
        '"available"',
        '"state"',
        '"speech_muted"',
        '"microphone_enabled"',
        '"foreground_active"',
        '"reason"',
        '"output_locale"',
        '"chat_context_revision"',
        '"applied_chat_context_revision"',
        '"chat_context_synced"',
        '"controls"',
    ):
        assert field in composer, f"composer template lost required field {field}"
    assert "owner_device" in composer
    assert '"owner_device":null' in composer or 'owner_device\\":null' in composer


def test_apple_interruption_fixture_stays_debug_only_and_media_free():
    source = APPLE_FIXTURE.read_text(encoding="utf-8")
    assert source.splitlines()[0] == "#if DEBUG"
    for installer in ("installVoiceInterruption", "installVoiceRecovery"):
        body = section(source, f"private static func {installer}", ("private static func",))
        for banned in (
            "URLSession",
            "AVAudioSession",
            "AVAudioPlayer",
            "AVAudioRecorder",
            "LiveKit",
            "media.connect",
            "activate()",
        ):
            assert banned not in body, f"{installer} must not open media or transport: {banned}"


def test_apple_ui_tests_pin_interruption_recovery_states_and_typed_fallback():
    source = APPLE_UI.read_text(encoding="utf-8")
    for name in SCENARIO_NAMES:
        assert f'"{name}"' in source

    interruption = section(
        source,
        "func testInterruptedVoiceSessionKeepsServerControlsAndTypedFallbackAvailable",
        ("func testRecoveredVoice",),
    )
    assert 'status.label.contains("Voice media is reconnecting")' in interruption
    assert 'app.buttons["voice-control-voice-end"]' in interruption
    assert "composer.isEnabled" in interruption
    assert "composer.isHittable" in interruption
    assert '["voice-request-terminal-notice"].exists' in interruption

    recovery = section(
        source,
        "func testRecoveredVoiceAcceptsExactlyOneTurnAndStaysFencedAgainstStaleNoticeReplays",
    )
    assert 'status.label.contains("Listening…")' in recovery
    assert "waitForNonExistence(timeout: 3)" in recovery
    assert "composer.isEnabled" in recovery
    assert "composer.isHittable" in recovery


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


def test_android_scenario_drives_real_controller_with_bounded_offline_runtime():
    source = ANDROID_SCENARIO.read_text(encoding="utf-8")
    assert "org.junit.Assume" not in source
    assert re.search(r"^class VoiceInterruptionRecovery065InstrumentedTest\b", source, re.MULTILINE)
    assert source.count("@Test") == 1
    assert "VoiceSessionController(" in source
    assert "setTranscriptSubmitter" in source
    assert "setPlayoutReporter" in source
    assert "retryDelayMillis = 3_600_000L" in source
    assert "while (true)" not in source
    assert "Thread.sleep" not in source
    assert "delay(" not in source

    scenario = section(
        source,
        "fun interruptionRecoversIntoExactlyOneAcceptedTurnWithFencedStaleReplaysAndResumedPlayout()",
        ("private fun greetingData",),
    )
    assert 'sessionState(state = "reconnecting", reason = "network_interrupted")' in scenario
    assert 'assertEquals("reconnecting", controller.state.value.phase)' in scenario
    assert 'assertEquals("network_interrupted", controller.state.value.reason)' in scenario
    assert '"Voice connection was interrupted. Typed chat is still available."' in scenario
    assert 'performTextInput("typed fallback during interruption")' in scenario
    assert 'sessionState(state = "listening", reason = "ready")' in scenario
    assert 'assertEquals("greeting", controller.state.value.phase)' in scenario
    assert "assertEquals(1, controller.state.value.awaitingAcceptance)" in scenario
    assert "assertEquals(listOf(SUBMISSION_ID to CONNECTION_ID), submissions)" in scenario
    assert "acked(connectionGeneration = OTHER_CONNECTION_ID)" in scenario
    assert "acked(connectionGeneration = CONNECTION_ID)" in scenario
    assert "assertEquals(0, controller.state.value.awaitingAcceptance)" in scenario
    assert 'assertEquals("speaking_result", controller.state.value.phase)' in scenario
    assert "assertEquals(1, submissions.size)" in scenario
    assert "assertEquals(2, media.announcements.size)" in scenario
    assert 'assertEquals(listOf("greeting" to "started", "result" to "started"), playoutEvents)' in scenario
    assert "controller.close()" in scenario

    rendered = section(source, "rule.setContent {", ("rule.waitForIdle()",))
    assert "VoiceFeedback(voice)" in rendered
    assert "ConsoleComposer(" in rendered
    assert 'onNodeWithTag("chat-input").assertIsEnabled()' in scenario


def test_android_evidence_check_records_only_identities_and_outcome_categories():
    source = ANDROID_EVIDENCE.read_text(encoding="utf-8")
    assert 'recordCheck("voice_conversation_interruption"' in source
    order = section(source, "val order =", ('assertTrue("checks never produced evidence"',))
    assert '"voice_conversation_interruption",' in order

    producer = section(
        source,
        "private fun runVoiceConversationInterruption(",
        ("private fun runSignIn(",),
    )
    assert 'put("scenario_count"' in producer
    assert 'put("component_apk_sha256"' in producer
    assert 'put("runtime_identity"' in producer
    assert '"outcome_categories"' in producer
    for digest in RUNTIME_DIGEST_FIELDS:
        assert f'put("{digest}"' in producer

    scenario_class = section(source, "private class VoiceInterruptionScenario(")
    labels = re.findall(r'categories \+= "([a-z0-9_]+)"', scenario_class)
    initial = re.search(r'val categories = mutableListOf\("([a-z0-9_]+)"\)', scenario_class)
    assert initial is not None
    category_labels([initial.group(1), *labels])


def test_apple_evidence_check_records_only_identities_and_outcome_categories():
    source = APPLE_EVIDENCE.read_text(encoding="utf-8")
    assert 'runCheck("voice_conversation_interruption", recorder: recorder)' in source

    producer = section(
        source,
        "private func runVoiceConversationInterruption(",
        ("private func runVoiceInterruptionFixture(",),
    )
    for key in ("scenario_count", "component_identity", "runtime_identity", "outcome_categories", "duration_ms"):
        assert f'"{key}":' in producer

    identities = section(source, "func voiceRuntimeDigestIdentities()", ("func checkRecord(",))
    for digest in RUNTIME_DIGEST_FIELDS:
        assert f'"{digest}"' in identities

    labels = re.findall(r'"([a-z0-9_]+)",\n', producer)
    category_labels([label for label in labels if label.startswith(("interruption_", "recovered_", "single_", "typed_", "server_"))])


def test_evidence_producers_record_no_transcript_audio_or_credential_content():
    apple = APPLE_EVIDENCE.read_text(encoding="utf-8")
    for payload in TRANSCRIPT_PAYLOADS:
        assert payload not in apple

    android = ANDROID_EVIDENCE.read_text(encoding="utf-8")
    producer = section(android, "private fun runVoiceConversationInterruption(", ("private fun runSignIn(",))
    scenario_run = section(android, "fun run(): List<String> {", ("private fun activeComposer()",))
    for payload in TRANSCRIPT_PAYLOADS:
        assert payload not in producer
        assert payload not in scenario_run
    for marker in CREDENTIAL_MARKERS:
        assert marker not in producer
        assert marker not in scenario_run
    for leaked in ('put("transcript', "transcriptPreview", "state.value.message"):
        assert leaked not in producer
        assert leaked not in scenario_run


def test_new_mobile_coverage_stays_bounded_without_soak_loops():
    for path in (APPLE_UNIT, APPLE_UI, APPLE_EVIDENCE, ANDROID_SCENARIO):
        source = path.read_text(encoding="utf-8")
        assert "while (true)" not in source
        assert "while true" not in source

    android_evidence = ANDROID_EVIDENCE.read_text(encoding="utf-8")
    scenario_class = section(
        android_evidence,
        "private class VoiceInterruptionScenario(",
        ("private companion object",),
    )
    assert "while (" not in scenario_class
    assert "while (true)" not in section(
        android_evidence,
        "private fun runVoiceConversationInterruption(",
        ("private fun runSignIn(",),
    )

    poll = section(
        APPLE_UNIT.read_text(encoding="utf-8"),
        "private func waitForVoicePhase(",
        ("private func restStartResponse(",),
    )
    assert "for _ in 0..<200" in poll
    assert "nanoseconds: 5_000_000" in poll


def test_scenario_names_are_shared_between_fixture_ui_and_evidence_producers():
    fixture = APPLE_FIXTURE.read_text(encoding="utf-8")
    ui = APPLE_UI.read_text(encoding="utf-8")
    evidence = APPLE_EVIDENCE.read_text(encoding="utf-8")
    for name in SCENARIO_NAMES:
        assert f'"{name}"' in fixture
        assert f'"{name}"' in ui
        assert f'"{name}"' in evidence
