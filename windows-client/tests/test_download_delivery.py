"""Exercises the Windows download action through the real window save flow.
All responses, dialogs and workers are isolated test inputs, and destinations live in tmp_path.
"""

import os
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
