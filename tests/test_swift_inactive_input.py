"""Exercises the standalone whole-source compiler verifier with explicit native and tool-output fixtures.
Native Swift execution and its counters are checked by the separate Mac-only suite.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import time

import pytest

from scripts import swift_inactive_input as proof


SOURCE = b"#if os(macOS)\npublic func value() -> Int { 1 }\n#endif\n"


def macho(platform=7, cpu=0x0100000C, subtype=0, kind=1, minimum=0x110000, sdk=0x1A0500):
    return struct.pack("<8I", 0xFEEDFACF, cpu, subtype, kind, 1, 24, 0, 0) + struct.pack(
        "<6I", 0x32, 24, platform, minimum, sdk, 0
    )


@pytest.mark.parametrize(
    "platform,os_name,family",
    [(7, "iOS", "iphonesimulator"), (1, "macOS", "macosx"), (9, "watchOS", "watchsimulator")],
)
def test_native_targets_come_from_bounded_object_and_native_binary(platform, os_name, family):
    target = proof.bind_native_target(macho(platform, kind=6), macho(platform))
    assert target["os"] == os_name and target["sdk_family"] == family
    assert target["architecture"] == "arm64" and target["sdk"] == [26, 5, 0]


@pytest.mark.parametrize(
    "change",
    [
        "fat",
        "cpu",
        "subtype",
        "kind",
        "platform",
        "sdk",
        "minimum",
        "duplicate",
        "truncated",
        "legacy",
    ],
)
def test_native_target_mismatch_or_ambiguous_header_refuses(change):
    raw = macho()
    if change in {"fat", "cpu", "subtype", "kind"}:
        words = list(struct.unpack_from("<8I", raw))
        words[{"fat": 0, "cpu": 1, "subtype": 2, "kind": 3}[change]] = {
            "fat": 0xCAFEBABE,
            "cpu": 7,
            "subtype": 2,
            "kind": 2,
        }[change]
        raw = struct.pack("<8I", *words) + raw[32:]
    elif change == "platform":
        raw = macho(1)
    elif change == "sdk":
        raw = macho(sdk=0x1B0000)
    elif change == "minimum":
        raw = macho(minimum=0x120000)
    elif change == "duplicate":
        words = list(struct.unpack_from("<8I", raw))
        words[4:6] = [2, 48]
        raw = struct.pack("<8I", *words) + raw[32:] * 2
    elif change == "truncated":
        raw = raw[:-1]
    else:
        raw = raw[:32] + struct.pack("<6I", 0x24, 24, 7, 1, 1, 0)
    with pytest.raises(proof.ProofError):
        proof.bind_native_target(macho(kind=6), raw)


@pytest.mark.parametrize("raw", [b"{}", b"[]", b'{"x":1,"x":2}', b'{"x":NaN}', b"\xff"])
def test_syntax_json_is_closed_and_lossless(raw):
    with pytest.raises(proof.ProofError):
        proof.validate_syntax(raw, source=SOURCE, target_os="iOS")


def syntax(source, target_os, decision="inactive", predicate="macOS"):
    return json.dumps(
        {
            "format": "astral.swift-whole-os-syntax/v1",
            "source_bytes": len(source),
            "target_os": target_os,
            "decision": decision,
            "predicate": {"kind": "os", "name": predicate},
            "statement_count": 1,
            "clause_count": 1,
            "roundtrip": True,
            "parser_error": False,
            "diagnostic_count": 0,
        }
    ).encode()


@pytest.mark.parametrize(
    "field,value",
    [
        ("source_bytes", True),
        ("source_bytes", 1),
        ("target_os", "macOS"),
        ("decision", "active"),
        ("predicate", {"kind": "flag", "name": "DEBUG"}),
        ("predicate", {"kind": "os", "name": "iOS"}),
        ("statement_count", 2),
        ("clause_count", 2),
        ("roundtrip", False),
        ("parser_error", True),
        ("diagnostic_count", 1),
        ("extra", 1),
    ],
)
def test_syntax_disposition_cannot_hide_active_or_unrecognized_code(field, value):
    doc = json.loads(syntax(SOURCE, "iOS"))
    doc[field] = value
    with pytest.raises(proof.ProofError):
        proof.validate_syntax(json.dumps(doc).encode(), source=SOURCE, target_os="iOS")


@pytest.fixture
def pipeline(tmp_path):
    developer = tmp_path / "Xcode.app/Contents/Developer"
    toolchain = developer / "Toolchains/XcodeDefault.xctoolchain/usr"
    for name in (
        "bin/swiftc",
        "bin/swift-frontend",
        "bin/llvm-cov",
        "lib/swift/host/libSwiftParser.dylib",
        "lib/swift/host/libSwiftSyntax.dylib",
        "lib/swift/host/libSwiftIfConfig.dylib",
    ):
        path = toolchain / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(name.encode())
    xcode = developer / "usr/bin/xcodebuild"
    xcode.parent.mkdir(parents=True)
    xcode.write_bytes(b"xcodebuild")
    sdk = developer / "Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk"
    sdk.mkdir(parents=True)
    (sdk / "SDKSettings.plist").write_bytes(
        plistlib.dumps({"Version": "26.5", "CanonicalName": "iphonesimulator26.5"})
    )
    system = sdk / "System/Library/CoreServices/SystemVersion.plist"
    system.parent.mkdir(parents=True)
    system.write_bytes(
        plistlib.dumps({"ProductVersion": "26.5", "ProductBuildVersion": "SDKBuild"})
    )
    source = tmp_path / "Source.swift"
    source.write_bytes(SOURCE)
    binary = tmp_path / "native.dylib"
    binary.write_bytes(macho(kind=6))
    primary = tmp_path / "primary.o"
    primary.write_bytes(macho())
    arguments = dict(
        source=source,
        source_sha256=hashlib.sha256(SOURCE).hexdigest(),
        native_binary=binary,
        primary_object=primary,
        developer=developer,
        output=tmp_path / "proof",
    )
    state = {"change": None, "calls": []}

    def run(command, **kwargs):
        import os

        state["calls"].append(command)

        def generated(path):
            if path.is_absolute():
                return path.read_bytes()
            descriptor = os.open(
                str(path),
                os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=kwargs["directory_fd"],
            )
            with os.fdopen(descriptor, "rb") as stream:
                return stream.read()

        out, err = b"", b""
        if command[-1] == "-version" and command[0].endswith("xcodebuild"):
            out = (
                b"Xcode 26.6\nBuild version 17F113\n"
                if state["change"] != "toolchain"
                else b"Xcode 27.1\nBuild version 27A9275\n"
            )
        elif command[-1] == "--version":
            out = b"Apple LLVM version 21.0.0\n"
        elif command[-1] == "-version":
            out = b"Apple Swift version 6.2 (fixture)\n"
        elif Path(command[0]).name == "whole-os-proof":
            path, os_name = Path(command[1]), command[2]
            predicate = (
                os_name
                if path.name == "Active.swift"
                else ("macOS" if os_name != "macOS" else "iOS")
            )
            out = syntax(
                generated(path),
                os_name,
                "active" if path.name == "Active.swift" else "inactive",
                predicate,
            )
        elif "-dump-ast" in command:
            path = Path(command[-1])
            out = (
                '(source_file "'
                + str(path)
                + '"'
                + (' (func_decl "__astralGuardPositive()")' if path.name == "Active.swift" else "")
                + ")"
            ).encode()
        elif "-emit-silgen" in command:
            path = Path(command[-1])
            out = proof.empty_sil(path)
            if path.name == "Active.swift":
                out += b"sil @__astralGuardPositive : function\n"
        elif "-o" in command:
            target = Path(command[command.index("-o") + 1])
            if target.is_absolute():
                target.write_bytes(b"compiled helper fixture")
                target.chmod(0o700)
            else:
                descriptor = os.open(
                    str(target),
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                    0o700,
                    dir_fd=kwargs["directory_fd"],
                )
                with os.fdopen(descriptor, "wb") as stream:
                    stream.write(b"compiled helper fixture")
        else:
            pytest.fail(str(command))
        if (
            state["change"] == "active_ast"
            and "-dump-ast" in command
            and Path(command[-1]).name == "Input.swift"
        ):
            out += b"(func_decl hidden)"
        if (
            state["change"] == "active_sil"
            and "-emit-silgen" in command
            and Path(command[-1]).name == "Input.swift"
        ):
            out += b"sil @hidden : function\n"
        if state["change"] == "diagnostic" and "-dump-ast" in command:
            err = b"unknown diagnostic\n"
        if state["change"] == "source_race" and "-dump-ast" in command:
            source.write_bytes(SOURCE + b"// changed\n")
        if (
            state["change"] == "no_positive"
            and "-dump-ast" in command
            and Path(command[-1]).name == "Active.swift"
        ):
            out = ('(source_file "' + str(command[-1]) + '")').encode()
        return subprocess.CompletedProcess(command, 0, out, err)

    return arguments, state, run


def test_complete_proof_retains_raw_identity_and_never_claims_build_provenance(pipeline):
    arguments, state, run = pipeline
    value = proof.collect_proof(**arguments, run=run)
    assert value["format"] == "astral.swift-whole-os-inactive/v1"
    assert value["scope"] == "source-conditional-only" and value["build_provenance"] == "unverified"
    assert value["source"]["sha256"] == arguments["source_sha256"]
    assert value == json.loads((arguments["output"] / "proof.json").read_bytes())
    assert value["toolchain"]["xcode_build"] == "17F113"
    assert len(value["toolchain"]["files"]) == 9
    implementation = Path(proof.__file__).resolve()
    assert value["toolchain"]["files"][str(implementation)] == {
        "resolved": str(implementation),
        "sha256": hashlib.sha256(implementation.read_bytes()).hexdigest(),
    }
    assert all(
        (arguments["output"] / entry["member"]).is_file() for entry in value["raw_outputs"].values()
    )
    assert not any("-dump-parse" in call for call in state["calls"])


@pytest.mark.parametrize("toolchain_limit", [None, 4096])
def test_toolchain_files_may_exceed_the_input_bound_but_not_their_own(
    pipeline, monkeypatch, toolchain_limit
):
    arguments, _state, run = pipeline
    frontend = arguments["developer"] / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend"
    universal = b"\xca\xfe\xba\xbe" * 2048
    frontend.write_bytes(universal)
    monkeypatch.setattr(proof, "MAX_FILE", 4096)
    if toolchain_limit is not None:
        monkeypatch.setattr(proof, "MAX_TOOLCHAIN_FILE", toolchain_limit)
        with pytest.raises(proof.ProofError):
            proof.collect_proof(**arguments, run=run)
        assert not (arguments["output"] / "proof.json").exists()
        return
    value = proof.collect_proof(**arguments, run=run)
    assert value["toolchain"]["files"][str(frontend)] == {
        "resolved": str(frontend),
        "sha256": hashlib.sha256(universal).hexdigest(),
    }


@pytest.mark.parametrize(
    "change", ["toolchain", "active_ast", "active_sil", "diagnostic", "source_race", "no_positive"]
)
def test_canonical_collection_refuses_unqualified_or_contradictory_proof(pipeline, change):
    arguments, state, run = pipeline
    state["change"] = change
    with pytest.raises(proof.ProofError):
        proof.collect_proof(**arguments, run=run)
    assert not (arguments["output"] / "proof.json").exists()


@pytest.mark.parametrize(
    "change", ["hash", "source_link", "binary_link", "output_exists", "sdk", "tool_race"]
)
def test_input_identity_and_sdk_must_survive_collection(pipeline, change):
    arguments, state, run = pipeline
    if change == "hash":
        arguments["source_sha256"] = "f" * 64
    elif change in {"source_link", "binary_link"}:
        key = "source" if change == "source_link" else "native_binary"
        path = arguments[key]
        moved = path.with_name("real-" + path.name)
        path.rename(moved)
        path.symlink_to(moved)
    elif change == "output_exists":
        arguments["output"].mkdir()
    elif change == "sdk":
        next(arguments["developer"].rglob("SDKSettings.plist")).write_bytes(
            plistlib.dumps({"Version": "27.0", "CanonicalName": "iphonesimulator27.0"})
        )
    else:
        original = run

        def run(command, **kwargs):
            result = original(command, **kwargs)
            if "-dump-ast" in command:
                Path(command[0]).write_bytes(b"replaced")
            return result

    with pytest.raises(proof.ProofError):
        proof.collect_proof(**arguments, run=run)


def test_bounded_runner_refuses_exit_output_and_deadline(tmp_path):
    result = proof.run_command(
        [sys.executable, "-c", "print('bounded')"], cwd=tmp_path, deadline=time.monotonic() + 5
    )
    assert result.stdout == b"bounded\n" and result.returncode == 0
    with pytest.raises(proof.ProofError):
        proof.run_command(
            [sys.executable, "-c", "print('x' * 5000)"],
            cwd=tmp_path,
            deadline=time.monotonic() + 5,
            max_bytes=1024,
        )
    with pytest.raises(proof.ProofError):
        proof.run_command([sys.executable, "-c", "pass"], cwd=tmp_path, deadline=0)


def test_registered_tool_alias_is_bound_inside_the_selected_developer(pipeline):
    arguments, _state, run = pipeline
    swiftc = arguments["developer"] / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    swiftc.unlink()
    swiftc.symlink_to("swift-frontend")
    value = proof.collect_proof(**arguments, run=run)
    assert value["toolchain"]["files"][str(swiftc)]["resolved"] == str(swiftc.resolve())


def test_collector_owns_the_developer_environment(pipeline):
    arguments, _state, original = pipeline

    def run(command, **kwargs):
        assert kwargs["developer"] == arguments["developer"]
        return original(command, **kwargs)

    proof.collect_proof(**arguments, run=run)


def cli_args(arguments):
    result = []
    for name, value in arguments.items():
        result.extend(["--" + name.replace("_", "-"), str(value)])
    return result


def test_cli_runs_real_decisions_and_keeps_failure_output_private(pipeline, monkeypatch, capsys):
    arguments, _state, run = pipeline
    original = proof.collect_proof
    monkeypatch.setattr(proof, "collect_proof", lambda **kwargs: original(**kwargs, run=run))
    assert proof.main(cli_args(arguments)) == 0
    arguments["source_sha256"] = "private source code must not appear"
    assert proof.main(cli_args(arguments)) == 1
    assert capsys.readouterr().err == "swift_inactive_input_invalid\n"


def test_command_deadline_terminates_its_own_child(tmp_path):
    with pytest.raises(proof.ProofError):
        proof.run_command(
            [sys.executable, "-c", "import signal; signal.pause()"],
            cwd=tmp_path,
            deadline=time.monotonic() + 0.05,
        )


@pytest.mark.parametrize("change", ["utf8", "sdk_shape"])
def test_malformed_source_and_sdk_are_typed_refusals(pipeline, change):
    arguments, _state, run = pipeline
    if change == "utf8":
        arguments["source"].write_bytes(b"\xff")
        arguments["source_sha256"] = hashlib.sha256(b"\xff").hexdigest()
    else:
        next(arguments["developer"].rglob("SDKSettings.plist")).write_bytes(plistlib.dumps([]))
    with pytest.raises(proof.ProofError):
        proof.collect_proof(**arguments, run=run)


def test_tool_alias_target_identity_cannot_be_rewritten_with_same_bytes(pipeline):
    arguments, _state, original = pipeline
    library = (
        arguments["developer"]
        / "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/libSwiftSyntax.dylib"
    )
    target = library.with_name("syntax-real.dylib")
    library.rename(target)
    library.symlink_to(target.name)

    def run(command, **kwargs):
        result = original(command, **kwargs)
        if "-dump-ast" in command:
            target.write_bytes(target.read_bytes())
        return result

    with pytest.raises(proof.ProofError):
        proof.collect_proof(**arguments, run=run)


def test_real_runner_selects_developer_without_inheriting_sdk_or_loader(tmp_path, monkeypatch):
    monkeypatch.setenv("SDKROOT", "foreign-sdk")
    monkeypatch.setenv("DYLD_LIBRARY_PATH", "foreign-loader")
    result = proof.run_command(
        [
            sys.executable,
            "-c",
            "import os,json; print(json.dumps([os.environ.get('DEVELOPER_DIR'), 'SDKROOT' in os.environ, 'DYLD_LIBRARY_PATH' in os.environ]))",
        ],
        cwd=tmp_path,
        deadline=time.monotonic() + 5,
        developer=tmp_path,
    )
    assert json.loads(result.stdout) == [str(tmp_path), False, False]


def test_script_entry_point_refuses_source_identity_without_tool_execution(
    pipeline, monkeypatch, capsys
):
    import runpy

    arguments, _state, _run = pipeline
    arguments["source_sha256"] = "f" * 64
    monkeypatch.setattr(sys, "argv", [str(Path(proof.__file__)), *cli_args(arguments)])
    with pytest.raises(SystemExit) as result:
        runpy.run_path(proof.__file__, run_name="__main__")
    assert result.value.code == 1 and capsys.readouterr().err == "swift_inactive_input_invalid\n"


@pytest.mark.parametrize(
    "banner,accepted",
    [
        (b"Apple LLVM version 21.0.0\n  Optimized build.\n", True),
        (b"Apple LLVM version 21.0.0\nUnknown build.\n", False),
        (b"Apple LLVM version 21.0.0\n  Optimized build.\nextra\n", False),
    ],
)
def test_llvm_banner_accepts_only_the_known_closed_lines(pipeline, banner, accepted):
    arguments, _state, original = pipeline

    def run(command, **kwargs):
        result = original(command, **kwargs)
        if command[-1] == "--version":
            return subprocess.CompletedProcess(command, 0, banner, b"")
        return result

    if accepted:
        assert (
            proof.collect_proof(**arguments, run=run)["toolchain"]["llvm"]
            == "Apple LLVM version 21.0.0"
        )
    else:
        with pytest.raises(proof.ProofError):
            proof.collect_proof(**arguments, run=run)


def test_exited_parent_cannot_leave_an_inherited_pipe_descendant(tmp_path):
    import os
    import signal

    pidfile = tmp_path / "owned-child.json"
    script = "import json,os,pathlib,subprocess,sys; child=subprocess.Popen([sys.executable,'-c','import signal; signal.pause()']); pathlib.Path(sys.argv[1]).write_text(json.dumps({'pid':child.pid,'pgid':os.getpgid(child.pid),'sid':os.getsid(child.pid)}))"
    owned = None

    def running(pid):
        result = subprocess.run(
            ["ps", "-o", "state=", "-p", str(pid)], capture_output=True, text=True, timeout=5
        )
        state = result.stdout.strip()
        return bool(state) and not state.startswith("Z")

    try:
        with pytest.raises(proof.ProofError):
            proof.run_command(
                [sys.executable, "-c", script, str(pidfile)],
                cwd=tmp_path,
                deadline=time.monotonic() + 2,
            )
        owned = json.loads(pidfile.read_bytes())
        deadline = time.monotonic() + 2
        while running(owned["pid"]) and time.monotonic() < deadline:
            time.sleep(0.02)
        assert not running(owned["pid"])
    finally:
        if owned is None and pidfile.exists():
            owned = json.loads(pidfile.read_bytes())
        if owned is not None and running(owned["pid"]):
            if (
                os.getpgid(owned["pid"]) == owned["pgid"]
                and os.getsid(owned["pid"]) == owned["sid"]
            ):
                os.kill(owned["pid"], signal.SIGKILL)


def test_successful_parent_cannot_leave_a_detached_output_descendant(tmp_path):
    import os
    import signal

    pidfile = tmp_path / "owned-child.json"
    script = "import json,os,pathlib,subprocess,sys; child=subprocess.Popen([sys.executable,'-c','import signal; signal.pause()'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); pathlib.Path(sys.argv[1]).write_text(json.dumps({'pid':child.pid,'pgid':os.getpgid(child.pid),'sid':os.getsid(child.pid)}))"
    owned = None

    def running(pid):
        result = subprocess.run(
            ["ps", "-o", "state=", "-p", str(pid)], capture_output=True, text=True, timeout=5
        )
        state = result.stdout.strip()
        return bool(state) and not state.startswith("Z")

    try:
        result = proof.run_command(
            [sys.executable, "-c", script, str(pidfile)],
            cwd=tmp_path,
            deadline=time.monotonic() + 5,
        )
        assert result.returncode == 0
        owned = json.loads(pidfile.read_bytes())
        deadline = time.monotonic() + 2
        while running(owned["pid"]) and time.monotonic() < deadline:
            time.sleep(0.02)
        assert not running(owned["pid"])
    finally:
        if owned is None and pidfile.exists():
            owned = json.loads(pidfile.read_bytes())
        if owned is not None and running(owned["pid"]):
            if (
                os.getpgid(owned["pid"]) == owned["pgid"]
                and os.getsid(owned["pid"]) == owned["sid"]
            ):
                os.kill(owned["pid"], signal.SIGKILL)


def test_sdk_version_alias_is_bound_to_actual_selected_metadata(pipeline):
    arguments, state, run = pipeline
    alias = (
        arguments["developer"]
        / "Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk"
    )
    resolved = alias.with_name("iPhoneSimulator.sdk")
    alias.rename(resolved)
    alias.symlink_to(resolved.name, target_is_directory=True)
    value = proof.collect_proof(**arguments, run=run)
    assert value["target"]["sdk"] == [26, 5, 0]
    assert value["toolchain"]["sdk"]["alias"] == str(alias)
    assert value["toolchain"]["sdk"]["resolved"] == str(resolved)
    assert value["toolchain"]["sdk"]["version"] == "26.5"
    assert value["toolchain"]["sdk"]["canonical_name"] == "iphonesimulator26.5"
    assert all(str(resolved) in path for path in value["toolchain"]["sdk_files"])


@pytest.mark.parametrize("change", ["external", "family", "retarget", "replaced", "metadata"])
def test_sdk_alias_and_metadata_cannot_escape_or_change_during_collection(pipeline, change):
    arguments, state, run = pipeline
    alias = (
        arguments["developer"]
        / "Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk"
    )
    resolved = alias.with_name("iPhoneSimulator.sdk")
    alias.rename(resolved)
    alias.symlink_to(resolved.name, target_is_directory=True)
    if change == "external":
        external = arguments["source"].parent / "external-sdk"
        resolved.rename(external)
        alias.unlink()
        alias.symlink_to(external, target_is_directory=True)
    elif change == "family":
        metadata = resolved / "SDKSettings.plist"
        metadata.write_bytes(plistlib.dumps({"Version": "26.5", "CanonicalName": "macosx26.5"}))

    def changed(command, **kwargs):
        value = run(command, **kwargs)
        if "-dump-ast" in command and Path(command[-1]).name == "Input.swift":
            if change == "retarget":
                alias.unlink()
                alias.symlink_to("./" + resolved.name, target_is_directory=True)
            elif change == "replaced":
                resolved.rename(resolved.with_name("old-sdk"))
                resolved.mkdir()
            elif change == "metadata":
                metadata = resolved / "SDKSettings.plist"
                raw = metadata.read_bytes()
                metadata.unlink()
                metadata.write_bytes(raw)
        return value

    with pytest.raises(proof.ProofError):
        proof.collect_proof(**arguments, run=changed)
    assert not (arguments["output"] / "proof.json").exists()


@pytest.mark.parametrize("held", [False, True])
def test_supervisor_reports_actual_worker_exit_and_held_directory(tmp_path, monkeypatch, held):
    import os

    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("TMPDIR", str(tmp_path))
    read_fd, write_fd = os.pipe()
    directory_fd = os.open(tmp_path, os.O_RDONLY | os.O_DIRECTORY) if held else -1
    proof.supervise(
        write_fd,
        directory_fd,
        [
            sys.executable,
            "-c",
            "import pathlib,sys; pathlib.Path('worker').write_bytes(b'actual'); sys.exit(23)",
        ],
    )
    with os.fdopen(read_fd, "rb") as stream:
        assert stream.read() == b"23\n"
    assert (tmp_path / "worker").read_bytes() == b"actual"


def test_worker_early_pipe_closure_preserves_its_later_nonzero_exit(tmp_path):
    result = proof.run_command(
        [
            sys.executable,
            "-c",
            "import os,pathlib,sys; os.close(1); os.close(2); pathlib.Path('done').write_bytes(b'finished'); sys.exit(23)",
        ],
        cwd=tmp_path,
        deadline=time.monotonic() + 5,
    )
    assert result.returncode == 23 and result.stdout == result.stderr == b""
    assert (tmp_path / "done").read_bytes() == b"finished"


@pytest.mark.parametrize("interrupt", [False, True])
def test_worker_alive_after_early_pipe_closure_is_stopped_at_deadline(tmp_path, interrupt):
    import os
    import signal

    pidfile = tmp_path / "worker.json"
    script = "import json,os,pathlib,signal,sys; pathlib.Path(sys.argv[1]).write_text(json.dumps({'pid':os.getpid(),'pgid':os.getpgrp(),'sid':os.getsid(0)})); os.kill(os.getppid(),signal.SIGTERM) if sys.argv[2]=='interrupt' else None; os.close(1); os.close(2); signal.pause()"
    owned = None

    def running(pid):
        result = subprocess.run(
            ["ps", "-o", "state=", "-p", str(pid)], capture_output=True, text=True, timeout=5
        )
        state = result.stdout.strip()
        return bool(state) and not state.startswith("Z")

    try:
        with pytest.raises((proof.ProofError, ValueError)):
            proof.run_command(
                [
                    sys.executable,
                    "-c",
                    script,
                    str(pidfile),
                    "interrupt" if interrupt else "normal",
                ],
                cwd=tmp_path,
                deadline=time.monotonic() + 1,
            )
        owned = json.loads(pidfile.read_bytes())
        deadline = time.monotonic() + 2
        while running(owned["pid"]) and time.monotonic() < deadline:
            time.sleep(0.02)
        assert not running(owned["pid"])
    finally:
        if owned is None and pidfile.exists():
            owned = json.loads(pidfile.read_bytes())
        if owned is not None and running(owned["pid"]):
            if (
                os.getpgid(owned["pid"]) == owned["pgid"]
                and os.getsid(owned["pid"]) == owned["sid"]
            ):
                os.kill(owned["pid"], signal.SIGKILL)


def test_regular_to_fifo_swap_is_bounded_and_never_reads_data(tmp_path):
    import os

    probe = tmp_path / "fifo_probe.py"
    probe.write_text("""import json,os,sys
