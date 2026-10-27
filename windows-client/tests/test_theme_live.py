"""Tests for astral_client/theme.py and renderer.py: live theming — apply_theme from
preset/colors-map/single-channel specs, the five presets, and the interactive
color_picker routed through RenderContext.
"""

import os

import pytest

pytest.importorskip("PySide6")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import astral_client.theme as T  # noqa: E402
from astral_client import renderer as rmod  # noqa: E402
from astral_client.renderer import RenderContext, render  # noqa: E402


@pytest.fixture(autouse=True)
def _restore_theme():
    snap = dict(T.PALETTE)
    yield
    T.PALETTE.clear()
    T.PALETTE.update(snap)
    T._derive()
    T.APP_STYLESHEET = T.build_stylesheet()


def test_build_stylesheet_nonempty_contains_palette():
    s = T.build_stylesheet()
    assert isinstance(s, str) and len(s) > 100
    assert T.PRIMARY in s
    assert T.TEXT in s
    assert T.SURFACE_2 in s


def test_apply_preset_changes_palette_and_stylesheet():
    before = T.build_stylesheet()
    assert T.apply_theme("daylight") is True
    assert T.PALETTE["bg"] == T.PRESETS["daylight"]["bg"]
    assert T.PRIMARY == T.PRESETS["daylight"]["primary"]
    assert T.build_stylesheet() != before
    assert T.apply_theme("daylight") is False


def test_apply_preset_via_dict():
    assert T.apply_theme({"preset": "ocean"}) is True
    assert T.PALETTE["primary"] == T.PRESETS["ocean"]["primary"]


def test_apply_colors_map():
    assert T.apply_theme({"colors": {"primary": "#123456", "text": "#ABCDEF"}}) is True
    assert T.PALETTE["primary"] == "#123456"
    assert T.PRIMARY == "#123456"
    assert "#123456" in T.build_stylesheet()


def test_colors_map_overrides_preset_name():
    assert T.apply_theme({"preset": "midnight",
                          "colors": dict(T.PRESETS["ocean"])}) is True
    assert T.PALETTE == T.PRESETS["ocean"]
    assert T.PRIMARY == T.PRESETS["ocean"]["primary"]


def test_apply_single_color_key():
    assert T.apply_theme({"color_key": "accent", "color_value": "#FF8800"}) is True
    assert T.PALETTE["accent"] == "#FF8800"
    assert T.ACCENT == "#FF8800"


def test_apply_string_preset_shorthand():
    assert T.apply_theme("sunset") is True
    assert T.PALETTE["bg"] == T.PRESETS["sunset"]["bg"]


def test_no_op_specs_return_false():
    assert T.apply_theme("does-not-exist") is False
    assert T.apply_theme({"color_key": "primary", "color_value": "nothex"}) is False
    assert T.apply_theme({}) is False
    assert T.apply_theme(None) is False


def test_six_presets_thirteen_channels():
    assert set(T.PRESETS) == {"graphite", "midnight", "daylight", "ocean", "sunset", "forest"}
    for chans in T.PRESETS.values():
        assert set(chans) == {"bg", "surface", "primary", "secondary",
                              "text", "muted", "accent", "success", "warning",
                              "error", "info", "on_error", "field_border"}


GRAPHITE = {"bg": "#121214", "surface": "#1B1B1F", "primary": "#7C3AED",
            "secondary": "#6E6E78", "text": "#ECECEF", "muted": "#93939B",
            "accent": "#A78BFA", "success": "#5EC28F", "warning": "#D4A94A",
            "error": "#E17272", "info": "#9A8CF2", "on_error": "#121214",
            "field_border": "#6E6E75"}


def test_graphite_is_listed_first_with_the_contract_values():
    assert next(iter(T.PRESETS)) == "graphite"
    assert T.PRESETS["graphite"] == GRAPHITE
    assert T.PRESETS["midnight"]["bg"] == "#0F1221"


def test_a_fresh_module_starts_on_graphite():
    import importlib.util

    spec = importlib.util.spec_from_file_location("astral_client_theme_fresh", T.__file__)
    fresh = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fresh)

    assert fresh.PALETTE == GRAPHITE
    assert fresh.PRIMARY == GRAPHITE["primary"]
    assert fresh.BG == GRAPHITE["bg"]


def test_midnight_is_an_ordinary_preset_that_replaces_graphite():
    T.apply_theme("graphite")
    assert T.apply_theme("midnight") is True
    assert T.PALETTE == T.PRESETS["midnight"]
    assert T.apply_theme("graphite") is True
    assert T.PALETTE == GRAPHITE


def test_color_picker_renders(qapp, native_root):
    from PySide6.QtWidgets import QWidget

    w = native_root(render, {"type": "color_picker", "color_key": "primary",
                "value": T.PALETTE["primary"], "label": "Primary"},
               RenderContext(emit=lambda *a: None))
    assert isinstance(w, QWidget)


