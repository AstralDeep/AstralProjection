"""Tests that every in-repo copy of the theme presets names the same presets with the same thirteen
palette values as THEME_PRESETS in src/astralprojection/chrome/personalization.py (the web
client.js PRESETS and the Windows, Android and Apple client themes, each parsed from source), and
that those values keep text at 4.5:1 and field borders at 3:1 on every surface a preset defines.
"""

from __future__ import annotations

import ast
from collections.abc import Callable
from pathlib import Path
import re

import pytest

ROOT = Path(__file__).resolve().parents[1]
ROLES = frozenset({
    "bg", "surface", "primary", "secondary", "text", "muted", "accent",
    "success", "warning", "error", "info", "on_error", "field_border",
})
CANONICAL = ROOT / "src/astralprojection/chrome/personalization.py"
WEB = ROOT / "backend/webrender/static/client.js"
WINDOWS = ROOT / "windows-client/astral_client/theme.py"
ANDROID = ROOT / "android-client/app/src/main/kotlin/com/personalailabs/astraldeep/app/ui/theme/Theme.kt"
APPLE = ROOT / "apple-clients/NativeAppearance/Theme.swift"

Presets = dict[str, dict[str, str]]

GRAPHITE = {
    "bg": "#121214",
    "surface": "#1B1B1F",
    "primary": "#7C3AED",
    "secondary": "#6E6E78",
    "text": "#ECECEF",
    "muted": "#93939B",
    "accent": "#A78BFA",
    "success": "#5EC28F",
    "warning": "#D4A94A",
    "error": "#E17272",
    "info": "#9A8CF2",
    "on_error": "#121214",
    "field_border": "#6E6E75",
}
MIDNIGHT = {
    "bg": "#0F1221",
    "surface": "#1A1E2E",
    "primary": "#6366F1",
    "secondary": "#8B5CF6",
    "text": "#F3F4F6",
    "muted": "#9CA3AF",
    "accent": "#06B6D4",
    "success": "#5EC28F",
    "warning": "#D4A94A",
    "error": "#E27777",
    "info": "#9A8CF2",
    "on_error": "#0F1221",
    "field_border": "#686F7E",
}
DAYLIGHT = {
    "bg": "#F8FAFC",
    "surface": "#FFFFFF",
    "primary": "#4F46E5",
    "secondary": "#7C3AED",
    "text": "#1E293B",
    "muted": "#58667B",
    "accent": "#067590",
    "success": "#147739",
    "warning": "#955B06",
    "error": "#B91C1C",
    "info": "#4338CA",
    "on_error": "#FFFFFF",
    "field_border": "#7F8A9B",
}


def _hex(value: str) -> str:
    assert re.fullmatch(r"#?[0-9A-Fa-f]{6}", value), value
    return "#" + value.lstrip("#").upper()


def _normalized(presets: dict) -> Presets:
    return {name: {role: _hex(value) for role, value in palette.items()} for name, palette in presets.items()}


def _python_presets(source: str, name: str) -> Presets:
    for node in ast.parse(source).body:
        targets = node.targets if isinstance(node, ast.Assign) else [getattr(node, "target", None)]
        if any(isinstance(target, ast.Name) and target.id == name for target in targets):
            return _normalized(ast.literal_eval(node.value))
    raise AssertionError(f"{name} is not assigned at module level")


def _canonical_presets(source: str) -> Presets:
    return _python_presets(source, "THEME_PRESETS")


def _windows_presets(source: str) -> Presets:
    return _python_presets(source, "PRESETS")


def _web_presets(source: str) -> Presets:
    block = re.search(r"\n  var PRESETS = \{\n(?P<body>.*?)\n  \};\n", source, re.S)
    assert block, "client.js PRESETS block is missing"
    presets: Presets = {}
    for line in block["body"].splitlines():
        entry = re.fullmatch(r"    (\w+): \{ (.+) \},", line)
        assert entry, f"unparsed PRESETS line: {line!r}"
        pairs = re.findall(r'(\w+): "(#[0-9A-Fa-f]{6})"', entry[2])
        assert len(pairs) == entry[2].count(":"), line
        presets[entry[1]] = dict(pairs)
    return _normalized(presets)


