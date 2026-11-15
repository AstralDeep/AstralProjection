"""Checks same-run Kernel Apple artifacts against source, toolchain and complete payload identities."""

import json
import hashlib
from pathlib import Path
import re

import pytest

from scripts import ci_kernel_apple as subject

ROOT = Path(__file__).resolve().parents[1]


def job(text, name):
    match = re.search(rf"(?ms)^  {name}:\n(.*?)(?=^  [\w-]+:\n|\Z)", text)
    assert match is not None
    return match.group(1)


@pytest.fixture
def products(tmp_path, monkeypatch):
    repo, kernel, artifacts = (tmp_path / name for name in ("projection", "kernel", "artifacts"))
    (repo / "apple-clients/NodePack").mkdir(parents=True)
    (repo / "apple-clients/NodePack/pins.json").write_text(json.dumps({"kernel": {"commit": "1" * 40}}))
    kernel.mkdir()
    for name in subject.REQUIRED_FILES:
        path = artifacts / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(name.encode())
    (artifacts / "apple-build-manifest.json").write_text(json.dumps({
        "source_commit": "1" * 40,
        "artifacts": [{"path": name, "sha256": hashlib.sha256(name.encode()).hexdigest(), "bytes": len(name.encode())} for name in subject.REQUIRED_FILES],
    }))
    state = {"projection": "2" * 40, "kernel": "1" * 40, "xcode": "Xcode 26.6\nBuild version 17F113\n"}
    def output(command, **kwargs):
        return state["xcode"] if command[0] == "xcodebuild" else state[Path(command[2]).name]
    monkeypatch.setattr(subject.subprocess, "check_output", output)
    return repo, kernel, artifacts, state


def test_record_and_verify_bind_complete_payloads_to_both_sources_and_toolchain(products):
    repo, kernel, artifacts, _ = products
    subject.record(repo, kernel, artifacts)
    receipt = json.loads((artifacts / subject.RECEIPT).read_text())
    assert receipt["identity"]["kernel_commit"] == "1" * 40
    assert receipt["identity"]["projection_commit"] == "2" * 40
    assert set(receipt["files"]) == {*subject.REQUIRED_FILES, "apple-build-manifest.json"}
    subject.verify(repo, artifacts)


@pytest.mark.parametrize("change", ["projection", "kernel-pin", "xcode", "payload", "missing", "extra", "symlink"])
def test_consumer_rejects_every_identity_or_payload_change(products, change):
    repo, kernel, artifacts, state = products
    subject.record(repo, kernel, artifacts)
    path = artifacts / subject.REQUIRED_FILES[0]
    if change in ("projection", "xcode"):
        state[change] = "changed"
    elif change == "kernel-pin":
        (repo / "apple-clients/NodePack/pins.json").write_text(json.dumps({"kernel": {"commit": "3" * 40}}))
    elif change == "payload":
        path.write_bytes(b"changed")
    elif change == "missing":
        path.unlink()
    elif change == "extra":
        (artifacts / "unreviewed.swift").write_bytes(b"extra")
    else:
        data = path.read_bytes()
        path.unlink()
        target = artifacts.parent / "outside"
        target.write_bytes(data)
        path.symlink_to(target)
    with pytest.raises((ValueError, FileNotFoundError)):
        subject.verify(repo, artifacts)


def test_build_source_must_match_pin_and_receipt_cannot_be_replaced(products):
    repo, kernel, artifacts, state = products
    state["kernel"] = "3" * 40
    with pytest.raises(ValueError):
        subject.record(repo, kernel, artifacts)
    assert not (artifacts / subject.RECEIPT).exists()
    state["kernel"] = "1" * 40
    subject.record(repo, kernel, artifacts)
    with pytest.raises(ValueError):
        subject.record(repo, kernel, artifacts)


@pytest.mark.parametrize("value", ["main", None, "a" * 39])
def test_nonimmutable_source_pin_is_refused(products, value):
    repo, kernel, artifacts, _ = products
    (repo / "apple-clients/NodePack/pins.json").write_text(json.dumps({"kernel": {"commit": value}}))
    with pytest.raises(ValueError):
        subject.record(repo, kernel, artifacts)


