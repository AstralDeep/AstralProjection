"""Exercises connected release-smoke qualification against real native console state.
Mock transport responses cannot qualify a legacy or partially bootstrapped shell.
"""

import copy
import json
from pathlib import Path
from types import SimpleNamespace

import pytest
from PySide6.QtWidgets import QApplication

from astral_client import app as appmod
from astral_client.deployment import resolve_effective_profile
from test_message_routing import win as window_fixture  # noqa: F401


ROOT = Path(__file__).resolve().parents[2]
MENU = json.loads((ROOT / "contracts/fixtures/console/chrome-console.json").read_text(encoding="utf-8"))
PRESENTATION = json.loads((ROOT / "contracts/fixtures/console/rote-console.json").read_text(encoding="utf-8"))["cases"][5]["presentation"]
CHECKS = (
    "console_model_valid", "console_presentation_valid", "console_shell_current",
    "console_shell_visible", "legacy_topbar_hidden", "legacy_split_hidden",
)
FRAME = {
    "type": "conversation_snapshot", "snapshot_purpose": "commit",
    "chat_id": "11111111-1111-4111-8111-111111111111", "render_revision": 1,
    "transcript": [{"role": "user", "text": "private prompt"},
                   {"role": "assistant", "text": "private answer"}],
    "canvas": {"components": [{"type": "text", "content": "private result"}]},
}


@pytest.fixture
def smoke(request, monkeypatch, tmp_path, qapp):
    window = request.getfixturevalue("window_fixture")
    effective = resolve_effective_profile(
        bundled_profile_path=ROOT / "windows-client/deployment/release-profile.json",
        expected_client_version="0.5.2", environment={},
    )
    window._deployment_profile = effective
    window.deployment_profile_digest = effective.digest
    window._url = effective.profile.websocket_endpoint
    window.client.url = effective.profile.websocket_endpoint
    window._byo.deployment_profile_digest = effective.digest
    window.show()
    QApplication.processEvents()
    timers = []
    sent = []
    quits = []
    monkeypatch.setattr(appmod, "QTimer", SimpleNamespace(singleShot=lambda delay, callback: timers.append((delay, callback))))
    monkeypatch.setattr(window, "_send", lambda: sent.append(window._input.text()))
    monkeypatch.setattr(qapp, "quit", lambda: quits.append(True))
    report = tmp_path / "smoke.json"
    appmod._install_release_smoke(window, effective, report_path=str(report),
                                 prompt="private prompt", timeout_seconds=5)
    return SimpleNamespace(window=window, report=report, timers=timers, sent=sent, quits=quits)


def bootstrap(smoke, mode="valid"):
    menu = copy.deepcopy(MENU)
    presentation = copy.deepcopy(PRESENTATION)
    if mode == "invalid_model":
        menu["console"]["version"] = 1
    if mode == "invalid_presentation":
        presentation["minimum_control_height"] = float("nan")
    if mode == "legacy":
        menu.pop("console")
    if mode not in {"missing", "presentation_only"}:
        smoke.window._on_message({"type": "chrome_menu", "model": menu})
    if mode not in {"missing", "model_only", "legacy"}:
        smoke.window._on_message({"type": "rote_config", "device_profile": {"console": presentation}})
    QApplication.processEvents()


def finish(smoke, frame=None):
    smoke.window._release_smoke_probe[2](frame=copy.deepcopy(FRAME if frame is None else frame))
    return json.loads(smoke.report.read_text(encoding="utf-8"))


def test_current_visible_console_qualifies_and_report_remains_redacted(smoke):
    bootstrap(smoke)
    report = finish(smoke)
    assert report["status"] == "passed"
    assert report["detail_code"] == "rendered_turn_complete"
    assert all(report[key] is True for key in CHECKS)
    assert smoke.window._release_smoke_exit_code == 0
    assert smoke.quits == [True]
    encoded = smoke.report.read_text(encoding="utf-8")
    assert all(value not in encoded for value in (
        "private prompt", "private answer", "private result", "sandbox.ai.uky.edu",
        "iam.ai.uky.edu", MENU["console"]["identity"]["name"],
    ))


