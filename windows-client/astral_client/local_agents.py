"""Feature 077 — "Agents on this PC": the client-local view of the personal
agents this desktop hosts.

The server's *My agents & skills* surface knows an agent is *running* only as
socket presence; the PC is where the child processes actually live, and until
now the person at it had no list, no status and no Stop — just a transient
banner. This dialog reads :meth:`ByoAgentHost.inventory` (derived, read-only),
refreshes every ``REFRESH_MS`` while open, and offers exactly two acts: **Stop**
(``ByoAgentHost.stop`` — the same kill the server commands) and **Open folder**
(the bundle directory in Explorer, so the LLM-written code is never a mystery).

It is a client-local window, not a server surface: it is reached from a
client-local entry the Settings menu appends after the server-owned groups, and
it exists only when the deployment profile hosts personal agents.
"""

from __future__ import annotations

import os
import subprocess
import sys
from typing import Any, Callable, Dict, List, Optional

from PySide6.QtCore import Qt, QTimer
from PySide6.QtWidgets import (
    QDialog,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QPushButton,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
)

from . import theme as T

REFRESH_MS = 2000
TITLE = "Agents on this PC"

_STATUS_COLOR = {"online": "#22C55E", "starting": "#EAB308", "offline": None}


def open_folder(path: str, opener: Optional[Callable[[str], None]] = None) -> bool:
    """Reveal ``path`` in the platform file manager. Returns False when the
    directory does not exist (never raises into the UI)."""
    if not path or not os.path.isdir(path):
        return False
    try:
        if opener is not None:
            opener(path)
        elif sys.platform == "win32":
            os.startfile(path)  # noqa: S606 — a directory this client wrote
        elif sys.platform == "darwin":
            subprocess.Popen(["open", path])
        else:
            subprocess.Popen(["xdg-open", path])
        return True
    except Exception:  # noqa: BLE001
        return False