from pathlib import Path
from scripts import swift_inactive_input as proof
path=Path(sys.argv[1])/'source.swift'
path.write_bytes(b'fixture')
opened=proof.os.open
wrapped=proof.os.fdopen
state={'reads':0,'flags':0}
def replace(name,flags,*args,**kwargs):
 if Path(name)==path:
  path.unlink();os.mkfifo(path,0o600);state['flags']=flags
 return opened(name,flags,*args,**kwargs)
class Spy:
 def __init__(self,stream):self.stream=stream
 def __enter__(self):return self
 def __exit__(self,*args):self.stream.close()
 def fileno(self):return self.stream.fileno()
 def read(self,*args):state['reads']+=1;return self.stream.read(*args)
proof.os.open=replace
proof.os.fdopen=lambda *args,**kwargs:Spy(wrapped(*args,**kwargs))
try:proof.read(path)
except proof.ProofError:
 print(json.dumps(state));sys.exit(0)
sys.exit(3)
""")
    result = subprocess.run(
        [sys.executable, str(probe), str(tmp_path)], capture_output=True, text=True, timeout=2,
        env={**os.environ, "PYTHONPATH": str(Path(proof.__file__).resolve().parents[1])},
    )
    assert result.returncode == 0
    state = json.loads(result.stdout)
    assert state["reads"] == 0 and state["flags"] & os.O_NONBLOCK


def test_replaced_regular_descriptor_is_rejected_before_any_read(tmp_path, monkeypatch):
    import os

    source = tmp_path / "source.swift"
    replacement = tmp_path / "replacement.swift"
    source.write_bytes(b"old")
    replacement.write_bytes(b"operator data must not be read")
    original_open, original_fdopen = os.open, os.fdopen
    reads = []

    def replace(name, flags, *args, **kwargs):
        if Path(name) == source:
            os.replace(replacement, source)
        return original_open(name, flags, *args, **kwargs)

    class Spy:
        def __init__(self, stream):
            self.stream = stream

        def __enter__(self):
            return self

        def __exit__(self, *args):
            self.stream.close()

        def fileno(self):
            return self.stream.fileno()

        def read(self, *args):
            reads.append(True)
            return self.stream.read(*args)

    monkeypatch.setattr(proof.os, "open", replace)
    monkeypatch.setattr(
        proof.os, "fdopen", lambda *args, **kwargs: Spy(original_fdopen(*args, **kwargs))
    )
    with pytest.raises(proof.ProofError):
        proof.read(source)
    assert reads == []


@pytest.mark.parametrize(
    "attack", ["unsafe_parent", "stdout_leaf", "binary_leaf", "cache_leaf", "root_swap"]
)
def test_output_namespace_cannot_overwrite_an_operator_file(pipeline, attack):
    arguments, state, original = pipeline
    parent = arguments["output"].parent
    victim = parent / "operator-file"
    preimage = b"operator preimage"
    victim.write_bytes(preimage)
    hostile = parent / "hostile"
    hostile.mkdir(mode=0o700)
    if attack == "unsafe_parent":
        shared = parent / "shared"
        shared.mkdir(mode=0o777)
        shared.chmod(0o777)
        arguments["output"] = shared / "proof"

    def run(command, **kwargs):
        result = original(command, **kwargs)
        if command[-1] == "-version" and command[0].endswith("xcodebuild"):
            output = arguments["output"]
            if attack == "unsafe_parent":
                output.rename(output.with_name("old-output"))
                output.mkdir()
                (output / "xcode.stdout").symlink_to(victim)
            elif attack == "root_swap":
                output.rename(output.with_name("old-output"))
                output.symlink_to(hostile, target_is_directory=True)
            else:
                path = (
                    output
                    / {
                        "stdout_leaf": "xcode.stdout",
                        "binary_leaf": "whole-os-proof",
                        "cache_leaf": "host-cache",
                    }[attack]
                )
                if path.exists():
                    path.rename(path.with_name("old-" + path.name))
                path.symlink_to(
                    hostile if attack == "cache_leaf" else victim,
                    target_is_directory=attack == "cache_leaf",
                )
        return result

    with pytest.raises(proof.ProofError):
        proof.collect_proof(**arguments, run=run)
    assert victim.read_bytes() == preimage
    assert not (hostile / "proof.json").exists()
    if attack == "root_swap":
        assert list(hostile.iterdir()) == []
    if attack == "unsafe_parent":
        assert state["calls"] == []


def test_runner_uses_held_directory_when_its_path_is_replaced(tmp_path):
    import os

    directory = tmp_path / "original"
    directory.mkdir(mode=0o700)
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    moved = tmp_path / "held"
    directory.rename(moved)
    hostile = tmp_path / "hostile"
    hostile.mkdir(mode=0o700)
    directory.symlink_to(hostile, target_is_directory=True)
    try:
        result = proof.run_command(
            [
                sys.executable,
                "-c",
                "from pathlib import Path; Path('relative-output').write_text('owned')",
            ],
            cwd=directory,
            directory_fd=descriptor,
            deadline=time.monotonic() + 5,
        )
        assert result.returncode == 0
        assert (moved / "relative-output").read_text() == "owned"
        assert not (hostile / "relative-output").exists()
    finally:
        os.close(descriptor)


def test_output_parent_must_remain_private_through_collection(pipeline):
    arguments, _state, original = pipeline
    parent = arguments["output"].parent

    def run(command, **kwargs):
        result = original(command, **kwargs)
        if command[-1] == "-version" and command[0].endswith("xcodebuild"):
            parent.chmod(0o777)
        return result

    try:
        with pytest.raises(proof.ProofError):
            proof.collect_proof(**arguments, run=run)
    finally:
        parent.chmod(0o700)
