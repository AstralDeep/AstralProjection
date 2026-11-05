"""Checks same-run Apple UI build transport used by apple-ci without building or launching a client."""

import json
from pathlib import Path
import plistlib
import tarfile

import pytest


from scripts import ci_apple_ui_products as MODULE


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def build(tmp_path, monkeypatch):
    monkeypatch.setenv("XCODE_BUILD", "17F113")
    derived = tmp_path / "build with spaces"
    products = derived / "Build/Products"
    products.mkdir(parents=True)
    targets = [{"BlueprintName": name} for name in ("AstralAppTests", "AstralAppUITests")]
    (products / "AstralApp_iphonesimulator26.5-arm64.xctestrun").write_bytes(
        plistlib.dumps({"TestConfigurations": [{"TestTargets": targets}]})
    )
    for name in MODULE.REQUIRED_PRODUCTS:
        file = products / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(b"instrumented executable")
        file.chmod(0o755)
    runtime = products / "Debug-iphonesimulator/Frameworks/Example.framework"
    runtime.mkdir(parents=True)
    (runtime / "Versions").mkdir()
    (runtime / "Versions/runtime").write_bytes(b"runtime dependency")
    (runtime / "runtime").symlink_to("Versions/runtime")
    return derived, tmp_path / "products.tar", tmp_path / "restored"


def test_products_archive_preserves_complete_tree_and_executable_modes(build):
    derived, archive, restored = build
    MODULE.pack(ROOT, derived, archive)
    MODULE.restore(ROOT, restored, archive)
    source = derived / "Build/Products"
    destination = restored / "Build/Products"
    assert sorted(p.relative_to(source) for p in source.rglob("*")) == sorted(
        p.relative_to(destination) for p in destination.rglob("*")
    )
    for name in MODULE.REQUIRED_PRODUCTS:
        assert (destination / name).read_bytes() == b"instrumented executable"
        assert (destination / name).stat().st_mode & 0o777 == 0o755
    runtime = destination / "Debug-iphonesimulator/Frameworks/Example.framework/runtime"
    assert runtime.is_symlink() and runtime.read_bytes() == b"runtime dependency"


@pytest.mark.parametrize("missing", ["run", "unit-target", "executable", "mode", "duplicate-run"])
def test_pack_rejects_incomplete_products(build, missing):
    derived, archive, _ = build
    products = derived / "Build/Products"
    run = next(products.glob("*.xctestrun"))
    if missing == "run":
        run.unlink()
    elif missing == "unit-target":
        run.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [{"BlueprintName": "AstralAppUITests"}]}]}))
    elif missing == "duplicate-run":
        run.with_name("duplicate.xctestrun").write_bytes(run.read_bytes())
    elif missing == "mode":
        (products / MODULE.REQUIRED_PRODUCTS[0]).chmod(0o600)
    else:
        (products / MODULE.REQUIRED_PRODUCTS[0]).unlink()
    with pytest.raises(ValueError):
        MODULE.pack(ROOT, derived, archive)
    assert not archive.exists()


@pytest.mark.parametrize("field", ["head", "workspace", "xcode_build", "package_lock_sha256", "archive_sha256"])
def test_restore_rejects_build_identity_or_archive_changes(build, field):
    derived, archive, restored = build
    MODULE.pack(ROOT, derived, archive)
    identity = archive.with_suffix(".json")
    data = json.loads(identity.read_text())
    data[field] = "mismatch"
    identity.write_text(json.dumps(data))
    with pytest.raises(ValueError):
        MODULE.restore(ROOT, restored, archive)
    assert not (restored / "Build/Products").exists()


@pytest.mark.parametrize("existing", ["directory", "symlink"])
def test_restore_refuses_existing_products(build, existing):
    derived, archive, restored = build
    MODULE.pack(ROOT, derived, archive)
    products = restored / "Build/Products"
    products.parent.mkdir(parents=True)
    if existing == "directory":
        products.mkdir()
    else:
        products.symlink_to(derived / "Build/Products")
    with pytest.raises(ValueError):
        MODULE.restore(ROOT, restored, archive)


def test_restore_rejects_archive_outside_products(build):
    derived, archive, restored = build
    MODULE.pack(ROOT, derived, archive)
    with tarfile.open(archive, "a") as bundle:
        bundle.addfile(tarfile.TarInfo("../outside"))
    identity = archive.with_suffix(".json")
    data = json.loads(identity.read_text())
    data["archive_sha256"] = MODULE.sha256(archive)
    identity.write_text(json.dumps(data))
    with pytest.raises(ValueError):
        MODULE.restore(ROOT, restored, archive)


def test_cli_runs_pack_and_restore(build, monkeypatch):
    derived, archive, restored = build
    for action, output in (("pack", derived), ("restore", restored)):
        monkeypatch.setattr("sys.argv", ["ci_apple_ui_products.py", action, "--repo", str(ROOT), "--derived", str(output), "--archive", str(archive)])
        MODULE.main()
    assert (restored / "Build/Products").is_dir()


@pytest.mark.parametrize("missing", ["archive", "manifest"])
def test_restore_refuses_missing_same_run_artifact(build, missing):
    derived, archive, restored = build
    MODULE.pack(ROOT, derived, archive)
    (archive if missing == "archive" else archive.with_suffix(".json")).unlink()
    with pytest.raises(FileNotFoundError):
        MODULE.restore(ROOT, restored, archive)
    assert not (restored / "Build/Products").exists()


def test_restore_rejects_escaping_symlink(build):
    derived, archive, restored = build
    MODULE.pack(ROOT, derived, archive)
    with tarfile.open(archive, "a") as bundle:
        link = tarfile.TarInfo("Products/escape")
        link.type = tarfile.SYMTYPE
        link.linkname = "../../outside"
        bundle.addfile(link)
    identity = archive.with_suffix(".json")
    data = json.loads(identity.read_text())
    data["archive_sha256"] = MODULE.sha256(archive)
    identity.write_text(json.dumps(data))
    with pytest.raises(tarfile.FilterError):
        MODULE.restore(ROOT, restored, archive)
    assert not (restored / "outside").exists()
