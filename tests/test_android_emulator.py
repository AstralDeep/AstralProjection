"""Exercises the locked emulator installer and real process boundaries without a device.
The workflow contract keeps the complete Android coverage lane fail closed.
"""

from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import urllib.error
import zipfile
import xml.etree.ElementTree as ET

import pytest


ROOT = Path(__file__).resolve().parents[1]


def test_required_emulator_setup_avoids_an_unlocked_sdkmanager_upgrade():
    workflow = (ROOT / ".github/workflows/android-ci.yml").read_text()
    job = workflow.partition("  instrumented:\n")[2].partition("  android-required:\n")[0]
    assert "reactivecircus/android-emulator-runner@" not in job
    assert "python3 ../scripts/run_android_emulator.py" in job
    assert "timeout-minutes: 30" in job
    assert "continue-on-error" not in job


@pytest.fixture
def emulator():
    from scripts import run_android_emulator

    return run_android_emulator


@pytest.fixture
def archive():
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as zipped:
        for name, content in {
            "emulator/source.properties": "Pkg.Revision=37.2.12\nPkg.BuildId=16428233\n",
            "emulator/emulator": "#!/bin/sh\nexit 0\n",
        }.items():
            info = zipfile.ZipInfo(name)
            info.external_attr = 0o100755 << 16
            zipped.writestr(info, content)
    return stream.getvalue()


@pytest.fixture
def lock(archive):
    return {
        "version": "37.2.12",
        "build": "16428233",
        "url": "https://dl.google.com/android/repository/emulator-linux_x64-16428233.zip",
        "bytes": len(archive),
        "sha256": hashlib.sha256(archive).hexdigest(),
    }


def test_download_installs_only_verified_executable_bytes(
    emulator, tmp_path, monkeypatch, archive, lock
):
    (tmp_path / "emulator").mkdir()
    (tmp_path / "emulator/previous-build").write_text("old")
    monkeypatch.setattr(emulator.urllib.request, "urlopen", lambda *a, **k: io.BytesIO(archive))
    emulator.install(tmp_path, lock)
    assert (tmp_path / "emulator/emulator").stat().st_mode & 0o111
    assert (tmp_path / "emulator/source.properties").read_text().startswith("Pkg.Revision=37.2.12")
    local = ET.parse(tmp_path / "emulator/package.xml").getroot().find("localPackage")
    assert local.attrib == {"path": "emulator", "obsolete": "false"}
    assert [node.text for node in local.find("revision")] == ["37", "2", "12"]
    assert not list(tmp_path.glob("astral-emulator-*"))
    assert not (tmp_path / "emulator/previous-build").exists()


@pytest.mark.parametrize(
    "mutation", ["digest", "short", "long", "bad-zip", "properties", "traversal", "symlink"]
)
def test_invalid_archives_never_replace_existing_sdk(
    emulator, tmp_path, monkeypatch, archive, lock, mutation
):
    target = tmp_path / "emulator"
    target.mkdir()
    (target / "original").write_text("retained")
    if mutation == "digest":
        lock["sha256"] = "0" * 64
    elif mutation == "short":
        archive = archive[:-1]
    elif mutation == "long":
        archive += b"extra"
    else:
        stream = io.BytesIO()
        if mutation == "bad-zip":
            stream.write(b"not a zip")
        else:
            with zipfile.ZipFile(stream, "w") as zipped:
                if mutation == "properties":
                    zipped.writestr("emulator/source.properties", "Pkg.Revision=foreign\n")
                    zipped.writestr("emulator/emulator", "wrong")
                elif mutation == "traversal":
                    zipped.writestr("emulator/../../outside", "unsafe")
                else:
                    info = zipfile.ZipInfo("emulator/linked")
                    info.external_attr = 0o120777 << 16
                    zipped.writestr(info, "../../outside")
        archive = stream.getvalue()
        lock.update(bytes=len(archive), sha256=hashlib.sha256(archive).hexdigest())
    monkeypatch.setattr(emulator.urllib.request, "urlopen", lambda *a, **k: io.BytesIO(archive))
    with pytest.raises((ValueError, zipfile.BadZipFile)):
        emulator.install(tmp_path, lock)
    assert (target / "original").read_text() == "retained"
    assert not (tmp_path.parent / "outside").exists()
    assert not list(tmp_path.glob("astral-emulator-*"))


