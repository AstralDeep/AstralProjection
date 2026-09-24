"""Tests for astral_client/app.py: the packaged app icon is present everywhere
PyInstaller and configure() look for it, decodes with a 256px frame, matches the
brand mark, and is actually applied plus a stable AppUserModelID.
"""

from __future__ import annotations

import importlib.util
import pathlib

import pytest

pytest.importorskip("PySide6")

from astral_client.app import APP_USER_MODEL_ID, app_icon_path, configure  # noqa: E402

REPO = pathlib.Path(__file__).resolve().parents[2]
SPEC = REPO / "windows-client" / "AstralDeep.spec"
GENERATOR = REPO / "windows-client" / "Scripts" / "generate_win_icon.py"


def _generator():
    spec = importlib.util.spec_from_file_location("generate_win_icon", GENERATOR)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_icon_file_is_where_every_consumer_looks():
    ico = pathlib.Path(app_icon_path())
    assert ico.exists(), f"app icon missing at {ico}"
    text = SPEC.read_text(encoding="utf-8")
    assert 'icon="assets/astraldeep.ico"' in text
    assert '("assets/astraldeep.ico", "assets")' in text


def test_icon_loads_with_a_256_frame(qapp):
    from PySide6.QtGui import QIcon

    icon = QIcon(app_icon_path())
    assert not icon.isNull(), "Qt could not load the app icon"
    sizes = {(s.width(), s.height()) for s in icon.availableSizes()}
    assert (256, 256) in sizes, f"no 256px frame (Explorer/taskbar source): {sizes}"
    assert (16, 16) in sizes, f"no 16px frame (title bar / tray): {sizes}"


def test_icon_is_the_brand_mark(qapp):
    assert _generator().check() == 0


def test_configure_sets_the_window_icon(qapp):
    prev_style, prev_font = qapp.styleSheet(), qapp.font()
    try:
        configure(qapp)
        assert not qapp.windowIcon().isNull()
    finally:
        qapp.setStyleSheet(prev_style)
        qapp.setFont(prev_font)


def test_app_user_model_id_is_stable():
    assert APP_USER_MODEL_ID == "AstralDeep.WindowsClient"
