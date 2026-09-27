"""Adapt recognized server-owned settings rows into compact native presentation.
Unrecognized component structures fall back to renderer.py without losing actions or content.
"""

from copy import deepcopy
from html import escape

from PySide6.QtCore import Qt
from PySide6.QtWidgets import QFrame, QHBoxLayout, QLabel, QPushButton, QSizePolicy, QVBoxLayout, QWidget

from . import theme as T
from .composites import FlowLayout
from .typography import Paragraph


class _NaturalWidthLabel(Paragraph):
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
    label = QLabel(text)
    label.setTextFormat(Qt.TextFormat.PlainText)
    label.setWordWrap(True)
    label.setIndent(0)
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
    title = _NaturalWidthLabel(component["title"], 20)
    title.setObjectName("settingsAgentTitle")
    title.setStyleSheet(f"background:transparent;color:{T.TEXT};font-size:14px;font-weight:500;")
    headings.addWidget(title)
    statuses = [badge for badge in badges if badge.get("variant") == "success"]
    status = statuses[0] if len(statuses) == 1 else None
    for badge in badges:
        if badge is status:
            continue
        variant = badge.get("variant", "default")
        color = T.PRIMARY if variant == "accent" else T.VARIANT_COLORS.get(variant, (T.MUTED, ""))[0] if variant != "default" else T.MUTED
        label = _label(badge["label"], color, 10)
        label.setObjectName("settingsAgentBadge")
        label.setStyleSheet(f"color:{color};background:{T._rgba(color, 0.10)};border:1px solid {T._rgba(color, 0.25)};border-radius:3px;padding:2px 6px;font-size:10px;font-weight:500;")
        label.setMinimumHeight(21)
        headings.addWidget(label)
    body.addWidget(heading)
    text = " ".join(description["content"].split())
    snippet = text if len(text) <= 110 else text[:109].rstrip() + "…"
    summary = Paragraph(snippet, 16)
    summary.setObjectName("settingsAgentDescription")
    summary.setStyleSheet(f"background:transparent;color:{T.MUTED};font-size:12px;")
    summary.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
    body.addWidget(summary)
    layout.addWidget(opener, 1)
    actions = QWidget()
    actions_layout = QHBoxLayout(actions)
    actions_layout.setContentsMargins(0, 0, 0, 0)
    actions_layout.setSpacing(8)
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
        actions_layout.addWidget(status_box)
    toggle = _button(enabled, context)
    toggle.setObjectName("settingsAgentToggle")
    actions_layout.addWidget(toggle)
    layout.addWidget(actions)
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


def _detail_text(text, *, size=14, line_height=22.4, heading=False):
    content = text.upper() if heading else text
    markup = escape(content).replace("\r\n", "\n").replace("\r", "\n").replace("\n", "<br>")
    label = QLabel(f'<p style="line-height:{line_height}px;margin:0;white-space:pre-wrap">{markup}</p>')
    label.setTextFormat(Qt.TextFormat.RichText)
    label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse | Qt.TextInteractionFlag.TextSelectableByKeyboard)
    label.setWordWrap(True)
    label.setAccessibleName(content)
    label.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop)
    color = T.MUTED if size == 12 else T._mix(T.BG, T.TEXT, 0.78)
    label.setStyleSheet(f"color:{color};font-size:{size}px;font-weight:{700 if heading else 400};background:transparent;")
    if heading:
        font = label.font()
        font.setLetterSpacing(font.SpacingType.AbsoluteSpacing, 0.72)
        label.setFont(font)
    return label


def _detail_button(source, context, height=30):
    control = _button(source, context)
    primary = source.get("variant") == "primary"
    padding = 14 if height == 32 else 12
    control.setStyleSheet(
        f"QPushButton{{font-size:12px;font-weight:500;padding:0 {padding}px;border:{0 if primary else 1}px solid {T._rgba(T.TEXT,0.10)};border-radius:7px;color:{T.TEXT};background:{T.GRAD if primary else T._rgba(T.TEXT,0.05)};}}"
        f"QPushButton:focus{{border-color:{T.PRIMARY};}}"
        f"QPushButton:disabled{{color:{T.MUTED};background:{T._rgba(T.TEXT,0.03)};}}"
    )
    control.setFixedHeight(height)
    return control


def _detail_stack(spacing=16):
    widget = QWidget()
    layout = QVBoxLayout(widget)
    layout.setContentsMargins(0, 0, 0, 0)
    layout.setSpacing(spacing)
    return widget, layout


def _plain_text(component, variant):
    return (isinstance(component, dict) and component.get("type") == "text"
            and component.get("variant", "body") == variant and isinstance(component.get("content"), str))


def _intro_example_parts(component):
    children = _children(component)
    if (component.get("type") != "card" or not isinstance(component.get("title"), str)
            or not isinstance(component.get("disabled", False), bool) or len(children) != 2
            or not _plain_text(children[0], "body") or children[1].get("type") != "container"
            or children[1].get("direction") != "row"):
        return None
    actions = _children(children[1])
    if (len(actions) != 2 or not _action(actions[0], "chat_message")
            or not _action(actions[1], "compose_prompt")
            or any(action["payload"].get("message") != children[0]["content"] for action in actions)):
        return None
    return children[0], actions


