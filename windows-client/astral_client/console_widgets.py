"""Renders the server-owned console catalog and ROTE geometry as native Qt widgets.
The application supplies authenticated actions and retains one canvas through result presentation changes.
"""

from __future__ import annotations

import re

from PySide6.QtCore import Qt, Signal, QTimer
from PySide6.QtGui import QKeySequence, QShortcut
from PySide6.QtWidgets import (
    QApplication, QFrame, QGridLayout, QHBoxLayout, QLabel, QLineEdit,
    QMenu, QPlainTextEdit, QPushButton, QScrollArea, QSizePolicy, QVBoxLayout, QWidget,
)

from . import theme as T
from . import icons


def clear_layout(layout):
    while layout.count():
        item = layout.takeAt(0)
        widget = item.widget()
        if widget is not None:
            widget.setParent(None)
            widget.deleteLater()
        elif item.layout() is not None:
            clear_layout(item.layout())


def label(text, *, heading=False):
    widget = QLabel(text)
    widget.setProperty("consoleTone", "text" if heading else "muted")
    widget.setTextFormat(Qt.TextFormat.PlainText)
    widget.setWordWrap(True)
    widget.setStyleSheet(
        f"color:{T.TEXT if heading else T.MUTED};font-size:{18 if heading else 13}px;"
        f"font-weight:{600 if heading else 400};background:transparent;"
    )
    return widget


def button(text, callback, *, name=None):
    widget = QPushButton(text.replace("&", "&&"))
    widget.setAccessibleName(name or text)
    widget.setToolTip(name or text)
    widget.setCursor(Qt.CursorShape.PointingHandCursor)
    widget.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
    widget.clicked.connect(callback)
    return widget


