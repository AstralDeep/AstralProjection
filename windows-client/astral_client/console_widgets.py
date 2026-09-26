"""Renders the server-owned console catalog and ROTE geometry as native Qt widgets.
The application supplies authenticated actions and retains one canvas through result presentation changes.
"""

from __future__ import annotations

import math
import re
import sys
from pathlib import Path

from PySide6.QtCore import QEvent, QPointF, QRect, QSize, Qt, Signal, QTimer
from PySide6.QtGui import QKeySequence, QPalette, QPixmap, QShortcut, QTextLayout, QTextOption
from PySide6.QtWidgets import (
    QApplication, QBoxLayout, QFrame, QGridLayout, QHBoxLayout, QLabel, QLineEdit,
    QMenu, QPlainTextEdit, QPushButton, QScrollArea, QSizePolicy, QStyle, QStyleOptionButton,
    QStylePainter, QVBoxLayout, QWidget,
)

from . import theme as T
from . import icons
from .composites import FlowLayout


def clear_layout(layout):
    while layout.count():
        item = layout.takeAt(0)
        widget = item.widget()
        if widget is not None:
            widget.setEnabled(False)
            widget.hide()
            widget.setParent(None)
            widget.deleteLater()
        elif item.layout() is not None:
            clear_layout(item.layout())


def label(text, *, heading=False, size=None, weight=None):
    widget = QLabel(text)
    widget.setProperty("consoleTone", "text" if heading else "muted")
    widget.setTextFormat(Qt.TextFormat.PlainText)
    widget.setWordWrap(True)
    widget.setStyleSheet(
        f"color:{T.TEXT if heading else T.MUTED};font-size:{size or (18 if heading else 12)}px;"
        f"font-weight:{weight or (600 if heading else 400)};background:transparent;"
    )
    return widget


def shared_image(name, height):
    root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[2]))
    path = root / ("assets/img" if hasattr(sys, "_MEIPASS") else "backend/webrender/static/img") / name
    widget = QLabel()
    pixmap = QPixmap(str(path))
    if not pixmap.isNull():
        scaled = pixmap.scaledToHeight(height * 2, Qt.TransformationMode.SmoothTransformation)
        scaled.setDevicePixelRatio(2)
        widget.setPixmap(scaled)
        widget.setFixedSize(round(scaled.width() / 2), height)
    widget.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
    return widget


def button(text, callback, *, name=None):
    widget = QPushButton(text.replace("&", "&&"))
    widget.setAccessibleName(name or text)
    widget.setToolTip(name or text)
    widget.setCursor(Qt.CursorShape.PointingHandCursor)
    widget.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
    widget.clicked.connect(callback)
    return widget


class AgentDescription(QLabel):
    def __init__(self, text):
        super().__init__(text)
        self._source = text
        self.setAccessibleName(text)
        self.setTextFormat(Qt.TextFormat.PlainText)
        self.setWordWrap(True)
        self.setProperty("consoleTone", "muted")
        self.setStyleSheet(f"font-size:12px;color:{T.MUTED};background:transparent;")
        self.setFixedHeight(34)

    def resizeEvent(self, event):
        super().resizeEvent(event)
        words = self._source.split()
        first = []
        metrics = self.fontMetrics()
        while words and metrics.horizontalAdvance(" ".join([*first, words[0]])) <= self.width():
            first.append(words.pop(0))
        if not first and words:
            first.append(metrics.elidedText(words.pop(0), Qt.TextElideMode.ElideRight, self.width()))
        second = metrics.elidedText(" ".join(words), Qt.TextElideMode.ElideRight, self.width())
        self.setText(" ".join(first) + ("\n" + second if second else ""))


class WrappedBanner(QPushButton):
    geometry_changed = Signal()

    def __init__(self):
        super().__init__()
        policy = QSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        policy.setHeightForWidth(True)
        self.setSizePolicy(policy)
        self._geometry_timer = QTimer(self)
        self._geometry_timer.setSingleShot(True)
        self._geometry_timer.timeout.connect(self._refresh_geometry)

    def setText(self, text):
        super().setText(text)
        self._queue_geometry_update()

    def _queue_geometry_update(self):
        timer = getattr(self, "_geometry_timer", None)
        if timer is not None:
            timer.start(0)

    def _refresh_geometry(self):
        self.updateGeometry()
        self.update()
        self.geometry_changed.emit()

    def changeEvent(self, event):
        super().changeEvent(event)
        if event.type() in (QEvent.Type.FontChange, QEvent.Type.StyleChange, QEvent.Type.LayoutDirectionChange):
            self._queue_geometry_update()

    def _text_layout(self, width):
        layout = QTextLayout(self.text(), self.font())
        option = QTextOption()
        option.setWrapMode(QTextOption.WrapMode.WrapAtWordBoundaryOrAnywhere)
        option.setTextDirection(self.layoutDirection())
        option.setAlignment(QStyle.visualAlignment(self.layoutDirection(), Qt.AlignmentFlag.AlignLeading))
        layout.setTextOption(option)
        layout.beginLayout()
        height = 0.0
        while True:
            line = layout.createLine()
            if not line.isValid():
                break
            line.setLineWidth(max(1, width))
            line.setPosition(QPointF(0, height))
            height += line.height()
        layout.endLayout()
        return layout, height

    def hasHeightForWidth(self):
        return True

    def heightForWidth(self, width):
        self.ensurePolished()
        option = QStyleOptionButton()
        self.initStyleOption(option)
        option.rect = QRect(0, 0, max(1, width), 100)
        content = self.style().subElementRect(QStyle.SubElement.SE_PushButtonContents, option, self)
        _, height = self._text_layout(content.width())
        return math.ceil(height + option.rect.height() - content.height())

    def sizeHint(self):
        return QSize(0, self.heightForWidth(self.width()))

    def minimumSizeHint(self):
        return QSize(0, self.fontMetrics().height())

    def paintEvent(self, event):
        option = QStyleOptionButton()
        self.initStyleOption(option)
        option.text = ""
        painter = QStylePainter(self)
        painter.drawControl(QStyle.ControlElement.CE_PushButton, option)
        content = self.style().subElementRect(QStyle.SubElement.SE_PushButtonContents, option, self)
        layout, height = self._text_layout(content.width())
        painter.setPen(option.palette.color(QPalette.ColorRole.ButtonText))
        layout.draw(painter, QPointF(content.left(), content.top() + max(0, (content.height() - height) / 2)))


