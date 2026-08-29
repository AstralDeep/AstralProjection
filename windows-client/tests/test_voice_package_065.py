"""Feature 065 frozen-Windows media closure and offline manifest evidence."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = ROOT / "AstralDeep.spec"
INPUT = ROOT / "requirements.in"
LOCK = ROOT / "requirements-release.lock.txt"
MANIFEST = ROOT / "deployment" / "runtime-manifest.json"
HELPER = ROOT / "asr-helper"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_frozen_spec_collects_qtmultimedia_and_livekit_native_closure() -> None:
    source = SPEC.read_text(encoding="utf-8")

    assert '"PySide6.QtMultimedia"' in source
    assert 'collect_submodules("livekit.rtc")' in source
    assert 'collect_dynamic_libs("livekit")' in source
    assert 'collect_data_files("livekit", include_py_files=False)' in source
    excludes = source[source.index("excludes = [") : source.index("a = Analysis(")]
    assert "PySide6.QtMultimedia" not in excludes


def test_frozen_spec_collects_qt_text_to_speech_plugin_and_first_party_helper() -> None:
    source = SPEC.read_text(encoding="utf-8")

    assert 'collect_submodules("PySide6.QtTextToSpeech")' in source
    assert 'collect_dynamic_libs(\n            "PySide6",' in source
    assert '"qtexttospeech_*.dll"' in source
    assert '"libqtexttospeech_*.dylib"' in source
    assert '"PySide6.QtTextToSpeech"' in source
    assert '("asr-helper/publish/AstralSpeechHelper.exe", "asr-helper")' in source
    assert '("asr-helper/helper-source-hashes.json", "asr-helper")' in source
    excludes = source[source.index("excludes = [") : source.index("a = Analysis(")]
    assert "PySide6.QtTextToSpeech" not in excludes


def test_helper_product_is_deterministic_warning_clean_and_dependency_free() -> None:
    project = (HELPER / "AstralSpeechHelper.csproj").read_text(encoding="utf-8")
    source_hashes = json.loads((HELPER / "helper-source-hashes.json").read_text(encoding="utf-8"))

    assert "<TargetFramework>net48</TargetFramework>" in project
    assert "<Deterministic>true</Deterministic>" in project
    assert "<ContinuousIntegrationBuild>true</ContinuousIntegrationBuild>" in project
    assert "<TreatWarningsAsErrors>true</TreatWarningsAsErrors>" in project
    assert "<PackageReference" not in project
    assert source_hashes["schema_version"] == 1
    assert set(source_hashes["files"]) == {
        "AstralSpeechHelper.csproj",
        "BoundedAudioStream.cs",
        "FrameProtocol.cs",
        "Program.cs",
    }
    for relative, expected in source_hashes["files"].items():
        assert _sha256(HELPER / relative) == expected


def test_helper_test_dependencies_are_exact_locked_and_isolated_from_product() -> None:
    test_project = (HELPER / "tests" / "AstralSpeechHelper.Tests.csproj").read_text(
        encoding="utf-8"
    )
    lock = json.loads((HELPER / "tests" / "packages.lock.json").read_text(encoding="utf-8"))
    expected = {
        "Microsoft.NET.Test.Sdk": "18.9.0",
        "MSTest.TestAdapter": "4.3.3",
        "MSTest.TestFramework": "4.3.3",
        "Microsoft.CodeCoverage": "18.9.0",
    }

    for package, version in expected.items():
        assert f'Include="{package}" Version="{version}"' in test_project
        assert (
            lock["dependencies"][".NETFramework,Version=v4.8"][package]["requested"]
            == f"[{version}, )"
        )
        assert lock["dependencies"][".NETFramework,Version=v4.8"][package]["resolved"] == version
    assert 'PrivateAssets="all"' in test_project

    product_inputs = "\n".join(
        [
            SPEC.read_text(encoding="utf-8"),
            (HELPER / "AstralSpeechHelper.csproj").read_text(encoding="utf-8"),
            (HELPER / "helper-source-hashes.json").read_text(encoding="utf-8"),
        ]
    )
    for package in expected:
        assert package not in product_inputs
    assert "asr-helper/tests" not in product_inputs
    assert ".Tests.dll" not in product_inputs


def test_runtime_manifest_offline_evidence_binds_livekit_release_lock() -> None:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    lock = LOCK.read_text(encoding="utf-8")

    assert "livekit==1.1.14" in INPUT.read_text(encoding="utf-8")
    assert "livekit==1.1.14" in lock
    assert "b8f8d38f131956297923e520bc4375bc9ebfa255cab7f125cb7755bfca71df24" in lock
    assert manifest["requirements_input_sha256"] == _sha256(INPUT)
    assert manifest["requirements_lock_sha256"] == _sha256(LOCK)
    assert manifest["required_runtime_lock_sha256"] == _sha256(LOCK)
    assert manifest["target_platform"] == "win_amd64"
    assert manifest["python_version"] == "3.11"
