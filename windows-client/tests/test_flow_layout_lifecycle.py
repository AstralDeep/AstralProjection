"""Verify custom layout item ownership through native widget and parent destruction.
Retained wrappers must not alias later Qt objects, and detached items remain caller-owned.
"""

import weakref

import pytest

pytest.importorskip("PySide6")

from PySide6.QtCore import QCoreApplication, QEvent
from PySide6.QtGui import QWindow
from PySide6.QtWidgets import QApplication, QPushButton, QSpacerItem, QVBoxLayout, QWidget
from shiboken6 import delete, isValid, ownedByPython

from astral_client.composites import FlowLayout


@pytest.mark.parametrize("operation", ["delete_widget", "reparent_widget", "delete_parent"])
def test_native_destruction_invalidates_retained_widget_items(qapp, native_root, operation):
    parent = native_root(QWidget)
    layout = FlowLayout(parent)
    widget = QPushButton("Retained item")
    layout.addWidget(widget)
    item = layout.itemAt(0)
    if operation == "delete_widget":
        widget.deleteLater()
    elif operation == "reparent_widget":
        widget.setParent(None)
    else:
        parent.deleteLater()
    QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
    try:
        assert not isValid(item)
        assert layout.items == []
        if operation == "reparent_widget":
            assert isValid(widget)
            assert widget.parent() is None
        elif operation == "delete_parent":
            assert not isValid(parent) and not isValid(layout)
    finally:
        if isValid(widget):
            widget.deleteLater()
            QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)


def test_taken_item_stays_owned_and_usable_after_layout_deletion(qapp, native_root):
    parent = native_root(QWidget)
    layout = FlowLayout(parent)
    widget = QPushButton("Transferred")
    layout.addWidget(widget)
    item = layout.takeAt(0)
    try:
        assert ownedByPython(item)
        widget.setParent(None)
        parent.deleteLater()
        QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
        assert isValid(item) and isValid(widget)
        assert item.widget() is widget
        assert layout.items == []
    finally:
        if isValid(item):
            delete(item)
        if isValid(widget):
            widget.deleteLater()
            QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)


@pytest.mark.parametrize("predelete_item", [False, True])
def test_deleting_layout_preserves_child_widgets_and_accepts_disposed_items(qapp, native_root, predelete_item):
    parent = native_root(QWidget)
    layout = FlowLayout(parent)
    widget = QPushButton("Still parented")
    layout.addWidget(widget)
    item = layout.itemAt(0)
    if predelete_item:
        delete(item)
    layout.deleteLater()
    QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
    assert not isValid(layout) and not isValid(item)
    assert layout.items == []
    assert isValid(widget) and widget.parent() is parent
    assert parent.layout() is None


@pytest.mark.parametrize("kind", ["widget", "spacer", "layout"])
def test_parent_destruction_disposes_owned_items_and_releases_references(qapp, native_root, kind):
    parent = native_root(QWidget)
    layout = FlowLayout(parent)
    if kind == "widget":
        layout.addWidget(QPushButton("Owned"))
    elif kind == "spacer":
        layout.addItem(QSpacerItem(16, 16))
    else:
        child = QVBoxLayout()
        layout.addChildLayout(child)
        child.addWidget(QPushButton("Nested"))
        layout.addItem(child)
        del child
    retained = layout.itemAt(0)
    reference = weakref.ref(retained)
    parent.deleteLater()
    QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
    assert not isValid(retained)
    assert layout.items == []
    del retained
    assert reference() is None


def test_repeated_layout_disposal_preserves_native_window_types_and_styles(qapp, native_root):
    stylesheet = qapp.styleSheet()
    retained = []
    try:
        for cycle in range(100):
            parent = native_root(QWidget)
            layout = FlowLayout(parent)
            for index in range(4):
                layout.addWidget(QPushButton(f"{cycle}:{index}"))
            retained.extend(layout.items)
            parent.show()
            QApplication.processEvents()
            assert isinstance(parent.windowHandle(), QWindow)
            parent.close()
            parent.deleteLater()
            QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
            assert all(not isValid(item) for item in retained)
            qapp.setStyleSheet(f"QPushButton {{ padding: {cycle % 3}px; }}")
    finally:
        qapp.setStyleSheet(stylesheet)
