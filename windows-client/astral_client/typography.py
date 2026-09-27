"""Lay out plain native text using the shared web typography's explicit line boxes.
Console widgets use this QLabel adapter to keep wrapping, accessibility and baseline spacing consistent.
"""

import math

from PySide6.QtCore import QPointF, QSize, Qt
from PySide6.QtGui import QPainter, QPalette, QTextLayout, QTextOption
from PySide6.QtWidgets import QLabel, QSizePolicy


class Paragraph(QLabel):
    def __init__(self, text, line_height, parent=None):
        super().__init__(text, parent)
        self.line_height = line_height
        self.setTextFormat(Qt.TextFormat.PlainText)
        self.setWordWrap(True)
        self.setSizePolicy(QSizePolicy.Policy.Preferred, QSizePolicy.Policy.Preferred)

    def _text_layout(self, width):
        text = self.text().replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\u2028")
        layout = QTextLayout(text, self.font())
        option = QTextOption()
        option.setWrapMode(QTextOption.WrapMode.WrapAtWordBoundaryOrAnywhere)
        option.setAlignment(self.alignment() & Qt.AlignmentFlag.AlignHorizontal_Mask)
        layout.setTextOption(option)
        layout.beginLayout()
        count = 0
        while True:
            line = layout.createLine()
            if not line.isValid():
                break
            line.setLineWidth(max(1, width))
            line.setPosition(QPointF(0, count * self.line_height + (self.line_height - line.height()) / 2))
            count += 1
        layout.endLayout()
        return layout, max(1, count) * self.line_height

    def heightForWidth(self, width):
        return math.ceil(self._text_layout(width)[1])

    def sizeHint(self):
        size = super().sizeHint()
        return QSize(size.width(), self.heightForWidth(size.width()))

    def minimumSizeHint(self):
        return QSize(0, math.ceil(self.line_height))

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setPen(self.palette().color(QPalette.ColorRole.WindowText))
        layout, height = self._text_layout(self.width())
        offset = 0
        if self.alignment() & Qt.AlignmentFlag.AlignVCenter:
            offset = max(0, (self.height() - height) / 2)
        elif self.alignment() & Qt.AlignmentFlag.AlignBottom:
            offset = max(0, self.height() - height)
        layout.draw(painter, QPointF(0, offset))
