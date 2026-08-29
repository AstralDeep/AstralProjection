"""Feature 075 Windows client-local speech adapter behavior."""

from __future__ import annotations

import io
import hashlib
import struct
import threading
import urllib.error

import pytest

pytest.importorskip("PySide6")

from astral_client import voice as voice_module  # noqa: E402


_REQUIRED_API = (
    "HELPER_MAX_PCM_BYTES",
    "HELPER_MAX_TEXT_BYTES",
    "QtLocalSpeechAdapter",
    "WindowsSpeechHelper",
    "canonicalize_local_final",
    "encode_helper_frame",
    "read_helper_frame",
)
_MISSING_API = tuple(name for name in _REQUIRED_API if not hasattr(voice_module, name))


HELPER_MAX_PCM_BYTES = getattr(voice_module, "HELPER_MAX_PCM_BYTES", 0)
HELPER_MAX_TEXT_BYTES = getattr(voice_module, "HELPER_MAX_TEXT_BYTES", 0)
QtLocalSpeechAdapter = getattr(voice_module, "QtLocalSpeechAdapter", None)
VoiceController = getattr(voice_module, "VoiceController", None)
VoiceHttpClient = getattr(voice_module, "VoiceHttpClient", None)
WindowsSpeechHelper = getattr(voice_module, "WindowsSpeechHelper", None)
canonicalize_local_final = getattr(voice_module, "canonicalize_local_final", None)
encode_helper_frame = getattr(voice_module, "encode_helper_frame", None)
read_helper_frame = getattr(voice_module, "read_helper_frame", None)


def test_task8_local_speech_api_is_present() -> None:
    assert _MISSING_API == ()


@pytest.fixture(autouse=True)
def _require_task8_api(request) -> None:
    if request.node.name != "test_task8_local_speech_api_is_present" and _MISSING_API:
        pytest.skip("Task 8 API is not implemented")


class FakeStdout:
    def __init__(self, frames: list[bytes]) -> None:
        self._stream = io.BytesIO(b"".join(frames))

    def read(self, size: int = -1) -> bytes:
        return self._stream.read(size)


class FakeStdin:
    def __init__(self) -> None:
        self.bytes = bytearray()

    def write(self, value: bytes) -> int:
        self.bytes.extend(value)
        return len(value)

    def flush(self) -> None:
        pass


class FakeProcess:
    def __init__(self, frames: list[bytes]) -> None:
        self.stdin = FakeStdin()
        self.stdout = FakeStdout(frames)
        self.stderr = None
        self.terminated = 0
        self.killed = 0

    def poll(self):
        return None

    def terminate(self) -> None:
        self.terminated += 1

    def kill(self) -> None:
        self.killed += 1

    def wait(self, timeout=None) -> int:
        return 0


class BlockingReadyStdout(FakeStdout):
    def __init__(self, frames: list[bytes]) -> None:
        super().__init__(frames)
        self.read_started = threading.Event()
        self.release = threading.Event()

    def read(self, size: int = -1) -> bytes:
        self.read_started.set()
        self.release.wait(5)
        return super().read(size)


class BlockingReadyProcess(FakeProcess):
    def __init__(self, frames: list[bytes]) -> None:
        super().__init__(frames)
        self.stdout = BlockingReadyStdout(frames)

    def terminate(self) -> None:
        super().terminate()
        self.stdout.release.set()


class FakeHelper:
    def __init__(self, ready: bool = True) -> None:
        self.ready = ready
        self.pcm: list[bytes] = []
        self.started = 0
        self.stopped = 0
        self.closed = 0
        self.on_final = None
        self.on_error = None

    def capability(self) -> bool:
        return self.ready

    def start_recognition(self, on_final, on_error) -> None:
        self.started += 1
        self.on_final = on_final
        self.on_error = on_error

    def feed_pcm(self, pcm: bytes) -> None:
        self.pcm.append(pcm)

    def stop_recognition(self) -> None:
        self.stopped += 1

    def close(self) -> None:
        self.closed += 1


class FakeAudio:
    def __init__(self) -> None:
        self.capture_callback = None
        self.started = 0
        self.stopped = 0

    def start_capture(self, callback) -> None:
        self.started += 1
        self.capture_callback = callback

    def stop_capture(self) -> None:
        self.stopped += 1
        self.capture_callback = None

    def capability(self):
        return {
            "has_microphone": True,
            "has_audio_output": True,
            "microphone_permission": "authorized",
            "full_duplex": True,
            "transport": "livekit",
        }

    def request_microphone_permission(self, callback) -> None:
        callback("authorized")

    def stop_all(self) -> None:
        self.stop_capture()


