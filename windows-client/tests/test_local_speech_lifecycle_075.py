"""P0 lifecycle contract for the Windows client-local speech path.

These tests deliberately keep time, scheduling, permission resolution, and HTTP
work under caller control.  The web client implements the same lifecycle, so
these assertions are parity guards rather than Windows-specific policy.
"""

from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import hashlib
from typing import Any, Callable

import pytest

pytest.importorskip("PySide6")

from astral_client.voice import (  # noqa: E402
    QtLocalSpeechAdapter,
    VoiceController,
    VoiceHttpError,
)
from astral_client.protocol import parse_client_local_capability  # noqa: E402


UTC = timezone.utc
NOW = datetime(2035, 1, 2, 3, 4, 5, tzinfo=UTC)
DEVICE = "00000000-0000-4000-8000-000000000001"
CONNECTION = "00000000-0000-4000-8000-000000000002"
CHAT = "00000000-0000-4000-8000-000000000003"
SESSION = "00000000-0000-4000-8000-000000000004"
SESSION_TWO = "00000000-0000-4000-8000-000000000014"
BINDING_ID = "00000000-0000-4000-8000-000000000008"
BINDING = "v1." + "a" * 64 + "." + "b" * 43
LOCAL_BINDING_TIMEOUT_MS = 120_000
LOCAL_FINAL_RETRY_MS = 2_500


def _uuid(value: int) -> str:
    return f"00000000-0000-4000-8000-{value:012x}"


