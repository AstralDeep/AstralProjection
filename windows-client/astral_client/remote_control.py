"""Feature 076 — this desktop as a *computer host* the owner drives from their
other signed-in devices (spec: specs/076-remote-computer-control in AstralDeep).

What lives here (GUI thread unless noted):

- :class:`RemoteControlSettings` — the persistent consent switch ("Allow remote
  control"), the stable ``host_id`` and the display name (``QSettings``).
- :func:`build_descriptor` — the ``register_ui.computer_host`` object.
- :class:`RemoteControlBanner` — the always-on-top "someone is controlling this
  computer" pill with Pause/Resume and Stop (the local kill switch).
- :class:`RemoteControlController` — consent announce/withdraw, the session
  state mirrored from ``computer_session`` frames, heartbeats, the presence
  detector (local mouse/keyboard ⇒ pause), and execution of
  ``computer_request`` frames through :class:`win_agent.computer_use.Executor`
  (screenshots inline on the GUI thread; everything else on a worker thread,
  one request at a time), answered with ``computer_response`` ui_events.

Nothing here decides *authorization*: the orchestrator gates every verb before
a request is built; this side enforces only its own consent, its announced
verb list, and the active session id (transport.md §3).
"""
from __future__ import annotations

import logging
import platform
import threading
import time
import uuid
from typing import Any, Callable, Dict, Optional

from PySide6.QtCore import QObject, QSettings, Qt, QTimer, Signal
from PySide6.QtWidgets import QHBoxLayout, QLabel, QPushButton, QWidget

from . import __version__
from win_agent import computer_use

logger = logging.getLogger("RemoteControl")

ENABLED_KEY = "astraldeep.remote_control.enabled.v1"
HOST_ID_KEY = "astraldeep.remote_control.host_id.v1"
NAME_KEY = "astraldeep.remote_control.name.v1"
BANNER_TITLE = "AstralDeep remote control"
HEARTBEAT_S = 30
PRESENCE_POLL_MS = 500
#: Human input newer than our own last injection by more than this is a person.
PRESENCE_GRACE_MS = 400
PROTOCOL = 1


def _default_name() -> str:
    name = platform.node() or "This computer"
    name = "".join(ch for ch in name if ord(ch) >= 32)[:64].strip()
    return name or "This computer"


class RemoteControlSettings:
    """Persistent consent + identity. ``host_id`` is minted once per install."""

    def __init__(self, settings: Optional[QSettings] = None):
        self._settings = settings if settings is not None else QSettings("AstralDeep", "WindowsClient")

    @property
    def enabled(self) -> bool:
        value = self._settings.value(ENABLED_KEY, False)
        if isinstance(value, str):
            return value.strip().lower() in ("1", "true", "yes")
        return bool(value)

    @enabled.setter
    def enabled(self, value: bool) -> None:
        self._settings.setValue(ENABLED_KEY, bool(value))
        self._settings.sync()

    @property
    def host_id(self) -> str:
        value = self._settings.value(HOST_ID_KEY, None)
        try:
            if isinstance(value, str) and uuid.UUID(value).version == 4 and str(uuid.UUID(value)) == value:
                return value
        except ValueError:
            pass
        fresh = str(uuid.uuid4())
        self._settings.setValue(HOST_ID_KEY, fresh)
        self._settings.sync()
        return fresh

    @property
    def name(self) -> str:
        value = self._settings.value(NAME_KEY, None)
        if isinstance(value, str) and value.strip():
            return value.strip()[:64]
        return _default_name()

    @name.setter
    def name(self, value: str) -> None:
        self._settings.setValue(NAME_KEY, str(value or "").strip()[:64])
        self._settings.sync()


def build_descriptor(settings: RemoteControlSettings,
                     screens: Optional[list] = None) -> Dict[str, Any]:
    """The exact ``computer_host`` object (transport.md §1)."""
    if screens is None:
        try:
            screens = computer_use.screens_descriptor()
        except Exception:  # noqa: BLE001 — no QGuiApplication (tests) ⇒ a nominal screen
            screens = []
    if not screens:
        screens = [{"index": 0, "width": 1920, "height": 1080, "scale": 1.0, "primary": True}]
    return {
        "host_id": settings.host_id,
        "name": settings.name,
        "platform": "windows",
        "client_version": __version__,
        "screens": screens,
        "verbs": list(computer_use.VERBS),
        "protocol": PROTOCOL,
    }


