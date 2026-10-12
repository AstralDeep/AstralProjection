#!/usr/bin/env python3
"""Installs the integrity-locked Linux emulator and runs the Android coverage lane once.
The isolated SDK fixture retains boot evidence and cleans up on success or failure.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
import xml.etree.ElementTree as ET

IMAGE = "system-images;android-34;default;x86_64"
SERIAL = "emulator-5554"
BOOT_SECONDS = 600
OPTIONS = [
    "-port",
    "5554",
    "-avd",
    "test",
    "-no-window",
    "-gpu",
    "swiftshader_indirect",
    "-no-snapshot",
    "-noaudio",
    "-no-boot-anim",
]


def read_lock(path: Path) -> dict:
    lock = json.loads(path.read_text())
    if (
        not isinstance(lock, dict)
        or set(lock) != {"version", "build", "url", "bytes", "sha256"}
        or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", str(lock["version"]))
        or not re.fullmatch(r"[0-9]+", str(lock["build"]))
        or lock["url"]
        != f"https://dl.google.com/android/repository/emulator-linux_x64-{lock['build']}.zip"
        or not re.fullmatch(r"[a-f0-9]{64}", str(lock["sha256"]))
        or type(lock["bytes"]) is not int
        or not 0 < lock["bytes"] <= 512 * 1024 * 1024
    ):
        raise ValueError("emulator_lock_invalid")
    return lock


def install(sdk: Path, lock: dict) -> None:
    sdk.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="astral-emulator-", dir=sdk) as temporary:
        root = Path(temporary)
        archive = root / "emulator.zip"
        digest = hashlib.sha256()
        size = 0
        with urllib.request.urlopen(lock["url"], timeout=30) as response, archive.open("wb") as out:
            while chunk := response.read(1024 * 1024):
                size += len(chunk)
                if size > lock["bytes"]:
                    raise ValueError("emulator_archive_size_invalid")
                digest.update(chunk)
                out.write(chunk)
        if size != lock["bytes"] or digest.hexdigest() != lock["sha256"]:
            raise ValueError("emulator_archive_integrity_invalid")
        extracted = root / "verified"
        with zipfile.ZipFile(archive) as zipped:
            for entry in zipped.infolist():
                path = PurePosixPath(entry.filename)
                mode = entry.external_attr >> 16
                if (
                    path.is_absolute()
                    or not path.parts
                    or path.parts[0] != "emulator"
                    or ".." in path.parts
                    or "\\" in entry.filename
                    or stat.S_ISLNK(mode)
                ):
                    raise ValueError("emulator_archive_path_invalid")
            zipped.extractall(extracted)
            for entry in zipped.infolist():
                mode = entry.external_attr >> 16
                if mode:
                    (extracted / entry.filename).chmod(mode & 0o777)
        properties = (extracted / "emulator/source.properties").read_text().splitlines()
        if (
            f"Pkg.Revision={lock['version']}" not in properties
            or f"Pkg.BuildId={lock['build']}" not in properties
            or not (extracted / "emulator/emulator").is_file()
        ):
            raise ValueError("emulator_archive_identity_invalid")
        package = ET.Element(
            "{http://schemas.android.com/repository/android/common/02}repository",
            {"xmlns:generic": "http://schemas.android.com/repository/android/generic/02"},
        )
        local = ET.SubElement(package, "localPackage", path="emulator", obsolete="false")
        ET.SubElement(
            local,
            "type-details",
            {"{http://www.w3.org/2001/XMLSchema-instance}type": "generic:genericDetailsType"},
        )
        revision = ET.SubElement(local, "revision")
        for field, value in zip(("major", "minor", "micro"), lock["version"].split(".")):
            ET.SubElement(revision, field).text = value
        ET.SubElement(local, "display-name").text = "Android Emulator"
        ET.ElementTree(package).write(
            extracted / "emulator/package.xml", encoding="utf-8", xml_declaration=True
        )
        target = sdk / "emulator"
        if target.exists():
            shutil.rmtree(target)
        (extracted / "emulator").rename(target)


def qualify(root: Path, sdk: Path, output: Path) -> None:
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise RuntimeError("emulator_host_unsupported")
    lock = read_lock(root / "android-client/gradle/emulator.lock.json")
    install(sdk, lock)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="astral-avd-", dir=sdk) as temporary:
        run_fixture(root, sdk, output, lock, Path(temporary))


def run_fixture(root: Path, sdk: Path, output: Path, lock: dict, avd: Path) -> None:
    tools = sdk / "cmdline-tools/latest/bin"
    adb = str(sdk / "platform-tools/adb")
    environment = {
        **os.environ,
        "ANDROID_HOME": str(sdk),
        "ANDROID_SDK_ROOT": str(sdk),
        "ANDROID_AVD_HOME": str(avd),
        "PATH": os.pathsep.join(
            [str(tools), str(sdk / "platform-tools"), os.environ.get("PATH", "")]
        ),
    }
    subprocess.run(
        [str(tools / "sdkmanager"), "--licenses"],
        input="y\n" * 100,
        text=True,
        check=True,
        env=environment,
    )
    binary_digest = hashlib.sha256((sdk / "emulator/emulator").read_bytes()).hexdigest()
    installed = subprocess.run(
        [str(tools / "sdkmanager"), "--list_installed"],
        capture_output=True,
        text=True,
        check=True,
        env=environment,
    )
    (output / "sdk-installed-before.txt").write_text(installed.stdout)
    if not re.search(
        rf"(?m)^\s*emulator\s*\|\s*{re.escape(lock['version'])}\s*\|", installed.stdout
    ):
        raise RuntimeError("emulator_sdk_identity_invalid")
    subprocess.run(
        [str(tools / "sdkmanager"), "--install", IMAGE, "--channel=0"], check=True, env=environment
    )
    installed = subprocess.run(
        [str(tools / "sdkmanager"), "--list_installed"],
        capture_output=True,
        text=True,
        check=True,
        env=environment,
    )
    (output / "sdk-installed-after.txt").write_text(installed.stdout)
    if (
        not re.search(
            rf"(?m)^\s*emulator\s*\|\s*{re.escape(lock['version'])}\s*\|", installed.stdout
        )
        or hashlib.sha256((sdk / "emulator/emulator").read_bytes()).hexdigest() != binary_digest
    ):
        raise RuntimeError("emulator_sdk_identity_changed")
    subprocess.run(
        [str(tools / "avdmanager"), "create", "avd", "--force", "-n", "test", "--package", IMAGE],
        input="no\n",
        text=True,
        check=True,
        env=environment,
    )
    with (avd / "test.avd/config.ini").open("a") as config:
        config.write("hw.cpu.ncore=2\n")
    shutil.copyfile(avd / "test.avd/config.ini", output / "avd-config.ini")
    process = None
    succeeded = False
    with (output / "emulator.log").open("w") as log:
        try:
            process = subprocess.Popen(
                [str(sdk / "emulator/emulator"), *OPTIONS],
                env=environment,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            deadline = time.monotonic() + BOOT_SECONDS
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("emulator_exited_before_boot")
                boot = subprocess.run(
                    [adb, "-s", SERIAL, "shell", "getprop", "sys.boot_completed"],
                    capture_output=True,
                    text=True,
                    env=environment,
                    timeout=10,
                )
                if boot.returncode == 0 and boot.stdout.strip() == "1":
                    break
                time.sleep(2)
            else:
                raise RuntimeError("emulator_boot_failed")
            for setting in (
                "window_animation_scale",
                "transition_animation_scale",
                "animator_duration_scale",
            ):
                subprocess.run(
                    [adb, "-s", SERIAL, "shell", "settings", "put", "global", setting, "0.0"],
                    check=True,
                    env=environment,
                )
            (output / "emulator-toolchain.json").write_text(
                json.dumps({**lock, "installed_binary_sha256": binary_digest}, indent=2) + "\n"
            )
            coverage = [sys.executable, str(root / "scripts/android_coverage.py")]
            common = ["--root", str(root), "--output", str(output)]
            subprocess.run(
                [*coverage, "device", *common, "--serial", SERIAL, "--lane", "fixtures"],
                cwd=root / "android-client",
                check=True,
                env=environment,
            )
            subprocess.run(
                [*coverage, "report", *common, "--lanes", "fixtures"],
                cwd=root / "android-client",
                check=True,
                env=environment,
            )
            succeeded = True
        finally:
            if process is not None:
                cleanup_failed = False
                try:
                    cleanup = subprocess.run(
                        [adb, "-s", SERIAL, "emu", "kill"],
                        capture_output=True,
                        text=True,
                        env=environment,
                        timeout=10,
                    )
                    cleanup_failed = cleanup.returncode != 0
                except (OSError, subprocess.TimeoutExpired):
                    cleanup_failed = True
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
                    else:
                        process.wait()
                if succeeded and cleanup_failed:
                    raise RuntimeError("emulator_cleanup_failed")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        qualify(args.root.resolve(), args.sdk.resolve(), args.output.resolve())
    except Exception as error:
        print(f"Android emulator qualification failed: {type(error).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
