"""Defensive branch coverage for the Feature 075 local speech adapter."""

from __future__ import annotations

import io
import pathlib
from typing import Any

import pytest

pytest.importorskip("PySide6")

from astral_client import voice as voice_module  # noqa: E402
from astral_client.helper_integrity import HelperIntegrityResult  # noqa: E402


class _Stdin:
    def __init__(self, *, fail_write: bool = False) -> None:
        self.fail_write = fail_write
        self.data = bytearray()

    def write(self, value: bytes) -> int:
        if self.fail_write:
            raise OSError("pipe closed")
        self.data.extend(value)
        return len(value)

    def flush(self) -> None:
        pass


class _Process:
    def __init__(self, frames: bytes = b"", *, fail_write: bool = False) -> None:
        self.stdin = _Stdin(fail_write=fail_write)
        self.stdout = io.BytesIO(frames)
        self.terminated = 0
        self.killed = 0
        self.returncode: int | None = None

    def poll(self) -> int | None:
        return self.returncode

    def terminate(self) -> None:
        self.terminated += 1
        self.returncode = 0

    def wait(self, timeout: float | None = None) -> int:
        del timeout
        return 0

    def kill(self) -> None:
        self.killed += 1
        self.returncode = -9


def _helper_with_process(
    frames: bytes,
    *,
    state: str = "recognizing",
    active_id: int | None = 1,
    stopping_id: int | None = None,
    generation: int = 7,
    fail_write: bool = False,
) -> tuple[voice_module.WindowsSpeechHelper, _Process]:
    helper = voice_module.WindowsSpeechHelper(environment={})
    process = _Process(frames, fail_write=fail_write)
    helper._process = process
    helper._ready = state == "ready"
    helper._state = state
    helper._active_recognition_id = active_id
    helper._stopping_recognition_id = stopping_id
    helper._lifecycle_generation = generation
    return helper, process


def test_frame_reader_rejects_cycle_kind_without_recognition_id() -> None:
    header = voice_module._HELPER_HEADER.pack(
        voice_module._HELPER_MAGIC,
        voice_module._HELPER_VERSION,
        voice_module._HELPER_KINDS["pcm"],
        0,
        0,
    )

    with pytest.raises(ValueError, match="recognition cycle"):
        voice_module.read_helper_frame(io.BytesIO(header))


@pytest.mark.parametrize(
    ("integrity_verifier", "expected_reason"),
    [
        (
            lambda _path: (_ for _ in ()).throw(RuntimeError("trust provider failed")),
            "exception",
        ),
        (
            lambda _path: HelperIntegrityResult(False, "signature_invalid"),
            "unavailable",
        ),
    ],
)
def test_helper_launch_never_spawns_after_integrity_failure(
    tmp_path: pathlib.Path,
    integrity_verifier: Any,
    expected_reason: str,
) -> None:
    helper_path = tmp_path / "AstralSpeechHelper.exe"
    helper_path.write_bytes(b"untrusted candidate")
    launches: list[bool] = []
    helper = voice_module.WindowsSpeechHelper(
        helper_path=helper_path,
        popen=lambda *_args, **_kwargs: launches.append(True),
        environment={},
        integrity_verifier=integrity_verifier,
    )

    assert helper.capability() is False, expected_reason
    assert launches == []
    assert helper._process is None


@pytest.mark.parametrize(
    ("frame", "expected_callback"),
    [
        (
            voice_module.encode_helper_frame("final", b"\xff", 1),
            "local_engine_lost",
        ),
        (
            voice_module.encode_helper_frame("final", "stale final", 2),
            "local_engine_lost",
        ),
        (
            voice_module.encode_helper_frame("error", b"not-json", 1),
            "local_engine_lost",
        ),
        (
            voice_module.encode_helper_frame("error", b'{"reason":"unexpected"}', 1),
            "local_engine_lost",
        ),
        (
            voice_module.encode_helper_frame("error", b'{"reason":"local_recognition_failed"}', 2),
            "local_engine_lost",
        ),
        (
            voice_module.encode_helper_frame("stopped", b"unexpected", 1),
            "local_engine_lost",
        ),
        (voice_module.encode_helper_frame("ready"), "local_engine_lost"),
    ],
    ids=(
        "non-utf8-final",
        "stale-final",
        "malformed-error",
        "wrong-error-reason",
        "stale-error",
        "stopped-with-payload",
        "unexpected-frame-kind",
    ),
)
def test_helper_reader_fails_closed_on_malformed_or_stale_frames(
    frame: bytes,
    expected_callback: str,
) -> None:
    helper, process = _helper_with_process(frame)
    callbacks: list[str] = []
    helper._on_error = callbacks.append

    helper._read_loop(process, helper._lifecycle_generation)

    assert callbacks == [expected_callback]
    assert helper._state == "closed"
    assert helper._process is None
    assert process.terminated == 1


