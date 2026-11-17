# The only window the Windows client opens while it waits for its kernel port.
# main.py reaches it through app.main(); it names no sign-in and makes no network request.

from __future__ import annotations

import sys
from typing import Optional

from PySide6.QtCore import Qt
from PySide6.QtWidgets import QApplication, QLabel, QMainWindow, QVBoxLayout, QWidget

TEXT = "Astral for Windows is not available yet. Use the Mac or iPhone app."
OBJECT_NAME = "not-available-yet"


class NotAvailableWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("AstralDeep")
        self.setMinimumSize(480, 240)
        body = QWidget(self)
        layout = QVBoxLayout(body)
        label = QLabel(TEXT, body)
        label.setObjectName(OBJECT_NAME)
        label.setWordWrap(True)
        label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        label.setAccessibleName(TEXT)
        layout.addWidget(label)
        self.setCentralWidget(body)


def run(argv: Optional[list[str]] = None, *, exec_app: bool = True) -> int:
    app = QApplication.instance() or QApplication(sys.argv if argv is None else argv)
    window = NotAvailableWindow()
    window.show()
    if not exec_app:
        return 0
    return int(app.exec())
