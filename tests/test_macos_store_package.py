"""Tests for the macOS Store package repair script: export shape repair, signing/profile
refusal, symlink and payload-change detection, and native tool failure handling stay
closed and bounded.
"""

from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import plistlib
import shutil
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest


SCRIPT = Path(__file__).resolve().parents[1] / "apple-clients/Scripts/repair_macos_store_package.py"
spec = importlib.util.spec_from_file_location("mac_store_package", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
DIST = hashlib.sha1(b"distribution").hexdigest().upper()
INSTALLER = hashlib.sha1(b"installer").hexdigest().upper()


@pytest.fixture
def package(tmp_path, monkeypatch):
    original = tmp_path / "original"
    app = original / "sample.pkg/Payload/AstralDeep.app"
    app.mkdir(parents=True)
    signed = {"com.apple.security.app-sandbox": True, "com.apple.security.network.client": True}
    profile = {"DeveloperCertificates": [b"distribution"]}
    objects = [
        app,
        app / "Contents/Resources/Sample.bundle",
        app / "Contents/Frameworks/Sample.framework",
    ]
    for code in objects:
        folder = code / "Contents/_CodeSignature"
        folder.mkdir(parents=True)
        (folder / "leaf").write_bytes(
            b"development" if code.suffix == ".bundle" else b"distribution"
        )
        (code / "Contents/Info.plist").write_bytes(
            plistlib.dumps({"CFBundleIdentifier": code.name})
        )
    executable = app / "Contents/MacOS/AstralDeep"
    executable.parent.mkdir()
    executable.write_bytes(bytes.fromhex("cafebabe") + b"CODE|signature-old")
    (app / "Contents/embedded.provisionprofile").write_bytes(plistlib.dumps(profile))
    (original / "Distribution").write_text('<installer><payload installKBytes="1"/></installer>')
    (original / "sample.pkg/PackageInfo").write_text('<pkg-info install-location="/Applications"/>')
    source = tmp_path / "original.pkg"
    source.write_bytes(b"original-package")
    output = tmp_path / "repaired.pkg"
    calls = []
    state = {
        "product_app": None,
        "subject": "Apple Distribution: Example",
        "installer": b"installer",
    }

    def fake(*args):
        calls.append(args)
        if args[0] == "pkgutil":
            if args[1] == "--check-signature":
                return b"valid"
            shutil.copytree(original, args[3])
            if Path(args[2]) != source:
                target = Path(args[3]) / "sample.pkg/Payload/AstralDeep.app"
                shutil.rmtree(target)
                shutil.copytree(state["product_app"], target)
                if state.get("bad_metadata"):
                    (Path(args[3]) / "Distribution").write_text('<installer changed="true"/>')
            return b""
        if args[0] == "xar":
            toc = Path(args[-1].split("=", 1)[1])
            encoded = base64.b64encode(state["installer"]).decode()
            toc.write_text(
                '<xar><toc><signature><KeyInfo xmlns="http://www.w3.org/2000/09/xmldsig#">'
                f"<X509Data><X509Certificate>{encoded}</X509Certificate></X509Data>"
                "</KeyInfo></signature></toc></xar>"
            )
            return b""
        if args[0] == "security":
            return plistlib.dumps(profile)
        if args[0] == "openssl":
            subject = (
                "3rd Party Mac Developer Installer: Example"
                if args[5].endswith("installer.der")
                else state["subject"]
            )
            return ("subject=CN = " + subject).encode()
        if args[0] == "ditto":
            shutil.copytree(args[1], args[2])
            return b""
        if args[0] == "productbuild":
            state["product_app"] = Path(args[2])
            Path(args[-1]).write_bytes(b"repaired-package")
            return b""
        if args[0] == "lipo":
            return state.get("architectures", "arm64 x86_64").encode()
        assert args[0] == "codesign"
        if "--extract-certificates=" in " ".join(args):
            prefix = next(
                a.split("=", 1)[1] for a in args if a.startswith("--extract-certificates=")
            )
            value = (Path(args[-1]) / "Contents/_CodeSignature/leaf").read_bytes()
            if state.get("bad_arch") and "arm64" in args:
                value = b"other"
            if (
                state.get("bad_nested_arch")
                and "x86_64" in args
                and Path(args[-1]).suffix == ".framework"
            ):
                value = b"other"
            Path(prefix + "0").write_bytes(value)
        elif "--verbose=4" in args:
            code = Path(args[-1])
            if code.suffix == ".bundle":
                return b"Format=bundle"
            flags = state.get("flags", "10000")
            executable = state.get("executable", str(code / "Contents/MacOS/AstralDeep"))
            return f"Executable={executable}\nFormat=Mach-O universal\nflags=0x{flags}(runtime)".encode()
        elif "--entitlements" in args and "-d" in args:
            return plistlib.dumps(signed)
        elif "--force" in args:
            code = Path(args[-1])
            (code / "Contents/_CodeSignature/leaf").write_bytes(b"distribution")
            if code.suffix == ".app":
                (code / "Contents/MacOS/AstralDeep").write_bytes(
                    bytes.fromhex("cafebabe") + b"CODE|signature-new"
                )
        elif "--remove-signature" in args:
            path = Path(args[-1])
            path.write_bytes(path.read_bytes().split(b"|signature", 1)[0])
        else:
            assert "--verify" in args
        return b""

    monkeypatch.setattr(module, "run", fake)
    return SimpleNamespace(
        app=app,
        original=original,
        source=source,
        output=output,
        state=state,
        calls=calls,
        profile=profile,
        signed=signed,
        scratch=tmp_path,
    )


def test_actual_export_shape_repairs_development_resources_and_preserves_original(package):
    before = module.inventory(package.original)
    with pytest.raises(module.PackageError, match="nested_certificate_mismatch"):
        module.verify_app(package.app, package.scratch, DIST)
    receipt = module.repair(package.source, package.output, INSTALLER)
    assert receipt["repaired_resources"] == ["Contents/Resources/Sample.bundle"]
    assert receipt["payload_code_unchanged"]
    assert module.inventory(package.original) == before
    assert package.source.read_bytes() == b"original-package"
    assert package.output.read_bytes() == b"repaired-package"
    signing = [c for c in package.calls if "--force" in c]
    assert [Path(c[-1]).suffix for c in signing] == [".bundle", ".app"]
    assert all("--deep" not in c for c in signing)
    assert "--options" in signing[-1] and "runtime" in signing[-1]


def test_already_matching_resources_are_not_signed_again(package):
    (package.app / "Contents/Resources/Sample.bundle/Contents/_CodeSignature/leaf").write_bytes(
        b"distribution"
    )
    assert module.repair(package.source, package.output)["repaired_resources"] == []


@pytest.mark.parametrize(
    "case",
    [
        "development_profile",
        "devices",
        "all_devices",
        "debug",
        "sandbox",
        "certificate_type",
        "arch",
    ],
)
def test_profile_and_certificate_refusals_prevent_signing(package, case):
    if case == "development_profile":
        package.profile["DeveloperCertificates"] = [b"development"]
    if case == "devices":
        package.profile["ProvisionedDevices"] = ["synthetic-device"]
    if case == "all_devices":
        package.profile["ProvisionsAllDevices"] = True
    if case == "debug":
        package.signed["get-task-allow"] = True
    if case == "sandbox":
        package.signed["com.apple.security.app-sandbox"] = False
    if case == "certificate_type":
        package.state["subject"] = "Apple Development: Example"
    if case == "arch":
        package.state["bad_arch"] = True
    with pytest.raises(module.PackageError):
        module.repair(package.source, package.output)
    assert not package.output.exists()
    assert not any("--force" in c for c in package.calls)


@pytest.mark.parametrize("case", ["framework", "resource_executable", "metadata", "installer"])
def test_unsupported_or_changed_final_package_never_publishes(package, case):
    if case == "framework":
        (
            package.app / "Contents/Frameworks/Sample.framework/Contents/_CodeSignature/leaf"
        ).write_bytes(b"development")
    if case == "resource_executable":
        (package.app / "Contents/Resources/Sample.bundle/Contents/Info.plist").write_bytes(
            plistlib.dumps({"CFBundleExecutable": "unexpected"})
        )
    if case == "metadata":
        package.state["bad_metadata"] = True
    if case == "installer":
        package.state["installer"] = b"other"
    with pytest.raises(module.PackageError):
        module.repair(package.source, package.output, INSTALLER)
    assert not package.output.exists()


def test_payload_changes_and_replaced_code_are_refused(package, monkeypatch):
    final = package.scratch / "changed.app"
    shutil.copytree(package.app, final)
    (final / "Contents/Info.plist").write_bytes(b"changed")
    with pytest.raises(module.PackageError, match="payload_content_changed"):
        module.assert_payload(package.app, final, package.scratch)
    shutil.copyfile(package.app / "Contents/Info.plist", final / "Contents/Info.plist")
    (final / "Contents/MacOS/AstralDeep").write_bytes(
        bytes.fromhex("cafebabe") + b"DIFFERENT|signature"
    )
    with pytest.raises(module.PackageError, match="executable_changed"):
        module.assert_payload(package.app, final, package.scratch)
    (final / "new").touch()
    with pytest.raises(module.PackageError, match="payload_members_changed"):
        module.assert_payload(package.app, final, package.scratch)


def test_symlink_escape_and_scripts_refused(package):
    (package.app / "escape").symlink_to("/tmp")
    with pytest.raises(module.PackageError, match="escaping_symlink"):
        module.inventory(package.app)
    (package.app / "escape").unlink()
    (package.app / "link").symlink_to("Contents")
    assert module.inventory(package.app)["link"] == "link:Contents"
    (package.original / "sample.pkg/Scripts").mkdir()
    with pytest.raises(module.PackageError, match="unexpected_installer_scripts"):
        module.app_from_package(package.original)


@pytest.mark.parametrize("case", ["existing", "symlink", "input_missing", "fingerprint"])
def test_input_and_output_preconditions(package, case):
    if case == "existing":
        package.output.write_text("retain")
    if case == "symlink":
        package.output.symlink_to(package.scratch / "missing")
    if case == "input_missing":
        package.source.unlink()
    with pytest.raises(module.PackageError):
        module.repair(package.source, package.output, "name" if case == "fingerprint" else None)
    if case == "existing":
        assert package.output.read_text() == "retain"


def test_native_command_failure_is_closed_and_bounded(monkeypatch):
    calls = []

    def fake(*args, **kwargs):
        calls.append(kwargs)
        return SimpleNamespace(returncode=1, stdout=b"PRIVATE", stderr=b"PRIVATE")

    monkeypatch.setattr(module.subprocess, "run", fake)
    with pytest.raises(module.PackageError, match="codesign_failed"):
        module.run("codesign", "arg")
    assert calls[0]["timeout"] == 180
    monkeypatch.setattr(
        module.subprocess, "run", lambda *a, **k: SimpleNamespace(returncode=0, stdout=b"ok")
    )
    assert module.run("codesign") == b"ok"


def test_cli_success_and_closed_failure(package, monkeypatch, capsys):
    monkeypatch.setattr(
        "sys.argv", [str(SCRIPT), "--input", str(package.source), "--output", str(package.output)]
    )
    assert module.main() == 0
    assert json.loads(capsys.readouterr().out)["distribution_leaf_sha1"] == DIST
    assert module.main() == 1
    assert capsys.readouterr().out.strip() == "mac_store_package_repair_unavailable"


def test_timeout_cleanup_preserves_original(package, monkeypatch):
    original_run = module.run

    def failed(*args):
        if args[0] == "productbuild":
            raise subprocess.TimeoutExpired("productbuild", 180)
        return original_run(*args)

    monkeypatch.setattr(module, "run", failed)
    with pytest.raises(subprocess.TimeoutExpired):
        module.repair(package.source, package.output)
    assert package.source.read_bytes() == b"original-package"
    assert not package.output.exists()
    assert not package.state["product_app"]


@pytest.mark.parametrize("flags", ["0", "10001"])
def test_existing_runtime_flags_must_be_preserved(package, flags):
    package.state["flags"] = flags
    with pytest.raises(module.PackageError, match="unsupported_original_signature_flags"):
        module.repair(package.source, package.output)
    assert not any("--force" in c for c in package.calls)


def test_alternate_framework_slice_certificate_must_match(package):
    resource = package.app / "Contents/Resources/Sample.bundle/Contents/_CodeSignature/leaf"
    resource.write_bytes(b"distribution")
    package.state["bad_nested_arch"] = True
    with pytest.raises(module.PackageError, match="nested_certificate_mismatch"):
        module.verify_app(package.app, package.scratch, DIST)
    assert any("x86_64" in c and c[-1].endswith("Sample.framework") for c in package.calls)


def test_changed_symlink_to_identical_macho_is_refused(package):
    first = package.app / "Contents/MacOS/AstralDeep"
    shutil.copyfile(first, first.with_name("SameCode"))
    (package.app / "entry").symlink_to("Contents/MacOS/AstralDeep")
    final = package.scratch / "same-code.app"
    shutil.copytree(package.app, final, symlinks=True)
    (final / "entry").unlink()
    (final / "entry").symlink_to("Contents/MacOS/SameCode")
    with pytest.raises(module.PackageError, match="payload_symlink_changed"):
        module.assert_payload(package.app, final, package.scratch)


@pytest.mark.parametrize("state", [{"architectures": ""}, {"executable": "/tmp/outside"}])
def test_invalid_native_slice_metadata_refuses(package, state):
    package.state.update(state)
    with pytest.raises(module.PackageError):
        module.architectures(package.app)