class LocalAgentsDialog(QDialog):
    """A live table of the hosted agents with Stop / Open folder."""

    def __init__(self, host, parent=None, *, opener: Optional[Callable[[str], None]] = None) -> None:
        super().__init__(parent)
        self._host = host
        self._opener = opener
        self._rows: List[Dict[str, Any]] = []
        self.setWindowTitle(TITLE)
        self.setMinimumSize(560, 320)
        self.setWindowModality(Qt.WindowModality.NonModal)

        lay = QVBoxLayout(self)
        self.intro = QLabel(
            "These personal agents were built for you and run here, on this computer, as "
            "separate processes. Stop one to end it now (the server will show it offline); "
            "Delete lives in Settings → My agents & skills.")
        self.intro.setWordWrap(True)
        self.intro.setStyleSheet(f"color:{T.MUTED}; font-size:12px;")
        lay.addWidget(self.intro)

        self.table = QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(["Agent", "Status", "Process", "Revision"])
        self.table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QTableWidget.SelectionMode.SingleSelection)
        self.table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.table.verticalHeader().setVisible(False)
        self.table.setAccessibleName("Agents hosted on this computer")
        self.table.itemSelectionChanged.connect(self._sync_buttons)
        lay.addWidget(self.table, 1)

        self.empty = QLabel("No personal agents are installed on this computer yet. Create one "
                            "from Settings → My agents & skills on any of your devices.")
        self.empty.setWordWrap(True)
        self.empty.setStyleSheet(f"color:{T.MUTED}; font-size:12px;")
        lay.addWidget(self.empty)

        row = QHBoxLayout()
        self.stop_btn = QPushButton("Stop")
        self.stop_btn.setObjectName("danger")
        self.stop_btn.setAccessibleName("Stop the selected agent")
        self.stop_btn.clicked.connect(self._stop_selected)
        self.folder_btn = QPushButton("Open folder")
        self.folder_btn.setAccessibleName("Open the selected agent's folder")
        self.folder_btn.clicked.connect(self._open_selected)
        self.refresh_btn = QPushButton("Refresh")
        self.refresh_btn.clicked.connect(self.refresh)
        self.status = QLabel("")
        self.status.setStyleSheet(f"color:{T.MUTED}; font-size:11px;")
        row.addWidget(self.stop_btn)
        row.addWidget(self.folder_btn)
        row.addWidget(self.refresh_btn)
        row.addStretch(1)
        row.addWidget(self.status)
        lay.addLayout(row)

        self._timer = QTimer(self)
        self._timer.setInterval(REFRESH_MS)
        self._timer.timeout.connect(self.refresh)
        self.refresh()

    # ── data ─────────────────────────────────────────────────────────────

    def rows(self) -> List[Dict[str, Any]]:
        return list(self._rows)

    def refresh(self) -> None:
        try:
            rows = list(self._host.inventory()) if self._host is not None else []
        except Exception:  # noqa: BLE001 — a listing failure is shown, not raised
            rows = []
            self.status.setText("Couldn't read the agent list.")
        selected = self.selected_agent_id()
        self._rows = rows
        self.table.setRowCount(len(rows))
        for i, entry in enumerate(rows):
            name = QTableWidgetItem(str(entry.get("name") or entry.get("agent_id") or ""))
            name.setData(Qt.ItemDataRole.UserRole, entry.get("agent_id"))
            name.setToolTip(str(entry.get("agent_id") or ""))
            status = QTableWidgetItem(str(entry.get("status") or "offline"))
            color = _STATUS_COLOR.get(str(entry.get("status") or ""), None)
            if color:
                from PySide6.QtGui import QBrush, QColor
                status.setForeground(QBrush(QColor(color)))
            pid = entry.get("pid")
            process = QTableWidgetItem(f"pid {pid}" if pid else "—")
            revision = QTableWidgetItem(str(entry.get("revision") or "")[:12] or "—")
            for col, item in enumerate((name, status, process, revision)):
                self.table.setItem(i, col, item)
            if entry.get("agent_id") == selected:
                self.table.selectRow(i)
        self.table.setVisible(bool(rows))
        self.empty.setVisible(not rows)
        online = sum(1 for e in rows if e.get("status") == "online")
        self.status.setText(f"{len(rows)} installed · {online} online" if rows else "")
        self._sync_buttons()

    def selected_agent_id(self) -> str:
        items = self.table.selectedItems()
        if not items:
            return ""
        return str(items[0].data(Qt.ItemDataRole.UserRole) or "")

    def _selected_entry(self) -> Optional[Dict[str, Any]]:
        agent_id = self.selected_agent_id()
        for entry in self._rows:
            if entry.get("agent_id") == agent_id:
                return entry
        return None

    def _sync_buttons(self) -> None:
        entry = self._selected_entry()
        self.stop_btn.setEnabled(bool(entry) and entry.get("status") in ("online", "starting"))
        self.folder_btn.setEnabled(bool(entry) and bool(entry.get("directory")))

    # ── acts ─────────────────────────────────────────────────────────────

    def _stop_selected(self) -> None:
        entry = self._selected_entry()
        if entry is None:
            return
        stopped = False
        try:
            stopped = bool(self._host.stop(str(entry["agent_id"])))
        except Exception:  # noqa: BLE001
            stopped = False
        self.refresh()
        self.status.setText(f"Stopped “{entry.get('name')}”." if stopped
                            else f"“{entry.get('name')}” was not running.")

    def _open_selected(self) -> None:
        entry = self._selected_entry()
        if entry is None:
            return
        if not open_folder(str(entry.get("directory") or ""), self._opener):
            self.status.setText("That folder is not there any more.")

    # ── lifecycle ────────────────────────────────────────────────────────

    def showEvent(self, event) -> None:  # noqa: N802 — Qt override
        super().showEvent(event)
        self.refresh()
        self._timer.start()

    def hideEvent(self, event) -> None:  # noqa: N802 — Qt override
        self._timer.stop()
        super().hideEvent(event)
