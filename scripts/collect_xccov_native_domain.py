#!/usr/bin/env python3
"""Collects a diagnostic Apple coverage domain from validated Xcode test Products without
building or launching tests; export_xccov_line_coverage.py turns it into a usable
report.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import signal
import stat
import subprocess
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
        "inputs",
        "source_before",
        "products_before",
        "result_before",
        "result_copy",
        "diagnostics",
        "summary_query",
        "summary_json",
        "tests_query",
        "tests_json",
        "native_binary",
        "test_identity",
        "binary_archive",
        "mapping",
        "source_after",
        "products_after",
        "result_after",
        "archive_after",
        "domain_validation",
        "output",
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
    stable = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns", "st_mode")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        opened = os.fstat(stream.fileno())
        require(stat.S_ISREG(opened.st_mode) and opened.st_size <= limit)
        require(all(getattr(before, key) == getattr(opened, key) for key in stable))
        raw = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
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


@contextmanager
def _held_directory(path: Path):
    _path(path)
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            try:
                os.mkdir(part, mode=0o700, dir_fd=descriptor)
            except FileExistsError:
                pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        _same_directory(path, descriptor)
        yield descriptor
        _same_directory(path, descriptor)
    finally:
        os.close(descriptor)


def _same_directory(path: Path, descriptor: int) -> None:
    _path(path)
    current, held = path.lstat(), os.fstat(descriptor)
    require(
        stat.S_ISDIR(current.st_mode)
        and (current.st_dev, current.st_ino) == (held.st_dev, held.st_ino)
    )


@contextmanager
def _exclusive_output(path: Path):
    with _held_directory(path.parent) as parent:
        descriptor = os.open(
            path.name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent
        )
        with os.fdopen(descriptor, "w+b") as stream:
            yield stream
            stream.flush()
            opened = os.fstat(stream.fileno())
            current = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            require(stat.S_ISREG(current.st_mode) and current.st_nlink == 1)
            require((opened.st_dev, opened.st_ino) == (current.st_dev, current.st_ino))


class _Diagnostics:
    def __init__(self, output: Path) -> None:
        self.path = Path(str(output) + ".diagnostics")
        self._parent = _held_directory(self.path.parent)
        self.parent = self._parent.__enter__()
        self.descriptor: int | None = None
        self.files: dict[str, bytes] = {}
        try:
            try:
                os.mkdir(self.path.name, mode=0o700, dir_fd=self.parent)
            except FileExistsError as exc:
                raise CollectionError() from exc
            self.descriptor = os.open(
                self.path.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.parent
            )
            self.verify()
        except BaseException:
            self.close()
            raise

    def verify(self) -> None:
        require(self.descriptor is not None)
        _same_directory(self.path.parent, self.parent)
        _same_directory(self.path, self.descriptor)
        require(stat.S_IMODE(os.fstat(self.descriptor).st_mode) == 0o700)
        names = set()
        with os.scandir(self.descriptor) as entries:
            for entry in entries:
                require(len(names) < 7 and entry.name in self.files and entry.name not in names)
                names.add(entry.name)
        require(names == set(self.files))
        for name, expected in self.files.items():
            descriptor = os.open(
                name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=self.descriptor
            )
            with os.fdopen(descriptor, "rb") as stream:
                opened = os.fstat(stream.fileno())
                require(stat.S_ISREG(opened.st_mode) and opened.st_nlink == 1)
                require(stat.S_IMODE(opened.st_mode) == 0o600 and opened.st_size == len(expected))
                require(stream.read(len(expected) + 1) == expected)
                after = os.fstat(stream.fileno())
                current = os.stat(name, dir_fd=self.descriptor, follow_symlinks=False)
                require(
                    all(
                        getattr(opened, key) == getattr(after, key) == getattr(current, key)
                        for key in (
                            "st_dev",
                            "st_ino",
                            "st_size",
                            "st_mode",
                            "st_nlink",
                            "st_mtime_ns",
                            "st_ctime_ns",
                        )
                    )
                )

    def write(self, name: str, raw: bytes) -> None:
        require(
            name
            in {
                "summary.stdout",
                "summary.stderr",
                "summary.status.json",
                "tests.stdout",
                "tests.stderr",
                "tests.status.json",
                "stage.json",
            }
        )
        self.verify()
        descriptor = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=self.descriptor,
        )
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(raw)
        self.files[name] = raw
        self.verify()

    def capture(self, name: str, value: dict[str, Any]) -> None:
        require(type(value["stdout"]) is bytes and len(value["stdout"]) <= 16 * 1024 * 1024)
        require(type(value["stderr"]) is bytes and len(value["stderr"]) <= 4 * 1024 * 1024)
        require(value["returncode"] is None or type(value["returncode"]) is int)
        require(
            value["failure"]
            in {
                None,
                "producer_failed",
                "producer_timeout",
                "export_timeout",
                "producer_unavailable",
                "producer_output_too_large",
                "producer_cancelled",
            }
        )
        require(type(value["stdout_truncated"]) is bool and type(value["stderr_truncated"]) is bool)
        self.write(name + ".stdout", value["stdout"])
        self.write(name + ".stderr", value["stderr"])
        self.write(
            name + ".status.json",
            json.dumps(
                {
                    key: value[key]
                    for key in ("returncode", "failure", "stdout_truncated", "stderr_truncated")
                },
                sort_keys=True,
                separators=(",", ":"),
            ).encode()
            + b"\n",
        )

    def close(self) -> None:
        if self.descriptor is not None:
            os.close(self.descriptor)
            self.descriptor = None
        self._parent.__exit__(None, None, None)


def _metadata_supervise(status_fd: int, directory_fd: int, command: list[str]) -> None:
    os.fchdir(directory_fd)
    os.close(directory_fd)
    try:
        worker = subprocess.Popen(command, close_fds=True)
    except OSError:
        value = b"unavailable\n"
    else:
        value = str(worker.wait()).encode() + b"\n"
    try:
        os.write(status_fd, value)
    finally:
        os.close(status_fd)


@contextmanager
def _metadata_snapshot(source: bytes):
    with tempfile.TemporaryDirectory(prefix="astral-native-supervisor-") as directory:
        snapshot = Path(directory).resolve() / "supervisor.py"
        with _exclusive_output(snapshot) as output:
            output.write(source)
            output.flush()
            os.fchmod(output.fileno(), 0o400)
            descriptor = os.open(snapshot, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(descriptor, "rb") as stream:
                before = os.fstat(descriptor)
                require(stat.S_ISREG(before.st_mode) and before.st_size == len(source))
                require(stream.read(len(source) + 1) == source)
                stream.seek(0)
                yield descriptor
                stream.seek(0)
                require(stream.read(len(source) + 1) == source)
                require(
                    all(
                        getattr(before, key) == getattr(os.fstat(descriptor), key)
                        for key in (
                            "st_dev",
                            "st_ino",
                            "st_size",
                            "st_mode",
                            "st_nlink",
                            "st_mtime_ns",
                            "st_ctime_ns",
                        )
                    )
                )


def _metadata_capture(
    process: Any,
    status: Any,
    result: dict[str, Any],
    max_stdout_bytes: int,
    max_stderr_bytes: int,
    export_deadline: float,
) -> None:
    selector = None
    streams = {
        process.stdout: ("stdout", max_stdout_bytes),
        process.stderr: ("stderr", max_stderr_bytes),
        status: ("status", 16),
    }
    chunks: dict[str, list[bytes]] = {name: [] for name in ("stdout", "stderr", "status")}
    totals = {name: 0 for name in chunks}
    try:
        deadline = min(export_deadline, time.monotonic() + 120)
        selector = selectors.DefaultSelector()
        for stream in streams:
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ)
        while selector.get_map() and result["failure"] is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                result["failure"] = (
                    "export_timeout" if export_deadline <= deadline else "producer_timeout"
                )
                break
            for key, _ in selector.select(min(remaining, 0.1)):
                stream = key.fileobj
                name, bound = streams[stream]
                chunk = os.read(stream.fileno(), min(64 * 1024, bound - totals[name] + 1))
                if not chunk:
                    selector.unregister(stream)
                    continue
                kept = chunk[: bound - totals[name]]
                chunks[name].append(kept)
                totals[name] += len(kept)
                if len(kept) != len(chunk):
                    result["failure"] = (
                        "producer_unavailable" if name == "status" else "producer_output_too_large"
                    )
                    if name != "status":
                        result[name + "_truncated"] = True
                    break
    except BaseException as exc:
        result["failure"] = (
            "producer_cancelled" if isinstance(exc, KeyboardInterrupt) else "producer_unavailable"
        )
        exc.metadata_capture = result
        raise
    finally:
        result["stdout"], result["stderr"] = (
            b"".join(chunks[name]) for name in ("stdout", "stderr")
        )
        worker_status = b"".join(chunks["status"])
        try:
            code = int(worker_status)
            require(-255 <= code <= 255 and str(code).encode() + b"\n" == worker_status)
        except ValueError:
            if result["failure"] is None:
                result["failure"] = "producer_unavailable"
        else:
            result["returncode"] = code
        try:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            finally:
                process.wait(timeout=2)
        except BaseException as exc:
            result["failure"] = "producer_unavailable"
            exc.metadata_capture = result
            raise
        finally:
            if selector is not None:
                selector.close()
            for stream in streams:
                stream.close()


def _metadata_command(
    command: list[str],
    *,
    cwd: Path,
    max_stdout_bytes: int,
    max_stderr_bytes: int,
    export_deadline: float,
) -> dict[str, Any]:
    require(0 < max_stdout_bytes <= 16 * 1024 * 1024 and 0 < max_stderr_bytes <= 4 * 1024 * 1024)
    result: dict[str, Any] = {
        "stdout": b"",
        "stderr": b"",
        "returncode": None,
        "failure": None,
        "stdout_truncated": False,
        "stderr_truncated": False,
    }
    if time.monotonic() >= export_deadline:
        result["failure"] = "export_timeout"
        return result
    source_path = Path(__file__).resolve()
    source = _read(source_path, 2 * 1024 * 1024)
    with _metadata_snapshot(source) as source_fd, _held_directory(cwd) as directory_fd:
        read_fd, write_fd = os.pipe()
        with os.fdopen(read_fd, "rb") as status:
            try:
                process = subprocess.Popen(
                    [
                        sys.executable,
                        "-I",
                        "-S",
                        "/dev/fd/" + str(source_fd),
                        "--metadata-supervise",
                        str(write_fd),
                        str(directory_fd),
                        str(source_fd),
                        *command,
                    ],
                    pass_fds=(write_fd, directory_fd, source_fd),
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    start_new_session=True,
                )
            except OSError:
                result["failure"] = "producer_unavailable"
                return result
            finally:
                os.close(write_fd)
            _metadata_capture(
                process, status, result, max_stdout_bytes, max_stderr_bytes, export_deadline
            )
            require(_read(source_path, len(source)) == source)
    if not result["stdout"] and result["failure"] is None and result["returncode"] == 0:
        result["failure"] = "producer_output_too_large"
    return result


def _test_documents(
    xcresult: Path,
    inventory: dict[str, Any],
    policy: Any,
    run: Any,
    deadline: float,
    diagnostics: _Diagnostics | None = None,
    metadata_run: Any = None,
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
        for name in ("summary", "tests"):
            command = [
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
            ]
            with _stage(name + "_query"):
                try:
                    captured = (
                        metadata_run(command)
                        if metadata_run
                        else {
                            "stdout": run(command, 16 * 1024 * 1024),
                            "stderr": b"",
                            "returncode": 0,
                            "failure": None,
                            "stdout_truncated": False,
                            "stderr_truncated": False,
                        }
                    )
                except BaseException as exc:
                    if diagnostics:
                        diagnostics.capture(
                            name,
                            getattr(
                                exc,
                                "metadata_capture",
                                {
                                    "stdout": b"",
                                    "stderr": b"",
                                    "returncode": None,
                                    "failure": "producer_cancelled"
                                    if isinstance(exc, KeyboardInterrupt)
                                    else "producer_unavailable",
                                    "stdout_truncated": False,
                                    "stderr_truncated": False,
                                },
                            ),
                        )
                    raise
                if diagnostics:
                    diagnostics.capture(name, captured)
                require(captured["failure"] is None and captured["returncode"] == 0)
            with _stage(name + "_json"):
                documents[name] = policy.strict_json(captured["stdout"])
        return documents


def _source_closure(
    repo: Path, exporter: Any, run: Any, deadline: float, platform: str = "ios"
) -> tuple:
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
    tracked = exporter._tracked_swift_sources(repo, platform, export_deadline=deadline)
    require(tracked and tracked <= set(sources))
    return head.decode(), sources, facts, tracked


# xctestrun Architectures lists x86_64 even on arm64 — not proof
def _products(products: Path, lane: str, platform: str = "ios") -> tuple[dict[str, Any], bytes]:
    require(platform in {"ios", "macos"} and (lane != "core" or platform == "ios"))
    folder = FOLDER if platform == "ios" else "Debug/"
    app = APP if platform == "ios" else folder + "AstralDeep.app"
    runner = RUNNER if platform == "ios" else folder + "AstralAppUITests-Runner.app"
    plugins = "/PlugIns/" if platform == "ios" else "/Contents/PlugIns/"
    executable = "/" if platform == "ios" else "/Contents/MacOS/"
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
            and unit.get("TestHostPath") == "__TESTROOT__/" + app
            and unit.get("TestBundlePath") == "__TESTHOST__" + plugins + "AstralAppTests.xctest"
        )
        require(
            ui.get("IsUITestBundle") is True
            and ui.get("TestHostBundleIdentifier")
            == "com.personalailabs.astraldeep.uitests.xctrunner"
            and ui.get("TestHostPath") == "__TESTROOT__/" + runner
            and ui.get("UITargetAppPath") == "__TESTROOT__/" + app
            and ui.get("TestBundlePath") == "__TESTHOST__" + plugins + "AstralAppUITests.xctest"
        )
        info = plistlib.loads(
            read(app + ("/Info.plist" if platform == "ios" else "/Contents/Info.plist"))
        )
        require(
            isinstance(info, dict)
            and info.get("CFBundleIdentifier") == "com.personalailabs.astraldeep"
            and info.get("CFBundleExecutable") == "AstralDeep"
            and info.get("CFBundlePackageType") == "APPL"
            and info.get("CFBundleSupportedPlatforms")
            == ["iPhoneSimulator" if platform == "ios" else "MacOSX"]
        )
        for name in (
            app + executable + "AstralDeep",
            app + plugins + "AstralAppTests.xctest" + executable + "AstralAppTests",
            runner + executable + "AstralAppUITests-Runner",
            runner + plugins + "AstralAppUITests.xctest" + executable + "AstralAppUITests",
        ):
            read(name)
            require(records[name]["mode"] & stat.S_IXUSR)
        instrumented("AstralDeep.app", app + executable + "AstralDeep")
        binary = read(app + executable + "AstralDeep.debug.dylib")
    return records, binary


def collect(
    *,
    repo: Path,
    products: Path,
    xcresult: Path,
    lane: str,
    output: Path,
    binary_archive: Path,
    platform: str = "ios",
) -> dict[str, Any]:
    require(
        platform in {"ios", "macos"}
        and lane in ({"core", "unit", "ui"} if platform == "ios" else {"unit", "ui"})
    )
    repo, products, xcresult = _path(repo), _path(products), _path(xcresult)
    output, binary_archive = _path(output), _path(binary_archive)
    require(output != binary_archive and xcresult.suffix == ".xcresult")
    artifact_member = f"coverage/native-binaries/apple-{platform}-{lane}.zip"
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
        source_before = _source_closure(repo, exporter, run, deadline, platform)
    with _stage("products_before"):
        product_before, binary = _products(products, lane, platform)
    with _stage("result_before"):
        result_before = _tree(xcresult, deadline)
    with _stage("diagnostics"):
        diagnostics = _Diagnostics(output)
    try:
        member = policy.binary_member(platform, lane)
        with _stage("binary_archive"):
            with _exclusive_output(binary_archive) as stream:
                with zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED) as bundle:
                    entry = zipfile.ZipInfo(member)
                    entry.create_system = 3
                    entry.external_attr = (stat.S_IFREG | 0o600) << 16
                    entry.compress_type = zipfile.ZIP_DEFLATED
                    bundle.writestr(entry, binary)
                stream.flush()
                stream.seek(0)
                archive_bytes = stream.read(MAX_FILE + 1)
                require(len(archive_bytes) <= MAX_FILE)
            require(_read(binary_archive) == archive_bytes)
        identity = {
            "member": member,
            "sha256": policy.sha256(binary),
            "artifact_member": artifact_member,
            "artifact_sha256": policy.sha256(archive_bytes),
        }
        documents = _test_documents(
            xcresult,
            result_before,
            policy,
            run,
            deadline,
            diagnostics,
            lambda command: _metadata_command(
                command,
                cwd=repo,
                max_stdout_bytes=16 * 1024 * 1024,
                max_stderr_bytes=exporter.MAX_FILE_LIST_BYTES,
                export_deadline=deadline,
            ),
        )
        with _stage("native_binary"):
            architecture = policy.macos_macho(binary, lane) if platform == "macos" else "arm64"
            if platform == "ios":
                policy.ios_macho(binary, lane)
        with _stage("test_identity"):
            policy.test_identity(
                documents["summary"],
                documents["tests"],
                lane,
                platform=platform,
                architecture=architecture,
            )
        with (
            _stage("mapping"),
            tempfile.TemporaryDirectory(prefix="astral-native-domain-") as directory,
        ):
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
                platform=platform,
            )
        with _stage("source_after"):
            require(source_before == _source_closure(repo, exporter, run, deadline, platform))
        with _stage("products_after"):
            require((product_before, binary) == _products(products, lane, platform))
        with _stage("result_after"):
            require(result_before == _tree(xcresult, deadline))
        with _stage("archive_after"):
            require(_read(binary_archive) == archive_bytes)
        with _stage("domain_validation"):
            policy.validate_domain(domain)
        with _stage("output"):
            with _exclusive_output(output) as stream:
                stream.write(policy.canonical(domain) + b"\n")
        return domain
    except BaseException as exc:
        stage = getattr(exc, "collection_stage", "inputs")
        stage = stage if isinstance(stage, str) and stage in STAGES else "inputs"
        diagnostics.write(
            "stage.json", policy.canonical({"stage": stage, "accepted": False}) + b"\n"
        )
        raise
    finally:
        with _stage("diagnostics"):
            diagnostics.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("repo", "products", "xcresult", "output", "binary-archive"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--lane", required=True, choices=("core", "unit", "ui"))
    parser.add_argument("--platform", choices=("ios", "macos"), default="ios")
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
    if len(sys.argv) >= 6 and sys.argv[1] == "--metadata-supervise":
        os.close(int(sys.argv[4]))
        _metadata_supervise(int(sys.argv[2]), int(sys.argv[3]), sys.argv[5:])
        os.close(1)
        os.close(2)
        while True:
            signal.pause()
    raise SystemExit(main())
