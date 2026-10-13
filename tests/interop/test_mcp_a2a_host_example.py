"""Interop tests for examples/mcp_a2a_host: they pin the official MCP and A2A revisions
of the host-side envelope mapping, validate every generated envelope against the pinned
schema shapes, and run the wheel-only example deterministically in sanitized and
freshly-installed-wheel environments.
"""

from __future__ import annotations

import ast
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
EXAMPLE_DIR = REPOSITORY_ROOT / "examples" / "mcp_a2a_host"
EXAMPLE_PATH = EXAMPLE_DIR / "example.py"
ENVELOPES_PATH = EXAMPLE_DIR / "envelopes.py"

_ALLOWED_IMPORT_ROOTS = {
    "__future__",
    "hashlib",
    "json",
    "pathlib",
    "re",
    "sys",
    "typing",
    "astralprims",
    "astralprojection",
    "rote",
    "webrender",
    "envelopes",
}
_MCP_RESULT_KEYS = {"content", "isError", "resultType", "structuredContent", "_meta"}
_MCP_TEXT_BLOCK_KEYS = {"type", "text", "annotations", "_meta"}
_A2A_PART_CONTENT_FIELDS = {"text", "raw", "url", "data"}
_A2A_PART_OPTIONAL_FIELDS = {"mediaType", "metadata", "filename"}
_A2A_ARTIFACT_KEYS = {"artifactId", "name", "description", "parts", "metadata", "extensions"}
_CANONICAL_A2A_TASK_STATES = frozenset(
    {
        "TASK_STATE_UNSPECIFIED",
        "TASK_STATE_SUBMITTED",
        "TASK_STATE_WORKING",
        "TASK_STATE_COMPLETED",
        "TASK_STATE_FAILED",
        "TASK_STATE_CANCELED",
        "TASK_STATE_INPUT_REQUIRED",
        "TASK_STATE_REJECTED",
        "TASK_STATE_AUTH_REQUIRED",
    }
)


def _load_envelopes():
    spec = importlib.util.spec_from_file_location("mcp_a2a_host_envelopes", ENVELOPES_PATH)
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


def _run_example(home: Path, python: None | str = None) -> str:
    completed = subprocess.run(
        [python or sys.executable, "-I", str(EXAMPLE_PATH)],
        capture_output=True,
        text=True,
        check=True,
        cwd=str(home),
        env=_example_environment(home),
        timeout=120,
    )
    return completed.stdout


@pytest.fixture(scope="module")
def example_outputs(tmp_path_factory) -> list[str]:
    home = tmp_path_factory.mktemp("example-home")
    return [_run_example(home), _run_example(home)]


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
    assert envelope["resultType"] == "complete"


def _assert_a2a_part(part: dict) -> None:
    assert isinstance(part, dict)
    assert len(_A2A_PART_CONTENT_FIELDS & set(part)) == 1, part
    assert set(part) <= _A2A_PART_CONTENT_FIELDS | _A2A_PART_OPTIONAL_FIELDS


def _assert_a2a_artifact(artifact: dict) -> None:
    assert isinstance(artifact, dict)
    assert set(artifact) <= _A2A_ARTIFACT_KEYS
    assert isinstance(artifact["artifactId"], str) and artifact["artifactId"]
    assert isinstance(artifact["name"], str) and artifact["name"]
    assert isinstance(artifact["parts"], list)
    for part in artifact["parts"]:
        _assert_a2a_part(part)


def _assert_a2a_task(task: dict) -> None:
    assert set(task) == {"id", "contextId", "status"}
    assert set(task["status"]) == {"state"}
    assert task["status"]["state"] in _CANONICAL_A2A_TASK_STATES


