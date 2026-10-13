"""Tests for win_agent/process_supervision.py: the frozen-safe BYO supervisor against
the neutral conformance fixture — bounded pipe reading, spawn ownership, full
descendant-tree termination, and release of terminal processes from its registry.
"""

from __future__ import annotations

import ast
import dataclasses
import io
import json
import queue
import subprocess
import sys
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

import pytest

from astralprojection.resources import fixture_path
from win_agent.process_supervision import (
    DEFAULT_PROCESS_SUPERVISION_LIMITS,
    BoundedStreamReader,
    OutputStream,
    ProcessState,
    ProcessSupervisionLimits,
    ProcessSupervisor,
    TerminationReason,
)


_ROOT = Path(__file__).resolve().parents[2]
_VECTOR_PATH = fixture_path(
    "runtime_reliability_060/process-supervision-vectors.json"
)
_CORPUS = json.loads(_VECTOR_PATH.read_text(encoding="utf-8"))
_VECTORS = {item["id"]: item for item in _CORPUS["vectors"]}
_EXPECTED_IDS = {
    "dual-stream-high-output",
    "oversized-logical-line",
    "one-pipe-eof-other-continues",
    "descendant-tree-stop",
    "descendant-tree-quit",
    "crash-after-output",
    "silent-tree-cancellation",
}


class _RecordingPipe(io.BytesIO):
    def __init__(self, value: bytes) -> None:
        super().__init__(value)
        self.requested_sizes: list[int] = []
        self.close_called = False

    def read(self, size: int = -1) -> bytes:
        self.requested_sizes.append(size)
        return super().read(size)

    def close(self) -> None:
        self.close_called = True
        super().close()


class _ControlledPipe:
    def __init__(self) -> None:
        self.chunks: queue.Queue[bytes | OSError] = queue.Queue()
        self.requests: queue.Queue[int] = queue.Queue()
        self.close_called = False

    def read(self, size: int) -> bytes:
        self.requests.put(size)
        chunk = self.chunks.get()
        if isinstance(chunk, OSError):
            raise chunk
        return chunk

    def close(self) -> None:
        self.close_called = True
        self.chunks.put(b"")


@dataclasses.dataclass
class _WaitingReader:
    reader: BoundedStreamReader
    pipe: _ControlledPipe
    settled: threading.Event
    result: list[bytes | Exception]
    callback_entered: threading.Event
    callback_lines: list[bytes]


@contextmanager
def _reader_waiter(
    monkeypatch: pytest.MonkeyPatch,
    prefix: bytes,
    *,
    block_callback: bytes | None = None,
):
    pipe = _ControlledPipe()
    registered = threading.Event()
    settled = threading.Event()
    callback_entered = threading.Event()
    release_callback = threading.Event()
    result: list[bytes | Exception] = []
    callback_lines: list[bytes] = []

    def publish(line: bytes) -> None:
        callback_lines.append(line)
        if line == block_callback:
            callback_entered.set()
            release_callback.wait()

    reader = BoundedStreamReader(
        stream=OutputStream.STDOUT, pipe=pipe, on_line=publish
    )
    original_wait = reader._condition.wait

    def wait(timeout: float | None = None) -> bool:
        registered.set()
        return original_wait(timeout)

    def await_line() -> None:
        try:
            result.append(reader.wait_for_line(prefix=prefix, timeout=5))
        except Exception as exc:
            result.append(exc)
        finally:
            settled.set()

    monkeypatch.setattr(reader._condition, "wait", wait)
    threads = (
        threading.Thread(target=reader.run, daemon=True),
        threading.Thread(target=await_line, daemon=True),
    )
    started: list[threading.Thread] = []
    try:
        for thread in threads:
            thread.start()
            started.append(thread)
        assert registered.wait(5)
        assert pipe.requests.get(timeout=5) == DEFAULT_PROCESS_SUPERVISION_LIMITS.read_chunk_bytes
        yield _WaitingReader(
            reader, pipe, settled, result, callback_entered, callback_lines
        )
    finally:
        release_callback.set()
        pipe.close()
        for thread in started:
            thread.join(5)
        assert all(not thread.is_alive() for thread in started)