def _iso(value: datetime) -> str:
    return value.astimezone(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class Clock:
    def __init__(self, now: datetime = NOW) -> None:
        self.now = now

    def __call__(self) -> datetime:
        return self.now

    def advance(self, *, seconds: float) -> None:
        self.now += timedelta(seconds=seconds)


class ManualScheduler:
    def __init__(self) -> None:
        self.calls: list[tuple[int, Callable[[], None]]] = []

    def __call__(self, delay_ms: int, callback: Callable[[], None]) -> None:
        self.calls.append((delay_ms, callback))

    def run_first(self, delay_ms: int) -> None:
        index = next(
            index for index, (delay, _callback) in enumerate(self.calls) if delay == delay_ms
        )
        _delay, callback = self.calls.pop(index)
        callback()

    def run_all(self, *, limit: int = 32) -> None:
        count = 0
        while self.calls:
            count += 1
            assert count <= limit, "scheduled local-speech callbacks did not quiesce"
            _delay, callback = self.calls.pop(0)
            callback()


class ManualRunner:
    def __init__(self) -> None:
        self.defer = False
        self.pending: list[Callable[[], None]] = []

    def __call__(self, work: Callable[[], None]) -> None:
        if self.defer:
            self.pending.append(work)
        else:
            work()

    def run_all(self) -> None:
        while self.pending:
            self.pending.pop(0)()


class FakeTransport:
    def __init__(self, order: list[str]) -> None:
        self.connection_generation = CONNECTION
        self.order = order
        self.local_frames: list[dict[str, Any]] = []
        self.attempts: list[dict[str, Any]] = []
        self.raise_types: set[str] = set()
        self.false_types: set[str] = set()
        self.reconnect_calls = 0

    def send_voice_local_frame(self, frame: dict[str, Any]) -> bool:
        retained = deepcopy(frame)
        self.attempts.append(retained)
        self.order.append(f"transport:{frame['type']}")
        if frame["type"] in self.raise_types:
            raise RuntimeError("local transport unavailable")
        self.local_frames.append(retained)
        return frame["type"] not in self.false_types

    def request_reconnect(self) -> None:
        self.order.append("transport:request_reconnect")
        self.reconnect_calls += 1


class FakeAudio:
    def __init__(self, order: list[str], *, defer_permission: bool = False) -> None:
        self.order = order
        self.defer_permission = defer_permission
        self.permission_requests = 0
        self.permission_callback: Callable[[str], None] | None = None
        self.stop_all_calls = 0
        self.stop_capture_calls = 0
        self.start_capture_calls = 0
        self.capture_callback: Callable[[bytes], None] | None = None

    def capability(self) -> dict[str, Any]:
        return {
            "has_microphone": True,
            "has_audio_output": True,
            "microphone_permission": "authorized",
            "full_duplex": True,
            "transport": "livekit",
        }

    def request_microphone_permission(self, callback: Callable[[str], None]) -> None:
        self.permission_requests += 1
        self.permission_callback = callback
        if not self.defer_permission:
            callback("authorized")

    def start_capture(
        self, callback: Callable[[bytes], None], *, sample_rate: int = 48_000
    ) -> None:
        assert sample_rate in {16_000, 48_000}
        self.start_capture_calls += 1
        self.capture_callback = callback

    def stop_capture(self) -> None:
        self.order.append("audio:stop_capture")
        self.stop_capture_calls += 1
        self.capture_callback = None

    def stop_all(self) -> None:
        self.order.append("audio:stop_all")
        self.stop_all_calls += 1
        self.capture_callback = None


class FakeMedia:
    def __init__(self, order: list[str]) -> None:
        self.order = order
        self.close_calls = 0
        self.stop_playback_calls = 0
        self.microphone_values: list[bool] = []

    def close(self) -> None:
        self.order.append("media:close")
        self.close_calls += 1

    def stop_playback(self) -> None:
        self.order.append("media:stop_playback")
        self.stop_playback_calls += 1

    def set_microphone_enabled(self, value: bool) -> None:
        self.order.append(f"media:microphone:{value}")
        self.microphone_values.append(value)


class FakeLocalSpeech:
    def __init__(self, order: list[str]) -> None:
        self.order = order
        self.cycles: list[dict[str, Callable[..., None]]] = []
        self.playouts: list[dict[str, Any]] = []
        self.stop_recognition_calls = 0
        self.stop_all_calls = 0
        self.close_calls = 0
        self.start_ok = True
        self.speak_ok = True

    def capability(self) -> dict[str, Any]:
        return {"eligible": True, "reason": "ready"}

    def start_recognition(
        self,
        on_final: Callable[[str], None],
        on_error: Callable[[str], None],
    ) -> bool:
        self.order.append("speech:start_recognition")
        self.cycles.append({"final": on_final, "error": on_error})
        return self.start_ok

    def stop_recognition(self) -> None:
        self.order.append("speech:stop_recognition")
        self.stop_recognition_calls += 1

    def stop_all(self) -> None:
        self.order.append("speech:stop_all")
        self.stop_all_calls += 1

    def close(self) -> None:
        self.order.append("speech:close")
        self.close_calls += 1

    def speak(
        self,
        text: str,
        locale: str,
        on_phase: Callable[[str], None],
        on_resume_ready: Callable[[], None],
    ) -> bool:
        self.order.append("speech:speak")
        self.playouts.append(
            {
                "text": text,
                "locale": locale,
                "phase": on_phase,
                "resume": on_resume_ready,
            }
        )
        return self.speak_ok

    @property
    def stop_calls(self) -> int:
        return self.stop_recognition_calls + self.stop_all_calls


class FakeHttp:
    def __init__(self, order: list[str]) -> None:
        self.order = order
        self.calls: list[tuple[Any, ...]] = []
        self.fail_methods: set[str] = set()
        self.session_id = SESSION

    def capability_v2(self) -> dict[str, Any]:
        self.calls.append(("capability_v2",))
        return {
            "schema_version": "2",
            "speech_backend": "client_local",
            "status": "requires_client_readiness",
            "reason": "client_readiness_required",
            "checked_at": "2035-01-02T03:04:00Z",
            "expires_at": "2099-01-02T03:04:00Z",
            "supported_transports": ["client_local"],
            "requirements": {
                "session_contract": "voice-rest/v2-client-local",
                "local_frame_contract": "client_local/v1",
                "configured_locale": "en-US",
                "recognition_must_be_local": True,
                "synthesis_must_be_local": True,
                "installation_policy": "explicit_user_action_only",
                "requirement_revision": 1,
                "max_final_unicode_scalars": 8000,
                "max_announcement_utf8_bytes": 600,
                "announcement_ttl_seconds": 10,
                "echo_suppression_milliseconds": 500,
            },
        }

    def create_local(self, body: dict[str, Any], scope: dict[str, str]) -> dict[str, Any]:
        self.calls.append(("create_local", deepcopy(body), deepcopy(scope)))
        return {
            "schema_version": "2",
            "session_id": self.session_id,
            "speech_backend": "client_local",
            "transport": "client_local",
            "generation": 1,
            "speech_revision": 1,
            "state": "starting",
            "visible_chat_id": CHAT,
            "chat_context_revision": 1,
            "applied_chat_context_revision": None,
            "chat_context_synced": False,
            "foreground_active": True,
            "microphone_enabled": True,
            "speech_muted": False,
            "configured_locale": "en-US",
            "idle_expires_at": "2099-01-02T03:14:00Z",
        }

    def update(
        self, session_id: str, body: dict[str, Any], scope: dict[str, str]
    ) -> dict[str, Any]:
        self.order.append("http:update")
        self.calls.append(("update", session_id, deepcopy(body), deepcopy(scope)))
        self._maybe_fail("update")
        return {
            "session_id": session_id,
            "speech_revision": body["expected_media_grant_revision"],
            "microphone_enabled": body.get("microphone_enabled", True),
            "speech_muted": body.get("speech_muted", False),
        }

    def stop_speech(
        self, session_id: str, body: dict[str, Any], scope: dict[str, str]
    ) -> None:
        self.order.append("http:stop_speech")
        self.calls.append(("stop_speech", session_id, deepcopy(body), deepcopy(scope)))
        self._maybe_fail("stop_speech")

    def end(
        self,
        session_id: str,
        generation: int,
        revision: int,
        scope: dict[str, str],
    ) -> None:
        self.order.append("http:end")
        self.calls.append(("end", session_id, generation, revision, deepcopy(scope)))
        self._maybe_fail("end")

    def _maybe_fail(self, method: str) -> None:
        if method in self.fail_methods:
            raise VoiceHttpError("network_interrupted")


@dataclass
class Harness:
    controller: VoiceController
    clock: Clock
    scheduler: ManualScheduler
    runner: ManualRunner
    order: list[str]
    transport: FakeTransport
    audio: FakeAudio
    media: FakeMedia
    speech: FakeLocalSpeech
    http: FakeHttp


def _harness(*, defer_permission: bool = False) -> Harness:
    clock = Clock()
    scheduler = ManualScheduler()
    runner = ManualRunner()
    order: list[str] = []
    transport = FakeTransport(order)
    audio = FakeAudio(order, defer_permission=defer_permission)
    media = FakeMedia(order)
    speech = FakeLocalSpeech(order)
    http = FakeHttp(order)
    controller = VoiceController(
        device_id=DEVICE,
        token_provider=lambda: "token",
        http_base="http://127.0.0.1:8001",
        connection_provider=lambda: transport.connection_generation,
        chat_provider=lambda: CHAT,
        transport=transport,
        audio=audio,
        http=http,
        media=media,
        local_speech=speech,
        local_schedule=scheduler,
        local_now=clock,
        run_async=runner,
    )
    assert controller.accept_frame(
        {
            "type": "voice_control_binding",
            "schema_version": "1",
            "device_id": DEVICE,
            "connection_generation": CONNECTION,
            "binding_id": BINDING_ID,
            "binding": BINDING,
            "expires_at": _iso(clock.now + timedelta(minutes=10)),
        }
    )
    return Harness(
        controller,
        clock,
        scheduler,
        runner,
        order,
        transport,
        audio,
        media,
        speech,
        http,
    )


def _common(controller: VoiceController, frame_type: str) -> dict[str, Any]:
    return {
        "type": frame_type,
        "schema_version": "2",
        "speech_backend": "client_local",
        "device_id": DEVICE,
        "connection_generation": CONNECTION,
        "session_id": controller.session_id,
        "generation": controller.generation,
        "speech_revision": controller.media_grant_revision,
    }


def _ready_frame(harness: Harness) -> dict[str, Any]:
    return {
        **_common(harness.controller, "voice_local_session_ready"),
        "contract": "client_local/v1",
        "transport": "client_local",
        "configured_locale": "en-US",
        "chat_id": CHAT,
        "chat_context_revision": 1,
        "applied_chat_context_revision": 1,
        "foreground_active": True,
        "microphone_enabled": True,
        "speech_muted": False,
        "lease_expires_at": _iso(harness.clock.now + timedelta(minutes=10)),
    }


def _activate(harness: Harness) -> None:
    previous_creates = sum(call[0] == "create_local" for call in harness.http.calls)
    harness.controller.handle_action("voice_session_start")
    assert sum(call[0] == "create_local" for call in harness.http.calls) == previous_creates + 1
    assert harness.transport.local_frames[-1]["type"] == "voice_local_ready"


def _start_session(harness: Harness) -> dict[str, Any]:
    _activate(harness)
    assert harness.controller.accept_frame(_ready_frame(harness))
    started = harness.transport.local_frames[-1]
    assert started["type"] == "voice_local_recognition_started"
    return started


def _bound_frame(
    harness: Harness,
    started: dict[str, Any],
    *,
    expiry_seconds: float = 121,
    ordinal: int | None = None,
) -> dict[str, Any]:
    value = ordinal if ordinal is not None else started["recognition_sequence"]
    return {
        **_common(harness.controller, "voice_local_turn_bound"),
        "client_turn_id": started["client_turn_id"],
        "turn_id": _uuid(100 + value),
        "submission_id": _uuid(200 + value),
        "request_generation": _uuid(300 + value),
        "chat_id": started["chat_id"],
        "chat_context_revision": started["chat_context_revision"],
        "recognition_sequence": started["recognition_sequence"],
        "binding_expires_at": _iso(
            harness.clock.now + timedelta(seconds=expiry_seconds)
        ),
    }


def _announcement_frame(
    harness: Harness,
    *,
    sequence: int = 1,
    turn_id: str | None = None,
    mute_revision: int = 1,
    consent_revision: int = 1,
) -> dict[str, Any]:
    text = f"Announcement {sequence}"
    return {
        **_common(harness.controller, "voice_local_announcement"),
        "announcement_id": _uuid(400 + sequence),
        "announcement_sequence": sequence,
        "turn_id": turn_id or _uuid(100 + sequence),
        "kind": "result",
        "output_policy": "lifecycle",
        "locale": "en-US",
        "text": text,
        "text_digest_sha256": hashlib.sha256(text.encode()).hexdigest(),
        "expires_at": _iso(harness.clock.now + timedelta(seconds=10)),
        "foreground_required": True,
        "mute_revision": mute_revision,
        "consent_revision": consent_revision,
    }


def _final_rejected_frame(
    harness: Harness, bound: dict[str, Any]
) -> dict[str, Any]:
    return {
        **_common(harness.controller, "voice_local_final_rejected"),
        **{
            name: bound[name]
            for name in (
                "client_turn_id",
                "turn_id",
                "submission_id",
                "request_generation",
                "chat_id",
                "chat_context_revision",
                "recognition_sequence",
            )
        },
        "reason": "stale_local_turn",
        "retry_policy": "none",
        "occurred_at": _iso(harness.clock.now),
    }


def _frames(harness: Harness, frame_type: str) -> list[dict[str, Any]]:
    return [
        frame for frame in harness.transport.local_frames if frame["type"] == frame_type
    ]


def test_recognition_start_exception_fails_closed_and_retains_prebind_failure() -> None:
    harness = _harness()
    _activate(harness)

    def fail_recognition(*_args: Any, **_kwargs: Any) -> bool:
        raise RuntimeError("asr lost")

    harness.speech.start_recognition = fail_recognition  # type: ignore[method-assign]

    assert harness.controller.accept_frame(_ready_frame(harness))

    assert harness.controller._local_turn is None
    assert not harness.controller._local_ready_authorized
    assert harness.controller._local_speech_stopped
    assert harness.speech.stop_all_calls == 1
    assert len(harness.controller._local_pending_failures) == 1
    assert harness.controller._local_pending_failures[0]["reason"] == "local_engine_lost"


def test_activation_capability_exception_fails_closed_without_http_create() -> None:
    harness = _harness()
    harness.speech.capability = lambda: (_ for _ in ()).throw(  # type: ignore[method-assign]
        RuntimeError("engine disappeared")
    )

    harness.controller.handle_action("voice_session_start")

    assert harness.controller._activation_id is None
    assert harness.controller.state == "unavailable"
    assert not any(call[0] == "create_local" for call in harness.http.calls)


@pytest.mark.parametrize("failure_mode", ["raise", "false"])
def test_ready_transport_failure_is_not_left_pending(failure_mode: str) -> None:
    harness = _harness()
    if failure_mode == "raise":
        harness.transport.raise_types.add("voice_local_ready")
    else:
        harness.transport.false_types.add("voice_local_ready")

    harness.controller.handle_action("voice_session_start")

    assert not harness.controller._local_ready_pending
    assert not harness.controller._local_ready_authorized
    assert harness.controller.state == "unavailable"
    assert len(harness.transport.attempts) == 1

    assert not harness.controller._send_local_ready()
    assert len(harness.transport.attempts) == 2


@pytest.mark.parametrize("failure_mode", ["raise", "false"])
def test_recognition_started_transport_failure_never_starts_capture(
    failure_mode: str,
) -> None:
    harness = _harness()
    _activate(harness)
    if failure_mode == "raise":
        harness.transport.raise_types.add("voice_local_recognition_started")
    else:
        harness.transport.false_types.add("voice_local_recognition_started")

    assert harness.controller.accept_frame(_ready_frame(harness))

    assert harness.controller._local_turn is None
    assert not harness.controller._local_ready_authorized
    assert harness.controller._local_speech_stopped
    assert harness.speech.cycles == []
    assert harness.controller.state == "unavailable"


def test_session_ready_starts_foreground_lease_and_close_stops_it(qapp: Any) -> None:
    harness = _harness()
    assert not harness.controller._lease_timer.isActive()

    _start_session(harness)

    assert harness.controller._lease_timer.interval() == 20_000
    assert harness.controller._lease_timer.isActive()

    harness.controller.close()

    assert not harness.controller._lease_timer.isActive()


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("recognition_must_be_local", 1),
        ("requirement_revision", 1.0),
        ("announcement_ttl_seconds", 10.0),
    ],
)
def test_capability_requirements_reject_json_type_confusion(
    field: str, value: object
) -> None:
    capability = FakeHttp([]).capability_v2()
    capability["requirements"][field] = value

    assert parse_client_local_capability(capability) is None


