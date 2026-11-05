#!/usr/bin/env python3
"""Transports complete Apple UI test Products between same-run CI jobs while binding their source, toolchain and package identity."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import subprocess
import tarfile


REQUIRED_PRODUCTS = (
    "Debug-iphonesimulator/AstralDeep.app/AstralDeep",
    "Debug-iphonesimulator/AstralDeep.app/AstralDeep.debug.dylib",
    "Debug-iphonesimulator/AstralDeep.app/PlugIns/AstralAppTests.xctest/AstralAppTests",
    "Debug-iphonesimulator/AstralAppUITests-Runner.app/AstralAppUITests-Runner",
    "Debug-iphonesimulator/AstralAppUITests-Runner.app/PlugIns/AstralAppUITests.xctest/AstralAppUITests",
)
PACKAGE_LOCK = "apple-clients/AstralApp/AstralApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"


def require(condition):
    if not condition:
        raise ValueError("Apple UI build Products or identity mismatch")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def identity(repo):
    return {
        "head": subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip(),
        "workspace": str(repo.resolve()),
        "xcode_build": os.environ["XCODE_BUILD"],
        "package_lock_sha256": sha256(repo / PACKAGE_LOCK),
    }


def validate(products):
    require(products.is_dir() and not products.is_symlink())
    runs = list(products.glob("*.xctestrun"))
    require(len(runs) == 1 and runs[0].is_file() and not runs[0].is_symlink())
    configurations = plistlib.loads(runs[0].read_bytes()).get("TestConfigurations")
    require(isinstance(configurations, list) and len(configurations) == 1)
    targets = configurations[0].get("TestTargets", [])
    require(len(targets) == 2 and {item.get("BlueprintName") for item in targets} == {
        "AstralAppTests", "AstralAppUITests",
    })
    for name in REQUIRED_PRODUCTS:
        path = products / name
        require(path.is_file() and not path.is_symlink() and path.stat().st_mode & 0o100)


def pack(repo, derived, archive):
    products = derived / "Build/Products"
    validate(products)
    require(not archive.exists() and not archive.with_suffix(".json").exists())
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "x") as bundle:
        bundle.add(products, arcname="Products")
    manifest = {**identity(repo), "archive_sha256": sha256(archive)}
    archive.with_suffix(".json").write_text(json.dumps(manifest, sort_keys=True) + "\n")


def restore(repo, derived, archive):
    manifest = json.loads(archive.with_suffix(".json").read_text())
    require(manifest == {**identity(repo), "archive_sha256": sha256(archive)})
    products = derived / "Build/Products"
    require(not products.exists() and not products.is_symlink())
    with tarfile.open(archive, "r:") as bundle:
        members = bundle.getmembers()
        require(bool(members))
        for member in members:
            path = PurePosixPath(member.name)
            require(not path.is_absolute() and path.parts[0] == "Products" and ".." not in path.parts)
        bundle.extractall(derived / "Build", members=members, filter="data")
    validate(products)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("pack", "restore"))
    for name in ("repo", "derived", "archive"):
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    {"pack": pack, "restore": restore}[args.action](args.repo, args.derived, args.archive)


if __name__ == "__main__":
    main()
