"""Tests for scripts/collect_xccov_native_domain.py (with
scripts/native_xccov_domain.py): binds binary/source/test inputs exactly, refuses
drifted or symlinked inputs, and keeps CLI failures private.
"""

from __future__ import annotations

import copy
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import time
from types import SimpleNamespace
import zipfile

import pytest

from scripts import collect_xccov_native_domain as collector
from scripts import export_xccov_line_coverage as exporter
from scripts import native_xccov_domain as domain


APP_SOURCE = domain.APP_ROOT + "Example.swift"
CORE_SOURCE = domain.CORE_ROOT + "AstralCore/Example.swift"
TEST_SOURCE = "apple-clients/AstralApp/AstralAppTests/ExampleTests.swift"
SOURCE = b"enum Example {\n static let value = 7\n}\n"


def _git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)


def _write(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(mode)


def _macho(lane):
    return struct.pack(
        "<8I", 0xFEEDFACF, 0x0100000C, 0, 8 if lane == "core" else 6, 1, 24, 0, 0
    ) + struct.pack("<6I", 0x32, 24, 7, 0x110000, 0x1A0500, 0)


def _metadata(lane):
    device = {"deviceId": "fixture-device", "architecture": "arm64", "platform": "iOS Simulator"}
    summary = {
        "result": "Passed",
        "totalTestCount": 1,
        "passedTests": 1,
        "failedTests": 0,
        "skippedTests": 0,
        "expectedFailures": 0,
        "devicesAndConfigurations": [{"device": copy.deepcopy(device)}],
    }
    bundle = {"core": "AstralCoreTests", "unit": "AstralAppTests", "ui": "AstralAppUITests"}[lane]
    tests = {
        "devices": [device],
        "testNodes": [
            {
                "name": "AstralCore" if lane == "core" else "AstralApp",
                "nodeType": "Test Plan",
                "result": "Passed",
                "children": [
                    {
                        "name": bundle,
                        "result": "Passed",
                        "children": [
                            {
                                "nodeType": "Test Case",
                                "result": "Passed",
                                "nodeIdentifier": "ExampleTests/testExample()",
                            }
                        ],
                    }
                ],
            }
        ],
    }
    return summary, tests


def _xctestrun(lane):
    if lane == "core":
        targets = [
            {
                "BlueprintName": "AstralCoreTests",
                "TestHostPath": "__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest",
                "TestBundlePath": "__TESTROOT__/" + collector.CORE,
            }
        ]
        products = [
            {
                "Name": "AstralCore",
                "IncludeInReport": True,
                "IsStatic": True,
                "ProductPaths": [
                    "__TESTROOT__/Debug-iphonesimulator/PackageFrameworks/AstralCore_-1B9_PackageProduct.framework/AstralCore_-1B9_PackageProduct"
                ],
            },
            {
                "Name": "AstralCoreTests",
                "IncludeInReport": True,
                "IsStatic": False,
                "ProductPaths": ["__TESTROOT__/" + collector.CORE + "/AstralCoreTests"],
            },
        ]
    else:
        targets = [
            {
                "BlueprintName": "AstralAppTests",
                "IsAppHostedTestBundle": True,
                "TestHostBundleIdentifier": "com.personalailabs.astraldeep",
                "TestHostPath": "__TESTROOT__/" + collector.APP,
                "TestBundlePath": "__TESTHOST__/PlugIns/AstralAppTests.xctest",
            },
            {
                "BlueprintName": "AstralAppUITests",
                "IsUITestBundle": True,
                "TestHostBundleIdentifier": "com.personalailabs.astraldeep.uitests.xctrunner",
                "TestHostPath": "__TESTROOT__/" + collector.RUNNER,
                "UITargetAppPath": "__TESTROOT__/" + collector.APP,
                "TestBundlePath": "__TESTHOST__/PlugIns/AstralAppUITests.xctest",
            },
        ]
        products = [
            {
                "Name": "AstralDeep.app",
                "IncludeInReport": True,
                "IsStatic": False,
                "ProductPaths": ["__TESTROOT__/" + collector.APP + "/AstralDeep"],
            }
        ]
    for product in products:
        product["Architectures"] = ["x86_64"]
    return {
        "TestConfigurations": [{"TestTargets": targets}],
        "CodeCoverageBuildableInfos": products,
    }


def _setup(tmp_path, monkeypatch, lane="ui", platform="ios", architecture="arm64"):
    repo = tmp_path.resolve() / "repo"
    repo.mkdir()
    for name in (APP_SOURCE, CORE_SOURCE, TEST_SOURCE):
        _write(repo / name, SOURCE, 0o644)
    _write(repo / "apple-clients/AstralApp/README.md", b"fixture\n")
    _git(repo, "init", "-q")
    _git(repo, "add", ".")
    _git(
        repo,
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@example.invalid",
        "commit",
        "-qm",
        "fixture",
    )
    products = tmp_path.resolve() / "derived/Build/Products"
    runfile = products / "Fixture_iphonesimulator26.5.xctestrun"
    _write(runfile, plistlib.dumps(_xctestrun(lane)))
    if platform == "macos":
        raw = plistlib.loads(runfile.read_bytes())
        for target in raw["TestConfigurations"][0]["TestTargets"]:
            for key in ("TestHostPath", "UITargetAppPath"):
                if key in target:
                    target[key] = target[key].replace("Debug-iphonesimulator/", "Debug/")
            target["TestBundlePath"] = target["TestBundlePath"].replace(
                "/PlugIns/", "/Contents/PlugIns/"
            )
        raw["CodeCoverageBuildableInfos"][0]["ProductPaths"] = [
            "__TESTROOT__/Debug/AstralDeep.app/Contents/MacOS/AstralDeep"
        ]
        _write(runfile, plistlib.dumps(raw))
    member = (
        domain.BINARY_MEMBERS["core" if lane == "core" else "app"]
        if platform == "ios"
        else domain.MACOS_BINARY_MEMBER
    )
    binary_path = products / member.removeprefix("Products/")
    binary_bytes = (
        _macho(lane)
        if platform == "ios"
        else struct.pack(
            "<8I",
            0xFEEDFACF,
            0x0100000C if architecture == "arm64" else 0x01000007,
            0 if architecture == "arm64" else 3,
            6,
            1,
            24,
            0,
            0,
        )
        + struct.pack("<6I", 0x32, 24, 1, 0x0E0000, 0x1A0600, 0)
    )
    _write(binary_path, binary_bytes)
    if lane == "core":
        _write(products / (collector.FOLDER + "AstralCore.o"), b"fixture static object")
    else:
        _write(
            products / (collector.APP + "/Info.plist"),
            plistlib.dumps(
                {
                    "CFBundleIdentifier": "com.personalailabs.astraldeep",
                    "CFBundleExecutable": "AstralDeep",
                    "CFBundlePackageType": "APPL",
                    "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
                }
            ),
        )
        for name in (
            collector.APP + "/AstralDeep",
            collector.APP + "/PlugIns/AstralAppTests.xctest/AstralAppTests",
            collector.RUNNER + "/AstralAppUITests-Runner",
            collector.RUNNER + "/PlugIns/AstralAppUITests.xctest/AstralAppUITests",
        ):
            _write(products / name, b"fixture executable", 0o700)
    if platform == "macos":
        for old in tuple(products.rglob("*")):
            if old.is_file() and "Debug-iphonesimulator/" in old.relative_to(products).as_posix():
                relative = (
                    old.relative_to(products).as_posix().replace("Debug-iphonesimulator/", "Debug/")
                )
                relative = relative.replace("/Info.plist", "/Contents/Info.plist").replace(
                    "/PlugIns/", "/Contents/PlugIns/"
                )
                if relative.endswith(("/AstralDeep", "/AstralAppUITests-Runner")):
                    parent, name = relative.rsplit("/", 1)
                    relative = parent + "/Contents/MacOS/" + name
                elif relative.endswith(("/AstralAppTests", "/AstralAppUITests")):
                    parent, name = relative.rsplit("/", 1)
                    relative = parent + "/Contents/MacOS/" + name
                content = old.read_bytes()
                if relative.endswith("/Info.plist"):
                    info = plistlib.loads(content)
                    info["CFBundleSupportedPlatforms"] = ["MacOSX"]
                    content = plistlib.dumps(info)
                _write(products / relative, content, old.stat().st_mode & 0o777)
                old.unlink()
    result = tmp_path.resolve() / "actual.xcresult"
    _write(result / "Data/native-observation", b"fixture raw result")
    summary, tests = _metadata(lane)
    if platform == "macos":
        for device in (summary["devicesAndConfigurations"][0]["device"], tests["devices"][0]):
            device.update(platform="macOS", architecture=architecture)
    calls = []
    original_run = exporter._bounded_command
    state = {
        "hook": lambda: None,
        "query_hook": lambda path: None,
        "summary": summary,
        "tests": tests,
        "query_paths": [],
        "stderr": b"",
        "returncode": 0,
    }

    def run(command, **kwargs):
        calls.append(command)
        if command[0] == "git":
            return original_run(command, **kwargs)
        if command[0] == "/usr/bin/xcodebuild":
            assert command == ["/usr/bin/xcodebuild", "-version"]
            return b"Xcode 26.6\nBuild version 17F113\n"
        if command[1] == "xcresulttool":
            assert command[2:4] == ["get", "test-results"]
            assert command[5:-1] == ["--schema-version", "0.1.0", "--compact", "--path"]
            copied = Path(command[-1])
            assert copied != result and copied.name == "Result.xcresult"
            assert copied.parent.stat().st_mode & 0o777 == 0o700
            state["query_paths"].append(copied)
            state["query_hook"](copied)
            return state.get("raw_" + command[4], json.dumps(state[command[4]]).encode())
        if command[2:] == ["--version"]:
            return b"Apple LLVM version 21.0.0\n"
        assert command[:6] == [
            "/usr/bin/xcrun",
            "llvm-cov",
            "export",
            "--empty-profile",
            "--arch=" + architecture,
            command[5],
        ]
        assert Path(command[5]).read_bytes() == binary_bytes
        assert Path(command[5]) != binary_path
        state["hook"]()
        paths = [CORE_SOURCE] if lane == "core" else [APP_SOURCE, CORE_SOURCE]
        filenames = [str(repo / path) for path in paths]
        mapping = {
            "type": "llvm.coverage.json.export",
            "version": "3.0.1",
            "data": [
                {
                    "files": [{"filename": name, "segments": []} for name in filenames],
                    "functions": [
                        {
                            "name": "$fixture" + str(index),
                            "count": 0,
                            "filenames": [name],
                            "regions": [[2, 2, 2, 22, 0, 0, 0, 0]],
                            "branches": [],
                            "mcdc_records": [],
                        }
                        for index, name in enumerate(filenames)
                    ],
                    "totals": {},
                }
            ],
        }
        return json.dumps(mapping).encode()

    monkeypatch.setattr(exporter, "_bounded_command", run)
    monkeypatch.setattr(
        collector,
        "_metadata_command",
        lambda command, **kwargs: {
            "stdout": run(command, **kwargs),
            "stderr": state["stderr"],
            "returncode": state.get("returncodes", {}).get(command[4], state["returncode"]),
            "failure": None,
            "stdout_truncated": False,
            "stderr_truncated": False,
        },
        raising=False,
    )
    monkeypatch.setattr(
        collector,
        "_module",
        lambda name: {"native_xccov_domain": domain, "export_xccov_line_coverage": exporter}[name],
    )
    kwargs = {
        "repo": repo,
        "products": products,
        "xcresult": result,
        "lane": lane,
        "output": tmp_path.resolve() / "out/domain.json",
        "binary_archive": tmp_path.resolve()
        / f"out/coverage/native-binaries/apple-{platform}-{lane}.zip",
    }
    if platform != "ios":
        kwargs["platform"] = platform
    return kwargs, state, runfile, binary_path, calls


@pytest.mark.parametrize("lane", ("core", "unit", "ui"))
def test_fixed_lane_collection_retains_exact_binary_and_intermediate_domain(
    tmp_path, monkeypatch, lane
):
    kwargs, _, _, binary, calls = _setup(tmp_path, monkeypatch, lane)
    result = collector.collect(**kwargs)
    assert result == json.loads(kwargs["output"].read_bytes())
    assert result["lane"] == lane and result["platform"] == "ios"
    assert result["observed_sources"] == sorted(result["sources"])
    assert result["binary"]["sha256"] == hashlib.sha256(binary.read_bytes()).hexdigest()
    assert (
        result["binary"]["artifact_sha256"]
        == hashlib.sha256(kwargs["binary_archive"].read_bytes()).hexdigest()
    )
    with zipfile.ZipFile(kwargs["binary_archive"]) as bundle:
        assert bundle.namelist() == [result["binary"]["member"]]
        assert bundle.read(result["binary"]["member"]) == binary.read_bytes()
    assert all("executionCount" not in facts for facts in result["sources"].values())
    assert not any("test" in command or "build" in command for command in calls)
    assert all(
        facts["native_last_line"] == 2 and facts["physical_lines"] == 3
        for facts in result["sources"].values()
    )


@pytest.mark.parametrize(
    "change",
    (
        "missing",
        "extra",
        "host",
        "target",
        "coverage",
        "traversal",
        "not-list",
        "not-object",
        "configurations",
    ),
)
@pytest.mark.parametrize("lane", ("core", "ui"))
def test_invalid_generated_test_binding_refuses_before_retaining_a_witness(
    tmp_path, monkeypatch, change, lane
):
    kwargs, _, runfile, _, _ = _setup(tmp_path, monkeypatch, lane)
    doc = plistlib.loads(runfile.read_bytes())
    if change == "missing":
        runfile.unlink()
    elif change == "extra":
        _write(runfile.with_name("Other.xctestrun"), runfile.read_bytes())
    else:
        target = doc["TestConfigurations"][0]["TestTargets"][0]
        if change == "host":
            target["TestHostPath"] = "__TESTROOT__/Debug-iphonesimulator/Other.app"
        elif change == "target":
            target["BlueprintName"] = "OtherTests"
        elif change == "coverage":
            doc["CodeCoverageBuildableInfos"][-1]["IncludeInReport"] = False
        elif change == "traversal":
            target["TestBundlePath"] = "__TESTROOT__/../Other.xctest"
        elif change == "not-list":
            doc["CodeCoverageBuildableInfos"] = {}
        elif change == "not-object":
            doc = []
        else:
            doc["TestConfigurations"] = [{}]
        _write(runfile, plistlib.dumps(doc))
    with pytest.raises((collector.CollectionError, KeyError)):
        collector.collect(**kwargs)
    assert not kwargs["output"].exists() and not kwargs["binary_archive"].exists()


@pytest.mark.parametrize(
    "change",
    (
        "dirty",
        "untracked",
        "staged",
        "mode",
        "symlink",
        "commit-race",
        "binary-race",
        "metadata-race",
        "result-race",
    ),
)
def test_source_and_native_inputs_must_remain_bound_before_and_after_mapping(
    tmp_path, monkeypatch, change
):
    kwargs, state, runfile, binary, _ = _setup(tmp_path, monkeypatch)
    source = kwargs["repo"] / APP_SOURCE
    if change == "dirty":
        source.write_bytes(SOURCE + b"// changed\n")
    elif change == "untracked":
        _write(source.with_name("Injected.swift"), SOURCE)
    elif change == "staged":
        _write(source.with_name("Injected.swift"), SOURCE)
        _git(kwargs["repo"], "add", ".")
    elif change == "mode":
        source.chmod(0o755)
    elif change == "symlink":
        source.unlink()
        source.symlink_to(kwargs["repo"] / CORE_SOURCE)
    elif change == "commit-race":
        state["hook"] = lambda: _git(
            kwargs["repo"],
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "--allow-empty",
            "-qm",
            "new head",
        )
    elif change == "binary-race":
        state["hook"] = lambda: binary.write_bytes(binary.read_bytes() + b"changed")
    elif change == "metadata-race":
        state["hook"] = lambda: runfile.write_bytes(runfile.read_bytes() + b"\n")
    else:
        state["hook"] = lambda: (kwargs["xcresult"] / "Data/native-observation").write_bytes(
            b"changed"
        )
    with pytest.raises((collector.CollectionError, exporter.ExportError)) as refused:
        collector.collect(**kwargs)
    assert refused.value.collection_stage == {
        "commit-race": "source_after",
        "binary-race": "products_after",
        "metadata-race": "products_after",
        "result-race": "result_after",
    }.get(change, "source_before")
    assert not kwargs["output"].exists()


@pytest.mark.parametrize("change", ("architecture", "failed", "staging", "platform", "macho"))
def test_real_native_metadata_and_binary_policy_are_not_replaced_by_xctestrun(
    tmp_path, monkeypatch, change
):
    kwargs, state, _, binary, _ = _setup(tmp_path, monkeypatch)
    if change == "architecture":
        state["summary"]["devicesAndConfigurations"][0]["device"]["architecture"] = "x86_64"
    elif change == "failed":
        state["summary"]["result"] = "Failed"
    elif change == "staging":
        state["tests"]["testNodes"][0]["children"][0]["children"][0]["nodeIdentifier"] = (
            "ReleaseEvidenceUITests/testReleaseEvidenceProducesPlatformReport()"
        )
    elif change == "platform":
        state["tests"]["devices"][0]["platform"] = "macOS"
    else:
        binary.write_bytes(b"launcher without coverage")
    with pytest.raises(domain.DomainError):
        collector.collect(**kwargs)
    assert not kwargs["output"].exists() and kwargs["binary_archive"].exists()


@pytest.mark.parametrize(
    "change",
    (
        "bundle-id",
        "device-info",
        "missing-test",
        "non-executable",
        "symbolic-binary",
        "linked-parent",
    ),
)
def test_shipping_product_paths_cannot_be_replaced_by_other_bundles_or_links(
    tmp_path, monkeypatch, change
):
    kwargs, _, _, binary, _ = _setup(tmp_path, monkeypatch)
    info_path = kwargs["products"] / (collector.APP + "/Info.plist")
    if change in {"bundle-id", "device-info"}:
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleIdentifier" if change == "bundle-id" else "CFBundleSupportedPlatforms"] = (
            "untrusted" if change == "bundle-id" else ["iPhoneOS"]
        )
        info_path.write_bytes(plistlib.dumps(info))
    elif change == "missing-test":
        (
            kwargs["products"] / (collector.APP + "/PlugIns/AstralAppTests.xctest/AstralAppTests")
        ).unlink()
    elif change == "non-executable":
        (kwargs["products"] / (collector.APP + "/AstralDeep")).chmod(0o600)
    elif change == "symbolic-binary":
        saved = binary.with_name("renamed")
        binary.rename(saved)
        binary.symlink_to(saved)
    else:
        alias = tmp_path / "linked"
        alias.symlink_to(kwargs["products"].parent, target_is_directory=True)
        kwargs["products"] = alias / "Products"
    with pytest.raises((collector.CollectionError, FileNotFoundError)):
        collector.collect(**kwargs)
    assert not kwargs["output"].exists()