class FakeTts:
    def __init__(self, ready: bool = True) -> None:
        self.ready = ready
        self.calls: list[tuple] = []
        self.callback = None

    def capability(self, locale: str) -> bool:
        self.calls.append(("capability", locale))
        return self.ready

    def speak(self, text: str, locale: str, callback) -> None:
        self.calls.append(("speak", text, locale))
        self.callback = callback
        callback("started")

    def stop(self) -> None:
        self.calls.append(("stop",))


class FakeScheduler:
    def __init__(self) -> None:
        self.calls: list[tuple[int, object]] = []

    def __call__(self, delay_ms: int, callback) -> None:
        self.calls.append((delay_ms, callback))


DEVICE = "00000000-0000-4000-8000-000000000001"
CONNECTION = "00000000-0000-4000-8000-000000000002"
CHAT = "00000000-0000-4000-8000-000000000003"
SESSION = "00000000-0000-4000-8000-000000000004"
TURN = "00000000-0000-4000-8000-000000000005"
SUBMISSION = "00000000-0000-4000-8000-000000000006"
REQUEST = "00000000-0000-4000-8000-000000000007"
BINDING = "v1." + "a" * 64 + "." + "b" * 43


class FakeLocalTransport:
    def __init__(self) -> None:
        self.connection_generation = CONNECTION
        self.local_frames = []

    def send_voice_local_frame(self, frame) -> None:
        self.local_frames.append(frame)


