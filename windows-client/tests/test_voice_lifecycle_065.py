"""Feature 065 Windows permission, session, media, and teardown behavior."""

from __future__ import annotations

import hashlib
from datetime import datetime, timezone

import pytest

pytest.importorskip("PySide6")

from astral_client.voice import VoiceController, VoiceHttpError  # noqa: E402
from astral_client.protocol import validate_voice_recovery_envelope  # noqa: E402


DEVICE = "00000000-0000-4000-8000-000000000001"
CONNECTION = "00000000-0000-4000-8000-000000000002"
CHAT = "00000000-0000-4000-8000-000000000003"
SESSION = "00000000-0000-4000-8000-000000000004"
TURN = "00000000-0000-4000-8000-000000000005"
CLIENT_TURN = "00000000-0000-4000-8000-000000000006"
SUBMISSION = "00000000-0000-4000-8000-000000000007"
REQUEST = "00000000-0000-4000-8000-000000000008"
BINDING_ID = "00000000-0000-4000-8000-000000000009"
BINDING = "v1." + "a" * 64 + "." + "b" * 43


class FakeTransport:
    def __init__(self):
        self.connection_generation = CONNECTION
        self.sent = []
        self.playout = []

    def send_voice_transcript(self, frame):
        self.sent.append(frame)

    def send_voice_playout_event(self, frame):
        self.playout.append(frame)


class FakeAudio:
    def __init__(self, permission="authorized", microphone=True, output=True):
        self.permission = permission
        self.microphone = microphone
        self.output = output
        self.stopped = 0

    def capability(self):
        return {
            "has_microphone": self.microphone,
            "has_audio_output": self.output,
            "microphone_permission": self.permission,
            "full_duplex": self.microphone and self.output,
            "transport": "livekit",
        }

    def request_microphone_permission(self, callback):
        callback(self.permission)

    def stop_all(self):
        self.stopped += 1


class FakeHttp:
    def __init__(self):
        self.calls = []
        self.takeover_required = False

    def capability(self):
        self.calls.append(("capability", None))
        return {"schema_version": "1", "status": "ready", "reason": "ready"}

    def create(self, body, scope):
        self.calls.append(("create", body, scope))
        if self.takeover_required:
            return {
                "error": "voice_takeover_required",
                "current_session": {
                    "session_id": SESSION,
                    "generation": 3,
                    "media_grant_revision": 4,
                },
            }
        return _activation_response()

    def takeover(self, session_id, body, scope):
        self.calls.append(("takeover", session_id, body, scope))
        return _activation_response(generation=4, grant_revision=5)

    def update(self, session_id, body, scope):
        self.calls.append(("update", session_id, body, scope))
        return {"state": "active", **body}

    def end(self, session_id, generation, grant_revision, scope):
        self.calls.append(("end", session_id, generation, grant_revision, scope))

    def stop_speech(self, session_id, body, scope):
        self.calls.append(("stop_speech", session_id, body, scope))

    def current_media_grant(self, session_id, scope):
        self.calls.append(("current_media_grant", session_id, scope))
        return _grant_state()

    def refresh_media_grant(self, session_id, body, scope):
        self.calls.append(("refresh_media_grant", session_id, body, scope))
        return _refresh_response(refresh_id=body["refresh_id"])


class FakeMedia:
    def __init__(self):
        self.calls = []
        self.on_data = None
        self.on_state = None
        self.on_playout = None

    def connect(self, grant, audio, on_data, on_state, on_playout):
        self.calls.append(("connect", grant, audio))
        self.on_data = on_data
        self.on_state = on_state
        self.on_playout = on_playout
        on_state("connected", "")

    def authorize_announcement(self, manifest):
        self.calls.append(("authorize_announcement", manifest))

    def set_microphone_enabled(self, enabled):
        self.calls.append(("microphone", enabled))

    def stop_playback(self):
        self.calls.append(("stop_playback",))

    def close(self):
        self.calls.append(("close",))


