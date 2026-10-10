"""Verify image workers do not retain native widgets beyond their GUI-thread lifetime.
Delayed image results must be safely discarded after the requesting label is destroyed.
"""

import gc
import threading
import weakref

import pytest
from PySide6.QtCore import QBuffer, QByteArray, QIODevice, Qt, Slot
from PySide6.QtGui import QImage

from astral_client import renderer


def test_pending_image_fetch_does_not_own_the_label(qapp, monkeypatch):
    started = threading.Event()
    release = threading.Event()
    workers = []
    destroyed = []

    def fetch(url):
        workers.append(threading.current_thread())
        started.set()
        assert release.wait(5)
        return None

    monkeypatch.setattr(renderer, "_fetch_image_bytes", fetch)
    label = renderer._AsyncImageLabel("https://example.invalid/image.png", "Image", 480)
    label.destroyed.connect(lambda: destroyed.append(threading.get_ident()), Qt.ConnectionType.DirectConnection)
    reference = weakref.ref(label)
    try:
        assert started.wait(5)
        del label
        gc.collect()
        assert reference() is None
        assert destroyed == [threading.get_ident()]
    finally:
        release.set()
        for worker in workers:
            worker.join(5)
            assert not worker.is_alive()
        qapp.processEvents()


@pytest.mark.parametrize("payload", ["image", "invalid", "empty"])
def test_image_results_are_applied_only_on_the_gui_thread(qapp, monkeypatch, native_root, payload):
    started = threading.Event()
    release = threading.Event()
    workers = []
    applied = []
    image = QImage(4, 4, QImage.Format.Format_ARGB32)
    image.fill(Qt.GlobalColor.red)
    data = QByteArray()
    buffer = QBuffer(data)
    assert buffer.open(QIODevice.OpenModeFlag.WriteOnly)
    assert image.save(buffer, "PNG")
    buffer.close()
    raw = {"image": bytes(data), "invalid": b"not an image", "empty": None}[payload]

    def fetch(url):
        workers.append(threading.current_thread())
        started.set()
        assert release.wait(5)
        return raw

    class Label(renderer._AsyncImageLabel):
        @Slot(object)
        def _apply_bytes(self, value):
            applied.append(threading.get_ident())
            super()._apply_bytes(value)

    monkeypatch.setattr(renderer, "_fetch_image_bytes", fetch)
    label = native_root(Label, "https://example.invalid/image.png", "Image", 2)
    try:
        assert started.wait(5)
        assert applied == [] and label.pixmap().isNull()
    finally:
        release.set()
        for worker in workers:
            worker.join(5)
            assert not worker.is_alive()
    assert applied == []
    qapp.processEvents()
    assert applied == [threading.get_ident()]
    if payload == "image":
        assert label.pixmap().width() == 2 and label.text() == ""
    else:
        assert label.pixmap().isNull() and label.text() == "Image"