class FakeLocalHttp:
    def __init__(self) -> None:
        self.calls = []

    def capability_v2(self):
        self.calls.append(("capability_v2",))
        return {
            "schema_version": "2",
            "speech_backend": "client_local",
            "status": "requires_client_readiness",
            "reason": "client_readiness_required",
            "checked_at": "2026-08-28T12:00:00Z",
            "expires_at": "2099-08-28T12:00:10Z",
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

    def create_local(self, body, scope):
        self.calls.append(("create_local", body, scope))
        return {
            "schema_version": "2",
            "session_id": SESSION,
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
            "idle_expires_at": "2099-08-28T12:10:00Z",
        }


class FakeLocalSpeech:
    def __init__(self, eligible=True) -> None:
        self.eligible = eligible
        self.started = 0
        self.spoken = []
        self.stopped = 0
        self.on_final = None
        self.on_error = None

    def capability(self):
        return {
            "eligible": self.eligible,
            "reason": "ready" if self.eligible else "local_recognition_unavailable",
        }

    def start_recognition(self, on_final, on_error):
        self.started += 1
        self.on_final = on_final
        self.on_error = on_error
        return True

    def speak(self, text, locale, on_phase):
        self.spoken.append((text, locale))
        on_phase("started")
        on_phase("finished")
        return True

    def stop_all(self):
        self.stopped += 1

    def close(self):
        self.stopped += 1


class FakeNoRemoteMedia:
    def __getattr__(self, name):
        raise AssertionError(f"client_local used remote media: {name}")


def _local_controller(*, eligible=True):
    transport = FakeLocalTransport()
    http = FakeLocalHttp()
    speech = FakeLocalSpeech(eligible)
    controller = VoiceController(
        device_id=DEVICE,
        token_provider=lambda: "token",
        http_base="http://127.0.0.1:8001",
        connection_provider=lambda: transport.connection_generation,
        chat_provider=lambda: CHAT,
        transport=transport,
        audio=FakeAudio(),
        local_speech=speech,
        http=http,
        media=FakeNoRemoteMedia(),
        run_async=lambda work: work(),
    )
    assert controller.accept_frame(
        {
            "type": "voice_control_binding",
            "schema_version": "1",
            "device_id": DEVICE,
            "connection_generation": CONNECTION,
            "binding_id": "00000000-0000-4000-8000-000000000008",
            "binding": BINDING,
            "expires_at": "2099-08-28T12:00:00Z",
        }
    )
    return controller, transport, http, speech


def _local_common(frame_type):
    return {
        "type": frame_type,
        "schema_version": "2",
        "speech_backend": "client_local",
        "device_id": DEVICE,
        "connection_generation": CONNECTION,
        "session_id": SESSION,
        "generation": 1,
        "speech_revision": 1,
    }


def test_controller_uses_selected_client_local_without_remote_media_or_fallback() -> None:
    controller, transport, http, speech = _local_controller()

    controller.handle_action("voice_session_start")

    create = next(call for call in http.calls if call[0] == "create_local")
    assert create[1]["schema_version"] == "2"
    assert create[1]["client_capability"]["transport"] == "client_local"
    assert create[1]["client_capability"]["full_duplex"] is False
    assert transport.local_frames[-1]["type"] == "voice_local_ready"
    assert controller.speech_backend == "client_local"

    unavailable, _transport, fallback_http, _speech = _local_controller(eligible=False)
    unavailable.handle_action("voice_session_start")
    assert [call[0] for call in fallback_http.calls] == ["capability_v2"]
    assert unavailable.state == "unavailable"


def test_v2_backend_mismatch_preserves_reason_for_remote_selection() -> None:
    error = urllib.error.HTTPError(
        "http://127.0.0.1/api/voice/v2/capability",
        409,
        "Conflict",
        {},
        io.BytesIO(b'{"error":"voice_unavailable","reason":"backend_mismatch"}'),
    )
    client = VoiceHttpClient(
        "http://127.0.0.1",
        lambda: "token",
        opener=lambda *_args, **_kwargs: (_ for _ in ()).throw(error),
    )
    with pytest.raises(voice_module.VoiceHttpError) as failure:
        client.capability_v2()
    assert failure.value.code == "backend_mismatch"


def test_controller_binds_local_final_once_and_speaks_only_authorized_announcement() -> None:
    controller, transport, _http, speech = _local_controller()
    controller.handle_action("voice_session_start")
    ready = {
        **_local_common("voice_local_session_ready"),
        "contract": "client_local/v1",
        "transport": "client_local",
        "configured_locale": "en-US",
        "chat_id": CHAT,
        "chat_context_revision": 1,
        "applied_chat_context_revision": 1,
        "foreground_active": True,
        "microphone_enabled": True,
        "speech_muted": False,
        "lease_expires_at": "2099-08-28T12:10:00Z",
    }
    assert controller.accept_frame(ready)
    started = transport.local_frames[-1]
    assert started["type"] == "voice_local_recognition_started"
    assert speech.started == 1
    bound = {
        **_local_common("voice_local_turn_bound"),
        "client_turn_id": started["client_turn_id"],
        "turn_id": TURN,
        "submission_id": SUBMISSION,
        "request_generation": REQUEST,
        "chat_id": CHAT,
        "chat_context_revision": 1,
        "recognition_sequence": 1,
        "binding_expires_at": "2099-08-28T12:02:00Z",
    }
    assert controller.accept_frame(bound)
    speech.on_final("Do the authorized work")
    speech.on_final("Do the authorized work")
    finals = [frame for frame in transport.local_frames if frame["type"] == "voice_local_final"]
    assert len(finals) == 1
    assert finals[0]["text_digest_sha256"] == hashlib.sha256(b"Do the authorized work").hexdigest()

    announcement = {
        **_local_common("voice_local_announcement"),
        "announcement_id": "00000000-0000-4000-8000-000000000009",
        "announcement_sequence": 1,
        "turn_id": TURN,
        "kind": "result",
        "output_policy": "lifecycle",
        "locale": "en-US",
        "text": "Authorized result",
        "text_digest_sha256": hashlib.sha256(b"Authorized result").hexdigest(),
        "expires_at": "2099-08-28T12:00:10Z",
        "foreground_required": True,
        "mute_revision": 1,
        "consent_revision": 1,
    }
    altered = {**announcement, "announcement_sequence": 2, "text": "Altered"}
    assert not controller.accept_frame(altered)
    assert controller.accept_frame(announcement)
    assert speech.spoken == [("Authorized result", "en-US")]
    assert [
        frame["phase"]
        for frame in transport.local_frames
        if frame["type"] == "voice_local_playout_event"
    ] == ["started", "finished"]


def test_helper_protocol_round_trip_and_rejects_malformed_or_oversized_frames() -> None:
    encoded = encode_helper_frame("pcm", b"\x01\x02")
    assert read_helper_frame(io.BytesIO(encoded)) == ("pcm", b"\x01\x02")

    with pytest.raises(ValueError, match="PCM frame"):
        encode_helper_frame("pcm", b"x" * (HELPER_MAX_PCM_BYTES + 1))
    with pytest.raises(ValueError, match="text frame"):
        encode_helper_frame("final", "x" * (HELPER_MAX_TEXT_BYTES + 1))
    with pytest.raises(ValueError, match="header"):
        read_helper_frame(io.BytesIO(b"short"))
    malformed = b"BAD!" + struct.pack("<BBHI", 1, 4, 0, 0)
    with pytest.raises(ValueError, match="magic"):
        read_helper_frame(io.BytesIO(malformed))


def test_helper_launch_uses_only_inherited_pipes_and_scrubbed_environment(tmp_path) -> None:
    helper_path = tmp_path / "AstralSpeechHelper.exe"
    helper_path.write_bytes(b"first-party-helper")
    process = FakeProcess([encode_helper_frame("ready", b'{"locale":"en-US"}')])
    launches: list[tuple] = []

    def popen(args, **kwargs):
        launches.append((args, kwargs))
        return process

    helper = WindowsSpeechHelper(
        helper_path=helper_path,
        popen=popen,
        environment={
            "SystemRoot": r"C:\\Windows",
            "WINDIR": r"C:\\Windows",
            "TEMP": r"C:\\secret-temp",
            "VOICE_CONTROL_SECRET": "must-not-cross",
            "HTTP_PROXY": "http://proxy.invalid",
            "PATH": r"C:\\untrusted",
        },
    )

    assert helper.capability()
    args, kwargs = launches[0]
    assert args == [str(helper_path), "--stdio"]
    assert kwargs["stdin"] is not None and kwargs["stdout"] is not None
    assert kwargs["stderr"] is not None
    assert kwargs["shell"] is False
    assert kwargs["cwd"] == str(helper_path.parent)
    assert kwargs["env"] == {
        "SystemRoot": r"C:\\Windows",
        "WINDIR": r"C:\\Windows",
    }
    assert "network" not in kwargs
    assert list(tmp_path.iterdir()) == [helper_path]


def test_helper_close_cancels_blocked_readiness_without_stale_ready(tmp_path) -> None:
    helper_path = tmp_path / "AstralSpeechHelper.exe"
    helper_path.write_bytes(b"first-party-helper")
    process = BlockingReadyProcess([encode_helper_frame("ready", b'{"locale":"en-US"}')])
    helper = WindowsSpeechHelper(helper_path=helper_path, popen=lambda *_args, **_kwargs: process)
    capability_result = []
    probe = threading.Thread(
        target=lambda: capability_result.append(helper.capability()), daemon=True
    )
    probe.start()
    assert process.stdout.read_started.wait(1)

    closer = threading.Thread(target=helper.close, daemon=True)
    closer.start()
    closer.join(0.2)
    closed_promptly = not closer.is_alive()
    if not closed_promptly:
        process.stdout.release.set()
    probe.join(1)
    closer.join(1)

    assert closed_promptly
    assert process.terminated == 1
    assert capability_result == [False]
    assert not helper._ready
    assert helper._process is None
    assert helper._state == "closed"


def test_adapter_requires_both_local_engines_and_reports_typed_fallback() -> None:
    adapter = QtLocalSpeechAdapter(audio=FakeAudio(), helper=FakeHelper(ready=False), tts=FakeTts())
    assert adapter.capability() == {
        "eligible": False,
        "reason": "local_recognition_unavailable",
    }

    adapter = QtLocalSpeechAdapter(audio=FakeAudio(), helper=FakeHelper(), tts=FakeTts(ready=False))
    assert adapter.capability() == {
        "eligible": False,
        "reason": "local_synthesis_unavailable",
    }


def test_adapter_bounds_pcm_deduplicates_final_and_keeps_audio_in_memory() -> None:
    audio = FakeAudio()
    helper = FakeHelper()
    adapter = QtLocalSpeechAdapter(audio=audio, helper=helper, tts=FakeTts())
    finals: list[str] = []
    errors: list[str] = []

    assert adapter.start_recognition(finals.append, errors.append)
    assert audio.capture_callback is not None
    audio.capture_callback(b"a" * (HELPER_MAX_PCM_BYTES * 2 + 7))
    assert [len(chunk) for chunk in helper.pcm] == [HELPER_MAX_PCM_BYTES] * 2 + [7]

    helper.on_final("  cafe\u0301\r\n  ")
    helper.on_final("  cafe\u0301\r\n  ")
    assert finals == ["caf\u00e9"]
    assert errors == []
    assert not hasattr(adapter, "audio_path")


def test_adapter_stops_capture_during_tts_and_reopens_after_exact_500ms_fence() -> None:
    audio = FakeAudio()
    helper = FakeHelper()
    tts = FakeTts()
    scheduler = FakeScheduler()
    adapter = QtLocalSpeechAdapter(audio=audio, helper=helper, tts=tts, schedule=scheduler)
    finals: list[str] = []
    phases: list[str] = []
    assert adapter.start_recognition(finals.append, lambda _reason: None)

    assert adapter.speak("Authorized announcement", "en-US", phases.append)
    assert audio.stopped == 1
    assert helper.stopped == 1
    assert phases == ["started"]
    assert tts.callback is not None

    tts.callback("finished")
    assert phases == ["started", "finished"]
    assert [(delay, callable(callback)) for delay, callback in scheduler.calls] == [(500, True)]
    assert audio.started == 1
    scheduler.calls[0][1]()
    assert audio.started == 2
    assert helper.started == 2


@pytest.mark.parametrize("terminal", ["interrupted", "failed"])
def test_adapter_terminal_playout_and_crash_fail_closed_without_remote_fallback(
    terminal: str,
) -> None:
    audio = FakeAudio()
    helper = FakeHelper()
    tts = FakeTts()
    scheduler = FakeScheduler()
    adapter = QtLocalSpeechAdapter(audio=audio, helper=helper, tts=tts, schedule=scheduler)
    errors: list[str] = []
    assert adapter.start_recognition(lambda _text: None, errors.append)
    assert adapter.speak("Current text", "en-US", lambda _phase: None)
    tts.callback(terminal)
    assert scheduler.calls[0][0] == 500

    helper.on_error("helper_crashed")
    assert errors == ["local_engine_lost"]
    assert audio.stopped >= 2
    assert helper.stopped == 1
    assert adapter.capability()["eligible"] is False
    assert "remote" not in adapter.capability()


def test_stop_logout_and_close_synchronously_clear_every_local_owner() -> None:
    audio = FakeAudio()
    helper = FakeHelper()
    tts = FakeTts()
    adapter = QtLocalSpeechAdapter(audio=audio, helper=helper, tts=tts)
    assert adapter.start_recognition(lambda _text: None, lambda _reason: None)

    adapter.stop_all()
    assert audio.stopped == 1
    assert helper.stopped == 1
    assert tts.calls[-1] == ("stop",)

    adapter.close()
    assert audio.stopped == 2
    assert helper.closed == 1


def test_pending_echo_fence_restart_is_cancelled_by_stop() -> None:
    audio = FakeAudio()
    helper = FakeHelper()
    tts = FakeTts()
    scheduler = FakeScheduler()
    adapter = QtLocalSpeechAdapter(audio=audio, helper=helper, tts=tts, schedule=scheduler)
    assert adapter.start_recognition(lambda _text: None, lambda _reason: None)
    assert adapter.speak("Current announcement", "en-US", lambda _phase: None)
    tts.callback("finished")
    assert scheduler.calls[-1][0] == 500

    adapter.stop_all()
    starts = helper.started
    scheduler.calls[-1][1]()

    assert helper.started == starts
    assert audio.capture_callback is None


def test_helper_rejects_stop_before_start_and_repeated_start_fail_closed(tmp_path) -> None:
    helper_path = tmp_path / "AstralSpeechHelper.exe"
    helper_path.write_bytes(b"first-party-helper")
    first = FakeProcess([encode_helper_frame("ready", b'{"locale":"en-US"}')])
    helper = WindowsSpeechHelper(helper_path=helper_path, popen=lambda *_args, **_kwargs: first)
    assert helper.capability()

    with pytest.raises(RuntimeError, match="invalid_helper_state"):
        helper.stop_recognition()
    assert first.terminated == 1

    second = FakeProcess([encode_helper_frame("ready", b'{"locale":"en-US"}')])
    helper = WindowsSpeechHelper(helper_path=helper_path, popen=lambda *_args, **_kwargs: second)
    assert helper.capability()
    helper._reader = type("Reader", (), {"is_alive": lambda self: True})()
    helper.start_recognition(lambda _text: None, lambda _reason: None)
    with pytest.raises(RuntimeError, match="invalid_helper_state"):
        helper.start_recognition(lambda _text: None, lambda _reason: None)
    assert second.terminated == 1


@pytest.mark.parametrize("payload", [b"\x00\x00", b"", "not-bytes"])
def test_helper_rejects_pcm_before_start_and_after_stop_fail_closed(tmp_path, payload) -> None:
    helper_path = tmp_path / "AstralSpeechHelper.exe"
    helper_path.write_bytes(b"first-party-helper")
    before = FakeProcess([encode_helper_frame("ready", b'{"locale":"en-US"}')])
    helper = WindowsSpeechHelper(helper_path=helper_path, popen=lambda *_args, **_kwargs: before)
    assert helper.capability()
    with pytest.raises(RuntimeError, match="invalid_helper_state"):
        helper.feed_pcm(payload)
    assert before.terminated == 1

    after = FakeProcess([encode_helper_frame("ready", b'{"locale":"en-US"}')])
    helper = WindowsSpeechHelper(helper_path=helper_path, popen=lambda *_args, **_kwargs: after)
    assert helper.capability()
    helper._reader = type("Reader", (), {"is_alive": lambda self: True})()
    helper.start_recognition(lambda _text: None, lambda _reason: None)
    helper.stop_recognition()
    with pytest.raises(RuntimeError, match="invalid_helper_state"):
        helper.feed_pcm(payload)
    assert after.terminated == 1


@pytest.mark.parametrize("payload", [b"", "not-bytes", b"x" * (HELPER_MAX_PCM_BYTES + 1)])
def test_helper_invalid_pcm_while_recognizing_fails_closed(tmp_path, payload) -> None:
    helper_path = tmp_path / "AstralSpeechHelper.exe"
    helper_path.write_bytes(b"first-party-helper")
    process = FakeProcess([encode_helper_frame("ready", b'{"locale":"en-US"}')])
    helper = WindowsSpeechHelper(helper_path=helper_path, popen=lambda *_args, **_kwargs: process)
    assert helper.capability()
    helper._reader = type("Reader", (), {"is_alive": lambda self: True})()
    helper.start_recognition(lambda _text: None, lambda _reason: None)

    with pytest.raises(ValueError, match="PCM frame"):
        helper.feed_pcm(payload)

    assert process.terminated == 1


def test_helper_serializes_pcm_before_concurrent_stop(tmp_path) -> None:
    helper_path = tmp_path / "AstralSpeechHelper.exe"
    helper_path.write_bytes(b"first-party-helper")
    process = FakeProcess([encode_helper_frame("ready", b'{"locale":"en-US"}')])
    helper = WindowsSpeechHelper(helper_path=helper_path, popen=lambda *_args, **_kwargs: process)
    assert helper.capability()
    helper._reader = type("Reader", (), {"is_alive": lambda self: True})()
    helper.start_recognition(lambda _text: None, lambda _reason: None)

    original_send = helper._send
    pcm_send_entered = threading.Event()
    release_pcm_send = threading.Event()
    stop_sent = threading.Event()

    def controlled_send(kind, payload=b""):
        if kind == "pcm":
            pcm_send_entered.set()
            assert release_pcm_send.wait(1)
        original_send(kind, payload)
        if kind == "stop":
            stop_sent.set()

    helper._send = controlled_send
    feed_thread = threading.Thread(target=helper.feed_pcm, args=(b"\x00\x00",))
    stop_thread = threading.Thread(target=helper.stop_recognition)
    feed_thread.start()
    assert pcm_send_entered.wait(1)
    stop_thread.start()
    stop_sent.wait(0.2)
    release_pcm_send.set()
    feed_thread.join(1)
    stop_thread.join(1)

    assert not feed_thread.is_alive()
    assert not stop_thread.is_alive()
    frames = io.BytesIO(process.stdin.bytes)
    assert [read_helper_frame(frames)[0] for _ in range(3)] == ["start", "pcm", "stop"]


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("  hello\r\nworld  ", "hello\nworld"),
        ("cafe\u0301", "caf\u00e9"),
    ],
)
def test_local_final_canonicalization_is_contract_exact(value: str, expected: str) -> None:
    assert canonicalize_local_final(value) == expected


@pytest.mark.parametrize("value", ["", "\x00", "a\x01b", "x" * 8001])
def test_local_final_canonicalization_rejects_empty_controls_and_oversize(
    value: str,
) -> None:
    with pytest.raises(ValueError):
        canonicalize_local_final(value)