def _spawn(supervisor: ProcessSupervisor, script: str):
    return supervisor.spawn(
        process_id=uuid.uuid4(),
        argv=(sys.executable, "-u", "-c", script),
    )


def _emit_script(stdout_count, stdout_size, stderr_count, stderr_size, exit_code=0):
    return (
        "import os\n"
        "def emit(fd, payload):\n"
        "    remaining = memoryview(payload)\n"
        "    while remaining:\n"
        "        written = os.write(fd, remaining[:16384])\n"
        "        if written <= 0: raise RuntimeError('output write made no progress')\n"
        "        remaining = remaining[written:]\n"
        f"out = b'O' * {stdout_size} + b'\\n'\n"
        f"err = b'E' * {stderr_size} + b'\\n'\n"
        f"emit(1, out * {stdout_count})\n"
        f"emit(2, err * {stderr_count})\n"
        f"raise SystemExit({exit_code})\n"
    )


def _tree_script(period: float = 0.005) -> str:
    descendant = "import time\nwhile True: time.sleep(0.05)\n"
    return (
        "import os,subprocess,sys,time\n"
        f"child = subprocess.Popen([sys.executable, '-u', '-c', {descendant!r}])\n"
        "os.write(1, f'READY {child.pid}\\n'.encode())\n"
        f"while True: time.sleep({period!r})\n"
    )


def _assert_cleanup(snapshot) -> None:
    assert snapshot.readers_joined is True
    assert snapshot.monitor_joined is True
    assert snapshot.pipes_closed is True
    assert snapshot.process_tree_terminated is True
    assert snapshot.cleanup_duration_seconds <= 5.0
    assert snapshot.cleanup_error is None


def test_neutral_fixture_and_local_defaults_are_one_frozen_contract() -> None:
    assert _CORPUS["schema_version"] == 1
    assert _CORPUS["contract"] == "astraldeep-process-supervision-060"
    assert set(_VECTORS) == _EXPECTED_IDS
    fixture = _CORPUS["limits"]
    limits = DEFAULT_PROCESS_SUPERVISION_LIMITS
    assert limits.read_chunk_bytes == fixture["read_chunk_bytes"]
    assert limits.maximum_logical_line_bytes == fixture["maximum_logical_line_bytes"]
    assert limits.ring_capacity_bytes_per_stream == fixture["ring_capacity_bytes_per_stream"]
    assert limits.ring_capacity_bytes_per_process == fixture["ring_capacity_bytes_per_process"]
    assert limits.termination_deadline_seconds == fixture["termination_deadline_ms"] / 1000
    with pytest.raises(dataclasses.FrozenInstanceError):
        limits.read_chunk_bytes = 1  # type: ignore[misc]


@pytest.mark.parametrize(
    "kwargs",
    [
        {"read_chunk_bytes": 0},
        {"force_kill_after_seconds": 5.0},
        {"ring_capacity_bytes_per_stream": 2, "ring_capacity_bytes_per_process": 3},
    ],
)
def test_invalid_supervision_limits_fail_closed(kwargs) -> None:
    with pytest.raises(ValueError):
        ProcessSupervisionLimits(**kwargs)


def test_reader_uses_fixed_binary_reads_bounds_lines_and_closes_pipe() -> None:
    limits = DEFAULT_PROCESS_SUPERVISION_LIMITS
    pipe = _RecordingPipe(b"A" * (limits.maximum_logical_line_bytes * 2) + b"\nend\n")
    diagnostics: list[tuple[str, str]] = []
    reader = BoundedStreamReader(
        stream=OutputStream.STDOUT,
        pipe=pipe,
        on_diagnostic=lambda code, stream: diagnostics.append((code, stream.value)),
    )

    reader.run()
    snapshot = reader.snapshot()

    assert set(pipe.requested_sizes) == {limits.read_chunk_bytes}
    assert snapshot.overlong_lines == 1
    assert snapshot.maximum_retained_line_bytes <= limits.maximum_logical_line_bytes
    assert diagnostics == [("output_line_too_long", "stdout")]
    assert snapshot.reader_done and snapshot.pipe_closed and pipe.close_called