def _activation_response(generation=2, grant_revision=4):
    return {
        "session": {
            "session_id": SESSION,
            "device_id": DEVICE,
            "device_kind": "windows",
            "transport": "livekit",
            "state": "active",
            "generation": generation,
            "media_grant_revision": grant_revision,
            "owner_connection_generation": CONNECTION,
            "visible_chat_id": CHAT,
            "applied_visible_chat_id": CHAT,
            "chat_context_revision": 3,
            "applied_chat_context_revision": 3,
            "chat_context_synced": True,
            "foreground_active": True,
            "foreground_reason": "foreground",
            "foreground_changed_at": "2026-07-31T18:00:00Z",
            "speech_muted": False,
            "microphone_enabled": True,
            "lease_expires_at": "2099-07-31T18:04:00Z",
            "started_at": "2026-07-31T18:00:00Z",
            "idle_expires_at": None,
        },
        "grant": {
            "grant_id": "grant-a",
            "transport": "livekit",
            "session_id": SESSION,
            "generation": generation,
            "media_grant_revision": grant_revision,
            "expires_at": "2099-07-31T18:05:00Z",
            "url": "ws://127.0.0.1:7880",
            "join_token": "secret-client-room-token-" + "x" * 40,
            "room_name": "voice-room",
            "participant_identity": "voice-client-a",
            "worker_identity": "voice-worker-a",
        },
    }


def _grant_state(*, connection=CONNECTION, generation=2, grant_revision=4):
    session = _activation_response(generation, grant_revision)["session"]
    session["owner_connection_generation"] = connection
    return {
        "session": session,
        "grant_state": {
            "transport": "livekit",
            "media_grant_revision": grant_revision,
            "status": "active",
            "expires_at": "2099-07-31T18:05:00Z",
        },
    }


def _refresh_response(
    *,
    refresh_id,
    connection=CONNECTION,
    generation=2,
    grant_revision=5,
    worker="voice-worker-a",
):
    value = _activation_response(generation, grant_revision)
    value["session"]["owner_connection_generation"] = connection
    value["grant"]["worker_identity"] = worker
    return {
        "refresh_id": refresh_id,
        "replayed": False,
        "replay_expires_at": "2099-07-31T18:05:00Z",
        **value,
    }


def test_remote_recovery_envelope_is_exact_and_refresh_bound(qapp):
    refresh_id = "00000000-0000-4000-8000-000000000010"
    value = _refresh_response(refresh_id=refresh_id)

    session, grant = validate_voice_recovery_envelope(value, refresh_id)
    assert session is value["session"]
    assert grant is value["grant"]

    with pytest.raises(ValueError, match="malformed"):
        validate_voice_recovery_envelope({**value, "credential": "forbidden"}, refresh_id)
    with pytest.raises(ValueError, match="malformed"):
        validate_voice_recovery_envelope(value, "00000000-0000-4000-8000-000000000011")


def _binding():
    return {
        "type": "voice_control_binding",
        "schema_version": "1",
        "device_id": DEVICE,
        "connection_generation": CONNECTION,
        "binding_id": BINDING_ID,
        "binding": BINDING,
        "expires_at": "2099-07-31T18:04:00Z",
    }


def _turn_state(*, state="succeeded", speech_outcome=...):
    frame = {
        "type": "voice_turn_state",
        "schema_version": "1",
        "session_id": SESSION,
        "connection_generation": CONNECTION,
        "generation": 2,
        "media_grant_revision": 4,
        "turn_id": TURN,
        "client_turn_id": CLIENT_TURN,
        "submission_id": SUBMISSION,
        "request_generation": REQUEST,
        "chat_id": CHAT,
        "chat_context_revision": 3,
        "detected_language": "en-US",
        "spoken_output_policy": "full_recap",
        "output_reason": "ready",
        "state": state,
        "foreground": False,
        "sensitive_result_pending": False,
        "sequence": 1,
        "occurred_at": "2026-07-31T18:00:01Z",
    }
    if speech_outcome is not ...:
        frame["speech_outcome"] = speech_outcome
    return frame


