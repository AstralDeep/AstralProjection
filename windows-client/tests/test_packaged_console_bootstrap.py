"""Qualifies console bootstrap through a bounded loopback WebSocket fixture and real entrypoints.
These synthetic transport checks establish packaged rendering behavior, not live authentication acceptance.
"""

import asyncio
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

import pytest
from websockets.asyncio.server import serve

from astral_client.settings import create_settings
from test_packaged_release import _candidate_exe, _clean_env


ROOT = Path(__file__).resolve().parents[2]
MENU = json.loads((ROOT / "contracts/fixtures/console/chrome-console.json").read_text(encoding="utf-8"))
PRESENTATION = json.loads((ROOT / "contracts/fixtures/console/rote-console.json").read_text(encoding="utf-8"))["cases"][5]["presentation"]
TOKEN = "synthetic-loopback-console-test"
PROMPT = "Synthetic console fixture request"


def snapshot(request, connection):
    timestamp = "2026-07-15T18:41:00Z"
    return {
        "type": "conversation_snapshot", "schema_version": 1,
        "snapshot_id": str(uuid.uuid4()), "chat_id": str(uuid.uuid4()),
        "connection_generation": connection,
        "request_generation": request["payload"]["request_generation"],
        "snapshot_purpose": "commit", "render_revision": 1, "committed_at": timestamp,
        "transcript": [
            {"message_id": str(index), "role": role, "created_at": timestamp,
             "parts": [{"type": "text", "text": text}], "attachments": []}
            for index, role, text in ((1, "user", PROMPT), (2, "assistant", "Synthetic result"))
        ],
        "canvas": {"target": "canvas", "components": [{"type": "text", "content": "Synthetic result"}]},
    }


async def run_fixture(command, tmp_path, mode, selection):
    observations = {"registered_console": False, "prompt_received": False}
    failures = []

    async def session(socket):
        try:
            registration = json.loads(await asyncio.wait_for(socket.recv(), 15))
            assert registration["type"] == "register_ui"
            assert registration["token"] == TOKEN
            observations["registered_console"] = registration["device"]["console_contract"] == "console/v2"
            menu = copy.deepcopy(MENU)
            presentation = copy.deepcopy(PRESENTATION)
            if mode == "invalid":
                menu["console"]["version"] = 1
            if mode == "legacy":
                menu.pop("console")
            device = {"console": presentation} if mode not in {"legacy", "model_only", "missing"} else {}
            await socket.send(json.dumps({"type": "rote_config", "device_profile": device}))
            if mode not in {"presentation_only", "missing"}:
                await socket.send(json.dumps({"type": "chrome_menu", "model": menu}))
            async with asyncio.timeout(15):
                async for raw in socket:
                    request = json.loads(raw)
                    if request.get("action") == "chat_message":
                        assert request["payload"]["message"] == PROMPT
                        observations["prompt_received"] = True
                        await socket.send(json.dumps(snapshot(request, registration["connection_generation"])))
                        await socket.wait_closed()
                        break
        except Exception as exc:
            failures.append(type(exc).__name__)
            await socket.close()

    async with serve(session, "127.0.0.1", 0, max_size=1024 * 1024, close_timeout=1) as server:
        port = server.sockets[0].getsockname()[1]
        profile_path = tmp_path / "fixture-profile.json"
        profile = json.loads((ROOT / "windows-client/deployment/local-backend-profile.json").read_text())
        profile["websocket_endpoint"] = f"ws://127.0.0.1:{port}/ws"
        profile_path.write_text(json.dumps(profile), encoding="utf-8")
        environment = _clean_env(tmp_path)
        if selection == "persisted":
            settings = create_settings(environment)
            settings.setValue("deployment/profile_json", json.dumps(profile))
            settings.sync()
            assert settings.status() == settings.Status.NoError
            profile_arguments = []
        else:
            profile_arguments = ["--deployment-profile", str(profile_path)]
        for name in ("GITHUB_TOKEN", "ASTRAL_WORKSPACE_DIR", "GH_TOKEN"):
            environment.pop(name, None)
        environment.update({
            "QT_QPA_PLATFORM": "offscreen", "ASTRAL_TOKEN": TOKEN,
            "HTTP_PROXY": "http://127.0.0.1:1", "HTTPS_PROXY": "http://127.0.0.1:1",
            "ALL_PROXY": "http://127.0.0.1:1", "NO_PROXY": "127.0.0.1,localhost",
        })
        report = tmp_path / "console-smoke.json"
        process = await asyncio.create_subprocess_exec(
            *command, *profile_arguments, "--release-smoke-report", str(report),
            "--release-smoke-prompt", PROMPT, "--release-smoke-timeout", "10",
            cwd=ROOT / "windows-client", env=environment,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), 20)
        except TimeoutError:
            process.kill()
            await process.communicate()
            raise
    assert not failures, failures
    assert observations == {"registered_console": True, "prompt_received": True}
    assert report.is_file(), (stdout.decode(errors="replace"), stderr.decode(errors="replace"))
    return process.returncode, json.loads(report.read_text(encoding="utf-8"))


@pytest.mark.parametrize("entrypoint,mode,selection", [
    *(("source", mode, "command_line") for mode in ("valid", "legacy", "missing", "model_only", "presentation_only", "invalid")),
    ("source", "valid", "persisted"), ("source", "legacy", "persisted"),
    *(("frozen", mode, selection) for mode in ("valid", "legacy") for selection in ("command_line", "persisted")),
])
def test_connected_console_qualification_over_fixture_transport(tmp_path, entrypoint, mode, selection):
    if selection == "persisted" and os.name != "nt":
        pytest.skip("native persisted deployment profiles use the Windows registry")
    command = [str(_candidate_exe())] if entrypoint == "frozen" else [sys.executable, str(ROOT / "windows-client/main.py")]
    exit_code, report = asyncio.run(run_fixture(command, tmp_path, mode, selection))
    expected = mode == "valid"
    assert exit_code == (0 if expected else 1)
    assert report["status"] == ("passed" if expected else "failed")
    assert report["detail_code"] == ("rendered_turn_complete" if expected else "console_bootstrap_incomplete")
    assert report["console_shell_current"] is expected
    assert report["console_shell_visible"] is expected
    assert report["source"] == f"{selection}_override"
    assert report["distribution"] == "local_backend"
    assert report["transcript_turns"] == 2 and report["canvas_components"] == 1
    assert all(report[key] is True for key in ("window_profile_match", "byo_profile_match", "tools_agent_profile_match"))
    if expected:
        assert all(report[key] is True for key in ("console_model_valid", "console_presentation_valid", "legacy_topbar_hidden", "legacy_split_hidden"))
    assert TOKEN not in json.dumps(report) and PROMPT not in json.dumps(report)