class BannerViewport(QScrollArea):
    def __init__(self, button):
        super().__init__()
        self.button = button
        self._last_text = None
        self._refresh_timer = QTimer(self)
        self._refresh_timer.setSingleShot(True)
        self._refresh_timer.timeout.connect(self._refresh)
        visible = not button.isHidden()
        self.setWidgetResizable(True)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setFrameShape(QFrame.Shape.NoFrame)
        self.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        self.setWidget(button)
        button.setVisible(visible)
        self.setVisible(visible)
        button.installEventFilter(self)
        button.geometry_changed.connect(lambda: self._refresh_timer.start(0))

    def _refresh(self):
        height = self.button.heightForWidth(self.viewport().width())
        self.button.setMinimumHeight(height)
        limit = max(self.button.minimumSizeHint().height(), self.window().height() // 3)
        self.setFixedHeight(min(height, limit))
        if self._last_text != self.button.text():
            self._last_text = self.button.text()
            self.verticalScrollBar().setValue(0)

    def eventFilter(self, watched, event):
        if watched is self.button and event.type() in (QEvent.Type.ShowToParent, QEvent.Type.HideToParent):
            self.setVisible(not self.button.isHidden())
            self._refresh_timer.start(0)
        elif watched is self.button and event.type() == QEvent.Type.KeyPress and event.key() in (
            Qt.Key.Key_PageUp, Qt.Key.Key_PageDown, Qt.Key.Key_Home, Qt.Key.Key_End,
        ):
            self.verticalScrollBar().keyPressEvent(event)
            return event.isAccepted()
        elif watched is self.window() and event.type() == QEvent.Type.Resize:
            self._refresh_timer.start(0)
        return super().eventFilter(watched, event)

    def showEvent(self, event):
        super().showEvent(event)
        if self.window() is not self:
            self.window().installEventFilter(self)
        self._refresh_timer.start(0)

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._refresh_timer.start(0)


class AttachmentTray(QScrollArea):
    def __init__(self):
        super().__init__()
        self.setWidgetResizable(True)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setFrameShape(QFrame.Shape.NoFrame)
        self.setAccessibleName("Staged attachments")
        self.body = QWidget()
        self.flow = FlowLayout(self.body)
        self.flow.setSpacing(6)
        self.setWidget(self.body)
        QApplication.instance().focusChanged.connect(self._reveal_focus)

    def _reveal_focus(self, previous, current):
        if current is not None and self.body.isAncestorOf(current):
            self.ensureWidgetVisible(current, 0, 0)

    def refresh(self):
        height = self.flow.heightForWidth(self.viewport().width())
        if self.body.minimumHeight() != height:
            self.body.setMinimumHeight(height)
        if self.height() != min(160, height):
            self.setFixedHeight(min(160, height))

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.refresh()


class ComposerEdit(QPlainTextEdit):
    returnPressed = Signal()

    def __init__(self):
        super().__init__()
        self.setMinimumHeight(44)
        self.setMaximumHeight(144)
        self.textChanged.connect(self._fit_text)
        self.setTabChangesFocus(True)
        self.document().setDocumentMargin(0)
        self._completer = None

    def _fit_text(self):
        lines = max(1, self.document().size().height())
        minimum = self.property("consoleMinimumHeight") or 44
        self.setFixedHeight(min(144, max(minimum, round(lines * self.fontMetrics().lineSpacing() + 22))))

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._fit_text()

    def text(self):
        return self.toPlainText()

    def setText(self, text):
        self.setPlainText(text)

    def setCompleter(self, completer):
        self._completer = completer
        completer.setWidget(self)
        completer.activated[str].connect(self.setText)

    def keyPressEvent(self, event):
        if self._completer is not None and self._completer.popup().isVisible():
            if event.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter, Qt.Key.Key_Escape, Qt.Key.Key_Tab):
                event.ignore()
                return
        if event.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter) and not event.modifiers() & Qt.KeyboardModifier.ShiftModifier:
            self.returnPressed.emit()
            event.accept()
            return
        super().keyPressEvent(event)
        text = self.toPlainText()
        if self._completer is not None:
            if text.startswith("/") and not any(character.isspace() for character in text):
                self._completer.setCompletionPrefix(text)
                self._completer.complete(self.cursorRect())
            else:
                self._completer.popup().hide()


class ResponsiveComposer(QWidget):
    def __init__(self):
        super().__init__()
        self._row = None
        self.voice_stacked = False
        self._reflow_timer = QTimer(self)
        self._reflow_timer.setSingleShot(True)
        self._reflow_timer.timeout.connect(self.reflow)

    def configure_controls(self, row, editor, voice, controls):
        self._row = row
        self._editor = editor
        self._voice = voice
        self._inline_index = row.indexOf(voice)
        self._fixed_controls = controls
        row.setAlignment(voice, Qt.AlignmentFlag.AlignVCenter)
        voice.geometry_changed.connect(self.queue_reflow)
        self.queue_reflow()

    def set_control_minimum(self, minimum):
        if self._row is None:
            return
        self._voice.set_control_minimum(minimum)
        self._voice.setProperty("consoleControlWidth", 32 if minimum >= 44 else 44)
        for voice_control in self._voice.findChildren(QPushButton):
            self._voice._size_control(voice_control)
        for control in self._fixed_controls:
            send = control is self._fixed_controls[-1]
            width = 44 if send or minimum < 44 else 32
            geometry = f"min-width:{width}px;max-width:{width}px;min-height:44px;max-height:44px;padding:0;border:0;"
            if not send:
                control.setStyleSheet(geometry + "background:transparent;")
            else:
                control.setStyleSheet(geometry + f"border-radius:10px;background:{T.GRAD};")
            control.setFixedSize(width, 44)
        self._row.setSpacing(2 if minimum >= 44 else 6)
        self._editor.setStyleSheet(f"font-size:{16 if minimum >= 44 else 14}px;padding:10px 12px;background:{T._rgba(T.SURFACE_2,0.9)};")
        self._editor.setProperty("consoleMinimumHeight", 44 if minimum >= 44 else 50)
        self._editor._fit_text()
        self.queue_reflow()

    def queue_reflow(self):
        self._reflow_timer.start(0)

    def reflow(self):
        if self._row is None:
            return
        margins = self.layout().contentsMargins()
        available = self.width() - margins.left() - margins.right()
        voice_width = self._voice.inline_width()
        fixed_width = sum(max(control.minimumWidth(), control.sizeHint().width())
                          for control in self._fixed_controls)
        editor_width = max(80, self._editor.minimumSizeHint().width())
        needed = editor_width + fixed_width + voice_width + self._row.spacing() * len(self._fixed_controls + (self._voice,))
        stacked = needed > available
        if stacked != self.voice_stacked:
            self.voice_stacked = stacked
            self._row.removeWidget(self._voice)
            self.layout().removeWidget(self._voice)
            if stacked:
                self.layout().addWidget(self._voice)
            else:
                self._row.insertWidget(self._inline_index, self._voice, 0, Qt.AlignmentFlag.AlignVCenter)
        self._voice.setMaximumWidth(16777215 if stacked else max(1, voice_width))
        self._voice.updateGeometry()
        self.layout().invalidate()

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.queue_reflow()


