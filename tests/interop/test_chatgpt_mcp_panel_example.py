"""Validates installed-wheel panel metadata, state and text fallback envelopes.
The loopback checks verify HTTP serving; the web suite separately executes the actual iframe lifecycle.
"""

from __future__ import annotations

import ast
import importlib.metadata
import shutil
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import threading
import zipfile
from pathlib import Path

import pytest
from packaging.requirements import Requirement

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
EXAMPLE_DIR = REPOSITORY_ROOT / "examples" / "chatgpt_mcp_panel"
EXAMPLE_PATH = EXAMPLE_DIR / "example.py"
ENVELOPES_PATH = EXAMPLE_DIR / "envelopes.py"
HOST_PATH = EXAMPLE_DIR / "synthetic_host.py"

_ALLOWED_IMPORT_ROOTS = {
    "__future__",
    "hashlib",
    "http",
    "json",
    "pathlib",
    "sys",
    "typing",
    "urllib",
    "astralprims",
    "astralprojection",
    "webrender",
    "envelopes",
}
_MCP_RESULT_KEYS = {"content", "isError", "structuredContent", "_meta"}
_MCP_TEXT_BLOCK_KEYS = {"type", "text", "annotations", "_meta"}
_SUMMARY_KEYS = {"isError", "contentText", "structuredState", "sha256"}
_PANEL_STATES = {"waiting", "running", "input_required", "failed", "cancelled", "succeeded"}
_METADATA_KEYS = {
    "openai/outputTemplate",
    "openai/toolInvocation/invoking",
    "openai/toolInvocation/invoked",
    "openai/widgetAccessible",
    "ui",
}


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _example_environment(home: Path) -> dict:
    return {
        "PATH": os.environ.get("PATH", os.defpath),
        "HOME": str(home),
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONHASHSEED": "0",
    }


def _run_example(home: Path, python: str) -> str:
    completed = subprocess.run(
        [python, "-I", str(EXAMPLE_PATH)],
        capture_output=True,
        text=True,
        check=True,
        cwd=str(home),
        env=_example_environment(home),
        timeout=120,
    )
    return completed.stdout


