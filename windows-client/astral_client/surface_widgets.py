"""Adapt recognized server-owned settings rows into compact native presentation.
Unrecognized component structures fall back to renderer.py without losing actions or content.
"""

from copy import deepcopy

from PySide6.QtCore import Qt
from PySide6.QtWidgets import QFrame, QHBoxLayout, QLabel, QPushButton, QSizePolicy, QVBoxLayout, QWidget

from . import theme as T
from .composites import FlowLayout


class _NaturalWidthLabel(QLabel):
    def sizeHint(self):
        size = super().sizeHint()
        size.setWidth(self.fontMetrics().horizontalAdvance(self.text()) + 1)
        return size


def _children(component):
    children = component.get("content", component.get("children"))
    return children if isinstance(children, list) and all(isinstance(item, dict) for item in children) else []


def _action(component, action):
    return (component.get("type") == "button" and component.get("action") == action
            and isinstance(component.get("label"), str) and isinstance(component.get("payload"), dict)
            and isinstance(component.get("disabled", False), bool))


def _button(source, context, title=None):
    button = QPushButton(str(title if title is not None else source["label"]).replace("&", "&&"))
    button.setAutoDefault(False)
    button.setCursor(Qt.CursorShape.PointingHandCursor)
    button.setAccessibleName(source["label"] if title is None else f"{source['label']}: {title}")
    button.setEnabled(not source.get("disabled", False))
    payload = deepcopy(source["payload"])
    button.clicked.connect(lambda: context.emit(source["action"], deepcopy(payload)))
    return button


def _label(text, color, size):
    label = _NaturalWidthLabel(text)
    label.setTextFormat(Qt.TextFormat.PlainText)
    label.setWordWrap(True)
    label.setStyleSheet(f"background:transparent;color:{color};font-size:{size}px;")
    label.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
    return label


def _agent_parts(component):
    if (component.get("type") != "card" or not isinstance(component.get("title"), str)
            or not isinstance(component.get("disabled", False), bool)):
        return None
    children = _children(component)
    if len(children) != 3:
        return None
    descriptions = [child for child in children if child.get("type") == "text" and isinstance(child.get("content"), str)]
    containers = [child for child in children if child.get("type") == "container" and child.get("direction") == "row"]
    if len(descriptions) != 1 or len(containers) != 2:
        return None
    badge_rows = [_children(row) for row in containers
                  if _children(row) and all(item.get("type") == "badge" and isinstance(item.get("label"), str)
                    and isinstance(item.get("variant", "default"), str)
                    and item.get("variant", "default") in {"accent", "default", "success", "warning", "error", "info"}
                    for item in _children(row))]
    actions = [item for row in containers for item in _children(row) if item.get("type") == "button"]
    opened = [item for item in actions if _action(item, "chrome_open") and item["payload"].get("surface") == "agents"]
    enabled = [item for item in actions if _action(item, "chrome_agent_enabled")]
    if (len(badge_rows) != 1 or len(actions) != 2 or len(opened) != 1 or len(enabled) != 1
            or sum(len(_children(row)) for row in containers) != len(badge_rows[0]) + 2):
        return None
    params = opened[0]["payload"].get("params")
    if (not isinstance(params, dict) or not isinstance(params.get("agent_id"), str)
            or not params["agent_id"] or enabled[0]["payload"].get("agent_id") != params["agent_id"]
            or not isinstance(enabled[0]["payload"].get("enabled"), bool)):
        return None
    return descriptions[0], badge_rows[0], opened[0], enabled[0]