@pytest.mark.parametrize(
    "frame",
    [
        voice_module.encode_helper_frame("final", "late final", 1),
        voice_module.encode_helper_frame("error", b'{"reason":"local_recognition_failed"}', 1),
        voice_module.encode_helper_frame("stopped", recognition_id=1),
    ],
    ids=("final", "error", "stopped"),
)
def test_helper_reader_ignores_frames_from_a_superseded_generation(frame: bytes) -> None:
    helper, process = _helper_with_process(frame)
    callbacks: list[str] = []
    helper._on_final = callbacks.append
    helper._on_error = callbacks.append

    helper._read_loop(process, helper._lifecycle_generation - 1)

    assert callbacks == []
    assert helper._process is process
    assert helper._state == "recognizing"
    helper.abort_recognition()


@pytest.mark.parametrize("kind", ["final", "error"])
def test_helper_reader_discards_frames_for_a_cycle_being_stopped(kind: str) -> None:
    payload = "late final" if kind == "final" else b'{"reason":"local_recognition_failed"}'
    frame = voice_module.encode_helper_frame(kind, payload, 1)
    helper, process = _helper_with_process(
        frame,
        state="stopping",
        active_id=None,
        stopping_id=1,
    )
    helper._stopped_event = voice_module.threading.Event()
    callbacks: list[str] = []
    helper._on_final = callbacks.append
    helper._on_error = callbacks.append

    helper._read_loop(process, helper._lifecycle_generation)

    assert callbacks == []
    assert helper._state == "closed"
    assert process.terminated == 1


def test_helper_reader_delivers_typed_recognition_failure_once_and_scrubs() -> None:
    frame = voice_module.encode_helper_frame("error", b'{"reason":"local_recognition_failed"}', 1)
    helper, process = _helper_with_process(frame)
    callbacks: list[str] = []
    helper._on_error = callbacks.append

    helper._read_loop(process, helper._lifecycle_generation)

    assert callbacks == ["local_recognition_failed"]
    assert helper._on_error is None
    assert helper._active_recognition_id is None
    assert helper._state == "closed"
    assert process.terminated == 1


def test_helper_stop_pipe_failure_and_abort_both_fail_closed() -> None:
    helper, process = _helper_with_process(b"", fail_write=True)

    helper.stop_recognition()

    assert helper._state == "closed"
    assert helper._process is None
    assert process.terminated == 1

    helper, process = _helper_with_process(b"")
    helper.abort_recognition()

    assert helper._state == "closed"
    assert helper._process is None
    assert process.terminated == 1


def test_helper_close_is_idempotent_after_terminal_cleanup() -> None:
    helper, process = _helper_with_process(b"", state="ready", active_id=None)

    helper.close()
    helper.close()

    assert process.terminated == 1
    assert helper._disposed is True
    assert helper._state == "closed"


class _Signal:
    def __init__(self) -> None:
        self.callback: Any = None

    def connect(self, callback: Any) -> None:
        self.callback = callback


class _Voice:
    def __init__(self, locale: Any) -> None:
        self._locale = locale

    def locale(self) -> Any:
        return self._locale


