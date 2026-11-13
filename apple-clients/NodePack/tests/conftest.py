"""Puts the node pack scripts on the import path for its tests."""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
for entry in (ROOT, ROOT / "launcher"):
    if str(entry) not in sys.path:
        sys.path.insert(0, str(entry))