def test_capability_requirements_reject_missing_and_extra_keys() -> None:
    capability = FakeHttp([]).capability_v2()
    missing = deepcopy(capability)
    missing["requirements"].pop("configured_locale")
    extra = deepcopy(capability)
    extra["requirements"]["engine"] = "forbidden"

    assert parse_client_local_capability(missing) is None
    assert parse_client_local_capability(extra) is None


def test_expired_capability_is_refused_before_local_session_creation() -> None:
    harness = _harness()
    capability = harness.http.capability_v2()
    capability["checked_at"] = _iso(harness.clock.now - timedelta(seconds=1))
    capability["expires_at"] = _iso(harness.clock.now)
    harness.http.capability_v2 = lambda: deepcopy(capability)

    harness.controller.handle_action("voice_session_start")

    assert not any(call[0] == "create_local" for call in harness.http.calls)
    assert harness.controller.state == "unavailable"


def test_control_binding_lifetime_is_bounded_and_expiry_fails_closed() -> None:
    harness = _harness()
    overlong = {
        "type": "voice_control_binding",
        "schema_version": "1",
        "device_id": DEVICE,
        "connection_generation": CONNECTION,
        "binding_id": _uuid(900),
        "binding": BINDING,
        "expires_at": _iso(harness.clock.now + timedelta(minutes=10, milliseconds=1)),
    }
    assert not harness.controller.accept_frame(overlong)
    original_binding_id = harness.controller.control_binding_id

    _start_session(harness)
    harness.clock.advance(seconds=600)
    assert not harness.controller._local_authority_matches(
        _common(harness.controller, "voice_local_ready")
    )
    harness.scheduler.run_first(600_001)

    assert original_binding_id == BINDING_ID
    assert harness.controller.control_binding is None
    assert harness.controller.session_id is None
    assert harness.controller.state == "unavailable"
    assert harness.transport.reconnect_calls == 1


