"""Exercises the Windows download action through the real window save flow.
All responses, dialogs and workers are isolated test inputs, and destinations live in tmp_path.
"""

import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread
from types import SimpleNamespace

import pytest

pytest.importorskip("PySide6")

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ["ASTRAL_WIN_AGENT"] = "0"

from PySide6.QtCore import QSettings  # noqa: E402

from astral_client import app as appmod  # noqa: E402
from astral_client.app import MainWindow  # noqa: E402
from astral_client.rest import RestError  # noqa: E402


class _RecordingClient:
    def __init__(self, *a, **k):
        self.events = []

    def start(self):
        pass

    def stop(self):
        pass

    def send_event(self, action, payload, session_id=None):
        self.events.append((action, payload, session_id))


@pytest.fixture
def win(qapp, monkeypatch, tmp_path):
    settings = QSettings(str(tmp_path / "settings.ini"), QSettings.Format.IniFormat)
    monkeypatch.setattr(appmod, "create_settings", lambda: settings)
    monkeypatch.setattr(appmod, "OrchestratorClient", _RecordingClient)
    monkeypatch.setattr(MainWindow, "_start_integrity_check", lambda self: None)
    monkeypatch.setattr(MainWindow, "_init_workspace", lambda self: None)
    window = MainWindow("ws://127.0.0.1:9/ws", "dev-token", connect=False)
    yield window
    window.close()


@pytest.fixture
def workers(monkeypatch):
    queued = []

    def spawn(*, target, **kwargs):
        queued.append(target)
        return SimpleNamespace(start=lambda: None)

    monkeypatch.setattr(appmod.threading, "Thread", spawn)
    return queued


def choose(monkeypatch, destination):
    monkeypatch.setattr(
        appmod.QFileDialog, "getSaveFileName", lambda *a, **k: (str(destination), ""))


def test_download_saves_complete_payload_and_reports_saved(win, workers, tmp_path, monkeypatch):
    destination = tmp_path / "result.bin"
    destination.write_bytes(b"stale")
    choose(monkeypatch, destination)
    saved = []
    real_write = appmod.rest.write_download

    def write(path, data):
        saved.append((path, bytes(data)))
        real_write(path, data)

    monkeypatch.setattr(appmod.rest, "fetch_bytes", lambda *a, **k: b"fresh bytes")
    monkeypatch.setattr(appmod.rest, "write_download", write)

    win._download("/api/result", "result.bin")
    workers.pop()()

    assert destination.read_bytes() == b"fresh bytes"
    assert saved == [(str(destination), b"fresh bytes")]
    assert win.topbar._mark.toolTip() == "Saved result.bin"
    assert list(tmp_path.glob("*.part")) == []
    assert win._viewport_downloads == 0


def test_download_over_limit_failure_preserves_existing_file(win, workers, tmp_path, monkeypatch):
    destination = tmp_path / "result.bin"
    destination.write_bytes(b"keep me")
    choose(monkeypatch, destination)

    def too_large(*a, **k):
        raise RestError(0, "download too large: the body exceeded the download limit")

    monkeypatch.setattr(appmod.rest, "fetch_bytes", too_large)

    win._download("/api/result", "result.bin")
    workers.pop()()

    assert destination.read_bytes() == b"keep me"
    assert "Download failed" in win.topbar._mark.toolTip()
    assert "too large" in win.topbar._mark.toolTip()
    assert list(tmp_path.glob("*.part")) == []


def test_download_write_failure_preserves_existing_file(win, workers, tmp_path, monkeypatch):
    destination = tmp_path / "result.bin"
    destination.write_bytes(b"keep me")
    choose(monkeypatch, destination)

    def disk_full(path, data):
        raise OSError("disk full")

    monkeypatch.setattr(appmod.rest, "fetch_bytes", lambda *a, **k: b"payload")
    monkeypatch.setattr(appmod.rest, "write_download", disk_full)

    win._download("/api/result", "result.bin")
    workers.pop()()

    assert destination.read_bytes() == b"keep me"
    assert "Download failed" in win.topbar._mark.toolTip()
    assert "disk full" in win.topbar._mark.toolTip()
    assert list(tmp_path.glob("*.part")) == []


def test_download_zero_bytes_saves_empty_file(win, workers, tmp_path, monkeypatch):
    destination = tmp_path / "empty.bin"
    choose(monkeypatch, destination)
    monkeypatch.setattr(appmod.rest, "fetch_bytes", lambda *a, **k: b"")

    win._download("/api/result", "empty.bin")
    workers.pop()()

    assert destination.exists() and destination.read_bytes() == b""
    assert win.topbar._mark.toolTip() == "Saved empty.bin"


def test_download_without_destination_choice_does_nothing(win, workers, monkeypatch):
    choose(monkeypatch, "")
    monkeypatch.setattr(
        appmod.rest, "fetch_bytes", lambda *a, **k: pytest.fail("must not fetch"))

    win._download("/api/result", "result.bin")

    assert workers == []


@pytest.mark.parametrize(
    ("mode", "expected_size", "error"),
    [
        ("complete", 23, None),
        ("empty", 0, None),
        ("exact_limit", appmod.rest.DOWNLOAD_LIMIT, None),
        ("declared_overflow", None, "too large"),
        ("unframed_overflow", None, "too large"),
        ("chunked_overflow", None, "too large"),
        ("truncated", None, "truncated"),
    ],
)
def test_download_real_http_response_reaches_native_save_feedback(
    win, workers, tmp_path, monkeypatch, mode, expected_size, error,
):
    requests = []

    class DownloadHandler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            requests.append((self.path, self.headers.get("Authorization")))
            self.send_response(200)
            size = expected_size if expected_size is not None else appmod.rest.DOWNLOAD_LIMIT + 1
            if mode == "truncated":
                size = 21
            if mode == "chunked_overflow":
                self.send_header("Transfer-Encoding", "chunked")
            elif mode != "unframed_overflow":
                self.send_header("Content-Length", str(size))
            self.end_headers()
            if mode == "declared_overflow":
                return
            if mode == "truncated":
                self.wfile.write(b"partial")
                return
            remaining = size
            chunk = b"D" * 65536
            while remaining:
                body = chunk[:min(remaining, len(chunk))]
                if mode == "chunked_overflow":
                    self.wfile.write(f"{len(body):x}\r\n".encode("ascii"))
                self.wfile.write(body)
                if mode == "chunked_overflow":
                    self.wfile.write(b"\r\n")
                remaining -= len(body)
            if mode == "chunked_overflow":
                self.wfile.write(b"0\r\n\r\n")

    server = HTTPServer(("127.0.0.1", 0), DownloadHandler)
    worker = Thread(target=lambda: server.serve_forever(poll_interval=0.01), daemon=True)
    worker.start()
    destination = tmp_path / "result.bin"
    destination.write_bytes(b"keep me")
    choose(monkeypatch, destination)
    try:
        win._download(f"http://127.0.0.1:{server.server_port}/api/result", "result.bin")
        workers.pop()()
    finally:
        server.shutdown()
        server.server_close()
        worker.join()

    assert requests == [("/api/result", "Bearer dev-token")]
    if error:
        assert destination.read_bytes() == b"keep me"
        assert "Download failed" in win.topbar._mark.toolTip()
        assert error in win.topbar._mark.toolTip()
    else:
        assert destination.stat().st_size == expected_size
        assert destination.read_bytes() == b"D" * expected_size
        assert win.topbar._mark.toolTip() == "Saved result.bin"
    assert list(tmp_path.glob("*.part")) == []
    assert win._viewport_downloads == 0