def _intro_example(component, context, compact):
    description, actions = _intro_example_parts(component)
    card = QFrame()
    card.setObjectName("agentIntroExample")
    card.setEnabled(not component.get("disabled", False))
    card.setProperty("component_id", component.get("component_id") or component.get("id"))
    card.setStyleSheet(f"QFrame#agentIntroExample{{background:{T._rgba(T.SURFACE,0.55)};border:1px solid {T._rgba(T.TEXT,0.08)};border-radius:10px;}}")
    layout = QVBoxLayout(card) if compact else QHBoxLayout(card)
    layout.setContentsMargins(14, 12, 14, 12)
    layout.setSpacing(12)
    copy, text_layout = _detail_stack(3)
    title = _detail_text(component["title"], line_height=21)
    title.setStyleSheet(f"color:{T.TEXT};font-size:14px;font-weight:600;background:transparent;")
    text_layout.addWidget(title)
    text_layout.addWidget(_detail_text(description["content"], size=12, line_height=18))
    layout.addWidget(copy, 1)
    controls = QWidget()
    control_layout = QHBoxLayout(controls)
    control_layout.setContentsMargins(0, 0, 0, 0)
    control_layout.setSpacing(6)
    for action in actions:
        control_layout.addWidget(_detail_button(action, context))
    layout.addWidget(controls, 0, Qt.AlignmentFlag.AlignLeft if compact else Qt.AlignmentFlag.AlignVCenter)
    return card


def adapt_detail_components(surface, params, components, context, compact=False):
    if not isinstance(params, dict) or not isinstance(components, list) or not all(isinstance(item, dict) for item in components):
        return None
    if surface == "guidance" and params.get("view") == "selection":
        if (len(components) != 8 or not _plain_text(components[0], "body")
                or not all(_plain_text(components[index], "h3") and _plain_text(components[index+1], "caption") for index in (1, 3, 5))
                or not _action(components[7], "chrome_open")
                or components[7]["payload"] != {"surface": "guidance", "params": {"view": "selection"}}):
            return None
        widget, layout = _detail_stack(0)
        layout.addWidget(_detail_text(components[0]["content"]))
        layout.addSpacing(22)
        for index in (1, 3, 5):
            layout.addWidget(_detail_text(components[index]["content"], size=12, line_height=18, heading=True))
            layout.addSpacing(16)
            layout.addWidget(_detail_text(components[index+1]["content"], size=12, line_height=16.8))
            layout.addSpacing(28 if index < 5 else 17)
        layout.addWidget(_detail_button(components[7], context, 32), 0, Qt.AlignmentFlag.AlignLeft)
        return widget
    if surface != "agent_intro" or len(components) < 7:
        return None
    badge, description, heading = components[:3]
    tools_heading, tools, permissions = components[-3:]
    examples = components[3:-3]
    if (badge.get("type") != "badge" or not isinstance(badge.get("label"), str)
            or not isinstance(badge.get("variant", "default"), str)
            or badge.get("variant", "default") not in {"default", "success"}
            or not _plain_text(description, "body") or not _plain_text(heading, "h3")
            or not examples or any(_intro_example_parts(example) is None for example in examples)
            or not _plain_text(tools_heading, "h3") or tools.get("type") != "list"
            or tools.get("ordered", False) or not isinstance(tools.get("items"), list)
            or not all(isinstance(item, str) for item in tools["items"])
            or not _action(permissions, "chrome_open") or permissions["payload"].get("surface") != "agents"):
        return None
    widget, layout = _detail_stack()
    layout.setContentsMargins(0, 3, 0, 0)
    state = _label(badge["label"], T.ACCENT if badge.get("variant") == "success" else T.MUTED, 11)
    state.setWordWrap(False)
    state.setStyleSheet(f"font-size:11px;font-weight:600;color:{T.ACCENT if badge.get('variant') == 'success' else T.MUTED};background:{T._rgba(T.PRIMARY,0.18)};border:1px solid {T._rgba(T.PRIMARY,0.4)};border-radius:10px;padding:2px 8px;")
    state.setFixedHeight(21)
    layout.addWidget(state, 0, Qt.AlignmentFlag.AlignLeft)
    layout.addWidget(_detail_text(description["content"]))
    examples_widget, examples_layout = _detail_stack(8)
    examples_layout.addWidget(_detail_text(heading["content"], size=12, line_height=18, heading=True))
    for example in examples:
        examples_layout.addWidget(_intro_example(example, context, compact))
    layout.addWidget(examples_widget)
    tools_widget, tools_layout = _detail_stack(8)
    tools_layout.addWidget(_detail_text(tools_heading["content"], size=12, line_height=18, heading=True))
    chips = QWidget()
    chip_layout = FlowLayout(chips)
    chip_layout.setSpacing(6)
    for item in tools["items"]:
        chip = _label(item, T._mix(T.BG,T.TEXT,0.78), 12)
        chip.setWordWrap(False)
        chip.setStyleSheet(f"color:{T._mix(T.BG,T.TEXT,0.78)};font-size:12px;padding:3px 9px;border:1px solid {T._rgba(T.TEXT,0.12)};border-radius:13px;background:{T._rgba(T.SURFACE,0.6)};")
        chip.setFixedHeight(26)
        chip_layout.addWidget(chip)
    tools_layout.addWidget(chips)
    layout.addWidget(tools_widget)
    permission_widget, permission_layout = _detail_stack(0)
    permission_layout.setContentsMargins(0, 4, 0, 0)
    permission_layout.addWidget(_detail_button(permissions, context), 0, Qt.AlignmentFlag.AlignLeft)
    layout.addWidget(permission_widget)
    return widget
