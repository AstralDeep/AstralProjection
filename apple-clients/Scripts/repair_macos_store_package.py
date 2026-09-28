#!/usr/bin/env python3
"""Repairs Development-signed resource bundles left inside an already-exported Mac Store
package: re-signs them inside-out with the exported app's Distribution identity,
reseals the app last, and verifies the repackaged payload.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


class PackageError(ValueError):
    pass


def run(*args: str) -> bytes:
    result = subprocess.run(args, capture_output=True, timeout=180, check=False)
    if result.returncode:
        # Command output can carry identity details, so only the tool and option enter the error
        option = next((a.split("=", 1)[0] for a in args[1:] if a.startswith("-")), "")
        raise PackageError(f"{Path(args[0]).name}_failed {option}".rstrip())
    if args[0] == "codesign" and "--verbose=4" in args:
        return result.stderr
    return result.stdout


def inventory(root: Path) -> dict[str, str]:
    result = {}
    size = 0
    for path in root.rglob("*"):
        name = str(path.relative_to(root))
        if path.is_symlink():
            if not path.resolve().is_relative_to(root.resolve()):
                raise PackageError("escaping_symlink")
            result[name] = "link:" + str(path.readlink())
        elif path.is_file():
            size += path.stat().st_size
            result[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        elif not path.is_dir():
            raise PackageError("unsupported_entry")
        if len(result) > 20000 or size > 512 * 1024 * 1024:
            raise PackageError("payload_limit")
    return result


def app_from_package(root: Path) -> Path:
    apps = list(root.glob("*.pkg/Payload/*.app"))
    if len(apps) != 1 or apps[0].is_symlink():
        raise PackageError("expected_one_app")
    if list(root.rglob("Scripts")):
        raise PackageError("unexpected_installer_scripts")
    inventory(root)
    return apps[0]


def certificate(path: Path, scratch: Path, arch: str | None = None) -> str:
    with tempfile.TemporaryDirectory(dir=scratch) as directory:
        prefix = str(Path(directory) / "cert")
        args = ["codesign", "-d", "--extract-certificates=" + prefix]
        if arch:
            args += ["--arch", arch]
        run(*args, str(path))
        leaf = Path(prefix + "0")
        # An ad hoc signature has no certificate chain, so it matches no identity.
        return hashlib.sha1(leaf.read_bytes()).hexdigest().upper() if leaf.is_file() else ""


# SwiftPM resource bundles can be exported with no signature at all
def unsigned_resource(code: Path, app: Path) -> bool:
    return (
        code.suffix == ".bundle"
        and code.is_relative_to(app / "Contents/Resources")
        and not (code / "Contents/_CodeSignature").exists()
    )


def installer_certificate(package: Path, scratch: Path) -> str:
    run("pkgutil", "--check-signature", str(package))
    toc = scratch / "package-toc.xml"
    run("xar", "-f", str(package), "--dump-toc=" + str(toc))
    certificates = ET.fromstring(toc.read_bytes()).findall(
        "./toc/signature/.//{http://www.w3.org/2000/09/xmldsig#}X509Certificate"
    )
    if not certificates:
        raise PackageError("missing_installer_certificate")
    leaf = base64.b64decode("".join((certificates[0].text or "").split()), validate=True)
    der = scratch / "installer.der"
    der.write_bytes(leaf)
    subject = run(
        "openssl", "x509", "-inform", "DER", "-in", str(der), "-noout", "-subject"
    ).decode()
    if not re.search(r"CN\s*=\s*3rd Party Mac Developer Installer:", subject):
        raise PackageError("not_store_installer")
    return hashlib.sha1(leaf).hexdigest().upper()


def entitlements(app: Path) -> dict:
    return plistlib.loads(run("codesign", "-d", "--entitlements", ":-", str(app)))


def code_bundles(app: Path) -> list[Path]:
    return sorted(
        (
            p
            for p in app.rglob("*")
            if p.is_dir()
            and not p.is_symlink()
            and p.suffix in {".app", ".framework", ".bundle", ".xpc", ".appex"}
        ),
        key=lambda p: (-len(p.parts), str(p)),
    )


def display(code: Path, arch: str | None = None) -> str:
    args = ["codesign", "-d", "--verbose=4"]
    if arch:
        args += ["--arch", arch]
    return run(*args, str(code)).decode()


def architectures(code: Path) -> list[str | None]:
    metadata = display(code)
    if "Mach-O" not in metadata:
        return [None]
    executable = re.search(r"^Executable=(.+)$", metadata, re.MULTILINE)
    if executable is None or not Path(executable[1]).resolve().is_relative_to(code.resolve()):
        raise PackageError("invalid_code_executable")
    values = run("lipo", "-archs", executable[1]).decode().split()
    if not values or len(values) > 8 or any(not re.fullmatch(r"[a-z0-9_]+", v) for v in values):
        raise PackageError("invalid_architectures")
    return values


def distribution_identity(app: Path, scratch: Path) -> tuple[str, dict]:
    profile = plistlib.loads(
        run("security", "cms", "-D", "-i", str(app / "Contents/embedded.provisionprofile"))
    )
    identity = certificate(app, scratch)
    allowed = {hashlib.sha1(c).hexdigest().upper() for c in profile["DeveloperCertificates"]}
    signed = entitlements(app)
    if (
        identity not in allowed
        or profile.get("ProvisionedDevices")
        or profile.get("ProvisionsAllDevices")
        or signed.get("com.apple.security.get-task-allow")
        or signed.get("get-task-allow")
        or signed.get("com.apple.security.app-sandbox") is not True
    ):
        raise PackageError("not_store_distribution")
    with tempfile.TemporaryDirectory(dir=scratch) as directory:
        prefix = str(Path(directory) / "leaf")
        run("codesign", "-d", "--extract-certificates=" + prefix, str(app))
        subject = run(
            "openssl", "x509", "-inform", "DER", "-in", prefix + "0", "-noout", "-subject"
        ).decode()
        if not re.search(
            r"CN\s*=\s*(Apple Distribution|3rd Party Mac Developer Application):", subject
        ):
            raise PackageError("not_distribution_certificate")
    for arch in ("arm64", "x86_64"):
        if certificate(app, scratch, arch) != identity:
            raise PackageError("architecture_certificate_mismatch")
        flags = re.search(r"\bflags=0x([0-9a-fA-F]+)\b", display(app, arch))
        # Refuse unknown flags rather than silently changing them
        if flags is None or int(flags[1], 16) != 0x10000:
            raise PackageError("unsupported_original_signature_flags")
    return identity, signed


def verify_app(app: Path, scratch: Path, identity: str) -> None:
    inventory(app)
    for code in [*code_bundles(app), app]:
        try:
            for arch in architectures(code):
                if certificate(code, scratch, arch) != identity:
                    raise PackageError("nested_certificate_mismatch")
        except PackageError as error:
            raise PackageError(f"{error} {where(code, app)}") from None
    run("codesign", "--verify", "--deep", "--strict", "--all-architectures", str(app))


def where(code: Path, app: Path) -> str:
    return "app" if code == app else str(code.relative_to(app))


def normalized_metadata(root: Path) -> dict[str, bytes]:
    result = {}
    for path in [root / "Distribution", *root.glob("*.pkg/PackageInfo")]:
        element = ET.fromstring(path.read_bytes())
        for node in element.iter():
            # Re-signing changes payload size and file count, so neither is compared
            node.attrib.pop("installKBytes", None)
            node.attrib.pop("numberOfFiles", None)
        result[str(path.relative_to(root))] = ET.tostring(element)
    return result


# Names the difference but never its values, which can carry identity details
def metadata_difference(before: dict[str, bytes], after: dict[str, bytes]) -> str:
    for name in sorted(before.keys() | after.keys()):
        if name not in before or name not in after:
            return f"{name} presence"
        if before[name] == after[name]:
            continue
        old, new = ET.fromstring(before[name]).iter(), ET.fromstring(after[name]).iter()
        for first, second in zip(old, new):
            if first.tag != second.tag:
                return f"{name} {first.tag} tag"
            keys = sorted(
                key
                for key in first.attrib.keys() | second.attrib.keys()
                if first.attrib.get(key) != second.attrib.get(key)
            )
            if keys:
                return f"{name} {first.tag} {','.join(keys)}"
            if (first.text or "").strip() != (second.text or "").strip():
                return f"{name} {first.tag} text"
        return f"{name} structure"
    return "none"


def assert_payload(original: Path, final: Path, scratch: Path) -> None:
    before, after = inventory(original), inventory(final)

    def members(files: dict[str, str]) -> set[str]:
        return {name for name in files if "_CodeSignature" not in Path(name).parts}

    if members(before) != members(after):
        raise PackageError("payload_members_changed")
    executables = []
    for name in before:
        if "_CodeSignature" in Path(name).parts or before[name] == after[name]:
            continue
        if before[name].startswith("link:") or after[name].startswith("link:"):
            raise PackageError("payload_symlink_changed")
        with (original / name).open("rb") as stream:
            magic = stream.read(4)
        if magic not in {
            bytes.fromhex(h)
            for h in (
                "feedface",
                "cefaedfe",
                "feedfacf",
                "cffaedfe",
                "cafebabe",
                "bebafeca",
                "cafebabf",
                "bfbafeca",
            )
        }:
            raise PackageError("payload_content_changed")
        executables.append(name)
    for index, executable in enumerate(executables):
        copies = []
        for label, root in (("before", original), ("after", final)):
            target = scratch / f"{label}-unsigned-{index}"
            shutil.copyfile(root / executable, target)
            run("codesign", "--remove-signature", str(target))
            copies.append(target.read_bytes())
        if copies[0] != copies[1]:
            raise PackageError("executable_changed")


def repair(source: Path, output: Path, installer: str | None = None) -> dict:
    if output.exists() or output.is_symlink() or source.resolve() == output.resolve():
        raise PackageError("output_exists")
    if installer is not None and not re.fullmatch(r"[0-9A-Fa-f]{40}", installer):
        raise PackageError("exact_installer_fingerprint_required")
    if source.is_symlink() or not source.is_file() or source.stat().st_size > 512 * 1024 * 1024:
        raise PackageError("input_limit")
    original_digest = hashlib.sha256(source.read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix="astral-mac-store-") as directory:
        scratch = Path(directory)
        actual_installer = installer_certificate(source, scratch)
        if installer is not None and installer.upper() != actual_installer:
            raise PackageError("installer_certificate_mismatch")
        installer = actual_installer
        original = scratch / "original"
        run("pkgutil", "--expand-full", str(source), str(original))
        original_app = app_from_package(original)
        try:
            identity, signed = distribution_identity(original_app, scratch)
        except PackageError as error:
            raise PackageError(f"{error} app") from None
        app = scratch / original_app.name
        run("ditto", str(original_app), str(app))
        repaired = []
        for code in code_bundles(app):
            try:
                current = "" if unsigned_resource(code, app) else certificate(code, scratch)
            except PackageError as error:
                raise PackageError(f"{error} {where(code, app)}") from None
            if current == identity:
                continue
            info = code / "Contents/Info.plist"
            if (
                code.suffix != ".bundle"
                or not code.is_relative_to(app / "Contents/Resources")
                or not info.is_file()
                or plistlib.loads(info.read_bytes()).get("CFBundleExecutable")
            ):
                raise PackageError("unsupported_nested_repair")
            run("codesign", "--force", "--sign", identity, "--timestamp", str(code))
            repaired.append(str(code.relative_to(app)))
        entitlement_file = scratch / "entitlements.plist"
        entitlement_file.write_bytes(plistlib.dumps(signed))
        run(
            "codesign",
            "--force",
            "--sign",
            identity,
            "--timestamp",
            "--options",
            "runtime",
            "--entitlements",
            str(entitlement_file),
            str(app),
        )
        verify_app(app, scratch, identity)
        package = scratch / "repaired.pkg"
        run(
            "productbuild",
            "--component",
            str(app),
            "/Applications",
            "--sign",
            installer,
            str(package),
        )
        if installer_certificate(package, scratch) != installer:
            raise PackageError("installer_certificate_mismatch")
        final = scratch / "final"
        run("pkgutil", "--expand-full", str(package), str(final))
        final_app = app_from_package(final)
        verify_app(final_app, scratch, identity)
        if entitlements(final_app) != signed:
            raise PackageError("entitlements_changed")
        before_metadata, after_metadata = normalized_metadata(original), normalized_metadata(final)
        if before_metadata != after_metadata:
            difference = metadata_difference(before_metadata, after_metadata)
            raise PackageError(f"installer_metadata_changed {difference}")
        assert_payload(original_app, final_app, scratch)
        if hashlib.sha256(source.read_bytes()).hexdigest() != original_digest:
            raise PackageError("input_changed")
        with output.open("xb") as target, package.open("rb") as data:
            shutil.copyfileobj(data, target)
        return {
            "input_sha256": original_digest,
            "output_sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
            "distribution_leaf_sha1": identity,
            "installer_leaf_sha1": installer.upper(),
            "repaired_resources": repaired,
            "payload_code_unchanged": True,
            "entitlements_unchanged": True,
            "installer_metadata_unchanged": True,
        }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--installer-certificate", help="Optional exact expected SHA-1 fingerprint")
    args = parser.parse_args()
    try:
        print(
            json.dumps(repair(args.input, args.output, args.installer_certificate), sort_keys=True)
        )
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, ET.ParseError) as error:
        print("mac_store_package_repair_unavailable")
        # The receipt stays closed; stderr carries only the fixed refusal reason.
        reason = str(error) if isinstance(error, PackageError) else type(error).__name__
        print(f"refusal: {reason}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