def test_hidden_build_stamp_is_not_a_required_payload(products):
    repo, kernel, artifacts, _ = products
    (artifacts / ".build-stamp").touch()
    subject.record(repo, kernel, artifacts)
    (artifacts / ".build-stamp").unlink()
    subject.verify(repo, artifacts)


def test_missing_receipt_fails_without_accepting_local_builds(products):
    repo, _, artifacts, _ = products
    with pytest.raises(FileNotFoundError):
        subject.verify(repo, artifacts)


@pytest.mark.parametrize("change", ["missing", "source", "digest", "bytes", "duplicate", "extra", "traversal", "boolean-size"])
def test_internal_assembly_manifest_is_required_and_validated_before_record(products, change):
    repo, kernel, artifacts, _ = products
    path = artifacts / "apple-build-manifest.json"
    manifest = json.loads(path.read_text())
    if change == "missing":
        path.unlink()
    else:
        if change == "source":
            manifest["source_commit"] = "3" * 40
        elif change == "digest":
            manifest["artifacts"][0]["sha256"] = "a" * 64
        elif change in ("bytes", "boolean-size"):
            manifest["artifacts"][0]["bytes"] = 0 if change == "bytes" else True
        elif change == "duplicate":
            manifest["artifacts"].append(manifest["artifacts"][0])
        elif change == "extra":
            manifest["artifacts"].append({"path": "extra", "sha256": "a" * 64, "bytes": 0})
        else:
            manifest["artifacts"][0]["path"] = "../outside"
        path.write_text(json.dumps(manifest))
    with pytest.raises((ValueError, FileNotFoundError)):
        subject.record(repo, kernel, artifacts)
    assert not (artifacts / subject.RECEIPT).exists()


def test_internal_assembly_manifest_is_bound_in_consumer_receipt(products):
    repo, kernel, artifacts, _ = products
    subject.record(repo, kernel, artifacts)
    path = artifacts / "apple-build-manifest.json"
    value = json.loads(path.read_text())
    value["new_metadata"] = "changed after assembly"
    path.write_text(json.dumps(value))
    with pytest.raises(ValueError):
        subject.verify(repo, artifacts)


def test_cli_records_and_verifies(products):
    repo, kernel, artifacts, _ = products
    common = ["--repo", str(repo), "--artifacts", str(artifacts)]
    subject.main(["record", *common, "--kernel-source", str(kernel)])
    subject.main(["verify", *common])
    with pytest.raises(ValueError):
        subject.main(["record", *common])


def test_every_native_package_consumer_requires_current_run_kernel_artifacts():
    text = (ROOT / ".github/workflows/apple-ci.yml").read_text()
    for name in ("app-unit-tests", "swift-package-prewarm", "ios-ui-build", "first-login-ui", "watch-continuity"):
        block = job(text, name)
        assert "kernel-apple" in block.split("    steps:")[0]
        assert "name: apple-kernel-artifacts" in block
        assert "ci_kernel_apple.py verify" in block
        assert block.index("ci_kernel_apple.py verify") < block.index("xcodebuild", block.index("ci_kernel_apple.py verify"))
    aggregate = job(text, "apple-required")
    assert "- kernel-slices" in aggregate and "- kernel-apple" in aggregate
    assert "needs.kernel-slices.result" in aggregate and "needs.kernel-apple.result" in aggregate


def test_kernel_builds_are_bounded_separate_from_tests_and_source_pinned():
    text = (ROOT / ".github/workflows/apple-ci.yml").read_text()
    slices, assembly = (job(text, name) for name in ("kernel-slices", "kernel-apple"))
    for target in ("aarch64-apple-darwin", "x86_64-apple-darwin", "aarch64-apple-ios", "aarch64-apple-ios-sim", "x86_64-apple-ios"):
        assert f"- {target}" in slices
    assert "timeout-minutes: 30" in slices
    assert "repository: AstralDeep/AstralKernel" in slices + assembly
    assert "ref: ${{ needs.changes.outputs.kernel_commit }}" in slices + assembly
    assert "build-apple-target.sh" in slices and "assemble-apple.sh" in assembly
    assert "ci_kernel_apple.py record" in assembly
    assert "include-hidden-files: true" in assembly and "if-no-files-found: error" in assembly
    assert "secrets." not in text and "contents: read" in text