def _controller(audio=None):
    transport = FakeTransport()
    http = FakeHttp()
    media = FakeMedia()
    controller = VoiceController(
        device_id=DEVICE,
        token_provider=lambda: "token",
        http_base="http://127.0.0.1:8001",
        connection_provider=lambda: transport.connection_generation,
        chat_provider=lambda: CHAT,
        transport=transport,
        audio=audio or FakeAudio(),
        http=http,
        media=media,
        run_async=lambda work: work(),
    )
    controller.accept_frame(_binding())
    return controller, transport, http, media


@pytest.mark.parametrize(
    "speech_outcome",
    (..., "source_finished", "failed", "suppressed"),
)
def test_turn_reducer_accepts_optional_exact_speech_outcome(qapp, speech_outcome):
    controller, _transport, _http, _media = _controller()
    controller.handle_action("voice_session_start")

    assert controller.accept_frame(_turn_state(speech_outcome=speech_outcome))


def test_turn_reducer_rejects_unknown_speech_outcome(qapp):
    controller, _transport, _http, _media = _controller()
    controller.handle_action("voice_session_start")

    assert not controller.accept_frame(_turn_state(speech_outcome="provider_failed"))


def test_turn_reducer_rejects_speech_outcome_before_success(qapp):
    controller, _transport, _http, _media = _controller()
    controller.handle_action("voice_session_start")

    assert not controller.accept_frame(_turn_state(state="processing", speech_outcome="failed"))


@pytest.mark.parametrize(
    ("turn_state", "expected_phase"),
    (
        ("succeeded", "speaking_result"),
        ("failed", "listening"),
        ("refused", "listening"),
        ("cancelled", "listening"),
        ("abandoned", "listening"),
    ),
)
def test_terminal_turn_state_never_coerces_session_to_error(qapp, turn_state, expected_phase):
    controller, _transport, _http, _media = _controller()
    controller.handle_action("voice_session_start")

    assert controller.accept_frame(_turn_state(state=turn_state))
    assert controller.state == expected_phase


@pytest.mark.parametrize("audio", [FakeAudio(permission="denied"), FakeAudio(microphone=False)])
def test_denial_or_missing_microphone_never_opens_session_and_keeps_text_fallback(qapp, audio):
    controller, _transport, http, media = _controller(audio)
    states = []
    controller.status_changed.connect(lambda state, message: states.append((state, message)))

    controller.handle_action("voice_session_start")

    assert not any(call[0] == "create" for call in http.calls)
    assert not media.calls
    assert states[-1][0] == "unavailable"
    assert "microphone" in states[-1][1].lower()


def test_explicit_start_checks_readiness_and_uses_bound_authenticated_scope(qapp):
    controller, _transport, http, media = _controller()
    states = []
    controller.status_changed.connect(lambda state, message: states.append((state, message)))

    controller.handle_action("voice_session_start")

    assert [call[0] for call in http.calls[:2]] == ["capability", "create"]
    _, body, scope = http.calls[1]
    assert body["device_id"] == DEVICE
    assert body["device_kind"] == "windows"
    assert body["visible_chat_id"] == CHAT
    assert body["foreground_active"] is True
    assert body["capability"] == {
        "has_microphone": True,
        "has_audio_output": True,
        "microphone_permission": "authorized",
        "full_duplex": True,
        "transport": "livekit",
    }
    assert scope == {
        "device_id": DEVICE,
        "connection_generation": CONNECTION,
        "control_binding": BINDING,
    }
    assert media.calls[0][0] == "connect"
    assert media.calls[0][1]["worker_identity"] == "voice-worker-a"
    assert states[-1][0] == "greeting"


def test_takeover_requires_explicit_second_action_and_generation_fences(qapp):
    controller, _transport, http, media = _controller()
    http.takeover_required = True

    controller.handle_action("voice_session_start")
    assert not media.calls
    assert controller.takeover_session_id == SESSION

    controller.handle_action("voice_session_takeover")

    call = next(item for item in http.calls if item[0] == "takeover")
    assert call[1] == SESSION
    assert call[2]["expected_generation"] == 3
    assert call[2]["expected_media_grant_revision"] == 4
    assert media.calls[0][0] == "connect"