def test_session_ready_requires_and_consumes_one_fresh_ready_handshake() -> None:
    harness = _harness()
    _activate(harness)
    ready = _ready_frame(harness)

    harness.controller._local_ready_pending = False
    assert not harness.controller.accept_frame(ready)
    assert harness.speech.cycles == []

    assert harness.controller._send_local_ready()
    assert harness.controller.accept_frame(ready)
    assert len(harness.speech.cycles) == 1

    assert not harness.controller.accept_frame(ready)
    assert len(harness.speech.cycles) == 1


@pytest.mark.parametrize(
    ("action", "failing_method"),
    [
        ("microphone_off", "update"),
        ("mute", "update"),
        ("background", "update"),
        ("stop", "stop_speech"),
    ],
)
def test_local_controls_stop_before_blocked_network_and_do_not_restart_on_failure(
    action: str, failing_method: str
) -> None:
    harness = _harness()
    started = _start_session(harness)
    assert harness.controller.accept_frame(_bound_frame(harness, started))
    stale_final = harness.speech.cycles[0]["final"]
    harness.http.fail_methods.add(failing_method)
    harness.runner.defer = True
    harness.order.clear()

    if action == "microphone_off":
        harness.controller.handle_action("voice_microphone_set")
    elif action == "mute":
        harness.controller.handle_action("voice_speech_mute_set")
    elif action == "background":
        harness.controller.set_foreground_active(False, "backgrounded")
    else:
        harness.controller.handle_action("voice_speech_stop")

    assert harness.speech.stop_calls >= 1
    assert harness.order[0].startswith("speech:stop")
    assert harness.runner.pending, "the server request should remain independently pending"
    assert not any(entry.startswith("http:") for entry in harness.order)

    stale_final("must not be submitted")
    harness.runner.run_all()
    harness.scheduler.run_all()

    assert len(harness.speech.cycles) == 1
    assert not _frames(harness, "voice_local_final")


