"""Checks the assembler's refusals: an unofficial or altered Python download, mismatched kernel artifacts, excluded packages that slipped in, and the backend prune."""

import hashlib

import pytest

import assemble_pack as ap


def test_python_must_come_from_the_official_release_host(tmp_path):
    with pytest.raises(ap.PackError, match="python-build-standalone"):
        ap.download_python({"url": "https://example.com/py.tar.gz", "sha256": "0" * 64}, tmp_path)


def test_a_cached_python_archive_with_the_wrong_digest_is_deleted_and_refused(tmp_path):
    url = ap.PYTHON_HOST_PREFIX + "20261110/cpython-test.tar.gz"
    cached = tmp_path / "cpython-test.tar.gz"
    cached.write_bytes(b"tampered")
    with pytest.raises(ap.PackError, match="SHA-256"):
        ap.download_python({"url": url, "sha256": "0" * 64}, tmp_path)
    assert not cached.exists()


def test_a_cached_python_archive_with_the_pinned_digest_is_used_without_a_download(tmp_path):
    url = ap.PYTHON_HOST_PREFIX + "20261110/cpython%2Btest.tar.gz"
    cached = tmp_path / "cpython+test.tar.gz"
    cached.write_bytes(b"genuine")
    pin = {"url": url, "sha256": hashlib.sha256(b"genuine").hexdigest()}
    assert ap.download_python(pin, tmp_path) == cached


def test_present_excluded_packages_are_refused_with_normalised_names():
    installed = [{"name": "SimpleITK", "version": "1"}, {"name": "python_magic", "version": "1"}]
    excluded = [{"name": "simpleitk"}, {"name": "python-magic"}, {"name": "spacy"}]
    with pytest.raises(ap.PackError, match="SimpleITK|simpleitk") as raised:
        ap.verify_exclusions(installed, excluded)
    assert "spacy" not in str(raised.value)
    ap.verify_exclusions([{"name": "numpy", "version": "1"}], excluded)


def test_backend_prune_removes_exclusions_nested_tests_and_bytecode(tmp_path):
    backend = tmp_path / "backend"
    for path in ("voice_agent/x.py", "tests/t.py", "agents/general/tests/t.py", "agents/general/a.py",
                 "orchestrator/__pycache__/x.pyc", "orchestrator/o.py"):
        (backend / path).parent.mkdir(parents=True, exist_ok=True)
        (backend / path).write_text("x")
    (backend / "requirements.txt").write_text("x")
    ap.prune_backend(backend, [{"path": "voice_agent"}, {"path": "requirements.txt"}])
    remaining = sorted(p.relative_to(backend).as_posix() for p in backend.rglob("*") if p.is_file())
    assert remaining == ["agents/general/a.py", "orchestrator/o.py"]


def test_kernel_artifacts_from_another_commit_are_refused(tmp_path):
    (tmp_path / "kernel-commit.txt").write_text("deadbeef\n")
    with pytest.raises(ap.PackError, match="pins.json"):
        ap.assemble(tmp_path / "out", tmp_path, tmp_path / "work")


def test_missing_kernel_artifacts_are_refused(tmp_path):
    import pins

    (tmp_path / "kernel-commit.txt").write_text(pins.load()["kernel"]["commit"] + "\n")
    with pytest.raises(ap.PackError, match="build_kernel.sh"):
        ap.assemble(tmp_path / "out", tmp_path, tmp_path / "work")


def test_every_launcher_module_is_copied_into_the_pack(tmp_path):
    ap.copy_launcher(tmp_path)
    copied = sorted(path.name for path in (tmp_path / "launcher").iterdir())
    assert copied == sorted(path.name for path in (ap.HERE / "launcher").glob("*.py"))
    assert "node_logging.py" in copied and "astral_node_launch.py" in copied
