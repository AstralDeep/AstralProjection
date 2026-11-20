"""Checks that Apple CI builds the llama.cpp voice runtime once and that every job which builds or tests the app downloads and verifies that build.
Also runs the verification script against missing, mispinned and incomplete runtimes, and asserts the app's package graph resolves from the committed Package.resolved."""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/apple-ci.yml"
SCRIPTS = ROOT / "apple-clients/Scripts"
VERIFY = SCRIPTS / "verify-voice-runtime.sh"
BUILD = SCRIPTS / "build-voice-runtime.sh"
CONSUMERS = ("voice-packages", "swift-package-prewarm", "ios-ui-build", "macos-app-build", "app-unit-tests", "first-login-ui", "watch-continuity")


def job(text: str, name: str) -> str:
    match = re.search(rf"(?ms)^  {name}:\n(.*?)(?=^  [\w-]+:\n|\Z)", text)
    assert match is not None
    return match.group(1)


def test_the_runtime_is_built_once_by_one_producer_job():
    text = WORKFLOW.read_text()
    assert text.count("build-voice-runtime.sh") == 1
    producer = job(text, "voice-runtime")
    assert "build-voice-runtime.sh" in producer
    assert "--slices" not in producer and "--arm64-only" not in producer
    assert "timeout-minutes: 25" in producer
    assert "name: apple-voice-runtime-artifacts" in producer
    assert "if-no-files-found: error" in producer
    assert producer.index("verify-voice-runtime.sh") < producer.index("upload-artifact")


@pytest.mark.parametrize("name", CONSUMERS)
def test_every_consumer_downloads_and_verifies_the_same_run_runtime_before_building(name):
    block = job(WORKFLOW.read_text(), name)
    assert "voice-runtime" in re.search(r"(?m)^    needs: \[(.*)\]$", block).group(1)
    assert "name: apple-voice-runtime-artifacts" in block
    assert "path: apple-clients/AstralVoiceRuntime/Artifacts" in block
    verified = block.index("verify-voice-runtime.sh")
    assert block.index("apple-voice-runtime-artifacts") < verified
    later = [block.find(tool, verified) for tool in ("xcodebuild", "swift test") if block.find(tool, verified) != -1]
    assert later and min(later) > verified


def test_the_aggregate_requires_the_producer():
    aggregate = job(WORKFLOW.read_text(), "apple-required")
    assert "      - voice-runtime\n" in aggregate
    assert "needs.voice-runtime.result" in aggregate


def test_the_prewarm_resolves_only_the_committed_package_versions():
    prewarm = job(WORKFLOW.read_text(), "swift-package-prewarm")
    assert "-onlyUsePackageVersionsFromResolvedFile" in prewarm and "-skipPackageUpdates" in prewarm
    resolved = (ROOT / "apple-clients/AstralApp/AstralApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text()
    assert "e0c6103bc87a88d25276cad491c86e757f58c865" in resolved


def test_the_runtime_script_builds_universal_mac_and_simulator_slices():
    script = BUILD.read_text()
    assert '"ios|iphoneos|$IOS_TARGET|ON|arm64"' in script
    assert '"ios-simulator|iphonesimulator|$IOS_TARGET|OFF|arm64 x86_64"' in script
    assert '"macos|macosx|$MACOS_TARGET|ON|arm64 x86_64"' in script
    assert "--arm64-only" in script and "lipo -create" in script


def run_verify(directory: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(VERIFY), str(directory)], capture_output=True, text=True)


def pinned() -> str:
    return re.search(r"(?m)^REVISION=([0-9a-f]{40})$", BUILD.read_text()).group(1)


def test_verification_rejects_a_missing_runtime(tmp_path):
    result = run_verify(tmp_path)
    assert result.returncode != 0 and "llama.cpp-revision" in result.stderr


def test_verification_rejects_a_runtime_built_at_another_revision(tmp_path):
    (tmp_path / "llama.cpp-revision").write_text("0" * 40 + "\n")
    result = run_verify(tmp_path)
    assert result.returncode != 0 and "pinned" in result.stderr


def test_verification_rejects_a_runtime_without_its_slices(tmp_path):
    (tmp_path / "llama.cpp-revision").write_text(pinned() + "\n")
    (tmp_path / "llama.cpp-LICENSE").write_text("MIT")
    result = run_verify(tmp_path)
    assert result.returncode != 0 and "missing slice" in result.stderr


@pytest.mark.skipif(not (SCRIPTS.parent / "AstralVoiceRuntime/Artifacts/LlamaRuntime.xcframework").is_dir(), reason="runtime not built here")
def test_verification_accepts_the_runtime_built_in_this_checkout():
    result = run_verify(SCRIPTS.parent / "AstralVoiceRuntime/Artifacts")
    assert result.returncode == 0, result.stderr
    assert os.access(VERIFY, os.X_OK)
