"""Checks same-run Apple UI build transport used by apple-ci without building or launching a client."""

import json
import plistlib
import subprocess
import tarfile

import pytest


from scripts import ci_apple_ui_products as MODULE


@pytest.fixture
def repo(tmp_path):
    repository = tmp_path / "source"
    lock = repository / MODULE.PACKAGE_LOCK
    lock.parent.mkdir(parents=True)
    lock.write_text('{"pins":[]}\n')
    subprocess.run(["git", "init", str(repository)], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(repository), "config", "user.email", "tests@example.invalid"], check=True)
    subprocess.run(["git", "-C", str(repository), "config", "user.name", "Tests"], check=True)
    subprocess.run(["git", "-C", str(repository), "add", MODULE.PACKAGE_LOCK], check=True)
    subprocess.run(["git", "-C", str(repository), "commit", "-m", "source"], check=True, capture_output=True)
    return repository


def make_build(tmp_path, platform):
    derived = tmp_path / "build with spaces"
    products = derived / "Build/Products"
    products.mkdir(parents=True)
    targets = [{"BlueprintName": name} for name in ("AstralAppTests", "AstralAppUITests")]
    (products / f"AstralApp_{platform}.xctestrun").write_bytes(
        plistlib.dumps({"TestConfigurations": [{"TestTargets": targets}]})
    )
    for name in MODULE.REQUIRED_PRODUCTS[platform]:
        file = products / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(b"instrumented executable")
        file.chmod(0o755)
    if platform == "ios":
        runtime = products / "Debug-iphonesimulator/Frameworks/Example.framework"
        runtime.mkdir(parents=True)
        (runtime / "Versions").mkdir()
        (runtime / "Versions/runtime").write_bytes(b"runtime dependency")
        (runtime / "runtime").symlink_to("Versions/runtime")
    return derived


@pytest.fixture
def build(tmp_path, monkeypatch, repo):
    monkeypatch.setenv("XCODE_BUILD", "17F113")
    return make_build(tmp_path, "ios"), tmp_path / "products.tar", tmp_path / "restored", repo


@pytest.fixture
def mac_build(tmp_path, monkeypatch, repo):
    monkeypatch.setenv("XCODE_BUILD", "17F113")
    return make_build(tmp_path, "macos"), tmp_path / "mac-products.tar", tmp_path / "mac-restored", repo


def test_products_archive_preserves_complete_tree_and_executable_modes(build):
    derived, archive, restored, repo = build
    MODULE.pack(repo, derived, archive)
    MODULE.restore(repo, restored, archive)
    source = derived / "Build/Products"
    destination = restored / "Build/Products"
    assert sorted(p.relative_to(source) for p in source.rglob("*")) == sorted(
        p.relative_to(destination) for p in destination.rglob("*")
    )
    for name in MODULE.REQUIRED_PRODUCTS["ios"]:
        assert (destination / name).read_bytes() == b"instrumented executable"
        assert (destination / name).stat().st_mode & 0o777 == 0o755
    runtime = destination / "Debug-iphonesimulator/Frameworks/Example.framework/runtime"
    assert runtime.is_symlink() and runtime.read_bytes() == b"runtime dependency"


@pytest.mark.parametrize("missing", ["run", "unit-target", "executable", "mode", "duplicate-run"])
def test_pack_rejects_incomplete_products(build, missing):
    derived, archive, _, repo = build
    products = derived / "Build/Products"
    run = next(products.glob("*.xctestrun"))
    if missing == "run":
        run.unlink()
    elif missing == "unit-target":
        run.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [{"BlueprintName": "AstralAppUITests"}]}]}))
    elif missing == "duplicate-run":
        run.with_name("duplicate.xctestrun").write_bytes(run.read_bytes())
    elif missing == "mode":
        (products / MODULE.REQUIRED_PRODUCTS["ios"][0]).chmod(0o600)
    else:
        (products / MODULE.REQUIRED_PRODUCTS["ios"][0]).unlink()
    with pytest.raises(ValueError):
        MODULE.pack(repo, derived, archive)
    assert not archive.exists()


