"""Python-gate drift guards for the Android client-local speech candidate.

They lock the runtime's outbound frame shapes and reasons to the frozen client_local/v1 contract,
keep the server-selected activation on the shared authenticated dispatch, and require the
acceptance-criteria scenario suites to stay present in the Android lanes that run them.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "android-client/core/src/main/kotlin/com/personalailabs/astraldeep/core/protocol"
APP = ROOT / "android-client/app/src/main/kotlin/com/personalailabs/astraldeep/app"
MESSAGES = CORE / "Messages.kt"
WIRE = CORE / "Wire.kt"
VOICE = APP / "voice"
RUNTIME = VOICE / "LocalVoiceRuntime.kt"
ENGINE = VOICE / "LocalSpeechEngine.kt"
CONTROLLER = VOICE / "VoiceSessionController.kt"
TRANSPORT = APP / "transport/OrchestratorClient.kt"
APP_VIEW_MODEL = APP / "ui/AppViewModel.kt"
APP_TESTS = ROOT / "android-client/app/src/test/kotlin/com/personalailabs/astraldeep/app"
ANDROID_TESTS = ROOT / "android-client/app/src/androidTest/kotlin/com/personalailabs/astraldeep/app"

OUTBOUND_FRAMES = frozenset(
    {
        "voice_local_ready",
        "voice_local_recognition_started",
        "voice_local_final",
        "voice_local_recognition_failed",
        "voice_local_playout_event",
    }
)

SERVER_FRAMES = frozenset(
    {"voice_local_session_ready", "voice_local_turn_bound", "voice_local_final_rejected", "voice_local_announcement"}
)


def _quoted(block: str) -> set[str]:
    return set(re.findall(r'"([a-z0-9_.-]+)"', block))


def _frozen_common() -> set[str]:
    text = MESSAGES.read_text(encoding="utf-8")
    return _quoted(re.search(r"private val common =\s*setOf\(([^)]*)\)", text, re.DOTALL).group(1))


def _frozen_frame_fields() -> dict[str, set[str]]:
    text = MESSAGES.read_text(encoding="utf-8")
    common = _frozen_common()
    return {
        frame: common | _quoted(details)
        for frame, details in re.findall(r'"(voice_local_[a-z_]+)" to common \+ setOf\(([^)]*)\)', text)
    }


def _frozen_reasons() -> set[str]:
    text = MESSAGES.read_text(encoding="utf-8")
    return _quoted(re.search(r"val reasons =\s*setOf\((.*?)\)\n", text, re.DOTALL).group(1))


def _runtime_emitted_keys() -> dict[str, set[str]]:
    text = RUNTIME.read_text(encoding="utf-8")
    shapes: dict[str, set[str]] = {}
    for match in re.finditer(r'common\("(voice_local_[a-z_]+)"', text):
        opening = text.rindex("buildJsonObject {", 0, match.start())
        depth = 0
        end = len(text)
        for index in range(text.index("{", opening), len(text)):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    end = index
                    break
        segment = text[opening:end]
        shapes.setdefault(match.group(1), set()).update(re.findall(r'put\("([a-z0-9_]+)"', segment))
    return shapes


def test_runtime_outbound_frames_match_the_frozen_field_sets() -> None:
    frozen = _frozen_frame_fields()
    common = _frozen_common()
    shapes = _runtime_emitted_keys()
    assert set(shapes) == OUTBOUND_FRAMES
    for frame in ("voice_local_recognition_started", "voice_local_final", "voice_local_recognition_failed"):
        assert shapes[frame] == frozen[frame] - common, frame
    assert shapes["voice_local_playout_event"] == frozen["voice_local_playout_event"] - common | {"reason"}


def test_ready_advertises_exactly_the_frozen_capability_plus_client_sequence() -> None:
    shapes = _runtime_emitted_keys()
    assert shapes["voice_local_ready"] == {"client_sequence"}
    engine = ENGINE.read_text(encoding="utf-8")
    segment = engine[engine.index("fun toJson(): JsonObject") : engine.index("data class LocalSpeechVerdict")]
    capability = set(re.findall(r'put\("([a-z0-9_]+)"', segment))
    assert capability == _frozen_frame_fields()["voice_local_ready"] - _frozen_common() - {"client_sequence"}
    assert 'put("contract", "client_local/v1")' in engine
    assert 'put("transport", "client_local")' in engine
    assert 'put("configured_locale", "en-US")' in engine
    assert 'put("full_duplex", false)' in engine
    assert 'put("recognition_processing", "guaranteed_local")' in engine
    assert 'put("synthesis_processing", "guaranteed_local")' in engine
    assert 'put("recognition_locale", "ready")' in engine
    assert 'put("synthesis_locale", "ready")' in engine


def test_readiness_reasons_stay_inside_the_shared_closed_set() -> None:
    reasons = _frozen_reasons()
    field_names = set().union(*_frozen_frame_fields().values())
    pattern = r'"((?:local|stale|stopped|no_|microphone|speech_recognition)[a-z_]+)"'
    candidates = set(re.findall(pattern, ENGINE.read_text(encoding="utf-8") + RUNTIME.read_text(encoding="utf-8")))
    candidates -= field_names
    assert {
        "microphone_permission_denied",
        "local_language_download_required",
        "local_synthesis_unavailable",
        "local_processing_not_guaranteed",
    } <= candidates
    assert candidates <= reasons, sorted(candidates - reasons)


def test_recognition_failure_reasons_stay_inside_the_shared_closed_set() -> None:
    runtime = RUNTIME.read_text(encoding="utf-8")
    block = re.search(r"private val RECOGNITION_FAILURE_REASONS =\s*setOf\(([^)]*)\)", runtime, re.DOTALL).group(1)
    emitted = _quoted(block)
    assert {"local_recognition_failed", "local_audio_interrupted", "stopped_by_user", "local_engine_lost"} <= emitted
    assert emitted <= _frozen_reasons(), sorted(emitted - _frozen_reasons())


def test_runtime_consumes_exactly_the_server_selected_local_frames() -> None:
    runtime = RUNTIME.read_text(encoding="utf-8")
    literals = set(re.findall(r'"(voice_local_[a-z_]+)"', runtime))
    assert SERVER_FRAMES <= literals
    assert literals <= SERVER_FRAMES | OUTBOUND_FRAMES
    for handler in ("acceptSessionReady", "acceptTurnBound", "acceptFinalRejected", "acceptAnnouncement"):
        assert re.search(rf"{handler}\(frame\.payload\)|\b{handler}\(", runtime), handler


def test_wire_still_routes_the_server_local_frames_to_the_typed_parser() -> None:
    wire = WIRE.read_text(encoding="utf-8")
    routed = re.search(
        r'"(voice_local_[a-z_]+)", "(voice_local_[a-z_]+)", "(voice_local_[a-z_]+)", "(voice_local_[a-z_]+)" ->\s*'
        r"LocalVoiceFrame\.fromJson\(root\)",
        wire,
    )
    assert routed is not None
    assert set(routed.groups()) == SERVER_FRAMES


def test_activation_stays_on_the_shared_authenticated_dispatch() -> None:
    controller = CONTROLLER.read_text(encoding="utf-8")
    assert "/api/voice/v2/capability" in controller
    assert "/api/voice/v2/sessions" in controller
    assert 'put("device_kind", "android")' in controller
    assert 'put("client_capability", capability.toJson())' in controller
    bearer = re.findall(r'header\("Authorization", "Bearer ([^"]*)"\)', controller)
    assert bearer and set(bearer) == {"${binding.token}"}
    assert "SpeechRecognizer" not in controller
    assert "TextToSpeech" not in controller


def test_local_frames_dispatch_through_the_live_socket_and_never_queue_offline() -> None:
    transport = TRANSPORT.read_text(encoding="utf-8")
    body = re.search(r"fun sendVoiceLocalFrame\(frame: String\): Boolean \{(.*?)\n    \}", transport, re.DOTALL).group(1)
    assert "currentSocket.send(frame)" in body
    assert "pending" not in body
    assert "enqueueOrSend" not in body
    view_model = APP_VIEW_MODEL.read_text(encoding="utf-8")
    assert "voiceController?.setLocalFrameSender(client::sendVoiceLocalFrame)" in view_model


def test_acceptance_scenario_suites_stay_present_in_the_android_lanes() -> None:
    suites = {
        APP_TESTS / "voice/LocalVoiceRuntime075Test.kt": [
            "staleConnectionSessionGenerationAndRevisionFramesAreRefused",
            "finalWaitsForTurnBindingThenSendsOneImmutableFrameAndRetriesExactBytesUntilExactAck",
            "boundTurnsRejectDuplicateAndUnknownBindingsWithoutResendingTheFinal",
            "backgroundSuspendsEverythingAndResumeRequiresANewHandshake",
            "muteStopsSpeechAndPlayoutAndUnmuteReauthorizesBeforeRecognition",
            "announcementExpiryInterruptsPlayoutAndReportsExpired",
            "interruptedSynthesisReportsFailedAndEchoSuppressesTheNextCycle",
            "echoSuppressionDelaysRecognitionRestartAfterFinishedPlayout",
        ],
        APP_TESTS / "voice/LocalSpeechReadiness075Test.kt": [
            "permissionDenialAndUndeterminedKeepTypedFallback",
            "missingRecognitionLanguageAndInstallationStatesKeepTypedFallback",
            "missingSynthesisAndAudioHardwareKeepTypedFallback",
        ],
        APP_TESTS / "voice/VoiceSessionController075LocalTest.kt": [
            "permissionDenialRefusesLocalActivationBeforeAnyLocalSessionRequest",
            "missingRecognitionLanguageKeepsTypedFallbackWithoutASessionRequest",
            "remoteSelectionKeepsTheLiveKitActivationPath",
            "connectionLostTearsDownTheLocalSessionAndRefusesLaterLocalFrames",
        ],
        APP_TESTS / "transport/LocalVoiceTransport075Test.kt": ["sendVoiceLocalFrame"],
    }
    for path, markers in suites.items():
        text = path.read_text(encoding="utf-8")
        assert text.startswith("//"), path
        for marker in markers:
            assert marker in text, (path.name, marker)
    instrumented = (ANDROID_TESTS / "LocalSpeechFallback075InstrumentedTest.kt").read_text(encoding="utf-8")
    assert "LocalSpeechReadiness.evaluate" in instrumented
    assert "AndroidLocalSpeechEngine" in instrumented


def test_frozen_voice_fixture_guards_stay_pinned() -> None:
    core_test = (ROOT / "android-client/core/src/test/kotlin/com/personalailabs/astraldeep/core/protocol").joinpath(
        "VoiceContract065Test.kt"
    )
    text = core_test.read_text(encoding="utf-8")
    assert "bc98077594fa8d51dd664fadefaa48cf596a94e7fb2a961a972dbabca4f02143" in text
    build = (ROOT / "android-client/app/build.gradle.kts").read_text(encoding="utf-8")
    assert "59b77d9acbfd4c40ec9c2eaa50c30e30090c8da7ff7026786d1f77d8c5984b04" in build