def test_unavailable_archive_fails_before_sdk_mutation(emulator, tmp_path, monkeypatch, lock):
    def unavailable(*args, **kwargs):
        raise urllib.error.URLError("unavailable")

    monkeypatch.setattr(emulator.urllib.request, "urlopen", unavailable)
    with pytest.raises(urllib.error.URLError):
        emulator.install(tmp_path, lock)
    assert not (tmp_path / "emulator").exists()
    assert not list(tmp_path.glob("astral-emulator-*"))


@pytest.mark.parametrize("mutation", ["foreign-url", "query", "build", "digest", "size", "extra"])
def test_lock_refuses_unbounded_or_foreign_inputs(emulator, tmp_path, lock, mutation):
    if mutation == "foreign-url":
        lock["url"] = "https://foreign.example/emulator.zip"
    elif mutation == "query":
        lock["url"] += "?latest=1"
    elif mutation == "build":
        lock["build"] = "different"
    elif mutation == "digest":
        lock["sha256"] = "short"
    elif mutation == "size":
        lock["bytes"] = True
    else:
        lock["extra"] = "unknown"
    path = tmp_path / "lock.json"
    path.write_text(json.dumps(lock))
    with pytest.raises(ValueError, match="emulator_lock_invalid"):
        emulator.read_lock(path)


def test_committed_lock_matches_the_prior_successful_official_build(emulator):
    lock = emulator.read_lock(ROOT / "android-client/gradle/emulator.lock.json")
    assert lock == {
        "version": "37.2.12",
        "build": "16428233",
        "url": "https://dl.google.com/android/repository/emulator-linux_x64-16428233.zip",
        "bytes": 349654171,
        "sha256": "b08fc43d8608d2955f607f1b287beb525041e730086bdca3af152accac3af9c1",
    }


@pytest.fixture
def processes(tmp_path, monkeypatch, emulator, lock):
    root = tmp_path / "workspace with spaces"
    sdk = tmp_path / "sdk with spaces"
    output = root / "build/088/android-coverage"
    (root / "android-client/gradle").mkdir(parents=True)
    (root / "scripts").mkdir()
    (root / "android-client/gradle/emulator.lock.json").write_text(json.dumps(lock))
    record = tmp_path / "calls.jsonl"
    common = (
        f"#!{sys.executable}\n"
        "import json, os, pathlib, sys, time\n"
        "name=pathlib.Path(sys.argv[0]).name\n"
        "with open(os.environ['EMULATOR_TEST_RECORD'],'a') as f: f.write(json.dumps([name,*sys.argv[1:]])+'\\n')\n"
    )
    tools = {
        "cmdline-tools/latest/bin/sdkmanager": (
            "if '--list_installed' in sys.argv:\n"
            " print('emulator | '+('foreign' if os.environ.get('EMULATOR_TEST_MODE')=='unrecognized' else '37.2.12')+' | Android Emulator | emulator/')\n"
            "if os.environ.get('EMULATOR_TEST_MODE')=='replacement' and '--install' in sys.argv:\n"
            " p=pathlib.Path(os.environ['ANDROID_HOME'])/'emulator/emulator';p.write_text('replacement')\n"
        ),
        "cmdline-tools/latest/bin/avdmanager": (
            "assert sys.stdin.read()=='no\\n'\n"
            "p=pathlib.Path(os.environ['ANDROID_AVD_HOME'])/'test.avd'\n"
            "p.mkdir(parents=True);(p/'config.ini').write_text('hw.keyboard=no\\n')\n"
        ),
        "platform-tools/adb": (
            "if sys.argv[-1]=='sys.boot_completed': print('0' if os.environ.get('EMULATOR_TEST_MODE')=='boot-timeout' else '1')\n"
            "if sys.argv[-2:]==['emu','kill'] and os.environ.get('EMULATOR_TEST_MODE')=='cleanup-failure': sys.exit(7)\n"
        ),
        "emulator/emulator": "time.sleep(60)\n",
    }
    for name, body in tools.items():
        path = sdk / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(common + body)
        path.chmod(0o755)
    (root / "scripts/android_coverage.py").write_text(
        common + "sys.exit(9 if sys.argv[1]==os.environ.get('EMULATOR_TEST_MODE') else 0)\n"
    )
    monkeypatch.setenv("EMULATOR_TEST_RECORD", str(record))
    monkeypatch.setattr(emulator, "install", lambda *a: None)
    monkeypatch.setattr(emulator.platform, "system", lambda: "Linux")
    monkeypatch.setattr(emulator.platform, "machine", lambda: "x86_64")
    return root, sdk, output, record


