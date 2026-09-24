"""Manual screenshot harness: drives a real MainWindow against a mock-auth orchestrator
and captures PNGs at each stage as desktop verification evidence. Runs on the native
Qt backend by default, not offscreen, so captured text isn't glyphless tofu.
"""

from __future__ import annotations

import argparse
import os
import sys
import time

if "--offscreen" in sys.argv:
    os.environ["QT_QPA_PLATFORM"] = "offscreen"
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

os.environ.setdefault("ASTRAL_WIN_AGENT", "0")

from PySide6.QtGui import QFont, QFontDatabase, QFontMetrics  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

from astral_client.app import MainWindow, configure  # noqa: E402


def assert_fonts_legible() -> str:
    families = [f for f in QFontDatabase.families() if f and not f.startswith("@")]
    if not families:
        raise SystemExit(
            "FONT GATE: no font families available to Qt — captures would render "
            "as tofu. Run on a host with system fonts (this harness must NOT use "
            "the offscreen platform for evidence). See feature 044 T052."
        )
    fm = QFontMetrics(QFont())
    if fm.horizontalAdvance("AstralDeep 0123") <= 0:
        raise SystemExit("FONT GATE: default font reports zero text advance — illegible.")
    return QFont().family() or families[0]


def pump(app: QApplication, seconds: float) -> None:
    end = time.time() + seconds
    while time.time() < end:
        app.processEvents()
        time.sleep(0.02)


def grab(win: MainWindow, path: str) -> None:
    win.grab().save(path)
    status = win.topbar._mark.toolTip().encode("ascii", "replace").decode()
    print("saved", path, "| status:", status)


def grab_settings_menu(win: MainWindow, app: QApplication, path: str) -> None:
    btn = win.topbar.settings_btn
    win.topbar._menu.popup(btn.mapToGlobal(btn.rect().bottomLeft()))
    pump(app, 0.6)
    win.topbar._menu.grab().save(path)
    labels = [a.text() for a in win.topbar._menu.actions() if a.text()]
    win.topbar._menu.close()
    print("saved", path, "| menu:", ", ".join(labels).encode("ascii", "replace").decode())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="ws://127.0.0.1:8001/ws")
    ap.add_argument("--token", default="dev-token")
    ap.add_argument("--prompt", default="roll 3 dice and show the results")
    ap.add_argument("--out", default=".")
    ap.add_argument("--offscreen", action="store_true",
                    help="force the offscreen platform (text-agnostic smoke runs only)")
    args = ap.parse_args()

    app = QApplication(sys.argv)
    configure(app)
    family = assert_fonts_legible()
    print("font gate OK — rendering with:", family.encode("ascii", "replace").decode())
    win = MainWindow(args.url, args.token)
    win.resize(1300, 860)
    win.show()

    pump(app, 5)
    grab(win, os.path.join(args.out, "shot_welcome.png"))
    grab_settings_menu(win, app, os.path.join(args.out, "shot_settings_menu.png"))

    win._input.setText(args.prompt)
    win._send()
    pump(app, float(os.getenv("SHOT_WAIT", "28")))
    grab(win, os.path.join(args.out, "shot_chat.png"))

    win.client.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
