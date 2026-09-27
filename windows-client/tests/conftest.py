"""Bootstrap Windows client tests with an optional offscreen QApplication and isolated profiles.
Test-owned Qt roots are disposed after ordinary fixtures without touching preexisting widgets.
"""

import os
import sys
import uuid

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import pytest  # noqa: E402

try:
    from PySide6.QtCore import QCoreApplication, QEvent, QObject  # noqa: E402
    from PySide6.QtWidgets import QApplication, QWidget  # noqa: E402
    from shiboken6 import isValid  # noqa: E402

    _qt_instance = QApplication.instance
    _qt_all_widgets = QApplication.allWidgets
    _qt_top_levels = QApplication.topLevelWidgets
    _qt_parent = QObject.parent
    _qt_close = QWidget.close
    _qt_delete_later = QObject.deleteLater
    _qt_flush = QCoreApplication.sendPostedEvents
    _qt_deferred_delete = QEvent.Type.DeferredDelete
    _qt_valid = isValid
    _HAS_QT = True
except Exception:  # noqa: BLE001
    QApplication = None  # type: ignore[assignment]
    _HAS_QT = False


@pytest.fixture(autouse=True)
def _native_test_roots():
    if not _HAS_QT:
        yield
        return
    existing = set(_qt_all_widgets()) if _qt_instance() is not None else set()
    yield
    if _qt_instance() is None:
        return
    roots = [widget for widget in _qt_top_levels()
             if _qt_valid(widget) and widget not in existing and _qt_parent(widget) is None]
    for widget in roots:
        if _qt_valid(widget):
            _qt_close(widget)
            _qt_delete_later(widget)
    _qt_flush(None, _qt_deferred_delete)
    assert all(not _qt_valid(widget) for widget in roots)


@pytest.fixture(scope="session")
def qapp():
    if not _HAS_QT:
        pytest.skip("PySide6 not installed")
    app = QApplication.instance() or QApplication([])
    yield app


@pytest.fixture
def native_root(qapp, _native_test_roots):
    from PySide6.QtCore import QCoreApplication, QEvent
    from PySide6.QtWidgets import QWidget
    from shiboken6 import isValid

    from astral_client.app import SurfaceDialog

    roots = []

    def create(factory, *args, **kwargs):
        widget = factory(*args, **kwargs)
        assert isinstance(widget, QWidget)
        roots.append(widget)
        return widget

    yield create
    for widget in reversed(roots):
        if isValid(widget):
            if isinstance(widget, SurfaceDialog):
                widget.set_mandatory(False)
            widget.close()
            widget.deleteLater()
    QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
    assert all(not isValid(widget) for widget in roots)


@pytest.fixture(autouse=True)
def isolated_native_profile(monkeypatch, _native_test_roots):
    monkeypatch.setenv("ASTRAL_WINDOWS_PROFILE_ID", str(uuid.uuid4()))