@pytest.mark.parametrize(
    "change",
    (
        "output-exists",
        "archive-exists",
        "wrong-name",
        "same-path",
        "nested-output",
        "relative",
        "wrong-lane",
        "wrong-result",
    ),
)
def test_outputs_are_create_only_and_cannot_alias_inputs(tmp_path, monkeypatch, change):
    kwargs, _, _, _, _ = _setup(tmp_path, monkeypatch)
    if change == "output-exists":
        _write(kwargs["output"], b"prior receipt")
    elif change == "archive-exists":
        _write(kwargs["binary_archive"], b"prior archive")
    elif change == "wrong-name":
        kwargs["binary_archive"] = kwargs["binary_archive"].with_name("other.zip")
    elif change == "same-path":
        kwargs["output"] = kwargs["binary_archive"]
    elif change == "nested-output":
        kwargs["output"] = kwargs["xcresult"] / "new.json"
    elif change == "relative":
        kwargs["products"] = Path("relative/Products")
    elif change == "wrong-lane":
        kwargs["lane"] = "macos"
    else:
        kwargs["xcresult"] = kwargs["products"]
    with pytest.raises(collector.CollectionError):
        collector.collect(**kwargs)
    if change == "output-exists":
        assert kwargs["output"].read_bytes() == b"prior receipt"
    if change == "archive-exists":
        assert kwargs["binary_archive"].read_bytes() == b"prior archive"