def test_stop_speech_stops_local_playout_before_server_request_runs(qapp):
    controller, _transport, http, media = _controller()
    controller.handle_action("voice_session_start")
    media.calls.clear()
    pending = []
    controller._run_async = pending.append

    controller.handle_action("voice_speech_stop")

    assert media.calls == [("stop_playback",)]
    assert not any(item[0] == "stop_speech" for item in http.calls)
    assert len(pending) == 1

    pending[0]()
    call = next(item for item in http.calls if item[0] == "stop_speech")
    assert call[1] == SESSION
    assert call[2] == {
        "expected_generation": 2,
        "expected_media_grant_revision": 4,
    }
    assert call[3] == {
        "device_id": DEVICE,
        "connection_generation": CONNECTION,
        "control_binding": BINDING,
    }
    assert media.calls == [("stop_playback",)]


def test_stop_speech_keeps_local_playout_stopped_when_server_request_fails(qapp):
    controller, _transport, http, media = _controller()
    controller.handle_action("voice_session_start")
    media.calls.clear()
    states = []
    controller.status_changed.connect(lambda state, message: states.append((state, message)))

    def fail_stop_speech(session_id, body, scope):
        http.calls.append(("stop_speech", session_id, body, scope))
        assert media.calls == [("stop_playback",)]
        raise VoiceHttpError("network_interrupted")

    http.stop_speech = fail_stop_speech
    controller.handle_action("voice_speech_stop")

    assert media.calls == [("stop_playback",)]
    assert [item[0] for item in http.calls].count("stop_speech") == 1
    assert states[-1] == ("error", "network_interrupted")


def test_server_idle_permission_revoke_and_explicit_end_release_media(qapp):
    controller, _transport, http, media = _controller()
    controller.handle_action("voice_session_start")

    idle = {
        "type": "voice_session_state",
        "schema_version": "1",
        "session_id": SESSION,
        "connection_generation": CONNECTION,
        "generation": 2,
        "media_grant_revision": 4,
        "visible_chat_id": CHAT,
        "chat_context_revision": 3,
        "applied_chat_context_revision": 3,
        "chat_context_synced": True,
        "state": "ended",
        "speech_muted": False,
        "microphone_enabled": False,
        "foreground_active": False,
        "reason": "idle_expired",
        "occurred_at": "2026-07-31T18:00:00Z",
    }
    assert controller.accept_frame(idle)
    assert media.calls[-1] == ("close",)

    controller, _transport, http, media = _controller()
    controller.handle_action("voice_session_start")
    controller.on_permission_changed("denied")
    assert media.calls[-1] == ("close",)
    assert any(call[0] == "update" for call in http.calls)

    controller, _transport, http, media = _controller()
    controller.handle_action("voice_session_start")
    controller.handle_action("voice_session_end")
    assert any(call[0] == "end" for call in http.calls)
    assert media.calls[-1] == ("close",)


def test_connection_rotation_discards_binding_and_stops_media_but_retains_recovery_fence(qapp):
    controller, _transport, _http, media = _controller()
    controller.handle_action("voice_session_start")

    controller.on_connection_rotated("00000000-0000-4000-8000-000000000010")

    assert controller.control_binding is None
    assert controller.control_binding_id is None
    assert controller.session_id == SESSION
    assert controller.generation == 2
    assert controller.media_grant_revision == 4
    assert controller.state == "reconnecting"
    assert media.calls[-1] == ("close",)