def test_failed_failure_frame_transport_cannot_prevent_local_stop() -> None:
    harness = _harness()
    started = _start_session(harness)
    assert harness.controller.accept_frame(_bound_frame(harness, started))
    harness.transport.raise_types.add("voice_local_recognition_failed")
    harness.runner.defer = True
    harness.order.clear()

    harness.controller.handle_action("voice_speech_stop")

    stop_index = next(
        index for index, event in enumerate(harness.order) if event.startswith("speech:stop")
    )
    send_index = harness.order.index("transport:voice_local_recognition_failed")
    assert stop_index < send_index
    assert len(harness.runner.pending) == 1


def test_bound_recognizer_error_stops_even_when_failure_report_cannot_send() -> None:
    harness = _harness()
    started = _start_session(harness)
    assert harness.controller.accept_frame(_bound_frame(harness, started))
    harness.transport.raise_types.add("voice_local_recognition_failed")

    harness.speech.cycles[0]["error"]("local_engine_lost")

    assert harness.controller._local_turn is None
    assert not harness.controller._local_ready_authorized
    assert harness.controller._local_speech_stopped
    assert harness.speech.stop_all_calls == 1
    assert harness.controller.state == "unavailable"


def test_announcement_transition_survives_failed_recognition_report() -> None:
    harness = _harness()
    started = _start_session(harness)
    assert harness.controller.accept_frame(_bound_frame(harness, started))
    harness.transport.raise_types.add("voice_local_recognition_failed")

    assert harness.controller.accept_frame(_announcement_frame(harness))

    assert harness.controller._local_turn is None
    assert harness.controller._local_active_playout is not None
    assert len(harness.speech.playouts) == 1


def test_successful_stop_requires_a_new_ready_ack_before_recognition_restarts() -> None:
    harness = _harness()
    _start_session(harness)
    harness.runner.defer = True

    harness.controller.handle_action("voice_speech_stop")
    assert len(harness.speech.cycles) == 1
    assert len(_frames(harness, "voice_local_ready")) == 1

    harness.runner.run_all()
    assert len(_frames(harness, "voice_local_ready")) == 2
    assert len(harness.speech.cycles) == 1

    ready = _ready_frame(harness)
    assert harness.controller.accept_frame(ready)
    assert len(harness.speech.cycles) == 2
    assert not harness.controller.accept_frame(ready)


def test_prebind_cancel_retains_exact_failure_while_a_new_cycle_recovers() -> None:
    harness = _harness()
    first_started = _start_session(harness)
    secret = "patient text that must be scrubbed"
    harness.speech.cycles[0]["final"](secret)

    harness.controller._cancel_local_recognition("stopped_by_user")

    assert len(harness.controller._local_pending_failures) == 1
    assert secret not in repr(harness.controller._local_pending_failures)
    assert secret not in repr(harness.controller._local_turn)
    harness.controller._start_local_recognition()
    second_started = _frames(harness, "voice_local_recognition_started")[-1]
    assert second_started["client_turn_id"] != first_started["client_turn_id"]
    assert second_started["recognition_sequence"] == 2

    first_bound = _bound_frame(harness, first_started, ordinal=1)
    assert harness.controller.accept_frame(first_bound)
    failures = _frames(harness, "voice_local_recognition_failed")
    assert len(failures) == 1
    assert failures[0]["client_turn_id"] == first_started["client_turn_id"]
    assert failures[0]["reason"] == "stopped_by_user"
    assert harness.controller._local_turn["client_turn_id"] == second_started["client_turn_id"]

    assert harness.controller.accept_frame(
        _bound_frame(harness, second_started, ordinal=2)
    )
    harness.speech.cycles[1]["final"]("recovered request")
    finals = _frames(harness, "voice_local_final")
    assert len(finals) == 1
    assert finals[0]["client_turn_id"] == second_started["client_turn_id"]


def test_prebind_failure_ledger_is_bounded_and_evicts_the_oldest() -> None:
    harness = _harness()
    started = _start_session(harness)
    client_turn_ids: list[str] = []

    for _index in range(5):
        client_turn_ids.append(started["client_turn_id"])
        harness.controller._cancel_local_recognition("local_audio_interrupted")
        harness.controller._start_local_recognition()
        started = _frames(harness, "voice_local_recognition_started")[-1]

    retained = harness.controller._local_pending_failures
    assert len(retained) == 4
    assert client_turn_ids[0] not in {entry["client_turn_id"] for entry in retained}
    assert {entry["client_turn_id"] for entry in retained} == set(client_turn_ids[1:])


def test_turn_binding_requires_exact_frozen_authority_and_bounded_expiry() -> None:
    harness = _harness()
    started = _start_session(harness)
    base = _bound_frame(harness, started)
    invalid_patches = [
        {"session_id": SESSION_TWO},
        {"connection_generation": _uuid(20)},
        {"chat_id": _uuid(21)},
        {"chat_context_revision": 2},
        {"binding_expires_at": _iso(harness.clock.now)},
        {
            "binding_expires_at": _iso(
                harness.clock.now + timedelta(seconds=121, milliseconds=1)
            )
        },
    ]

    for patch in invalid_patches:
        assert not harness.controller.accept_frame({**base, **patch}), patch
        assert "turn_id" not in harness.controller._local_turn

    assert harness.controller.accept_frame(base)
    assert harness.controller._local_turn["binding_expires_at"] == base[
        "binding_expires_at"
    ]


