"""Verify native speech ownership in astral_client.voice and GUI-thread destruction.
Caller-supplied adapters and speech backends retain their existing Qt owners.
"""

import threading
from uuid import uuid4

import pytest
from PySide6.QtCore import QCoreApplication, QEvent, QObject
from shiboken6 import isValid

from astral_client.voice import QtLocalSpeechAdapter, VoiceController


@pytest.fixture
def qt_objects(qapp):
    objects = []
    yield objects
    for obj in reversed(objects):
        if isValid(obj):
            obj.deleteLater()
    QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)


def _controller(parent, local_speech=None):
    return VoiceController(
        device_id=str(uuid4()),
        token_provider=lambda: "",
        http_base="http://127.0.0.1:8001",
        connection_provider=lambda: None,
        chat_provider=lambda: None,
        transport=object(),
        audio=object(),
        http=object(),
        media=object(),
        local_speech=local_speech,
        parent=parent,
    )


def test_native_speech_is_destroyed_on_its_owners_thread(qapp, qt_objects):
    owner = QObject()
    controller = _controller(owner)
    adapter = controller.local_speech
    backend = adapter.tts
    engine = backend._engine
    descendants = [controller, adapter, backend, engine]
    qt_objects.extend([owner, *descendants])
    destroyed_threads = []
    for obj in descendants:
        obj.destroyed.connect(lambda *_: destroyed_threads.append(threading.get_ident()))

    assert adapter.parent() is controller
    assert backend.parent() is adapter
    assert engine.parent() is backend
    assert all(obj.thread() is qapp.thread() for obj in descendants)

    owner.deleteLater()
    QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)

    assert all(not isValid(obj) for obj in descendants)
    assert destroyed_threads == [threading.get_ident()] * len(descendants)


def test_injected_speech_backend_retains_its_owner(qapp, qt_objects):
    owner = QObject()
    backend = QObject(qapp)
    qt_objects.extend([owner, backend])
    adapter = QtLocalSpeechAdapter(
        audio=object(), helper=object(), tts=backend, parent=owner
    )
    qt_objects.append(adapter)

    assert adapter.parent() is owner
    assert adapter.tts is backend
    assert backend.parent() is qapp

    owner.deleteLater()
    QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)

    assert not isValid(adapter)
    assert isValid(backend)
    assert backend.parent() is qapp


def test_injected_speech_adapter_retains_its_owner(qapp, qt_objects):
    owner = QObject()
    adapter = QObject(qapp)
    controller = _controller(owner, local_speech=adapter)
    qt_objects.extend([owner, adapter, controller])

    assert controller.local_speech is adapter
    assert adapter.parent() is qapp

    owner.deleteLater()
    QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)

    assert not isValid(controller)
    assert isValid(adapter)
    assert adapter.parent() is qapp
