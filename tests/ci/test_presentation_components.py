"""Checks exact presentation source custody and local-wheel receipt denial before freezing clients."""

import hashlib
import json
import subprocess
from types import SimpleNamespace
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

import pytest

from scripts import install_presentation_components as tool


def repository(tmp_path):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.email", "fixture@example.invalid"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.name", "Fixture"], check=True)
    (tmp_path / "source.txt").write_text("committed source")
    subprocess.run(["git", "-C", str(tmp_path), "add", "source.txt"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "commit", "-qm", "Fixture"], check=True)
    return subprocess.check_output(["git", "-C", str(tmp_path), "rev-parse", "HEAD"], text=True).strip()


@pytest.mark.parametrize("dirty", [False, True])
def test_wrong_or_dirty_deep_source_is_refused_before_loading_helper(tmp_path, monkeypatch, dirty):
    commit = repository(tmp_path)
    if dirty:
        (tmp_path / "untracked").write_text("not qualified")
    pins = tmp_path / "pins.json"
    pins.write_text(json.dumps({"format": "astral.presentation-sources/v1", "deep": {
        "repository": "https://github.com/AstralDeep/AstralDeep.git", "commit": commit if dirty else "0" * 40}}))
    monkeypatch.setattr(tool, "PINS", pins)
    with pytest.raises(ValueError, match="clean|expected"):
        tool.sources(tmp_path, tmp_path, tmp_path)


def test_source_pin_identity_is_closed(tmp_path, monkeypatch):
    pins = tmp_path / "pins.json"
    pins.write_text('{}')
    monkeypatch.setattr(tool, "PINS", pins)
    with pytest.raises(ValueError, match="source pins"):
        tool.sources(tmp_path, tmp_path, tmp_path)


def receipt(tmp_path, monkeypatch):
    (tmp_path / "source/config").mkdir(parents=True)
    (tmp_path / "source/config/astral-composition.json").write_bytes(b"manifest")
    (tmp_path / "context.json").write_text(json.dumps(dict.fromkeys(("deep", "primitives", "kernel"), str(tmp_path))))
    wheels = tmp_path / "wheels"
    wheels.mkdir()
    payload = wheels / "component.whl"
    payload.write_bytes(b"qualified wheel")
    sha = hashlib.sha256(payload.read_bytes()).hexdigest()
    entries = [{"component": "astral-kernel", "wheel_sha256": sha, "wheel": payload.name}]
    invoked = []
    helper = SimpleNamespace(load_contract=lambda *a, **k: "contract", select_components=lambda *a: "selected",
        _load_lock=lambda *a: entries, verify_install=lambda *a: invoked.append(a))
    monkeypatch.setattr(tool, "sources", lambda *a: (helper, tmp_path, {}, {}))
    monkeypatch.setattr(tool.subprocess, "check_output", lambda *a, **k: b"manifest")
    monkeypatch.setattr(tool, "expected_hashes", lambda: {"astral-kernel": sha})
    return payload, entries, invoked


def test_verified_receipt_reaches_installed_origin_verification(tmp_path, monkeypatch):
    _, _, invoked = receipt(tmp_path, monkeypatch)
    tool.verify(tmp_path)
    assert len(invoked) == 1 and invoked[0][0] == "selected"


@pytest.mark.parametrize("change", ["wheel", "receipt", "manifest", "context"])
def test_tampered_local_presentation_inputs_fail_closed(tmp_path, monkeypatch, change):
    payload, entries, invoked = receipt(tmp_path, monkeypatch)
    if change == "wheel":
        payload.write_bytes(b"tampered wheel")
    elif change == "receipt":
        entries[0]["wheel_sha256"] = "0" * 64
    elif change == "manifest":
        (tmp_path / "source/config/astral-composition.json").write_bytes(b"tampered manifest")
    else:
        (tmp_path / "context.json").write_text('{}')
    with pytest.raises(ValueError):
        tool.verify(tmp_path)
    assert not invoked


def test_release_lock_has_real_local_hashes_and_no_index_substitute():
    assert set(tool.expected_hashes()) == set(tool.KEYS)
    text = (tool.ROOT / "windows-client/requirements-release.lock.txt").read_text()
    assert "astralprims==0.4.0" not in text
    assert "\nastral-rote==0.1.0" not in text
    spec = (tool.ROOT / "windows-client/AstralDeep.spec").read_text()
    assert 'collect_submodules("rote")' in spec
    assert spec.index('"verify"') < spec.index("a = Analysis(")


@pytest.mark.parametrize("text", ["", "astralprims @ ${ASTRAL_PRIMITIVES_WHEEL_URI} --hash=sha256:bad", "other @ ${ASTRAL_PRIMITIVES_WHEEL_URI} --hash=sha256:" + "0" * 64])
def test_unbound_or_mislabeled_release_hashes_are_refused(tmp_path, monkeypatch, text):
    (tmp_path / "windows-client").mkdir()
    (tmp_path / "windows-client/requirements-release.lock.txt").write_text(text)
    monkeypatch.setattr(tool, "ROOT", tmp_path)
    with pytest.raises(ValueError):
        tool.expected_hashes()


