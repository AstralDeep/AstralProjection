"""Coordinates connection-scoped viewport hydration and semantic native control state.
The window retains its committed view until both the ROTE acknowledgment and snapshot validate.
"""

from __future__ import annotations

import copy
import uuid
from dataclasses import dataclass

from PySide6.QtCore import QObject, QSignalBlocker, QTimer
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QLabel, QLineEdit, QPlainTextEdit,
    QPushButton, QTabWidget, QWidget,
)

from .console import parse_console_presentation
from .protocol import ConversationSnapshot, WindowsProtocolError, decode_semantic_transcript
from .renderer import render


class ControlIdentityError(ValueError):
    pass


def _kind(control):
    if isinstance(control, QLineEdit):
        return "text"
    if isinstance(control, QPlainTextEdit):
        return "multiline"
    if isinstance(control, QComboBox):
        return "choice"
    if isinstance(control, (QCheckBox, QPushButton)) and control.isCheckable():
        return "checked"
    if isinstance(control, QTabWidget):
        return "tab"
    return None


def _identity(control, root):
    key = control.property("astral_control_key")
    current = control
    while current is not None:
        component = current.property("component_id") or current.property("component_state_key")
        if component:
            return (str(component), str(current.property("component_type") or ""), str(key or ""), _kind(control))
        if current is root:
            break
        current = current.parentWidget()
    return None


def control_index(root, *, strict=False):
    result, duplicates = {}, set()
    for control in [root, *root.findChildren(QWidget)]:
        if _kind(control) is None:
            continue
        key = _identity(control, root)
        if key is None:
            if strict:
                raise ControlIdentityError("A result control has no semantic identity.")
            continue
        if key in result:
            duplicates.add(key)
        result[key] = control
    if strict and duplicates:
        raise ControlIdentityError("Result control identities are ambiguous.")
    return {key: value for key, value in result.items() if key not in duplicates}


def capture_controls(root, *, strict=False):
    result = {}
    for key, control in control_index(root, strict=strict).items():
        kind = key[-1]
        position = None
        if kind == "text":
            value = control.text()
            position = (control.cursorPosition(), control.selectionStart(), len(control.selectedText()))
        elif kind == "multiline":
            value = control.toPlainText()
            cursor = control.textCursor()
            position = (cursor.position(), cursor.anchor())
        elif kind == "choice":
            value = control.currentText()
        elif kind == "tab":
            page = control.currentWidget()
            value = page.property("astral_tab_key") if page is not None else None
        else:
            value = control.isChecked()
        result[key] = (value, position, control is QApplication.focusWidget())
    return result


def restore_controls(root, saved, *, strict=False):
    index = control_index(root, strict=strict)
    if strict and not saved.keys() <= index.keys():
        raise ControlIdentityError("The refreshed result cannot preserve every control.")
    resolved = []
    for key, state in saved.items():
        control = index.get(key)
        if control is None:
            continue
        value, position, focused = state
        kind = key[-1]
        choices = None
        if kind in {"choice", "tab"}:
            choices = ([control.itemText(i) for i in range(control.count())] if kind == "choice"
                       else [control.widget(i).property("astral_tab_key") for i in range(control.count())])
            if choices.count(value) != 1 or value is None:
                if strict:
                    raise ControlIdentityError("The refreshed choice has no unambiguous identity.")
                continue
        resolved.append((control, kind, value, position, focused, choices))
    for control, kind, value, position, focused, choices in resolved:
        with QSignalBlocker(control):
            if kind == "text":
                control.setText(value)
                cursor, start, length = position
                control.setCursorPosition(cursor)
                if start >= 0:
                    control.setSelection(start + length if cursor == start else start,
                                         -length if cursor == start else length)
            elif kind == "multiline":
                control.setPlainText(value)
                cursor = control.textCursor()
                cursor.setPosition(position[1])
                cursor.setPosition(position[0], cursor.MoveMode.KeepAnchor)
                control.setTextCursor(cursor)
            elif kind in {"choice", "tab"}:
                control.setCurrentIndex(choices.index(value))
            else:
                control.setChecked(value)
        if kind == "choice":
            control.currentTextChanged.emit(control.currentText())
        elif kind == "checked" and control.property("astral_control_key") == "expanded":
            control.toggled.emit(control.isChecked())
        if focused:
            control.setFocus()


