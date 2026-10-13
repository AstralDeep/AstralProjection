"""Verify that native speech objects are destroyed with their GUI owner.
The real Qt speech chain must not remain available for worker-thread garbage collection.
"""

import threading
from types import SimpleNamespace
from uuid import uuid4

from PySide6.QtCore import QCoreApplication, QEvent, QObject, Qt
from shiboken6 import isValid

from astral_client.voice import VoiceController


def test_default_speech_objects_are_destroyed_with_controller(qapp):
    owner = QObject()
    controller = VoiceController(
        device_id=str(uuid4()),
        token_provider=lambda: "",
        http_base="https://localhost",
        connection_provider=lambda: None,
        chat_provider=lambda: None,
        transport=SimpleNamespace(),
        audio=SimpleNamespace(),
        http=SimpleNamespace(),
        media=SimpleNamespace(),
        parent=owner,
    )
    adapter = controller.local_speech
    backend = adapter.tts
    engine = backend._engine
    objects = [controller, adapter, backend, engine]
    destroyed_threads = []
    for item in objects:
        item.destroyed.connect(
            lambda: destroyed_threads.append(threading.get_ident()),
            Qt.ConnectionType.DirectConnection,
        )
    try:
        owner.deleteLater()
        QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
        assert all(not isValid(item) for item in objects)
        assert destroyed_threads == [threading.get_ident()] * len(objects)
    finally:
        for item in objects:
            if isValid(item):
                item.deleteLater()
        QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
