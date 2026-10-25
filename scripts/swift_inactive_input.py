#!/usr/bin/env python3
"""Verifies an intrinsic whole-source OS conditional with pinned Apple compiler tools and native target facts.
The standalone receipt supplies no build provenance or coverage disposition; future producer integration must bind those separately.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import selectors
import signal
import stat
import struct
import subprocess
import sys
import time
from typing import Any


MAX_FILE = 256 * 1024 * 1024
MAX_SOURCE = 16 * 1024 * 1024
MAX_TOOL = 4 * 1024 * 1024
TIME_BUDGET = 120
HELPER = Path(__file__).resolve().with_name("WholeOSInputProof.swift")
PLATFORMS = {
    7: ("iOS", "iphonesimulator", "iPhoneSimulator", "ios", "-simulator"),
    1: ("macOS", "macosx", "MacOSX", "macosx", ""),
    9: ("watchOS", "watchsimulator", "WatchSimulator", "watchos", "-simulator"),
}


class ProofError(ValueError):
    def __init__(self) -> None:
        super().__init__("swift_inactive_input_invalid")


def require(value: Any) -> None:
    if not value:
        raise ProofError()


def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def read(path: Path, maximum: int = MAX_FILE) -> bytes:
    require(path.is_absolute() and path == path.resolve() and not path.is_symlink())
    before = path.lstat()
    require(stat.S_ISREG(before.st_mode) and before.st_size <= maximum)
    fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns", "st_mode")
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as stream:
        opened = os.fstat(stream.fileno())
        require(stat.S_ISREG(opened.st_mode) and opened.st_size <= maximum)
        require(all(getattr(before, key) == getattr(opened, key) for key in fields))
        raw = stream.read(maximum + 1)
        after = os.fstat(stream.fileno())
    final = path.lstat()
    require(
        len(raw) == opened.st_size <= maximum
        and all(
            getattr(before, key)
            == getattr(opened, key)
            == getattr(after, key)
            == getattr(final, key)
            for key in fields
        )
    )
    return raw


def version(number: int) -> list[int]:
    return [number >> 16, (number >> 8) & 255, number & 255]


def version_text(value: list[int]) -> str:
    return ".".join(map(str, value[:2] if value[2] == 0 else value))


def native_target(raw: bytes, *, primary: bool) -> dict[str, Any]:
    require(isinstance(raw, bytes) and 32 <= len(raw) <= MAX_FILE)
    magic, cpu, subtype, kind, count, size, _flags, reserved = struct.unpack_from("<8I", raw)
    architecture = {(0x0100000C, 0): "arm64", (0x01000007, 3): "x86_64"}.get((cpu, subtype))
    require(
        magic == 0xFEEDFACF
        and architecture is not None
        and reserved == 0
        and (kind == 1 if primary else kind in {2, 6, 8})
    )
    require(0 < count <= 4096 and count * 8 <= size <= len(raw) - 32)
    offset, builds = 32, []
    for _ in range(count):
        require(offset + 8 <= 32 + size)
        command, length = struct.unpack_from("<II", raw, offset)
        require(length >= 8 and length % 8 == 0 and offset + length <= 32 + size)
        require(command not in {0x24, 0x25, 0x2F, 0x30})
        if command == 0x32:
            require(length >= 24)
            platform, minimum, sdk, tools = struct.unpack_from("<4I", raw, offset + 8)
            require(platform in PLATFORMS and minimum > 0 and sdk > 0 and length == 24 + tools * 8)
            builds.append((platform, minimum, sdk))
        offset += length
    require(offset == 32 + size and len(builds) == 1)
    platform, minimum, sdk = builds[0]
    os_name, family, sdk_name, triple_os, suffix = PLATFORMS[platform]
    return {
        "platform": platform,
        "os": os_name,
        "sdk_family": family,
        "sdk_name": sdk_name,
        "architecture": architecture,
        "minimum": version(minimum),
        "sdk": version(sdk),
        "triple": f"{architecture}-apple-{triple_os}{version_text(version(minimum))}{suffix}",
    }


def bind_native_target(binary: bytes, primary_object: bytes) -> dict[str, Any]:
    native, primary = (
        native_target(binary, primary=False),
        native_target(primary_object, primary=True),
    )
    require(all(native[key] == primary[key] for key in ("platform", "architecture", "sdk")))
    require(primary["minimum"] <= native["minimum"])
    return primary


def strict_json(raw: bytes) -> Any:
    require(isinstance(raw, bytes) and 0 < len(raw) <= MAX_TOOL)

    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result)
            result[key] = value
        return result

    try:
        return json.loads(
            raw.decode("utf-8", "strict"),
            object_pairs_hook=unique,
            parse_constant=lambda _: require(False),
        )
    except (UnicodeError, ValueError, RecursionError) as exc:
        raise ProofError() from exc


def validate_syntax(
    raw: bytes, *, source: bytes, target_os: str, decision: str = "inactive"
) -> dict[str, Any]:
    value = strict_json(raw)
    require(
        isinstance(value, dict)
        and set(value)
        == {
            "format",
            "source_bytes",
            "target_os",
            "decision",
            "predicate",
            "statement_count",
            "clause_count",
            "roundtrip",
            "parser_error",
            "diagnostic_count",
        }
    )
    require(
        value["format"] == "astral.swift-whole-os-syntax/v1"
        and value["target_os"] == target_os
        and value["decision"] == decision
    )
    require(type(value["source_bytes"]) is int and value["source_bytes"] == len(source))
    require(
        all(
            type(value[key]) is int and value[key] == expected
            for key, expected in (
                ("statement_count", 1),
                ("clause_count", 1),
                ("diagnostic_count", 0),
            )
        )
    )
    require(value["roundtrip"] is True and value["parser_error"] is False)
    predicate = value["predicate"]
    require(
        isinstance(predicate, dict)
        and set(predicate) == {"kind", "name"}
        and predicate["kind"] == "os"
        and predicate["name"] in {"iOS", "macOS", "watchOS"}
    )
    require((predicate["name"] == target_os) == (decision == "active"))
    return value


def empty_ast(path: Path) -> bytes:
    require(not any(character in str(path) for character in ('"', "\\", "\n", "\r")))
    return ('(source_file "' + str(path) + '")').encode()


def empty_sil(path: Path) -> bytes:
    require(not any(character in str(path) for character in ("'", "\\", "\n", "\r")))
    return (
        "sil_stage raw\n\nimport Builtin\nimport Swift\nimport SwiftShims\n\n// Mappings from '#fileID' to '#filePath':\n//   'AstralInactiveProof/"
        + path.name
        + "' => '"
        + str(path)
        + "'\n"
    ).encode()


def validate_empty(ast: bytes, sil: bytes, path: Path) -> None:
    require(ast.strip(b" \n\r\t") == empty_ast(path))
    require(
        [line.strip() for line in sil.splitlines() if line.strip()]
        == [line.strip() for line in empty_sil(path).splitlines() if line.strip()]
    )


_DIRECTORY_FIELDS = ("st_dev", "st_ino", "st_mode", "st_uid", "st_gid")
_FILE_FIELDS = (
    "st_dev",
    "st_ino",
    "st_size",
    "st_mtime_ns",
    "st_ctime_ns",
    "st_mode",
    "st_uid",
    "st_gid",
    "st_nlink",
)
_DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK


def same_identity(first, second, fields) -> bool:
    return all(getattr(first, field) == getattr(second, field) for field in fields)


class PrivateOutput:
    def __init__(self, path: Path):
        self.path, self.descriptors, self.files, self.caches = path, [], {}, {}
        self.binary_ready = False
        self.ancestry, self.links = [], []
        try:
            require(
                path.is_absolute() and path == path.resolve() and path.name not in {"", ".", ".."}
            )
            require(len(path.parts) <= 64)
            descriptor = os.open("/", _DIRECTORY_FLAGS)
            self.descriptors.append(descriptor)
            self.ancestry.append((descriptor, os.fstat(descriptor)))
            for part in path.parent.parts[1:]:
                parent = os.fstat(descriptor)
                before = os.stat(part, dir_fd=descriptor, follow_symlinks=False)
                require(stat.S_ISDIR(before.st_mode) and before.st_uid in {0, os.geteuid()})
                require(
                    not before.st_mode & 0o022
                    or before.st_uid == 0
                    and before.st_mode & stat.S_ISVTX
                )
                if parent.st_mode & 0o022:
                    require(parent.st_uid == 0 and parent.st_mode & stat.S_ISVTX)
                child = os.open(part, _DIRECTORY_FLAGS, dir_fd=descriptor)
                self.descriptors.append(child)
                require(same_identity(before, os.fstat(child), _DIRECTORY_FIELDS))
                self.ancestry.append((child, before))
                self.links.append((descriptor, part, before))
                descriptor = child
            self.parent_fd = descriptor
            parent = os.fstat(descriptor)
            require(parent.st_uid == os.geteuid() and parent.st_mode & 0o777 == 0o700)
            os.mkdir(path.name, mode=0o700, dir_fd=descriptor)
            self.fd = os.open(path.name, _DIRECTORY_FLAGS, dir_fd=descriptor)
            self.descriptors.append(self.fd)
            self.identity = os.fstat(self.fd)
            for name in ("host-cache", "target-cache"):
                os.mkdir(name, mode=0o700, dir_fd=self.fd)
                cached = os.open(name, _DIRECTORY_FLAGS, dir_fd=self.fd)
                self.descriptors.append(cached)
                self.caches[name] = (cached, os.fstat(cached))
            self.check()
        except BaseException:
            self.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        for descriptor in reversed(self.descriptors):
            os.close(descriptor)
        self.descriptors = []

    def check(self, *, new_binary=False):
        require(self.path == self.path.resolve())
        for descriptor, identity in self.ancestry:
            require(same_identity(identity, os.fstat(descriptor), _DIRECTORY_FIELDS))
        for descriptor, name, identity in self.links:
            require(
                same_identity(
                    identity,
                    os.stat(name, dir_fd=descriptor, follow_symlinks=False),
                    _DIRECTORY_FIELDS,
                )
            )
        require(same_identity(self.identity, os.fstat(self.fd), _DIRECTORY_FIELDS))
        require(same_identity(self.identity, self.path.lstat(), _DIRECTORY_FIELDS))
        require(
            same_identity(
                self.identity,
                os.stat(self.path.name, dir_fd=self.parent_fd, follow_symlinks=False),
                _DIRECTORY_FIELDS,
            )
        )
        for name, (descriptor, identity) in self.caches.items():
            require(same_identity(identity, os.fstat(descriptor), _DIRECTORY_FIELDS))
            require(
                same_identity(
                    identity,
                    os.stat(name, dir_fd=self.fd, follow_symlinks=False),
                    _DIRECTORY_FIELDS,
                )
            )
        for name, identity in self.files.items():
            require(
                same_identity(
                    identity, os.stat(name, dir_fd=self.fd, follow_symlinks=False), _FILE_FIELDS
                )
            )
        if not self.binary_ready and not new_binary:
            try:
                os.stat("whole-os-proof", dir_fd=self.fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                require(False)

    def write(self, name: str, raw: bytes, mode=0o600):
        self.check()
        require(name == Path(name).name and name not in {"", ".", ".."})
        descriptor = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_NONBLOCK,
            mode,
            dir_fd=self.fd,
        )
        with os.fdopen(descriptor, "wb") as stream:
            opened = os.fstat(stream.fileno())
            require(
                stat.S_ISREG(opened.st_mode)
                and opened.st_uid == os.geteuid()
                and opened.st_nlink == 1
            )
            stream.write(raw)
            stream.flush()
            self.files[name] = os.fstat(stream.fileno())
        self.check()

    def read(self, name: str, *, adopt=False):
        self.check(new_binary=adopt)
        before = os.stat(name, dir_fd=self.fd, follow_symlinks=False)
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.fd)
        with os.fdopen(descriptor, "rb") as stream:
            opened = os.fstat(stream.fileno())
            require(
                stat.S_ISREG(opened.st_mode)
                and opened.st_size <= MAX_FILE
                and opened.st_uid == os.geteuid()
                and opened.st_nlink == 1
            )
            require(same_identity(before, opened, _FILE_FIELDS))
            if adopt:
                require(opened.st_mode & stat.S_IXUSR and not opened.st_mode & 0o022)
                os.fchmod(stream.fileno(), 0o500)
                opened = os.fstat(stream.fileno())
            raw = stream.read(MAX_FILE + 1)
            after = os.fstat(stream.fileno())
        require(
            len(raw) == opened.st_size <= MAX_FILE and same_identity(opened, after, _FILE_FIELDS)
        )
        require(
            same_identity(after, os.stat(name, dir_fd=self.fd, follow_symlinks=False), _FILE_FIELDS)
        )
        if adopt:
            self.files[name] = after
            self.binary_ready = True
        self.check()
        return raw


def supervise(status_fd: int, directory_fd: int, arguments: list[str]) -> None:
    if directory_fd >= 0:
        os.fchdir(directory_fd)
        os.environ["HOME"] = os.getcwd()
        os.environ["TMPDIR"] = os.getcwd() + os.sep
        os.close(directory_fd)
    child = subprocess.Popen(arguments, close_fds=True)
    code = child.wait()
    os.write(status_fd, str(code).encode() + b"\n")
    os.close(status_fd)


def run_command(
    command: list[str],
    *,
    cwd: Path,
    deadline: float,
    max_bytes: int = MAX_TOOL,
    developer: Path | None = None,
    directory_fd: int | None = None,
) -> subprocess.CompletedProcess:
    require(time.monotonic() < deadline)
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(cwd), "TMPDIR": str(cwd)}
    if developer is not None:
        environment["DEVELOPER_DIR"] = str(developer)
    if directory_fd is not None:
        require(stat.S_ISDIR(os.fstat(directory_fd).st_mode))
    read_fd, write_fd = os.pipe()
    try:
        with os.fdopen(read_fd, "rb") as status:
            read_fd = None
            with subprocess.Popen(
                [
                    sys.executable,
                    "-I",
                    "-S",
                    str(Path(__file__).resolve()),
                    "--supervise",
                    str(write_fd),
                    str(directory_fd if directory_fd is not None else -1),
                    *command,
                ],
                cwd=cwd if directory_fd is None else None,
                pass_fds=(write_fd,) if directory_fd is None else (write_fd, directory_fd),
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            ) as process:
                os.close(write_fd)
                write_fd = None
                streams = None
                output = {"stdout": bytearray(), "stderr": bytearray(), "status": bytearray()}
                try:
                    streams = selectors.DefaultSelector()
                    for key in output:
                        stream = status if key == "status" else getattr(process, key)
                        os.set_blocking(stream.fileno(), False)
                        streams.register(stream, selectors.EVENT_READ, key)
                    while streams.get_map():
                        require(time.monotonic() < deadline)
                        for key, _ in streams.select(min(0.1, max(0, deadline - time.monotonic()))):
                            raw = os.read(key.fileobj.fileno(), 65536)
                            if raw:
                                output[key.data].extend(raw)
                                require(len(output["status"]) <= 16)
                                require(len(output["stdout"]) + len(output["stderr"]) <= max_bytes)
                            else:
                                streams.unregister(key.fileobj)
                    result = int(output["status"])
                    require(
                        -255 <= result <= 255 and str(result).encode() + b"\n" == output["status"]
                    )
                finally:
                    if streams is not None:
                        streams.close()
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    finally:
                        process.wait()
                return subprocess.CompletedProcess(
                    command, result, bytes(output["stdout"]), bytes(output["stderr"])
                )
    finally:
        for descriptor in (read_fd, write_fd):
            if descriptor is not None:
                os.close(descriptor)


def _collect_source(
    *,
    source: Path,
    source_sha256: str,
    native_binary: Path,
    primary_object: Path,
    developer: Path,
    output: Path,
    storage: PrivateOutput,
    deadline: float,
    run=run_command,
) -> dict[str, Any]:
    inputs = {
        path: read(path, MAX_SOURCE if path == source else MAX_FILE)
        for path in (source, native_binary, primary_object)
    }
    raw = inputs[source]
    require(0 < len(raw) <= MAX_SOURCE and digest(raw) == source_sha256)
    raw.decode("utf-8", "strict")
    target = bind_native_target(inputs[native_binary], inputs[primary_object])
    require(developer.is_absolute() and developer == developer.resolve() and developer.is_dir())
    toolchain = developer / "Toolchains/XcodeDefault.xctoolchain/usr"
    implementation = Path(__file__).resolve()
    tools = [
        developer / "usr/bin/xcodebuild",
        *(toolchain / "bin" / name for name in ("swiftc", "swift-frontend", "llvm-cov")),
        *(
            toolchain / "lib/swift/host" / name
            for name in ("libSwiftParser.dylib", "libSwiftSyntax.dylib", "libSwiftIfConfig.dylib")
        ),
        HELPER,
        implementation,
    ]
    tool_bytes = {}
    for path in tools:
        resolved = path.resolve()
        require(resolved.is_relative_to(developer) or path in {HELPER, implementation})
        tool_bytes[path] = (resolved, digest(read(resolved)), path.lstat(), resolved.lstat())
    outputs, commands = {}, []

    def command(name, arguments, *, diagnostics=False, produces_binary=False):
        storage.check()
        result = run(
            arguments, cwd=output, deadline=deadline, developer=developer, directory_fd=storage.fd
        )
        storage.check(new_binary=produces_binary)
        require(result.returncode == 0)
        if produces_binary:
            storage.read("whole-os-proof", adopt=True)
        require(
            isinstance(result.stdout, bytes)
            and isinstance(result.stderr, bytes)
            and len(result.stdout) + len(result.stderr) <= MAX_TOOL
        )
        for channel in ("stdout", "stderr"):
            member = name + "." + channel
            value = getattr(result, channel)
            storage.write(member, value)
            outputs[member] = {"member": member, "sha256": digest(value)}
        commands.append(arguments)
        require(result.returncode == 0 and (not diagnostics or not result.stderr.strip()))
        return result.stdout

    require(
        command("xcode", [str(tools[0]), "-version"]).strip() == b"Xcode 26.6\nBuild version 17F113"
    )
    require(
        command("llvm", [str(tools[3]), "--version"]).splitlines()
        in ([b"Apple LLVM version 21.0.0"], [b"Apple LLVM version 21.0.0", b"  Optimized build."])
    )
    swift_version = command("swift", [str(tools[2]), "-version"]).decode("utf-8", "strict").strip()
    require(swift_version.startswith("Apple Swift version ") and len(swift_version) <= 1024)
    sdk_alias = (
        developer
        / "Platforms"
        / (target["sdk_name"] + ".platform")
        / "Developer/SDKs"
        / (target["sdk_name"] + version_text(target["sdk"]) + ".sdk")
    )
    namespace = sdk_alias.parent
    require(namespace == namespace.resolve() and namespace.is_dir())
    sdk = sdk_alias.resolve(strict=True)
    require(
        sdk.parent == namespace
        and sdk.name
        in {target["sdk_name"] + ".sdk", target["sdk_name"] + version_text(target["sdk"]) + ".sdk"}
        and sdk.is_dir()
    )
    sdk_identity = (sdk_alias.lstat(), sdk.lstat(), namespace.lstat())
    sdk_link = os.readlink(sdk_alias) if sdk_alias.is_symlink() else None
    sdk_files = [sdk / "SDKSettings.plist", sdk / "System/Library/CoreServices/SystemVersion.plist"]
    sdk_bytes = {path: read(path) for path in sdk_files}
    sdk_file_identity = {path: path.lstat() for path in sdk_files}
    settings, system = (plistlib.loads(sdk_bytes[path]) for path in sdk_files)
    require(isinstance(settings, dict) and isinstance(system, dict))
    require(
        settings.get("Version") == version_text(target["sdk"])
        and settings.get("CanonicalName") == target["sdk_family"] + version_text(target["sdk"])
    )
    require(
        system.get("ProductVersion") == version_text(target["sdk"])
        and isinstance(system.get("ProductBuildVersion"), str)
        and 0 < len(system["ProductBuildVersion"]) <= 128
    )
    host = toolchain / "lib/swift/host"
    binary = Path("whole-os-proof")
    command(
        "build-helper",
        [
            "/usr/bin/xcrun",
            "--sdk",
            "macosx",
            str(tools[1]),
            str(HELPER),
            "-I",
            str(host),
            "-L",
            str(host),
            "-lSwiftParser",
            "-lSwiftSyntax",
            "-lSwiftIfConfig",
            "-Xlinker",
            "-rpath",
            "-Xlinker",
            str(host),
            "-module-cache-path",
            "host-cache",
            "-o",
            str(binary),
        ],
        diagnostics=True,
        produces_binary=True,
    )
    helper_binary = storage.read("whole-os-proof")
    alternate = "macOS" if target["os"] != "macOS" else "iOS"
    sources = {
        "Active.swift": f"#if os({target['os']})\nfunc __astralGuardPositive() -> Int {{ 1 }}\n#endif\n".encode(),
        "Inactive.swift": f"#if os({alternate})\nfunc __astralGuardPositive() -> Int {{ 1 }}\n#endif\n".encode(),
        "Input.swift": raw,
    }
    syntax = None
    for name, value in sources.items():
        path = Path(name)
        storage.write(name, value, mode=0o400)
        parsed = command(
            name + "-syntax", ["./whole-os-proof", str(path), target["os"]], diagnostics=True
        )
        checked = validate_syntax(
            parsed,
            source=value,
            target_os=target["os"],
            decision="active" if name == "Active.swift" else "inactive",
        )
        values = {}
        for mode in ("-dump-ast", "-emit-silgen"):
            values[mode] = command(
                name + mode,
                [
                    str(tools[2]),
                    "-frontend",
                    mode,
                    "-parse-as-library",
                    "-swift-version",
                    "5",
                    "-module-name",
                    "AstralInactiveProof",
                    "-target",
                    target["triple"],
                    "-sdk",
                    str(sdk),
                    "-module-cache-path",
                    "target-cache",
                    str(path),
                ],
                diagnostics=True,
            )
        if name == "Active.swift":
            require(
                b"(func_decl" in values["-dump-ast"]
                and b"__astralGuardPositive" in values["-dump-ast"]
            )
            require(
                any(
                    line.startswith(b"sil ") and b"__astralGuardPositive" in line
                    for line in values["-emit-silgen"].splitlines()
                )
            )
        else:
            validate_empty(values["-dump-ast"], values["-emit-silgen"], path)
        require(storage.read(name) == value and storage.read("whole-os-proof") == helper_binary)
        if name == "Input.swift":
            syntax = checked
    require(
        all(
            read(path, MAX_SOURCE if path == source else MAX_FILE) == value
            for path, value in inputs.items()
        )
    )
    require(all(read(path) == value for path, value in sdk_bytes.items()))
    require(sdk_alias.resolve(strict=True) == sdk and namespace == namespace.resolve())
    require((os.readlink(sdk_alias) if sdk_alias.is_symlink() else None) == sdk_link)
    require(
        all(
            same_identity(before, path.lstat(), _FILE_FIELDS)
            for before, path in zip(sdk_identity, (sdk_alias, sdk, namespace), strict=True)
        )
    )
    require(
        all(
            same_identity(before, path.lstat(), _FILE_FIELDS)
            for path, before in sdk_file_identity.items()
        )
    )
    fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns", "st_mode")
    for path, (resolved, value, before, target_before) in tool_bytes.items():
        require(path.resolve() == resolved and digest(read(resolved)) == value)
        after = path.lstat()
        target_after = resolved.lstat()
        require(
            all(
                getattr(before, field) == getattr(after, field)
                and getattr(target_before, field) == getattr(target_after, field)
                for field in fields
            )
        )
    receipt = {
        "format": "astral.swift-whole-os-inactive/v1",
        "scope": "source-conditional-only",
        "build_provenance": "unverified",
        "source": {
            "sha256": digest(raw),
            "bytes": len(raw),
            "physical_lines": raw.count(b"\n") + int(not raw.endswith(b"\n")),
        },
        "native_binary_sha256": digest(inputs[native_binary]),
        "primary_object_sha256": digest(inputs[primary_object]),
        "target": target,
        "syntax": syntax,
        "toolchain": {
            "xcode_build": "17F113",
            "llvm": "Apple LLVM version 21.0.0",
            "swift": swift_version,
            "files": {
                str(path): {"resolved": str(resolved), "sha256": value}
                for path, (resolved, value, _before, _target_before) in tool_bytes.items()
            },
            "sdk_files": {str(path): digest(value) for path, value in sdk_bytes.items()},
            "sdk": {
                "alias": str(sdk_alias),
                "resolved": str(sdk),
                "version": settings["Version"],
                "canonical_name": settings["CanonicalName"],
            },
            "helper_binary_sha256": digest(helper_binary),
        },
        "raw_outputs": outputs,
        "commands": commands,
    }
    storage.write(
        "proof.json", (json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n").encode()
    )
    return receipt


def _collect_proof(
    *,
    source: Path,
    source_sha256: str,
    native_binary: Path,
    primary_object: Path,
    developer: Path,
    output: Path,
    run=run_command,
):
    deadline = time.monotonic() + TIME_BUDGET
    with PrivateOutput(output) as storage:
        return _collect_source(
            source=source,
            source_sha256=source_sha256,
            native_binary=native_binary,
            primary_object=primary_object,
            developer=developer,
            output=output,
            storage=storage,
            deadline=deadline,
            run=run,
        )


def collect_proof(
    *,
    source: Path,
    source_sha256: str,
    native_binary: Path,
    primary_object: Path,
    developer: Path,
    output: Path,
    run=run_command,
) -> dict[str, Any]:
    try:
        return _collect_proof(
            source=source,
            source_sha256=source_sha256,
            native_binary=native_binary,
            primary_object=primary_object,
            developer=developer,
            output=output,
            run=run,
        )
    except ProofError:
        raise
    except (
        ValueError,
        OSError,
        TypeError,
        KeyError,
        struct.error,
        subprocess.SubprocessError,
    ) as exc:
        raise ProofError() from exc


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source", "native-binary", "primary-object", "developer", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--source-sha256", required=True)
    try:
        collect_proof(**vars(parser.parse_args(argv)))
    except (ValueError, OSError, TypeError, KeyError, struct.error, subprocess.SubprocessError):
        print("swift_inactive_input_invalid", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--supervise":
        supervise(int(sys.argv[2]), int(sys.argv[3]), sys.argv[4:])
        os.close(1)
        os.close(2)
        while True:
            signal.pause()
    else:
        raise SystemExit(main())