def test_binding_timeout_scrubs_final_and_recovers_with_a_new_cycle() -> None:
    harness = _harness()
    first_started = _start_session(harness)
    stale_final = harness.speech.cycles[0]["final"]
    stale_final("sensitive timeout text")

    harness.scheduler.run_first(LOCAL_BINDING_TIMEOUT_MS)

    starts = _frames(harness, "voice_local_recognition_started")
    assert len(starts) == 2
    assert starts[-1]["client_turn_id"] != first_started["client_turn_id"]
    assert starts[-1]["recognition_sequence"] == 2
    assert "sensitive timeout text" not in repr(harness.controller._local_turn)
    assert "sensitive timeout text" not in repr(
        harness.controller._local_pending_failures
    )
    assert not _frames(harness, "voice_local_final")

    stale_final("late stale text")
    assert not _frames(harness, "voice_local_final")


def test_local_final_retries_exact_frame_until_exact_message_ack() -> None:
    harness = _harness()
    started = _start_session(harness)
    bound = _bound_frame(harness, started)
    assert harness.controller.accept_frame(bound)
    secret = "exact acknowledgement text"

    harness.speech.cycles[0]["final"](secret)
    pending = harness.controller._local_pending_final
    assert pending is not None
    first = _frames(harness, "voice_local_final")[-1]

    stale_ack = {
        "type": "user_message_acked",
        "schema_version": "1",
        "chat_id": bound["chat_id"],
        "message_id": 1,
        "submission_id": _uuid(999),
        "request_generation": bound["request_generation"],
        "connection_generation": CONNECTION,
        "voice_turn_id": bound["turn_id"],
    }
    assert not harness.controller.accept_frame(stale_ack)
    assert harness.controller._local_pending_final is pending

    harness.scheduler.run_first(LOCAL_FINAL_RETRY_MS)
    finals = _frames(harness, "voice_local_final")
    assert len(finals) == 2
    assert finals[1] == first

    exact_ack = {
        **stale_ack,
        "submission_id": bound["submission_id"],
    }
    assert harness.controller.accept_frame(exact_ack)
    assert harness.controller._local_pending_final is None
    assert len(harness.speech.cycles) == 2
    assert secret not in repr(pending)

    # The already-scheduled retry owns only the scrubbed object and is inert.
    harness.scheduler.run_first(LOCAL_FINAL_RETRY_MS)
    assert len(_frames(harness, "voice_local_final")) == 2


def test_local_final_ack_timeout_scrubs_plaintext_and_ends_session_fail_closed() -> None:
    harness = _harness()
    started = _start_session(harness)
    bound = _bound_frame(harness, started)
    assert harness.controller.accept_frame(bound)
    secret = "timeout plaintext must be scrubbed"

    harness.speech.cycles[0]["final"](secret)
    pending = harness.controller._local_pending_final
    assert pending is not None
    assert secret in repr(pending)

    harness.clock.advance(seconds=120)
    harness.scheduler.run_first(LOCAL_FINAL_RETRY_MS)

    assert harness.controller._local_pending_final is None
    assert harness.controller.session_id is None
    assert harness.controller.speech_backend == "llm_factory"
    assert harness.controller.state == "unavailable"
    assert secret not in repr(pending)
    assert secret not in repr(harness.controller._local_turn)
    assert [call[0] for call in harness.http.calls].count("end") == 1


class AdapterHelper:
    def __init__(self) -> None:
        self.on_final: Callable[[str], None] | None = None
        self.on_error: Callable[[str], None] | None = None
        self.stop_calls = 0
        self.close_calls = 0

    def capability(self) -> bool:
        return True

    def start_recognition(
        self, on_final: Callable[[str], None], on_error: Callable[[str], None]
    ) -> None:
        self.on_final = on_final
        self.on_error = on_error

    def feed_pcm(self, _pcm: bytes) -> None:
        pass

    def stop_recognition(self) -> None:
        self.stop_calls += 1

    def close(self) -> None:
        self.close_calls += 1


class AdapterTts:
    def __init__(self) -> None:
        self.callback: Callable[[str], None] | None = None
        self.stop_calls = 0

    def capability(self, locale: str) -> bool:
        return locale == "en-US"

    def speak(
        self, _text: str, _locale: str, callback: Callable[[str], None]
    ) -> None:
        self.callback = callback

    def stop(self) -> None:
        self.stop_calls += 1


def test_adapter_first_final_beats_later_same_cycle_error_and_stops_capture() -> None:
    order: list[str] = []
    audio = FakeAudio(order)
    helper = AdapterHelper()
    tts = AdapterTts()
    adapter = QtLocalSpeechAdapter(audio=audio, helper=helper, tts=tts)
    finals: list[str] = []
    errors: list[str] = []

    assert adapter.start_recognition(finals.append, errors.append)
    assert helper.on_final is not None and helper.on_error is not None
    same_cycle_final = helper.on_final
    same_cycle_error = helper.on_error

    same_cycle_final("first final")
    same_cycle_error("late helper error")
    same_cycle_final("second final")

    assert finals == ["first final"]
    assert errors == []
    assert audio.stop_capture_calls == 1
    assert helper.stop_calls == 1


def test_stale_final_rejected_cannot_cancel_a_newer_recognition() -> None:
    harness = _harness()
    first_started = _start_session(harness)
    first_bound = _bound_frame(harness, first_started)
    assert harness.controller.accept_frame(first_bound)
    harness.speech.cycles[0]["final"]("first request")
    assert harness.controller.accept_frame(
        {
            "type": "user_message_acked",
            "schema_version": "1",
            "chat_id": first_bound["chat_id"],
            "message_id": 1,
            "submission_id": first_bound["submission_id"],
            "request_generation": first_bound["request_generation"],
            "connection_generation": CONNECTION,
            "voice_turn_id": first_bound["turn_id"],
        }
    )

    announcement = _announcement_frame(
        harness, turn_id=first_bound["turn_id"]
    )
    assert harness.controller.accept_frame(announcement)
    playout = harness.speech.playouts[-1]
    playout["phase"]("started")
    playout["phase"]("finished")
    playout["resume"]()
    second_started = _frames(harness, "voice_local_recognition_started")[-1]
    assert second_started["recognition_sequence"] == 3
    stops_before = harness.speech.stop_calls

    assert not harness.controller.accept_frame(
        _final_rejected_frame(harness, first_bound)
    )
    assert harness.controller._local_turn["client_turn_id"] == second_started[
        "client_turn_id"
    ]
    assert harness.speech.stop_calls == stops_before