def test_raw_result_tree_bounds_deadline_and_symlink_refusal(tmp_path, monkeypatch):
    root = tmp_path.resolve() / "result.xcresult"
    _write(root / "nested/data", b"native")
    with pytest.raises(collector.CollectionError):
        collector._tree(root, time.monotonic() - 1)
    monkeypatch.setattr(collector, "MAX_TREE", 2)
    with pytest.raises(collector.CollectionError):
        collector._tree(root, time.monotonic() + 1)
    monkeypatch.setattr(collector, "MAX_TREE", 1000)
    monkeypatch.setattr(collector, "MAX_ENTRIES", 1)
    with pytest.raises(collector.CollectionError):
        collector._tree(root, time.monotonic() + 1)
    monkeypatch.setattr(collector, "MAX_ENTRIES", 10)
    (root / "alias").symlink_to(root / "nested/data")
    with pytest.raises(collector.CollectionError):
        collector._tree(root, time.monotonic() + 1)
    with pytest.raises(collector.CollectionError):
        collector._read(root / "nested/data", limit=1)


def test_cli_fixed_sibling_import_and_stable_data_free_refusal(tmp_path, capsys):
    assert collector._module("native_xccov_domain").DOMAIN_FORMAT == domain.DOMAIN_FORMAT
    assert (
        collector._module("export_xccov_line_coverage").MAX_SOURCE_LINES
        == exporter.MAX_SOURCE_LINES
    )
    args = ["--lane", "ui"]
    for name in ("repo", "products", "xcresult", "output", "binary-archive"):
        args += ["--" + name, str(tmp_path.resolve() / "PRIVATE")]
    assert collector.main(args) == 1
    assert capsys.readouterr().err == (
        "native_xccov_collection_invalid\nnative_xccov_collection_stage=inputs\n"
    )