class RemoteControlBanner(QWidget):
    """A small always-on-top pill at the bottom-centre of the primary screen.
    Visible for the whole life of a session (spec FR-007); its Stop button is
    the local kill switch and its Pause/Resume mirrors the session state."""

    def __init__(self, on_pause: Callable[[], None], on_resume: Callable[[], None],
                 on_stop: Callable[[], None]):
        super().__init__(None, Qt.WindowType.Tool | Qt.WindowType.FramelessWindowHint
                         | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.WindowDoesNotAcceptFocus)
        self.setWindowTitle(BANNER_TITLE)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating, True)
        self.setObjectName("remoteControlBanner")
        self.setStyleSheet(
            "#remoteControlBanner { background:#111827; border:1px solid #6366F1; border-radius:10px; }"
            "QLabel { color:#F9FAFB; font-size:12px; padding:0 6px; }"
            "QPushButton { color:#F9FAFB; background:#374151; border:none; border-radius:6px; "
            "padding:4px 10px; font-size:12px; }"
            "QPushButton#stop { background:#DC2626; font-weight:600; }")
        self._label = QLabel("")
        self._pause_btn = QPushButton("Pause")
        self._pause_btn.setAccessibleName("Pause remote control")
        self._stop_btn = QPushButton("Stop")
        self._stop_btn.setObjectName("stop")
        self._stop_btn.setAccessibleName("Stop remote control")
        self._on_pause, self._on_resume = on_pause, on_resume
        self._paused = False
        self._pause_btn.clicked.connect(self._toggle)
        self._stop_btn.clicked.connect(lambda: on_stop())
        lay = QHBoxLayout(self)
        lay.setContentsMargins(10, 6, 10, 6)
        lay.setSpacing(8)
        lay.addWidget(self._label)
        lay.addWidget(self._pause_btn)
        lay.addWidget(self._stop_btn)

    def _toggle(self) -> None:
        if self._paused:
            self._on_resume()
        else:
            self._on_pause()

    def set_state(self, controller_label: str, paused: bool, pause_reason: Optional[str]) -> None:
        self._paused = paused
        if paused:
            why = "someone is using this computer" if pause_reason == "local_input" else "paused"
            self._label.setText(f"Remote control by your {controller_label} — {why}")
            self._pause_btn.setText("Resume")
        else:
            self._label.setText(f"Your {controller_label} is controlling this computer")
            self._pause_btn.setText("Pause")
        self.adjustSize()
        self._place()

    def _place(self) -> None:
        try:
            from PySide6.QtGui import QGuiApplication
            screen = QGuiApplication.primaryScreen()
            if screen is None:
                return
            geo = screen.availableGeometry()
            self.move(geo.x() + (geo.width() - self.width()) // 2,
                      geo.y() + geo.height() - self.height() - 12)
        except Exception:  # noqa: BLE001
            pass


