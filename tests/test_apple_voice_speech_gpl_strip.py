"""Fails when the Xcode project links AstralVoiceSpeech without a build phase that strips FluidAudio's GPL voice resources.
The script's own behaviour and the guard's parser are tested against small inline project texts, so the guard passes while the project does not reference the package."""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1] / "apple-clients"
PROJECT = ROOT / "AstralApp" / "AstralApp.xcodeproj" / "project.pbxproj"
SCRIPT = ROOT / "AstralVoiceSpeech" / "Scripts" / "strip-voice-gpl-resources.sh"
PRODUCT = "AstralVoiceSpeech"
SCRIPT_NAME = "strip-voice-gpl-resources.sh"

PRODUCT_DEPENDENCY = re.compile(
    r"([0-9A-Fa-f]{24}) /\*[^*]*\*/ = \{[^{}]*?isa = XCSwiftPackageProductDependency;[^{}]*?productName = (\w+);[^{}]*?\}"
)
OBJECT = re.compile(r"^\t\t([0-9A-Fa-f]{24}) /\* ([^\n]*?) \*/ = \{\n(.*?)^\t\t\};$", re.M | re.S)
ID_LIST = r"{name} = \(\n(.*?)\n\t\t\t\);"
ID = re.compile(r"[0-9A-Fa-f]{24}")


def id_list(body: str, name: str) -> list[str]:
    match = re.search(ID_LIST.format(name=name), body, re.S)
    return ID.findall(match.group(1)) if match else []


def references_package(text: str) -> bool:
    return PRODUCT in text


def targets_missing_strip_phase(text: str) -> list[str]:
    product_ids = {i for i, name in PRODUCT_DEPENDENCY.findall(text) if name == PRODUCT}
    objects = {i: (label, body) for i, label, body in OBJECT.findall(text)}
    strip_phases = {
        i for i, (_, body) in objects.items() if "isa = PBXShellScriptBuildPhase;" in body and SCRIPT_NAME in body
    }
    linking = {
        label: body
        for label, body in objects.values()
        if "isa = PBXNativeTarget;" in body and product_ids & set(id_list(body, "packageProductDependencies"))
    }
    if not linking:
        return ["<no target links the package, so the guard cannot verify the strip phase>"]
    return sorted(label for label, body in linking.items() if not strip_phases & set(id_list(body, "buildPhases")))


def violations(text: str) -> list[str]:
    return targets_missing_strip_phase(text) if references_package(text) else []


def project(*, links: bool = True, phase_in_target: bool = True, phase_script: str = SCRIPT_NAME) -> str:
    phases = "\t\t\t\tAA0000000000000000000001 /* Sources */,\n"
    if phase_in_target:
        phases += "\t\t\t\tAA0000000000000000000002 /* Strip voice GPL resources */,\n"
    deps = "\t\t\t\tAA0000000000000000000003 /* AstralVoiceSpeech */,\n" if links else ""
    return (
        "/* Begin PBXNativeTarget section */\n"
        "\t\tAA0000000000000000000010 /* App */ = {\n"
        "\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildPhases = (\n{phases}\t\t\t);\n"
        f"\t\t\tpackageProductDependencies = (\n{deps}\t\t\t);\n"
        "\t\t};\n"
        "/* End PBXNativeTarget section */\n"
        "/* Begin PBXShellScriptBuildPhase section */\n"
        "\t\tAA0000000000000000000002 /* Strip voice GPL resources */ = {\n"
        "\t\t\tisa = PBXShellScriptBuildPhase;\n"
        f'\t\t\tshellScript = "\\"${{SRCROOT}}/../AstralVoiceSpeech/Scripts/{phase_script}\\" \\"${{TARGET_BUILD_DIR}}\\"";\n'
        "\t\t};\n"
        "/* End PBXShellScriptBuildPhase section */\n"
        "/* Begin XCSwiftPackageProductDependency section */\n"
        "\t\tAA0000000000000000000003 /* AstralVoiceSpeech */ = {\n"
        "\t\t\tisa = XCSwiftPackageProductDependency;\n"
        "\t\t\tproductName = AstralVoiceSpeech;\n"
        "\t\t};\n"
        "/* End XCSwiftPackageProductDependency section */\n"
    )


def test_every_target_that_links_the_voice_package_strips_the_gpl_resources():
    assert violations(PROJECT.read_text()) == []


def test_a_project_that_does_not_reference_the_package_passes():
    assert violations("/* Begin PBXNativeTarget section */\n/* End PBXNativeTarget section */\n") == []


def test_a_linking_target_with_the_strip_phase_passes():
    assert violations(project()) == []


def test_a_linking_target_without_the_strip_phase_is_reported():
    assert violations(project(phase_in_target=False)) == ["App"]


def test_a_phase_that_runs_another_script_is_reported():
    assert violations(project(phase_script="other.sh")) == ["App"]


def test_a_reference_with_no_linking_target_is_reported():
    assert violations(project(links=False))[0].startswith("<no target links")


def test_one_target_with_the_phase_does_not_cover_another():
    second = project().replace("AA0000000000000000000010 /* App */", "AA0000000000000000000011 /* Other */")
    second = second.replace("\t\t\t\tAA0000000000000000000002 /* Strip voice GPL resources */,\n", "")
    first_target = project().split("/* End PBXNativeTarget section */")[0].split("/* Begin PBXNativeTarget section */\n")[1]
    other_target = second.split("/* End PBXNativeTarget section */")[0].split("/* Begin PBXNativeTarget section */\n")[1]
    combined = project().replace(first_target, first_target + other_target)
    assert violations(combined) == ["Other"]


def test_the_script_exists_and_is_executable():
    assert SCRIPT.is_file()
    assert os.access(SCRIPT, os.X_OK)


def run_script(path: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(SCRIPT), str(path)], capture_output=True, text=True)


def test_the_script_removes_every_bundle_and_reports_it(tmp_path):
    first = tmp_path / "App.app" / "Contents" / "Resources" / "FluidAudio_LuxTtsG2pResources.bundle"
    second = tmp_path / "Products" / "Frameworks" / "LuxTtsG2pResources.bundle"
    kept = tmp_path / "Products" / "Frameworks" / "Other.bundle"
    for bundle in (first, second, kept):
        bundle.mkdir(parents=True)
        (bundle / "data").write_text("x")
    result = run_script(tmp_path)
    assert result.returncode == 0, result.stderr
    assert not first.exists() and not second.exists() and kept.exists()
    assert result.stdout.count("removed ") == 3 and str(first) in result.stdout and str(second) in result.stdout


def test_the_script_is_safe_when_the_bundle_is_absent(tmp_path):
    (tmp_path / "App.app").mkdir()
    result = run_script(tmp_path)
    assert result.returncode == 0, result.stderr
    assert "none remain" in result.stdout


def test_the_script_rejects_a_missing_directory(tmp_path):
    assert run_script(tmp_path / "absent").returncode == 2
    assert subprocess.run([str(SCRIPT)], capture_output=True, text=True).returncode == 2


@pytest.mark.skipif(os.geteuid() == 0, reason="root ignores directory permissions")
def test_the_script_fails_when_a_bundle_cannot_be_removed(tmp_path):
    parent = tmp_path / "locked"
    bundle = parent / "FluidAudio_LuxTtsG2pResources.bundle"
    bundle.mkdir(parents=True)
    parent.chmod(0o500)
    try:
        assert run_script(tmp_path).returncode != 0
        assert bundle.exists()
    finally:
        parent.chmod(0o700)
