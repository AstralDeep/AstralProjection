#!/usr/bin/env python3
"""Source-bound Android JVM/device coverage collection; never merges XML counters."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET

VERSION = "astral.android-coverage/v1"
PACKAGE = "com.personalailabs.astraldeep"
TEST_PACKAGE = PACKAGE + ".test/androidx.test.runner.AndroidJUnitRunner"
PREFIX = PACKAGE + ".app."
STAGING_CLASS = PREFIX + "ReleaseEvidenceInstrumentedTest"
MAX_EXEC = 64 * 1024 * 1024
MAX_APK = 256 * 1024 * 1024
LANES = {"fixtures", "staging"}
STAGING_KEYS = {
    "astralStagingUrl",
    "astralAccessToken",
    "astralCandidateSha",
    "astralReleaseId",
    "astralReleaseVersion",
    "astralLifecycleAgentId",
    "astralLifecycleStates",
    "astralStagingEnvironmentB64",
    "astralToolchainCanaryB64",
    "astralRunnerImage",
    "astralRunnerName",
    "astralRunnerArch",
    "astralRunnerEnvironment",
    "astralWorkflowName",
    "astralRunId",
    "astralRunAttempt",
    "astralJobId",
}


class InvalidCoverage(ValueError):
    """A closed diagnostic failure; no credentials are included in errors."""


def require(condition: bool, code: str) -> None:
    if not condition:
        raise InvalidCoverage(code)


def digest(path: Path) -> str:
    require(path.is_file() and not path.is_symlink(), "file_missing_or_symlink")
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")


def read_json(path: Path) -> dict:
    require(
        path.is_file() and not path.is_symlink() and path.stat().st_size <= 8 * 1024 * 1024,
        "invalid_json_file",
    )
    result = json.loads(path.read_text(encoding="utf-8"))
    require(isinstance(result, dict), "invalid_json_object")
    return result


def inside(root: Path, path: Path) -> Path:
    require(not path.is_symlink(), "path_symlink")
    actual = path.resolve()
    require(actual.is_relative_to(root.resolve()), "path_outside_root")
    current = path.absolute()
    while current != root.absolute() and current != current.parent:
        require(not current.is_symlink(), "path_symlink")
        current = current.parent
    return actual


def file_tree(root: Path, paths: list[Path], *, missing: bool = False) -> dict[str, str]:
    result = {}
    for path in paths:
        path = inside(root, path)
        require(path.exists() or missing, "input_missing")
        files = [path] if path.is_file() else sorted(path.rglob("*"))
        for file in files:
            require(not file.is_symlink(), "input_symlink")
            if file.is_file():
                result[str(file.relative_to(root))] = digest(file)
    return result


def source_tree(root: Path) -> dict[str, str]:
    android = root / "android-client"
    paths = []
    for file in android.rglob("*"):
        relative = file.relative_to(android)
        if any(part in {"build", ".gradle", ".kotlin", ".idea"} for part in relative.parts):
            continue
        if file.name in {"local.properties", "keystore.properties"} or file.suffix in {
            ".jks",
            ".keystore",
        }:
            continue
        require(not file.is_symlink(), "source_symlink")
        if file.is_file():
            paths.append(file)
    paths += [root / "scripts/android_coverage.py"]
    paths += list((root / "contracts/assets").rglob("*"))
    paths += [
        root / "contracts/fixtures/voice_065/client_conformance.json",
        root / "contracts/fixtures/voice_075/client_local_conformance.json",
    ]
    paths += list((root / "contracts/fixtures/workspace_088").rglob("*"))
    paths += [root / "backend/webrender/static/vendor/plotly.min.js"]
    return file_tree(root, paths)


def run(args: list[str], *, timeout: int = 300, cwd: Path | None = None) -> str:
    completed = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    require(completed.returncode == 0, "subprocess_failed")
    return completed.stdout


def java_binary(name: str) -> str:
    home = os.environ.get("JAVA_HOME")
    path = Path(home) / "bin" / name if home else Path(shutil.which(name) or "")
    require(path.is_file(), "jdk_tool_missing")
    return str(path)


def unit_result(directory: Path) -> dict[str, int]:
    files = sorted(directory.glob("TEST-*.xml"))
    require(bool(files), "unit_results_missing")
    totals = {key: 0 for key in ("tests", "failures", "errors", "skipped")}
    for file in files:
        element = ET.parse(file).getroot()
        for key in totals:
            totals[key] += int(element.get(key, "0"))
    require(
        totals["tests"] > 0 and not any(totals[key] for key in ("failures", "errors", "skipped")),
        "unit_tests_not_passed",
    )
    return totals


def fixture_inventory(root: Path) -> tuple[list[str], int]:
    classes, count = [], 0
    for file in sorted((root / "android-client/app/src/androidTest/kotlin").rglob("*.kt")):
        source = file.read_text(encoding="utf-8")
        class_name = re.search(r"^class (\w+)", source, re.MULTILINE)
        tests = len(re.findall(r"@Test\b", source))
        if not class_name or not tests:
            continue
        name = PREFIX + class_name[1]
        if name == STAGING_CLASS:
            continue
        require("org.junit.Assume" not in source, "fixture_contains_assumption")
        classes.append(name)
        count += tests
    require(bool(classes) and count > 0, "fixture_inventory_empty")
    return classes, count


def prepare(root: Path, output: Path) -> None:
    require(not output.exists(), "output_already_exists")
    inputs = read_json(root / "android-client/app/build/coverage/inputs.json")
    require(
        inputs.get("version") == "astral.android-coverage-inputs/v1"
        and inputs.get("agp") == "9.2.1"
        and inputs.get("jacoco") == "0.8.14"
        and inputs.get("variant") == "coverage",
        "unsupported_build_inputs",
    )
    app = root / "android-client/app"
    agent = read_json(app / "build/coverage/unit-agent.json")
    require(
        agent
        == {
            "count": 1,
            "engine": "jacoco",
            "version": "0.8.14",
            "task": ":app:testCoverageUnitTest",
            "agp_unit_coverage": False,
        },
        "invalid_unit_agent",
    )
    classes = [inside(root, Path(path)) for path in inputs["classes"]]
    sources = [inside(root, Path(path)) for path in inputs["sources"]]
    tools = [Path(path) for path in inputs["tools"]]
    require(len(classes) > 0 and len(tools) > 0, "build_domain_empty")
    class_hashes = file_tree(root, classes)
    require(bool(class_hashes), "class_domain_empty")
    unit = unit_result(app / "build/test-results/testCoverageUnitTest")
    fixture_classes, fixture_count = fixture_inventory(root)
    artifacts = {
        "unit.exec": app / "build/kover/bin-reports/testCoverageUnitTest.exec",
        "app-coverage.apk": app / "build/outputs/apk/coverage/app-coverage.apk",
        "app-coverage-androidTest.apk": app
        / "build/outputs/apk/androidTest/coverage/app-coverage-androidTest.apk",
    }
    for name, path in artifacts.items():
        require(
            path.is_file()
            and 0 < path.stat().st_size <= (MAX_EXEC if name.endswith("exec") else MAX_APK),
            "artifact_missing_or_oversized",
        )
    output.mkdir(parents=True)
    for name, path in artifacts.items():
        shutil.copyfile(path, output / name)
    manifest = {
        "version": VERSION,
        "variant": "coverage",
        "unit_tests": unit,
        "agent": agent,
        "sources": source_tree(root),
        "class_files": class_hashes,
        "source_inputs": file_tree(root, sources, missing=True),
        "tools": {str(path): digest(path) for path in tools},
        "classes": [str(path.relative_to(root)) for path in classes],
        "source_roots": [str(path.relative_to(root)) for path in sources],
        "original_artifacts": {
            str(path.relative_to(root)): digest(path) for path in artifacts.values()
        },
        "artifacts": {name: digest(output / name) for name in artifacts},
        "fixture_classes": fixture_classes,
        "fixture_count": fixture_count,
    }
    write_json(output / "manifest.json", manifest)
    validate_ids(root, output, manifest, [output / "unit.exec"])


def verify_base(root: Path, output: Path) -> dict:
    manifest = read_json(output / "manifest.json")
    require(
        manifest.get("version") == VERSION and manifest.get("variant") == "coverage",
        "unsupported_receipt",
    )
    require(source_tree(root) == manifest["sources"], "source_changed")
    require(
        file_tree(root, [root / path for path in manifest["classes"]]) == manifest["class_files"],
        "class_domain_changed",
    )
    require(
        file_tree(root, [root / path for path in manifest["source_roots"]], missing=True)
        == manifest["source_inputs"],
        "source_domain_changed",
    )
    for path, expected in manifest["original_artifacts"].items():
        require(digest(inside(root, root / path)) == expected, "original_artifact_changed")
    for path, expected in manifest["artifacts"].items():
        require(digest(inside(output, output / path)) == expected, "retained_artifact_changed")
    for path, expected in manifest["tools"].items():
        require(digest(Path(path)) == expected, "tool_changed")
    return manifest


def validate_ids(root: Path, output: Path, manifest: dict, execution: list[Path]) -> dict:
    compiled = output / "validator"
    compiled.mkdir(exist_ok=True)
    classpath = os.pathsep.join([str(compiled), *manifest["tools"]])
    run(
        [
            java_binary("javac"),
            "-Xlint:all",
            "-Werror",
            "-cp",
            classpath,
            "-d",
            str(compiled),
            str(root / "android-client/coverage-tools/ValidateClassIds.java"),
        ]
    )
    raw = run(
        [
            java_binary("java"),
            "-cp",
            classpath,
            "ValidateClassIds",
            *map(str, execution),
            "--",
            *[str(root / path) for path in manifest["classes"]],
        ]
    )
    result = json.loads(raw)
    require(
        result.get("class_domain", 0) > 0
        and result.get("mismatches") == 0
        and len(result.get("lanes", [])) == len(execution),
        "invalid_class_closure",
    )
    return result


def adb_command(adb: str, serial: str, *args: str) -> list[str]:
    require(bool(re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", serial)), "invalid_device_serial")
    return [adb, "-s", serial, *args]


def installed_hash(adb: str, serial: str, package: str = PACKAGE) -> str:
    paths = run(adb_command(adb, serial, "shell", "pm", "path", package)).strip().splitlines()
    require(len(paths) == 1 and paths[0].startswith("package:"), "installed_apk_ambiguous")
    path = paths[0][8:]
    require(
        bool(re.fullmatch(r"/data/app/[A-Za-z0-9_./=+~-]+\.apk", path)),
        "installed_apk_path_invalid",
    )
    raw = subprocess.run(
        adb_command(adb, serial, "exec-out", "cat", path), capture_output=True, timeout=60
    )
    require(raw.returncode == 0 and 0 < len(raw.stdout) <= MAX_APK, "installed_apk_unreadable")
    return hashlib.sha256(raw.stdout).hexdigest()


def staging_arguments(file: Path | None) -> dict[str, str]:
    require(
        file is not None and file.is_file() and file.stat().st_mode & 0o077 == 0,
        "private_staging_arguments_required",
    )
    values = read_json(file)
    require(set(values) == STAGING_KEYS, "invalid_staging_argument_keys")
    require(
        all(
            isinstance(value, str) and 0 < len(value) <= 65536 and "\0" not in value
            for value in values.values()
        ),
        "invalid_staging_argument_value",
    )
    require(values["astralStagingUrl"].startswith("https://"), "staging_https_required")
    return values


def safe_instrumentation_log(log: str, values: dict[str, str]) -> str:
    token = values.get("astralAccessToken")
    if token:
        for secret in sorted(
            {token, json.dumps(token)[1:-1], repr(token)[1:-1]}, key=len, reverse=True
        ):
            log = log.replace(secret, "[REDACTED]")
    return log


def _device(
    root: Path,
    output: Path,
    adb: str,
    serial: str,
    lane: str,
    arguments: Path | None,
    attempt_id: str,
) -> None:
    require(lane in LANES, "invalid_lane")
    manifest = verify_base(root, output)
    require(
        not any(
            (output / f"{lane}.{suffix}").exists() or (output / f"{lane}.{suffix}").is_symlink()
            for suffix in ("json", "ec", "log", "started.json", "failed.json")
        ),
        "lane_already_collected",
    )
    values = staging_arguments(arguments) if lane == "staging" else {}
    require(lane == "staging" or arguments is None, "fixture_arguments_forbidden")
    write_json(
        output / f"{lane}.started.json",
        {
            "version": VERSION,
            "lane": lane,
            "manifest_sha256": digest(output / "manifest.json"),
            "attempt_id": attempt_id,
        },
    )
    if lane == "fixtures":
        for name in ("app-coverage.apk", "app-coverage-androidTest.apk"):
            run(adb_command(adb, serial, "install", "-r", str(output / name)), timeout=300)
    expected_apk = manifest["artifacts"]["app-coverage.apk"]
    require(installed_hash(adb, serial) == expected_apk, "installed_apk_changed")
    expected_test_apk = manifest["artifacts"]["app-coverage-androidTest.apk"]
    require(
        installed_hash(adb, serial, PACKAGE + ".test") == expected_test_apk,
        "installed_test_apk_changed",
    )
    remote = f"/data/user/0/{PACKAGE}/files/astral-coverage-{lane}.ec"
    run(adb_command(adb, serial, "shell", "run-as", PACKAGE, "rm", "-f", remote))
    classes = STAGING_CLASS if lane == "staging" else ",".join(manifest["fixture_classes"])
    instrument = [
        "am",
        "instrument",
        "-w",
        "-r",
        "-e",
        "coverage",
        "true",
        "-e",
        "coverageFile",
        remote,
        "-e",
        "class",
        classes,
    ]
    for key, value in sorted(values.items()):
        instrument += ["-e", key, value]
    instrument.append(TEST_PACKAGE)
    # adb shell executes a shell string: quote every value, including private IAM inputs.
    try:
        result = subprocess.run(
            adb_command(adb, serial, "shell", shlex.join(instrument)),
            capture_output=True,
            text=True,
            timeout=1800,
        )
    except (subprocess.SubprocessError, OSError, UnicodeError):
        raise InvalidCoverage("device_transport_failed") from None
    log = result.stdout + result.stderr
    log_path = output / f"{lane}.log"
    with log_path.open("x", encoding="utf-8") as stream:
        stream.write(safe_instrumentation_log(log, values))
    log_path.chmod(0o600)
    expected_count = 1 if lane == "staging" else manifest["fixture_count"]
    codes = [
        int(code)
        for code in re.findall(r"^INSTRUMENTATION_STATUS_CODE: (-?\d+)\s*$", log, re.MULTILINE)
    ]
    require(
        result.returncode == 0
        and re.search(rf"OK \({expected_count} tests?\)", log) is not None
        and codes.count(0) == expected_count
        and all(code in {0, 1} for code in codes),
        "device_tests_not_passed",
    )
    raw = subprocess.run(
        adb_command(adb, serial, "exec-out", "run-as", PACKAGE, "cat", remote),
        capture_output=True,
        timeout=60,
    )
    require(
        raw.returncode == 0 and 0 < len(raw.stdout) <= MAX_EXEC,
        "device_execution_missing_or_oversized",
    )
    with (output / f"{lane}.ec").open("xb") as stream:
        stream.write(raw.stdout)
    require(installed_hash(adb, serial) == expected_apk, "installed_apk_changed")
    expected_test_apk = manifest["artifacts"]["app-coverage-androidTest.apk"]
    require(
        installed_hash(adb, serial, PACKAGE + ".test") == expected_test_apk,
        "installed_test_apk_changed",
    )
    verify_base(root, output)
    closure = validate_ids(root, output, manifest, [output / "unit.exec", output / f"{lane}.ec"])
    write_json(
        output / f"{lane}.json",
        {
            "version": VERSION,
            "lane": lane,
            "passed": expected_count,
            "skipped": 0,
            "serial": serial,
            "installed_apk_sha256": expected_apk,
            "installed_test_apk_sha256": expected_test_apk,
            "execution_sha256": digest(output / f"{lane}.ec"),
            "log_sha256": digest(log_path),
            "manifest_sha256": digest(output / "manifest.json"),
            "started_sha256": digest(output / f"{lane}.started.json"),
            "closure": closure,
        },
    )


def device(
    root: Path, output: Path, adb: str, serial: str, lane: str, arguments: Path | None
) -> None:
    attempt_id = uuid.uuid4().hex
    try:
        _device(root, output, adb, serial, lane, arguments, attempt_id)
    except Exception:
        started = output / f"{lane}.started.json"
        failed = output / f"{lane}.failed.json"
        if (
            lane in LANES
            and started.is_file()
            and not failed.exists()
            and not failed.is_symlink()
            and read_json(started).get("attempt_id") == attempt_id
        ):
            write_json(
                failed,
                {
                    "version": VERSION,
                    "lane": lane,
                    "status": "failed",
                    "started_sha256": digest(started),
                },
            )
        raise


def verify(root: Path, output: Path, lanes: list[str]) -> tuple[dict, list[Path], dict]:
    require(bool(lanes) and len(lanes) == len(set(lanes)) and set(lanes) <= LANES, "invalid_lanes")
    manifest = verify_base(root, output)
    execution = [output / "unit.exec"]
    for lane in lanes:
        failed = output / f"{lane}.failed.json"
        require(not failed.exists() and not failed.is_symlink(), "contradictory_failed_lane")
        receipt = read_json(output / f"{lane}.json")
        expected_count = 1 if lane == "staging" else manifest["fixture_count"]
        require(
            receipt.get("version") == VERSION
            and receipt.get("lane") == lane
            and receipt.get("passed") == expected_count
            and receipt.get("skipped") == 0
            and receipt.get("manifest_sha256") == digest(output / "manifest.json")
            and receipt.get("started_sha256") == digest(output / f"{lane}.started.json")
            and receipt.get("installed_apk_sha256") == manifest["artifacts"]["app-coverage.apk"]
            and receipt.get("installed_test_apk_sha256")
            == manifest["artifacts"]["app-coverage-androidTest.apk"],
            "invalid_device_receipt",
        )
        require(
            digest(output / f"{lane}.ec") == receipt.get("execution_sha256")
            and digest(output / f"{lane}.log") == receipt.get("log_sha256"),
            "device_evidence_changed",
        )
        execution.append(output / f"{lane}.ec")
    if (output / "native-report-inputs.json").exists():
        require(
            read_json(output / "native-report-inputs.json")
            == native_inputs(root, manifest, execution, lanes),
            "native_report_inputs_changed",
        )
    return manifest, execution, validate_ids(root, output, manifest, execution)


def native_inputs(root: Path, manifest: dict, execution: list[Path], lanes: list[str]) -> dict:
    return {
        "lanes": lanes,
        "execution": list(map(str, execution)),
        "classes": [str(root / path) for path in manifest["classes"]],
        "sources": [str(root / path) for path in manifest["source_roots"]],
        "tools": list(manifest["tools"]),
    }


def report_domain(root: Path, xml: Path, manifest: dict) -> dict:
    expected = {}
    for path in manifest["sources"]:
        for directory in (
            "android-client/app/src/main/kotlin/",
            "android-client/app/src/main/java/",
        ):
            if path.startswith(directory) and path.endswith((".kt", ".java")):
                key = path.removeprefix(directory)
                require(key not in expected, "ambiguous_maintained_source")
                expected[key] = path
    require(bool(expected), "maintained_source_domain_empty")
    observed, empty = set(), []
    lines = covered = 0
    for package in ET.parse(xml).getroot().findall("package"):
        for source in package.findall("sourcefile"):
            key = "/".join(filter(None, (package.get("name"), source.get("name"))))
            if key in expected:
                require(key not in observed, "duplicate_report_source")
                require(
                    source.find("counter[@type='LINE']") is not None,
                    "maintained_source_missing_counter",
                )
                observed.add(key)
                for line in source.findall("line"):
                    total = int(line.get("mi", "0")) + int(line.get("ci", "0"))
                    if total > 0:
                        lines += 1
                        covered += int(line.get("ci", "0")) > 0
            else:
                require(
                    set(source.attrib) == {"name"}
                    and len(source) == 0
                    and not (source.text or "").strip(),
                    "unexpected_executable_source",
                )
                empty.append(key)
    require(observed == set(expected), "maintained_source_domain_mismatch")
    return {
        "maintained_sources": sorted(expected.values()),
        "empty_external_sources": sorted(empty),
        "executable_lines": lines,
        "covered_lines": covered,
    }


def report(root: Path, output: Path, lanes: list[str]) -> None:
    manifest, execution, closure = verify(root, output, lanes)
    require(not (output / "report").exists(), "report_already_exists")
    write_json(
        output / "native-report-inputs.json", native_inputs(root, manifest, execution, lanes)
    )
    run(
        [
            str(root / "android-client/gradlew"),
            "-PastralCoverage=true",
            f"-PastralCoverageReceipt={output}",
            ":app:coverageReport",
            "--no-configuration-cache",
            "--offline",
            "--console=plain",
        ],
        cwd=root / "android-client",
    )
    verify(root, output, lanes)
    xml = output / "report/report.xml"
    require(xml.is_file(), "native_report_missing")
    domain = report_domain(root, xml, manifest)
    write_json(
        output / "report.json",
        {
            "version": VERSION,
            "lanes": lanes,
            "manifest_sha256": digest(output / "manifest.json"),
            "native_inputs_sha256": digest(output / "native-report-inputs.json"),
            "report_sha256": digest(xml),
            "closure": closure,
            "raw_execution": {path.name: digest(path) for path in execution},
            "protected_staging_included": "staging" in lanes,
            "source_domain": domain,
        },
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "device", "verify", "report"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--serial")
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--lane", choices=sorted(LANES))
    parser.add_argument("--lanes", default="fixtures")
    parser.add_argument("--arguments-file", type=Path)
    args = parser.parse_args(argv)
    try:
        root = args.root.resolve()
        output = args.output.absolute()
        require(output == output.resolve(), "output_symlink_or_traversal")
        if args.command == "prepare":
            prepare(root, output)
        elif args.command == "device":
            require(
                args.serial is not None and args.lane is not None,
                "explicit_device_and_lane_required",
            )
            device(root, output, args.adb, args.serial, args.lane, args.arguments_file)
        elif args.command == "verify":
            verify(root, output, args.lanes.split(","))
        else:
            report(root, output, args.lanes.split(","))
    except (InvalidCoverage, OSError, ValueError, ET.ParseError, subprocess.SubprocessError):
        print("android_coverage_failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