def test_connection_rotation_reads_current_state_and_rejoins_once_with_new_grant(qapp):
    controller, transport, http, media = _controller()
    controller.handle_action("voice_session_start")
    prior_on_data = media.on_data
    prior_on_state = media.on_state
    prior_on_playout = media.on_playout
    transport.connection_generation = "00000000-0000-4000-8000-000000000010"
    http.current_media_grant = lambda session_id, scope: (
        http.calls.append(("current_media_grant", session_id, scope))
        or _grant_state(connection=transport.connection_generation)
    )
    http.refresh_media_grant = lambda session_id, body, scope: (
        http.calls.append(("refresh_media_grant", session_id, body, scope))
        or _refresh_response(
            refresh_id=body["refresh_id"], connection=transport.connection_generation
        )
    )

    controller.on_connection_rotated(transport.connection_generation)
    binding = _binding()
    binding["connection_generation"] = transport.connection_generation
    binding["binding_id"] = "00000000-0000-4000-8000-000000000011"
    assert controller.accept_frame(binding)

    assert [call[0] for call in http.calls].count("current_media_grant") == 1
    assert [call[0] for call in http.calls].count("refresh_media_grant") == 1
    refresh = next(call for call in http.calls if call[0] == "refresh_media_grant")
    assert refresh[2]["expected_generation"] == 2
    assert refresh[2]["expected_media_grant_revision"] == 4
    assert refresh[2]["device_id"] == DEVICE
    assert refresh[3]["connection_generation"] == transport.connection_generation
    assert controller.session_id == SESSION
    assert controller.generation == 2
    assert controller.media_grant_revision == 5
    assert [call[0] for call in media.calls].count("connect") == 2

    controller.accept_frame(binding)
    assert [call[0] for call in http.calls].count("refresh_media_grant") == 1

    stale = _voice_transcript(final=True, text="old final")
    stale["media_grant_revision"] = 5
    prior_on_data("astraldeep.voice.transcript.v1", "voice-worker-a", stale)
    assert not transport.sent
    prior_on_state("disconnected", "old room closed")
    controller._on_media_playout = lambda *_args: (_ for _ in ()).throw(
        AssertionError("old playout callback crossed media epoch")
    )
    prior_on_playout({}, "started")
    assert controller.session_id == SESSION
    assert controller.media_grant_revision == 5


@pytest.mark.parametrize(
    "mutation",
    [
        "extra",
        "inactive",
        "expired_lease",
        "applied_chat_mismatch",
        "chat_revision_mismatch",
        "chat_unsynced",
    ],
)
def test_remote_recovery_current_state_is_exact_active_and_unexpired(qapp, mutation):
    controller, transport, http, media = _controller()
    controller.handle_action("voice_session_start")
    transport.connection_generation = "00000000-0000-4000-8000-000000000010"

    def current(_session_id, _scope):
        value = _grant_state(connection=transport.connection_generation)
        if mutation == "extra":
            value["session"]["credential"] = "forbidden"
        elif mutation == "inactive":
            value["session"]["state"] = "suspended"
        elif mutation == "expired_lease":
            value["session"]["lease_expires_at"] = "2020-01-01T00:00:00Z"
        elif mutation == "applied_chat_mismatch":
            value["session"]["applied_visible_chat_id"] = TURN
        elif mutation == "chat_revision_mismatch":
            value["session"]["applied_chat_context_revision"] = 2
        else:
            value["session"]["chat_context_synced"] = False
        return value

    http.current_media_grant = current
    refreshes = []
    http.refresh_media_grant = lambda *_args: refreshes.append(True)
    controller.on_connection_rotated(transport.connection_generation)
    binding = _binding()
    binding["connection_generation"] = transport.connection_generation
    binding["binding_id"] = "00000000-0000-4000-8000-000000000011"
    assert controller.accept_frame(binding)

    assert not refreshes
    assert [call[0] for call in media.calls].count("connect") == 1
    assert controller.state == "error"


def test_remote_recovery_rejects_when_retained_lease_already_expired(qapp):
    controller, transport, http, media = _controller()
    controller.handle_action("voice_session_start")
    controller.lease_expires_at = datetime(2020, 1, 1, tzinfo=timezone.utc)
    transport.connection_generation = "00000000-0000-4000-8000-000000000010"
    controller.on_connection_rotated(transport.connection_generation)
    binding = _binding()
    binding["connection_generation"] = transport.connection_generation
    binding["binding_id"] = "00000000-0000-4000-8000-000000000011"
    assert controller.accept_frame(binding)

    assert not any(call[0] == "current_media_grant" for call in http.calls)
    assert [call[0] for call in media.calls].count("connect") == 1


