"""Feature 076 — the computer-use executor: what this desktop does when a
``computer_request`` arrives (spec contracts/verbs.md, transport.md §3-4).

Stdlib + Qt only (Constitution V): screen capture through ``QScreen``, input
through ``user32.SendInput`` / ``SetCursorPos`` via ``ctypes``, windows through
``EnumWindows``, commands through ``subprocess``. Every verb returns a typed
result dict — ``{"ok": True, "result": {...}}`` or
``{"ok": False, "error": {"code", "message"}}`` — and never raises into the
transport. The pure parts (chord parsing, coordinate mapping, path checks,
verb table) are platform-neutral so they are unit-tested offscreen on any OS;
the Windows-only parts are isolated in :class:`WindowsInjector` and
:class:`WindowsSystem`, replaced by fakes in tests.

Coordinates: the orchestrator sends points in the pixel space of the most
recent screenshot; :func:`to_physical` maps them back through that capture's
scale and screen origin. Before any screenshot they are primary-screen physical
pixels (spec FR-013).
"""
from __future__ import annotations

import base64
import ctypes
import logging
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path, PureWindowsPath
from typing import Any, Callable, Dict, List, Optional, Tuple

logger = logging.getLogger("ComputerUse")

IS_WINDOWS = sys.platform == "win32"

#: The closed verb set this host executes — must equal the orchestrator's
#: HOST_VERBS (announced in the descriptor; the server refuses anything else).
VERBS: Tuple[str, ...] = (
    "screenshot", "list_windows", "get_clipboard", "read_file", "list_dir", "wait",
    "click", "double_click", "right_click", "move", "drag", "scroll", "type_text",
    "press_keys", "focus_window", "open_app", "set_clipboard",
    "run_command", "write_file", "delete_path",
)

MAX_TEXT_CHARS = 4000
MAX_CLIPBOARD_CHARS = 16 * 1024
MAX_READ_BYTES = 262_144
MAX_WRITE_BYTES = 256 * 1024
MAX_COMMAND_TIMEOUT_S = 300
MAX_OUTPUT_BYTES = 64 * 1024
MAX_DIR_ENTRIES = 500
MAX_WINDOWS = 100
JPEG_QUALITY = 70
MIN_WIDTH, MAX_WIDTH, DEFAULT_WIDTH = 320, 1920, 1280


