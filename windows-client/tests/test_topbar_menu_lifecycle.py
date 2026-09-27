"""Verify native menu heading lifetime and dispatch during repeated server model refreshes.
The checks retain visible, noninteractive headings without owning custom header widgets.
"""

import pytest
from PySide6.QtCore import QEvent, Qt
from PySide6.QtGui import QFontMetrics
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QLabel, QWidgetAction

from astral_client.app import TopBar, configure


@pytest.fixture
def topbar(qapp):
    stylesheet, font = qapp.styleSheet(), qapp.font()
    loaded = qapp.property("astralOpenSansLoaded")
    configure(qapp)
    opened, local, signed_out = [], [], []
    bar = TopBar("user", lambda: None, lambda: None,
                 lambda surface, label: opened.append((surface, label)),
                 lambda: signed_out.append(True),
                 local_items=[("Agents & tools", lambda: local.append(True))])
    bar.show()
    yield bar, opened, local, signed_out
    bar.close()
    bar.deleteLater()
    QApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
    qapp.setStyleSheet(stylesheet)
    qapp.setFont(font)
    qapp.setProperty("astralOpenSansLoaded", loaded)


def model(label="Account & access", surface="agents"):
    return {"menu": [{"label": label, "items": [
        {"label": "Agents & permissions", "surface": surface}]}],
        "signout": {"label": "Leave session", "action": "logout"}}


def test_repeated_refresh_keeps_headings_native_visible_and_noninteractive(topbar, qapp):
    bar, opened, local, signed_out = topbar
    stylesheet = qapp.styleSheet()
    for index in range(80):
        bar.set_menu_model(model(surface=f"surface-{index}"))
        qapp.setStyleSheet(stylesheet)
        QApplication.processEvents()
        actions = bar._menu.actions()
        headers = [action for action in actions if not action.isEnabled()]
        assert [action.text() for action in headers] == ["ACCOUNT && ACCESS", "THIS PC"]
        assert bar._menu.findChildren(QLabel) == []
        assert not any(isinstance(action, QWidgetAction) for action in actions)
        for heading in headers:
            assert not isinstance(heading, QWidgetAction)
            assert not heading.isSeparator()
            assert bar._menu.actionGeometry(heading).height() >= QFontMetrics(heading.font()).height()
            heading.trigger()
        assert opened == local == signed_out == []
    next(action for action in actions if action.text() == "Agents && permissions").trigger()
    next(action for action in actions if action.text() == "Agents && tools").trigger()
    assert opened == [("surface-79", "Agents & permissions")]
    assert local == [True]


@pytest.mark.parametrize("activation", ["mouse", "keyboard"])
def test_blank_heading_keeps_items_and_signout_uses_existing_callback(topbar, activation):
    bar, opened, local, signed_out = topbar
    bar.set_menu_model(model(label="  "))
    headers = [action for action in bar._menu.actions() if not action.isEnabled()]
    assert [action.text() for action in headers] == ["THIS PC"]
    assert any(action.text() == "Agents && permissions" for action in bar._menu.actions())
    bar._menu.popup(bar.mapToGlobal(bar.rect().bottomLeft()))
    QApplication.processEvents()
    signout = bar._menu.actions()[-1]
    assert signout.text() == "Leave session"
    if activation == "mouse":
        QTest.mouseClick(bar._menu, Qt.MouseButton.LeftButton,
                         pos=bar._menu.actionGeometry(signout).center())
    else:
        bar._menu.setActiveAction(signout)
        QTest.keyClick(bar._menu, Qt.Key.Key_Return)
    assert signed_out == [True]
    assert opened == local == []
    assert not bar._menu.isVisible()