def _import_roots(path: Path) -> set[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"))
    roots: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            roots.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            roots.add(node.module.split(".")[0])
    return roots


def test_envelope_module_pins_official_revisions() -> None:
    envelopes = _load_envelopes()
    assert envelopes.MCP_SDK_PIN == "mcp==2.3.0"
    assert envelopes.MCP_SCHEMA_REVISION == "2026-07-28"
    assert envelopes.A2A_SDK_PIN == "a2a-sdk==1.2.2"
    assert envelopes.A2A_PROTOCOL_REVISION == "1.0"
    assert envelopes.ASTRALPROJECTION_PIN == "astralprojection==0.1.0"
    assert envelopes.CONTRACT_VERSION == "astralprojection.contract/v1"


def test_mcp_envelope_builder_matches_pinned_call_tool_result_shape() -> None:
    envelopes = _load_envelopes()
    success = envelopes.build_mcp_call_tool_result(
        content_blocks=[{"type": "text", "text": "hello"}],
        html_text="<p>hi</p>",
    )
    _assert_call_tool_result(success)
    assert success["isError"] is False
    assert [block["text"] for block in success["content"]] == ["hello", "<p>hi</p>"]
    empty = envelopes.build_mcp_call_tool_result()
    _assert_call_tool_result(empty)
    assert empty["content"][0]["text"] == "(no renderable content)"
    failure = envelopes.build_mcp_call_tool_result(error=ValueError("boom"))
    _assert_call_tool_result(failure)
    assert failure["isError"] is True
    assert "boom" in failure["content"][0]["text"]


def test_a2a_artifact_builder_matches_pinned_lf_a2a_v1_shape() -> None:
    envelopes = _load_envelopes()
    artifact = envelopes.build_a2a_artifact(
        artifact_id="a-1",
        name="render",
        data={"component": "value"},
        html_text="<p>x</p>",
    )
    _assert_a2a_artifact(artifact)
    assert artifact["parts"][0]["data"] == {"component": "value"}
    assert artifact["parts"][1] == {"text": "<p>x</p>", "mediaType": "text/html"}
    oversized = envelopes.build_a2a_artifact(
        artifact_id="a-2",
        name="bulk",
        data={"content": "x" * 25000},
    )
    _assert_a2a_artifact(oversized)
    summary = oversized["parts"][0]["data"]
    assert summary["truncated"] is True
    assert re.fullmatch(r"[0-9a-f]{16}", summary["sha256Prefix"])
    failure = envelopes.build_a2a_artifact(artifact_id="a-3", name="err", error=ValueError("bad"))
    _assert_a2a_artifact(failure)
    assert "bad" in failure["parts"][0]["text"]


def test_a2a_task_states_are_the_canonical_lf_a2a_v1_set() -> None:
    envelopes = _load_envelopes()
    assert envelopes.A2A_TASK_STATES == _CANONICAL_A2A_TASK_STATES
    task = envelopes.a2a_task_envelope(
        task_id="t-1", context_id="c-1", state="TASK_STATE_WORKING"
    )
    _assert_a2a_task(task)
    with pytest.raises(ValueError):
        envelopes.a2a_task_envelope(task_id="t-1", context_id="c-1", state="WORKING")


def test_redaction_covers_secret_keys_values_and_structure() -> None:
    envelopes = _load_envelopes()
    redacted = envelopes.redact(
        {
            "session_token": "raw-value",
            "nested": {"api_key": "k", "note": "starts eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJl"},
            "items": ["plain", "sk-" + "a" * 20],
        }
    )
    assert redacted["session_token"] == envelopes.REDACTED
    assert redacted["nested"]["api_key"] == envelopes.REDACTED
    assert redacted["nested"]["note"] == "starts " + envelopes.REDACTED
    assert redacted["items"][1] == envelopes.REDACTED
    assert redacted["items"][0] == "plain"
    deep: object = "bottom"
    for _ in range(envelopes.MAX_STRUCTURE_DEPTH + 2):
        deep = {"child": deep}
    truncated = envelopes.redact(deep)
    while isinstance(truncated, dict):
        truncated = truncated["child"]
    assert truncated == "[TRUNCATED_DEPTH]"
    assert len(envelopes.redact([0] * 300)) == envelopes.MAX_LIST_ITEMS


def test_bounding_is_deterministic_and_marked() -> None:
    envelopes = _load_envelopes()
    text = "x" * 25000
    first, first_flag = envelopes.bound_text(text)
    second, second_flag = envelopes.bound_text(text)
    assert first == second and first_flag is second_flag is True
    digest = re.search(r"sha256:([0-9a-f]{16}), 25000 chars\]", first)
    assert digest and digest.group(1) == hashlib.sha256(text.encode()).hexdigest()[:16]
    assert envelopes.bound_text("short") == ("short", False)


def test_error_mapping_covers_denials_missing_input_and_failures() -> None:
    envelopes = _load_envelopes()
    assert envelopes.map_exception_to_state(PermissionError("denied")) == "TASK_STATE_REJECTED"
    assert envelopes.map_exception_to_state(KeyError("field")) == "TASK_STATE_INPUT_REQUIRED"
    assert envelopes.map_exception_to_state(ValueError("bad")) == "TASK_STATE_FAILED"
    assert envelopes.map_exception_to_state(FileNotFoundError("gone")) == "TASK_STATE_FAILED"


def test_example_imports_only_the_installed_wheel_surface() -> None:
    roots = _import_roots(EXAMPLE_PATH) | _import_roots(ENVELOPES_PATH)
    assert roots <= _ALLOWED_IMPORT_ROOTS
    assert "astraldeep" not in roots


def test_example_is_byte_identical_across_clean_runs(example_outputs) -> None:
    assert example_outputs[0] == example_outputs[1]


def test_example_envelopes_match_the_pinned_schema_shapes(example_outputs) -> None:
    envelopes = _load_envelopes()
    document = json.loads(example_outputs[0])
    _assert_call_tool_result(document["mcpCallToolResult"])
    _assert_a2a_artifact(document["a2aArtifact"])
    _assert_a2a_task(document["a2aTask"])
    for case in document["errorMapping"]:
        _assert_call_tool_result(case["mcpCallToolResult"])
        assert case["a2aTaskState"] in envelopes.A2A_TASK_STATES


def test_example_output_shows_adaptation_fallback_redaction_and_bounding(example_outputs) -> None:
    document = json.loads(example_outputs[0])
    assert document["pins"]["mcpSchemaRevision"] == "2026-07-28"
    assert document["pins"]["a2aProtocolRevision"] == "1.0"
    assert re.fullmatch(r"[0-9a-f]{64}", document["pins"]["uiProtocolSha256"])
    assert document["adaptation"]["deviceType"] == "watch"
    assert document["adaptation"]["inputTypes"] == [
        "alert",
        "metric",
        "bar_chart",
        "table",
        "text",
        "text",
        "timeline_widget",
    ]
    assert document["adaptation"]["adaptedTypes"] == [
        "alert",
        "metric",
        "metric",
        "list",
        "text",
        "text",
        "timeline_widget",
    ]
    blocks = document["mcpCallToolResult"]["content"]
    assert any("timeline_widget" in block["text"] for block in blocks)
    assert any("[REDACTED]" in block["text"] for block in blocks)
    assert "eyJhbGciOiJIUzI1NiJ9" not in example_outputs[0]
    assert any("event-0001" in block["text"] and len(block["text"]) <= 200 for block in blocks)
    bounding = document["hostBounding"]
    assert bounding["mcpBounded"] is True
    assert "[BOUNDED:" in bounding["mcpTail"]
    assert bounding["a2aDataSummary"]["truncated"] is True
    assert bounding["a2aDataSummary"]["chars"] > 20000
    assert [case["a2aTaskState"] for case in document["errorMapping"]] == [
        "TASK_STATE_FAILED",
        "TASK_STATE_INPUT_REQUIRED",
        "TASK_STATE_REJECTED",
    ]
    assert document["a2aTask"]["status"]["state"] == "TASK_STATE_COMPLETED"


def test_example_runs_from_a_freshly_built_installed_wheel(tmp_path) -> None:
    dist = tmp_path / "dist"
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
        cwd=str(tmp_path),
    )
    assert "Successfully built astralprojection" in build.stdout
    wheels = list(dist.glob("astralprojection-*.whl"))
    assert len(wheels) == 1
    venv_dir = tmp_path / "venv"
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
    probe = subprocess.run(
        [str(python), "-I", "-c", "import astralprojection;print(astralprojection.__file__)"],
        capture_output=True,
        text=True,
        check=True,
        timeout=60,
        cwd=str(tmp_path),
    )
    installed = probe.stdout.strip()
    assert installed.startswith(str(venv_dir))
    assert str(REPOSITORY_ROOT) not in installed
    first = _run_example(tmp_path, python=str(python))
    second = _run_example(tmp_path, python=str(python))
    assert first == second
    document = json.loads(first)
    _assert_call_tool_result(document["mcpCallToolResult"])
    _assert_a2a_artifact(document["a2aArtifact"])
    _assert_a2a_task(document["a2aTask"])