@pytest.mark.parametrize("stage", sorted(collector.STAGES))
def test_cli_stage_diagnostic_keeps_exception_details_private(tmp_path, monkeypatch, capsys, stage):
    private = "PRIVATE path /credential?token=SECRET\nforged_stage=passed"
    error = RuntimeError(private)

    def refuse(**kwargs):
        with collector._stage(stage):
            raise error

    monkeypatch.setattr(collector, "collect", refuse)
    args = ["--lane", "core"]
    for name in ("repo", "products", "xcresult", "output", "binary-archive"):
        args += ["--" + name, str(tmp_path / "PRIVATE")]
    assert collector.main(args) == 1
    assert capsys.readouterr().err == (
        "native_xccov_collection_invalid\nnative_xccov_collection_stage=" + stage + "\n"
    )
    assert str(error) == private and type(error) is RuntimeError


@pytest.mark.parametrize("stage", ("PRIVATE\nforged", ["mapping"], None))
def test_cli_does_not_print_untrusted_exception_stage(tmp_path, monkeypatch, capsys, stage):
    def refuse(**kwargs):
        error = RuntimeError("SECRET")
        error.collection_stage = stage
        raise error

    monkeypatch.setattr(collector, "collect", refuse)
    args = ["--lane", "core"]
    for name in ("repo", "products", "xcresult", "output", "binary-archive"):
        args += ["--" + name, str(tmp_path / "PRIVATE")]
    assert collector.main(args) == 1
    assert capsys.readouterr().err == (
        "native_xccov_collection_invalid\nnative_xccov_collection_stage=inputs\n"
    )


def test_cli_success_uses_identical_explicit_arguments(tmp_path, monkeypatch):
    kwargs, _, _, _, _ = _setup(tmp_path, monkeypatch)
    args = []
    for key, value in kwargs.items():
        args += ["--" + key.replace("_", "-"), str(value)]
    assert collector.main(args) == 0
    assert json.loads(kwargs["output"].read_bytes())["lane"] == "ui"


def test_git_assume_unchanged_cannot_hide_different_head_blob_bytes(tmp_path, monkeypatch):
    kwargs, _, _, _, _ = _setup(tmp_path, monkeypatch)
    _git(kwargs["repo"], "update-index", "--assume-unchanged", APP_SOURCE)
    (kwargs["repo"] / APP_SOURCE).write_bytes(SOURCE + b"// hidden local edit\n")
    with pytest.raises(collector.CollectionError):
        collector.collect(**kwargs)
    assert not kwargs["output"].exists() and not kwargs["binary_archive"].exists()


def test_lazy_native_cache_is_private_and_original_result_remains_exact(tmp_path, monkeypatch):
    kwargs, state, _, _, _ = _setup(tmp_path, monkeypatch, "core")
    original = collector._tree(kwargs["xcresult"], time.monotonic() + 10)

    def query(copied):
        assert (copied / "Data/native-observation").read_bytes() == b"fixture raw result"
        (copied / "database.sqlite3").write_bytes(b"tool-generated query cache")

    state["query_hook"] = query
    assert collector.collect(**kwargs)["lane"] == "core"
    assert collector._tree(kwargs["xcresult"], time.monotonic() + 10) == original
    assert len(state["query_paths"]) == 2
    assert not any(path.parent.exists() for path in state["query_paths"])


@pytest.mark.parametrize("failure", ("timeout", "cancel", "original-changed"))
def test_query_copy_is_removed_on_refusal_timeout_and_cancellation(tmp_path, monkeypatch, failure):
    kwargs, state, _, _, _ = _setup(tmp_path, monkeypatch, "core")

    def query(copied):
        (copied / "database.sqlite3").write_bytes(b"partial query cache")
        if failure == "timeout":
            raise exporter.ExportError("producer_timeout", "PRIVATE")
        if failure == "cancel":
            raise KeyboardInterrupt()
        (kwargs["xcresult"] / "Data/native-observation").write_bytes(b"replaced raw observation")

    state["query_hook"] = query
    expected = {"timeout": exporter.ExportError, "cancel": KeyboardInterrupt}.get(
        failure, collector.CollectionError
    )
    with pytest.raises(expected):
        collector.collect(**kwargs)
    assert state["query_paths"] and not any(path.parent.exists() for path in state["query_paths"])
    assert not kwargs["output"].exists()


@pytest.mark.parametrize("change", ("content", "mode", "symlink", "deadline"))
def test_query_copy_refuses_changed_inventory_before_native_tool(tmp_path, monkeypatch, change):
    result = tmp_path.resolve() / "raw.xcresult"
    source = result / "Data/native-observation"
    _write(source, b"original")
    inventory = collector._tree(result, time.monotonic() + 10)
    if change == "content":
        source.write_bytes(b"changed")
    elif change == "mode":
        source.chmod(0o755)
    elif change == "symlink":
        outside = tmp_path.resolve() / "outside"
        _write(outside, b"original")
        source.unlink()
        source.symlink_to(outside)
    calls = []
    with pytest.raises(collector.CollectionError) as refused:
        collector._test_documents(
            result,
            inventory,
            domain,
            lambda *args: calls.append(args),
            time.monotonic() + (-1 if change == "deadline" else 10),
        )
    assert refused.value.collection_stage == "result_copy"
    assert calls == []


@pytest.mark.parametrize("lane", ["unit", "ui"])
@pytest.mark.parametrize("architecture", ["arm64", "x86_64"])
def test_macos_collection_derives_mapping_architecture_from_exact_native_member(
    tmp_path, monkeypatch, lane, architecture
):
    kwargs, _, _, binary, calls = _setup(tmp_path, monkeypatch, lane, "macos", architecture)
    result = collector.collect(**kwargs)
    assert result["format"] == domain.MACOS_DOMAIN_FORMAT
    assert result["platform"] == "macos" and result["architecture"] == architecture
    assert result["binary"]["member"] == domain.MACOS_BINARY_MEMBER
    assert result["binary"]["sha256"] == domain.sha256(binary.read_bytes())
    assert any("--arch=" + architecture in call for call in calls)
    with zipfile.ZipFile(kwargs["binary_archive"]) as bundle:
        assert bundle.namelist() == [domain.MACOS_BINARY_MEMBER]
        assert bundle.read(domain.MACOS_BINARY_MEMBER) == binary.read_bytes()


