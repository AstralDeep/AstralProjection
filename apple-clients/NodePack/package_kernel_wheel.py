"""Packages the uniffi Python bindings and the macOS kernel dylib into a wheel with only the standard library.

build_kernel.sh calls it with the staging directory that holds astral_kernel_ffi.py and libastral_kernel_ffi.dylib.
"""

import argparse
import base64
import hashlib
import zipfile
from pathlib import Path

NAME = "astral_kernel"


def record_line(path: str, data: bytes) -> str:
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
    return f"{path},sha256={digest},{len(data)}"


def build_wheel(stage: Path, out: Path, version: str, platform_tag: str) -> Path:
    bindings = stage / "astral_kernel_ffi.py"
    library = stage / "libastral_kernel_ffi.dylib"
    for required in (bindings, library):
        if not required.is_file():
            raise SystemExit(f"missing {required}")
    dist_info = f"{NAME}-{version}.dist-info"
    files = {
        f"{NAME}/__init__.py": b"from .astral_kernel_ffi import *  # noqa: F401,F403\n",
        f"{NAME}/astral_kernel_ffi.py": bindings.read_bytes(),
        f"{NAME}/libastral_kernel_ffi.dylib": library.read_bytes(),
        f"{dist_info}/METADATA": (
            f"Metadata-Version: 2.1\nName: {NAME.replace('_', '-')}\nVersion: {version}\n"
            "Requires-Python: >=3.9\n"
        ).encode(),
        f"{dist_info}/WHEEL": (
            "Wheel-Version: 1.0\nGenerator: astral nodepack package_kernel_wheel.py\n"
            f"Root-Is-Purelib: false\nTag: py3-none-{platform_tag}\n"
        ).encode(),
    }
    record = [record_line(path, data) for path, data in files.items()]
    record.append(f"{dist_info}/RECORD,,")
    files[f"{dist_info}/RECORD"] = ("\n".join(record) + "\n").encode()

    out.mkdir(parents=True, exist_ok=True)
    wheel = out / f"{NAME}-{version}-py3-none-{platform_tag}.whl"
    with zipfile.ZipFile(wheel, "w", zipfile.ZIP_DEFLATED) as archive:
        for path, data in files.items():
            info = zipfile.ZipInfo(path, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, data)
    return wheel


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--platform-tag", required=True)
    args = parser.parse_args()
    print(build_wheel(args.stage, args.out, args.version, args.platform_tag))


if __name__ == "__main__":
    main()
