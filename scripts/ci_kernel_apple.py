"""Binds same-run Apple Kernel build artifacts to both repositories and the actual Xcode toolchain.
Apple CI records the complete payload after source assembly and verifies it before native consumers resolve Swift packages."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

RECEIPT = "ci-provenance.json"
FORMAT = "astral.kernel-apple-ci/v1"
REQUIRED_FILES = (
    "Bindings/AstralKernelBindings.swift",
    "AstralKernelFFI.xcframework/Info.plist",
    *(
        f"AstralKernelFFI.xcframework/{slice_name}/{file}"
        for slice_name in ("macos-arm64_x86_64", "ios-arm64", "ios-arm64_x86_64-simulator")
        for file in ("libastral_kernel_ffi.a", "Headers/AstralKernelFFI.h", "Headers/module.modulemap")
    ),
)


def require(condition):
    if not condition:
        raise ValueError("Kernel Apple artifact source, toolchain or payload mismatch")


def commit(repo):
    value = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    require(re.fullmatch(r"[0-9a-f]{40}", value) is not None)
    return value


def identity(repo):
    pins = json.loads((repo / "apple-clients/NodePack/pins.json").read_text())
    kernel = pins["kernel"]["commit"]
    require(isinstance(kernel, str) and re.fullmatch(r"[0-9a-f]{40}", kernel) is not None)
    return {
        "projection_commit": commit(repo),
        "kernel_commit": kernel,
        "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
    }


def payloads(artifacts):
    require(artifacts.is_dir() and not artifacts.is_symlink())
    paths = list(artifacts.rglob("*"))
    require(not any(path.is_symlink() for path in paths))
    files = {path.relative_to(artifacts).as_posix(): path for path in paths if path.is_file()}
    require(set(files) - {RECEIPT, ".build-stamp"} == set(REQUIRED_FILES))
    result = {}
    for name in REQUIRED_FILES:
        digest = hashlib.sha256()
        with files[name].open("rb") as stream:
            for chunk in iter(lambda: stream.read(1 << 20), b""):
                digest.update(chunk)
        result[name] = digest.hexdigest()
    return result


def record(repo, kernel_source, artifacts):
    require(kernel_source is not None)
    expected = identity(repo)
    require(commit(kernel_source) == expected["kernel_commit"])
    receipt = artifacts / RECEIPT
    require(not receipt.exists() and not receipt.is_symlink())
    value = {"format": FORMAT, "identity": expected, "files": payloads(artifacts)}
    receipt.write_text(json.dumps(value, sort_keys=True) + "\n")


def verify(repo, artifacts):
    receipt = artifacts / RECEIPT
    require(not receipt.is_symlink())
    value = json.loads(receipt.read_text())
    require(value == {"format": FORMAT, "identity": identity(repo), "files": payloads(artifacts)})


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("record", "verify"))
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--kernel-source", type=Path)
    args = parser.parse_args(argv)
    if args.action == "record":
        record(args.repo, args.kernel_source, args.artifacts)
    else:
        verify(args.repo, args.artifacts)


if __name__ == "__main__":
    main()
