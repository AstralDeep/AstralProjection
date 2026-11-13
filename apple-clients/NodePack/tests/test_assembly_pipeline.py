"""Qualifies node-pack artifact assembly and failure containment with tiny source and runtime archives.
Only external download, Git export and Python package processes are simulated.
"""

import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
from types import SimpleNamespace

import pytest

import assemble_pack as ap
import pack_manifest as pm


def write(root, name, data=b"fixture", mode=0o644):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(mode)
    return path


@pytest.fixture
def assembly(tmp_path, monkeypatch):
    runtime = tmp_path / "runtime"
    write(runtime, "python/bin/python3.11", mode=0o755)
    for name in ("pip", "helper"):
        write(runtime, f"python/bin/{name}")
    for name in ("pip", "setuptools", "wheel", "pkg_resources", "_distutils_hack"):
        write(runtime, f"python/lib/python3.11/site-packages/{name}/__init__.py")
    write(runtime, "python/lib/python3.11/site-packages/distutils-precedence.pth")
    for name in ("test", "idlelib", "turtledemo", "tkinter", "ensurepip"):
        write(runtime, f"python/lib/python3.11/{name}/payload")
    for name in ("lib/libtcl.dylib", "lib/libtk.dylib", "lib/thread/a", "lib/tcl/a", "lib/tk/a", "lib/itcl/a",
                 "lib/python3.11/lib-dynload/_tkinter.so", "share/a", "include/a", "lib/python3.11/__pycache__/stale.pyc"):
        write(runtime, "python/" + name)
    write(runtime, "python/lib/python3.11/site-packages/kept/__init__.py")
    archive = tmp_path / "python.tar.gz"
    with tarfile.open(archive, "w:gz") as bundle:
        bundle.add(runtime / "python", arcname="python")
    settings = {
        "pack_format": 1, "kernel": {"repository": "https://example.invalid/kernel", "commit": "1" * 40},
        "deep": {"repository": "https://example.invalid/deep", "commit": "2" * 40},
        "python": {"version": "3.11.18", "sha256": pm.sha256_file(archive), "url": ap.PYTHON_HOST_PREFIX + "fixture.tar.gz"},
        "backend_exclusions": [{"path": "data"}, {"path": "requirements.txt"}],
        "excluded_packages": [{"name": "forbidden"}], "kept_server_parts": ["orchestrator"],
    }
    components = {key: {"repository": f"https://example.invalid/{key}", "commit": "3" * 40,
                        "path": f"components/{key}"} for key in ap.COMPONENT_BUILD_ORDER}
    kernel = tmp_path / "kernel"
    write(kernel, "kernel-commit.txt", (settings["kernel"]["commit"] + "\n").encode())
    write(kernel, "astral_kernel-0.1.0-py3-none-macosx_14_0_arm64.whl")
    write(kernel, "astral-mailbox-macos-aarch64", mode=0o755)
    monkeypatch.setattr(ap.pins, "load", lambda: settings)
    monkeypatch.setattr(ap, "download_python", lambda *a: archive)

    def export(name, repository, commit, destination, work):
        destination.mkdir(parents=True)
        if name == "AstralDeep":
            write(destination, "config/astral-composition.json", json.dumps({"components": components}).encode())
            for path in ("backend/orchestrator/orchestrator.py", "backend/data/private.bin", "backend/requirements.txt",
                         "backend/tests/test_x.py", "backend/agents/tests/test_y.py", "backend/__pycache__/stale.pyc",
                         "scripts/node/node.py", "pyproject.toml", ".gitmodules"):
                write(destination, path)
        return commit

    monkeypatch.setattr(ap, "export_commit", export)
    commands = []
    failure = {"step": None}
    installed = [["kept", "1.0"]]

    def external(command, **kwargs):
        commands.append(command)
        if failure["step"] is not None and failure["step"] in command:
            raise subprocess.CalledProcessError(1, command)
        if "importlib.metadata" in " ".join(command):
            return SimpleNamespace(stdout=json.dumps(installed))
        if "wheel" in command:
            directory = Path(command[command.index("-w") + 1])
            write(directory, "external-1.0-py3-none-any.whl")
        if "build" in command:
            directory = Path(command[command.index("--wheel-dir") + 1])
            entries = []
            for key, component in components.items():
                wheel = write(directory, key + "-0.1.0-py3-none-any.whl", key.encode())
                entries.append({"component": key, "wheel": wheel.name, "wheel_sha256": pm.sha256_file(wheel),
                    "source_path": component["path"], "source_sha256": hashlib.sha256(key.encode()).hexdigest(),
                    "version": "0.1.0", "distribution": key})
            manifest = Path(command[command.index("--root") + 1]) / "config/astral-composition.json"
            receipt = {"format": "astraldeep.component-wheel-lock/v1", "installer": "pip-wheel/v1",
                       "manifest_sha256": pm.sha256_file(manifest), "components": entries}
            write(directory, "astral-component-wheels.lock.json", json.dumps(receipt).encode())
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(ap.subprocess, "run", external)
    return SimpleNamespace(root=tmp_path, kernel=kernel, settings=settings, components=components,
                           commands=commands, failure=failure, installed=installed)


