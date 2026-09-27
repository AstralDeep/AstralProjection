"""Restrict PyInstaller native dependency discovery to the selected interpreter and Windows.
AstralDeep.spec applies this environment before collecting the locked package closure.
"""

from __future__ import annotations

from collections.abc import Mapping
import os
from pathlib import Path
import sys


class FreezeEnvironmentError(RuntimeError):
    pass


def freeze_environment(environment: Mapping[str, str] | None = None) -> dict[str, str]:
    if sys.platform != "win32":
        raise FreezeEnvironmentError("Windows freeze requires a Windows interpreter")
    result = dict(os.environ if environment is None else environment)
    windows_root = result.get("SystemRoot") or result.get("SYSTEMROOT")
    if not windows_root or not Path(windows_root).is_absolute():
        raise FreezeEnvironmentError("Windows freeze requires an absolute SystemRoot")
    executable = Path(sys.executable)
    directories = [
        executable.parent,
        Path(sys.base_prefix),
        Path(windows_root) / "System32",
        Path(windows_root),
    ]
    if not executable.is_absolute() or not executable.is_file() or any(
        not directory.is_absolute() or not directory.is_dir() for directory in directories
    ):
        raise FreezeEnvironmentError("Windows freeze requires existing interpreter and system directories")
    for name in list(result):
        if name.upper() in {"PATH", "PYTHONPATH", "PYTHONHOME"}:
            del result[name]
    result["PATH"] = os.pathsep.join(dict.fromkeys(str(path.resolve()) for path in directories))
    return result