def test_reader_error_timeout_eof_and_tiny_ring_paths_are_bounded() -> None:
    class BrokenPipe(_RecordingPipe):
        def read(self, size: int = -1) -> bytes:
            raise OSError("fixture read failure")

    broken = BoundedStreamReader(stream=OutputStream.STDERR, pipe=BrokenPipe(b""))
    broken.run()
    assert "fixture read failure" in (broken.snapshot().read_error or "")
    with pytest.raises(EOFError):
        broken.wait_for_line(prefix=b"never", timeout=0.01)

    pending = BoundedStreamReader(
        stream=OutputStream.STDOUT,
        pipe=_RecordingPipe(b""),
    )
    with pytest.raises(TimeoutError):
        pending.wait_for_line(prefix=b"never", timeout=0.001)
    pending.close_pipe()
    pending.close_pipe()

    tiny = BoundedStreamReader(
        stream=OutputStream.STDOUT,
        pipe=_RecordingPipe(b"abcdef\n"),
        limits=ProcessSupervisionLimits(
            read_chunk_bytes=4,
            maximum_logical_line_bytes=8,
            ring_capacity_bytes_per_stream=4,
            ring_capacity_bytes_per_process=8,
            force_kill_after_seconds=0.5,
            termination_deadline_seconds=1,
        ),
    )
    tiny.run()
    assert tiny.snapshot().dropped_lines == 1


@pytest.mark.parametrize("terminal", [b"READY payload\n", OSError("closing read")])
def test_reader_publication_and_snapshot_progress_while_pipe_close_blocks(terminal) -> None:
    close_entered = threading.Event()
    release_close = threading.Event()
    reader_settled = threading.Event()

    class ClosingPipe(_ControlledPipe):
        close_count = 0

        def close(self) -> None:
            self.close_count += 1
            close_entered.set()
            release_close.wait()
            super().close()

    pipe = ClosingPipe()
    callbacks: list[bytes] = []
    reader = BoundedStreamReader(
        stream=OutputStream.STDOUT,
        pipe=pipe,
        on_line=callbacks.append,
        on_eof=lambda _: reader_settled.set(),
    )
    threads = [
        threading.Thread(target=reader.run, daemon=True),
        threading.Thread(target=reader.close_pipe, daemon=True),
    ]
    try:
        threads[0].start()
        assert pipe.requests.get(timeout=5) == DEFAULT_PROCESS_SUPERVISION_LIMITS.read_chunk_bytes
        threads[1].start()
        assert close_entered.wait(5)
        pipe.chunks.put(terminal)
        pipe.chunks.put(b"")
        assert reader_settled.wait(5)
        snapshot = reader.snapshot()
        assert snapshot.reader_done and not snapshot.pipe_closed
        assert snapshot.read_error is None
        assert callbacks == ([terminal.rstrip(b"\n")] if isinstance(terminal, bytes) else [])
        reader.close_pipe()
        assert pipe.close_count == 1
    finally:
        release_close.set()
        for thread in threads:
            if thread.ident is not None:
                thread.join(5)
        assert all(not thread.is_alive() for thread in threads)
    assert reader.snapshot().pipe_closed
    assert pipe.close_called and pipe.close_count == 1


@pytest.mark.parametrize("error", [OSError("close failure"), ValueError("already closed"), RuntimeError("close failure")])
def test_reader_close_failure_preserves_the_error_contract_and_allows_retry(error) -> None:
    class FailingClosePipe(_RecordingPipe):
        def close(self) -> None:
            if not self.close_called:
                self.close_called = True
                raise error
            super().close()

    pipe = FailingClosePipe(b"")
    reader = BoundedStreamReader(stream=OutputStream.STDOUT, pipe=pipe)
    if isinstance(error, RuntimeError):
        with pytest.raises(RuntimeError, match="close failure"):
            reader.close_pipe()
        assert not reader.snapshot().pipe_closed
    else:
        reader.close_pipe()
        assert reader.snapshot().pipe_closed
    reader.close_pipe()
    assert reader.snapshot().pipe_closed