class ResultPanel(QFrame):
    fullscreen_requested = Signal(bool)
    workspace_requested = Signal(str)

    def __init__(self, canvas):
        super().__init__()
        self.setObjectName("consoleResult")
        self.canvas = canvas
        self.fullscreen = False
        self.collapsed = False
        self.labels = {}
        self.presentation = {}
        self.preview_height = 380
        self.outer_layout = QVBoxLayout(self)
        self.outer_layout.setContentsMargins(0, 0, 0, 0)
        self.outer_layout.setSpacing(14)
        self.agent_header = QWidget()
        agent_layout = QHBoxLayout(self.agent_header)
        agent_layout.setContentsMargins(4, 0, 0, 0)
        agent_layout.setSpacing(10)
        self.agent_icon = label("✦", heading=True, size=14)
        self.agent_icon.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.agent_icon.setFixedSize(32, 32)
        agent_layout.addWidget(self.agent_icon)
        identity = QVBoxLayout()
        identity.setSpacing(2)
        self.agent_name = label("", heading=True, size=14)
        self.role = label("")
        identity.addWidget(self.agent_name)
        identity.addWidget(self.role)
        agent_layout.addLayout(identity, 1)
        self.outer_layout.addWidget(self.agent_header)
        self.card = QFrame()
        self.card.setObjectName("consoleResultCard")
        self.outer_layout.addWidget(self.card, 1)
        self._layout = QVBoxLayout(self.card)
        self._layout.setContentsMargins(0, 0, 0, 0)
        self._layout.setSpacing(0)
        self.header_widget = QFrame()
        self.header_widget.setObjectName("consoleResultHeader")
        self.header = QBoxLayout(QBoxLayout.Direction.LeftToRight, self.header_widget)
        self.header.setContentsMargins(16, 10, 16, 10)
        self.header.setSpacing(10)
        self.header_actions = QHBoxLayout()
        self.header_actions.setSpacing(8)
        self._header_reflow_timer = QTimer(self)
        self._header_reflow_timer.setSingleShot(True)
        self._header_reflow_timer.timeout.connect(self._reflow_header)
        self.title = label("", heading=True, size=14)
        self.title.setWordWrap(False)
        self.title.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        self.fullscreen_icon = label("✦", heading=True, size=14)
        self.fullscreen_icon.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.fullscreen_icon.setFixedSize(36, 36)
        self.header.addWidget(self.fullscreen_icon)
        self.result_heading = QVBoxLayout()
        self.result_heading.setSpacing(2)
        self.result_heading.addWidget(self.title)
        self.fullscreen_role = label("", size=12)
        self.result_heading.addWidget(self.fullscreen_role)
        self.header.addLayout(self.result_heading, 1)
        self.turn_badge = label("")
        self.header.addWidget(self.turn_badge)
        self.workspace_layout = QHBoxLayout()
        self.workspace_layout.setSpacing(8)
        self.collapse_button = button("", self.toggle_collapsed)
        self.fullscreen_button = button("", self.toggle_fullscreen)
        self.header_actions.addWidget(self.collapse_button)
        self.header_actions.addWidget(self.fullscreen_button)
        self.header_actions.addLayout(self.workspace_layout)
        self._fullscreen_action_last = False
        self.header.addLayout(self.header_actions)
        self._layout.addWidget(self.header_widget)
        self._layout.addWidget(canvas, 1)
        self.preview_button = button("", self.toggle_fullscreen)
        self.preview_button.setParent(canvas)
        self.preview_cover = button("", self.toggle_fullscreen)
        self.preview_cover.setParent(canvas)
        self.preview_cover.setStyleSheet("background:transparent;border:0;")
        self.preview_cover.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.preview_fade = QFrame(canvas)
        self.preview_fade.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        canvas.installEventFilter(self)
        self.restyle()

    def restyle(self):
        self.card.setStyleSheet(
            f"#consoleResultCard{{background:{T.SURFACE_2};border:{0 if self.fullscreen else 1}px solid {T._rgba(T.TEXT,0.16)};border-radius:{0 if self.fullscreen else 10}px;}}"
            f"#consoleResultHeader{{background:{T._rgba(T.TEXT,0.025)};border-bottom:1px solid {T._rgba(T.TEXT,0.12)};}}")
        self.agent_icon.setStyleSheet(f"color:{T.ACCENT};background:{T._rgba(T.PRIMARY,0.18)};border:1px solid {T._rgba(T.PRIMARY,0.38)};border-radius:8px;")
        self.fullscreen_icon.setStyleSheet(self.agent_icon.styleSheet())
        self.fullscreen_role.setStyleSheet(f"color:{T.ACCENT};font-size:12px;")
        self.turn_badge.setStyleSheet(f"color:{T.MUTED};font-size:11px;padding:2px 7px;border-radius:6px;border:1px solid {T.BORDER};background:{T._rgba(T.TEXT,0.04)};")
        self.preview_button.setStyleSheet(f"font-size:12px;font-weight:600;background:{T.SURFACE_2};border:1px solid {T._rgba(T.TEXT,0.24)};border-radius:6px;padding:8px 18px;")
        self.preview_fade.setStyleSheet(f"background:qlineargradient(x1:0,y1:0,x2:0,y2:1,stop:0 {T._rgba(T.SURFACE_2,0)},stop:0.55 {T._rgba(T.SURFACE_2,0.88)},stop:1 {T._rgba(T.SURFACE_2,0.98)});")

    def configure(self, labels, presentation):
        self.labels = labels
        self.presentation = presentation
        agent = labels["result_default_agent"]
        self.title.setText(labels["result_title"].replace("{agent}", agent))
        self.role.setText(labels["result_agent_role"])
        self.fullscreen_role.setText(labels["result_agent_role"])
        self.agent_name.setText(agent)
        self.preview_height = round(presentation["result_body_max_height"])
        self.preview_button.setText(labels["result_preview_action"])
        self.preview_button.setAccessibleName(labels["result_preview_action"])
        self.preview_cover.setAccessibleName(labels["result_preview_action"])
        self.apply_state()

    def set_metadata(self, agent, turns):
        if not self.labels:
            return
        self.title.setText(self.labels["result_title"].replace("{agent}", agent or self.labels["result_default_agent"]))
        self.agent_name.setText(agent or self.labels["result_default_agent"])
        self.turn_badge.setText(f"{self.labels['turn_singular'].capitalize()} {turns}")
        self.turn_badge.setVisible(turns > 0)
        self._header_reflow_timer.start(0)

    def set_workspace_actions(self, actions):
        clear_layout(self.workspace_layout)
        for action in actions:
            control = button(action["label"], lambda checked=False, operation=action["operation"]: self.workspace_requested.emit(operation))
            control.setProperty("workspaceOperation", action["operation"])
            control.setObjectName("iconGhost")
            icons.apply(control, action["icon"], T.MUTED, T.TEXT)
            self.workspace_layout.addWidget(control)
        self._header_reflow_timer.start(0)

    def toggle_collapsed(self):
        self.collapsed = not self.collapsed
        self.apply_state()

    def toggle_fullscreen(self):
        if not self.fullscreen:
            opener = self.sender()
            if opener not in (self.preview_button, self.fullscreen_button):
                opener = self.fullscreen_button
            opener.setFocus()
        self.fullscreen_requested.emit(not self.fullscreen)

    def apply_state(self):
        if not self.labels:
            return
        icons.apply(self.collapse_button, "chevron_right" if self.collapsed else "chevron_down", T.MUTED, T.TEXT, 14)
        self.collapse_button.setAccessibleName(self.labels["expand" if self.collapsed else "collapse"])
        self.collapse_button.setToolTip(self.collapse_button.accessibleName())
        self.collapse_button.setProperty("expanded", not self.collapsed)
        self.fullscreen_button.setText(self.labels["exit_fullscreen" if self.fullscreen else "fullscreen"])
        self.fullscreen_button.setAccessibleName(self.fullscreen_button.text())
        self.fullscreen_button.setToolTip(self.fullscreen_button.text())
        icons.apply(self.fullscreen_button, "exit_fullscreen" if self.fullscreen else "fullscreen", T.MUTED, T.TEXT)
        self.agent_header.setVisible(not self.fullscreen)
        self.collapse_button.setVisible(not self.fullscreen)
        self.turn_badge.setVisible(not self.fullscreen and bool(self.turn_badge.text()))
        self.canvas.setVisible(not self.collapsed)
        self.preview_button.setVisible(not self.fullscreen and not self.collapsed)
        self.preview_cover.setVisible(not self.fullscreen and not self.collapsed)
        self.preview_fade.setVisible(not self.fullscreen and not self.collapsed)
        self.canvas.setMinimumHeight(0 if self.collapsed else 120)
        self.canvas.setMaximumHeight(16777215 if self.fullscreen else self.preview_height)
        self.canvas.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded if self.fullscreen else Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.canvas.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setStyleSheet(f"#consoleResult{{background:{T.SURFACE_2 if self.fullscreen else 'transparent'};border:0;}}")
        self.restyle()
        self._place_preview()
        self._header_reflow_timer.start(0)

    def _place_preview(self):
        self.preview_cover.setGeometry(self.canvas.rect())
        self.preview_cover.raise_()
        self.preview_fade.setGeometry(0, max(0, self.canvas.height() - 90), self.canvas.width(), 90)
        self.preview_fade.raise_()
        width = min(self.canvas.width() - 24, self.preview_button.sizeHint().width())
        self.preview_button.setGeometry(max(0, (self.canvas.width() - width) // 2), max(0, self.canvas.height() - 52), max(1, width), 38)
        self.preview_button.raise_()

    def eventFilter(self, watched, event):
        if watched is self.canvas and event.type() == QEvent.Type.Resize:
            self._place_preview()
        return super().eventFilter(watched, event)

    def _reflow_header(self):
        compact = self.presentation.get('settings_navigation_axis') == 'horizontal'
        height = 44 if compact else 28
        width = 40 if compact else height
        self.collapse_button.setStyleSheet(f"min-width:{width}px;max-width:{width}px;min-height:{height}px;max-height:{height}px;padding:0;border-radius:6px;background:{T._rgba(T.TEXT,0.05)};")
        self.fullscreen_button.setStyleSheet(f"font-size:12px;font-weight:700;padding:5px 12px;border-radius:6px;background:{T._rgba(T.TEXT,0.04)};")
        self.fullscreen_button.setText('' if compact else self.labels.get('exit_fullscreen' if self.fullscreen else 'fullscreen', ''))
        if self.fullscreen:
            self.fullscreen_button.setStyleSheet(f"font-size:13px;font-weight:700;padding:8px 14px;border:1px solid {T._rgba(T.VARIANT_COLORS['error'][0],0.35)};border-radius:8px;color:{T.VARIANT_COLORS['error'][0]};background:{T._rgba(T.VARIANT_COLORS['error'][0],0.1)};")
        self.fullscreen_button.setMinimumHeight(height)
        self.fullscreen_button.setMaximumWidth(36 if compact else 16777215)
        self.turn_badge.setVisible(not compact and not self.fullscreen and bool(self.turn_badge.text()))
        self.header_actions.setSpacing(4 if compact else 8)
        self.fullscreen_icon.setVisible(self.fullscreen and not compact)
        self.fullscreen_role.setVisible(self.fullscreen and not compact)
        margin = 12 if compact else 32 if self.fullscreen else 16
        self.header.setContentsMargins(margin, 10 if compact else 16 if self.fullscreen else 10, margin, 10 if compact else 16 if self.fullscreen else 10)
        self.title.setStyleSheet(f"color:{T.TEXT};font-size:{14 if compact or not self.fullscreen else 16}px;font-weight:600;")
        self.canvas._lay.setContentsMargins(*(16, 16, 16, 16) if compact or not self.fullscreen else (36, 28, 36, 28))
        if self._fullscreen_action_last != self.fullscreen:
            self.header_actions.removeWidget(self.fullscreen_button)
            self.header_actions.insertWidget(self.header_actions.count() if self.fullscreen else 1, self.fullscreen_button)
            self._fullscreen_action_last = self.fullscreen
        for index in range(self.workspace_layout.count()):
            control = self.workspace_layout.itemAt(index).widget()
            width = 38 if compact else height
            control.setStyleSheet(f"min-width:{width}px;max-width:{width}px;min-height:{height}px;max-height:{height}px;padding:0;background:transparent;border:0;")

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.preview_cover.setGeometry(self.canvas.rect())
        self._header_reflow_timer.start(0)


class ConsoleShell(QWidget):
    scenario_requested = Signal(str, bool)
    surface_requested = Signal(str, str, dict)
    chat_requested = Signal(str)
    history_requested = Signal()
    new_chat_requested = Signal()
    signout_requested = Signal()
    background_changed = Signal(bool)
    clear_selection_requested = Signal()

    def __init__(self, rail, canvas, composer, chips, status, parent=None):
        super().__init__(parent)
        self.setObjectName("consoleShell")
        self.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Expanding)
        self.model = None
        self.menu = None
        self.presentation = None
        self.category = None
        self.drawer_open = False
        self.background = False
        self._history = []
        self._has_conversation = False
        self._return_focus = None
        self._drawer_focus = None
        self.rail = rail
        self.canvas = canvas
        self.composer = composer
        self.layout_row = QHBoxLayout(self)
        self.layout_row.setContentsMargins(0, 0, 0, 0)
        self.layout_row.setSpacing(0)
        self.sidebar = QFrame()
        self.sidebar.setObjectName("consoleSidebar")
        self.sidebar_layout = QVBoxLayout(self.sidebar)
        self.sidebar_layout.setContentsMargins(22, 22, 22, 22)
        self.sidebar_layout.setSpacing(16)
        self.brand = shared_image("AstralDeep.png", 38)
        self.sidebar_layout.addWidget(self.brand)
        self.brand_divider = QFrame()
        self.brand_divider.setObjectName("consoleDivider")
        self.brand_divider.setFixedHeight(1)
        self.sidebar_layout.addWidget(self.brand_divider)
        self.new_button = button("", self._new_chat)
        self.new_button.setObjectName("consoleNewChat")
        self.history_button = button("", self._toggle_history)
        self.history_button.setObjectName("consoleHistory")
        self.history_button.setCheckable(True)
        history_button_layout = QHBoxLayout(self.history_button)
        history_button_layout.setContentsMargins(0, 0, 6, 0)
        history_button_layout.addStretch(1)
        self.history_chevron = QLabel()
        self.history_chevron.setFixedSize(12, 12)
        self.history_chevron.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        history_button_layout.addWidget(self.history_chevron)
        history_header = QHBoxLayout()
        history_header.addWidget(self.history_button, 1)
        self.history_new_button = button("", self._new_chat)
        self.history_new_button.setObjectName("iconGhost")
        history_header.addWidget(self.history_new_button)
        self.sidebar_layout.addLayout(history_header)
        self.history_scroll = QScrollArea()
        self.history_scroll.setWidgetResizable(True)
        self.history_scroll.setMaximumHeight(220)
        self.history_body = QWidget()
        self.history_layout = QVBoxLayout(self.history_body)
        self.history_layout.setContentsMargins(0, 0, 0, 0)
        self.history_scroll.setWidget(self.history_body)
        self.history_scroll.hide()
        self.sidebar_layout.addWidget(self.history_scroll)
        self.directory_label = label("")
        self.directory_label.setObjectName("consoleDirectoryTitle")
        directory_header = QHBoxLayout()
        directory_header.addWidget(self.directory_label, 1)
        self.directory_count = label("", heading=True, size=12, weight=700)
        self.directory_count.setObjectName("consoleCount")
        directory_header.addWidget(self.directory_count)
        self.sidebar_layout.addLayout(directory_header)
        self.search = QLineEdit()
        self.search.setObjectName("consoleAgentSearch")
        self.search.addAction(icons.icon("search", T.MUTED, T.TEXT), QLineEdit.ActionPosition.LeadingPosition)
        self.search.textChanged.connect(self._render_agents)
        self.sidebar_layout.addWidget(self.search)
        self.agent_scroll = QScrollArea()
        self.agent_scroll.setWidgetResizable(True)
        self.agent_scroll.setStyleSheet("QScrollBar:vertical{width:4px;margin:0;}")
        self.agent_scroll.setViewportMargins(0, 0, -4, 0)
        self.agent_body = QWidget()
        self.agent_layout = QVBoxLayout(self.agent_body)
        self.agent_layout.setContentsMargins(0, 0, 4, 0)
        self.agent_layout.setSpacing(8)
        self.agent_scroll.setWidget(self.agent_body)
        self.sidebar_layout.addWidget(self.agent_scroll, 1)
        self.account_button = button("", lambda: None)
        self.account_button.setObjectName("consoleAccount")
        self.account_button.setFixedHeight(50)
        account_layout = QHBoxLayout(self.account_button)
        account_layout.setContentsMargins(10, 8, 10, 8)
        account_layout.setSpacing(10)
        account_layout.addWidget(shared_image("user-avatar.png", 32))
        account_identity = QVBoxLayout()
        account_identity.setSpacing(0)
        self.account_name = label("", heading=True, size=14)
        self.account_role = label("")
        for item in (self.account_name, self.account_role):
            item.setWordWrap(False)
            item.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
            item.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
            account_identity.addWidget(item)
        account_layout.addLayout(account_identity, 1)
        self.account_gear = QLabel()
        self.account_gear.setPixmap(icons.icon("gear", T.MUTED, T.TEXT, 16).pixmap(16, 16))
        self.history_chevron.setPixmap(icons.icon("chevron_down" if self.history_button.isChecked() else "chevron_right", T.MUTED, T.TEXT, 12).pixmap(12, 12))
        self.account_gear.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        account_layout.addWidget(self.account_gear)
        self.account_menu = QMenu(self.account_button)
        self.account_button.setMenu(self.account_menu)
        self.sidebar_layout.addWidget(self.account_button)
        self.layout_row.addWidget(self.sidebar)
        self.main = QFrame()
        self.main.setObjectName("consoleMain")
        self.main_layout = QVBoxLayout(self.main)
        self.main_layout.setContentsMargins(0, 0, 0, 0)
        self.main_layout.setSpacing(0)
        self.header = QWidget()
        self.header.setObjectName("consoleHeader")
        header_layout = QHBoxLayout(self.header)
        header_layout.setSpacing(12)
        self.drawer_button = button("☰", self.toggle_drawer)
        header_layout.addWidget(self.drawer_button)
        self.heading = button("", self.show_dashboard)
        self.heading.setObjectName("consoleDashboard")
        header_layout.addWidget(self.heading)
        self.turn_count = label("", heading=True, size=13)
        self.turn_count.setObjectName("consoleTurns")
        header_layout.addWidget(self.turn_count)
        header_layout.addStretch(1)
        status.setParent(self.header)
        status.hide()
        header_layout.addWidget(self.new_button)
        self.main_layout.addWidget(self.header)
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QFrame.Shape.NoFrame)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.scroll.setStyleSheet("QScrollBar:vertical{width:6px;margin:0;}")
        self.scroll.setViewportMargins(0, 0, -6, 0)
        self.scroll_body = QWidget()
        self.feed_layout = QVBoxLayout(self.scroll_body)
        self.feed_layout.setSpacing(24)
        self.landing = QWidget()
        landing_layout = QVBoxLayout(self.landing)
        landing_layout.setContentsMargins(0, 0, 0, 0)
        self.title = label("", heading=True)
        self.title.setStyleSheet(f"color:{T.TEXT};font-size:24px;font-weight:800;letter-spacing:-0.48px;")
        self.title.setMinimumHeight(36)
        self.subtitle = label("", size=14)
        landing_layout.setSpacing(0)
        landing_layout.addWidget(self.title)
        landing_layout.addSpacing(4)
        landing_layout.addWidget(self.subtitle)
        landing_layout.addSpacing(14)
        page_divider = QFrame()
        page_divider.setObjectName("consoleDivider")
        page_divider.setFixedHeight(1)
        landing_layout.addWidget(page_divider)
        landing_layout.addSpacing(26)
        scenarios_header = QHBoxLayout()
        scenarios_header.setSpacing(14)
        self.start_here = label("", heading=True, weight=700)
        self.start_here.setWordWrap(False)
        scenarios_header.addWidget(self.start_here, 1)
        self.categories_scroll = QScrollArea()
        self.categories_scroll.setObjectName("consoleCategories")
        self.categories_scroll.setWidgetResizable(True)
        self.categories_scroll.setSizePolicy(QSizePolicy.Policy.Preferred, QSizePolicy.Policy.Fixed)
        self.categories_scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.categories_scroll.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.categories_body = QWidget()
        self.categories_layout = QHBoxLayout(self.categories_body)
        self.categories_layout.setContentsMargins(5, 5, 5, 5)
        self.categories_layout.setSpacing(6)
        self.categories_scroll.setWidget(self.categories_body)
        scenarios_header.addWidget(self.categories_scroll)
        landing_layout.addLayout(scenarios_header)
        landing_layout.addSpacing(14)
        self.scenarios = QWidget()
        self.scenario_layout = QGridLayout(self.scenarios)
        self.scenario_layout.setContentsMargins(0, 0, 0, 0)
        self.scenario_layout.setSpacing(14)
        landing_layout.addWidget(self.scenarios)
        self.empty_title = label("", heading=True)
        self.empty_title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.empty_subtitle = label("")
        self.empty_subtitle.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.empty_title.hide()
        self.empty_subtitle.hide()
        self.feed_layout.addWidget(self.landing)
        self.feed_layout.addWidget(rail)
        self.results = ResultPanel(canvas)
        self.results.fullscreen_requested.connect(self.set_fullscreen)
        self.feed_layout.addWidget(self.results)
        self.feed_layout.addStretch(1)
        self.scroll.setWidget(self.scroll_body)
        self.main_layout.addWidget(self.scroll, 1)
        self.selection_button = button("", self.clear_selection_requested.emit)
        self.selection_button.hide()
        self.main_layout.addWidget(self.selection_button)
        self.main_layout.addWidget(chips)
        self.main_layout.addWidget(composer)
        self.layout_row.addWidget(self.main, 1)
        self.more_button = button("⋯", lambda: None)
        self.more_button.setObjectName("iconGhost")
        self.more_menu = QMenu(self.more_button)
        self.more_button.setMenu(self.more_menu)
        self.shade = button("", self.close_drawer)
        self.shade.setParent(self)
        self.shade.setAccessibleName("Close navigation")
        self.shade.setStyleSheet("background:rgba(0,0,0,0.45);border:0;")
        self.shade.hide()
        self.escape = QShortcut(QKeySequence("Escape"), self)
        self.escape.activated.connect(self.dismiss)
        self.update_conversation(False, False)
        self.restyle()

    def restyle(self):
        self.setStyleSheet(
            f"#consoleSidebar{{background:{T._mix(T.BG, T.SURFACE_2, 0.45)};border-right:1px solid {T.BORDER};}}"
            f"#consoleSidebar[drawer=\"true\"]{{background:{T.SURFACE_2};}}"
            f"#consoleMain{{background:qradialgradient(cx:0.5,cy:0,radius:0.8,stop:0 {T._mix(T.BG,T.SECONDARY,0.16)},stop:0.7 {T.BG});}}"
            f"#consoleHeader{{background:{T._mix(T.BG,T.SURFACE_2,0.98)};border-bottom:1px solid {T.BORDER};}}"
            f"#consoleResult{{background:{T.SURFACE};border:1px solid {T.BORDER};border-radius:12px;}}"
            f"#consoleScenario{{background:{T._rgba(T.SURFACE_2,0.6)};border:1px solid {T._rgba(T.TEXT,0.09)};border-radius:12px;}}"
            f"#consoleDivider{{background:{T._rgba(T.TEXT,0.08)};border:none;}}"
            f"#consoleCategories{{background:{T._rgba(T.SURFACE_2,0.55)};border:1px solid {T._rgba(T.TEXT,0.09)};border-radius:10px;}}"
            f"#consoleCategory{{background:transparent;border:1px solid transparent;border-radius:6px;padding:0 14px;font-size:12px;font-weight:600;color:{T.MUTED};}}"
            f"#consoleCategory:checked{{background:{T._rgba(T.PRIMARY,0.2)};border-color:{T._rgba(T.PRIMARY,0.45)};color:{T.TEXT};}}"
            f"#consoleCategory:focus{{border:2px solid {T.PRIMARY};}}"
            f"#consoleScenario QPushButton{{padding:0 14px;border-radius:6px;font-size:12px;font-weight:600;}}"
            f"#consoleAgent{{background:{T._rgba(T.SURFACE_2,0.55)};border:1px solid {T._rgba(T.TEXT,0.07)};border-radius:10px;padding:0;}}"
            f"#consoleAgent:hover,#consoleAgent:focus{{border-color:{T.PRIMARY};}}"
            f"#consoleHistory{{background:transparent;border:0;padding:6px 0;text-align:left;font-size:12px;font-weight:700;color:{T.MUTED};}}"
            f"#consoleHistory:focus{{border:2px solid {T.PRIMARY};}}"
            f"#consoleAccount{{padding:0;background:{T._rgba(T.SURFACE_2,0.75)};border:1px solid {T._rgba(T.TEXT,0.09)};border-radius:10px;}}"
            "#consoleAccount::menu-indicator{image:none;width:0;}"
            f"#consoleDashboard{{padding:0 14px;background:{T._rgba(T.SURFACE_2,0.75)};border:1px solid {T._rgba(T.TEXT,0.16)};border-radius:6px;font-size:13px;font-weight:600;color:{T._mix(T.BG,T.TEXT,0.78)};}}"
            f"#consoleNewChat{{padding:0 14px;background:{T._rgba(T.PRIMARY,0.18)};border:1px solid {T._rgba(T.PRIMARY,0.4)};border-radius:6px;font-size:13px;color:{T.ACCENT};}}"
            f"#consoleAgentSearch{{background:{T._rgba(T.SURFACE_2,0.6)};border:1px solid {T._rgba(T.TEXT,0.14)};border-radius:10px;padding:8px 12px;font-size:14px;}}"
            f"#consoleShell{{background:{T.BG};}}"
        )
        for widget in self.findChildren(QLabel):
            tone = widget.property("consoleTone")
            if tone is not None:
                color = T.TEXT if tone == "text" else T.MUTED
                widget.setStyleSheet(re.sub(r"color:[^;]+;", f"color:{color};", widget.styleSheet()))
        self.directory_label.setStyleSheet(f"color:{T.MUTED};font-size:12px;font-weight:700;letter-spacing:1px;")
        self.directory_count.setStyleSheet(f"color:{T.TEXT};font-size:12px;font-weight:700;padding:2px 8px;border-radius:11px;border:1px solid {T._rgba(T.PRIMARY,0.32)};background:{T._rgba(T.PRIMARY,0.16)};")
        self.turn_count.setStyleSheet(f"color:{T.ACCENT};font-size:13px;font-weight:600;padding:6px 12px;border-radius:6px;background:{T.BG};")
        self.account_gear.setPixmap(icons.icon("gear", T.MUTED, T.TEXT, 16).pixmap(16, 16))

        self.results.restyle()

    def clear_private_state(self):
        self.dismiss()
        self.model = None
        self.account_button.setText("")
        self.account_name.clear()
        self.account_role.clear()
        self.account_menu.clear()
        self.more_menu.clear()
        self.search.clear()
        self.category = None
        self.background = False
        self.set_history([])
        self.set_selection(None)
        for layout in (self.agent_layout, self.categories_layout, self.scenario_layout):
            clear_layout(layout)
        self.results.set_workspace_actions([])
        self.setEnabled(False)

    def apply_model(self, model, menu):
        self.model = model
        self.menu = menu
        labels = model["labels"]
        self.brand.setAccessibleName(labels["brand"])
        self.heading.setText(labels["dashboard"])
        self.new_button.setText(labels["new_chat"])
        self.new_button.setAccessibleName(labels["new_chat"])
        self.history_button.setText(labels["history"].upper())
        self.history_button.setAccessibleName(labels["history"])
        self.history_new_button.setAccessibleName(labels["new_chat"])
        self.history_new_button.setToolTip(labels["new_chat"])
        icons.apply(self.history_new_button, "add", T.MUTED, T.TEXT)
        self.directory_label.setText(labels['agent_directory'].upper())
        self.directory_count.setText(str(len(model['catalog']['agents'])))
        self.search.setPlaceholderText(labels["search_agents"])
        self.search.setAccessibleName(labels["search_agents"])
        self.drawer_button.setAccessibleName(labels["agent_directory"])
        icons.apply(self.drawer_button, "menu", T.MUTED, T.TEXT)
        self.title.setText(labels["title"])
        self.subtitle.setText(labels["subtitle"])
        self.start_here.setText(labels["start_here"])
        self.empty_title.setText(labels["empty_title"])
        self.empty_subtitle.setText(labels["empty_subtitle"])
        self.more_button.setAccessibleName(labels["more"])
        icons.apply(self.more_button, "more", T.MUTED, T.TEXT)
        self.more_button.setToolTip(labels["more"])
        self.selection_button.setAccessibleName(labels["clear_selection"])
        identity = model["identity"]
        self.account_name.setText(identity['name'])
        self.account_role.setText(identity['role'])
        self.account_button.setAccessibleName(identity["name"])
        self.account_menu.clear()
        for section in menu.get("sections", []):
            self.account_menu.addSection(section["label"])
            for item in section["items"]:
                self.account_menu.addAction(item["label"], lambda selected=item: self._open_item(selected))
        signout = menu.get("signout", {})
        if signout.get("action") == "logout":
            self.account_menu.addSeparator()
            self.account_menu.addAction(signout["label"], self.signout_requested.emit)
        self.more_menu.clear()
        self.results.set_workspace_actions(menu.get("workspace_actions", []))
        for item in model["composer_actions"]:
            action = self.more_menu.addAction(item["label"])
            if item["kind"] == "toggle":
                action.setCheckable(True)
                action.setChecked(self.background)
                action.toggled.connect(self._set_background)
            else:
                action.triggered.connect(lambda checked=False, selected=item: self._open_action(selected))
        categories = model["catalog"]["categories"]
        if self.category not in categories:
            self.category = None
        clear_layout(self.categories_layout)
        for category in [None, *categories]:
            text = labels["all_categories"] if category is None else category
            control = button(text, lambda checked=False, selected=category: self.select_category(selected))
            control.setCheckable(True)
            control.setObjectName("consoleCategory")
            control.setChecked(category == self.category)
            control.setProperty("category", category or "")
            control.installEventFilter(self)
            self.categories_layout.addWidget(control)
        self.categories_layout.addStretch(1)
        self.set_turns(0)
        self._render_agents()
        self._render_scenarios()
        if self.presentation:
            self.results.configure(labels, self.presentation)
            self._size_controls()

    def apply_presentation(self, presentation):
        self.presentation = presentation
        wide = presentation["navigation_mode"] != "drawer"
        self.close_drawer()
        if wide:
            self.layout_row.insertWidget(0, self.sidebar)
            self.sidebar.show()
        else:
            self.layout_row.removeWidget(self.sidebar)
            self.sidebar.setParent(self)
            self.sidebar.hide()
        self.sidebar.setFixedWidth(round(presentation["sidebar_width"]))
        self.drawer_button.setVisible(not wide)
        if self.model:
            self.heading.setText(self.model["labels"]["dashboard"] + (self.model["labels"]["dashboard_suffix"] if wide else ""))
            self.heading.setIcon(icons.icon("back", T.MUTED, T.TEXT, 14))
            self.heading.setIconSize(QSize(14, 14))
            icons.apply(self.new_button, "add", T.TEXT, T.TEXT)
            if wide:
                self.new_button.setText(self.model["labels"]["new_chat"])
        padding = presentation["content_padding"]
        self.feed_layout.setContentsMargins(*(round(padding[k]) for k in ("left", "top", "right", "bottom")))
        padding = presentation["composer_padding"]
        self.composer.layout().setContentsMargins(*(round(padding[k]) for k in ("left", "top", "right", "bottom")))
        self._render_scenarios()
        if self.model:
            self.results.configure(self.model["labels"], presentation)
        self._size_controls()
        self._place_overlays()

    def set_turns(self, turns):
        if self.model:
            labels = self.model['labels']
            self.turn_count.setText(f"({turns} {labels['turn_singular' if turns == 1 else 'turn_plural']})")

    def _size_controls(self):
        if self.presentation is None:
            return
        minimum = round(self.presentation["minimum_control_height"])
        for control in self.categories_body.findChildren(QPushButton):
            control.setMinimumHeight(max(32, minimum))
        for control in self.history_body.findChildren(QPushButton):
            control.setMinimumHeight(max(32, minimum))
        for control in (self.heading, self.new_button, self.drawer_button):
            control.setMinimumHeight(max(32, minimum))
        self.history_new_button.setFixedSize(max(28, minimum), max(28, minimum))
        self.history_new_button.setStyleSheet(f"min-width:0;max-width:16777215;min-height:0;padding:0;border-radius:6px;background:transparent;border:1px solid {T.BORDER};")
        self.history_button.setMinimumHeight(max(28, minimum))
        self.search.setMinimumHeight(max(38, minimum))
        wide = self.presentation['navigation_mode'] == 'sidebar'
        self.header.setFixedHeight(54 if wide else 61)
        self.sidebar.setProperty('drawer', not wide)
        self.sidebar.style().unpolish(self.sidebar)
        self.sidebar.style().polish(self.sidebar)
        self.header.layout().setContentsMargins(32 if wide else 10, 10 if wide else 8, 32 if wide else 8, 10 if wide else 8)
        self.drawer_button.setFixedWidth(44)
        padding = self.presentation['content_padding']
        available = self.scroll.viewport().width() - round(padding['left'] + padding['right'])
        category_width = self.categories_layout.sizeHint().width() + 2
        self.categories_scroll.setFixedWidth(max(1, min(category_width, round(available * 0.62))))
        categories = self.categories_body.findChildren(QPushButton)
        for control in categories:
            control.ensurePolished()
        height = max((max(control.minimumHeight(), control.sizeHint().height())
                      for control in categories), default=minimum)
        margins = self.categories_layout.contentsMargins()
        self.categories_scroll.setFixedHeight(
            height + margins.top() + margins.bottom() + self.categories_scroll.frameWidth() * 2
        )
        self.subtitle.setMinimumHeight(21)
        if isinstance(self.composer, ResponsiveComposer):
            self.composer.set_control_minimum(minimum)

    def select_category(self, category):
        self.category = category
        for index in range(self.categories_layout.count()):
            control = self.categories_layout.itemAt(index).widget()
            if isinstance(control, QPushButton):
                control.setChecked(control.property("category") == (category or ""))
        self._render_scenarios()

    def _render_scenarios(self):
        focused = QApplication.focusWidget()
        focus_key = (focused.property("scenarioId"), focused.property("runScenario")) if focused is not None else None
        clear_layout(self.scenario_layout)
        if self.model is None or self.presentation is None:
            return
        labels = self.model["labels"]
        rows = [row for row in self.model["catalog"]["scenarios"] if self.category is None or row["category"] == self.category]
        columns = self.presentation["scenario_columns"]
        for index, row in enumerate(rows):
            card = QFrame()
            card.setObjectName("consoleScenario")
            card.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
            layout = QVBoxLayout(card)
            layout.setContentsMargins(16, 16, 16, 16)
            layout.setSpacing(8)
            head = QHBoxLayout()
            head.addWidget(label(row['category']), 1)
            badge = label(labels["example"], size=11, weight=600)
            badge.setStyleSheet(f"color:{T.MUTED};font-size:11px;font-weight:600;padding:2px 8px;border-radius:10px;border:1px solid {T._rgba(T.TEXT,0.12)};background:{T._rgba(T.TEXT,0.05)};")
            head.addWidget(badge)
            layout.addLayout(head)
            title = label(row["title"], heading=True, size=14, weight=700)
            title.setMinimumHeight(21)
            layout.addWidget(title)
            description = label(row["description"])
            description.setMinimumHeight(18)
            layout.addWidget(description)
            controls = QHBoxLayout()
            controls.setSpacing(8)
            controls.setContentsMargins(0, 4, 0, 0)
            for run, key in ((True, "run"), (False, "load_prompt")):
                control = button(labels[key], lambda checked=False, identity=row["id"], execute=run: self.scenario_requested.emit(identity, execute))
                control.setProperty("scenarioId", row["id"])
                control.setProperty("runScenario", run)
                control.setMinimumHeight(max(34, round(self.presentation["minimum_control_height"])))
                if focus_key == (row["id"], run):
                    control.setFocus()
                if run:
                    control.setObjectName("primary")
                controls.addWidget(control)
            controls.addStretch(1)
            layout.addLayout(controls)
            self.scenario_layout.addWidget(card, index // columns, index % columns)

    def _render_agents(self):
        clear_layout(self.agent_layout)
        if self.model is None:
            return
        query = self.search.text().casefold().strip()
        for row in self.model["catalog"]["agents"]:
            if query and query not in f"{row['name']} {row['description']}".casefold():
                continue
            control = button(row["name"], lambda checked=False, selected=row: self._open_agent(selected))
            control.setAccessibleDescription(f"{row['state']}. {row['description']}")
            control.setProperty("agentId", row["id"])
            control.setObjectName("consoleAgent")
            control.setText("")
            control.setFixedHeight(84)
            control.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Minimum)
            content = QVBoxLayout(control)
            content.setContentsMargins(14, 12, 12, 12)
            content.setSpacing(4)
            heading = QHBoxLayout()
            name = label(row["name"], heading=True)
            name.setStyleSheet(f"color:{T.TEXT};font-size:14px;font-weight:600;")
            name.setWordWrap(False)
            name.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
            name.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
            heading.addWidget(name, 1)
            state = label("")
            state.setFixedSize(8, 8)
            state.setProperty("consoleTone", None)
            state.setStyleSheet(f"background:{T.VARIANT_COLORS['success'][0] if row['state'] == 'ready' else T.MUTED};border-radius:4px;")
            state.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
            heading.addWidget(state)
            content.addLayout(heading)
            description = AgentDescription(row["description"])
            description.setAlignment(Qt.AlignmentFlag.AlignTop)
            description.setFixedHeight(34)
            description.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
            content.addWidget(description)
            self.agent_layout.addWidget(control)
        self.agent_layout.addStretch(1)

    def _open_agent(self, row):
        self.close_drawer()
        self.surface_requested.emit("agent_intro", row["name"], {"agent_id": row["id"]})

    def _open_item(self, item):
        self.close_drawer()
        self.surface_requested.emit(item["surface"], item["label"], item.get("params", {}))

    def _open_action(self, item):
        action = item["action"]
        self.surface_requested.emit(action["surface"], item["label"], action.get("params", {}))

    def _set_background(self, enabled):
        self.background = enabled
        self.background_changed.emit(enabled)

    def _new_chat(self):
        self.close_drawer()
        self.new_chat_requested.emit()

    def show_dashboard(self):
        self.dismiss()
        self.landing.show()
        self.rail.hide()
        self.results.hide()

    def _toggle_history(self):
        expanded = self.history_button.isChecked()
        self.history_scroll.setVisible(expanded)
        self.history_button.setAccessibleDescription("Expanded" if expanded else "Collapsed")
        self.history_chevron.setPixmap(icons.icon("chevron_down" if expanded else "chevron_right", T.MUTED, T.TEXT, 12).pixmap(12, 12))
        if expanded:
            self.history_requested.emit()

    def set_history(self, rows):
        self._history = rows if isinstance(rows, list) else []
        clear_layout(self.history_layout)
        for row in self._history[:200]:
            if not isinstance(row, dict) or not isinstance(row.get("id", row.get("chat_id")), str):
                continue
            identity = row.get("id", row.get("chat_id"))
            title = str(row.get("title") or row.get("name") or identity)[:200]
            self.history_layout.addWidget(button(title, lambda checked=False, selected=identity: self._load_chat(selected)))
        self.history_layout.addStretch(1)
        self._size_controls()

    def _load_chat(self, identity):
        self.close_drawer()
        self.chat_requested.emit(identity)

    def update_conversation(self, active, results):
        self._has_conversation = active
        self.landing.setVisible(not active)
        self.rail.setVisible(active)
        self.results.setVisible(results or self.results.fullscreen)

    def set_selection(self, selection):
        names = []
        if selection:
            if selection.get("agent"):
                names.append(selection["agent"]["agent_id"])
            names.extend(item[identity] for key, identity in (("skills", "skill_id"), ("notes", "note_id"))
                         for item in selection.get(key, []))
        self.selection_button.setText(" · ".join(names) + "   ×")
        self.selection_button.setVisible(bool(names))

    def toggle_drawer(self):
        if self.drawer_open:
            self.close_drawer()
        elif self.presentation and self.presentation["navigation_mode"] == "drawer":
            self._drawer_focus = QApplication.focusWidget()
            self.drawer_open = True
            self.shade.show()
            self.shade.raise_()
            self.sidebar.show()
            self.sidebar.raise_()
            self._place_overlays()
            self.main.setEnabled(False)
            self.history_button.setFocus()

    def close_drawer(self):
        if not self.drawer_open:
            return
        self.drawer_open = False
        self.sidebar.hide()
        self.shade.hide()
        self.main.setEnabled(True)
        if self._drawer_focus is not None:
            try:
                self._drawer_focus.setFocus()
            except RuntimeError:
                self.drawer_button.setFocus()
        self._drawer_focus = None

    def set_fullscreen(self, enabled):
        if enabled == self.results.fullscreen:
            return
        self.close_drawer()
        self.results.fullscreen = enabled
        if enabled:
            self._return_focus = QApplication.focusWidget()
            self._collapsed_before_fullscreen = self.results.collapsed
            self._scroll_before_fullscreen = self.scroll.verticalScrollBar().value()
            self.feed_layout.removeWidget(self.results)
            self.results.setParent(self)
            self.main.setEnabled(False)
            self.sidebar.setEnabled(False)
            self.results.collapsed = False
            self.results.show()
            self.results.raise_()
            self._place_overlays()
            self.results.fullscreen_button.setFocus()
        else:
            self.main.setEnabled(True)
            self.sidebar.setEnabled(True)
            self.feed_layout.insertWidget(self.feed_layout.count() - 1, self.results)
            self.results.show()
            self.results.collapsed = self._collapsed_before_fullscreen
            self.results.apply_state()
            if self._return_focus is not None:
                try:
                    self._return_focus.setFocus()
                except RuntimeError:
                    self.results.fullscreen_button.setFocus()
            self._return_focus = None
            QTimer.singleShot(0, lambda: self.scroll.verticalScrollBar().setValue(self._scroll_before_fullscreen))
        self.results.apply_state()

    def dismiss(self):
        if self.results.fullscreen:
            self.set_fullscreen(False)
        else:
            self.close_drawer()

    def _place_overlays(self):
        self.shade.setGeometry(self.rect())
        if self.drawer_open:
            self.sidebar.setGeometry(0, 0, self.sidebar.width(), self.height())
        if self.results.fullscreen:
            self.results.setGeometry(self.rect())

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._place_overlays()
        self._size_controls()

    def eventFilter(self, watched, event):
        if event.type() == QEvent.Type.FocusIn and watched.property("category") is not None:
            self.categories_scroll.ensureWidgetVisible(watched, 6, 0)
        return super().eventFilter(watched, event)