class VerbError(Exception):
    """A typed refusal the transport reports as ``{"ok": False, "error": …}``."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


# ── capture geometry / coordinate mapping (pure) ─────────────────────────────

@dataclass(frozen=True)
class CaptureGeometry:
    screen_index: int
    width: int          # scaled (what the model/phone saw)
    height: int
    scale: float        # scaled / physical
    phys_x: int         # physical origin of that screen on the virtual desktop
    phys_y: int
    phys_w: int
    phys_h: int

    def to_physical(self, x: int, y: int) -> Tuple[int, int]:
        if not (0 <= x <= self.width and 0 <= y <= self.height):
            raise VerbError("out_of_range",
                            f"({x}, {y}) is outside the last screenshot ({self.width}×{self.height})")
        px = self.phys_x + int(round(x / self.scale))
        py = self.phys_y + int(round(y / self.scale))
        px = min(max(px, self.phys_x), self.phys_x + self.phys_w - 1)
        py = min(max(py, self.phys_y), self.phys_y + self.phys_h - 1)
        return px, py


def to_physical(geometry: Optional[CaptureGeometry], x: int, y: int,
                primary: Optional[Tuple[int, int, int, int]] = None) -> Tuple[int, int]:
    """Map screenshot-space coordinates to physical pixels. With no capture yet,
    coordinates are primary-screen physical pixels bounded by ``primary``
    ``(x, y, w, h)`` when known."""
    if geometry is not None:
        return geometry.to_physical(x, y)
    if primary is not None:
        ox, oy, w, h = primary
        if not (0 <= x < w and 0 <= y < h):
            raise VerbError("out_of_range", f"({x}, {y}) is outside the primary screen ({w}×{h})")
        return ox + x, oy + y
    return x, y


# ── key chords (pure) ─────────────────────────────────────────────────────────

VK = {
    "enter": 0x0D, "return": 0x0D, "tab": 0x09, "escape": 0x1B, "esc": 0x1B, "space": 0x20,
    "backspace": 0x08, "delete": 0x2E, "del": 0x2E, "insert": 0x2D, "home": 0x24, "end": 0x23,
    "pageup": 0x21, "pagedown": 0x22, "up": 0x26, "down": 0x28, "left": 0x25, "right": 0x27,
    "printscreen": 0x2C, "capslock": 0x14, "numlock": 0x90, "scrolllock": 0x91, "pause": 0x13,
    "menu": 0x5D, "apps": 0x5D,
    **{f"f{i}": 0x6F + i for i in range(1, 25)},
    "minus": 0xBD, "plus": 0xBB, "equals": 0xBB, "comma": 0xBC, "period": 0xBE, "slash": 0xBF,
    "backslash": 0xDC, "semicolon": 0xBA, "quote": 0xDE, "backquote": 0xC0,
    "bracketleft": 0xDB, "bracketright": 0xDD,
}
MODIFIERS = {"ctrl": 0x11, "control": 0x11, "shift": 0x10, "alt": 0x12, "win": 0x5B, "super": 0x5B,
             "cmd": 0x5B, "meta": 0x5B}


def parse_chord(keys: str) -> Tuple[List[int], int]:
    """``"ctrl+shift+s"`` → ``([VK_CONTROL, VK_SHIFT], ord("S"))``. Letters and
    digits map through their uppercase virtual-key codes; everything else
    through :data:`VK`. Unknown tokens are a typed ``out_of_range``."""
    raw = str(keys or "").replace(" ", "").lower()
    if not raw or raw.startswith("+") or raw.endswith("+") or "++" in raw:
        raise VerbError("out_of_range", "keys must be a chord like 'ctrl+s', 'enter' or 'alt+f4'")
    parts = [p for p in raw.split("+") if p]
    if not parts:
        raise VerbError("out_of_range", "keys must name at least one key")
    mods: List[int] = []
    main: Optional[int] = None
    for part in parts:
        if part in MODIFIERS:
            code = MODIFIERS[part]
            if code not in mods:
                mods.append(code)
            continue
        if main is not None:
            raise VerbError("out_of_range", f"a chord may name only one non-modifier key ({keys!r})")
        if len(part) == 1 and (part.isalnum()):
            main = ord(part.upper())
        elif part in VK:
            main = VK[part]
        else:
            raise VerbError("out_of_range", f"unknown key {part!r}")
    if main is None:
        # A bare modifier chord (e.g. "win") presses and releases it.
        if len(mods) == 1:
            return [], mods[0]
        raise VerbError("out_of_range", "a chord needs one non-modifier key")
    return mods, main


# ── path / argument validation (pure) ─────────────────────────────────────────

def _abs_path(value: Any, *, must_exist: bool = False) -> Path:
    text = str(value or "").strip()
    if not text or "\x00" in text or len(text) > 1024:
        raise VerbError("out_of_range", "path must be a non-empty absolute path")
    path = Path(text)
    if not path.is_absolute():
        raise VerbError("out_of_range", f"{text!r} is not an absolute path")
    if must_exist and not path.exists():
        raise VerbError("not_found", f"{text} does not exist")
    return path


_APP_NAME_OK = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._+-")


def validate_app(app: Any) -> Tuple[str, bool]:
    """Return ``(app, is_path)`` or raise. A bare name has no separators and only
    safe characters; a path must be absolute and end in .exe/.lnk/.bat/.cmd."""
    text = str(app or "").strip()
    if not text or len(text) > 1024 or "\x00" in text:
        raise VerbError("out_of_range", "app must be an application name or an absolute path")
    if "\\" in text or "/" in text or ":" in text:
        path = PureWindowsPath(text)
        if not path.is_absolute() or path.suffix.lower() not in (".exe", ".lnk", ".bat", ".cmd"):
            raise VerbError("out_of_range", "app paths must be absolute and end in .exe, .lnk, .bat or .cmd")
        for ch in text:
            if ch in '|&;<>*?"`$':
                raise VerbError("out_of_range", f"app path contains a forbidden character {ch!r}")
        return text, True
    if any(ch not in _APP_NAME_OK for ch in text) or len(text) > 80:
        raise VerbError("out_of_range", "app names may only contain letters, digits, spaces, . _ + -")
    return text, False


# ── Windows-only primitives ───────────────────────────────────────────────────

if IS_WINDOWS:  # pragma: no cover — exercised on the rig, not in CI
    import ctypes.wintypes as wt

    _user32 = ctypes.WinDLL("user32", use_last_error=True)
    _kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    ULONG_PTR = ctypes.c_size_t

    class MOUSEINPUT(ctypes.Structure):
        _fields_ = [("dx", wt.LONG), ("dy", wt.LONG), ("mouseData", wt.DWORD),
                    ("dwFlags", wt.DWORD), ("time", wt.DWORD), ("dwExtraInfo", ULONG_PTR)]

    class KEYBDINPUT(ctypes.Structure):
        _fields_ = [("wVk", wt.WORD), ("wScan", wt.WORD), ("dwFlags", wt.DWORD),
                    ("time", wt.DWORD), ("dwExtraInfo", ULONG_PTR)]

    class HARDWAREINPUT(ctypes.Structure):
        _fields_ = [("uMsg", wt.DWORD), ("wParamL", wt.WORD), ("wParamH", wt.WORD)]

    class _INPUTUNION(ctypes.Union):
        _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]

    class INPUT(ctypes.Structure):
        _fields_ = [("type", wt.DWORD), ("u", _INPUTUNION)]

    class LASTINPUTINFO(ctypes.Structure):
        _fields_ = [("cbSize", wt.UINT), ("dwTime", wt.DWORD)]

    _user32.SendInput.argtypes = (wt.UINT, ctypes.POINTER(INPUT), ctypes.c_int)
    _user32.SendInput.restype = wt.UINT
    _user32.SetCursorPos.argtypes = (ctypes.c_int, ctypes.c_int)
    _user32.GetLastInputInfo.argtypes = (ctypes.POINTER(LASTINPUTINFO),)
    _user32.OpenInputDesktop.argtypes = (wt.DWORD, wt.BOOL, wt.DWORD)
    _user32.OpenInputDesktop.restype = wt.HANDLE
    _user32.CloseDesktop.argtypes = (wt.HANDLE,)
    _user32.GetForegroundWindow.restype = wt.HWND
    _user32.SetForegroundWindow.argtypes = (wt.HWND,)
    _user32.ShowWindow.argtypes = (wt.HWND, ctypes.c_int)
    _user32.IsIconic.argtypes = (wt.HWND,)
    _user32.IsWindowVisible.argtypes = (wt.HWND,)
    _user32.GetWindowTextLengthW.argtypes = (wt.HWND,)
    _user32.GetWindowTextW.argtypes = (wt.HWND, wt.LPWSTR, ctypes.c_int)
    _user32.GetWindowRect.argtypes = (wt.HWND, ctypes.POINTER(wt.RECT))
    _user32.GetWindowThreadProcessId.argtypes = (wt.HWND, ctypes.POINTER(wt.DWORD))
    _user32.GetWindowLongW.argtypes = (wt.HWND, ctypes.c_int)
    _user32.GetWindowLongW.restype = wt.LONG
    _WNDENUMPROC = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    _user32.EnumWindows.argtypes = (_WNDENUMPROC, wt.LPARAM)

    INPUT_MOUSE, INPUT_KEYBOARD = 0, 1
    MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP = 0x0002, 0x0004
    MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP = 0x0008, 0x0010
    MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP = 0x0020, 0x0040
    MOUSEEVENTF_WHEEL, MOUSEEVENTF_HWHEEL = 0x0800, 0x1000
    KEYEVENTF_KEYUP, KEYEVENTF_UNICODE = 0x0002, 0x0004
    SW_RESTORE = 9
    GWL_EXSTYLE, WS_EX_TOOLWINDOW = -20, 0x00000080
    DESKTOP_SWITCHDESKTOP = 0x0100

    def _send(inputs: List[INPUT]) -> None:
        arr = (INPUT * len(inputs))(*inputs)
        sent = _user32.SendInput(len(inputs), arr, ctypes.sizeof(INPUT))
        if sent != len(inputs):
            raise VerbError("failed", f"SendInput injected {sent}/{len(inputs)} events "
                                      f"(error {ctypes.get_last_error()})")

    def _mouse(flags: int, data: int = 0) -> INPUT:
        inp = INPUT()
        inp.type = INPUT_MOUSE
        inp.u.mi = MOUSEINPUT(0, 0, data & 0xFFFFFFFF, flags, 0, 0)
        return inp

    def _key(vk: int = 0, scan: int = 0, flags: int = 0) -> INPUT:
        inp = INPUT()
        inp.type = INPUT_KEYBOARD
        inp.u.ki = KEYBDINPUT(vk, scan, flags, 0, 0)
        return inp

    class WindowsInjector:
        """Mouse/keyboard synthesis. Records the tick of its own last injection
        so the presence detector can tell human input from ours."""

        def __init__(self) -> None:
            self.last_injected_tick: int = 0

        def _stamp(self) -> None:
            self.last_injected_tick = int(_kernel32.GetTickCount())

        def move(self, px: int, py: int) -> None:
            if not _user32.SetCursorPos(int(px), int(py)):
                raise VerbError("failed", "SetCursorPos refused (secure desktop or locked screen?)")
            self._stamp()

        def click(self, px: int, py: int, button: str = "left", count: int = 1) -> None:
            self.move(px, py)
            down, up = {"left": (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
                        "right": (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
                        "middle": (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP)}[button]
            for i in range(max(1, min(int(count), 2))):
                _send([_mouse(down), _mouse(up)])
                if i == 0 and count > 1:
                    time.sleep(0.05)
            self._stamp()

        def drag(self, x1: int, y1: int, x2: int, y2: int) -> None:
            self.move(x1, y1)
            _send([_mouse(MOUSEEVENTF_LEFTDOWN)])
            steps = 12
            for i in range(1, steps + 1):
                self.move(x1 + (x2 - x1) * i // steps, y1 + (y2 - y1) * i // steps)
                time.sleep(0.01)
            _send([_mouse(MOUSEEVENTF_LEFTUP)])
            self._stamp()

        def scroll(self, px: int, py: int, dx: int, dy: int) -> None:
            self.move(px, py)
            if dy:
                _send([_mouse(MOUSEEVENTF_WHEEL, int(dy) * 120)])
            if dx:
                _send([_mouse(MOUSEEVENTF_HWHEEL, int(dx) * 120)])
            self._stamp()

        def type_text(self, text: str) -> None:
            for ch in text:
                if ch == "\n":
                    _send([_key(vk=0x0D), _key(vk=0x0D, flags=KEYEVENTF_KEYUP)])
                    continue
                for unit in _utf16_units(ch):
                    _send([_key(scan=unit, flags=KEYEVENTF_UNICODE),
                           _key(scan=unit, flags=KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)])
            self._stamp()

        def press(self, mods: List[int], vk: int) -> None:
            seq = [_key(vk=m) for m in mods] + [_key(vk=vk), _key(vk=vk, flags=KEYEVENTF_KEYUP)]
            seq += [_key(vk=m, flags=KEYEVENTF_KEYUP) for m in reversed(mods)]
            _send(seq)
            self._stamp()

    def _utf16_units(ch: str) -> List[int]:
        data = ch.encode("utf-16-le")
        return [int.from_bytes(data[i:i + 2], "little") for i in range(0, len(data), 2)]

    class WindowsSystem:
        """Windows, presence, lock state, foreground."""

        @staticmethod
        def last_input_tick() -> int:
            info = LASTINPUTINFO()
            info.cbSize = ctypes.sizeof(LASTINPUTINFO)
            if not _user32.GetLastInputInfo(ctypes.byref(info)):
                return 0
            return int(info.dwTime)

        @staticmethod
        def tick() -> int:
            return int(_kernel32.GetTickCount())

        @staticmethod
        def screen_locked() -> bool:
            handle = _user32.OpenInputDesktop(0, False, DESKTOP_SWITCHDESKTOP)
            if not handle:
                return True
            _user32.CloseDesktop(handle)
            return False

        @staticmethod
        def list_windows(exclude_titles: Tuple[str, ...] = ()) -> List[Dict[str, Any]]:
            out: List[Dict[str, Any]] = []
            foreground = _user32.GetForegroundWindow()
            try:
                import psutil
            except Exception:  # noqa: BLE001
                psutil = None

            def _cb(hwnd, _lparam):
                if len(out) >= MAX_WINDOWS:
                    return False
                if not _user32.IsWindowVisible(hwnd):
                    return True
                if _user32.GetWindowLongW(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW:
                    return True
                length = _user32.GetWindowTextLengthW(hwnd)
                if length <= 0:
                    return True
                buf = ctypes.create_unicode_buffer(length + 1)
                _user32.GetWindowTextW(hwnd, buf, length + 1)
                title = buf.value
                if not title or title in exclude_titles:
                    return True
                rect = wt.RECT()
                _user32.GetWindowRect(hwnd, ctypes.byref(rect))
                pid = wt.DWORD(0)
                _user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
                process = ""
                if psutil is not None and pid.value:
                    try:
                        process = psutil.Process(pid.value).name()
                    except Exception:  # noqa: BLE001
                        process = ""
                out.append({"hwnd": int(hwnd), "title": title[:200], "process": process,
                            "rect": [rect.left, rect.top, rect.right, rect.bottom],
                            "focused": int(hwnd) == int(foreground or 0),
                            "minimized": bool(_user32.IsIconic(hwnd))})
                return True

            _user32.EnumWindows(_WNDENUMPROC(_cb), 0)
            return out

        @staticmethod
        def focus_window(hwnd: int) -> bool:
            if _user32.IsIconic(hwnd):
                _user32.ShowWindow(hwnd, SW_RESTORE)
            # Windows refuses SetForegroundWindow from a process that has not
            # received input recently; a synthetic ALT tap lifts that lock.
            _send([_key(vk=0x12), _key(vk=0x12, flags=KEYEVENTF_KEYUP)])
            _user32.SetForegroundWindow(hwnd)
            time.sleep(0.05)
            return int(_user32.GetForegroundWindow() or 0) == int(hwnd)

        @staticmethod
        def open_app(app: str, args: List[str], is_path: bool) -> Optional[int]:
            if is_path:
                proc = subprocess.Popen([app, *args], close_fds=True,
                                        creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0))
                return proc.pid
            os.startfile(app)  # noqa: S606 — a validated bare app name via ShellExecute
            return None

else:  # non-Windows import (tests, other hosts): the platform pieces are absent
    WindowsInjector = None  # type: ignore[assignment]
    WindowsSystem = None  # type: ignore[assignment]


# ── capture (Qt, GUI thread) ──────────────────────────────────────────────────

def screens_descriptor() -> List[Dict[str, Any]]:
    """The ``screens`` list for the host descriptor (physical pixels)."""
    from PySide6.QtGui import QGuiApplication
    app = QGuiApplication.instance()
    out: List[Dict[str, Any]] = []
    if app is None:
        return out
    primary = QGuiApplication.primaryScreen()
    for index, screen in enumerate(QGuiApplication.screens()):
        dpr = float(screen.devicePixelRatio() or 1.0)
        geo = screen.geometry()
        out.append({"index": index, "width": int(round(geo.width() * dpr)),
                    "height": int(round(geo.height() * dpr)), "scale": round(dpr, 3),
                    "primary": screen is primary})
    if out and not any(s["primary"] for s in out):
        out[0]["primary"] = True
    return out[:8]


def capture(screen_index: int = 0, max_width: int = DEFAULT_WIDTH,
            quality: int = JPEG_QUALITY) -> Tuple[Dict[str, Any], CaptureGeometry]:
    """Grab one screen, downscale to ``max_width``, encode JPEG, return the
    result payload + the geometry later verbs map coordinates through. MUST run
    on the GUI thread (``QScreen.grabWindow``)."""
    from PySide6.QtCore import QBuffer, QIODevice, Qt
    from PySide6.QtGui import QGuiApplication

    screens = QGuiApplication.screens()
    if not screens:
        raise VerbError("failed", "no screens are available")
    if not (0 <= int(screen_index) < len(screens)):
        raise VerbError("out_of_range", f"screen_index must be 0..{len(screens) - 1}")
    max_width = max(MIN_WIDTH, min(int(max_width or DEFAULT_WIDTH), MAX_WIDTH))
    screen = screens[int(screen_index)]
    pixmap = screen.grabWindow(0)
    if pixmap.isNull():
        raise VerbError("screen_locked", "the screen could not be captured (locked or protected)")
    image = pixmap.toImage()
    phys_w, phys_h = image.width(), image.height()
    if phys_w <= 0 or phys_h <= 0:
        raise VerbError("failed", "empty capture")
    if phys_w > max_width:
        image = image.scaledToWidth(max_width, Qt.TransformationMode.SmoothTransformation)
    width, height = image.width(), image.height()
    buf = QBuffer()
    buf.open(QIODevice.OpenModeFlag.WriteOnly)
    if not image.save(buf, "JPEG", int(quality)):
        raise VerbError("failed", "JPEG encoding failed")
    data = bytes(buf.data())
    buf.close()
    dpr = float(screen.devicePixelRatio() or 1.0)
    geo = screen.geometry()
    geometry = CaptureGeometry(
        screen_index=int(screen_index), width=width, height=height, scale=width / phys_w,
        phys_x=int(round(geo.x() * dpr)), phys_y=int(round(geo.y() * dpr)),
        phys_w=phys_w, phys_h=phys_h,
    )
    result = {"screen_index": int(screen_index), "width": width, "height": height,
              "scale": round(width / phys_w, 6), "media_type": "image/jpeg",
              "base64": base64.b64encode(data).decode("ascii")}
    return result, geometry


# ── clipboard / files / commands (worker thread) ──────────────────────────────

def clipboard_get() -> Dict[str, Any]:
    from win_agent.tools import _clip_get
    text = _clip_get() or ""
    truncated = len(text) > MAX_CLIPBOARD_CHARS
    return {"text": text[:MAX_CLIPBOARD_CHARS], "truncated": truncated}


def clipboard_set(text: str) -> Dict[str, Any]:
    from win_agent.tools import _clip_set
    if not isinstance(text, str) or len(text) > MAX_CLIPBOARD_CHARS:
        raise VerbError("out_of_range", "text must be a string of at most 16 KiB")
    _clip_set(text)
    return {"chars": len(text)}


def read_file(path_value: Any, max_bytes: Any) -> Dict[str, Any]:
    path = _abs_path(path_value, must_exist=True)
    if not path.is_file():
        raise VerbError("not_found", f"{path} is not a file")
    try:
        limit = max(1, min(int(max_bytes or 65536), MAX_READ_BYTES))
    except (TypeError, ValueError):
        raise VerbError("out_of_range", "max_bytes must be an integer")
    size = path.stat().st_size
    with path.open("rb") as fh:
        data = fh.read(limit + 1)
    truncated = len(data) > limit
    text = data[:limit].decode("utf-8", errors="replace")
    return {"path": str(path), "text": text, "truncated": truncated, "size": size}


def list_dir(path_value: Any) -> Dict[str, Any]:
    path = _abs_path(path_value, must_exist=True)
    if not path.is_dir():
        raise VerbError("not_found", f"{path} is not a directory")
    entries = []
    for i, child in enumerate(sorted(path.iterdir(), key=lambda c: (not c.is_dir(), c.name.lower()))):
        if i >= MAX_DIR_ENTRIES:
            break
        try:
            st = child.stat()
            entries.append({"name": child.name, "is_dir": child.is_dir(), "size": int(st.st_size),
                            "modified": int(st.st_mtime)})
        except OSError:
            entries.append({"name": child.name, "is_dir": child.is_dir(), "size": 0, "modified": None})
    return {"path": str(path), "entries": entries, "count": len(entries)}


def write_file(path_value: Any, content: Any, if_exists: Any) -> Dict[str, Any]:
    path = _abs_path(path_value)
    if not isinstance(content, str):
        raise VerbError("out_of_range", "content must be text")
    data = content.encode("utf-8")
    if len(data) > MAX_WRITE_BYTES:
        raise VerbError("out_of_range", f"content exceeds {MAX_WRITE_BYTES} bytes")
    mode = str(if_exists or "refuse")
    if path.exists():
        if path.is_dir():
            raise VerbError("failed", f"{path} is a directory")
        if mode != "overwrite":
            raise VerbError("exists", f"{path} already exists (pass if_exists=overwrite to replace it)")
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".astral-tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)
    return {"path": str(path), "bytes": len(data)}


def delete_path(path_value: Any) -> Dict[str, Any]:
    path = _abs_path(path_value, must_exist=True)
    if path.is_dir():
        try:
            path.rmdir()
        except OSError:
            raise VerbError("failed", f"{path} is not empty — only files and empty directories are deleted")
    else:
        path.unlink()
    return {"path": str(path), "deleted": True}


def run_command(command: Any, cwd: Any, timeout_s: Any) -> Dict[str, Any]:
    if not isinstance(command, str) or not command.strip() or len(command) > 2000:
        raise VerbError("out_of_range", "command must be a non-empty string of at most 2000 characters")
    try:
        timeout = max(1, min(int(timeout_s or 60), MAX_COMMAND_TIMEOUT_S))
    except (TypeError, ValueError):
        raise VerbError("out_of_range", "timeout_s must be an integer")
    workdir = str(_abs_path(cwd, must_exist=True)) if cwd else str(Path.home())
    argv = (["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command]
            if IS_WINDOWS else ["/bin/sh", "-c", command])
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    started = time.monotonic()
    try:
        proc = subprocess.run(argv, cwd=workdir, capture_output=True, timeout=timeout,
                              creationflags=flags)
    except subprocess.TimeoutExpired as exc:
        out = (exc.stdout or b"")[:MAX_OUTPUT_BYTES].decode("utf-8", errors="replace")
        raise VerbError("timeout", f"command still running after {timeout} s; partial output: {out[:500]}")
    except OSError as exc:
        raise VerbError("failed", f"could not start the command: {exc}")
    duration_ms = int((time.monotonic() - started) * 1000)
    stdout = proc.stdout or b""
    stderr = proc.stderr or b""
    truncated = len(stdout) > MAX_OUTPUT_BYTES or len(stderr) > MAX_OUTPUT_BYTES // 4
    return {"exit_code": int(proc.returncode), "stdout": stdout[:MAX_OUTPUT_BYTES].decode("utf-8", errors="replace"),
            "stderr": stderr[:MAX_OUTPUT_BYTES // 4].decode("utf-8", errors="replace"),
            "truncated": truncated, "duration_ms": duration_ms}


# ── the executor ──────────────────────────────────────────────────────────────

class Executor:
    """Runs one verb at a time against this desktop. ``injector`` and ``system``
    default to the Windows implementations; tests inject fakes. ``capture_fn``
    must be called on the GUI thread — the controller marshals it."""

    def __init__(self, injector=None, system=None, capture_fn: Callable = capture,
                 banner_titles: Tuple[str, ...] = ("AstralDeep remote control",)):
        if injector is None and IS_WINDOWS:
            injector = WindowsInjector()
        if system is None and IS_WINDOWS:
            system = WindowsSystem()
        self.injector = injector
        self.system = system
        self.capture_fn = capture_fn
        self.banner_titles = banner_titles
        self.last_geometry: Optional[CaptureGeometry] = None
        self.primary_physical: Optional[Tuple[int, int, int, int]] = None

    # -- helpers ------------------------------------------------------------

    def _need(self, what):
        if what is None:
            raise VerbError("unsupported", "this verb is not available on this platform")
        return what

    def _point(self, args: Dict[str, Any], xk: str = "x", yk: str = "y") -> Tuple[int, int]:
        try:
            x, y = int(args.get(xk)), int(args.get(yk))
        except (TypeError, ValueError):
            raise VerbError("out_of_range", f"{xk}/{yk} must be integers")
        return to_physical(self.last_geometry, x, y, self.primary_physical)

    def _locked_check(self) -> None:
        system = self.system
        if system is not None and getattr(system, "screen_locked", None) and system.screen_locked():
            raise VerbError("screen_locked", "the screen is locked — unlock the computer first")

    # -- entry points -------------------------------------------------------

    def screenshot(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """GUI thread."""
        self._locked_check()
        result, geometry = self.capture_fn(int(args.get("screen_index") or 0),
                                           int(args.get("max_width") or DEFAULT_WIDTH))
        self.last_geometry = geometry
        return result

    def run(self, verb: str, args: Dict[str, Any]) -> Dict[str, Any]:
        """Worker thread (everything except ``screenshot``). Returns the verb's
        result dict or raises :class:`VerbError`."""
        args = args if isinstance(args, dict) else {}
        if verb == "wait":
            seconds = float(args.get("seconds") or 1.0)
            if not (0.1 <= seconds <= 10.0):
                raise VerbError("out_of_range", "seconds must be between 0.1 and 10")
            time.sleep(seconds)
            return {"waited": seconds}
        if verb == "list_windows":
            return {"windows": self._need(self.system).list_windows(self.banner_titles)}
        if verb == "get_clipboard":
            return clipboard_get()
        if verb == "set_clipboard":
            return clipboard_set(args.get("text"))
        if verb == "read_file":
            return read_file(args.get("path"), args.get("max_bytes"))
        if verb == "list_dir":
            return list_dir(args.get("path"))
        if verb == "write_file":
            return write_file(args.get("path"), args.get("content"), args.get("if_exists"))
        if verb == "delete_path":
            return delete_path(args.get("path"))
        if verb == "run_command":
            return run_command(args.get("command"), args.get("cwd"), args.get("timeout_s"))
        if verb == "open_app":
            app, is_path = validate_app(args.get("app"))
            argv = args.get("args") or []
            if not isinstance(argv, list) or any(not isinstance(a, str) for a in argv) or len(argv) > 16:
                raise VerbError("out_of_range", "args must be a short list of strings")
            pid = self._need(self.system).open_app(app, argv, is_path)
            return {"launched": True, "pid": pid, "app": app}
        if verb == "focus_window":
            system = self._need(self.system)
            hwnd = args.get("hwnd")
            title = str(args.get("title") or "").strip().lower()
            windows = system.list_windows(self.banner_titles)
            target = None
            if hwnd is not None:
                target = next((w for w in windows if int(w["hwnd"]) == int(hwnd)), None)
            elif title:
                target = next((w for w in windows if title in w["title"].lower()), None)
            if target is None:
                raise VerbError("window_not_found", "no open window matches")
            if not system.focus_window(int(target["hwnd"])):
                raise VerbError("failed", f"could not bring {target['title']!r} to the front")
            return {"hwnd": int(target["hwnd"]), "title": target["title"]}
        injector = self._need(self.injector)
        self._locked_check()
        if verb in ("click", "double_click", "right_click", "move"):
            px, py = self._point(args)
            if verb == "move":
                injector.move(px, py)
                return {"x": args.get("x"), "y": args.get("y")}
            button = str(args.get("button") or ("right" if verb == "right_click" else "left")).lower()
            if button not in ("left", "right", "middle"):
                raise VerbError("out_of_range", "button must be left, right or middle")
            count = 2 if verb == "double_click" else max(1, min(int(args.get("count") or 1), 2))
            injector.click(px, py, button, count)
            return {"x": args.get("x"), "y": args.get("y"), "button": button, "count": count}
        if verb == "drag":
            x1, y1 = self._point(args, "x1", "y1")
            x2, y2 = self._point(args, "x2", "y2")
            injector.drag(x1, y1, x2, y2)
            return {"dragged": True}
        if verb == "scroll":
            px, py = self._point(args)
            try:
                dx, dy = int(args.get("dx") or 0), int(args.get("dy") if args.get("dy") is not None else -3)
            except (TypeError, ValueError):
                raise VerbError("out_of_range", "dx/dy must be integers")
            if not (-20 <= dx <= 20 and -20 <= dy <= 20):
                raise VerbError("out_of_range", "dx/dy are limited to ±20 notches")
            injector.scroll(px, py, dx, dy)
            return {"dx": dx, "dy": dy}
        if verb == "type_text":
            text = args.get("text")
            if not isinstance(text, str) or not text or len(text) > MAX_TEXT_CHARS:
                raise VerbError("out_of_range", f"text must be 1-{MAX_TEXT_CHARS} characters")
            injector.type_text(text)
            return {"chars": len(text)}
        if verb == "press_keys":
            mods, vk = parse_chord(str(args.get("keys") or ""))
            injector.press(mods, vk)
            return {"keys": str(args.get("keys"))}
        raise VerbError("unsupported", f"{verb!r} is not a verb this computer executes")