@pytest.mark.parametrize(
    "mutation",
    [
        "metadata_arch",
        "metadata_platform",
        "core",
        "plist",
        "host",
        "coverage",
        "binary",
        "artifact",
    ],
)
def test_macos_collection_rejects_foreign_platform_or_architecture_and_layout(
    tmp_path, monkeypatch, mutation
):
    kwargs, state, runfile, binary, _ = _setup(tmp_path, monkeypatch, "unit", "macos")
    if mutation == "metadata_arch":
        state["tests"]["devices"][0]["architecture"] = "x86_64"
    elif mutation == "metadata_platform":
        state["summary"]["devicesAndConfigurations"][0]["device"]["platform"] = "iOS Simulator"
    elif mutation == "core":
        kwargs["lane"] = "core"
    elif mutation == "artifact":
        kwargs["binary_archive"] = kwargs["binary_archive"].with_name("apple-ios-unit.zip")
    elif mutation == "binary":
        binary.write_bytes(_macho("unit"))
    elif mutation == "plist":
        path = kwargs["products"] / "Debug/AstralDeep.app/Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
        path.write_bytes(plistlib.dumps(info))
    else:
        doc = plistlib.loads(runfile.read_bytes())
        if mutation == "host":
            doc["TestConfigurations"][0]["TestTargets"][0]["TestBundlePath"] = (
                "__TESTHOST__/PlugIns/AstralAppTests.xctest"
            )
        else:
            doc["CodeCoverageBuildableInfos"][0]["ProductPaths"] = [
                "__TESTROOT__/Debug/AstralDeep.app/AstralDeep"
            ]
        runfile.write_bytes(plistlib.dumps(doc))
    with pytest.raises((collector.CollectionError, domain.DomainError)):
        collector.collect(**kwargs)
    assert not kwargs["output"].exists()


@pytest.mark.parametrize(
    "failure,stage",
    [
        ("exit", "summary_query"),
        ("json", "summary_json"),
        ("tests_exit", "tests_query"),
        ("tests_json", "tests_json"),
        ("identity", "test_identity"),
        ("binary", "native_binary"),
    ],
)
def test_failed_metadata_retains_bounded_raw_diagnostics_and_selected_binary(
    tmp_path, monkeypatch, capsys, failure, stage
):
    kwargs, state, _, binary, _ = _setup(tmp_path, monkeypatch, "unit", "macos")
    if failure == "exit":
        state["returncode"] = 7
        state["stderr"] = b"PRIVATE raw tool stderr\n"
    elif failure == "json":
        state["raw_summary"] = b'{"result":"Passed","result":"Failed"}'
    elif failure == "tests_exit":
        state["returncodes"] = {"tests": 9}
    elif failure == "tests_json":
        state["raw_tests"] = b"not JSON\x00"
    elif failure == "identity":
        state["summary"]["result"] = "Failed"
    else:
        binary.write_bytes(b"PRIVATE invalid native binary")
    args = [
        item for key, value in kwargs.items() for item in ("--" + key.replace("_", "-"), str(value))
    ]
    assert collector.main(args) == 1
    assert capsys.readouterr().err == (
        "native_xccov_collection_invalid\nnative_xccov_collection_stage=" + stage + "\n"
    )
    assert not kwargs["output"].exists()
    with zipfile.ZipFile(kwargs["binary_archive"]) as archive:
        assert archive.read(domain.MACOS_BINARY_MEMBER) == binary.read_bytes()
    diagnostic = Path(str(kwargs["output"]) + ".diagnostics")
    assert diagnostic.stat().st_mode & 0o777 == 0o700
    assert (diagnostic / "summary.stdout").read_bytes() == state.get(
        "raw_summary", json.dumps(state["summary"]).encode()
    )
    assert (diagnostic / "summary.stderr").read_bytes() == state["stderr"]
    status = json.loads((diagnostic / "summary.status.json").read_bytes())
    assert status["returncode"] == state["returncode"]
    assert json.loads((diagnostic / "stage.json").read_bytes()) == {
        "stage": stage,
        "accepted": False,
    }
    assert all(path.stat().st_mode & 0o777 == 0o600 for path in diagnostic.iterdir())


@pytest.mark.parametrize(
    "kind",
    [
        "existing",
        "symlink",
        "directory-replacement",
        "parent-replacement",
        "file-symlink",
        "hardlink",
    ],
)
def test_diagnostic_namespace_is_exclusive_and_cannot_redirect_writes(tmp_path, monkeypatch, kind):
    kwargs, state, _, _, _ = _setup(tmp_path, monkeypatch, "core")
    diagnostic = Path(str(kwargs["output"]) + ".diagnostics")
    outside = tmp_path / "outside"
    _write(outside / "unchanged", b"outside marker")
    if kind == "existing":
        _write(diagnostic / "prior", b"prior diagnostic")
    elif kind == "symlink":
        diagnostic.parent.mkdir(parents=True, exist_ok=True)
        diagnostic.symlink_to(outside, target_is_directory=True)
    else:

        def replace(_):
            if kind == "file-symlink":
                (diagnostic / "summary.stdout").symlink_to(outside / "unchanged")
                return
            if kind == "hardlink":
                os.link(outside / "unchanged", diagnostic / "summary.stdout")
                return
            target = diagnostic if kind == "directory-replacement" else diagnostic.parent
            target.rename(target.with_name(target.name + "-captured"))
            target.symlink_to(outside, target_is_directory=True)

        state["query_hook"] = replace
    with pytest.raises(collector.CollectionError):
        collector.collect(**kwargs)
    assert sorted(path.name for path in outside.iterdir()) == ["unchanged"]
    assert (outside / "unchanged").read_bytes() == b"outside marker"


@pytest.mark.parametrize("stream", ["stdout", "stderr"])
def test_metadata_capture_has_independent_byte_bounds_and_does_not_print_payload(
    tmp_path, capsys, stream
):
    command = [sys.executable, "-c", "import sys;sys." + stream + ".write('PRIVATE' * 20)"]
    captured = collector._metadata_command(
        command,
        cwd=tmp_path,
        max_stdout_bytes=32,
        max_stderr_bytes=16,
        export_deadline=time.monotonic() + 10,
    )
    assert captured["failure"] == "producer_output_too_large"
    assert len(captured["stdout"]) <= 32 and len(captured["stderr"]) <= 16
    assert captured[stream + "_truncated"] is True
    assert capsys.readouterr() == ("", "")


def test_metadata_group_leader_is_reserved_until_owned_group_cleanup(tmp_path, monkeypatch):
    processes = []
    ordering = []
    popen, killpg = subprocess.Popen, os.killpg

    def start(*args, **kwargs):
        process = popen(*args, **kwargs)
        processes.append(process)
        wait = process.wait

        def reap(*args, **kwargs):
            ordering.append("reap")
            return wait(*args, **kwargs)

        process.wait = reap
        return process

    def stop(group, sig):
        assert ordering == [] and processes[0].returncode is None
        assert os.getpgid(group) == group
        ordering.append("kill")
        killpg(group, sig)

    monkeypatch.setattr(collector.subprocess, "Popen", start)
    monkeypatch.setattr(collector.os, "killpg", stop)
    captured = collector._metadata_command(
        [sys.executable, "-c", "print('actual worker')"],
        cwd=tmp_path,
        max_stdout_bytes=32,
        max_stderr_bytes=32,
        export_deadline=time.monotonic() + 10,
    )
    assert captured["returncode"] == 0 and captured["failure"] is None
    assert captured["stdout"] == b"actual worker\n"
    assert ordering == ["kill", "reap"] and processes[0].returncode == -9


