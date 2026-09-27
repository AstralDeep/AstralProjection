"""Paint a dimmed, blurred copy of the native shell behind server-owned modal surfaces.
Snapshots remain in memory and refresh after parent geometry changes.
"""

from PySide6.QtCore import Qt, QTimer
from PySide6.QtWidgets import QGraphicsBlurEffect, QLabel, QWidget

from . import theme as T


class SurfaceBackdrop(QWidget):
    def __init__(self, parent):
        super().__init__(parent)
        self.setObjectName("surfaceBackdrop")
        self._image = QLabel(self)
        self._image.setScaledContents(True)
        effect = QGraphicsBlurEffect(self._image)
        effect.setBlurRadius(6)
        effect.setBlurHints(QGraphicsBlurEffect.BlurHint.QualityHint)
        self._image.setGraphicsEffect(effect)
        self._tint = QWidget(self)
        self._tint.setObjectName("surfaceBackdropTint")
        self._tint.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self._refresh_timer = QTimer(self)
        self._refresh_timer.setSingleShot(True)
        self._refresh_timer.timeout.connect(self.refresh)
        self._refreshing = False
        self.hide()

    def refresh(self):
        parent = self.parentWidget()
        if parent is None or not parent.isVisible():
            return
        visible = self.isVisible()
        self._refreshing = True
        self.hide()
        self._image.setPixmap(parent.grab())
        self._tint.setStyleSheet(f"#surfaceBackdropTint{{background:{T._rgba(T.BG, 0.72)};}}")
        if visible:
            self.show()
        self._refreshing = False

    def schedule_refresh(self):
        if self.isVisible():
            self._refresh_timer.start(0)

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._image.setGeometry(self.rect())
        self._tint.setGeometry(self.rect())
        if self.isVisible():
            self._refresh_timer.start(0)

    def showEvent(self, event):
        super().showEvent(event)
        if not self._refreshing:
            self._refresh_timer.start(0)

    def hideEvent(self, event):
        if not self._refreshing:
            self._refresh_timer.stop()
            self._image.clear()
        super().hideEvent(event)