@pytest.mark.parametrize("mode", ["success", "device", "report", "boot-timeout", "cleanup-failure"])
def test_actual_process_boundaries_cleanup_and_never_repeat_the_suite(
    emulator, processes, monkeypatch, mode
):
    root, sdk, output, record = processes
    monkeypatch.setenv("EMULATOR_TEST_MODE", mode)
    ticks = iter([0, 0, 600])
    monkeypatch.setattr(emulator.time, "monotonic", lambda: next(ticks))
    monkeypatch.setattr(emulator.time, "sleep", lambda _: None)
    if mode == "success":
        emulator.qualify(root, sdk, output)
    else:
        with pytest.raises((RuntimeError, subprocess.CalledProcessError)):
            emulator.qualify(root, sdk, output)
    calls = [json.loads(line) for line in record.read_text().splitlines()]
    assert [x for x in calls if x[0] == "sdkmanager"] == [
        ["sdkmanager", "--licenses"],
        ["sdkmanager", "--list_installed"],
        ["sdkmanager", "--install", "system-images;android-34;default;x86_64", "--channel=0"],
        ["sdkmanager", "--list_installed"],
    ]
    assert [x for x in calls if x[0] == "avdmanager"] == [
        [
            "avdmanager",
            "create",
            "avd",
            "--force",
            "-n",
            "test",
            "--package",
            "system-images;android-34;default;x86_64",
        ]
    ]
    coverage = [x for x in calls if x[0] == "android_coverage.py"]
    expected = [
        [
            "android_coverage.py",
            "device",
            "--root",
            str(root),
            "--output",
            str(output),
            "--serial",
            "emulator-5554",
            "--lane",
            "fixtures",
        ],
        [
            "android_coverage.py",
            "report",
            "--root",
            str(root),
            "--output",
            str(output),
            "--lanes",
            "fixtures",
        ],
    ]
    assert coverage == (
        [] if mode == "boot-timeout" else expected[:1] if mode == "device" else expected
    )
    assert [x for x in calls if x[-2:] == ["emu", "kill"]] == [
        ["adb", "-s", "emulator-5554", "emu", "kill"]
    ]
    assert (output / "emulator.log").is_file()
    assert not list(sdk.glob("astral-avd-*"))
    assert not (output / "avd").exists()
    assert "hw.cpu.ncore=2\n" in (output / "avd-config.ini").read_text()
    assert (
        not (output / "emulator-toolchain.json").exists()
        if mode == "boot-timeout"
        else (output / "emulator-toolchain.json").is_file()
    )


def test_foreign_host_is_refused_before_installation(emulator, processes, monkeypatch):
    root, sdk, output, record = processes
    monkeypatch.setattr(emulator.platform, "system", lambda: "Darwin")
    with pytest.raises(RuntimeError, match="emulator_host_unsupported"):
        emulator.qualify(root, sdk, output)
    assert not record.exists()