def test_metadata_supervisor_uses_an_exact_private_source_snapshot(tmp_path, monkeypatch):
    popen = subprocess.Popen
    observed = []
    source = Path(collector.__file__).read_bytes()
    output = collector._exclusive_output

    @contextmanager
    def snapshot_output(path):
        observed.append(path)
        with output(path) as stream:
            yield stream

    def start(arguments, **kwargs):
        assert arguments[:3] == [sys.executable, "-I", "-S"]
        snapshot = observed[0]
        source_fd = int(arguments[3].removeprefix("/dev/fd/"))
        assert arguments[3] == "/dev/fd/" + str(source_fd)
        assert source_fd in kwargs["pass_fds"]
        assert os.pread(source_fd, len(source) + 1, 0) == source
        assert snapshot != Path(collector.__file__)
        assert snapshot.read_bytes() == source
        assert snapshot.stat().st_mode & 0o777 == 0o400
        assert snapshot.parent.stat().st_mode & 0o777 == 0o700
        assert len(kwargs["pass_fds"]) == 3 and kwargs["stdin"] == subprocess.DEVNULL
        return popen(arguments, **kwargs)

    monkeypatch.setattr(collector, "_exclusive_output", snapshot_output)
    monkeypatch.setattr(collector.subprocess, "Popen", start)
    captured = collector._metadata_command(
        [sys.executable, "-c", "import pathlib;print(pathlib.Path.cwd().name)"],
        cwd=tmp_path,
        max_stdout_bytes=1024,
        max_stderr_bytes=32,
        export_deadline=time.monotonic() + 10,
    )
    assert captured["stdout"] == (tmp_path.name + "\n").encode()
    assert captured["returncode"] == 0 and captured["failure"] is None
    assert len(observed) == 1 and not observed[0].exists()


def test_metadata_timeout_cleans_owned_descendants_after_parent_exit(tmp_path, monkeypatch):
    marker = tmp_path / "owned-child-pid"
    child = """import os,time,pathlib,sys
parent=int(sys.argv[2])
while os.getppid()==parent:
    time.sleep(0.001)
pathlib.Path(sys.argv[1]).write_text(str(os.getpid())+','+str(os.getpgrp()))
print('ready',flush=True)
time.sleep(60)
"""
    parent = "import os,subprocess,sys;subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[2],str(os.getpid())])"
    clock = time.monotonic
    deadline = clock() + 20
    signals = []
    killpg = os.killpg

    def signal_owned_group(group, sig):
        pid, expected = map(int, marker.read_text().split(","))
        assert group == expected == os.getpgid(pid)
        signals.append((group, sig))
        killpg(group, sig)

    monkeypatch.setattr(
        collector,
        "time",
        SimpleNamespace(monotonic=lambda: deadline + 1 if marker.exists() else clock()),
    )
    monkeypatch.setattr(collector.os, "killpg", signal_owned_group)
    try:
        captured = collector._metadata_command(
            [sys.executable, "-c", parent, child, str(marker)],
            cwd=tmp_path,
            max_stdout_bytes=32,
            max_stderr_bytes=1024,
            export_deadline=deadline,
        )
    finally:
        if not signals and marker.exists():
            pid, group = map(int, marker.read_text().split(","))
            if os.getpgid(pid) == group:
                killpg(group, 9)
    assert captured["failure"] == "export_timeout" and captured["returncode"] == 0
    assert len(signals) == 1 and signals[0][1] == 9


def test_metadata_cancellation_cleans_process_and_preserves_fixed_capture(tmp_path, monkeypatch):
    process = []
    popen = subprocess.Popen
    selector = collector.selectors.DefaultSelector()

    def start(*args, **kwargs):
        value = popen(*args, **kwargs)
        process.append(value)
        return value

    def cancel(_):
        raise KeyboardInterrupt()

    monkeypatch.setattr(collector.subprocess, "Popen", start)
    monkeypatch.setattr(selector, "select", cancel)
    monkeypatch.setattr(collector.selectors, "DefaultSelector", lambda: selector)
    with pytest.raises(KeyboardInterrupt) as interrupted:
        collector._metadata_command(
            [sys.executable, "-c", "import time;time.sleep(60)"],
            cwd=tmp_path,
            max_stdout_bytes=32,
            max_stderr_bytes=32,
            export_deadline=time.monotonic() + 10,
        )
    assert process[0].poll() is not None
    assert interrupted.value.metadata_capture["failure"] == "producer_cancelled"
    assert interrupted.value.metadata_capture["returncode"] is None


def test_metadata_capture_preserves_nonzero_exit_stderr_and_unavailable_tool(tmp_path):
    captured = collector._metadata_command(
        [sys.executable, "-c", "import sys;print('raw');sys.stderr.write('PRIVATE');sys.exit(7)"],
        cwd=tmp_path,
        max_stdout_bytes=32,
        max_stderr_bytes=32,
        export_deadline=time.monotonic() + 10,
    )
    assert captured["returncode"] == 7 and captured["failure"] is None
    assert captured["stdout"] == b"raw\n" and captured["stderr"] == b"PRIVATE"
    unavailable = collector._metadata_command(
        [str(tmp_path / "PRIVATE-missing")],
        cwd=tmp_path,
        max_stdout_bytes=32,
        max_stderr_bytes=32,
        export_deadline=time.monotonic() + 10,
    )
    assert unavailable["failure"] == "producer_unavailable"
    assert unavailable["stderr"] == b"" and unavailable["returncode"] is None


@pytest.mark.parametrize("missing", [False, True])
def test_metadata_supervisor_reports_only_actual_worker_status_and_closes_private_fds(
    tmp_path, monkeypatch, missing
):
    monkeypatch.chdir(tmp_path)
    read_fd, write_fd = os.pipe()
    directory_fd = os.open(tmp_path, os.O_RDONLY | os.O_DIRECTORY)
    command = (
        [str(tmp_path / "unavailable")]
        if missing
        else [
            sys.executable,
            "-c",
            "import os,pathlib,sys; "
            "closed=[]\n"
            "for fd in map(int,sys.argv[1:]):\n"
            " try: os.fstat(fd)\n"
            " except OSError: closed.append(fd)\n"
            "pathlib.Path('worker').write_text(str(len(closed)));sys.exit(23)",
            str(write_fd),
            str(directory_fd),
        ]
    )
    collector._metadata_supervise(write_fd, directory_fd, command)
    with os.fdopen(read_fd, "rb") as stream:
        assert stream.read(17) == (b"unavailable\n" if missing else b"23\n")
    with pytest.raises(OSError):
        os.fstat(directory_fd)
    if not missing:
        assert (tmp_path / "worker").read_text() == "2"