@pytest.mark.parametrize(
    ("mutation", "expected_fragment"),
    (
        ("session", "session"),
        ("generation", "session"),
        ("current_grant", "session"),
        ("grant_revision", "grant"),
        ("worker", "worker"),
    ),
)
def test_remote_recovery_rejects_stale_session_generation_grant_and_worker(
    qapp, mutation, expected_fragment
):
    controller, transport, http, media = _controller()
    controller.handle_action("voice_session_start")
    transport.connection_generation = "00000000-0000-4000-8000-000000000010"
    http.current_media_grant = lambda _session_id, _scope: _grant_state(
        connection=transport.connection_generation,
        grant_revision=5 if mutation == "current_grant" else 4,
    )

    refreshes = []

    def refreshed(_session_id, body, _scope):
        refreshes.append(body)
        value = _refresh_response(
            refresh_id=body["refresh_id"], connection=transport.connection_generation
        )
        if mutation == "session":
            value["session"]["session_id"] = "00000000-0000-4000-8000-000000000012"
            value["grant"]["session_id"] = value["session"]["session_id"]
        elif mutation == "generation":
            value["session"]["generation"] = 3
            value["grant"]["generation"] = 3
        elif mutation == "grant_revision":
            value["grant"]["media_grant_revision"] = 4
        else:
            value["grant"]["worker_identity"] = "voice-worker-b"
        return value

    http.refresh_media_grant = refreshed
    states = []
    controller.status_changed.connect(lambda state, message: states.append((state, message)))
    controller.on_connection_rotated(transport.connection_generation)
    binding = _binding()
    binding["connection_generation"] = transport.connection_generation
    binding["binding_id"] = "00000000-0000-4000-8000-000000000011"
    assert controller.accept_frame(binding)

    assert [call[0] for call in media.calls].count("connect") == 1
    assert controller.state == "error"
    assert expected_fragment in states[-1][1].lower()
    assert bool(refreshes) is (mutation != "current_grant")


def test_remote_recovery_preserves_submitted_final_dedupe_across_rejoin(qapp):
    controller, transport, http, media = _controller()
    controller.handle_action("voice_session_start")
    final = _voice_transcript(final=True, text="only once")
    media.on_data("astraldeep.voice.transcript.v1", "voice-worker-a", final)
    assert len(transport.sent) == 1

    transport.connection_generation = "00000000-0000-4000-8000-000000000010"
    http.current_media_grant = lambda _session_id, _scope: _grant_state(
        connection=transport.connection_generation
    )
    http.refresh_media_grant = lambda _session_id, body, _scope: _refresh_response(
        refresh_id=body["refresh_id"], connection=transport.connection_generation
    )
    controller.on_connection_rotated(transport.connection_generation)
    binding = _binding()
    binding["connection_generation"] = transport.connection_generation
    binding["binding_id"] = "00000000-0000-4000-8000-000000000011"
    assert controller.accept_frame(binding)

    media.on_data("astraldeep.voice.transcript.v1", "voice-worker-a", final)
    assert len(transport.sent) == 1