def test_assembly_seals_only_verified_runtime_and_source_inputs(assembly):
    output, work = assembly.root / "out", assembly.root / "work"
    descriptor = json.loads(ap.assemble(output, assembly.kernel, work).read_text())
    manifest = json.loads((output / "node-pack-manifest.json").read_text())
    archive = output / descriptor["archive"]["file"]
    assert descriptor["archive"]["sha256"] == pm.sha256_file(archive)
    assert descriptor["manifest_sha256"] == pm.sha256_file(output / "node-pack-manifest.json")
    assert pm.verify_tree(work / "stage", manifest) == []
    assert set(manifest["components"]) == set(ap.COMPONENT_BUILD_ORDER)
    receipt = manifest["component_wheels"]
    assert {entry["component"] for entry in receipt["components"]} == set(ap.COMPONENT_BUILD_ORDER)
    assert receipt["manifest_sha256"] == pm.sha256_file(work / "components-root/config/astral-composition.json")
    assert manifest["installed_distributions"] == [{"name": "kept", "version": "1.0"}]
    assert manifest["kernel"]["commit"] == assembly.settings["kernel"]["commit"]
    with tarfile.open(archive) as bundle:
        names = bundle.getnames()
    assert "app/backend/orchestrator/orchestrator.py" in names
    assert "bin/astral-mailbox" in names and "launcher/astral_node_launch.py" in names
    assert not any("/tests/" in path or "/data/" in path or "__pycache__" in path for path in names)
    assert not any(path.startswith("python/lib/python3.11/site-packages/pip") for path in names)
    assert "python/bin/helper" not in names
    commands = assembly.commands
    build = next(i for i, command in enumerate(commands) if "build" in command)
    install = next(i for i, command in enumerate(commands) if "install_local_components.py" in " ".join(command) and "install" in command)
    verify = next(i for i, command in enumerate(commands) if "verify" in command)
    assert build < install < verify
    assert all("--require-hashes" in command for command in commands if "pip" in command and "--no-index" not in command)


def test_failed_component_verification_never_produces_a_candidate(assembly):
    assembly.failure["step"] = "verify"
    output = assembly.root / "out"
    with pytest.raises(subprocess.CalledProcessError):
        ap.assemble(output, assembly.kernel, assembly.root / "work")
    assert not output.exists()
    assert not any("compileall" in command for command in assembly.commands)


def test_assembler_cli_reports_the_sealed_artifact(assembly, monkeypatch, capsys):
    monkeypatch.setattr(ap.sys, "argv", ["assemble", "--kernel-dir", str(assembly.kernel),
        "--out", str(assembly.root / "out"), "--work", str(assembly.root / "work")])
    ap.main()
    assert "archive " in capsys.readouterr().out
    assembly.failure["step"] = "verify"
    with pytest.raises(SystemExit, match="node pack"):
        ap.main()


def test_python_download_stream_is_digest_checked_before_cache_promotion(tmp_path, monkeypatch):
    payload = b"tiny runtime archive"
    calls = []

    def response(url, timeout):
        calls.append((url, timeout))
        return io.BytesIO(payload)

    monkeypatch.setattr(ap.urllib.request, "urlopen", response)
    pin = {"url": ap.PYTHON_HOST_PREFIX + "fixture.tar.gz", "sha256": hashlib.sha256(payload).hexdigest()}
    result = ap.download_python(pin, tmp_path / "downloads")
    assert result.read_bytes() == payload and calls == [(pin["url"], 120)]
    assert not list(result.parent.glob("*.part"))



def test_assembly_refuses_an_excluded_installed_package_before_sealing(assembly):
    assembly.installed[:] = [["forbidden", "1.0"]]
    output = assembly.root / "out"
    with pytest.raises(ap.PackError, match="excluded packages"):
        ap.assemble(output, assembly.kernel, assembly.root / "work")
    assert not output.exists()
