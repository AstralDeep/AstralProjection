"""Native composite widgets consume the shared primitive schemas through renderer.py.
Charts use Qt painting and expose their values as accessible text using theme roles.
"""

from __future__ import annotations

import copy
import math

from PySide6.QtCore import QPointF, QRect, QRectF, QSize, Qt
from PySide6.QtGui import QColor, QPainter, QPen, QPolygonF
from PySide6.QtWidgets import (
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QLayout,
    QPushButton,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from . import theme as T


def _text(value) -> str:
    return "" if value is None else str(value)


def _list(value, limit=128) -> list:
    if value is None:
        return []
    if not isinstance(value, list) or len(value) > limit:
        raise ValueError("Invalid or excessive collection")
    return value


def _number(value) -> float:
    if isinstance(value, bool):
        raise ValueError("Invalid numeric value")
    try:
        result = float(value)
    except (TypeError, ValueError, OverflowError) as exc:
        raise ValueError("Invalid numeric value") from exc
    if not math.isfinite(result):
        raise ValueError("Non-finite numeric value")
    return result


def _variant(value) -> str:
    key = _text(value).strip().lower()
    return key if key in T.VARIANT_COLORS else "default"


def _state_color(variant):
    return T.ACCENT if variant == "info" else T.VARIANT_COLORS[variant][0]


def _label(text, *, muted=False, bold=False, size=13) -> QLabel:
    label = QLabel(_text(text))
    label.setTextFormat(Qt.TextFormat.PlainText)
    label.setWordWrap(True)
    label.setTextInteractionFlags(
        Qt.TextInteractionFlag.TextSelectableByMouse
        | Qt.TextInteractionFlag.TextSelectableByKeyboard
    )
    label.setSizePolicy(QSizePolicy.Policy.Preferred, QSizePolicy.Policy.Preferred)
    label.setStyleSheet(
        f"color:{T.MUTED if muted else T.TEXT};font-size:{size}px;"
        f"font-weight:{600 if bold else 400};background:transparent;"
    )
    return label


def _box(title="") -> QWidget:
    widget = QWidget()
    layout = QVBoxLayout(widget)
    layout.setContentsMargins(0, 0, 0, 0)
    layout.setSpacing(8)
    widget.setAccessibleName(_text(title))
    if title:
        layout.addWidget(_label(title, bold=True, size=14))
    return widget


def _legend(text, color, *, muted=True, dot=False) -> QWidget:
    widget = QWidget()
    layout = QHBoxLayout(widget)
    layout.setContentsMargins(0, 0, 0, 0)
    layout.setSpacing(8 if dot else 4)
    swatch = QFrame()
    swatch.setFixedSize(8 if dot else 10, 8 if dot else 10)
    swatch.setStyleSheet(f"background:{color};border:none;border-radius:{4 if dot else 2}px;")
    label = _label(text, muted=muted, size=12 if dot else 11)
    label.setToolTip(text)
    layout.addWidget(swatch)
    layout.addWidget(label, 1)
    widget.setAccessibleName(text)
    return widget


class FlowLayout(QLayout):
    def __init__(self, parent=None, align="start"):
        super().__init__(parent)
        self.items = []
        self.flow_align = align
        self.setContentsMargins(0, 0, 0, 0)
        self.setSpacing(8)

    def addItem(self, item):
        self.items.append(item)

    def count(self):
        return len(self.items)

    def itemAt(self, index):
        return self.items[index] if 0 <= index < len(self.items) else None

    def takeAt(self, index):
        return self.items.pop(index) if 0 <= index < len(self.items) else None

    def expandingDirections(self):
        return Qt.Orientation(0)

    def hasHeightForWidth(self):
        return True

    def heightForWidth(self, width):
        return self._arrange(QRect(0, 0, width, 0), False)

    def minimumSize(self):
        return QSize(0, max((i.sizeHint().height() for i in self.items), default=0))

    def sizeHint(self):
        return QSize(320, self.heightForWidth(320))

    def setGeometry(self, rect):
        super().setGeometry(rect)
        self._arrange(rect, True)

    def _arrange(self, rect, apply):
        width = max(1, rect.width())
        rows = [[]]
        used = 0
        for item in self.items:
            item_width = min(width, max(1, item.sizeHint().width()))
            if rows[-1] and used + self.spacing() + item_width > width:
                rows.append([])
                used = 0
            rows[-1].append((item, item_width))
            used += item_width + (self.spacing() if len(rows[-1]) > 1 else 0)
        y = rect.y()
        for row in rows:
            if not row:
                continue
            available = width - sum(w for _, w in row) - self.spacing() * (len(row) - 1)
            x = rect.x() + (available // 2 if self.flow_align == "center" else
                            available if self.flow_align == "end" else 0)
            gap = self.spacing()
            if self.flow_align == "between" and len(row) > 1:
                gap += available // (len(row) - 1)
            height = max(
                item.heightForWidth(item_width) if item.hasHeightForWidth()
                else item.sizeHint().height()
                for item, item_width in row
            )
            for item, item_width in row:
                if apply:
                    item.setGeometry(QRect(x, y, item_width, height))
                x += item_width + gap
            y += height + self.spacing()
        return max(0, y - rect.y() - self.spacing())


class StatGrid(QWidget):
    def __init__(self, items, columns):
        super().__init__()
        self.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        self.cells = items
        self.columns = columns
        self.current_columns = 0
        layout = QGridLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(8)
        self._reflow(320)

    def _reflow(self, width):
        columns = min(self.columns, max(1, (width + 8) // 168))
        if columns == self.current_columns:
            return
        for column in range(self.columns):
            self.layout().setColumnStretch(column, int(column < columns))
        for index, cell in enumerate(self.cells):
            self.layout().addWidget(cell, index // columns, index % columns)
        self.current_columns = columns

    def resizeEvent(self, event):
        self._reflow(event.size().width())
        super().resizeEvent(event)


def action_group(component, context):
    widget = _box()
    name = _text(component.get("label"))
    widget.setAccessibleName(name)
    if name:
        widget.layout().addWidget(_label(name, muted=True, size=12))
    row = QWidget()
    layout = FlowLayout(row, _text(component.get("align")))
    buttons = _list(component.get("buttons"))
    for item in buttons:
        if not isinstance(item, dict):
            raise ValueError("Invalid button")
        name = _text(item.get("label")) or "Action"
        button = QPushButton(name.replace("&", "&&"))
        button.setAccessibleName(name)
        button.setToolTip(name)
        button.setMinimumHeight(36)
        button.setCursor(Qt.CursorShape.PointingHandCursor)
        variant = _text(item.get("variant") or "primary")
        button.setObjectName(variant if variant in {"primary", "secondary", "ghost", "danger"} else "primary")
        action, payload = item.get("action"), item.get("payload", {})
        valid = isinstance(action, str) and bool(action.strip()) and isinstance(payload, dict)
        enabled = valid and not bool(item.get("disabled")) and not bool(component.get("disabled"))
        button.setEnabled(enabled)
        button.setStyleSheet(
            "QPushButton{padding:8px 16px;font-size:14px;font-weight:500;border-radius:8px;}"
            f"QPushButton:disabled{{background:{T._rgba(T.TEXT, 0.05)};"
            f"border:1px solid {T.BORDER};color:{T.MUTED};}}"
        )
        if valid:
            saved = copy.deepcopy(payload)
            button.clicked.connect(lambda checked=False, a=action, p=saved: context.emit(a, copy.deepcopy(p)))
        else:
            button.setToolTip("Action unavailable. Request refreshed data.")
            button.setAccessibleDescription(button.toolTip())
        layout.addWidget(button)
    widget.layout().addWidget(row)
    if not buttons:
        widget.layout().addWidget(_label("No actions available.", muted=True))
    return widget


def stat_group(component, context):
    widget = _box(component.get("title"))
    try:
        columns = max(1, min(6, int(component.get("columns", 4))))
    except (TypeError, ValueError, OverflowError):
        columns = 4
    cells = []
    for item in _list(component.get("items")):
        if not isinstance(item, dict):
            raise ValueError("Invalid statistic")
        cell = QFrame()
        cell.setObjectName("statCell")
        cell.setStyleSheet(
            f"QFrame#statCell{{background:{T._rgba(T.TEXT, 0.05)};"
            f"border:1px solid {T.BORDER};border-radius:8px;}}"
        )
        layout = QVBoxLayout(cell)
        layout.setContentsMargins(12, 12, 12, 12)
        layout.setSpacing(0)
        label, value = _text(item.get("label")), _text(item.get("value"))
        layout.addWidget(_label(label, muted=True, size=12))
        readout = QWidget()
        readout_layout = FlowLayout(readout)
        readout_layout.setSpacing(4)
        readout_layout.addWidget(_label(value, bold=True, size=18))
        details = [label, value]
        if item.get("delta") is not None:
            trend = _text(item.get("trend")).lower()
            glyph = {"up": "▲", "down": "▼", "flat": "–"}.get(trend, "")
            delta = _label(f"{glyph} {_text(item['delta'])}".strip(), size=12)
            delta.setStyleSheet(f"color:{_state_color(_variant(item.get('variant')))};font-size:12px;")
            delta.setAccessibleName(f"{trend} {_text(item['delta'])}".strip())
            readout_layout.addWidget(delta)
            details.append(delta.accessibleName())
        layout.addWidget(readout)
        if item.get("hint"):
            layout.addWidget(_label(item["hint"], muted=True, size=11))
            details.append(_text(item["hint"]))
        cell.setAccessibleName(": ".join(details))
        cells.append(cell)
    widget.layout().addWidget(StatGrid(cells, columns))
    if not cells:
        widget.layout().addWidget(_label("No statistics available.", muted=True))
    return widget


def pipeline_stepper(component, context):
    widget = _box(component.get("title"))
    content = QWidget()
    vertical = _text(component.get("orientation")).lower() == "vertical"
    layout = QVBoxLayout(content) if vertical else FlowLayout(content)
    layout.setContentsMargins(0, 0, 0, 0)
    layout.setSpacing(12)
    current = False
    statuses = {"done": "success", "active": "info", "pending": "default", "error": "error"}
    steps = _list(component.get("steps"))
    for item in steps:
        if not isinstance(item, dict):
            raise ValueError("Invalid step")
        status = _text(item.get("status") or "pending").strip().lower()
        status = status if status in statuses else "pending"
        variant = statuses[status]
        name = _text(item.get("label"))
        step = QWidget()
        step_layout = QHBoxLayout(step)
        step_layout.setContentsMargins(0, 0, 0, 0)
        step_layout.setSpacing(8)
        step.setAccessibleName(f"{name}: {status}")
        step.setProperty("status", status)
        step.setProperty("current_step", status == "active" and not current)
        current = current or status == "active"
        color = T._rgba(T.TEXT, 0.25) if status == "pending" else _state_color(variant)
        heading = _legend(name, color, muted=False, dot=True)
        step_layout.addWidget(heading)
        if item.get("detail"):
            step_layout.addWidget(_label(item["detail"], muted=True, size=11))
            step.setAccessibleDescription(_text(item["detail"]))
        layout.addWidget(step)
    widget.layout().addWidget(content)
    if not steps:
        widget.layout().addWidget(_label("No steps available.", muted=True))
    return widget


class PrimitivePlot(QWidget):
    def __init__(self, kind, values, *, scale=1, variant="default"):
        super().__init__()
        self.kind, self.values, self.scale, self.variant = kind, values, scale, variant
        self.setFixedHeight({"gauge": 72, "donut_chart": 160}.get(kind, 192))
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)

    def sizeHint(self):
        return QSize({"gauge": 128, "donut_chart": 160}.get(self.kind, 192), self.height())

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        if self.kind == "gauge":
            diameter = min(102.4, max(1.0, self.width() - 20.0))
            rect = QRectF((self.width() - diameter) / 2, 12.8, diameter, diameter)
            painter.setPen(QPen(QColor(T._mix(T.SURFACE, T.TEXT, 0.12)), 10.24,
                                Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
            painter.drawArc(rect, 0, 180 * 16)
            painter.setPen(QPen(QColor(_state_color(self.variant)), 10.24,
                                Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
            painter.drawArc(rect, 180 * 16, -round(self.values[0] * 180 * 16))
        else:
            ratio = 0.8 if self.kind == "donut_chart" else 0.9
            size = min(128.0 if self.kind == "donut_chart" else 172.8,
                       max(1.0, self.width() * ratio))
            rect = QRectF((self.width() - size) / 2, (self.height() - size) / 2, size, size)
            if self.kind == "donut_chart":
                self._donut(painter, rect)
            else:
                self._radar(painter, rect)
        painter.end()

    def _donut(self, painter, rect):
        palette = _palette()
        largest = max(self.values, default=0)
        normalized = [v / largest for v in self.values] if largest else []
        total = sum(normalized)
        offset = 90 * 16
        for index, value in enumerate(normalized):
            span = -round(360 * 16 * value / total)
            painter.setPen(QPen(QColor(palette[index % len(palette)]), 22.4))
            painter.drawArc(rect, offset, span)
            offset += span

    def _radar(self, painter, rect):
        center, radius = rect.center(), rect.width() / 2
        painter.setPen(QPen(QColor(T._mix(T.SURFACE, T.TEXT, 0.15)), 0.96))
        for fraction in (12 / 45, 24 / 45, 36 / 45, 1):
            painter.drawEllipse(center, radius * fraction, radius * fraction)
        count = len(self.values[0])
        vectors = [QPointF(math.cos(2 * math.pi * i / count - math.pi / 2),
                          math.sin(2 * math.pi * i / count - math.pi / 2)) for i in range(count)]
        for index, row in enumerate(self.values):
            color = QColor(_palette()[index % 6])
            painter.setPen(QPen(color, 2.88))
            color.setAlphaF(0.28)
            painter.setBrush(color)
            polygon = QPolygonF([center + vector * (radius * min(1, value / self.scale))
                                 for vector, value in zip(vectors, row)])
            painter.drawPolygon(polygon)


def _palette():
    colors = [T.PRIMARY, T.SECONDARY, T.ACCENT]
    return colors + [T._mix(color, "#FFFFFF", 0.45) for color in colors]


def gauge(component, context):
    value = max(0, min(1, _number(component.get("value", 0))))
    variant = "default"
    for threshold in _list(component.get("thresholds")):
        if not isinstance(threshold, dict):
            raise ValueError("Invalid threshold")
        if value >= max(0, min(1, _number(threshold.get("at", 0)))):
            variant = _variant(threshold.get("variant"))
    display = _text(component.get("display_value")) or f"{round(value * 100)}%"
    name = _text(component.get("label"))
    widget = _box()
    widget.layout().setSpacing(4)
    widget.setAccessibleName(f"{name}: {display}" if name else display)
    plot = PrimitivePlot("gauge", [value], variant=variant)
    plot.setAccessibleName(widget.accessibleName())
    widget.layout().addWidget(plot)
    for text, muted, size in ((display, False, 18), (name, True, 12),
                              (component.get("subtitle"), True, 11)):
        if text:
            label = _label(text, muted=muted, bold=not muted, size=size)
            label.setAlignment(Qt.AlignmentFlag.AlignCenter)
            widget.layout().addWidget(label)
    return widget


def donut_chart(component, context):
    values = [max(0, _number(v)) for v in _list(component.get("data"))]
    labels = _list(component.get("labels"))
    widget = _box(component.get("title"))
    if not values:
        widget.layout().addWidget(_label("No chart data available.", muted=True))
        return widget
    plot = PrimitivePlot("donut_chart", values)
    plot.setFixedWidth(160)
    center = [_text(component.get(k)) for k in ("center_value", "center_label")]
    if any(center):
        overlay = QVBoxLayout(plot)
        overlay.setContentsMargins(24, 24, 24, 24)
        overlay.setSpacing(0)
        overlay.setAlignment(Qt.AlignmentFlag.AlignCenter)
        for index, text in enumerate(center):
            label = _label(text, bold=index == 0, muted=index == 1, size=18 if index == 0 else 11)
            label.setAlignment(Qt.AlignmentFlag.AlignCenter)
            overlay.addWidget(label)
    widget.layout().addWidget(plot, alignment=Qt.AlignmentFlag.AlignLeft)
    descriptions = []
    legend = QWidget()
    legend_layout = FlowLayout(legend)
    for index, value in enumerate(values):
        name = _text(labels[index]) if index < len(labels) else f"series {index + 1}"
        summary = f"{name or f'series {index + 1}'}: {value:g}"
        legend_layout.addWidget(_legend(name or f"series {index + 1}", _palette()[index % 6]))
        descriptions.append(summary)
    widget.layout().addWidget(legend)
    plot.setAccessibleName(f"Donut chart: {_text(component.get('title'))}")
    plot.setAccessibleDescription("; ".join(descriptions))
    if not any(values):
        widget.layout().addWidget(_label("Total is zero.", muted=True))
    return widget


def radar_chart(component, context):
    axes = [_text(a) for a in _list(component.get("axes"), 32)]
    datasets = _list(component.get("datasets"), 32)
    widget = _box(component.get("title"))
    if len(axes) < 3 or not datasets:
        widget.layout().addWidget(_label("Radar chart requires at least three axes and one dataset.", muted=True))
        return widget
    rows, names = [], []
    for index, dataset in enumerate(datasets):
        if not isinstance(dataset, dict):
            raise ValueError("Invalid dataset")
        data = [max(0, _number(v)) for v in _list(dataset.get("data"))]
        rows.append((data + [0] * len(axes))[:len(axes)])
        names.append(_text(dataset.get("label")) or f"series {index + 1}")
    observed = max(max(row) for row in rows)
    declared = component.get("max_value")
    scale = _number(declared) if declared is not None else observed
    scale = scale if scale > 0 else observed or 1
    plot = PrimitivePlot("radar_chart", rows, scale=scale)
    plot.setFixedWidth(192)
    plot.setAccessibleName(f"Radar chart: {_text(component.get('title'))}")
    widget.layout().addWidget(plot, alignment=Qt.AlignmentFlag.AlignLeft)
    descriptions = []
    legend = QWidget()
    legend_layout = FlowLayout(legend)
    for index, (name, row) in enumerate(zip(names, rows)):
        description = f"{name}: " + ", ".join(f"{axis or f'axis {i + 1}'} {value:g}" for i, (axis, value) in enumerate(zip(axes, row)))
        entry = _legend(name, _palette()[index % 6])
        entry.setAccessibleDescription(description)
        entry.setToolTip(description)
        legend_layout.addWidget(entry)
        descriptions.append(description)
    widget.layout().addWidget(legend)
    plot.setAccessibleDescription("; ".join(descriptions))
    return widget


BUILDERS = {"action_group": action_group, "stat_group": stat_group, "gauge": gauge,
            "pipeline_stepper": pipeline_stepper, "donut_chart": donut_chart, "radar_chart": radar_chart}


def build_composite(component, context):
    try:
        return BUILDERS[component["type"]](component, context)
    except ValueError:
        widget = _box(component.get("title") or component.get("label"))
        message = "Unable to display this component because its data is invalid. Request refreshed data."
        widget.layout().addWidget(_label(message, muted=True))
        widget.setAccessibleDescription(message)
        return widget