def test_official_mcp_sdk_validates_example_envelope(example_outputs) -> None:
    mcp_types = pytest.importorskip("mcp.types")
    document = json.loads(example_outputs[0])
    result = mcp_types.CallToolResult.model_validate(document["mcpCallToolResult"])
    assert result.is_error is False
    assert result.result_type == "complete"
    assert all(block.type == "text" for block in result.content)
    failure = mcp_types.CallToolResult.model_validate(document["errorMapping"][0]["mcpCallToolResult"])
    assert failure.is_error is True


def test_official_a2a_sdk_validates_example_artifact_and_task(example_outputs) -> None:
    a2a_types = pytest.importorskip("a2a.types")
    json_format = pytest.importorskip("google.protobuf.json_format")
    document = json.loads(example_outputs[0])
    artifact = json_format.ParseDict(document["a2aArtifact"], a2a_types.Artifact())
    assert artifact.artifact_id == "ap-08-artifact-1"
    assert artifact.name == "projection-render"
    assert artifact.parts[0].WhichOneof("content") == "data"
    assert artifact.parts[1].media_type == "text/html"
    task = json_format.ParseDict(document["a2aTask"], a2a_types.Task())
    assert task.status.state == a2a_types.TaskState.TASK_STATE_COMPLETED
    sdk_states = {value.name for value in a2a_types.TaskState.DESCRIPTOR.values}
    assert sdk_states == _CANONICAL_A2A_TASK_STATES
    with pytest.raises(json_format.ParseError):
        json_format.ParseDict(
            {**document["a2aTask"], "status": {"state": "NOT_A_STATE"}}, a2a_types.Task()
        )
    with pytest.raises(json_format.ParseError):
        json_format.ParseDict(
            {"artifactId": "x", "name": "n", "parts": [{"text": "a", "data": {"b": 1}}]},
            a2a_types.Artifact(),
        )
