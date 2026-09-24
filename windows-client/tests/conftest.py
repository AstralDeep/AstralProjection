"""Pytest bootstrap for the Windows client suite: fixes sys.path and provides the qapp
fixture, a headless QApplication that skips gracefully when PySide6 is unavailable.
"""

import os
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import pytest  # noqa: E402

try:
    from PySide6.QtWidgets import QApplication  # noqa: E402
    _HAS_QT = True
except Exception:  # noqa: BLE001
    QApplication = None  # type: ignore[assignment]
    _HAS_QT = False


@pytest.fixture(scope="session")
def qapp():
    if not _HAS_QT:
        pytest.skip("PySide6 not installed")
    app = QApplication.instance() or QApplication([])
    yield app