def test_metadata_success_cleans_a_descendant_with_detached_output(tmp_path, monkeypatch):
    marker = tmp_path / "child.json"
    script = (
        "import json,os,pathlib,subprocess,sys; "
        "child=subprocess.Popen([sys.executable,'-c','import signal;signal.pause()'],"
        "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); "
        "pathlib.Path(sys.argv[1]).write_text(json.dumps({'pid':child.pid,"
        "'pgid':os.getpgid(child.pid),'sid':os.getsid(child.pid)}));print('done')"
    )
    groups = []
    killpg = os.killpg

    def stop(group, sig):
        owned = json.loads(marker.read_bytes())
        assert os.getpgid(owned["pid"]) == owned["pgid"] == group
        assert os.getsid(owned["pid"]) == owned["sid"] == group
        groups.append(group)
        killpg(group, sig)

    monkeypatch.setattr(collector.os, "killpg", stop)
    try:
        captured = collector._metadata_command(
            [sys.executable, "-c", script, str(marker)],
            cwd=tmp_path,
            max_stdout_bytes=32,
            max_stderr_bytes=32,
            export_deadline=time.monotonic() + 10,
        )
        assert captured["returncode"] == 0 and captured["failure"] is None
        assert captured["stdout"] == b"done\n" and len(groups) == 1
        owned = json.loads(marker.read_bytes())
        state = subprocess.run(
            ["ps", "-o", "state=", "-p", str(owned["pid"])],
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()
        assert not state or state.startswith("Z")
    finally:
        if not groups and marker.exists():
            owned = json.loads(marker.read_bytes())
            if os.getpgid(owned["pid"]) == owned["pgid"]:
                killpg(owned["pgid"], 9)


def test_metadata_worker_early_pipe_closure_keeps_its_nonzero_exit(tmp_path):
    captured = collector._metadata_command(
        [
            sys.executable,
            "-c",
            "import os,pathlib,sys;os.close(1);os.close(2);"
            "pathlib.Path('finished').write_bytes(b'actual');sys.exit(23)",
        ],
        cwd=tmp_path,
        max_stdout_bytes=32,
        max_stderr_bytes=32,
        export_deadline=time.monotonic() + 10,
    )
    assert captured["returncode"] == 23 and captured["failure"] is None
    assert captured["stdout"] == captured["stderr"] == b""
    assert (tmp_path / "finished").read_bytes() == b"actual"


@pytest.mark.parametrize("mode", ["export", "producer", "interrupt"])
def test_metadata_early_pipe_closure_does_not_leave_a_live_worker(tmp_path, monkeypatch, mode):
    marker = tmp_path / "worker.json"
    script = (
        "import json,os,pathlib,signal,sys; "
        "pathlib.Path(sys.argv[1]).write_text(json.dumps({'pid':os.getpid(),"
        "'pgid':os.getpgrp(),'sid':os.getsid(0)})); "
        "os.kill(os.getppid(),signal.SIGTERM) if sys.argv[2]=='interrupt' else None; "
        "os.close(1);os.close(2);signal.pause()"
    )
    clock, killpg = time.monotonic, os.killpg
    deadline = clock() + (1000 if mode == "producer" else 20)
    groups = []

    def stop(group, sig):
        groups.append(group)
        killpg(group, sig)

    if mode != "interrupt":
        beyond = deadline - 1 if mode == "producer" else deadline + 1
        monkeypatch.setattr(
            collector,
            "time",
            SimpleNamespace(monotonic=lambda: beyond if marker.exists() else clock()),
        )
    monkeypatch.setattr(collector.os, "killpg", stop)
    try:
        captured = collector._metadata_command(
            [sys.executable, "-c", script, str(marker), mode],
            cwd=tmp_path,
            max_stdout_bytes=32,
            max_stderr_bytes=32,
            export_deadline=deadline,
        )
        assert (
            captured["failure"]
            == {
                "interrupt": "producer_unavailable",
                "export": "export_timeout",
                "producer": "producer_timeout",
            }[mode]
        )
        assert captured["returncode"] is None
        owned = json.loads(marker.read_bytes())
        assert groups == [owned["pgid"]]
        state = subprocess.run(
            ["ps", "-o", "state=", "-p", str(owned["pid"])],
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()
        assert not state or state.startswith("Z")
    finally:
        if not groups and marker.exists():
            owned = json.loads(marker.read_bytes())
            if os.getpgid(owned["pid"]) == owned["pgid"]:
                killpg(owned["pgid"], 9)


@pytest.mark.parametrize("failure", ["spawn", "selector", "cleanup", "already_gone"])
def test_metadata_failure_paths_keep_cleanup_owned_and_do_not_invent_worker_status(
    tmp_path, monkeypatch, failure
):
    processes = []
    popen, killpg = subprocess.Popen, os.killpg

    def start(*args, **kwargs):
        if failure == "spawn":
            raise OSError("PRIVATE spawn details")
        process = popen(*args, **kwargs)
        processes.append(process)
        return process

    def stop(group, sig):
        killpg(group, sig)
        if failure == "cleanup":
            raise PermissionError("PRIVATE cleanup details")
        if failure == "already_gone":
            raise ProcessLookupError()

    def unavailable():
        raise OSError("PRIVATE selector details")

    monkeypatch.setattr(collector.subprocess, "Popen", start)
    monkeypatch.setattr(collector.os, "killpg", stop)
    if failure == "selector":
        monkeypatch.setattr(collector.selectors, "DefaultSelector", unavailable)
    arguments = dict(
        command=[sys.executable, "-c", "print('done')"],
        cwd=tmp_path,
        max_stdout_bytes=32,
        max_stderr_bytes=32,
        export_deadline=time.monotonic() + 10,
    )
    if failure in {"selector", "cleanup"}:
        with pytest.raises(OSError) as refused:
            collector._metadata_command(**arguments)
        assert refused.value.metadata_capture["failure"] == "producer_unavailable"
    else:
        captured = collector._metadata_command(**arguments)
        assert captured["failure"] == ("producer_unavailable" if failure == "spawn" else None)
        assert captured["returncode"] == (None if failure == "spawn" else 0)
    assert all(process.returncode == -9 for process in processes)


@pytest.mark.parametrize(
    "worker_status", [b"", b"00\n", b"+0\n", b"256\n", b"-256\n", b"2\njunk", b"9" * 17]
)
def test_metadata_private_status_is_bounded_and_canonical(tmp_path, worker_status):
    read_fd, write_fd = os.pipe()
    command = [
        sys.executable,
        "-c",
        "import os,signal,sys;os.write(int(sys.argv[1]),bytes.fromhex(sys.argv[2]));"
        "os.close(int(sys.argv[1]));os.close(1);os.close(2);signal.pause()",
        str(write_fd),
        worker_status.hex(),
    ]
    process = subprocess.Popen(
        command,
        cwd=tmp_path,
        pass_fds=(write_fd,),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    os.close(write_fd)
    result = dict(
        stdout=b"",
        stderr=b"",
        returncode=None,
        failure=None,
        stdout_truncated=False,
        stderr_truncated=False,
    )
    with os.fdopen(read_fd, "rb") as status:
        collector._metadata_capture(process, status, result, 32, 32, time.monotonic() + 10)
    assert result["failure"] == "producer_unavailable" and result["returncode"] is None
    assert result["stdout"] == result["stderr"] == b""
    assert result["stdout_truncated"] is result["stderr_truncated"] is False
    assert process.returncode == -9


def test_metadata_expired_export_never_starts_a_supervisor(tmp_path, monkeypatch):
    def unexpected(*args, **kwargs):
        pytest.fail("expired metadata producer started")

    monkeypatch.setattr(collector.subprocess, "Popen", unexpected)
    captured = collector._metadata_command(
        [sys.executable, "-c", "print('unreachable')"],
        cwd=tmp_path,
        max_stdout_bytes=32,
        max_stderr_bytes=32,
        export_deadline=0,
    )
    assert captured["failure"] == "export_timeout" and captured["returncode"] is None
    assert captured["stdout"] == captured["stderr"] == b""


@pytest.mark.parametrize("replacement", ["source", "snapshot"])
def test_metadata_source_replacement_cannot_substitute_the_executed_supervisor(
    tmp_path, monkeypatch, replacement
):
    source = tmp_path / "collector.py"
    source.write_bytes(Path(collector.__file__).read_bytes())
    marker = tmp_path / "actual-worker"
    observed = []
    output, popen = collector._exclusive_output, subprocess.Popen

    @contextmanager
    def snapshot_output(path):
        observed.append(path)
        with output(path) as stream:
            yield stream

    def start(*args, **kwargs):
        changed = source if replacement == "source" else observed[0]
        changed.unlink()
        changed.write_bytes(b"raise SystemExit(99)\n")
        return popen(*args, **kwargs)

    monkeypatch.setattr(collector, "__file__", str(source))
    monkeypatch.setattr(collector, "_exclusive_output", snapshot_output)
    monkeypatch.setattr(collector.subprocess, "Popen", start)
    with pytest.raises(collector.CollectionError):
        collector._metadata_command(
            [
                sys.executable,
                "-c",
                "import pathlib;pathlib.Path('actual-worker').touch();print('done')",
            ],
            cwd=tmp_path,
            max_stdout_bytes=32,
            max_stderr_bytes=32,
            export_deadline=time.monotonic() + 10,
        )
    assert marker.exists() and len(observed) == 1 and not observed[0].exists()


def test_retained_archive_digest_is_captured_from_the_written_descriptor(tmp_path, monkeypatch):
    kwargs, _, _, _, _ = _setup(tmp_path, monkeypatch, "core")
    read = collector._read
    replaced = []

    def replace_before_first_path_read(path, *args, **options):
        if path == kwargs["binary_archive"] and not replaced:
            replaced.append(True)
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr(domain.BINARY_MEMBERS["core"], b"different binary")
        return read(path, *args, **options)

    monkeypatch.setattr(collector, "_read", replace_before_first_path_read)
    with pytest.raises(collector.CollectionError) as refused:
        collector.collect(**kwargs)
    assert refused.value.collection_stage == "binary_archive"
    assert not kwargs["output"].exists()


def test_diagnostic_fifo_swap_is_rejected_without_reading_or_emitting_domain(tmp_path):
    fixture = tmp_path / "fixture"
    fixture.mkdir()
    controller = """import importlib.util,json,os,pathlib,stat,sys,pytest
spec=importlib.util.spec_from_file_location('collector_tests',sys.argv[1])
tests=importlib.util.module_from_spec(spec)
spec.loader.exec_module(tests)
with pytest.MonkeyPatch.context() as patch:
    kwargs,_,_,_,_=tests._setup(pathlib.Path(sys.argv[2]),patch,'core')
    diagnostic=pathlib.Path(str(kwargs['output'])+'.diagnostics')
    opened=tests.collector.os.open
    fdopen=tests.collector.os.fdopen
    swapped=[]
    reads=[]
    def swap(name,flags,mode=0o777,*,dir_fd=None):
        if name=='summary.stdout' and not flags & os.O_CREAT and not swapped:
            leaf=diagnostic/name
            leaf.unlink()
            os.mkfifo(leaf,0o600)
            swapped.append(flags)
        return opened(name,flags,mode,dir_fd=dir_fd)
    def guard(descriptor,*args,**options):
        stream=fdopen(descriptor,*args,**options)
        if stat.S_ISFIFO(os.fstat(descriptor).st_mode):
            def refuse(*args,**options):
                reads.append(True)
                raise AssertionError('FIFO data must never be read')
            stream.read=refuse
        return stream
    patch.setattr(tests.collector.os,'open',swap)
    patch.setattr(tests.collector.os,'fdopen',guard)
    try:
        tests.collector.collect(**kwargs)
    except tests.collector.CollectionError:
        assert swapped and swapped[0] & os.O_NONBLOCK
        assert not reads and not kwargs['output'].exists()
        assert kwargs['binary_archive'].is_file()
        print(json.dumps({'refused':True,'fifo_reads':len(reads),'domain_exists':False}))
    else:
        raise AssertionError('FIFO replacement was accepted')
"""
    command = [sys.executable, "-c", controller, str(Path(__file__).resolve()), str(fixture)]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        pytest.fail("Diagnostic verification blocked after a real FIFO replacement")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {"refused": True, "fifo_reads": 0, "domain_exists": False}


@pytest.mark.parametrize("replacement_kind", ["fifo", "regular"])
def test_source_replacement_is_rejected_before_any_read(tmp_path, replacement_kind):
    controller = """import json,os,pathlib,stat,sys
from scripts import collect_xccov_native_domain as collector
path=pathlib.Path(sys.argv[1]).resolve()
path.write_bytes(b'original')
replacement=path.with_suffix('.replacement')
replacement.write_bytes(b'replaced')
opened,fdopen=collector.os.open,collector.os.fdopen
swapped=[]
def swap(name,flags,*args,**options):
    if name==path and not swapped:
        if sys.argv[2]=='fifo':
            path.unlink()
            os.mkfifo(path,0o600)
        else:
            os.replace(replacement,path)
        swapped.append(flags)
    return opened(name,flags,*args,**options)
def guard(descriptor,*args,**options):
    stream=fdopen(descriptor,*args,**options)
    if swapped:
        def refuse(*args,**options):
            raise AssertionError('Replaced data must never be read')
        stream.read=refuse
    return stream
collector.os.open,collector.os.fdopen=swap,guard
try:
    collector._read(path)
except collector.CollectionError:
    assert swapped and swapped[0] & os.O_NONBLOCK
    print(json.dumps({'refused':True}))
else:
    raise AssertionError('FIFO replacement was accepted')
"""
    try:
        result = subprocess.run(
            [sys.executable, "-c", controller, str(tmp_path / "source.swift"), replacement_kind],
            cwd=Path(__file__).resolve().parents[1],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except subprocess.TimeoutExpired:
        pytest.fail("Source verification blocked after a real FIFO replacement")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {"refused": True}


def test_diagnostic_enumeration_stops_at_seven_leaves_without_eager_listing(tmp_path, monkeypatch):
    sink = collector._Diagnostics(tmp_path.resolve() / "domain.json")
    names = [
        "summary.stdout",
        "summary.stderr",
        "summary.status.json",
        "tests.stdout",
        "tests.stderr",
        "tests.status.json",
        "stage.json",
    ]
    try:
        for name in names:
            sink.write(name, b"raw")
        visited = []

        class Entries:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return None

            def __iter__(self):
                return self

            def __next__(self):
                index = len(visited)
                assert index < 8, "directory enumeration exceeded its fixed leaf bound"
                visited.append(index)
                return SimpleNamespace(name=names[index % 7])

        def eager(_):
            raise AssertionError("eager directory materialization is forbidden")

        monkeypatch.setattr(collector.os, "listdir", eager)
        monkeypatch.setattr(collector.os, "scandir", lambda _: Entries())
        with pytest.raises(collector.CollectionError):
            sink.verify()
        assert len(visited) == 8
    finally:
        sink.close()