def capture_selections(root):
    result = {}
    for label in root.findChildren(QLabel):
        if label.hasSelectedText():
            key = (_identity(label, root), label.text())
            if key in result:
                raise ControlIdentityError("Selected text has an ambiguous identity.")
            result[key] = (label.selectionStart(), len(label.selectedText()))
    return result


def restore_selections(root, saved):
    labels = root.findChildren(QLabel)
    for (identity, text), (start, length) in saved.items():
        targets = [label for label in labels if label.text() == text and _identity(label, root) == identity]
        if len(targets) != 1:
            raise ControlIdentityError("The refreshed content cannot preserve text selection.")
        targets[0].setSelection(start, length)


def _focus_identity(control, root):
    return (_identity(control, root), control.metaObject().className(), control.accessibleName(),
            control.text() if isinstance(control, (QPushButton, QLabel)) else "")


def capture_focus(root):
    focus = QApplication.focusWidget()
    if focus is not None and (focus is root or root.isAncestorOf(focus)):
        return _focus_identity(focus, root)
    return None


def focus_target(root, identity):
    if identity is None:
        return None
    targets = [control for control in [root, *root.findChildren(QWidget)]
               if _focus_identity(control, root) == identity]
    if len(targets) != 1:
        raise ControlIdentityError("The focused result control has no unambiguous identity.")
    return targets[0]


@dataclass
class RefreshRequest:
    client: object
    owner: str
    chat: str
    connection: str
    generation: str
    submission: str
    revision: int
    device: dict
    layout: dict | None = None
    snapshot: dict | None = None