def test_announcement_requires_exact_sequence_locale_foreground_and_fresh_expiry() -> None:
    harness = _harness()
    _start_session(harness)
    base = _announcement_frame(harness)
    invalid = [
        {**base, "announcement_sequence": 2},
        {**base, "locale": "fr-FR"},
        {**base, "foreground_required": False},
        {**base, "expires_at": _iso(harness.clock.now)},
        {
            **base,
            "expires_at": _iso(harness.clock.now + timedelta(seconds=12)),
        },
    ]

    for frame in invalid:
        assert not harness.controller.accept_frame(frame)
    assert harness.speech.playouts == []


@pytest.mark.parametrize("text", ["", "e\u0301", "line\nbreak", "nul\x00text"])
def test_announcement_text_must_be_nonempty_nfc_and_control_free(text: str) -> None:
    harness = _harness()
    _start_session(harness)
    frame = _announcement_frame(harness)
    frame["text"] = text
    frame["text_digest_sha256"] = hashlib.sha256(text.encode()).hexdigest()

    assert not harness.controller.accept_frame(frame)
    assert harness.speech.playouts == []


def test_queued_announcement_expiry_is_rechecked_before_playout() -> None:
    harness = _harness()
    _start_session(harness)
    first = _announcement_frame(harness, sequence=1)
    second = _announcement_frame(harness, sequence=2)
    second["expires_at"] = _iso(harness.clock.now + timedelta(seconds=1))

    assert harness.controller.accept_frame(first)
    assert harness.controller.accept_frame(second)
    assert len(harness.speech.playouts) == 1
    harness.speech.playouts[0]["phase"]("started")
    harness.clock.advance(seconds=2)
    harness.speech.playouts[0]["phase"]("finished")

    events = _frames(harness, "voice_local_playout_event")
    assert [(event["announcement_sequence"], event["phase"]) for event in events] == [
        (1, "started"),
        (1, "finished"),
        (2, "failed"),
    ]
    assert events[-1]["reason"] == "local_announcement_expired"
    assert len(harness.speech.playouts) == 1
    assert harness.controller._local_announcement_queue == []
    harness.scheduler.run_first(500)
    assert len(_frames(harness, "voice_local_recognition_started")) == 2


def test_active_announcement_expiry_stops_before_failed_event_and_recovers() -> None:
    harness = _harness()
    _start_session(harness)
    assert harness.controller.accept_frame(_announcement_frame(harness))
    playout = harness.speech.playouts[-1]
    playout["phase"]("started")
    harness.clock.advance(seconds=10)
    harness.order.clear()

    harness.scheduler.run_first(10_000)

    assert harness.order[0] == "speech:stop_all"
    events = _frames(harness, "voice_local_playout_event")
    assert [event["phase"] for event in events] == ["started", "failed"]
    assert events[-1]["reason"] == "local_announcement_expired"
    assert harness.controller._local_active_playout is None
    harness.scheduler.run_first(500)
    assert len(_frames(harness, "voice_local_recognition_started")) == 2


def test_queued_expiry_recovers_when_playout_telemetry_cannot_send() -> None:
    harness = _harness()
    _start_session(harness)
    first = _announcement_frame(harness, sequence=1)
    second = _announcement_frame(harness, sequence=2)
    second["expires_at"] = _iso(harness.clock.now + timedelta(seconds=1))
    assert harness.controller.accept_frame(first)
    assert harness.controller.accept_frame(second)
    first_playout = harness.speech.playouts[0]
    first_playout["phase"]("started")
    harness.clock.advance(seconds=2)
    harness.transport.raise_types.add("voice_local_playout_event")

    first_playout["phase"]("finished")

    assert harness.controller._local_active_playout is None
    assert harness.controller._local_announcement_queue == []
    harness.scheduler.run_first(500)
    assert len(_frames(harness, "voice_local_recognition_started")) == 2


def test_finished_before_started_is_failed_and_recognition_recovers() -> None:
    harness = _harness()
    _start_session(harness)
    assert harness.controller.accept_frame(_announcement_frame(harness))

    harness.speech.playouts[-1]["phase"]("finished")

    events = _frames(harness, "voice_local_playout_event")
    assert len(events) == 1
    assert events[0]["phase"] == "failed"
    assert events[0]["reason"] == "local_synthesis_failed"
    harness.scheduler.run_first(500)
    assert len(_frames(harness, "voice_local_recognition_started")) == 2


def test_speak_exception_fails_closed_and_recognition_recovers() -> None:
    harness = _harness()
    _start_session(harness)

    def fail_synthesis(*_args: Any, **_kwargs: Any) -> bool:
        raise RuntimeError("tts lost")

    harness.speech.speak = fail_synthesis  # type: ignore[method-assign]

    assert not harness.controller.accept_frame(_announcement_frame(harness))

    events = _frames(harness, "voice_local_playout_event")
    assert len(events) == 1
    assert events[0]["phase"] == "failed"
    assert events[0]["reason"] == "local_synthesis_failed"
    assert harness.controller._local_active_playout is None
    assert harness.speech.stop_recognition_calls == 1
    harness.scheduler.run_first(500)
    assert len(_frames(harness, "voice_local_recognition_started")) == 2