def _snake(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def _android_presets(source: str) -> Presets:
    fields = re.search(r"data class ThemePalette\((?P<params>.*?)\)\s*\{", source, re.S)
    table = re.search(
        r"val THEME_PRESETS: Map<String, ThemePalette> =\s*mapOf\((?P<body>.*?)\n\s*\)\n", source, re.S
    )
    assert fields and table, "Android ThemePalette or THEME_PRESETS is missing"
    order = [_snake(name) for name in re.findall(r"val (\w+): String", fields["params"])]
    entries = list(re.finditer(r'"(\w+)" to\s+ThemePalette\((?P<args>.*?)\),?\s*(?=\n\s*"\w+" to|\Z)', table["body"], re.S))
    assert entries, "Android THEME_PRESETS has no entries"
    leftover = re.sub(r'"(\w+)" to\s+ThemePalette\((.*?)\),?\s*(?=\n\s*"\w+" to|\Z)', "", table["body"], flags=re.S)
    assert not leftover.strip(), f"unparsed THEME_PRESETS text: {leftover!r}"
    presets: Presets = {}
    for entry in entries:
        values = re.findall(r'"(#[0-9A-Fa-f]{6})"', entry["args"])
        assert len(values) == len(order), entry[0]
        presets[entry[1]] = dict(zip(order, values))
    return _normalized(presets)


def _apple_all(source: str) -> Presets:
    struct = re.search(r"struct AstralPalette: Equatable \{(?P<body>.*?)\n    static let graphite", source, re.S)
    switch = re.search(r"func apply\(preset: String\) \{(?P<body>.*?)\n        default:", source, re.S)
    assert struct and switch, "Apple AstralPalette defaults or apply(preset:) is missing"
    hex_color = re.compile(r"(\w+)(?::| =) Color\(hex: 0x([0-9A-Fa-f]{6})\)")
    defaults = {_snake(name): value for name, value in hex_color.findall(struct["body"])}
    presets: Presets = {"graphite": defaults}
    cases = switch["body"] + "\n"
    for name, body in re.findall(r'case "(\w+)":\s*palette = AstralPalette\((.*?)\)\n', cases, re.S):
        explicit = {_snake(role): value for role, value in hex_color.findall(body)}
        presets[name] = {**defaults, **explicit}
    return _normalized(presets)


def _apple_presets(source: str) -> Presets:
    return {name: {role: value for role, value in palette.items() if role in ROLES}
            for name, palette in _apple_all(source).items()}


COPIES: dict[str, tuple[Path, Callable[[str], Presets], str]] = {
    "web client.js": (WEB, _web_presets, "var PRESETS = {"),
    "Windows theme.py": (WINDOWS, _windows_presets, "PRESETS = {"),
    "Android Theme.kt": (ANDROID, _android_presets, "val THEME_PRESETS"),
    "Apple Theme.swift": (APPLE, _apple_presets, "struct AstralPalette"),
}


def _divergence(canonical: Presets, copy: Presets) -> list[str]:
    problems = [f"preset set {sorted(copy)} != {sorted(canonical)}"] if set(copy) != set(canonical) else []
    for name in sorted(set(copy) & set(canonical)):
        for role in sorted(ROLES):
            if copy[name].get(role) != canonical[name].get(role):
                problems.append(f"{name}.{role}: {copy[name].get(role)} != {canonical[name].get(role)}")
    return problems


def test_canonical_presets_define_all_seven_roles_as_hex_colors() -> None:
    canonical = _canonical_presets(CANONICAL.read_text(encoding="utf-8"))

    assert {"graphite", "midnight"} <= set(canonical)
    for palette in canonical.values():
        assert set(palette) == ROLES


def test_graphite_is_the_first_canonical_preset_and_midnight_keeps_its_values() -> None:
    canonical = _canonical_presets(CANONICAL.read_text(encoding="utf-8"))

    assert next(iter(canonical)) == "graphite"
    assert canonical["graphite"] == GRAPHITE
    assert canonical["midnight"] == MIDNIGHT
    assert len(canonical) == 6


@pytest.mark.parametrize("copy", sorted(COPIES))
def test_graphite_leads_every_copy_with_the_same_values(copy: str) -> None:
    path, parse, _ = COPIES[copy]
    presets = parse(path.read_text(encoding="utf-8"))

    assert next(iter(presets)) == "graphite"
    assert presets["graphite"] == GRAPHITE
    assert presets["midnight"] == MIDNIGHT


def test_windows_and_android_default_to_graphite() -> None:
    windows = WINDOWS.read_text(encoding="utf-8")
    android = ANDROID.read_text(encoding="utf-8")

    assert 'PALETTE: dict = dict(PRESETS["graphite"])' in windows
    assert 'DEFAULT_PALETTE = THEME_PRESETS.getValue("graphite")' in android


@pytest.mark.parametrize("copy", sorted(COPIES))
def test_every_in_repo_preset_copy_matches_the_canonical_presets(copy: str) -> None:
    canonical = _canonical_presets(CANONICAL.read_text(encoding="utf-8"))
    path, parse, _ = COPIES[copy]

    assert _divergence(canonical, parse(path.read_text(encoding="utf-8"))) == []


@pytest.mark.parametrize("copy", sorted(COPIES))
def test_a_changed_palette_value_in_any_copy_is_detected(copy: str) -> None:
    canonical = _canonical_presets(CANONICAL.read_text(encoding="utf-8"))
    path, parse, marker = COPIES[copy]
    source = path.read_text(encoding="utf-8")
    table = source.index(marker)
    value = re.compile(r"(?:#|0x)(8B5CF6)").search(source, table)
    assert value, copy
    mutated = source[: value.start(1)] + "8B5CF7" + source[value.end(1):]

    assert _divergence(canonical, parse(mutated)) == ["midnight.secondary: #8B5CF7 != #8B5CF6"]


def test_a_missing_or_renamed_preset_is_detected() -> None:
    canonical = _canonical_presets(CANONICAL.read_text(encoding="utf-8"))
    web = _web_presets(WEB.read_text(encoding="utf-8"))
    renamed = {("dusk" if name == "sunset" else name): palette for name, palette in web.items()}

    assert _divergence(canonical, renamed)
    assert _divergence(canonical, {name: web[name] for name in list(web)[:-1]})


@pytest.mark.parametrize("copy", sorted(COPIES))
def test_a_copy_whose_preset_table_moved_fails_instead_of_passing_empty(copy: str) -> None:
    _, parse, _ = COPIES[copy]

    with pytest.raises(AssertionError):
        parse("")


def test_a_canonical_table_that_moved_fails_instead_of_passing_empty() -> None:
    with pytest.raises(AssertionError):
        _canonical_presets("OTHER = {}\n")


TEXT_FLOOR = 4.5
BOUNDARY_FLOOR = 3.0
BADGE_TINT = 0.14
TEXT_ROLES = ("text", "muted", "accent", "success", "warning", "error", "info")
STATUS_ROLES = ("success", "warning", "error", "info")


def _rgb(value: str) -> tuple[float, float, float]:
    return tuple(int(value[index:index + 2], 16) for index in (1, 3, 5))


def _luminance(rgb: tuple[float, ...]) -> float:
    def channel(byte: float) -> float:
        unit = byte / 255
        return unit / 12.92 if unit <= 0.03928 else ((unit + 0.055) / 1.055) ** 2.4

    red, green, blue = (channel(byte) for byte in rgb)
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


def _contrast(foreground: tuple[float, ...] | str, background: tuple[float, ...] | str) -> float:
    pair = [_luminance(_rgb(c) if isinstance(c, str) else c) for c in (foreground, background)]
    return (max(pair) + 0.05) / (min(pair) + 0.05)


def _over(foreground: str, alpha: float, background: str) -> tuple[float, ...]:
    return tuple(f * alpha + b * (1 - alpha) for f, b in zip(_rgb(foreground), _rgb(background)))


def _surfaces() -> dict[str, dict[str, str]]:
    """Each preset's palette plus the Apple client's surface2, the lightest inset surface."""
    canonical = _canonical_presets(CANONICAL.read_text(encoding="utf-8"))
    apple = _apple_all(APPLE.read_text(encoding="utf-8"))
    return {name: {**canonical[name], "surface2": apple[name]["surface2"]} for name in canonical}


PRESET_NAMES = sorted(_surfaces())


@pytest.mark.parametrize("preset", PRESET_NAMES)
def test_text_roles_keep_four_and_a_half_to_one_on_every_surface(preset: str) -> None:
    palette = _surfaces()[preset]

    for role in TEXT_ROLES:
        for surface in ("bg", "surface", "surface2"):
            ratio = _contrast(palette[role], palette[surface])
            assert ratio >= TEXT_FLOOR, f"{preset}.{role} on {surface}: {ratio:.2f}"


@pytest.mark.parametrize("preset", PRESET_NAMES)
def test_badge_text_keeps_four_and_a_half_to_one_on_its_own_tint(preset: str) -> None:
    palette = _surfaces()[preset]

    for surface in ("bg", "surface"):
        neutral = _contrast(palette["muted"], _over(palette["muted"], BADGE_TINT, palette[surface]))
        assert neutral >= TEXT_FLOOR, f"{preset} neutral badge on {surface}: {neutral:.2f}"
    for role in STATUS_ROLES:
        tinted = _contrast(palette[role], _over(palette[role], BADGE_TINT, palette["surface"]))
        assert tinted >= TEXT_FLOOR, f"{preset} {role} badge: {tinted:.2f}"


@pytest.mark.parametrize("preset", PRESET_NAMES)
def test_danger_label_keeps_four_and_a_half_to_one_on_the_error_fill(preset: str) -> None:
    palette = _surfaces()[preset]

    assert _contrast(palette["on_error"], palette["error"]) >= TEXT_FLOOR


@pytest.mark.parametrize("preset", PRESET_NAMES)
def test_field_borders_keep_three_to_one_on_every_surface(preset: str) -> None:
    palette = _surfaces()[preset]

    for surface in ("bg", "surface", "surface2"):
        ratio = _contrast(palette["field_border"], palette[surface])
        assert ratio >= BOUNDARY_FLOOR, f"{preset}.field_border on {surface}: {ratio:.2f}"


def test_the_contrast_check_would_catch_the_values_it_replaced() -> None:
    assert _contrast("#FFFFFF", "#E06C6C") < TEXT_FLOOR
    assert _contrast("#5EC28F", "#FFFFFF") < TEXT_FLOOR
    assert _contrast("#8C8C95", _over("#8C8C95", BADGE_TINT, "#1B1B1F")) < TEXT_FLOOR
    assert _contrast("#2D2D31", "#1B1B1F") < BOUNDARY_FLOOR