def test_foreground_lease_heartbeat_is_fenced_content_free_and_stops_on_teardown(
    qapp,
):
    controller, _transport, http, _media = _controller()
    controller.handle_action("voice_session_start")

    assert controller._lease_timer.interval() == 20_000
    assert controller._lease_timer.isActive()

    controller._renew_foreground_lease()
    heartbeat = [call for call in http.calls if call[0] == "update"][-1]
    assert heartbeat[1] == SESSION
    assert heartbeat[2] == {
        "expected_generation": 2,
        "expected_media_grant_revision": 4,
        "foreground_active": True,
        "foreground_reason": "foreground",
    }
    assert "interaction" not in heartbeat[2]
    assert heartbeat[3] == {
        "device_id": DEVICE,
        "connection_generation": CONNECTION,
        "control_binding": BINDING,
    }

    controller.set_foreground_active(False, "backgrounded")
    assert not controller._lease_timer.isActive()
    updates_before = len([call for call in http.calls if call[0] == "update"])
    controller._renew_foreground_lease()
    assert len([call for call in http.calls if call[0] == "update"]) == updates_before

    controller.set_foreground_active(True, "foreground")
    assert controller._lease_timer.isActive()
    resume = [call for call in http.calls if call[0] == "update"][-1][2]
    assert resume["foreground_active"] is True
    assert resume["foreground_reason"] == "foreground"
    assert "interaction" not in resume

    controller.handle_action("voice_session_end")
    assert not controller._lease_timer.isActive()


def test_partial_preview_and_one_final_submission_from_expected_worker(qapp):
    controller, transport, _http, media = _controller()
    previews = []
    controller.transcript_changed.connect(lambda text, final: previews.append((text, final)))
    controller.handle_action("voice_session_start")

    partial = _voice_transcript(final=False, text="Open my")
    media.on_data("astraldeep.voice.transcript.v1", "voice-worker-a", partial)
    assert previews[-1] == ("Open my", False)
    assert not transport.sent

    final = _voice_transcript(final=True, text="Open my schedule")
    media.on_data("astraldeep.voice.transcript.v1", "voice-worker-a", final)
    media.on_data("astraldeep.voice.transcript.v1", "voice-worker-a", final)

    assert previews[-1] == ("Open my schedule", True)
    assert len(transport.sent) == 1


def test_wrong_worker_empty_final_and_old_generation_never_submit(qapp):
    controller, transport, _http, media = _controller()
    controller.handle_action("voice_session_start")

    media.on_data(
        "astraldeep.voice.transcript.v1",
        "voice-worker-b",
        _voice_transcript(),
    )
    empty = _voice_transcript()
    empty["text"] = ""
    media.on_data("astraldeep.voice.transcript.v1", "voice-worker-a", empty)
    stale = _voice_transcript()
    stale["generation"] = 1
    media.on_data("astraldeep.voice.transcript.v1", "voice-worker-a", stale)

    assert not transport.sent


def test_navigation_does_not_rebind_recognition_time_background_turn(qapp):
    active = {"chat": CHAT}
    transport = FakeTransport()
    http = FakeHttp()
    media = FakeMedia()
    controller = VoiceController(
        device_id=DEVICE,
        token_provider=lambda: "token",
        http_base="http://127.0.0.1:8001",
        connection_provider=lambda: CONNECTION,
        chat_provider=lambda: active["chat"],
        transport=transport,
        audio=FakeAudio(),
        http=http,
        media=media,
        run_async=lambda work: work(),
    )
    controller.accept_frame(_binding())
    controller.handle_action("voice_session_start")
    active["chat"] = "00000000-0000-4000-8000-000000000010"

    media.on_data(
        "astraldeep.voice.transcript.v1",
        "voice-worker-a",
        _voice_transcript(),
    )

    assert len(transport.sent) == 1
    assert transport.sent[0]["chat_id"] == CHAT


def _voice_transcript(*, final=True, text="Open my schedule"):
    value = {
        "type": "voice_transcript",
        "schema_version": "1",
        "session_id": SESSION,
        "generation": 2,
        "turn_id": TURN,
        "client_turn_id": CLIENT_TURN,
        "submission_id": SUBMISSION,
        "request_generation": REQUEST,
        "chat_id": CHAT,
        "chat_context_revision": 3,
        "media_grant_revision": 4,
        "sequence": 2 if final else 1,
        "final": final,
        "text": text,
        "detected_language": "en" if final else None,
        "source_participant_identity": "voice-worker-a",
    }
    if final:
        value.update(
            {
                "text_digest_sha256": hashlib.sha256(text.encode()).hexdigest(),
                "transcript_proof": "a" * 64,
                "proof_expires_at": "2099-07-31T18:02:00Z",
            }
        )
    return value