@pytest.mark.parametrize("field", ["head", "platform", "workspace", "xcode_build", "package_lock_sha256", "archive_sha256"])
def test_restore_rejects_build_identity_or_archive_changes(build, field):
    derived, archive, restored, repo = build
    MODULE.pack(repo, derived, archive)
    identity = archive.with_suffix(".json")
    data = json.loads(identity.read_text())
    data[field] = "mismatch"
    identity.write_text(json.dumps(data))
    with pytest.raises(ValueError):
        MODULE.restore(repo, restored, archive)
    assert not (restored / "Build/Products").exists()


@pytest.mark.parametrize("existing", ["directory", "symlink"])
def test_restore_refuses_existing_products(build, existing):
    derived, archive, restored, repo = build
    MODULE.pack(repo, derived, archive)
    products = restored / "Build/Products"
    products.parent.mkdir(parents=True)
    if existing == "directory":
        products.mkdir()
    else:
        products.symlink_to(derived / "Build/Products")
    with pytest.raises(ValueError):
        MODULE.restore(repo, restored, archive)


def test_restore_rejects_archive_outside_products(build):
    derived, archive, restored, repo = build
    MODULE.pack(repo, derived, archive)
    with tarfile.open(archive, "a") as bundle:
        bundle.addfile(tarfile.TarInfo("../outside"))
    identity = archive.with_suffix(".json")
    data = json.loads(identity.read_text())
    data["archive_sha256"] = MODULE.sha256(archive)
    identity.write_text(json.dumps(data))
    with pytest.raises(ValueError):
        MODULE.restore(repo, restored, archive)


def test_cli_runs_pack_and_restore(build, monkeypatch):
    derived, archive, restored, repo = build
    for action, output in (("pack", derived), ("restore", restored)):
        monkeypatch.setattr("sys.argv", ["ci_apple_ui_products.py", action, "--repo", str(repo), "--derived", str(output), "--archive", str(archive)])
        MODULE.main()
    assert (restored / "Build/Products").is_dir()


@pytest.mark.parametrize("missing", ["archive", "manifest"])
def test_restore_refuses_missing_same_run_artifact(build, missing):
    derived, archive, restored, repo = build
    MODULE.pack(repo, derived, archive)
    (archive if missing == "archive" else archive.with_suffix(".json")).unlink()
    with pytest.raises(FileNotFoundError):
        MODULE.restore(repo, restored, archive)
    assert not (restored / "Build/Products").exists()


def test_restore_rejects_escaping_symlink(build):
    derived, archive, restored, repo = build
    MODULE.pack(repo, derived, archive)
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
        MODULE.restore(repo, restored, archive)
    assert not (restored / "outside").exists()


def test_macos_products_archive_round_trips_complete_unit_and_ui_products(mac_build):
    derived, archive, restored, repo = mac_build
    MODULE.pack(repo, derived, archive, platform="macos")
    assert json.loads(archive.with_suffix(".json").read_text())["platform"] == "macos"
    MODULE.restore(repo, restored, archive, platform="macos")
    products = restored / "Build/Products"
    for name in MODULE.REQUIRED_PRODUCTS["macos"]:
        path = products / name
        assert path.read_bytes() == b"instrumented executable"
        assert path.stat().st_mode & 0o100


def test_cli_selects_macos_products_platform(mac_build, monkeypatch):
    derived, archive, restored, repo = mac_build
    for action, output in (("pack", derived), ("restore", restored)):
        monkeypatch.setattr(
            "sys.argv",
            ["ci_apple_ui_products.py", action, "--repo", str(repo), "--derived", str(output),
             "--archive", str(archive), "--platform", "macos"],
        )
        MODULE.main()
    assert (restored / "Build/Products/Debug/AstralDeep.app/Contents/MacOS/AstralDeep").is_file()


def test_restore_rejects_products_from_another_platform(mac_build):
    derived, archive, restored, repo = mac_build
    MODULE.pack(repo, derived, archive, platform="macos")
    with pytest.raises(ValueError):
        MODULE.restore(repo, restored, archive)
    assert not (restored / "Build/Products").exists()


def test_pack_rejects_dirty_tracked_source(build):
    derived, archive, _, repo = build
    (repo / MODULE.PACKAGE_LOCK).write_text('{"pins":["changed"]}\n')
    with pytest.raises(ValueError):
        MODULE.pack(repo, derived, archive)
    assert not archive.exists()