@pytest.mark.parametrize("mode", [
    "missing", "model_only", "presentation_only", "invalid_model",
    "invalid_presentation", "legacy",
])
def test_rendered_turn_cannot_qualify_missing_or_invalid_console(smoke, mode):
    bootstrap(smoke, mode)
    report = finish(smoke)
    assert report["status"] == "failed"
    assert report["detail_code"] == "console_bootstrap_incomplete"
    assert report["console_shell_current"] is False
    assert report["console_shell_visible"] is False
    assert report["transcript_turns"] == 2 and report["canvas_components"] == 1
    assert smoke.window._release_smoke_exit_code == 1


@pytest.mark.parametrize("mutation", [
    "hidden", "disabled", "detached", "stale_model", "stale_presentation",
    "topbar_visible", "split_visible", "invalidated_model",
])
def test_only_current_visible_console_without_legacy_chrome_qualifies(smoke, mutation):
    bootstrap(smoke)
    window = smoke.window
    shell = window._console_shell
    if mutation == "hidden":
        shell.hide()
    elif mutation == "disabled":
        shell.setEnabled(False)
    elif mutation == "detached":
        window._root_layout.removeWidget(shell)
    elif mutation == "stale_model":
        shell.model = copy.deepcopy(shell.model)
        shell.model["labels"]["title"] = "stale title"
    elif mutation == "stale_presentation":
        shell.presentation = {**shell.presentation, "settings_width": 1}
    elif mutation == "topbar_visible":
        window.topbar.show()
    elif mutation == "split_visible":
        window._legacy_split.show()
    else:
        window._console_model = {"version": 1}
    report = finish(smoke)
    assert report["detail_code"] == "console_bootstrap_incomplete"
    assert report["status"] == "failed"
    assert smoke.window._release_smoke_exit_code == 1


@pytest.mark.parametrize("criterion", ["transcript", "canvas", "window", "byo", "tools"])
def test_console_does_not_replace_existing_result_and_profile_requirements(smoke, criterion, monkeypatch):
    bootstrap(smoke)
    frame = copy.deepcopy(FRAME)
    if criterion == "transcript":
        frame["transcript"] = frame["transcript"][:1]
    elif criterion == "canvas":
        frame["canvas"]["components"] = []
    elif criterion == "window":
        smoke.window.client.url = "ws://127.0.0.1:1/ws"
    elif criterion == "byo":
        smoke.window._byo.deployment_profile_digest = "mismatch"
    else:
        from win_agent import agent
        monkeypatch.setattr(agent, "build_card", lambda _: {"metadata": {}})
    report = finish(smoke, frame)
    assert all(report[key] is True for key in CHECKS)
    assert report["status"] == "failed"
    assert report["detail_code"] == "incomplete_rendered_turn"
    assert smoke.window._release_smoke_exit_code == 1


def test_connected_commit_probe_sends_once_and_waits_for_commit(smoke):
    bootstrap(smoke)
    status, message, _finish = smoke.window._release_smoke_probe
    message(FRAME)
    assert len(smoke.timers) == 2
    status("connecting")
    status("connected")
    status("connected")
    assert smoke.sent == ["private prompt"]
    message({"type": "conversation_snapshot", "snapshot_purpose": "resume"})
    message({"type": "chat_status"})
    assert len(smoke.timers) == 2
    message(FRAME)
    delay, complete = smoke.timers[-1]
    assert delay == 0
    complete()
    assert json.loads(smoke.report.read_text())["status"] == "passed"
    _finish(error="smoke_timeout")
    assert smoke.quits == [True]


@pytest.mark.parametrize("already_connected", [False, True])
def test_connected_poll_and_timeout_are_bounded(smoke, already_connected):
    smoke.window._connected_once = already_connected
    smoke.timers[0][1]()
    assert smoke.sent == (["private prompt"] if already_connected else [])
    if not already_connected:
        assert smoke.timers[-1][0] == 100
    smoke.timers[1][1]()
    report = json.loads(smoke.report.read_text())
    assert report["status"] == "failed" and report["detail_code"] == "smoke_timeout"
    assert report["console_shell_visible"] is False
    smoke.timers[0][1]()
    assert smoke.quits == [True]