class ComposerEdit(QPlainTextEdit):
    returnPressed = Signal()

    def __init__(self):
        super().__init__()
        self.setMaximumHeight(72)
        self.setMinimumHeight(48)
        self.setTabChangesFocus(True)
        self._completer = None

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
        for control in self._fixed_controls:
            if control.objectName() == "iconGhost":
                control.setStyleSheet(f"min-height:{max(0, minimum - 2)}px;")
            control.setMinimumHeight(minimum)
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
        self.preview_height = 380
        self._layout = QVBoxLayout(self)
        self._layout.setContentsMargins(16, 12, 16, 12)
        self.role = label("")
        self._layout.addWidget(self.role)
        self.header = QHBoxLayout()
        self.title = label("", heading=True)
        self.title.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        self.header.addWidget(self.title, 1)
        self.turn_badge = label("")
        self.header.addWidget(self.turn_badge)
        self.workspace_layout = QHBoxLayout()
        self.header.addLayout(self.workspace_layout)
        self.collapse_button = button("", self.toggle_collapsed)
        self.fullscreen_button = button("", self.toggle_fullscreen)
        self.header.addWidget(self.collapse_button)
        self.header.addWidget(self.fullscreen_button)
        self._layout.addLayout(self.header)
        self._layout.addWidget(canvas, 1)
        self.preview_button = button("", self.toggle_fullscreen)
        self._layout.addWidget(self.preview_button)
        self.preview_cover = button("", self.toggle_fullscreen)
        self.preview_cover.setParent(canvas)
        self.preview_cover.setStyleSheet("background:transparent;border:0;")
        self.preview_cover.setFocusPolicy(Qt.FocusPolicy.NoFocus)

    def configure(self, labels, presentation):
        self.labels = labels
        agent = labels["result_default_agent"]
        self.title.setText(labels["result_title"].replace("{agent}", agent))
        self.role.setText(labels["result_agent_role"])
        self.preview_height = round(presentation["result_body_max_height"])
        self.preview_button.setText(labels["result_preview_action"])
        self.preview_button.setAccessibleName(labels["result_preview_action"])
        self.preview_cover.setAccessibleName(labels["result_preview_action"])
        self.apply_state()

    def set_metadata(self, agent, turns):
        if not self.labels:
            return
        self.title.setText(self.labels["result_title"].replace("{agent}", agent or self.labels["result_default_agent"]))
        self.turn_badge.setText(f"{turns} {self.labels['turn_singular' if turns == 1 else 'turn_plural']}")
        self.turn_badge.setVisible(turns > 0)

    def set_workspace_actions(self, actions):
        clear_layout(self.workspace_layout)
        for action in actions:
            control = button(action["label"], lambda checked=False, operation=action["operation"]: self.workspace_requested.emit(operation))
            control.setProperty("workspaceOperation", action["operation"])
            control.setObjectName("iconGhost")
            icons.apply(control, action["icon"], T.MUTED, T.TEXT)
            self.workspace_layout.addWidget(control)

    def toggle_collapsed(self):
        self.collapsed = not self.collapsed
        self.apply_state()

    def toggle_fullscreen(self):
        self.fullscreen_requested.emit(not self.fullscreen)

    def apply_state(self):
        if not self.labels:
            return
        self.collapse_button.setText("＋" if self.collapsed else "−")
        icons.apply(self.collapse_button, "expand" if self.collapsed else "collapse", T.MUTED, T.TEXT)
        self.collapse_button.setAccessibleName(self.labels["expand" if self.collapsed else "collapse"])
        self.collapse_button.setToolTip(self.collapse_button.accessibleName())
        self.collapse_button.setProperty("expanded", not self.collapsed)
        self.fullscreen_button.setText(self.labels["exit_fullscreen" if self.fullscreen else "fullscreen"])
        self.fullscreen_button.setAccessibleName(self.fullscreen_button.text())
        self.fullscreen_button.setToolTip(self.fullscreen_button.text())
        icons.apply(self.fullscreen_button, "exit_fullscreen" if self.fullscreen else "fullscreen", T.MUTED, T.TEXT)
        self.canvas.setVisible(not self.collapsed)
        self.preview_button.setVisible(not self.fullscreen and not self.collapsed)
        self.preview_cover.setVisible(not self.fullscreen and not self.collapsed)
        self.canvas.setMinimumHeight(0 if self.collapsed else 120)
        self.canvas.setMaximumHeight(16777215 if self.fullscreen else self.preview_height)
        self.preview_cover.setGeometry(self.canvas.rect())
        self.preview_cover.raise_()

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.preview_cover.setGeometry(self.canvas.rect())


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
        self.sidebar_layout.setContentsMargins(24, 28, 24, 18)
        self.sidebar_layout.setSpacing(14)
        self.brand = label("", heading=True)
        self.sidebar_layout.addWidget(self.brand)
        self.new_button = button("", self._new_chat)
        self.new_button.setObjectName("primary")
        self.history_button = button("", self._toggle_history)
        self.history_button.setCheckable(True)
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
        self.sidebar_layout.addWidget(self.directory_label)
        self.search = QLineEdit()
        self.search.textChanged.connect(self._render_agents)
        self.sidebar_layout.addWidget(self.search)
        self.agent_scroll = QScrollArea()
        self.agent_scroll.setWidgetResizable(True)
        self.agent_body = QWidget()
        self.agent_layout = QVBoxLayout(self.agent_body)
        self.agent_layout.setContentsMargins(0, 0, 0, 0)
        self.agent_scroll.setWidget(self.agent_body)
        self.sidebar_layout.addWidget(self.agent_scroll, 1)
        self.account_button = button("", lambda: None)
        self.account_menu = QMenu(self.account_button)
        self.account_button.setMenu(self.account_menu)
        self.sidebar_layout.addWidget(self.account_button)
        self.layout_row.addWidget(self.sidebar)
        self.main = QWidget()
        self.main_layout = QVBoxLayout(self.main)
        self.main_layout.setContentsMargins(0, 0, 0, 0)
        self.main_layout.setSpacing(0)
        self.header = QWidget()
        header_layout = QHBoxLayout(self.header)
        self.drawer_button = button("☰", self.toggle_drawer)
        header_layout.addWidget(self.drawer_button)
        self.heading = button("", self.show_dashboard)
        self.heading.setObjectName("ghost")
        header_layout.addWidget(self.heading, 1)
        header_layout.addWidget(status)
        header_layout.addWidget(self.new_button)
        self.main_layout.addWidget(self.header)
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QFrame.Shape.NoFrame)
        self.scroll_body = QWidget()
        self.feed_layout = QVBoxLayout(self.scroll_body)
        self.feed_layout.setSpacing(24)
        self.landing = QWidget()
        landing_layout = QVBoxLayout(self.landing)
        landing_layout.setContentsMargins(0, 0, 0, 0)
        self.title = label("", heading=True)
        self.title.setStyleSheet(f"color:{T.TEXT};font-size:30px;font-weight:600;")
        self.subtitle = label("")
        landing_layout.addWidget(self.title)
        landing_layout.addWidget(self.subtitle)
        self.categories_scroll = QScrollArea()
        self.categories_scroll.setWidgetResizable(True)
        self.categories_scroll.setMaximumHeight(62)
        self.categories_scroll.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.categories_body = QWidget()
        self.categories_layout = QHBoxLayout(self.categories_body)
        self.categories_layout.setContentsMargins(0, 10, 0, 10)
        self.categories_scroll.setWidget(self.categories_body)
        landing_layout.addWidget(self.categories_scroll)
        self.scenarios = QWidget()
        self.scenario_layout = QGridLayout(self.scenarios)
        self.scenario_layout.setContentsMargins(0, 0, 0, 0)
        self.scenario_layout.setSpacing(14)
        landing_layout.addWidget(self.scenarios)
        self.empty_title = label("", heading=True)
        self.empty_title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.empty_subtitle = label("")
        self.empty_subtitle.setAlignment(Qt.AlignmentFlag.AlignCenter)
        landing_layout.addSpacing(24)
        landing_layout.addWidget(self.empty_title)
        landing_layout.addWidget(self.empty_subtitle)
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
            f"#consoleSidebar{{background:{T.SURFACE_2};border-right:1px solid {T.BORDER};}}"
            f"#consoleResult{{background:{T.SURFACE};border:1px solid {T.BORDER};border-radius:12px;}}"
            f"#consoleScenario{{background:{T.SURFACE};border:1px solid {T.BORDER};border-radius:12px;}}"
            f"#consoleShell{{background:{T.BG};}}"
        )
        for widget in self.findChildren(QLabel):
            tone = widget.property("consoleTone")
            if tone is not None:
                color = T.TEXT if tone == "text" else T.MUTED
                widget.setStyleSheet(re.sub(r"color:[^;]+;", f"color:{color};", widget.styleSheet()))

    def clear_private_state(self):
        self.dismiss()
        self.model = None
        self.account_button.setText("")
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
        self.brand.setText(labels["brand"])
        self.heading.setText(labels["dashboard"])
        self.new_button.setText(labels["new_chat"])
        self.new_button.setAccessibleName(labels["new_chat"])
        self.history_button.setText(labels["history"])
        self.history_button.setAccessibleName(labels["history"])
        self.history_new_button.setAccessibleName(labels["new_chat"])
        self.history_new_button.setToolTip(labels["new_chat"])
        icons.apply(self.history_new_button, "add", T.MUTED, T.TEXT)
        self.directory_label.setText(f"{labels['agent_directory']}   {len(model['catalog']['agents'])}")
        self.search.setPlaceholderText(labels["search_agents"])
        self.search.setAccessibleName(labels["search_agents"])
        self.drawer_button.setAccessibleName(labels["agent_directory"])
        icons.apply(self.drawer_button, "menu", T.MUTED, T.TEXT)
        self.title.setText(labels["title"])
        self.subtitle.setText(labels["subtitle"])
        self.empty_title.setText(labels["empty_title"])
        self.empty_subtitle.setText(labels["empty_subtitle"])
        self.more_button.setAccessibleName(labels["more"])
        icons.apply(self.more_button, "more", T.MUTED, T.TEXT)
        self.more_button.setToolTip(labels["more"])
        self.selection_button.setAccessibleName(labels["clear_selection"])
        identity = model["identity"]
        self.account_button.setText(f"{identity['initials']}   {identity['name']}  ·  {identity['role']}")
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
            control.setChecked(category == self.category)
            control.setProperty("category", category or "")
            self.categories_layout.addWidget(control)
        self.categories_layout.addStretch(1)
        self._render_agents()
        self._render_scenarios()
        if self.presentation:
            self.results.configure(labels, self.presentation)
            self._size_controls()

    def apply_presentation(self, presentation):
        self.presentation = presentation
        wide = presentation["navigation_mode"] == "sidebar"
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

    def _size_controls(self):
        if self.presentation is None:
            return
        minimum = round(self.presentation["minimum_control_height"])
        for control in self.findChildren(QPushButton):
            control.setMinimumHeight(max(minimum, control.minimumHeight()))
            if control.objectName() == "iconGhost":
                style = re.sub(r"min-height:\s*\d+px;?", "", control.styleSheet())
                style += f"min-height:{minimum}px;"
                if style != control.styleSheet():
                    control.setStyleSheet(style)
        margins = self.categories_layout.contentsMargins()
        self.categories_scroll.setFixedHeight(
            minimum + margins.top() + margins.bottom() + self.categories_scroll.frameWidth() * 2
            + self.categories_scroll.horizontalScrollBar().sizeHint().height())
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
            layout.setContentsMargins(18, 16, 18, 16)
            layout.addWidget(label(labels["example"]))
            layout.addWidget(label(row["title"], heading=True))
            layout.addWidget(label(row["description"]))
            layout.addStretch(1)
            controls = QHBoxLayout()
            for run, key in ((True, "run"), (False, "load_prompt")):
                control = button(labels[key], lambda checked=False, identity=row["id"], execute=run: self.scenario_requested.emit(identity, execute))
                control.setProperty("scenarioId", row["id"])
                control.setProperty("runScenario", run)
                control.setMinimumHeight(round(self.presentation["minimum_control_height"]))
                if focus_key == (row["id"], run):
                    control.setFocus()
                if run:
                    control.setObjectName("primary")
                controls.addWidget(control)
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
            control.setText("")
            control.setMinimumHeight(90)
            control.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Minimum)
            content = QVBoxLayout(control)
            content.setContentsMargins(12, 10, 12, 10)
            heading = QHBoxLayout()
            name = label(row["name"], heading=True)
            name.setStyleSheet(f"color:{T.TEXT};font-size:13px;font-weight:600;")
            name.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
            heading.addWidget(name, 1)
            state = label("●")
            state.setProperty("consoleTone", None)
            state.setStyleSheet(f"color:{T.VARIANT_COLORS['success' if row['state'] == 'ready' else 'warning'][0]};")
            state.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
            heading.addWidget(state)
            content.addLayout(heading)
            description = label(row["description"])
            description.setAlignment(Qt.AlignmentFlag.AlignTop)
            description.setMaximumHeight(description.fontMetrics().lineSpacing() * 2)
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
            if self._return_focus is not None:
                try:
                    self._return_focus.setFocus()
                except RuntimeError:
                    self.results.fullscreen_button.setFocus()
            self._return_focus = None
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
