"""Check native line-box geometry, literal text and modal backdrop behavior.
These tests supplement screenshot comparison without substituting for live client acceptance.
"""

import pytest
from PySide6.QtCore import QEvent, Qt
from PySide6.QtWidgets import QApplication, QVBoxLayout, QWidget

from astral_client import theme
from astral_client.surface_backdrop import SurfaceBackdrop
from astral_client.typography import Paragraph


@pytest.mark.parametrize("alignment", [Qt.AlignmentFlag.AlignTop, Qt.AlignmentFlag.AlignVCenter,
                                      Qt.AlignmentFlag.AlignBottom])
def test_paragraph_wraps_literal_text_in_fixed_line_boxes(qapp, alignment):
    theme.configure_fonts(qapp)
    text = "<b>Literal & safe</b> " * 8
    paragraph = Paragraph(text, 18)
    paragraph.setAlignment(alignment)
    paragraph.setStyleSheet("color:#F3F4F6;font-size:12px;")
    paragraph.resize(180, 240)
    paragraph.show()
    QApplication.processEvents()
    layout, height = paragraph._text_layout(180)
    assert paragraph.textFormat() == Qt.TextFormat.PlainText
    assert paragraph.text() == text
    assert layout.lineCount() > 1
    assert height == layout.lineCount() * 18
    assert paragraph.heightForWidth(180) == height
    assert paragraph.heightForWidth(90) > height
    assert paragraph.sizeHint().height() >= 18
    assert paragraph.minimumSizeHint().height() == 18
    assert not paragraph.grab().isNull()
    paragraph.setText("")
    assert paragraph.heightForWidth(0) == 18
    paragraph.close()
    paragraph.deleteLater()
    QApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)


def test_surface_backdrop_retains_no_disk_capture_and_refreshes_geometry(qapp):
    parent = QWidget()
    parent.resize(320, 240)
    layout = QVBoxLayout(parent)
    layout.addWidget(Paragraph("Behind the dialog", 21))
    backdrop = SurfaceBackdrop(parent)
    backdrop.refresh()
    assert backdrop._image.pixmap().isNull()
    parent.show()
    QApplication.processEvents()
    backdrop.setGeometry(parent.rect())
    backdrop.refresh()
    assert not backdrop._image.pixmap().isNull()
    assert not backdrop.isVisible()
    backdrop.show()
    backdrop.raise_()
    backdrop.refresh()
    assert backdrop.isVisible()
    parent.resize(390, 300)
    backdrop.setGeometry(parent.rect())
    QApplication.processEvents()
    assert backdrop._image.geometry() == parent.rect()
    assert backdrop._tint.geometry() == parent.rect()
    assert backdrop._image.pixmap().size() == parent.grab().size()
    assert backdrop._image.graphicsEffect().blurRadius() == 6
    assert not backdrop.grab().isNull()
    backdrop.hide()
    assert not backdrop.isVisible()
    assert backdrop._image.pixmap().isNull()
    assert not backdrop._refresh_timer.isActive()
    parent.close()
    parent.deleteLater()
    QApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)


def test_backdrop_without_parent_is_inert(qapp):
    backdrop = SurfaceBackdrop(None)
    backdrop.refresh()
    assert backdrop._image.pixmap().isNull()
    backdrop.deleteLater()
    QApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)


@pytest.mark.parametrize("separator", ["\n", "\r\n", "\r"])
def test_paragraph_preserves_explicit_server_line_breaks(qapp, separator):
    text = f"First line{separator}Second line"
    paragraph = Paragraph(text, 18)
    assert paragraph._text_layout(400)[0].lineCount() == 2
    assert paragraph.heightForWidth(400) == 36
    assert paragraph.text() == text
    paragraph.deleteLater()
    QApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)


def test_backdrop_refreshes_theme_and_underlying_surface_after_restyle(qapp):
    original = dict(theme.PALETTE)
    parent = QWidget()
    parent.resize(160, 100)
    parent.setStyleSheet("background:#FF0000;")
    backdrop = SurfaceBackdrop(parent)
    backdrop.setGeometry(parent.rect())
    backdrop.schedule_refresh()
    assert not backdrop._refresh_timer.isActive()
    parent.show()
    backdrop.show()
    QApplication.processEvents()
    try:
        assert backdrop._image.pixmap().toImage().pixelColor(80, 50).name() == "#ff0000"
        parent.setStyleSheet("background:#0000FF;")
        theme.apply_theme("daylight")
        backdrop.schedule_refresh()
        QApplication.processEvents()
        assert backdrop._image.pixmap().toImage().pixelColor(80, 50).name() == "#0000ff"
        assert theme._rgba(theme.BG, 0.72) in backdrop._tint.styleSheet()
        assert not backdrop._refresh_timer.isActive()
    finally:
        theme.apply_theme({"colors": original})
        parent.close()
        parent.deleteLater()
        QApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
