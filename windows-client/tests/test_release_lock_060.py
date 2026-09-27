"""Tests for the Windows/Python 3.11 release-lock tooling: exact hashed lock
completeness, manifest-to-lock binding, candidate-manifest identity/drift validation,
environment-set comparison, and the lock CLI's command dispatch.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sys
from types import SimpleNamespace

import pytest


ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "requirements-release.lock.txt"
INPUT = ROOT / "requirements.in"
MANIFEST = ROOT / "deployment" / "runtime-manifest.json"
SPEC = ROOT / "AstralDeep.spec"
TOOL = ROOT.parent / "scripts" / "windows_release_candidate.py"


def _tool_module():
    spec = importlib.util.spec_from_file_location("windows_release_candidate", TOOL)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _locked_packages() -> dict[str, str]:
    packages = {}
    for line in LOCK.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^([a-z0-9][a-z0-9._-]*)==([^ ;\\]+)", line)
        if match:
            packages[match.group(1).replace("_", "-").lower()] = match.group(2)
        direct = re.match(
            r"^lets-agent @ https://github\.com/AstralDeep/LETS/releases/download/"
            r"v([0-9]+\.[0-9]+\.[0-9]+)/lets_agent-"
            r"([0-9]+\.[0-9]+\.[0-9]+)-py3-none-any\.whl",
            line,
        )
        if direct:
            assert direct.group(1) == direct.group(2)
            packages["lets-agent"] = direct.group(2)
    return packages


def _freeze_tool(tmp_path):
    spec = importlib.util.spec_from_file_location(
        "astral_client.freeze_environment", ROOT / "astral_client" / "freeze_environment.py"
    )
    tool = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(tool)
    executable = tmp_path / "release" / "Scripts" / "python.exe"
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"interpreter fixture")
    base = tmp_path / "python"
    base.mkdir()
    system = tmp_path / "Windows" / "System32"
    system.mkdir(parents=True)
    tool.sys = SimpleNamespace(
        platform="win32", executable=str(executable), base_prefix=str(base)
    )
    return tool, system.parent


def test_freeze_environment_ignores_ambient_search_paths_without_mutating_input(tmp_path):
    tool, windows = _freeze_tool(tmp_path)
    environment = {
        "SystemRoot": str(windows),
        "PATH": "unrelated-native-tools",
        "Path": "another-native-tool",
        "PYTHONPATH": "unrelated-python",
        "PythonHome": "other-python-installation",
        "TEMP": str(tmp_path),
    }
    original = dict(environment)
    clean = tool.freeze_environment(environment)
    assert environment == original
    assert clean == {
        "SystemRoot": str(windows),
        "TEMP": str(tmp_path),
        "PATH": os.pathsep.join(
            str(path.resolve())
            for path in (
                Path(tool.sys.executable).parent,
                Path(tool.sys.base_prefix),
                windows / "System32",
                windows,
            )
        ),
    }


def test_freeze_environment_reads_process_environment_and_deduplicates(tmp_path, monkeypatch):
    tool, windows = _freeze_tool(tmp_path)
    tool.sys.base_prefix = str(Path(tool.sys.executable).parent)
    monkeypatch.setattr(tool.os, "environ", {"SYSTEMROOT": str(windows), "PATH": "tainted"})
    clean = tool.freeze_environment()
    assert len(clean["PATH"].split(os.pathsep)) == 3
    assert "tainted" not in clean["PATH"]


def test_freeze_environment_rejects_non_windows_host(tmp_path):
    tool, windows = _freeze_tool(tmp_path)
    tool.sys.platform = "linux"
    with pytest.raises(tool.FreezeEnvironmentError, match="Windows interpreter"):
        tool.freeze_environment({"SystemRoot": str(windows)})


@pytest.mark.parametrize("windows_root", [None, "", "relative-windows"])
def test_freeze_environment_rejects_missing_or_relative_system_root(tmp_path, windows_root):
    tool, _windows = _freeze_tool(tmp_path)
    environment = {} if windows_root is None else {"SystemRoot": windows_root}
    with pytest.raises(tool.FreezeEnvironmentError, match="absolute SystemRoot"):
        tool.freeze_environment(environment)


@pytest.mark.parametrize(
    "invalid", ["relative-executable", "missing-executable", "missing-base", "relative-base", "missing-system32"]
)
def test_freeze_environment_rejects_invalid_required_directories(tmp_path, invalid):
    tool, windows = _freeze_tool(tmp_path)
    if invalid == "relative-executable":
        tool.sys.executable = "python.exe"
    elif invalid == "missing-executable":
        tool.sys.executable = str(tmp_path / "absent-python.exe")
    elif invalid == "missing-base":
        tool.sys.base_prefix = str(tmp_path / "absent-base")
    elif invalid == "relative-base":
        tool.sys.base_prefix = "relative-base"
    else:
        (windows / "System32").rmdir()
    with pytest.raises(tool.FreezeEnvironmentError, match="existing interpreter and system directories"):
        tool.freeze_environment({"SystemRoot": str(windows)})


@pytest.mark.skipif(sys.platform != "win32", reason="PyInstaller Windows PE resolver")
def test_freeze_environment_prevents_ambient_dll_resolution(tmp_path, monkeypatch):
    from PyInstaller.depend.bindepend import resolve_library_path

    tool, windows = _freeze_tool(tmp_path)
    source = Path(os.environ["SystemRoot"]) / "System32" / "kernel32.dll"
    tainted = tmp_path / "unrelated-tool"
    tainted.mkdir()
    name = "astral-freeze-probe.dll"
    shutil.copyfile(source, tainted / name)
    system_library = windows / "System32" / name
    shutil.copyfile(source, system_library)
    environment = {"SystemRoot": str(windows), "PATH": os.pathsep.join((str(tainted), str(system_library.parent)))}
    monkeypatch.setenv("PATH", environment["PATH"])
    assert Path(resolve_library_path(name)) == tainted / name
    monkeypatch.setenv("PATH", tool.freeze_environment(environment)["PATH"])
    assert Path(resolve_library_path(name)) == system_library


def test_package_spec_sanitizes_environment_before_native_discovery():
    source = SPEC.read_text(encoding="utf-8")
    sanitize = source.index("_freeze_environment = freeze_environment()")
    install = source.index("os.environ.update(_freeze_environment)")
    collect = source.index('collect_submodules("PySide6.QtCharts")')
    assert sanitize < source.index("os.environ.clear()") < install < collect < source.index("a = Analysis(")


def test_complete_lock_is_exact_hashed_and_covers_direct_inputs():
    text = LOCK.read_text(encoding="utf-8")
    logical = text.replace("\\\n", " ").splitlines()
    requirements = [line for line in logical if line and not line.lstrip().startswith("#") and "==" in line]
    assert len(requirements) >= 50
    assert all("--hash=sha256:" in line for line in requirements)
    assert not re.search(r"(?m)^[A-Za-z0-9_.-]+\s*(?:>=|<=|~=|!=|===)", text)

    direct = {}
    for line in INPUT.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^([A-Za-z0-9_.-]+)==([^\s]+)$", line)
        if match:
            direct[match.group(1).replace("_", "-").lower()] = match.group(2)
    locked = _locked_packages()
    assert direct
    assert all(locked.get(name) == version for name, version in direct.items())
    assert {"pyinstaller", "sigstore", "astralprims", "pefile", "pywin32-ctypes"} <= set(locked)
    assert locked["lets-agent"] == "1.0.11"
    assert "lets-agent @ https://github.com/AstralDeep/LETS/releases/download/v1.0.11/" in text
    assert "c22dd4c55b1f8e62200455c370ea1b56fb2a96da7fbeae1406e3d0b1365f8c80" in text


def test_manifest_and_package_spec_bind_the_exact_lock_bytes():
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    assert manifest["requirements_lock_sha256"] == _sha(LOCK)
    assert manifest["required_runtime_lock_sha256"] == _sha(LOCK)
    assert manifest["requirements_input_sha256"] == _sha(INPUT)
    spec = SPEC.read_text(encoding="utf-8")
    assert '"requirements-release.lock.txt", "deployment"' in spec
    assert '"deployment/runtime-manifest.json", "deployment"' in spec
    assert "resolve_effective_profile(" in spec
    assert "validate_packaged_deployment(" in spec
    assert spec.index("validate_packaged_deployment(") < spec.index("a = Analysis(")


def test_two_clean_manifest_calculations_are_byte_identical(tmp_path):
    first = {
        "lock_sha256": _sha(LOCK),
        "packages": sorted(_locked_packages().items()),
    }
    second = {
        "packages": sorted(_locked_packages().items()),
        "lock_sha256": _sha(LOCK),
    }
    a = json.dumps(first, sort_keys=True, separators=(",", ":")).encode()
    b = json.dumps(second, sort_keys=True, separators=(",", ":")).encode()
    assert hashlib.sha256(a).digest() == hashlib.sha256(b).digest()


def test_candidate_manifest_binds_build_once_exe_and_release_inputs(tmp_path):
    tool = _tool_module()
    executable = tmp_path / "AstralDeep.exe"
    executable.write_bytes(b"one unsigned build")
    value = tool.artifact_manifest(
        executable=executable,
        profile=ROOT / "deployment" / "release-profile.json",
        runtime_manifest_path=MANIFEST,
        requirements_input=INPUT,
        lock=LOCK,
        source_sha="a" * 40,
        run_id="123",
        run_attempt="2",
        artifact_name="windows-candidate-a",
    )
    assert value["executable_sha256"] == hashlib.sha256(executable.read_bytes()).hexdigest()
    assert value["requirements_lock_sha256"] == _sha(LOCK)
    assert value["deployment_profile_sha256"] == json.loads(
        MANIFEST.read_text(encoding="utf-8")
    )["deployment_profile_sha256"]


def test_lock_reader_normalizes_ignores_host_helper_and_fails_closed(tmp_path):
    tool = _tool_module()
    lock = tmp_path / "requirements.lock.txt"
    lock.write_text(
        "Example_Pkg==1.2.3 \\\n"
        + "    --hash=sha256:"
        + "a" * 64
        + "\n"
        + 'macholib==1.0 ; sys_platform == "darwin" \\\n'
        + "    --hash=sha256:"
        + "b" * 64
        + "\n",
        encoding="utf-8",
    )
    assert tool.locked_packages(lock) == {"example-pkg": "1.2.3"}

    lock.write_text(
        "lets-agent @ https://github.com/AstralDeep/LETS/releases/download/"
        "v1.0.11/lets_agent-1.0.11-py3-none-any.whl \\\n"
        "    --hash=sha256:" + "c" * 64 + "\n",
        encoding="utf-8",
    )
    assert tool.locked_packages(lock) == {"lets-agent": "1.0.11"}

    lock.write_text("foo==1\nfoo==1\n", encoding="utf-8")
    with pytest.raises(tool.CandidateManifestError, match="repeats package foo"):
        tool.locked_packages(lock)

    lock.write_text("# no packages\n", encoding="utf-8")
    with pytest.raises(tool.CandidateManifestError, match="no exact packages"):
        tool.locked_packages(lock)
    with pytest.raises(tool.CandidateManifestError, match="release lock is unreadable"):
        tool.locked_packages(tmp_path / "missing.lock")


def test_file_and_profile_hashes_fail_closed_on_unreadable_inputs(tmp_path):
    tool = _tool_module()
    profile = tmp_path / "profile.json"
    profile.write_text('{"z":1,"a":2}', encoding="utf-8")
    expected = hashlib.sha256(b'{"a":2,"z":1}').hexdigest()
    assert tool.canonical_profile_sha256(profile) == expected

    profile.write_text("not json", encoding="utf-8")
    with pytest.raises(tool.CandidateManifestError, match="not readable JSON"):
        tool.canonical_profile_sha256(profile)
    with pytest.raises(tool.CandidateManifestError, match="required input is unreadable"):
        tool.sha256_file(tmp_path / "missing.bin")


def test_installed_version_selection_is_normalized_and_complete(monkeypatch):
    tool = _tool_module()
    rows = [
        SimpleNamespace(metadata={"Name": "Example_Pkg"}, version="1.2.3"),
        SimpleNamespace(metadata={}, version="ignored"),
        SimpleNamespace(metadata={"Name": "Other"}, version="4.5.6"),
    ]
    monkeypatch.setattr(tool.importlib.metadata, "distributions", lambda: rows)
    assert tool.installed_versions({"example-pkg"}) == {"example-pkg": "1.2.3"}
    assert tool.installed_versions({"other"}, rows) == {"other": "4.5.6"}
    with pytest.raises(tool.CandidateManifestError, match="missing locked packages"):
        tool.installed_versions({"missing"}, rows)


def test_environment_manifest_binds_exact_installed_set(tmp_path):
    tool = _tool_module()
    lock = tmp_path / "requirements.lock.txt"
    lock.write_text("foo==1.0 --hash=sha256:" + "a" * 64 + "\n", encoding="utf-8")
    tool.installed_versions = lambda names: {name: "1.0" for name in names}
    manifest = tool.environment_manifest(lock)
    assert manifest["document_type"] == "windows_release_environment"
    assert manifest["target_platform"] == "win_amd64"
    assert manifest["packages"] == [{"name": "foo", "version": "1.0"}]
    assert manifest["requirements_lock_sha256"] == _sha(lock)

    tool.installed_versions = lambda names: {name: "2.0" for name in names}
    with pytest.raises(tool.CandidateManifestError, match="differ from the release lock"):
        tool.environment_manifest(lock)


def test_json_io_and_environment_comparison_are_strict(tmp_path):
    tool = _tool_module()
    first = tmp_path / "nested" / "first.json"
    second = tmp_path / "second.json"
    value = {
        "requirements_lock_sha256": "a" * 64,
        "packages": [{"name": "foo", "version": "1"}],
    }
    tool.write_json(first, value)
    tool.write_json(second, value)
    assert first.read_text(encoding="utf-8").endswith("\n")
    assert tool.load_json(first) == value
    result = tool.compare_environment_manifests(first, second)
    assert result["status"] == "passed"
    assert result["package_count"] == 1
    assert result["environment_manifest_sha256"] == _sha(first)

    tool.write_json(second, {**value, "packages": []})
    with pytest.raises(tool.CandidateManifestError, match="did not resolve identically"):
        tool.compare_environment_manifests(first, second)

    malformed = tmp_path / "malformed.json"
    malformed.write_text("{", encoding="utf-8")
    with pytest.raises(tool.CandidateManifestError, match="manifest is unreadable"):
        tool.load_json(malformed)
    malformed.write_text("[]", encoding="utf-8")
    with pytest.raises(tool.CandidateManifestError, match="must be an object"):
        tool.load_json(malformed)


@pytest.mark.parametrize(
    ("source_sha", "run_id", "run_attempt", "message"),
    [
        ("not-a-sha", "1", "1", "source SHA is invalid"),
        ("a" * 40, "run", "1", "workflow run identity is invalid"),
        ("a" * 40, "1", "attempt", "workflow run identity is invalid"),
    ],
)
def test_candidate_manifest_rejects_invalid_workflow_identity(
    source_sha, run_id, run_attempt, message
):
    tool = _tool_module()
    with pytest.raises(tool.CandidateManifestError, match=message):
        tool.artifact_manifest(
            executable=Path("unused.exe"),
            profile=Path("unused-profile.json"),
            runtime_manifest_path=Path("unused-runtime.json"),
            requirements_input=Path("unused.in"),
            lock=Path("unused.lock"),
            source_sha=source_sha,
            run_id=run_id,
            run_attempt=run_attempt,
            artifact_name="candidate",
        )


def test_candidate_manifest_rejects_runtime_input_drift(tmp_path):
    tool = _tool_module()
    executable = tmp_path / "AstralDeep.exe"
    profile = tmp_path / "profile.json"
    runtime = tmp_path / "runtime.json"
    requirements_input = tmp_path / "requirements.in"
    lock = tmp_path / "requirements.lock.txt"
    executable.write_bytes(b"candidate")
    profile.write_text("{}", encoding="utf-8")
    requirements_input.write_text("foo==1\n", encoding="utf-8")
    lock.write_text("foo==1 --hash=sha256:" + "a" * 64 + "\n", encoding="utf-8")
    runtime.write_text("{}", encoding="utf-8")
    with pytest.raises(tool.CandidateManifestError, match="does not bind exact"):
        tool.artifact_manifest(
            executable=executable,
            profile=profile,
            runtime_manifest_path=runtime,
            requirements_input=requirements_input,
            lock=lock,
            source_sha="a" * 40,
            run_id="1",
            run_attempt="1",
            artifact_name="candidate",
        )


def test_artifact_reference_validates_provider_identity(tmp_path):
    tool = _tool_module()
    manifest = tmp_path / "candidate.json"
    tool.write_json(
        manifest,
        {
            "source_sha": "a" * 40,
            "workflow_run_id": "123",
            "workflow_run_attempt": "2",
            "artifact_name": "candidate",
            "executable_sha256": "b" * 64,
        },
    )
    reference = tool.artifact_reference(
        manifest_path=manifest,
        artifact_id="42",
        artifact_digest="sha256:" + "c" * 64,
    )
    assert reference["artifact_id"] == "42"
    assert reference["artifact_archive_sha256"] == "c" * 64
    assert reference["executable_sha256"] == "b" * 64

    for artifact_id in ("0", "-1", "not-numeric"):
        with pytest.raises(tool.CandidateManifestError, match="artifact ID is invalid"):
            tool.artifact_reference(
                manifest_path=manifest,
                artifact_id=artifact_id,
                artifact_digest="c" * 64,
            )
    with pytest.raises(tool.CandidateManifestError, match="artifact digest is invalid"):
        tool.artifact_reference(
            manifest_path=manifest,
            artifact_id="42",
            artifact_digest="not-a-digest",
        )


@pytest.mark.parametrize(
    ("command", "function_name", "arguments"),
    [
        (
            "environment-manifest",
            "environment_manifest",
            ["--lock", "lock.txt"],
        ),
        (
            "compare-environments",
            "compare_environment_manifests",
            ["--first", "a.json", "--second", "b.json"],
        ),
        (
            "artifact-manifest",
            "artifact_manifest",
            [
                "--executable",
                "candidate.exe",
                "--profile",
                "profile.json",
                "--runtime-manifest",
                "runtime.json",
                "--requirements-input",
                "requirements.in",
                "--lock",
                "lock.txt",
                "--source-sha",
                "a" * 40,
                "--run-id",
                "1",
                "--run-attempt",
                "1",
                "--artifact-name",
                "candidate",
            ],
        ),
        (
            "artifact-reference",
            "artifact_reference",
            [
                "--manifest",
                "candidate.json",
                "--artifact-id",
                "1",
                "--artifact-digest",
                "a" * 64,
            ],
        ),
    ],
)
def test_cli_dispatches_every_command(
    tmp_path, monkeypatch, command, function_name, arguments
):
    tool = _tool_module()
    output = tmp_path / f"{command}.json"
    monkeypatch.setattr(
        tool,
        function_name,
        lambda *args, **kwargs: {"document_type": command},
    )
    assert tool.main([command, *arguments, "--output", str(output)]) == 0
    assert json.loads(output.read_text(encoding="utf-8")) == {
        "document_type": command
    }


def test_cli_reports_candidate_error_without_writing_output(
    tmp_path, monkeypatch, capsys
):
    tool = _tool_module()
    output = tmp_path / "failed.json"

    def fail(_lock):
        raise tool.CandidateManifestError("synthetic rejection")

    monkeypatch.setattr(tool, "environment_manifest", fail)
    assert (
        tool.main(
            [
                "environment-manifest",
                "--lock",
                "lock.txt",
                "--output",
                str(output),
            ]
        )
        == 1
    )
    assert not output.exists()
    assert "windows candidate manifest failed: synthetic rejection" in capsys.readouterr().err
