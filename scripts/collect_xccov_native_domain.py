#!/usr/bin/env python3
"""Collects a diagnostic iOS coverage domain from validated Xcode test Products without
building or launching tests; export_xccov_line_coverage.py turns it into a usable
report.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import stat
import sys
import tempfile
import time
from typing import Any
import zipfile


MAX_FILE = 256 * 1024 * 1024
MAX_TREE = 1024 * 1024 * 1024
MAX_ENTRIES = 10_000
STAGES = frozenset(
    {
        "inputs", "source_before", "products_before", "result_before", "result_copy", "test_metadata",
        "binary_archive", "mapping", "source_after", "products_after", "result_after",
        "archive_after", "domain_validation", "output",
    }
)
SOURCE_ROOTS = ("apple-clients/AstralCore", "apple-clients/AstralApp")
FOLDER = "Debug-iphonesimulator/"
APP = FOLDER + "AstralDeep.app"
RUNNER = FOLDER + "AstralAppUITests-Runner.app"
CORE = FOLDER + "AstralCoreTests.xctest"


class CollectionError(ValueError):
    def __init__(self) -> None:
        super().__init__("native_xccov_collection_invalid")


def require(value: Any) -> None:
    if not value:
        raise CollectionError()


@contextmanager
def _stage(name: str):
    require(name in STAGES)
    try:
        yield
    except Exception as exc:
        exc.collection_stage = name
        raise


def _module(name: str) -> Any:
    path = Path(__file__).resolve().with_name(name + ".py")
    require(path.is_file() and not path.is_symlink())
    spec = importlib.util.spec_from_file_location("_collector_" + name, path)
    require(spec is not None and spec.loader is not None)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _path(path: Path) -> Path:
    require(path.is_absolute() and str(path) == str(path.resolve()))
    return path


def _read(path: Path, limit: int = MAX_FILE) -> bytes:
    _path(path)
    before = path.lstat()
    require(stat.S_ISREG(before.st_mode) and before.st_size <= limit)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        opened = os.fstat(stream.fileno())
        raw = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
    stable = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns", "st_mode")
    require(
        len(raw) == opened.st_size <= limit
        and all(
            getattr(before, key) == getattr(opened, key) == getattr(after, key) for key in stable
        )
        and all(getattr(after, key) == getattr(path.lstat(), key) for key in stable)
    )
    return raw


def _identity(path: Path, raw: bytes) -> dict[str, Any]:
    return {
        "sha256": hashlib.sha256(raw).hexdigest(),
        "size": len(raw),
        "mode": stat.S_IMODE(path.lstat().st_mode),
    }


def _tree(root: Path, deadline: float) -> dict[str, Any]:
    require(_path(root).is_dir())
    result = {}
    total = 0
    pending = [root]
    entries = 0
    while pending:
        require(time.monotonic() < deadline)
        directory = pending.pop()
        for child in directory.iterdir():
            entries += 1
            require(entries <= MAX_ENTRIES and not child.is_symlink())
            if child.is_dir():
                pending.append(child)
            else:
                raw = _read(child)
                total += len(raw)
                require(total <= MAX_TREE)
                result[child.relative_to(root).as_posix()] = _identity(child, raw)
    require(result)
    return result


def _test_documents(
    xcresult: Path, inventory: dict[str, Any], policy: Any, run: Any, deadline: float
) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="astral-result-query-") as directory:
        copied = Path(directory).resolve() / "Result.xcresult"
        with _stage("result_copy"):
            copied.mkdir(mode=0o700)
            for name, facts in inventory.items():
                require(time.monotonic() < deadline)
                raw = _read(xcresult / name)
                require(_identity(xcresult / name, raw) == facts)
                destination = copied / name
                destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                with destination.open("xb") as stream:
                    stream.write(raw)
                destination.chmod(facts["mode"])
            require(_tree(copied, deadline) == inventory)
        documents = {}
        with _stage("test_metadata"):
            for name in ("summary", "tests"):
                documents[name] = policy.strict_json(
                    run(
                        [
                            "/usr/bin/xcrun",
                            "xcresulttool",
                            "get",
                            "test-results",
                            name,
                            "--schema-version",
                            "0.1.0",
                            "--compact",
                            "--path",
                            str(copied),
                        ],
                        16 * 1024 * 1024,
                    )
                )
        return documents


def _source_closure(repo: Path, exporter: Any, run: Any, deadline: float) -> tuple:
    require(run(["git", "rev-parse", "--show-object-format"], 128).strip() == b"sha1")
    head = run(["git", "rev-parse", "HEAD"], 128).strip()
    require(re.fullmatch(rb"[0-9a-f]{40}", head))
    status = run(
        [
            "git",
            "status",
            "--porcelain=v1",
            "-z",
            "--branch",
            "--untracked-files=all",
            "--",
            *SOURCE_ROOTS,
        ],
        4 * 1024 * 1024,
    )
    require(
        status.startswith(b"## ") and status.endswith(b"\0") and len(status[:-1].split(b"\0")) == 1
    )
    raw = run(["git", "ls-tree", "-rz", "HEAD", "--", *SOURCE_ROOTS], 4 * 1024 * 1024)
    require(raw.endswith(b"\0"))
    values = raw[:-1].split(b"\0")
    require(len(values) <= MAX_ENTRIES)
    sources, facts = {}, {}
    total = 0
    for value in values:
        header, encoded = value.split(b"\t", 1)
        name = encoded.decode("utf-8", "strict")
        if not name.endswith(".swift"):
            continue
        require(name not in facts and any(name.startswith(root + "/") for root in SOURCE_ROOTS))
        mode, kind, digest = header.split(b" ")
        require(mode in {b"100644", b"100755"} and kind == b"blob")
        require(re.fullmatch(rb"[0-9a-f]{40}", digest))
        content = exporter._read_source_bytes(repo, name, export_deadline=deadline)
        blob = b"blob " + str(len(content)).encode("ascii") + b"\0" + content
        require(hashlib.sha1(blob).hexdigest().encode() == digest)
        executable = bool((repo / name).lstat().st_mode & stat.S_IXUSR)
        require(executable == (mode == b"100755"))
        sources[name] = content
        facts[name] = {"sha256": hashlib.sha256(content).hexdigest(), "mode": mode.decode()}
        total += len(content)
        require(total <= 64 * 1024 * 1024)
    tracked = exporter._tracked_swift_sources(repo, "ios", export_deadline=deadline)
    require(tracked and tracked <= set(sources))
    return head.decode(), sources, facts, tracked


# xctestrun Architectures lists x86_64 even on arm64 — not proof
def _products(products: Path, lane: str) -> tuple[dict[str, Any], bytes]:
    require(_path(products).is_dir() and products.name == "Products")
    records = {}

    def read(name: str) -> bytes:
        raw = _read(products / name)
        records[name] = _identity(products / name, raw)
        return raw

    names = []
    for child in products.iterdir():
        names.append(child.name)
        require(len(names) <= MAX_ENTRIES)
    runs = [name for name in names if name.endswith(".xctestrun")]
    require(len(runs) == 1)
    doc = plistlib.loads(read(runs[0]))
    require(isinstance(doc, dict))
    configurations = doc.get("TestConfigurations")
    require(isinstance(configurations, list) and len(configurations) == 1)
    require(isinstance(configurations[0], dict))
    targets = configurations[0].get("TestTargets")
    expected = {"AstralCoreTests"} if lane == "core" else {"AstralAppTests", "AstralAppUITests"}
    require(isinstance(targets, list) and len(targets) == len(expected))
    require(all(isinstance(target, dict) for target in targets))
    require({target.get("BlueprintName") for target in targets} == expected)
    selected = {target["BlueprintName"]: target for target in targets}
    coverage = doc.get("CodeCoverageBuildableInfos")
    require(isinstance(coverage, list) and 0 < len(coverage) <= MAX_ENTRIES)

    def instrumented(name: str, path: str, *, static: bool = False) -> None:
        matches = [item for item in coverage if isinstance(item, dict) and item.get("Name") == name]
        require(len(matches) == 1 and matches[0].get("IncludeInReport") is True)
        require(matches[0].get("ProductPaths") == ["__TESTROOT__/" + path])
        require(matches[0].get("IsStatic") is static)

    if lane == "core":
        target = selected["AstralCoreTests"]
        require(
            target.get("IsAppHostedTestBundle", False) is False
            and target.get("IsUITestBundle", False) is False
        )
        require(
            target.get("TestHostPath")
            == "__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest"
        )
        require(target.get("TestBundlePath") == "__TESTROOT__/" + CORE)
        instrumented("AstralCoreTests", CORE + "/AstralCoreTests")
        matches = [
            item for item in coverage if isinstance(item, dict) and item.get("Name") == "AstralCore"
        ]
        require(
            len(matches) == 1
            and matches[0].get("IsStatic") is True
            and matches[0].get("IncludeInReport") is True
        )
        paths = matches[0].get("ProductPaths")
        require(isinstance(paths, list) and len(paths) == 1 and isinstance(paths[0], str))
        require(
            re.fullmatch(
                r"__TESTROOT__/Debug-iphonesimulator/PackageFrameworks/(AstralCore_[A-Za-z0-9-]+_PackageProduct)\.framework/\1",
                paths[0],
            )
        )
        read(FOLDER + "AstralCore.o")
        binary = read(CORE + "/AstralCoreTests")
    else:
        unit, ui = selected["AstralAppTests"], selected["AstralAppUITests"]
        require(
            unit.get("IsAppHostedTestBundle") is True
            and unit.get("IsUITestBundle", False) is False
            and unit.get("TestHostBundleIdentifier") == "com.personalailabs.astraldeep"
            and unit.get("TestHostPath") == "__TESTROOT__/" + APP
            and unit.get("TestBundlePath") == "__TESTHOST__/PlugIns/AstralAppTests.xctest"
        )
        require(
            ui.get("IsUITestBundle") is True
            and ui.get("TestHostBundleIdentifier")
            == "com.personalailabs.astraldeep.uitests.xctrunner"
            and ui.get("TestHostPath") == "__TESTROOT__/" + RUNNER
            and ui.get("UITargetAppPath") == "__TESTROOT__/" + APP
            and ui.get("TestBundlePath") == "__TESTHOST__/PlugIns/AstralAppUITests.xctest"
        )
        info = plistlib.loads(read(APP + "/Info.plist"))
        require(
            isinstance(info, dict)
            and info.get("CFBundleIdentifier") == "com.personalailabs.astraldeep"
            and info.get("CFBundleExecutable") == "AstralDeep"
            and info.get("CFBundlePackageType") == "APPL"
            and info.get("CFBundleSupportedPlatforms") == ["iPhoneSimulator"]
        )
        for name in (
            APP + "/AstralDeep",
            APP + "/PlugIns/AstralAppTests.xctest/AstralAppTests",
            RUNNER + "/AstralAppUITests-Runner",
            RUNNER + "/PlugIns/AstralAppUITests.xctest/AstralAppUITests",
        ):
            read(name)
            require(records[name]["mode"] & stat.S_IXUSR)
        instrumented("AstralDeep.app", APP + "/AstralDeep")
        binary = read(APP + "/AstralDeep.debug.dylib")
    return records, binary


def collect(
    *, repo: Path, products: Path, xcresult: Path, lane: str, output: Path, binary_archive: Path
) -> dict[str, Any]:
    require(lane in {"core", "unit", "ui"})
    repo, products, xcresult = _path(repo), _path(products), _path(xcresult)
    output, binary_archive = _path(output), _path(binary_archive)
    require(output != binary_archive and xcresult.suffix == ".xcresult")
    artifact_member = f"coverage/native-binaries/apple-ios-{lane}.zip"
    require(binary_archive.as_posix().endswith("/" + artifact_member))
    require(not output.exists() and not binary_archive.exists())
    require(
        not output.is_relative_to(products)
        and not output.is_relative_to(xcresult)
        and not binary_archive.is_relative_to(products)
        and not binary_archive.is_relative_to(xcresult)
    )
    policy, exporter = _module("native_xccov_domain"), _module("export_xccov_line_coverage")
    deadline = time.monotonic() + exporter.EXPORT_TIMEOUT_SECONDS

    def run(command: list[str], bound: int) -> bytes:
        return exporter._bounded_command(
            command, cwd=repo, max_stdout_bytes=bound, export_deadline=deadline
        )

    with _stage("source_before"):
        source_before = _source_closure(repo, exporter, run, deadline)
    with _stage("products_before"):
        product_before, binary = _products(products, lane)
    with _stage("result_before"):
        result_before = _tree(xcresult, deadline)
    documents = _test_documents(xcresult, result_before, policy, run, deadline)
    with _stage("test_metadata"):
        policy.test_identity(documents["summary"], documents["tests"], lane)
        policy.ios_macho(binary, lane)
    member = policy.BINARY_MEMBERS["core" if lane == "core" else "app"]
    with _stage("binary_archive"):
        binary_archive.parent.mkdir(parents=True, exist_ok=True)
        _path(binary_archive.parent)
        with (
            binary_archive.open("xb") as stream,
            zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED) as bundle,
        ):
            entry = zipfile.ZipInfo(member)
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | 0o600) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            bundle.writestr(entry, binary)
        archive_bytes = _read(binary_archive)
    identity = {
        "member": member,
        "sha256": policy.sha256(binary),
        "artifact_member": artifact_member,
        "artifact_sha256": policy.sha256(archive_bytes),
    }
    with _stage("mapping"), tempfile.TemporaryDirectory(prefix="astral-native-domain-") as directory:
        selected = Path(directory).resolve() / "selected-binary"
        with selected.open("xb") as stream:
            stream.write(binary)
        selected.chmod(0o400)
        domain = policy.collect_domain(
            binary_path=selected,
            binary_bytes=binary,
            binary_identity=identity,
            archive_root=str(repo),
            prefix="",
            lane=lane,
            tracked=source_before[3],
            source_bytes=source_before[1].__getitem__,
            run=run,
            summary=documents["summary"],
            tests=documents["tests"],
        )
    with _stage("source_after"):
        require(source_before == _source_closure(repo, exporter, run, deadline))
    with _stage("products_after"):
        require((product_before, binary) == _products(products, lane))
    with _stage("result_after"):
        require(result_before == _tree(xcresult, deadline))
    with _stage("archive_after"):
        require(_read(binary_archive) == archive_bytes)
    with _stage("domain_validation"):
        policy.validate_domain(domain)
    with _stage("output"):
        output.parent.mkdir(parents=True, exist_ok=True)
        _path(output.parent)
        with output.open("xb") as stream:
            stream.write(policy.canonical(domain) + b"\n")
    return domain


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("repo", "products", "xcresult", "output", "binary-archive"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--lane", required=True, choices=("core", "unit", "ui"))
    args = parser.parse_args(argv)
    try:
        collect(**vars(args))
    except Exception as exc:
        print("native_xccov_collection_invalid", file=sys.stderr)
        stage = getattr(exc, "collection_stage", "inputs")
        stage = stage if isinstance(stage, str) and stage in STAGES else "inputs"
        print("native_xccov_collection_stage=" + stage, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
