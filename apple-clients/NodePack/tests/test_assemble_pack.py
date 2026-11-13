"""Checks the assembler's refusals: an unofficial or altered Python download, mismatched kernel artifacts, excluded packages that slipped in, and the backend prune."""

import hashlib
import os
import subprocess
import sys
from contextlib import contextmanager

import pytest

import assemble_pack as ap


def local_repository(path):
    path.mkdir()
    subprocess.run(["git", "init", "--quiet", path], check=True)
    subprocess.run(["git", "-C", path, "config", "user.name", "Pack Test"], check=True)
    subprocess.run(["git", "-C", path, "config", "user.email", "pack@example.test"], check=True)
    (path / "input.txt").write_text("pinned source\n")
    subprocess.run(["git", "-C", path, "add", "input.txt"], check=True)
    subprocess.run(["git", "-C", path, "commit", "--quiet", "-m", "Source"], check=True)
    return subprocess.check_output(["git", "-C", path, "rev-parse", "HEAD"], text=True).strip()


@pytest.mark.parametrize("dirty", ["tracked", "untracked"])
def test_local_export_refuses_a_dirty_source_checkout(tmp_path, monkeypatch, dirty):
    source = tmp_path / "source"
    commit = local_repository(source)
    monkeypatch.setenv("NODEPACK_REPO_ASTRALDEEP", str(source))
    (source / ("input.txt" if dirty == "tracked" else "untracked.txt")).write_text("not qualified")
    with pytest.raises(ap.PackError, match="clean"):
        ap.export_commit("AstralDeep", "https://example.test/repo", commit, tmp_path / "out", tmp_path / "work")


def test_local_export_refuses_a_checkout_at_another_revision_and_an_abbreviated_pin(tmp_path, monkeypatch):
    source = tmp_path / "source"
    commit = local_repository(source)
    monkeypatch.setenv("NODEPACK_REPO_ASTRALDEEP", str(source))
    with pytest.raises(ap.PackError, match="full"):
        ap.export_commit("AstralDeep", "https://example.test/repo", commit[:8], tmp_path / "short", tmp_path / "work")
    (source / "input.txt").write_text("new source")
    subprocess.run(["git", "-C", source, "commit", "--quiet", "-am", "New source"], check=True)
    with pytest.raises(ap.PackError, match="expected"):
        ap.export_commit("AstralDeep", "https://example.test/repo", commit, tmp_path / "old", tmp_path / "work")


def test_local_export_uses_the_explicit_clean_source_and_preserves_the_exact_committed_bytes(tmp_path, monkeypatch):
    work = tmp_path / "work"
    for index in range(2):
        source = tmp_path / f"source-{index}"
        commit = local_repository(source)
        (source / "input.txt").write_text(f"source {index}\n")
        subprocess.run(["git", "-C", source, "commit", "--quiet", "-am", f"Source {index}"], check=True)
        commit = subprocess.check_output(["git", "-C", source, "rev-parse", "HEAD"], text=True).strip()
        monkeypatch.setenv("NODEPACK_SOURCE_ASTRALDEEP", str(source))
        target = tmp_path / f"out-{index}"
        actual = ap.export_commit("AstralDeep", str(tmp_path / "not-the-source"), commit, target, work)
        assert actual == commit
        assert (target / "input.txt").read_bytes() == f"source {index}\n".encode()
        assert not (target / ".git").exists()


def test_source_changes_during_export_are_refused_and_never_replace_the_pinned_bytes(tmp_path, monkeypatch):
    source = tmp_path / "source"
    commit = local_repository(source)
    monkeypatch.setenv("NODEPACK_SOURCE_ASTRALDEEP", str(source))
    original = ap.tarfile.open

    @contextmanager
    def changed_source(*args, **kwargs):
        with original(*args, **kwargs) as bundle:
            yield bundle
        (source / "input.txt").write_text("changed during export")

    monkeypatch.setattr(ap.tarfile, "open", changed_source)
    with pytest.raises(ap.PackError, match="clean"):
        ap.export_commit("AstralDeep", str(tmp_path / "unused"), commit, tmp_path / "out", tmp_path / "work")
    assert (tmp_path / "out" / "input.txt").read_text() == "pinned source\n"


def test_default_source_exports_the_full_pin_from_its_private_mirror(tmp_path):
    source = tmp_path / "source"
    commit = local_repository(source)
    actual = ap.export_commit("default", str(source), commit, tmp_path / "out", tmp_path / "work")
    assert actual == commit
    assert (tmp_path / "out" / "input.txt").read_text() == "pinned source\n"


def test_local_source_validator_requires_the_repository_root_and_reports_cli_errors(tmp_path, monkeypatch, capsys):
    source = tmp_path / "source"
    commit = local_repository(source)
    nested = source / "nested"
    nested.mkdir()
    with pytest.raises(ValueError, match="checkout root"):
        ap.local_sources.validate(nested, commit)
    monkeypatch.setattr(sys, "argv", ["local_sources.py", str(source), commit])
    ap.local_sources.main()
    assert capsys.readouterr().out.strip() == str(source.resolve())
    monkeypatch.setattr(sys, "argv", ["local_sources.py"])
    with pytest.raises(SystemExit, match="usage"):
        ap.local_sources.main()
    monkeypatch.setattr(sys, "argv", ["local_sources.py", str(tmp_path / "missing"), commit])
    with pytest.raises(SystemExit, match="local source"):
        ap.local_sources.main()


def test_kernel_builder_refuses_dirty_local_source_before_creating_outputs(tmp_path):
    source = tmp_path / "source"
    commit = local_repository(source)
    (source / "unqualified.txt").write_text("uncommitted")
    output = tmp_path / "output"
    environment = {**os.environ, "KERNEL_COMMIT": commit, "NODEPACK_WORK": str(tmp_path / "work")}
    result = subprocess.run(
        ["bash", ap.HERE / "build_kernel.sh", "--source", source, "--out", output],
        env=environment, capture_output=True, text=True,
    )
    assert result.returncode != 0 and "clean checkout" in result.stderr
    assert not output.exists()


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