class RemoteControlController(QObject):
    """Owns consent, the mirrored session, the banner and request execution."""

    #: (payload) — a worker-thread verb finished; delivered on the GUI thread.
    _finished = Signal(dict)
    #: session state changed — for the app's own status line / tests.
    session_changed = Signal(object)

    def __init__(self, *, send_event: Callable[[str, dict], Any],
                 settings: Optional[RemoteControlSettings] = None,
                 executor: Optional[computer_use.Executor] = None,
                 notify: Optional[Callable[[str, str], None]] = None,
                 banner_factory: Optional[Callable[..., Any]] = None,
                 system=None, parent: Optional[QObject] = None):
        super().__init__(parent)
        self._send_event = send_event
        self.settings = settings or RemoteControlSettings()
        self.executor = executor or computer_use.Executor()
        self._notify = notify or (lambda text, kind: None)
        self._banner_factory = banner_factory or RemoteControlBanner
        self._system = system if system is not None else getattr(self.executor, "system", None)
        self._banner = None
        self.session: Optional[Dict[str, Any]] = None
        self._busy = False
        self._queue: list = []
        self._session_start_tick = 0
        self._connected = False
        self._heartbeat = QTimer(self)
        self._heartbeat.setInterval(HEARTBEAT_S * 1000)
        self._heartbeat.timeout.connect(self._beat)
        self._presence = QTimer(self)
        self._presence.setInterval(PRESENCE_POLL_MS)
        self._presence.timeout.connect(self._poll_presence)
        self._finished.connect(self._deliver)

    # ── consent ───────────────────────────────────────────────────────────

    @property
    def enabled(self) -> bool:
        return self.settings.enabled

    @property
    def host_id(self) -> str:
        return self.settings.host_id

    def descriptor(self) -> Optional[Dict[str, Any]]:
        """What ``register_ui`` should carry: the descriptor when consent is on."""
        return build_descriptor(self.settings) if self.enabled else None

    def set_enabled(self, enabled: bool) -> None:
        """The client-local ``computer_host_consent`` action: persist, then
        announce/withdraw on the live socket (transport.md §2)."""
        enabled = bool(enabled)
        if enabled == self.settings.enabled:
            return
        self.settings.enabled = enabled
        if enabled:
            self._send("computer_event", {"host_id": self.host_id, "event": "announce",
                                          "host": build_descriptor(self.settings)})
            self._notify("Remote control is on — this computer can now be driven from your "
                         "other signed-in devices.", "info")
        else:
            self._end_local("consent_revoked")
            self._send("computer_event", {"host_id": self.host_id, "event": "withdraw"})
            self._notify("Remote control is off.", "info")

    # ── transport state ────────────────────────────────────────────────────

    def on_transport_status(self, status: str) -> None:
        """Socket loss ends the mirrored session: the server ends it as
        ``host_offline`` on its side, so the banner must not outlive the socket."""
        if status == "connected":
            self._connected = True
            return
        if status.startswith(("reconnecting", "closed", "auth_required")):
            self._connected = False
            if self.session is not None:
                self._end_local("host_offline")

    # ── inbound frames ─────────────────────────────────────────────────────

    def handle_frame(self, msg: dict) -> bool:
        kind = msg.get("type")
        if kind == "computer_session":
            self._on_session_frame(msg)
            return True
        if kind == "computer_request":
            self._on_request(msg)
            return True
        return kind == "computer_host"

    def _on_session_frame(self, msg: dict) -> None:
        if msg.get("host_id") != self.host_id:
            return  # about another of the owner's computers
        state = str(msg.get("state") or "")
        session_id = str(msg.get("session_id") or "")
        if state == "ended":
            if self.session is not None and self.session["session_id"] == session_id:
                self._clear_session()
                reason = str(msg.get("reason") or "")
                if reason not in ("local_stop", "consent_revoked"):
                    self._notify(f"Remote control session ended ({reason.replace('_', ' ')}).", "info")
            return
        if not self.enabled:
            # A stale session frame after the switch went off: refuse by silence
            # (the server's withdraw handling ends it; requests are refused).
            return
        fresh = self.session is None or self.session["session_id"] != session_id
        self.session = {"session_id": session_id, "state": state,
                        "controller_label": str(msg.get("controller_label") or "other device"),
                        "pause_reason": msg.get("pause_reason")}
        if fresh:
            self._session_start_tick = self._tick()
            self._heartbeat.start()
            self._presence.start()
            self._beat()  # the acknowledgement the server waits for
            self._notify(f"Your {self.session['controller_label']} started controlling this computer.", "info")
        self._show_banner()
        self.session_changed.emit(dict(self.session))

    def _on_request(self, msg: dict) -> None:
        request_id = str(msg.get("request_id") or "")
        if not request_id:
            return
        session_id = str(msg.get("session_id") or "")
        verb = str(msg.get("verb") or "")
        args = msg.get("args") if isinstance(msg.get("args"), dict) else {}
        if not self.enabled:
            self._respond(request_id, error=("no_session", "remote control is switched off on this computer"))
            return
        if self.session is None or self.session["session_id"] != session_id:
            self._respond(request_id, error=("no_session", "no active remote-control session on this computer"))
            return
        if self.session["state"] == "paused":
            self._respond(request_id, error=("paused", "this computer is paused — someone is using it"))
            return
        if verb not in computer_use.VERBS:
            self._respond(request_id, error=("unsupported", f"{verb!r} is not a verb this computer executes"))
            return
        if verb == "screenshot":
            try:
                result = self.executor.screenshot(args)
            except computer_use.VerbError as exc:
                self._respond(request_id, error=(exc.code, exc.message))
            except Exception as exc:  # noqa: BLE001 — typed, never a crash
                logger.exception("screenshot failed")
                self._respond(request_id, error=("failed", f"screenshot failed: {exc}"))
            else:
                self._respond(request_id, result=result)
            return
        if self._busy:
            self._queue.append((request_id, verb, args))
            return
        self._start_worker(request_id, verb, args)

    def _start_worker(self, request_id: str, verb: str, args: dict) -> None:
        self._busy = True

        def _work():
            try:
                result = self.executor.run(verb, args)
                payload = {"request_id": request_id, "ok": True, "result": result}
            except computer_use.VerbError as exc:
                payload = {"request_id": request_id, "ok": False, "error": {"code": exc.code, "message": exc.message}}
            except Exception as exc:  # noqa: BLE001
                logger.exception("verb %s failed", verb)
                payload = {"request_id": request_id, "ok": False,
                           "error": {"code": "failed", "message": f"{verb} failed: {exc}"}}
            self._finished.emit(payload)

        threading.Thread(target=_work, name=f"computer-use-{verb}", daemon=True).start()

    def _deliver(self, payload: dict) -> None:
        self._busy = False
        self._send("computer_response", payload)
        if self._queue:
            request_id, verb, args = self._queue.pop(0)
            self._on_request({"request_id": request_id, "verb": verb, "args": args,
                              "session_id": self.session["session_id"] if self.session else ""})

    def _respond(self, request_id: str, *, result: Optional[dict] = None,
                 error: Optional[tuple] = None) -> None:
        if error is not None:
            payload = {"request_id": request_id, "ok": False,
                       "error": {"code": error[0], "message": error[1]}}
        else:
            payload = {"request_id": request_id, "ok": True, "result": result or {}}
        self._send("computer_response", payload)

    # ── banner / local controls ────────────────────────────────────────────

    def _show_banner(self) -> None:
        if self.session is None:
            return
        if self._banner is None:
            self._banner = self._banner_factory(self.pause_locally, self.resume_locally, self.stop_locally)
        self._banner.set_state(self.session["controller_label"], self.session["state"] == "paused",
                               self.session.get("pause_reason"))
        self._banner.show()

    def pause_locally(self, reason: str = "local_pause") -> None:
        if self.session is None or self.session["state"] == "paused":
            return
        self.session["state"] = "paused"
        self.session["pause_reason"] = reason
        self._send("computer_event", {"host_id": self.host_id, "event": "paused",
                                      "session_id": self.session["session_id"], "reason": reason})
        self._show_banner()
        self.session_changed.emit(dict(self.session))

    def resume_locally(self) -> None:
        if self.session is None or self.session["state"] != "paused":
            return
        self.session["state"] = "active"
        self.session["pause_reason"] = None
        self._session_start_tick = self._tick()
        self._send("computer_event", {"host_id": self.host_id, "event": "resumed",
                                      "session_id": self.session["session_id"]})
        self._show_banner()
        self.session_changed.emit(dict(self.session))

    def stop_locally(self) -> None:
        if self.session is None:
            return
        session_id = self.session["session_id"]
        self._send("computer_event", {"host_id": self.host_id, "event": "stopped",
                                      "session_id": session_id, "reason": "local_stop"})
        self._clear_session()

    def stop_all(self) -> None:
        """Application shutdown / sign-out: never leave a banner or a live
        session behind (spec FR-007)."""
        self.stop_locally()

    def _end_local(self, reason: str) -> None:
        if self.session is None:
            return
        self._clear_session()
        logger.info("076: local session ended (%s)", reason)

    def _clear_session(self) -> None:
        self.session = None
        self._queue.clear()
        self._heartbeat.stop()
        self._presence.stop()
        if self._banner is not None:
            self._banner.hide()
        self.session_changed.emit(None)

    # ── heartbeat + presence ───────────────────────────────────────────────

    def _beat(self) -> None:
        if self.session is None:
            return
        self._send("computer_event", {"host_id": self.host_id, "event": "heartbeat",
                                      "session_id": self.session["session_id"]})

    def _tick(self) -> int:
        system = self._system
        if system is not None and hasattr(system, "tick"):
            try:
                return int(system.tick())
            except Exception:  # noqa: BLE001
                return 0
        return int(time.monotonic() * 1000)

    def _poll_presence(self) -> None:
        """Local mouse/keyboard while a session is active ⇒ pause (FR-008)."""
        if self.session is None or self.session["state"] != "active":
            return
        system = self._system
        if system is None or not hasattr(system, "last_input_tick"):
            return
        try:
            last_input = int(system.last_input_tick())
        except Exception:  # noqa: BLE001
            return
        injected = int(getattr(self.executor.injector, "last_injected_tick", 0) or 0)
        if last_input <= max(injected + PRESENCE_GRACE_MS, self._session_start_tick):
            return
        self.pause_locally("local_input")

    # ── plumbing ───────────────────────────────────────────────────────────

    def _send(self, action: str, payload: dict) -> None:
        try:
            self._send_event(action, payload)
        except Exception:  # noqa: BLE001 — a dead socket never kills the controller
            logger.debug("076: %s send failed", action, exc_info=True)