def test_tts_capability_rejects_wrong_state_and_incomplete_voice_selection(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    original = voice_module.QTextToSpeech

    class FakeTextToSpeech:
        State = original.State

        def __init__(self, _engine: str, _parent: Any) -> None:
            self.stateChanged = _Signal()
            self.current_state = self.State.Ready
            self.current_locale = voice_module.QLocale("en_US")
            self.voices: list[_Voice] = [_Voice(self.current_locale)]

        def availableLocales(self) -> list[Any]:
            return [voice_module.QLocale("en_US")]

        def setLocale(self, locale: Any) -> None:
            self.current_locale = locale

        def locale(self) -> Any:
            return self.current_locale

        def availableVoices(self) -> list[_Voice]:
            return self.voices

        def setVoice(self, voice: _Voice) -> None:
            self.selected_voice = voice

        def voice(self) -> _Voice:
            return self.selected_voice

        def state(self) -> Any:
            return self.current_state

        def stop(self) -> None:
            pass

    monkeypatch.setattr(voice_module, "QTextToSpeech", FakeTextToSpeech)
    backend = voice_module._QtTextToSpeechBackend()

    assert backend.capability("fr-FR") is False
    backend._engine.current_state = original.State.Speaking
    assert backend.capability("en-US") is False
    backend._engine.current_state = original.State.Ready
    backend._engine.voices = []
    assert backend.capability("en-US") is False
    backend._engine.voices = [_Voice(voice_module.QLocale("en_US"))]
    backend._engine.current_locale = voice_module.QLocale("en_GB")
    backend._engine.setLocale = lambda _locale: None
    assert backend.capability("en-US") is False
    backend.deleteLater()


class _Audio:
    def __init__(self, *, fail_start: bool = False) -> None:
        self.fail_start = fail_start
        self.callback: Any = None
        self.starts = 0
        self.stops = 0

    def start_capture(self, callback: Any, *, sample_rate: int) -> None:
        assert sample_rate == 16_000
        self.starts += 1
        if self.fail_start:
            raise RuntimeError("capture failed")
        self.callback = callback

    def stop_capture(self) -> None:
        self.stops += 1
        self.callback = None


class _Helper:
    def __init__(self, *, fail_start: bool = False, fail_feed: bool = False) -> None:
        self.fail_start = fail_start
        self.fail_feed = fail_feed
        self.start_calls = 0
        self.feed_calls: list[bytes] = []
        self.stop_calls = 0
        self.abort_calls = 0
        self.on_final: Any = None
        self.on_error: Any = None

    def capability(self) -> bool:
        return True

    def start_recognition(self, on_final: Any, on_error: Any) -> None:
        self.start_calls += 1
        if self.fail_start:
            raise RuntimeError("helper start failed")
        self.on_final = on_final
        self.on_error = on_error

    def feed_pcm(self, pcm: bytes) -> None:
        self.feed_calls.append(pcm)
        if self.fail_feed:
            raise ValueError("helper rejected pcm")

    def stop_recognition(self) -> None:
        self.stop_calls += 1

    def abort_recognition(self) -> None:
        self.abort_calls += 1

    def close(self) -> None:
        pass


class _Tts:
    def __init__(self) -> None:
        self.callback: Any = None
        self.stop_calls = 0

    def capability(self, locale: str) -> bool:
        return locale == "en-US"

    def speak(self, _text: str, _locale: str, callback: Any) -> None:
        self.callback = callback

    def stop(self) -> None:
        self.stop_calls += 1


def test_adapter_capture_start_failure_aborts_helper_and_reports_once() -> None:
    audio = _Audio(fail_start=True)
    helper = _Helper()
    tts = _Tts()
    errors: list[str] = []
    adapter = voice_module.QtLocalSpeechAdapter(audio=audio, helper=helper, tts=tts)

    assert adapter.start_recognition(lambda _text: None, errors.append) is False

    assert errors == ["local_engine_lost"]
    assert helper.abort_calls == 1
    assert helper.stop_calls == 0
    assert audio.stops == 1
    assert tts.stop_calls == 1
    assert adapter.capability() == {
        "eligible": False,
        "reason": "local_recognition_unavailable",
    }


def test_adapter_ignores_stale_pcm_then_fails_closed_on_current_feed_error() -> None:
    audio = _Audio()
    helper = _Helper(fail_feed=True)
    tts = _Tts()
    errors: list[str] = []
    adapter = voice_module.QtLocalSpeechAdapter(audio=audio, helper=helper, tts=tts)
    assert adapter.start_recognition(lambda _text: None, errors.append)
    generation = adapter._active_recognition_generation
    assert generation is not None

    adapter._feed_pcm(generation - 1, b"stale")
    assert helper.feed_calls == []

    adapter._feed_pcm(generation, b"current")

    assert helper.feed_calls == [b"current"]
    assert helper.abort_calls == 1
    assert errors == ["local_engine_lost"]
    assert adapter._engine_available is False


def test_adapter_bounds_duplicate_phases_and_explicit_stop_cancels_restart() -> None:
    audio = _Audio()
    helper = _Helper()
    tts = _Tts()
    scheduled: list[tuple[int, Any]] = []
    phases: list[str] = []
    resumed: list[bool] = []
    adapter = voice_module.QtLocalSpeechAdapter(
        audio=audio,
        helper=helper,
        tts=tts,
        schedule=lambda delay, callback: scheduled.append((delay, callback)),
    )
    assert adapter.start_recognition(lambda _text: None, lambda _reason: None)

    assert adapter.speak(
        "Bound announcement",
        "en-US",
        phases.append,
        lambda: resumed.append(True),
    )
    assert tts.callback is not None
    tts.callback("started")
    tts.callback("started")
    tts.callback("finished")
    tts.callback("finished")

    assert phases == ["started", "finished"]
    assert len(scheduled) == 1
    assert scheduled[0][0] == 500

    adapter.stop_recognition()
    scheduled[0][1]()

    assert resumed == []
    assert helper.stop_calls == 1
    assert adapter._recognition_requested is False


def test_adapter_maps_unknown_tts_phase_to_one_terminal_failure() -> None:
    audio = _Audio()
    helper = _Helper()
    tts = _Tts()
    scheduled: list[tuple[int, Any]] = []
    phases: list[str] = []
    adapter = voice_module.QtLocalSpeechAdapter(
        audio=audio,
        helper=helper,
        tts=tts,
        schedule=lambda delay, callback: scheduled.append((delay, callback)),
    )

    assert adapter.speak(
        "Bound announcement",
        "en-US",
        phases.append,
        lambda: None,
    )
    assert tts.callback is not None
    tts.callback("provider-specific-state")
    tts.callback("finished")

    assert phases == ["failed"]
    assert len(scheduled) == 1
