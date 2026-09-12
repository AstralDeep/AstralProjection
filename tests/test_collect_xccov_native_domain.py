"""Diagnostic collector tests; fixture geometry is never native hit evidence."""

from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import time
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
    # These substitutions match real Xcode26.6 generated Products metadata.
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
        product["Architectures"] = ["x86_64"]  # Not executed-architecture evidence.
    return {
        "TestConfigurations": [{"TestTargets": targets}],
        "CodeCoverageBuildableInfos": products,
    }


def _setup(tmp_path, monkeypatch, lane="ui"):
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
    member = domain.BINARY_MEMBERS["core" if lane == "core" else "app"]
    binary_path = products / member.removeprefix("Products/")
    _write(binary_path, _macho(lane))
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
    result = tmp_path.resolve() / "actual.xcresult"
    _write(result / "Data/native-observation", b"fixture raw result")
    summary, tests = _metadata(lane)
    calls = []
    original_run = exporter._bounded_command
    state = {"hook": lambda: None, "summary": summary, "tests": tests}

    def run(command, **kwargs):
        calls.append(command)
        if command[0] == "git":
            return original_run(command, **kwargs)
        if command[0] == "/usr/bin/xcodebuild":
            assert command == ["/usr/bin/xcodebuild", "-version"]
            return b"Xcode 26.6\nBuild version 17F113\n"
        if command[1] == "xcresulttool":
            assert command[2:4] == ["get", "test-results"]
            assert command[5:] == ["--schema-version", "0.1.0", "--compact", "--path", str(result)]
            return json.dumps(state[command[4]]).encode()
        if command[2:] == ["--version"]:
            return b"Apple LLVM version 21.0.0\n"
        assert command[:6] == [
            "/usr/bin/xcrun",
            "llvm-cov",
            "export",
            "--empty-profile",
            "--arch=arm64",
            command[5],
        ]
        assert Path(command[5]).read_bytes() == _macho(lane)
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
        "_module",
        lambda name: {"native_xccov_domain": domain, "export_xccov_line_coverage": exporter}[name],
    )
    kwargs = {
        "repo": repo,
        "products": products,
        "xcresult": result,
        "lane": lane,
        "output": tmp_path.resolve() / "out/domain.json",
        "binary_archive": tmp_path.resolve() / f"out/coverage/native-binaries/apple-ios-{lane}.zip",
    }
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
    with pytest.raises((collector.CollectionError, exporter.ExportError)):
        collector.collect(**kwargs)
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
    assert not kwargs["output"].exists() and not kwargs["binary_archive"].exists()


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
    assert capsys.readouterr().err == "native_xccov_collection_invalid\n"


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
