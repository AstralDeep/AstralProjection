"""Runs the standalone Swift syntax helper and retains its actual native counters on macOS.
These tool-level diagnostics do not certify a canonical compiler-input or coverage artifact.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

from scripts import swift_inactive_input as proof


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/WholeOSInputProof.swift"
pytestmark = pytest.mark.skipif(
    sys.platform != "darwin", reason="The bundled Apple host parser is a macOS tool"
)


@pytest.fixture(scope="module")
def native_tool(tmp_path_factory):
    root = tmp_path_factory.mktemp("native-proof")
    selected = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip())
    host = selected.parents[1] / "lib/swift/host"
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    before = HELPER.read_bytes()
    command = [
        str(selected),
        str(HELPER),
        "-sdk",
        sdk,
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
        "-profile-generate",
        "-profile-coverage-mapping",
        "-module-cache-path",
        str(root / "cache"),
        "-o",
        str(root / "whole-os-proof"),
    ]
    result = subprocess.run(command, capture_output=True, timeout=45)
    (root / "build.stdout").write_bytes(result.stdout)
    (root / "build.stderr").write_bytes(result.stderr)
    assert result.returncode == 0, result.stderr.decode()
    assert HELPER.read_bytes() == before
    record = {
        "extent": "native helper diagnostics only; no canonical 17F113 artifact assertion",
        "source_sha256": hashlib.sha256(before).hexdigest(),
        "command": command,
        "tool_version": subprocess.check_output([str(selected), "-version"], text=True),
        "runs": [],
        "compiler_controls": [],
        "tool_files": {
            str(path): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in [
                selected.resolve(),
                *(
                    host / name
                    for name in (
                        "libSwiftParser.dylib",
                        "libSwiftSyntax.dylib",
                        "libSwiftIfConfig.dylib",
                    )
                ),
            ]
        },
    }

    def run(raw, target="iOS", missing=False):
        source = root / (str(len(record["runs"])) + ".swift")
        if not missing:
            source.write_bytes(raw)
        command = [str(root / "whole-os-proof"), str(source), target]
        result = subprocess.run(
            command,
            capture_output=True,
            timeout=10,
            env={**os.environ, "LLVM_PROFILE_FILE": str(root / "run-%p-%m.profraw")},
        )
        record["runs"].append(
            {
                "command": command,
                "source_sha256": hashlib.sha256(raw).hexdigest(),
                "exit": result.returncode,
                "stdout": result.stdout.decode(),
                "stderr": result.stderr.decode(),
            }
        )
        assert result.returncode == 0
        return json.loads(result.stdout)

    run.evidence_root = root
    run.evidence_record = record
    yield run
    assert HELPER.read_bytes() == before
    assert all(
        hashlib.sha256(Path(path).read_bytes()).hexdigest() == expected
        for path, expected in record["tool_files"].items()
    )
    profiles = sorted(root.glob("*.profraw"))
    assert profiles
    merge = [
        "xcrun",
        "llvm-profdata",
        "merge",
        "-sparse",
        *map(str, profiles),
        "-o",
        str(root / "merged.profdata"),
    ]
    subprocess.run(merge, check=True, capture_output=True, timeout=20)
    export = [
        "xcrun",
        "llvm-cov",
        "export",
        "-format=lcov",
        "-instr-profile=" + str(root / "merged.profdata"),
        str(root / "whole-os-proof"),
    ]
    output = subprocess.check_output(export, timeout=20)
    (root / "native.lcov").write_bytes(output)
    record.update(
        merge_command=merge,
        export_command=export,
        binary_sha256=hashlib.sha256((root / "whole-os-proof").read_bytes()).hexdigest(),
    )
    (root / "receipt.json").write_text(json.dumps(record, indent=2) + "\n")
    source_records = [
        block
        for block in output.decode().split("end_of_record")
        if "SF:" + str(HELPER) + "\n" in block
    ]
    assert len(source_records) == 1
    lines = [row.split(",") for row in source_records[0].splitlines() if row.startswith("DA:")]
    assert lines and sum(int(row[1]) > 0 for row in lines) / len(lines) >= 0.9


@pytest.mark.parametrize(
    "predicate,target,decision",
    [
        ("macOS", "iOS", "inactive"),
        ("iOS", "macOS", "inactive"),
        ("macOS", "watchOS", "inactive"),
        ("macOS", "macOS", "active"),
        ("watchOS", "watchOS", "active"),
    ],
)
def test_actual_parser_recognizes_closed_whole_os_clause(native_tool, predicate, target, decision):
    raw = (
        "// complete source\n#if os("
        + predicate
        + ")\nimport ModuleThatDoesNotExist\npublic func value() -> Int { 1 }\n#endif\n// trailing bytes\n"
    ).encode()
    value = native_tool(raw, target)
    assert value["decision"] == decision
    assert value["predicate"] == {"kind": "os", "name": predicate}
    assert value["roundtrip"] is True and value["source_bytes"] == len(raw)


@pytest.mark.parametrize(
    "raw",
    [
        b"#if DEBUG\nfunc value() {}\n#endif\n",
        b"#if canImport(Missing)\nfunc value() {}\n#endif\n",
        b"#if os(macOS) || DEBUG\nfunc value() {}\n#endif\n",
        b"#if !os(iOS)\nfunc value() {}\n#endif\n",
        b"#if os(macOS)\nfunc value() {}\n#else\nfunc other() {}\n#endif\n",
        b"import Foundation\n#if os(macOS)\nfunc value() {}\n#endif\n",
        b"#if os(macOS)\nfunc value() {}\n#endif\nfunc other() {}\n",
        b"// #if os(macOS)\nfunc value() {}\n// #endif\n",
        b'let text = "#if os(macOS)\\n#endif"\n',
        b"#if os(macOS)\nfunc value() {}\n",
        b'#sourceLocation(file: "Pretend.swift", line: 1)\n#if os(macOS)\nfunc value() {}\n#endif\n',
        b"",
        b"\xff",
        b"#if os(OtherOS)\nfunc value() {}\n#endif\n",
        b"#if os(label: macOS)\nfunc value() {}\n#endif\n",
        b"#if other(macOS)\nfunc value() {}\n#endif\n",
    ],
)
def test_actual_parser_refuses_other_exclusions_recovery_or_siblings(native_tool, raw):
    assert native_tool(raw)["decision"] == "refused"


def test_actual_parser_refuses_unknown_target_and_missing_source(native_tool):
    assert (
        native_tool(b"#if os(macOS)\nfunc value() {}\n#endif\n", target="linux")["decision"]
        == "refused"
    )
    assert native_tool(b"", missing=True)["decision"] == "refused"


@pytest.mark.parametrize(
    "sdk_name,target_os,triple",
    [
        ("macosx", "macOS", "arm64-apple-macosx14.0"),
        ("iphonesimulator", "iOS", "arm64-apple-ios17.0-simulator"),
        ("watchsimulator", "watchOS", "arm64-apple-watchos10.0-simulator"),
    ],
)
def test_actual_typed_ast_and_sil_controls_have_closed_empty_grammar(
    native_tool, sdk_name, target_os, triple
):
    root = native_tool.evidence_root / sdk_name
    root.mkdir()
    frontend = subprocess.check_output(["xcrun", "--find", "swift-frontend"], text=True).strip()
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", sdk_name, "--show-sdk-path"], text=True
    ).strip()
    for active in (False, True):
        predicate = target_os if active else ("macOS" if target_os != "macOS" else "iOS")
        raw = f"#if os({predicate})\nfunc __astralGuardPositive() -> Int {{ 1 }}\n#endif\n".encode()
        source = root / ("Active.swift" if active else "Inactive.swift")
        source.write_bytes(raw)
        syntax = native_tool(raw, target_os)
        proof.validate_syntax(
            json.dumps(syntax).encode(),
            source=raw,
            target_os=target_os,
            decision="active" if active else "inactive",
        )
        values = {}
        for mode in ("-dump-ast", "-emit-silgen"):
            command = [
                frontend,
                "-frontend",
                mode,
                "-parse-as-library",
                "-swift-version",
                "5",
                "-module-name",
                "AstralInactiveProof",
                "-target",
                triple,
                "-sdk",
                sdk,
                "-module-cache-path",
                str(root / "cache"),
                str(source),
            ]
            result = subprocess.run(command, capture_output=True, timeout=120)
            assert result.returncode == 0 and not result.stderr.strip()
            (root / (source.stem + mode + ".stdout")).write_bytes(result.stdout)
            (root / (source.stem + mode + ".stderr")).write_bytes(result.stderr)
            values[mode] = result.stdout
            native_tool.evidence_record["compiler_controls"].append(
                {
                    "argv": command,
                    "source_sha256": hashlib.sha256(raw).hexdigest(),
                    "stdout_sha256": hashlib.sha256(result.stdout).hexdigest(),
                    "stderr_sha256": hashlib.sha256(result.stderr).hexdigest(),
                    "sdk_settings_sha256": hashlib.sha256(
                        (Path(sdk) / "SDKSettings.plist").read_bytes()
                    ).hexdigest(),
                }
            )
        if active:
            assert (
                b"(func_decl" in values["-dump-ast"]
                and b"__astralGuardPositive" in values["-dump-ast"]
            )
            assert any(
                line.startswith(b"sil ") and b"__astralGuardPositive" in line
                for line in values["-emit-silgen"].splitlines()
            )
            with pytest.raises(proof.ProofError):
                proof.validate_empty(values["-dump-ast"], values["-emit-silgen"], source)
        else:
            proof.validate_empty(values["-dump-ast"], values["-emit-silgen"], source)
        assert source.read_bytes() == raw


@pytest.mark.parametrize("replace_namespace", [True, False])
def test_real_compiler_output_and_cache_use_held_private_directory(
    native_tool, tmp_path, replace_namespace
):
    output = tmp_path / "proof"
    hostile = tmp_path / "hostile"
    hostile.mkdir(mode=0o700)
    victim = tmp_path / "operator-file"
    preimage = b"operator preimage"
    victim.write_bytes(preimage)
    (hostile / "whole-os-proof").symlink_to(victim)
    frontend = Path(
        subprocess.check_output(["xcrun", "--find", "swift-frontend"], text=True).strip()
    )
    host = frontend.parents[1] / "lib/swift/host"
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    with proof.PrivateOutput(output) as storage:
        held = tmp_path / "held" if replace_namespace else output
        if replace_namespace:
            output.rename(held)
            output.symlink_to(hostile, target_is_directory=True)
        command = [
            "/usr/bin/xcrun",
            "--sdk",
            "macosx",
            str(frontend.with_name("swiftc")),
            str(HELPER),
            "-sdk",
            sdk,
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
            "whole-os-proof",
        ]
        result = proof.run_command(
            command,
            cwd=output,
            directory_fd=storage.fd,
            developer=frontend.parents[4],
            deadline=proof.time.monotonic() + 45,
        )
        assert result.returncode == 0, result.stderr.decode()
        assert (held / "whole-os-proof").is_file() and (held / "host-cache").is_dir()
        assert victim.read_bytes() == preimage
        if replace_namespace:
            with pytest.raises(proof.ProofError):
                storage.check()
        else:
            storage.read("whole-os-proof", adopt=True)
            raw = b"#if os(iOS)\nfunc value() {}\n#endif\n"
            storage.write("Input.swift", raw, mode=0o400)
            parsed = proof.run_command(
                ["./whole-os-proof", "Input.swift", "macOS"],
                cwd=output,
                directory_fd=storage.fd,
                deadline=proof.time.monotonic() + 10,
            )
            assert parsed.returncode == 0
            proof.validate_syntax(parsed.stdout, source=raw, target_os="macOS")
            storage.check()
        evidence = native_tool.evidence_root
        label = "held-compile-attack" if replace_namespace else "held-compile-normal"
        (evidence / (label + ".stdout")).write_bytes(result.stdout)
        (evidence / (label + ".stderr")).write_bytes(result.stderr)
        native_tool.evidence_record[label] = {
            "argv": command,
            "binary_sha256": hashlib.sha256((held / "whole-os-proof").read_bytes()).hexdigest(),
            "namespace_finalization_refused": replace_namespace,
            "operator_preimage_unchanged": True,
        }


def test_real_frontend_accepts_relative_input_in_held_directory(native_tool, tmp_path):
    frontend = subprocess.check_output(["xcrun", "--find", "swift-frontend"], text=True).strip()
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    with proof.PrivateOutput(tmp_path / "proof") as storage:
        storage.write("Input.swift", b"#if os(iOS)\nfunc value() {}\n#endif\n", mode=0o400)
        values = {}
        for mode in ("-dump-ast", "-emit-silgen"):
            command = [
                frontend,
                "-frontend",
                mode,
                "-parse-as-library",
                "-swift-version",
                "5",
                "-module-name",
                "AstralInactiveProof",
                "-target",
                "arm64-apple-macosx14.0",
                "-sdk",
                sdk,
                "-module-cache-path",
                "target-cache",
                "Input.swift",
            ]
            result = proof.run_command(
                command,
                cwd=storage.path,
                directory_fd=storage.fd,
                deadline=proof.time.monotonic() + 120,
            )
            assert result.returncode == 0 and not result.stderr.strip()
            values[mode] = result.stdout
            (native_tool.evidence_root / ("held-relative" + mode + ".stdout")).write_bytes(
                result.stdout
            )
        proof.validate_empty(values["-dump-ast"], values["-emit-silgen"], Path("Input.swift"))


def test_real_collector_uses_native_object_and_shipping_library_profile(
    native_tool, tmp_path, monkeypatch
):
    monkeypatch.setattr(proof, "TIME_BUDGET", 600)
    import platform

    architecture = platform.machine()
    assert architecture in {"arm64", "x86_64"}
    swiftc = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip())
    developer = swiftc.parents[4]
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    version_command = [str(developer / "usr/bin/xcodebuild"), "-version"]
    actual_version = subprocess.check_output(version_command)
    pinned = actual_version.strip() == b"Xcode 26.6\nBuild version 17F113"
    raw = b"#if os(iOS)\npublic func __astralCollectorProfile() -> Int { 1 }\n#endif\n"
    source = tmp_path / "Source.swift"
    source.write_bytes(raw)
    primary, binary = tmp_path / "Source.o", tmp_path / "libCollectorProfile.dylib"
    triple = architecture + "-apple-macosx14.0"
    commands = [
        [
            "/usr/bin/xcrun",
            "--sdk",
            "macosx",
            str(swiftc),
            "-parse-as-library",
            "-emit-object",
            "-module-name",
            "AstralCollectorProfile",
            "-target",
            triple,
            "-sdk",
            sdk,
            "-module-cache-path",
            str(tmp_path / "build-cache"),
            str(source),
            "-o",
            str(primary),
        ],
        [
            "/usr/bin/xcrun",
            "--sdk",
            "macosx",
            str(swiftc),
            "-parse-as-library",
            "-emit-library",
            "-module-name",
            "AstralCollectorProfile",
            "-target",
            triple,
            "-sdk",
            sdk,
            "-module-cache-path",
            str(tmp_path / "build-cache"),
            str(source),
            "-o",
            str(binary),
        ],
    ]
    for index, command in enumerate(commands):
        result = subprocess.run(command, capture_output=True, timeout=120)
        (native_tool.evidence_root / f"collector-build-{index}.stdout").write_bytes(result.stdout)
        (native_tool.evidence_root / f"collector-build-{index}.stderr").write_bytes(result.stderr)
        assert result.returncode == 0, result.stderr.decode()
    target = proof.bind_native_target(binary.read_bytes(), primary.read_bytes())
    assert target["os"] == "macOS" and target["architecture"] == architecture
    output = tmp_path / "collector-proof"
    arguments = dict(
        source=source,
        source_sha256=hashlib.sha256(raw).hexdigest(),
        native_binary=binary,
        primary_object=primary,
        developer=developer,
        output=output,
    )
    try:
        value = proof.collect_proof(**arguments)
    except proof.ProofError:
        assert not pinned
        assert not (output / "proof.json").exists()
        assert (output / "xcode.stdout").read_bytes() == actual_version
        decision = "unqualified-toolchain-refused"
    else:
        assert pinned
        assert (
            value["scope"] == "source-conditional-only"
            and value["build_provenance"] == "unverified"
        )
        assert value["target"] == target and value["source"]["sha256"] == arguments["source_sha256"]
        assert value["raw_outputs"]
        for item in value["raw_outputs"].values():
            assert (
                hashlib.sha256((output / item["member"]).read_bytes()).hexdigest() == item["sha256"]
            )
        assert json.loads((output / "proof.json").read_bytes()) == value
        decision = "pinned-source-conditional-proof"
    assert source.read_bytes() == raw
    native_tool.evidence_record["collector_profile"] = {
        "version_argv": version_command,
        "actual_xcode": actual_version.decode().strip(),
        "build_argv": commands,
        "arguments": {name: str(value) for name, value in arguments.items()},
        "source_sha256": hashlib.sha256(raw).hexdigest(),
        "primary_sha256": hashlib.sha256(primary.read_bytes()).hexdigest(),
        "shipping_library_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "native_target": target,
        "decision": decision,
        "proof_path": str(output / "proof.json"),
    }
