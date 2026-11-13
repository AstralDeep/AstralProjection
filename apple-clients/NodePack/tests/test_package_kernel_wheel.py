"""Checks the kernel wheel packager's layout, RECORD hashes and refusal of an incomplete stage."""

import base64
import hashlib
import sys
import zipfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from package_kernel_wheel import NAME, build_wheel  # noqa: E402


def stage(tmp_path: Path, with_library: bool = True) -> Path:
    directory = tmp_path / "stage"
    directory.mkdir()
    (directory / "astral_kernel_ffi.py").write_text("VALUE = 1\n")
    if with_library:
        (directory / "libastral_kernel_ffi.dylib").write_bytes(b"\xcf\xfa\xed\xfe")
    return directory


def test_wheel_layout_tag_and_record(tmp_path):
    wheel = build_wheel(stage(tmp_path), tmp_path / "out", "0.1.0", "macosx_14_0_arm64")
    assert wheel.name == f"{NAME}-0.1.0-py3-none-macosx_14_0_arm64.whl"
    with zipfile.ZipFile(wheel) as archive:
        names = set(archive.namelist())
        assert f"{NAME}/libastral_kernel_ffi.dylib" in names
        assert f"{NAME}/astral_kernel_ffi.py" in names
        assert "Tag: py3-none-macosx_14_0_arm64" in archive.read(f"{NAME}-0.1.0.dist-info/WHEEL").decode()
        for line in archive.read(f"{NAME}-0.1.0.dist-info/RECORD").decode().splitlines():
            path, digest, size = line.split(",")
            if not digest:
                continue
            data = archive.read(path)
            expected = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
            assert digest == f"sha256={expected}" and int(size) == len(data)


def test_build_is_reproducible(tmp_path):
    first = build_wheel(stage(tmp_path), tmp_path / "a", "0.1.0", "macosx_14_0_arm64").read_bytes()
    second = build_wheel(tmp_path / "stage", tmp_path / "b", "0.1.0", "macosx_14_0_arm64").read_bytes()
    assert first == second


def test_missing_library_is_refused(tmp_path):
    with pytest.raises(SystemExit):
        build_wheel(stage(tmp_path, with_library=False), tmp_path / "out", "0.1.0", "macosx_14_0_arm64")
