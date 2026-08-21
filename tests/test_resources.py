"""Public package and resource contracts for AstralProjection."""

from __future__ import annotations

import hashlib
import importlib
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

import astralprojection
from astralprojection import resources

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


def test_compatibility_packages_and_public_facade_are_importable() -> None:
    assert importlib.import_module("webrender").__name__ == "webrender"
    assert importlib.import_module("rote").__name__ == "rote"
    assert astralprojection.CONTRACT_VERSION == "astralprojection.contract/v1"
    assert astralprojection.__version__ == "0.1.0"
    assert astralprojection.static_path is resources.static_path
    assert astralprojection.template_path is resources.template_path
    assert astralprojection.protocol_manifest_path is resources.protocol_manifest_path


@pytest.mark.parametrize(
    ("accessor", "name"),
    [
        (resources.template_path, "shell.html"),
        (resources.template_path, "kiosk.html"),
        (resources.static_path, "client.js"),
        (resources.static_path, "astral.css"),
        (resources.font_path, "inter-latin.woff2"),
        (resources.font_path, "jetbrains-mono-latin.woff2"),
        (resources.image_path, "astra-fav.png"),
        (resources.image_path, "AstralDeep.png"),
        (resources.vendor_path, "plotly.min.js"),
        (resources.vendor_path, "tailwind.js"),
        (resources.vendor_path, "livekit-client.umd.min.js"),
        (resources.vendor_path, "livekit-client.sha256"),
        (resources.vendor_path, "LICENSE.livekit-client"),
        (resources.vendor_path, "THIRD_PARTY_NOTICES.livekit-client"),
        (resources.vendor_path, "THIRD_PARTY_NOTICES.livekit-client.sha256"),
        (resources.fixture_path, "voice_065/client_conformance.json"),
        (resources.fixture_path, "voice_065/recap_review_matrix.json"),
        (
            resources.fixture_path,
            "runtime_reliability_060/process-supervision-vectors.json",
        ),
    ],
)
def test_declared_resources_are_present(accessor, name: str) -> None:
    resource = accessor(name)
    assert resource.is_file(), name
    assert resource.read_bytes(), name


def test_protocol_and_notice_resources_are_packaged() -> None:
    protocol = json.loads(resources.protocol_manifest_path().read_text(encoding="utf-8"))
    assert protocol["version"] == 1
    packaged_notice = resources.notice_path()
    notice = packaged_notice.read_text(encoding="utf-8")
    assert notice.startswith("AstralProjection\n")
    assert "LiveKit Web Client 2.21.0" in notice
    assert packaged_notice.read_bytes() == (REPOSITORY_ROOT / "NOTICE").read_bytes()


def test_livekit_bundle_matches_packaged_digest() -> None:
    bundle = resources.vendor_path("livekit-client.umd.min.js")
    digest_file = resources.vendor_path("livekit-client.sha256")
    expected = digest_file.read_text(encoding="ascii").strip().split()[0]
    assert len(bundle.read_bytes()) > 100_000
    assert resources.resource_sha256(bundle) == expected
    assert hashlib.sha256(bundle.read_bytes()).hexdigest() == expected


@pytest.mark.parametrize(
    "unsafe",
    [
        "",
        ".",
        "..",
        "../shell.html",
        "folder/../shell.html",
        "/absolute",
        "C:/absolute",
        "folder\\file",
        "folder//file",
        ".git/config",
        "nul.txt",
        "trailing./file",
        "control\x00byte",
    ],
)
def test_resource_accessors_refuse_traversal_and_nonportable_names(unsafe: str) -> None:
    for accessor in (
        resources.static_path,
        resources.template_path,
        resources.font_path,
        resources.image_path,
        resources.vendor_path,
        resources.fixture_path,
    ):
        with pytest.raises(resources.InvalidResourcePath):
            accessor(unsafe)


def test_missing_resource_is_not_silently_returned() -> None:
    with pytest.raises(resources.ResourceNotFoundError):
        resources.static_path("missing.js")


def test_resource_roots_are_package_traversables() -> None:
    assert resources.static_root().is_dir()
    assert resources.template_root().is_dir()
    assert resources.contract_root().is_dir()


def test_wheel_install_contains_compatibility_packages_and_resources(tmp_path: Path) -> None:
    wheel_dir = tmp_path / "wheel"
    install_dir = tmp_path / "site"
    wheel_dir.mkdir()
    install_dir.mkdir()
    build = subprocess.run(
        [
            sys.executable,
            "-m",
            "build",
            "--wheel",
            "--no-isolation",
            "--outdir",
            os.fspath(wheel_dir),
            os.fspath(REPOSITORY_ROOT),
        ],
        cwd=tmp_path,
        check=False,
        capture_output=True,
        text=True,
    )
    assert build.returncode == 0, build.stdout + build.stderr
    [wheel] = wheel_dir.glob("astralprojection-*.whl")
    install = subprocess.run(
        [
            sys.executable,
            "-m",
            "pip",
            "install",
            "--no-deps",
            "--target",
            os.fspath(install_dir),
            os.fspath(wheel),
        ],
        cwd=tmp_path,
        check=False,
        capture_output=True,
        text=True,
    )
    assert install.returncode == 0, install.stdout + install.stderr

    probe = subprocess.run(
        [
            sys.executable,
            "-I",
            "-c",
            (
                "import json, pathlib, sys; "
                f"sys.path.insert(0, {os.fspath(install_dir)!r}); "
                "import astralprojection, webrender, rote; "
                "p=astralprojection.protocol_manifest_path(); "
                "assert json.loads(p.read_text(encoding='utf-8'))['version'] == 1; "
                "assert astralprojection.static_path('client.js').is_file(); "
                "assert astralprojection.template_path('shell.html').is_file(); "
                "assert astralprojection.vendor_path('livekit-client.umd.min.js').is_file(); "
                "assert astralprojection.fixture_path("
                "'voice_065/client_conformance.json').is_file(); "
                "assert astralprojection.notice_path().is_file(); "
                "assert pathlib.Path(astralprojection.__file__).is_relative_to("
                f"pathlib.Path({os.fspath(install_dir)!r})); "
                "print(astralprojection.CONTRACT_VERSION)"
            ),
        ],
        cwd=tmp_path,
        check=False,
        capture_output=True,
        text=True,
    )
    assert probe.returncode == 0, probe.stdout + probe.stderr
    assert probe.stdout.strip() == "astralprojection.contract/v1"
