"""Verify main-window display tracking through Qt's widget event path.
Native-handle wrapper faults must not disable current-screen DPI and geometry updates.
"""

import pytest
from PySide6.QtCore import QCoreApplication, QEvent, QObject, QRect, Signal
from PySide6.QtWidgets import QApplication, QWidgetItem

from test_message_routing import win as window_fixture  # noqa: F401


@pytest.fixture(name="window")
def window_setup(request):
    return request.getfixturevalue("window_fixture")


class ScreenProbe(QObject):
    logicalDotsPerInchChanged = Signal(float)
    geometryChanged = Signal(QRect)


@pytest.mark.parametrize("fault", ["wrong_wrapper", "unavailable"])
def test_show_tracks_screen_when_borrowed_native_handle_cannot_be_used(window, monkeypatch, fault):
    borrowed = QWidgetItem(window._send_btn)
    calls = []

    def native_handle():
        calls.append(fault)
        if fault == "unavailable":
            raise RuntimeError("Native handle wrapper unavailable")
        return borrowed

    monkeypatch.setattr(window, "windowHandle", native_handle)
    window.show()
    QApplication.processEvents()
    assert window.isVisible()
    assert window._observed_screen is window.screen()
    assert window._viewport_timer.isActive()
    assert calls == []


def test_native_screen_signal_reaches_widget_and_refreshes_capabilities(window):
    window.show()
    QApplication.processEvents()
    screen = window.screen()
    window._viewport_timer.stop()
    window.windowHandle().screenChanged.emit(screen)
    assert window._observed_screen is screen
    assert window._viewport_timer.isActive()


@pytest.mark.parametrize("event_type", [QEvent.Type.ScreenChangeInternal, QEvent.Type.DevicePixelRatioChange])
def test_widget_screen_event_rebinds_only_current_monitor(window, monkeypatch, event_type):
    first, second = ScreenProbe(), ScreenProbe()
    selected = [first]
    monkeypatch.setattr(window, "screen", lambda: selected[0])
    window.show()
    assert window._observed_screen is first
    selected[0] = second
    QCoreApplication.sendEvent(window, QEvent(event_type))
    assert window._observed_screen is second
    for signal, value in ((first.logicalDotsPerInchChanged, 120.0), (first.geometryChanged, QRect(0, 0, 1280, 720))):
        window._viewport_timer.stop()
        signal.emit(value)
        assert not window._viewport_timer.isActive()
    for signal, value in ((second.logicalDotsPerInchChanged, 144.0), (second.geometryChanged, QRect(0, 0, 1920, 1080))):
        window._viewport_timer.stop()
        signal.emit(value)
        assert window._viewport_timer.isActive()


def test_unrelated_widget_event_preserves_current_monitor(window, monkeypatch):
    window.show()
    screen = window._observed_screen
    calls = []
    monkeypatch.setattr(window, "screen", lambda: calls.append(True))
    window._viewport_timer.stop()
    QCoreApplication.sendEvent(window, QEvent(QEvent.Type.LanguageChange))
    assert calls == []
    assert window._observed_screen is screen
    assert not window._viewport_timer.isActive()


def test_repeated_show_keeps_single_current_screen_subscription(window, monkeypatch):
    screen = ScreenProbe()
    requests = []
    monkeypatch.setattr(window, "screen", lambda: screen)
    monkeypatch.setattr(window, "_queue_device_refresh", lambda *args: requests.append(args))
    window.show()
    window.hide()
    window.show()
    requests.clear()
    screen.logicalDotsPerInchChanged.emit(120.0)
    assert requests == [(120.0,)]
