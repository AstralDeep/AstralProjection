"""Feature 075 Windows client-local speech adapter behavior."""

from __future__ import annotations

import io
import struct

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
    assert helper.stopped >= 2
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
    assert tts.calls[-1] == ("stop",)


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
