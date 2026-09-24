"""Child-process entry for one BYO agent bundle: rebinds stdio, then imports and runs
the delivered agent_main.py. Imports no Qt, since this interpreter is AstralDeep.exe
itself and importing Qt here would open a second GUI.
"""

from __future__ import annotations

import importlib
import io
import os
import sys
import traceback


# Frozen console=False build: sys.stdout can start as None
def _rebind_std_streams() -> bool:
    for fd, name, mode in ((1, "stdout", "w"), (2, "stderr", "w"), (0, "stdin", "r")):
        stream = getattr(sys, name, None)
        if stream is not None and callable(getattr(stream, "write", None) if mode == "w"
                                           else getattr(stream, "readline", None)):
            continue
        try:
            rebound = os.fdopen(
                fd, mode, buffering=1,
                encoding="utf-8", errors="replace", closefd=False,
            )
        except OSError:
            rebound = None
        if rebound is None and mode == "w":
            if name == "stderr":
                rebound = io.StringIO()
            else:
                return False
        setattr(sys, name, rebound)
    return getattr(sys, "stdout", None) is not None


def run_worker(agent_dir: str) -> int:
    if not _rebind_std_streams():
        return 3
    directory = os.path.abspath(agent_dir or "")
    entry = os.path.join(directory, "agent_main.py")
    if not os.path.isfile(entry):
        print(f"byo-worker: no agent_main.py in {directory}", file=sys.stderr, flush=True)
        return 2

    sys.path.insert(0, directory)
    try:
        module = importlib.import_module("agent_main")
    except Exception:  # noqa: BLE001
        traceback.print_exc()
        return 1

    entrypoint = getattr(module, "main", None) or getattr(module, "run", None)
    if not callable(entrypoint):
        return 0
    try:
        return int(entrypoint() or 0)
    except SystemExit as exc:
        return int(exc.code or 0)
    except Exception:  # noqa: BLE001
        traceback.print_exc()
        return 1


def main(argv=None) -> int:
    argv = list(sys.argv if argv is None else argv)
    if "--byo-worker" not in argv:
        print("usage: --byo-worker <agent_dir>", file=sys.stderr, flush=True)
        return 2
    idx = argv.index("--byo-worker")
    if idx + 1 >= len(argv):
        print("byo-worker: missing <agent_dir>", file=sys.stderr, flush=True)
        return 2
    return run_worker(argv[idx + 1])


if __name__ == "__main__":
    raise SystemExit(main())