def test_existing_build_output_is_refused(tmp_path, monkeypatch):
    monkeypatch.setattr(tool, "sources", lambda *a: (None, tmp_path, {}, {}))
    with pytest.raises(ValueError, match="absent"):
        tool.build(tmp_path, tmp_path, tmp_path, tmp_path)


def test_wheel_zip_bytes_are_canonical_across_filesystem_metadata(tmp_path):
    archives = []
    contents = {
        "sample/__init__.py": b"VALUE = 1\n",
        "sample-1.0.dist-info/METADATA": b"Name: sample\nVersion: 1.0\n",
    }
    for name, system, mode in (("unix", 3, 0o100644), ("windows", 0, 0o100666)):
        path = tmp_path / f"{name}.whl"
        with ZipFile(path, "w", compression=ZIP_DEFLATED) as archive:
            for member, payload in contents.items():
                info = ZipInfo(member, (1980, 1, 1, 0, 0, 0))
                info.create_system = system
                info.external_attr = mode << 16
                archive.writestr(info, payload)
        archives.append(path)

    for archive in archives:
        tool.normalize_wheel_archive(archive)

    assert archives[0].read_bytes() == archives[1].read_bytes()
    with ZipFile(archives[0]) as archive:
        assert {member.filename: archive.read(member.filename) for member in archive.infolist()} == contents
        assert all(member.create_system == 3 for member in archive.infolist())
        assert all(member.external_attr == 0o100644 << 16 for member in archive.infolist())


def test_normalized_component_wheel_updates_receipt_digest(tmp_path):
    wheel = tmp_path / "component.whl"
    with ZipFile(wheel, "w") as archive:
        archive.writestr("component.py", b"VALUE = 1\n")
    lock = tmp_path / "astral-component-wheels.lock.json"
    lock.write_text(json.dumps({"components": [{"wheel": wheel.name, "wheel_sha256": "old"}]}))

    def write_lock(path, document):
        path.write_text(json.dumps(document))

    tool.normalize_component_wheels(SimpleNamespace(_write_lock=write_lock), lock)

    entry = json.loads(lock.read_text())["components"][0]
    assert entry["wheel_sha256"] == hashlib.sha256(wheel.read_bytes()).hexdigest()
    with ZipFile(wheel) as archive:
        assert archive.read("component.py") == b"VALUE = 1\n"


@pytest.mark.parametrize("case", ["duplicate", "directory", "extra", "comment", "invalid-zip"])
def test_noncanonical_wheel_archives_are_rejected(tmp_path, case):
    path = tmp_path / "component.whl"
    with ZipFile(path, "w") as archive:
        first = ZipInfo("component.py")
        if case == "extra":
            first.extra = b"\x01\x00\x00\x00"
        elif case == "comment":
            first.comment = b"comment"
        archive.writestr(first, b"source")
        if case == "duplicate":
            with pytest.warns(UserWarning, match="Duplicate name"):
                archive.writestr(ZipInfo("component.py"), b"duplicate")
        elif case == "directory":
            archive.writestr(ZipInfo("package/"), b"")
    if case == "invalid-zip":
        path.write_bytes(b"not a zip archive")

    with pytest.raises(ValueError, match="duplicate|noncanonical|could not be normalized"):
        tool.normalize_wheel_archive(path)
    assert not path.with_suffix(path.suffix + ".normalized").exists()


def test_cli_requires_all_explicit_sources(monkeypatch):
    monkeypatch.setattr(tool.sys, "argv", ["installer", "install"])
    with pytest.raises(SystemExit, match="all three"):
        tool.main()



def test_composite_action_preserves_nested_roots_interpreter_and_checkout_custody():
    action = (tool.ROOT / ".github/actions/presentation/action.yml").read_text()
    pins = json.loads(tool.PINS.read_text())
    assert pins["deep"]["commit"] in action
    assert action.count("persist-credentials: false") == 3
    assert "working-directory: ${{ inputs.projection-root }}" in action
    assert '"$PRESENTATION_PYTHON"' in action and "setup-python" not in action
    assert '--output "$PRESENTATION_OUTPUT"' in action
    assert "$GITHUB_WORKSPACE/.presentation-sources/" in action



def test_installer_coverage_is_opt_in_and_preserved_by_the_python_owner_job():
    action = (tool.ROOT / ".github/actions/presentation/action.yml").read_text()
    workflow = (tool.ROOT / ".github/workflows/ci.yml").read_text()
    lock = (tool.ROOT / "tooling/python-ci/requirements.lock.txt").read_text()
    assert "${" not in lock
    assert 'default: "false"' in action
    assert '[[ "$PRESENTATION_EXTERNAL_LOCK" == "tooling/python-ci/requirements.lock.txt" ]]' in action
    assert action.index("coverage erase") < action.index("coverage run --branch --append")
    assert "coverage run --branch --append" in action
    assert workflow.count('measure-coverage: "true"') == 1
    assert "--cov-branch --cov-append" in workflow