@pytest.mark.parametrize("mode", ["unrecognized", "replacement"])
def test_sdk_indirect_replacement_is_refused_before_boot(emulator, processes, monkeypatch, mode):
    root, sdk, output, record = processes
    monkeypatch.setenv("EMULATOR_TEST_MODE", mode)
    with pytest.raises(RuntimeError, match="emulator_sdk_identity"):
        emulator.qualify(root, sdk, output)
    calls = [json.loads(line) for line in record.read_text().splitlines()]
    assert not any(x[0] in ["emulator", "android_coverage.py", "avdmanager"] for x in calls)


def test_exited_emulator_is_reaped_without_device_tests(emulator, processes, monkeypatch):
    root, sdk, output, record = processes
    (sdk / "emulator/emulator").write_text(f"#!{sys.executable}\nraise SystemExit(8)\n")
    original = emulator.subprocess.Popen
    children = []

    def exited(*args, **kwargs):
        child = original(*args, **kwargs)
        if Path(args[0][0]).name == "emulator":
            child.wait()
            children.append(child)
        return child

    monkeypatch.setattr(emulator.subprocess, "Popen", exited)
    with pytest.raises(RuntimeError, match="emulator_exited_before_boot"):
        emulator.qualify(root, sdk, output)
    assert all(child.poll() is not None for child in children)
    calls = [json.loads(line) for line in record.read_text().splitlines()]
    assert not any(x[0] == "android_coverage.py" for x in calls)
    assert any(x[-2:] == ["emu", "kill"] for x in calls)


@pytest.mark.parametrize("error", [subprocess.TimeoutExpired("adb", 10), OSError("adb missing")])
def test_cleanup_exception_still_reaps_the_started_emulator(
    emulator, processes, monkeypatch, error
):
    root, sdk, output, record = processes
    original_run = emulator.subprocess.run
    original_popen = emulator.subprocess.Popen
    children = []

    def run(args, **kwargs):
        if args[-2:] == ["emu", "kill"]:
            raise error
        return original_run(args, **kwargs)

    def popen(args, **kwargs):
        child = original_popen(args, **kwargs)
        if Path(args[0]).name == "emulator":
            children.append(child)
        return child

    monkeypatch.setattr(emulator.subprocess, "run", run)
    monkeypatch.setattr(emulator.subprocess, "Popen", popen)
    with pytest.raises(RuntimeError, match="emulator_cleanup_failed"):
        emulator.qualify(root, sdk, output)
    assert len(children) == 1 and children[0].poll() is not None
    calls = [json.loads(line) for line in record.read_text().splitlines()]
    assert [x[1] for x in calls if x[0] == "android_coverage.py"] == ["device", "report"]


@pytest.mark.parametrize("failure", [False, True])
def test_main_binds_paths_and_returns_the_qualification_outcome(
    emulator, tmp_path, monkeypatch, failure
):
    calls = []

    def qualify(*args):
        calls.append(args)
        if failure:
            raise RuntimeError("denied")

    monkeypatch.setattr(emulator, "qualify", qualify)
    assert emulator.main(
        ["--root", str(tmp_path), "--sdk", str(tmp_path / "sdk"), "--output", str(tmp_path / "out")]
    ) == int(failure)
    assert calls == [
        (tmp_path.resolve(), (tmp_path / "sdk").resolve(), (tmp_path / "out").resolve())
    ]


def test_cleanup_escalates_and_reaps_a_process_that_does_not_exit(emulator, processes, monkeypatch):
    root, sdk, output, record = processes
    original_popen = emulator.subprocess.Popen
    children = []
    escalations = []

    def popen(args, **kwargs):
        child = original_popen(args, **kwargs)
        if Path(args[0]).name == "emulator":
            children.append(child)
            original_wait = child.wait
            original_kill = child.kill

            def wait(timeout=None):
                if not escalations:
                    raise subprocess.TimeoutExpired(args, timeout)
                return original_wait(timeout=timeout)

            def kill():
                escalations.append("kill")
                original_kill()

            child.wait = wait
            child.kill = kill
        return child

    monkeypatch.setattr(emulator.subprocess, "Popen", popen)
    emulator.qualify(root, sdk, output)
    assert escalations == ["kill"]
    assert len(children) == 1 and children[0].poll() is not None
    assert not list(sdk.glob("astral-avd-*"))