@pytest.fixture(scope="session")
def wheel_python(tmp_path_factory) -> str:
    workspace = tmp_path_factory.mktemp("panel-wheel")
    dist = workspace / "dist"
    dist.mkdir()
    build = subprocess.run(
        [
            sys.executable,
            "-m",
            "pip",
            "wheel",
            "--no-deps",
            "--no-build-isolation",
            "--no-index",
            "--wheel-dir",
            str(dist),
            str(REPOSITORY_ROOT),
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=600,
        cwd=str(workspace),
    )
    assert "Successfully built astralprojection" in build.stdout
    wheels = list(dist.glob("astralprojection-*.whl"))
    assert len(wheels) == 1
    with zipfile.ZipFile(wheels[0]) as archive:
        names = archive.namelist()
        assert any(name == "webrender/targets/chatgpt_panel.py" for name in names)
    venv_dir = workspace / "venv"
    subprocess.run(
        [sys.executable, "-m", "venv", "--without-pip", "--system-site-packages", str(venv_dir)],
        check=True,
        capture_output=True,
        timeout=300,
    )
    python = venv_dir / "Scripts" / "python.exe" if os.name == "nt" else venv_dir / "bin" / "python"
    assert python.is_file()
    site_packages = json.loads(
        subprocess.run(
            [str(python), "-I", "-c", "import json,sysconfig;print(json.dumps(sysconfig.get_paths()['purelib']))"],
            capture_output=True,
            text=True,
            check=True,
            timeout=60,
        ).stdout
    )
    with zipfile.ZipFile(wheels[0]) as archive:
        archive.extractall(site_packages)
    pending = ["astralprims"]
    copied: set[str] = set()
    while pending:
        name = pending.pop()
        if name in copied:
            continue
        dependency = importlib.metadata.distribution(name)
        copied.add(name)
        for requirement in dependency.requires or []:
            parsed = Requirement(requirement)
            if parsed.marker is None or parsed.marker.evaluate({"extra": ""}):
                pending.append(parsed.name)
        for member in dependency.files or []:
            if ".." in member.parts:
                continue
            source = dependency.locate_file(member)
            destination = Path(site_packages) / member
            if source.is_file():
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
    probe = subprocess.run(
        [str(python), "-I", "-c", "import astralprojection, webrender.targets.chatgpt_panel;print(astralprojection.__file__)"],
        capture_output=True,
        text=True,
        check=True,
        timeout=60,
        cwd=str(workspace),
    )
    installed = probe.stdout.strip()
    assert installed.startswith(str(venv_dir))
    assert str(REPOSITORY_ROOT) not in installed
    return str(python)


@pytest.fixture(scope="module")
def example_outputs(tmp_path_factory, wheel_python) -> list[str]:
    home = tmp_path_factory.mktemp("panel-example-home")
    return [_run_example(home, wheel_python), _run_example(home, wheel_python)]


def _assert_call_tool_result(envelope: dict) -> None:
    assert isinstance(envelope, dict)
    assert set(envelope) <= _MCP_RESULT_KEYS
    assert isinstance(envelope["content"], list) and envelope["content"]
    for block in envelope["content"]:
        assert isinstance(block, dict)
        assert block.get("type") == "text"
        assert isinstance(block.get("text"), str)
        assert set(block) <= _MCP_TEXT_BLOCK_KEYS
    assert isinstance(envelope["isError"], bool)


def _assert_summary(summary: dict, *, exact: bool = True) -> None:
    if exact:
        assert set(summary) == _SUMMARY_KEYS
    else:
        assert _SUMMARY_KEYS <= set(summary)
    assert isinstance(summary["isError"], bool)
    assert isinstance(summary["contentText"], str) and summary["contentText"]
    assert re.fullmatch(r"[0-9a-f]{64}", summary["sha256"])


def _import_roots(path: Path) -> set[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"))
    roots: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            roots.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            roots.add(node.module.split(".")[0])
    return roots


def test_example_imports_only_the_installed_wheel_surface() -> None:
    roots = _import_roots(EXAMPLE_PATH) | _import_roots(ENVELOPES_PATH) | _import_roots(HOST_PATH)
    assert roots <= _ALLOWED_IMPORT_ROOTS
    assert "astraldeep" not in roots


def test_example_is_byte_identical_across_clean_runs(example_outputs) -> None:
    assert example_outputs[0] == example_outputs[1]


def test_example_pins_and_panel_resource_match_the_declared_target(example_outputs) -> None:
    document = json.loads(example_outputs[0])
    assert document["pins"]["mcpAppsSdk"] == "@modelcontextprotocol/ext-apps==2.0.4"
    assert document["pins"]["mcpAppsProtocolRevision"] == "2026-01-26"
    assert document["pins"]["mcpAppsSpecCommit"] == "7af9a75da720b8a81be0f9aff47b25f75e9530ad"
    assert document["pins"]["mcpSchemaRevision"] == "2025-11-25"
    assert document["pins"]["astralprojection"] == "astralprojection==0.1.0"
    assert document["pins"]["contractVersion"] == "astralprojection.contract/v1"
    assert re.fullmatch(r"[0-9a-f]{64}", document["pins"]["uiProtocolSha256"])
    assert document["toolName"] == "astral_work_status"
    assert document["panelResource"]["uri"] == "ui://astralprojection/astral-work-status"
    assert document["panelResource"]["mimeType"] == "text/html;profile=mcp-app"
    template = document["toolDescriptor"]["_meta"]["openai/outputTemplate"]
    assert template == document["panelResource"]["uri"]
    assert document["toolDescriptor"]["_meta"]["ui"]["resourceUri"] == template
    assert set(document["toolDescriptor"]["_meta"]) == _METADATA_KEYS
    assert document["toolDescriptor"]["_meta"]["openai/widgetAccessible"] is False
    read_result = document["resourcesReadResult"]
    assert read_result["uri"] == document["panelResource"]["uri"]
    assert read_result["textSha256"] == document["panelResource"]["sha256"]
    assert re.fullmatch(r"[0-9a-f]{64}", document["panelResource"]["sha256"])
    assert document["panelResource"]["bytes"] > 0


def test_example_covers_every_state_truthfully(example_outputs) -> None:
    document = json.loads(example_outputs[0])
    states = {scenario["structuredState"] for scenario in document["stateScenarios"]}
    assert states == _PANEL_STATES
    for scenario in document["stateScenarios"]:
        summary = scenario["envelope"]
        _assert_summary(summary)
        assert summary["isError"] is False
        assert summary["structuredState"] == scenario["structuredState"]
        assert "State: " in scenario["contentText"]
        if scenario["structuredState"] == "succeeded":
            assert scenario["artifactCount"] == 2
            assert "Evidence pack" in scenario["contentText"]
        if scenario["structuredState"] == "running":
            assert "Progress: 3 of 5" in scenario["contentText"]
    assert document["authorizedInputs"] == {
        "inputRequiredMessageSource": "alert",
        "failedDetailSource": "text",
    }


def test_example_denials_recovery_fallback_and_transport_rejection(example_outputs) -> None:
    document = json.loads(example_outputs[0])
    denials = document["denialScenarios"]
    assert [case["case"] for case in denials] == [
        "host_policy_denial",
        "unauthorized_view_model_rejected",
    ]
    for case in denials:
        _assert_summary(case, exact=False)
        assert case["isError"] is True
        assert case["panelEmitted"] is False
        assert case["structuredState"] is None
    assert [step["structuredState"] for step in document["recoverySequence"]] == [
        "failed",
        "running",
        "succeeded",
    ]
    assert len({step["resourceUri"] for step in document["recoverySequence"]}) == 1
    fallback = document["fallbackScenario"]
    assert fallback["hostHasPanelSupport"] is False
    assert fallback["contentBlocks"] >= 1
    assert "State: Completed" in fallback["usableText"]
    assert "Evidence pack" in fallback["usableText"]
    rejection = document["transportStateRejection"]
    assert "unsupported keys" in rejection["error"]
    assert "content" in rejection["error"]


def test_example_build_report_in_process_matches_the_wheel_run(
    tmp_path, wheel_python, example_outputs
) -> None:
    home = tmp_path / "inproc-home"
    home.mkdir()
    module = _load_module("chatgpt_panel_example_inproc", EXAMPLE_PATH)
    rendered = json.dumps(module.build_report(), indent=2, sort_keys=True) + "\n"
    assert rendered == example_outputs[0]


def test_example_main_prints_the_report(tmp_path, wheel_python, example_outputs, capsys) -> None:
    module = _load_module("chatgpt_panel_example_main", EXAMPLE_PATH)
    module.main()
    assert capsys.readouterr().out == example_outputs[0]


def test_example_runs_from_the_freshly_built_installed_wheel(
    tmp_path, wheel_python, example_outputs
) -> None:
    home = tmp_path / "fresh-home"
    home.mkdir()
    first = _run_example(home, wheel_python)
    second = _run_example(home, wheel_python)
    assert first == second
    assert first == example_outputs[0]
    document = json.loads(first)
    assert set(document["panelResource"]) == {"uri", "mimeType", "title", "bytes", "sha256"}
    succeeded = next(
        scenario["envelope"]
        for scenario in document["stateScenarios"]
        if scenario["structuredState"] == "succeeded"
    )
    _assert_summary(succeeded)


def test_loopback_http_serves_panel_envelopes(tmp_path, wheel_python) -> None:
    home = tmp_path / "host-home"
    home.mkdir()
    example = json.loads(_run_example(home, wheel_python))
    host = _load_module("chatgpt_panel_synthetic_host", HOST_PATH)
    works = dict(
        _load_module("chatgpt_panel_example", EXAMPLE_PATH).AUTHORIZED_WORKS
    )
    server = host.build_server(works)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        base_url = f"http://127.0.0.1:{server.server_address[1]}"
        summary = host.exercise(base_url, "work-succeeded")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=10)
    assert summary["toolName"] == "astral_work_status"
    assert summary["outputTemplateUri"] == example["panelResource"]["uri"]
    assert summary["outputTemplateMime"] == "text/html;profile=mcp-app"
    assert summary["resourceMatchesPanelDocument"] is True
    assert summary["panelCsp"] == host.PANEL_CSP
    assert "default-src 'none'" in summary["panelCsp"]
    assert "connect-src 'none'" in summary["panelCsp"]
    assert summary["embedSandboxed"] is True
    assert summary["toolIsError"] is False
    assert summary["toolStructuredState"] == "succeeded"
    assert summary["toolContentBlocks"] >= 1
    assert summary["fallbackHasNoStructuredContent"] is True
    assert summary["fallbackContentMatchesToolContent"] is True
    assert summary["fallbackTextStartsWith"] == "Astral Work status: Quarterly compliance review"
    assert summary["denialIsError"] is True
    assert summary["denialHasNoPanel"] is True
    assert summary["missingResourceErrorCode"] == -32002
    assert summary["unknownPathErrorCode"] == -32601


def test_synthetic_host_denies_unknown_work_items() -> None:
    host = _load_module("chatgpt_panel_synthetic_host_denial", HOST_PATH)
    server = host.build_server({})
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        base_url = f"http://127.0.0.1:{server.server_address[1]}"
        body, _ = host._fetch(base_url, "/tool/astral_work_status?work_id=missing")
        denial = json.loads(body)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=10)
    assert denial["isError"] is True
    assert "host policy denied" in denial["content"][0]["text"]


def test_panel_document_digest_is_pinned_in_the_example_report(example_outputs) -> None:
    document = json.loads(example_outputs[0])
    from webrender.targets.chatgpt_panel import panel_document

    digest = hashlib.sha256(panel_document().encode("utf-8")).hexdigest()
    assert document["panelResource"]["sha256"] == digest