def test_announcement_sequence_and_authority_revisions_are_nondecreasing() -> None:
    harness = _harness()
    _start_session(harness)
    first = _announcement_frame(harness, mute_revision=2, consent_revision=3)
    assert harness.controller.accept_frame(first)
    harness.speech.playouts[-1]["phase"]("started")
    harness.speech.playouts[-1]["phase"]("finished")

    skipped = _announcement_frame(
        harness, sequence=3, mute_revision=2, consent_revision=3
    )
    regressed_mute = _announcement_frame(
        harness, sequence=2, mute_revision=1, consent_revision=3
    )
    regressed_consent = _announcement_frame(
        harness, sequence=2, mute_revision=2, consent_revision=2
    )
    assert not harness.controller.accept_frame(skipped)
    assert not harness.controller.accept_frame(regressed_mute)
    assert not harness.controller.accept_frame(regressed_consent)

    second = _announcement_frame(
        harness, sequence=2, mute_revision=2, consent_revision=3
    )
    assert harness.controller.accept_frame(second)
    assert len(harness.speech.playouts) == 2


@pytest.mark.parametrize("surrogate", ["\ud800", "\udfff"])
def test_controller_rejects_lone_surrogate_announcement_without_raising(
    surrogate: str,
) -> None:
    harness = _harness()
    _start_session(harness)
    frame = _announcement_frame(harness)
    frame["text"] = f"bad{surrogate}text"
    frame["text_digest_sha256"] = "0" * 64

    assert not harness.controller.accept_frame(frame)
    assert harness.controller._local_active_playout is None


def test_playout_is_interrupted_once_and_old_callbacks_are_fenced_after_rotation() -> None:
    harness = _harness()
    _start_session(harness)
    assert harness.controller.accept_frame(_announcement_frame(harness))
    old_playout = harness.speech.playouts[-1]
    old_playout["phase"]("started")

    harness.controller._teardown("ended", "rotating session")
    phases = [frame["phase"] for frame in _frames(harness, "voice_local_playout_event")]
    assert phases == ["started", "interrupted"]
    after_teardown = len(harness.transport.local_frames)

    old_playout["phase"]("finished")
    old_playout["phase"]("failed")
    old_playout["resume"]()
    assert len(harness.transport.local_frames) == after_teardown

    harness.http.session_id = SESSION_TWO
    _activate(harness)
    assert harness.controller.accept_frame(_ready_frame(harness))
    current_turn = harness.controller._local_turn["client_turn_id"]
    after_rotation = len(harness.transport.local_frames)

    old_playout["phase"]("finished")
    old_playout["resume"]()
    assert len(harness.transport.local_frames) == after_rotation
    assert harness.controller._local_turn["client_turn_id"] == current_turn


def test_adapter_preserves_canonical_interrupted_terminal_phase() -> None:
    order: list[str] = []
    audio = FakeAudio(order)
    helper = AdapterHelper()
    tts = AdapterTts()
    scheduler = ManualScheduler()
    adapter = QtLocalSpeechAdapter(
        audio=audio, helper=helper, tts=tts, schedule=scheduler
    )
    phases: list[str] = []
    resumes: list[str] = []

    assert adapter.speak("hello", "en-US", phases.append, lambda: resumes.append("ready"))
    assert tts.callback is not None
    tts.callback("started")
    tts.callback("interrupted")
    tts.callback("finished")

    assert phases == ["started", "interrupted"]
    scheduler.run_first(500)
    assert resumes == ["ready"]


def test_end_is_idempotent_while_its_network_callback_is_pending() -> None:
    harness = _harness()
    _start_session(harness)
    harness.runner.defer = True

    harness.controller.handle_action("voice_session_end")
    harness.controller.handle_action("voice_session_end")

    assert len(harness.runner.pending) == 1
    harness.runner.run_all()
    assert sum(call[0] == "end" for call in harness.http.calls) == 1
    assert harness.controller.session_id is None


def test_close_is_idempotent_and_closes_each_owned_runtime_once() -> None:
    harness = _harness()
    _start_session(harness)

    harness.controller.close()
    first_close_counts = (
        harness.media.close_calls,
        harness.audio.stop_all_calls,
        harness.speech.close_calls,
    )
    harness.controller.close()

    assert harness.controller._closed is True
    assert harness.speech.close_calls == 1
    assert first_close_counts == (0, 0, 1)
    assert (
        harness.media.close_calls,
        harness.audio.stop_all_calls,
        harness.speech.close_calls,
    ) == first_close_counts


def test_duplicate_and_post_close_permission_callbacks_cannot_activate() -> None:
    duplicate = _harness(defer_permission=True)
    duplicate.controller.handle_action("voice_session_start")
    callback = duplicate.audio.permission_callback
    assert callback is not None

    callback("authorized")
    callback("authorized")

    assert sum(call[0] == "create_local" for call in duplicate.http.calls) == 1
    assert len(_frames(duplicate, "voice_local_ready")) == 1

    closed = _harness(defer_permission=True)
    closed.controller.handle_action("voice_session_start")
    late_callback = closed.audio.permission_callback
    assert late_callback is not None
    closed.controller.close()

    late_callback("authorized")
    closed.controller.handle_action("voice_session_start")

    assert not any(call[0] == "capability_v2" for call in closed.http.calls)
    assert not any(call[0] == "create_local" for call in closed.http.calls)
    assert closed.transport.local_frames == []
    assert closed.audio.permission_requests == 1