class ViewportRefresh(QObject):
    def __init__(self, window):
        super().__init__(window)
        self.window = window
        self.supported = False
        self.pending = None
        self.desired = None
        self.applied = None
        self.retry_required = False
        self.timeout = QTimer(self)
        self.timeout.setSingleShot(True)
        self.timeout.setInterval(10000)
        self.timeout.timeout.connect(self.fail)
        self.deferred = QTimer(self)
        self.deferred.setSingleShot(True)
        self.deferred.setInterval(250)
        self.deferred.timeout.connect(self.flush)

    def scope_matches(self, request):
        window = self.window
        return (request is self.pending and request.client is window.client
                and request.owner == window._resume_store.storage_key
                and request.chat == window.active_chat
                and request.connection == getattr(window.client, "connection_generation", None)
                and request.generation == window._continuity.request_generation
                and request.revision == window._continuity.last_committed_render_revision)

    def retire(self, *, reset=False):
        request, self.pending = self.pending, None
        self.timeout.stop()
        self.deferred.stop()
        if request is not None:
            self.window._continuity.retire_request(request.generation)
            if getattr(request.client, "request_generation", None) == request.generation:
                request.client.request_generation = None
                request.client.request_purpose = None
                request.client.request_chat_id = None
        if reset:
            self.supported = False
            self.applied = self.desired = None
            self.retry_required = False

    def fail(self):
        if self.pending is None:
            return
        self.retire()
        self.retry_required = True
        self.window._show_banner("Window layout could not refresh. Your result is unchanged. Activate to retry.", "warning")
        self.window._banner.setProperty("viewport_retry", True)

    def retry(self):
        self.retry_required = False
        self.window._banner.setProperty("viewport_retry", False)
        self.window._hide_banner()
        self.flush()

    def busy(self):
        window = self.window
        focus = QApplication.focusWidget()
        editing = (focus is not None and window.isAncestorOf(focus)
                   and isinstance(focus, (QLineEdit, QPlainTextEdit, QComboBox)))
        actions = window._workspace_actions
        voice = getattr(window, "_voice_controller", None)
        surface = window._surface_dialog
        return bool(editing or QApplication.activeModalWidget() or QApplication.activePopupWidget()
                    or window._turn_active or window._turn_phase_active or window._timeline_mode
                    or window._newest_visible_local_submission() or window._newest_active_operation_status()
                    or window._work_read or window._guidance_ticket or window._pending_voice_chat
                    or getattr(window, "_viewport_downloads", 0)
                    or (surface is not None and surface.isVisible())
                    or (actions is not None and actions._active)
                    or any(item.get("status") == "uploading" for item in window._attachments)
                    or (voice is not None and (voice.session_id is not None
                        or voice.state not in {"off", "error", "unavailable"}
                        or voice._activation_id is not None)))

    def observe(self, device):
        self.desired = copy.deepcopy(device)
        self.flush()

    def flush(self):
        window = self.window
        if self.pending is not None:
            if not self.scope_matches(self.pending):
                self.retire(reset=True)
            elif self.pending.snapshot is not None and self.pending.layout is not None:
                self.apply()
            return
        if self.desired is None or self.desired == self.applied or self.retry_required:
            return
        updater = getattr(window.client, "update_device", None)
        if not callable(updater):
            return
        if not self.supported or window.active_chat is None:
            if updater(self.desired) is not False:
                self.applied = copy.deepcopy(self.desired)
            return
        continuity = window._continuity
        if (window._rendered_snapshot is None or window._rendered_snapshot is not continuity.committed_snapshot
                or (continuity.request_generation is not None and not continuity.request_completed)
                or self.busy()):
            self.deferred.start()
            return
        connection = getattr(window.client, "connection_generation", None)
        owner = window._resume_store.storage_key
        if not connection or not owner or not getattr(window.client, "authenticated", False):
            return
        generation, submission = str(uuid.uuid4()), str(uuid.uuid4())
        continuity.open_request("hydration", generation, expected_render_revision=continuity.last_committed_render_revision)
        window.client.begin_conversation_request("hydration", window.active_chat, generation)
        request = RefreshRequest(window.client, owner, window.active_chat, connection,
                                 generation, submission, continuity.last_committed_render_revision,
                                 copy.deepcopy(self.desired))
        self.pending = request
        self.timeout.start()
        if not updater(request.device, chat_id=request.chat, base_render_revision=request.revision,
                       request_generation=generation, submission_id=submission,
                       is_current=lambda: self.scope_matches(request)):
            self.fail()

    def accept(self, frame):
        if self.pending is not None and not self.scope_matches(self.pending):
            self.retire(reset=True)
        kind = frame.get("type")
        scoped = any(key in frame for key in ("chat_id", "connection_generation", "request_generation"))
        if kind == "rote_config" and not scoped:
            self.supported = frame.get("viewport_snapshot_supported") is True
            if self.pending is not None:
                return True
            return False
        request = self.pending
        matches = (request is not None and self.scope_matches(request)
                   and frame.get("chat_id") == request.chat
                   and frame.get("connection_generation") == request.connection
                   and frame.get("request_generation") == request.generation)
        if (kind == "error" and request is not None and self.scope_matches(request)
                and frame.get("submission_id") == request.submission and frame.get("accepted") is False):
            self.fail()
            return True
        if kind == "rote_config":
            if matches:
                profile = frame.get("device_profile")
                layout = parse_console_presentation(profile.get("console") if isinstance(profile, dict) else None)
                if (layout is None or frame.get("viewport_snapshot_supported") is not True
                        or request.layout is not None and request.layout != layout):
                    self.fail()
                else:
                    request.layout = layout
                    self.apply()
            return True
        if kind == "error" and frame.get("code") in {"viewport_snapshot_rejected", "viewport_snapshot_retryable"}:
            if matches:
                self.fail()
            return True
        if kind != "conversation_snapshot" or not matches:
            return False
        try:
            snapshot = ConversationSnapshot.from_dict(frame)
            if snapshot.snapshot_purpose != "hydration" or snapshot.render_revision != request.revision:
                raise WindowsProtocolError("Viewport revision does not match")
        except (WindowsProtocolError, TypeError, ValueError):
            self.fail()
            return True
        if request.snapshot is not None and request.snapshot != frame:
            self.fail()
            return True
        request.snapshot = copy.deepcopy(frame)
        self.apply()
        return True

    def apply(self):
        request = self.pending
        if request is None or request.layout is None or request.snapshot is None:
            return
        if not self.scope_matches(request):
            self.retire(reset=True)
            return
        if self.busy():
            self.deferred.start()
            return
        window = self.window
        staged = QWidget()
        staged_rail = QWidget()
        widgets = []
        messages = []
        rail_state = None
        try:
            saved = capture_controls(window.canvas._inner, strict=True)
            selected_canvas = capture_selections(window.canvas._inner)
            canvas_focus = capture_focus(window.canvas._inner)
            for component in request.snapshot["canvas"]["components"]:
                widget = render(component, window.canvas.ctx, top_level=True)
                widget.setParent(staged)
                widgets.append(widget)
            restore_controls(staged, saved, strict=True)
            restore_selections(staged, selected_canvas)
            focus_target(staged, canvas_focus)
            if request.snapshot["transcript"] != window._rendered_snapshot.transcript:
                rail_state = capture_controls(window.rail, strict=True)
                selections = capture_selections(window.rail)
                for message in decode_semantic_transcript(request.snapshot["transcript"]):
                    bubble = window.rail._semantic_bubble(message, window.canvas.ctx)
                    bubble.setParent(staged_rail)
                    messages.append((bubble, message.role))
                restore_controls(staged_rail, rail_state, strict=True)
                restore_selections(staged_rail, selections)
        except (ControlIdentityError, RuntimeError, ValueError, TypeError):
            staged.deleteLater()
            staged_rail.deleteLater()
            self.fail()
            return
        disposition = window._continuity.reduce_snapshot(request.snapshot)
        if disposition != "snapshot_applied":
            staged.deleteLater()
            staged_rail.deleteLater()
            self.fail()
            return
        areas = [window.canvas, window.rail._scroll]
        shell = window._console_shell
        if shell is not None:
            areas.extend((shell.scroll, shell.agent_scroll, shell.history_scroll, shell.categories_scroll))
        scrolls = [(area, area.verticalScrollBar().value(), area.horizontalScrollBar().value()) for area in areas]
        window.canvas.replace_prepared(request.snapshot["canvas"]["components"], widgets)
        if rail_state is not None:
            window.rail.clear()
            for bubble, role in messages:
                window.rail._insert_bubble(bubble, role)
        staged.deleteLater()
        staged_rail.deleteLater()
        window._rendered_snapshot = window._continuity.committed_snapshot
        window._console_presentation = request.layout
        window._show_console()
        restore_controls(window.canvas._inner, saved, strict=True)
        restore_selections(window.canvas._inner, selected_canvas)
        focused = focus_target(window.canvas._inner, canvas_focus)
        if focused is not None:
            focused.setFocus()
        if rail_state is not None:
            restore_controls(window.rail, rail_state, strict=True)
        for area, vertical, horizontal in scrolls:
            area.verticalScrollBar().setValue(vertical)
            area.horizontalScrollBar().setValue(horizontal)
        self.applied = request.device
        self.pending = None
        self.timeout.stop()
        self.deferred.stop()
        window._sync_console_conversation()
        accepted = window._rendered_snapshot

        def restore_scroll():
            if (window._rendered_snapshot is accepted and window.client is request.client
                    and window.active_chat == request.chat
                    and window._resume_store.storage_key == request.owner
                    and getattr(window.client, "connection_generation", None) == request.connection):
                for area, vertical, horizontal in scrolls:
                    area.verticalScrollBar().setValue(vertical)
                    area.horizontalScrollBar().setValue(horizontal)

        QTimer.singleShot(0, self, restore_scroll)
        if self.desired != self.applied:
            self.deferred.start()
