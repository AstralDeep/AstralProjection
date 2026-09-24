"""Thread-safe bridge between the win_agent coding-tool daemon thread and the GUI thread
for native Allow/Deny and folder-picker dialogs; tools.py calls
confirm_action()/pick_directory(), and the GUI's QTimer poller drives the reply.
"""

from __future__ import annotations

import logging
import os
import queue
import threading
import time
import uuid
from typing import Any, Callable, Dict, Optional

logger = logging.getLogger("astral.confirm")

_DEFAULT_TIMEOUT = 300


def _timeout() -> float:
    try:
        return max(
            5.0, float(os.getenv("ASTRAL_CONFIRM_TIMEOUT", str(_DEFAULT_TIMEOUT)))
        )
    except ValueError:
        return float(_DEFAULT_TIMEOUT)


class _Bridge:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._q: "queue.Queue[Dict[str, Any]]" = queue.Queue()
        self._reply: "queue.Queue[Dict[str, Any]]" = queue.Queue()
        self._attached = False
        self._poller = None
        self._serial = threading.Lock()

    def attach(self, show_fn: Callable[[Dict[str, Any]], Dict[str, Any]]) -> None:
        with self._lock:
            self._show_fn = show_fn
            self._attached = True

        try:
            from PySide6.QtCore import QTimer
        except Exception:  # noqa: BLE001
            logger.info("confirm bridge attached without Qt (headless/test mode)")
            return

        timer = QTimer()
        timer.setInterval(100)
        timer.timeout.connect(self._drain_once)
        timer.start()
        self._poller = timer
        self._timer_ref = timer

    def _drain_once(self) -> None:
        try:
            req = self._q.get_nowait()
        except queue.Empty:
            return
        self._show_and_reply(req)

    def _show_and_reply(self, req: Dict[str, Any]) -> None:
        try:
            reply = self._show_fn(req)
        except Exception as exc:  # noqa: BLE001
            logger.warning("confirm dialog failed: %s", exc)
            reply = {"accepted": False, "choice": None, "reason": "dialog_error"}
        if not isinstance(reply, dict):
            reply = {"accepted": bool(reply), "choice": None}
        reply.setdefault("_confirm_id", req.get("_confirm_id"))
        self._reply.put(reply)

    def request_confirm(self, req: Dict[str, Any]) -> Dict[str, Any]:
        with self._lock:
            attached = self._attached
        if not attached:
            return {"accepted": False, "choice": None, "reason": "no_gui"}
        req = dict(req)
        req["_confirm_id"] = uuid.uuid4().hex
        with self._serial:
            self._q.put(req)
            deadline = time.monotonic() + _timeout()
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    logger.warning(
                        "confirm request timed out after %ss: %s",
                        _timeout(), req.get("kind"),
                    )
                    return {"accepted": False, "choice": None, "reason": "timeout"}
                try:
                    reply = self._reply.get(timeout=remaining)
                except queue.Empty:
                    continue
                if reply.get("_confirm_id") == req["_confirm_id"]:
                    return reply
                # Stale reply after a timeout — drop it, don't misattribute
                logger.warning("dropping stale confirm reply (kind=%s)", req.get("kind"))


BRIDGE = _Bridge()


def confirm_action(
    *,
    tool: str,
    path: str = "",
    command: str = "",
    preview: str = "",
    summary: str = "",
) -> bool:
    req: Dict[str, Any] = {
        "kind": "action",
        "tool": tool,
        "path": path,
        "command": command,
        "preview": preview,
        "summary": summary,
    }
    reply = BRIDGE.request_confirm(req)
    return bool(reply.get("accepted"))


def pick_directory(
    *, title: str = "Choose the folder Astral may read & write", default: str = ""
) -> Optional[str]:
    req: Dict[str, Any] = {"kind": "directory", "title": title, "default": default}
    reply = BRIDGE.request_confirm(req)
    if not reply.get("accepted"):
        return None
    choice = reply.get("choice")
    return choice or None
