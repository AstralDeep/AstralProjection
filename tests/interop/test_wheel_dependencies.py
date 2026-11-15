"""Verifies wheel-test dependency copying honors version constraints, markers and file boundaries."""

from pathlib import PurePosixPath
from types import SimpleNamespace
import zipfile

import pytest

from wheel_dependencies import copy_dependencies
import wheel_dependencies


def test_dependency_copy_validates_version_and_ignores_inactive_extras(tmp_path, monkeypatch):
    wheel = tmp_path / "root.whl"
    with zipfile.ZipFile(wheel, "w") as archive:
        archive.writestr("root.dist-info/METADATA", "Metadata-Version: 2.3\nRequires-Dist: sample>=1\nRequires-Dist: absent; extra == 'dev'\n")
    source = tmp_path / "source.py"
    source.write_text("qualified dependency")
    observed = []
    dependency = SimpleNamespace(version="2.0", requires=["sample>=1"],
        files=[PurePosixPath("sample/__init__.py"), PurePosixPath("../unsafe")], locate_file=lambda _: source)

    def distribution(name):
        observed.append(name)
        assert name == "sample"
        return dependency

    monkeypatch.setattr(wheel_dependencies.importlib.metadata, "distribution", distribution)
    target = tmp_path / "site"
    copy_dependencies(wheel, target)
    assert (target / "sample/__init__.py").read_text() == source.read_text()
    assert not (tmp_path / "unsafe").exists()
    assert observed == ["sample", "sample"]
    dependency.version = "0.5"
    with pytest.raises(ValueError, match="does not satisfy"):
        copy_dependencies(wheel, target)


def test_dependency_copy_requires_unambiguous_root_metadata(tmp_path):
    wheel = tmp_path / "root.whl"
    with zipfile.ZipFile(wheel, "w"):
        pass
    with pytest.raises(ValueError, match="exactly one"):
        copy_dependencies(wheel, tmp_path / "site")
