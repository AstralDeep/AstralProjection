"""Verify per-test native root disposal without touching shared Qt fixtures.
Isolated pytest processes exercise teardown ordering and captured native API calls.
"""

from pathlib import Path

import pytest


pytest_plugins = ["pytester"]
pytest.importorskip("PySide6")


def test_native_lifetime_preserves_shared_roots_and_runs_after_fixture_teardown(pytester):
    pytester.makeconftest(Path(__file__).with_name("conftest.py").read_text(encoding="utf-8"))
    pytester.makepyfile('''
import pytest
from PySide6.QtWidgets import QWidget
from shiboken6 import isValid
import conftest

state = {}

@pytest.fixture(scope="session")
def session_root(qapp):
    root = QWidget()
    yield root
    assert isValid(root)
    root.deleteLater()
    conftest._qt_flush(None, conftest._qt_deferred_delete)

@pytest.fixture(scope="module")
def module_root(qapp):
    root = QWidget()
    child = QWidget(root)
    yield root, child
    assert isValid(root) and isValid(child)
    child.deleteLater()
    root.deleteLater()
    conftest._qt_flush(None, conftest._qt_deferred_delete)

@pytest.fixture
def ordinary_root(qapp):
    root = QWidget()
    state["ordinary"] = root
    yield root
    assert isValid(root)
    state["ordinary_finalizer"] = True

def test_create(session_root, module_root, ordinary_root):
    state["transient"] = QWidget()
    state["child"] = QWidget(state["transient"])
    state["already_deleted"] = QWidget()
    state["already_deleted"].deleteLater()
    conftest._qt_flush(None, conftest._qt_deferred_delete)
    module_root[1].setParent(None)
    assert isValid(session_root) and isValid(module_root[0])

def test_verify(session_root, module_root):
    assert state["ordinary_finalizer"] is True
    for name in ("ordinary", "transient", "child", "already_deleted"):
        assert not isValid(state[name])
    assert isValid(session_root) and all(isValid(widget) for widget in module_root)
''')
    result = pytester.runpytest_subprocess("-q", "-p", "no:cacheprovider")
    result.assert_outcomes(passed=2)


def test_native_lifetime_handles_no_application_missing_qt_and_patched_methods(pytester):
    pytester.makeconftest(Path(__file__).with_name("conftest.py").read_text(encoding="utf-8"))
    pytester.makepyfile('''
import pytest
from PySide6.QtCore import QObject
from PySide6.QtWidgets import QApplication, QWidget
from shiboken6 import isValid
import conftest

def test_no_application_created():
    assert conftest._qt_instance() is None
    lifecycle = conftest._native_test_roots.__wrapped__()
    next(lifecycle)
    assert conftest._qt_instance() is None
    with pytest.raises(StopIteration):
        next(lifecycle)
    assert conftest._qt_instance() is None

def test_missing_qt_is_a_no_op(monkeypatch):
    monkeypatch.setattr(conftest, "_HAS_QT", False)
    lifecycle = conftest._native_test_roots.__wrapped__()
    next(lifecycle)
    with pytest.raises(StopIteration):
        next(lifecycle)

def test_cleanup_uses_original_native_methods(qapp, monkeypatch):
    lifecycle = conftest._native_test_roots.__wrapped__()
    next(lifecycle)
    root = QWidget()
    monkeypatch.setattr(QApplication, "instance", lambda: None)
    monkeypatch.setattr(QApplication, "topLevelWidgets", lambda: [])
    monkeypatch.setattr(QWidget, "close", lambda self: pytest.fail("patched close called"))
    monkeypatch.setattr(QObject, "deleteLater", lambda self: pytest.fail("patched delete called"))
    with pytest.raises(StopIteration):
        next(lifecycle)
    assert not isValid(root)
''')
    result = pytester.runpytest_subprocess("-q", "-p", "no:cacheprovider")
    result.assert_outcomes(passed=3)