def test_color_picker_requests_save_before_server_application(qapp, monkeypatch, native_root):
    from PySide6.QtWidgets import QPushButton

    monkeypatch.setattr(rmod, "_choose_color", lambda *a, **k: "#FF8800")
    seen = []
    ctx = RenderContext(emit=lambda a, p: seen.append((a, p)))
    current = T.PALETTE["accent"]
    w = native_root(render, {"type": "color_picker", "color_key": "accent",
                "value": current, "label": "Accent"}, ctx)
    w.findChild(QPushButton).click()
    assert seen[-1][0] == "save_theme"
    assert seen[-1][1]["theme"] == {"color_key": "accent", "color_value": "#FF8800"}
    assert T.PALETTE["accent"] == current
    native_root(render, {"type": "theme_apply", "colors": {"accent": "#FF8800"}}, ctx)
    assert T.PALETTE["accent"] == "#FF8800"


def test_color_picker_cancel_emits_nothing(qapp, monkeypatch, native_root):
    from PySide6.QtWidgets import QPushButton

    monkeypatch.setattr(rmod, "_choose_color", lambda *a, **k: None)
    seen = []
    w = native_root(render, {"type": "color_picker", "color_key": "primary", "value": T.PALETTE["primary"]},
               RenderContext(emit=lambda a, p: seen.append((a, p))))
    w.findChild(QPushButton).click()
    assert seen == []


def test_theme_apply_component_applies_live(qapp, native_root):
    native_root(render, {"type": "theme_apply", "preset": "forest", "message": "applied"},
           RenderContext(emit=lambda *a: None))
    assert T.PALETTE["primary"] == T.PRESETS["forest"]["primary"]


def test_theme_apply_routes_through_ctx_callback(qapp, native_root):
    seen = []
    before = dict(T.PALETTE)
    native_root(render, {"type": "theme_apply", "preset": "ocean"},
           RenderContext(emit=lambda *a: None,
                         apply_theme=lambda spec: seen.append(spec)))
    assert seen and seen[0]["preset"] == "ocean"
    assert T.PALETTE == before


def test_color_picker_waits_for_theme_apply_callback(qapp, monkeypatch, native_root):
    from PySide6.QtWidgets import QPushButton

    monkeypatch.setattr(rmod, "_choose_color", lambda *a, **k: "#FF8800")
    seen = []
    ctx = RenderContext(emit=lambda a, p: None,
                        apply_theme=lambda spec: seen.append(spec))
    w = native_root(render, {"type": "color_picker", "color_key": "accent",
                "value": T.PALETTE["accent"], "label": "Accent"}, ctx)
    w.findChild(QPushButton).click()
    assert seen == []
    native_root(render, {"type": "theme_apply", "color_key": "accent", "color_value": "#FF8800"}, ctx)
    assert seen == [{"type": "theme_apply", "color_key": "accent", "color_value": "#FF8800"}]


def test_status_colors_and_the_danger_pair_follow_the_active_preset():
    assert T.VARIANT_COLORS["error"][0] == GRAPHITE["error"]
    assert T.ON_ERROR == GRAPHITE["on_error"]
    assert T.apply_theme("daylight") is True
    daylight = T.PRESETS["daylight"]
    for role in ("success", "warning", "error", "info"):
        assert T.VARIANT_COLORS[role][0] == daylight[role]
    assert T.ERROR == daylight["error"]
    assert T.ON_ERROR == "#FFFFFF"
    sheet = T.build_stylesheet()
    assert f"QPushButton#danger {{ background: {daylight['error']}; border: none; color: #FFFFFF;" in sheet


def _contrast(foreground, background):
    def luminance(value):
        channels = [c / 255 for c in T._hex_to_rgb(value)]
        r, g, b = [c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
        return 0.2126 * r + 0.7152 * g + 0.0722 * b

    high, low = sorted((luminance(foreground), luminance(background)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def test_danger_label_and_hover_stay_readable_in_every_preset():
    for name in T.PRESETS:
        T.apply_theme(name)
        assert _contrast(T.ON_ERROR, T.ERROR) >= 4.5, name
        assert _contrast(T.ON_ERROR, T.ERROR_HOVER) >= 4.5, name


def test_fields_draw_their_boundary_with_the_field_border_role():
    sheet = T.build_stylesheet()
    assert f"border: 1px solid {T.FIELD_BORDER};" in sheet
    assert T.FIELD_BORDER == GRAPHITE["field_border"]
    assert T.apply_theme({"color_key": "field_border", "color_value": "#445566"}) is True
    assert T.FIELD_BORDER == "#445566"
    assert "border: 1px solid #445566;" in T.build_stylesheet()


def test_colors_without_status_roles_keep_the_current_status_colors():
    assert T.apply_theme("daylight") is True
    assert T.apply_theme({"colors": {"primary": "#123456"}}) is True
    assert T.VARIANT_COLORS["error"][0] == T.PRESETS["daylight"]["error"]