def test_reader_publishes_multi_line_chunk_to_waiter_before_callbacks_finish(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    payload = b"alpha\nREADY payload\nomega\npar"
    with _reader_waiter(monkeypatch, b"READY ", block_callback=b"alpha") as state:
        state.pipe.chunks.put(payload)
        assert state.callback_entered.wait(5)
        assert state.settled.wait(5)
        assert state.result == [b"READY payload"]
        assert state.callback_lines == [b"alpha"]
        snapshot = state.reader.snapshot()
        assert snapshot.lines == (b"alpha", b"READY payload", b"omega")
        assert snapshot.total_bytes == len(payload)
        assert snapshot.total_lines == 3
        assert snapshot.reader_done is False

    snapshot = state.reader.snapshot()
    assert state.callback_lines == [b"alpha", b"READY payload", b"omega", b"par"]
    assert snapshot.lines == tuple(state.callback_lines)
    assert snapshot.total_bytes == snapshot.retained_bytes == len(payload)
    assert snapshot.total_lines == 4
    assert snapshot.reader_done and snapshot.pipe_closed


def test_reader_keeps_partial_chunks_pending_until_the_line_completes(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    with _reader_waiter(monkeypatch, b"READY ") as state:
        for chunk in (b"REA", b"DY payload"):
            state.pipe.chunks.put(chunk)
            assert (
                state.pipe.requests.get(timeout=5)
                == DEFAULT_PROCESS_SUPERVISION_LIMITS.read_chunk_bytes
            )
            assert not state.settled.is_set()
            assert state.reader.snapshot().total_lines == 0
            assert state.callback_lines == []
        state.pipe.chunks.put(b"\n")
        assert state.settled.wait(5)
        assert state.result == [b"READY payload"]

    snapshot = state.reader.snapshot()
    assert state.callback_lines == [b"READY payload"]
    assert snapshot.total_bytes == len(b"READY payload\n")
    assert snapshot.total_lines == 1
    assert snapshot.reader_done and snapshot.pipe_closed


def test_reader_publishes_eof_trailing_line_before_its_callback_finishes(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    payload = b"READY payload"
    with _reader_waiter(monkeypatch, b"READY ", block_callback=payload) as state:
        state.pipe.chunks.put(payload)
        assert (
            state.pipe.requests.get(timeout=5)
            == DEFAULT_PROCESS_SUPERVISION_LIMITS.read_chunk_bytes
        )
        assert not state.settled.is_set()
        state.pipe.chunks.put(b"")
        assert state.callback_entered.wait(5)
        assert state.settled.wait(5)
        assert state.result == [payload]
        assert state.reader.snapshot().reader_done is False

    snapshot = state.reader.snapshot()
    assert state.callback_lines == [payload]
    assert snapshot.lines == (payload,)
    assert snapshot.total_bytes == snapshot.retained_bytes == len(payload)
    assert snapshot.total_lines == 1
    assert snapshot.reader_done and snapshot.pipe_closed


@pytest.mark.parametrize("terminal", [b"", OSError("controlled read failure")])
def test_reader_retires_waiting_missing_prefix_at_eof_or_read_failure(
    monkeypatch: pytest.MonkeyPatch, terminal: bytes | OSError
) -> None:
    with _reader_waiter(monkeypatch, b"missing") as state:
        state.pipe.chunks.put(terminal)
        assert state.settled.wait(5)
        assert len(state.result) == 1
        assert isinstance(state.result[0], EOFError)

    snapshot = state.reader.snapshot()
    assert snapshot.lines == ()
    assert snapshot.total_bytes == snapshot.total_lines == 0
    assert snapshot.reader_done and snapshot.pipe_closed and state.pipe.close_called
    assert snapshot.read_error == (
        "OSError: controlled read failure" if isinstance(terminal, OSError) else None
    )


def test_supervisor_rejects_invalid_or_duplicate_spawn_ownership() -> None:
    supervisor = ProcessSupervisor()
    with pytest.raises(TypeError):
        supervisor.spawn(process_id="not-a-uuid", argv=(sys.executable,))  # type: ignore[arg-type]
    with pytest.raises(ValueError):
        supervisor.spawn(process_id=uuid.uuid4(), argv=())
    with pytest.raises(ValueError):
        supervisor.spawn(
            process_id=uuid.uuid4(),
            argv=(sys.executable, "-c", "pass"),
            stdout=subprocess.PIPE,
        )

    process_id = uuid.uuid4()
    process = supervisor.spawn(
        process_id=process_id,
        argv=(sys.executable, "-u", "-c", "import time; time.sleep(10)"),
    )
    with pytest.raises(ValueError):
        supervisor.spawn(
            process_id=process_id,
            argv=(sys.executable, "-c", "pass"),
        )
    with pytest.raises(subprocess.TimeoutExpired):
        process.wait(timeout=0.001)
    _assert_cleanup(supervisor.terminate(process_id, reason=TerminationReason.CANCEL))


def test_supervisor_snapshots_and_terminate_all_cover_every_owned_child() -> None:
    supervisor = ProcessSupervisor()
    for _index in range(2):
        supervisor.spawn(
            process_id=uuid.uuid4(),
            argv=(sys.executable, "-u", "-c", "import time; time.sleep(10)"),
        )
    running = supervisor.snapshots()
    assert len(running) == 2
    assert all(snapshot.state is ProcessState.RUNNING for snapshot in running)
    settled = supervisor.terminate_all(reason=TerminationReason.QUIT)
    assert len(settled) == 2
    assert all(snapshot.state is ProcessState.KILLED for snapshot in settled)
    for snapshot in settled:
        _assert_cleanup(snapshot)


def test_terminal_processes_release_bounded_rings_from_long_lived_registry() -> None:
    supervisor = ProcessSupervisor()
    for _cycle in range(2):
        process = _spawn(supervisor, "raise SystemExit(0)\n")
        _assert_cleanup(process.wait(timeout=5))
        assert supervisor.snapshots() == ()
    assert supervisor.terminate_all(reason=TerminationReason.QUIT) == ()


def test_full_neutral_output_vectors_are_drained_and_bounded() -> None:
    high = _VECTORS["dual-stream-high-output"]["behavior"]
    supervisor = ProcessSupervisor()
    process = _spawn(
        supervisor,
        _emit_script(
            high["stdout"]["line_count"],
            high["stdout"]["line_bytes"],
            high["stderr"]["line_count"],
            high["stderr"]["line_bytes"],
        ),
    )
    try:
        high_snapshot = process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        supervisor.terminate_all(reason=TerminationReason.QUIT)
        raise
    assert high_snapshot.stdout.total_lines == high["stdout"]["line_count"]
    assert high_snapshot.stderr.total_lines == high["stderr"]["line_count"]
    assert high_snapshot.stdout.dropped_bytes > 0
    assert high_snapshot.stderr.dropped_bytes > 0
    _assert_cleanup(high_snapshot)

    oversized = _VECTORS["oversized-logical-line"]["behavior"]
    oversized_supervisor = ProcessSupervisor()
    process = _spawn(
        oversized_supervisor,
        _emit_script(
            oversized["stdout"]["line_count"],
            oversized["stdout"]["line_bytes"],
            0,
            0,
        ),
    )
    try:
        oversized_snapshot = process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        oversized_supervisor.terminate_all(reason=TerminationReason.QUIT)
        raise
    assert oversized_snapshot.stdout.overlong_lines >= 1
    assert oversized_snapshot.stdout.maximum_retained_line_bytes <= 65536
    _assert_cleanup(oversized_snapshot)


def test_one_pipe_eof_does_not_stop_the_other_reader() -> None:
    vector = _VECTORS["one-pipe-eof-other-continues"]["behavior"]
    script = (
        "import os,time\n"
        "os.close(1)\n"
        f"time.sleep({vector['delay_after_close_ms'] / 1000!r})\n"
        f"line = b'E' * {vector['continuing_line_bytes']} + b'\\n'\n"
        f"for _ in range({vector['continuing_line_count']}): os.write(2, line)\n"
    )
    snapshot = _spawn(ProcessSupervisor(), script).wait(timeout=10)
    assert snapshot.stdout.reader_done is True
    assert snapshot.stderr.total_lines == vector["continuing_line_count"]
    _assert_cleanup(snapshot)


def test_crash_exit_is_failed_only_after_complete_cleanup() -> None:
    vector = _VECTORS["crash-after-output"]["behavior"]
    snapshot = _spawn(
        ProcessSupervisor(),
        _emit_script(
            vector["stdout"]["line_count"],
            vector["stdout"]["line_bytes"],
            vector["stderr"]["line_count"],
            vector["stderr"]["line_bytes"],
            vector["exit_code"],
        ),
    ).wait(timeout=10)
    assert snapshot.exit_code == 23
    assert snapshot.state is ProcessState.FAILED
    _assert_cleanup(snapshot)


def test_stop_quit_and_cancel_terminate_the_complete_descendant_tree() -> None:
    for reason in (TerminationReason.STOP, TerminationReason.QUIT, TerminationReason.CANCEL):
        process = _spawn(ProcessSupervisor(), _tree_script())
        process.wait_for_line(OutputStream.STDOUT, prefix=b"READY ", timeout=3)
        started = time.monotonic()
        snapshot = process.terminate(reason=reason)
        assert time.monotonic() - started <= 5.0
        _assert_cleanup(snapshot)


def test_noncooperative_tree_is_force_killed_by_four_and_clean_by_five_seconds() -> None:
    descendant = (
        "import signal,time\n"
        "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        "signal.signal(signal.SIGINT, signal.SIG_IGN)\n"
        "while True: time.sleep(.05)\n"
    )
    script = (
        "import os,signal,subprocess,sys,time\n"
        "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        "signal.signal(signal.SIGINT, signal.SIG_IGN)\n"
        f"child=subprocess.Popen([sys.executable,'-u','-c',{descendant!r}])\n"
        "os.write(1, f'READY {child.pid}\\n'.encode())\n"
        "while True: time.sleep(.05)\n"
    )
    process = _spawn(ProcessSupervisor(), script)
    process.wait_for_line(OutputStream.STDOUT, prefix=b"READY ", timeout=3)
    started = time.monotonic()
    snapshot = process.terminate(reason=TerminationReason.CANCEL)
    elapsed = time.monotonic() - started

    if sys.platform != "win32":
        assert 3.8 <= elapsed
    assert elapsed <= 5.0
    _assert_cleanup(snapshot)


def test_host_is_the_only_supervisor_and_worker_remains_a_child_entry() -> None:
    host_path = _ROOT / "windows-client" / "win_agent" / "byo_host.py"
    worker_path = _ROOT / "windows-client" / "win_agent" / "byo_worker.py"
    supervisor_path = _ROOT / "windows-client" / "win_agent" / "process_supervision.py"
    host_source = host_path.read_text(encoding="utf-8")
    worker_source = worker_path.read_text(encoding="utf-8")
    supervisor_source = supervisor_path.read_text(encoding="utf-8")

    assert "from win_agent.process_supervision import" in host_source
    assert "subprocess.Popen" not in host_source
    assert "process_supervision" not in worker_source
    assert "backend." not in supervisor_source
    assert "shared.process_supervision" not in supervisor_source

    host_tree = ast.parse(host_source)
    worker_tree = ast.parse(worker_source)
    assert any(
        isinstance(node, ast.Attribute) and node.attr == "spawn"
        for node in ast.walk(host_tree)
    )
    assert not any(
        isinstance(node, (ast.Import, ast.ImportFrom))
        and "process_supervision" in ast.unparse(node)
        for node in ast.walk(worker_tree)
    )