def _agent_row(component, context, parts):
    description, badges, opened, enabled = parts
    frame = QFrame()
    frame.setEnabled(not bool(component.get("disabled", False)))
    frame.setObjectName("settingsAgentRow")
    frame.setProperty("component_id", component.get("component_id") or component.get("id"))
    frame.setStyleSheet(
        f"QFrame#settingsAgentRow{{background:{T._rgba(T.TEXT, 0.05)};border:1px solid {T._rgba(T.TEXT, 0.10)};border-radius:8px;}}"
        f"QPushButton#settingsAgentOpen{{padding:0;background:transparent;border:1px solid transparent;text-align:left;}}"
        f"QPushButton#settingsAgentOpen:focus{{border:1px solid {T.PRIMARY};}}"
        f"QPushButton#settingsAgentToggle{{padding:6px 12px;background:{T._rgba(T.TEXT, 0.05)};border:1px solid {T._rgba(T.TEXT, 0.10)};border-radius:8px;font-size:12px;color:{T.TEXT};}}"
        f"QPushButton#settingsAgentToggle:focus{{border-color:{T.PRIMARY};}}"
    )
    layout = QHBoxLayout(frame)
    layout.setContentsMargins(12, 12, 12, 12)
    layout.setSpacing(12)
    opener = _button(opened, context, component["title"])
    opener.setObjectName("settingsAgentOpen")
    opener.setText("")
    opener.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
    opener.setAccessibleDescription(description["content"])
    opener.setToolTip(description["content"])
    body = QVBoxLayout(opener)
    body.setContentsMargins(0, 0, 0, 0)
    body.setSpacing(2)
    heading = QWidget()
    heading.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
    headings = FlowLayout(heading)
    headings.setSpacing(8)
    headings.addWidget(_label(component["title"], T.TEXT, 14))
    statuses = [badge for badge in badges if badge.get("variant") == "success"]
    status = statuses[0] if len(statuses) == 1 else None
    for badge in badges:
        if badge is status:
            continue
        variant = badge.get("variant", "default")
        color = T.PRIMARY if variant == "accent" else T.VARIANT_COLORS.get(variant, (T.MUTED, ""))[0] if variant != "default" else T.MUTED
        label = _label(badge["label"], color, 10)
        label.setStyleSheet(f"color:{color};background:{T._rgba(color, 0.10)};border:1px solid {T._rgba(color, 0.25)};border-radius:3px;padding:2px 6px;font-size:10px;")
        headings.addWidget(label)
    body.addWidget(heading)
    text = " ".join(description["content"].split())
    snippet = text if len(text) <= 110 else text[:109].rstrip() + "…"
    body.addWidget(_label(snippet, T.MUTED, 12))
    layout.addWidget(opener, 1)
    if status is not None:
        status_box = QWidget()
        status_layout = QHBoxLayout(status_box)
        status_layout.setContentsMargins(0, 0, 0, 0)
        status_layout.setSpacing(6)
        dot = QFrame()
        dot.setFixedSize(6, 6)
        dot.setStyleSheet(f"border:none;background:{T.VARIANT_COLORS['success'][0]};border-radius:3px;")
        status_layout.addWidget(dot)
        status_label = _label(status["label"], T.MUTED, 12)
        status_label.setWordWrap(False)
        status_layout.addWidget(status_label)
        layout.addWidget(status_box)
    toggle = _button(enabled, context)
    toggle.setObjectName("settingsAgentToggle")
    layout.addWidget(toggle)
    return frame


def adapt_settings_component(surface, params, component, context):
    if surface != "agents" or not isinstance(params, dict) or params.get("agent_id") or not isinstance(component, dict):
        return None
    parts = _agent_parts(component)
    if parts is not None:
        return _agent_row(component, context, parts)
    children = _children(component)
    if (component.get("type") != "container" or component.get("direction") != "row" or not children
            or not all(_action(child, "chrome_open") and child["payload"].get("surface") in {"agents", "drafts"} for child in children)):
        return None
    widget = QWidget()
    outer = QVBoxLayout(widget)
    outer.setContentsMargins(0, 0, 0, 4)
    row = QWidget()
    outer.addWidget(row)
    layout = FlowLayout(row)
    layout.setSpacing(6)
    for child in children:
        button = _button(child, context)
        button.setStyleSheet(
            f"QPushButton{{padding:6px 12px;border:1px solid {T._rgba(T.TEXT, 0.10)};border-radius:7px;background:{T._rgba(T.TEXT, 0.05)};color:{T.TEXT};font-size:12px;}}"
            f"QPushButton:disabled{{background:{T._rgba(T.PRIMARY, 0.18)};border-color:{T._rgba(T.PRIMARY, 0.40)};color:{T.PRIMARY};}}"
            f"QPushButton:focus{{border-color:{T.PRIMARY};}}"
        )
        layout.addWidget(button)
    return widget
