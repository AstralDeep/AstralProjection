"""Tests that every in-repo copy of the theme presets names the same presets with the same seven
palette values as THEME_PRESETS in src/astralprojection/chrome/personalization.py: the web
client.js PRESETS and the Windows, Android and Apple client themes, each parsed from source.
"""

from __future__ import annotations

import ast
from collections.abc import Callable
from pathlib import Path
import re

import pytest

ROOT = Path(__file__).resolve().parents[1]
ROLES = frozenset({"bg", "surface", "primary", "secondary", "text", "muted", "accent"})
CANONICAL = ROOT / "src/astralprojection/chrome/personalization.py"
WEB = ROOT / "backend/webrender/static/client.js"
WINDOWS = ROOT / "windows-client/astral_client/theme.py"
ANDROID = ROOT / "android-client/app/src/main/kotlin/com/personalailabs/astraldeep/app/ui/theme/Theme.kt"
APPLE = ROOT / "apple-clients/NativeAppearance/Theme.swift"

Presets = dict[str, dict[str, str]]


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


def _android_presets(source: str) -> Presets:
    fields = re.search(r"data class ThemePalette\((?P<params>.*?)\)\s*\{", source, re.S)
    table = re.search(
        r"val THEME_PRESETS: Map<String, ThemePalette> =\s*mapOf\((?P<body>.*?)\n\s*\)\n", source, re.S
    )
    assert fields and table, "Android ThemePalette or THEME_PRESETS is missing"
    order = re.findall(r"val (\w+): String", fields["params"])
    presets: Presets = {}
    for line in filter(str.strip, table["body"].splitlines()):
        entry = re.fullmatch(r'\s*"(\w+)" to ThemePalette\((.*)\),', line)
        assert entry, f"unparsed THEME_PRESETS line: {line!r}"
        values = re.findall(r'"(#[0-9A-Fa-f]{6})"', entry[2])
        assert len(values) == len(order), line
        presets[entry[1]] = dict(zip(order, values))
    return _normalized(presets)


def _apple_presets(source: str) -> Presets:
    struct = re.search(r"struct AstralPalette: Equatable \{(?P<body>.*?)\n    static let midnight", source, re.S)
    switch = re.search(r"func apply\(preset: String\) \{(?P<body>.*?)\n        default:", source, re.S)
    assert struct and switch, "Apple AstralPalette defaults or apply(preset:) is missing"
    defaults = dict(re.findall(r"var (\w+) = Color\(hex: 0x([0-9A-Fa-f]{6})\)", struct["body"]))
    presets: Presets = {"midnight": defaults}
    cases = switch["body"] + "\n"
    for name, body in re.findall(r'case "(\w+)":\s*palette = AstralPalette\((.*?)\)\n', cases, re.S):
        presets[name] = {**defaults, **dict(re.findall(r"(\w+): Color\(hex: 0x([0-9A-Fa-f]{6})\)", body))}
    return {name: {role: value for role, value in palette.items() if role in ROLES}
            for name, palette in _normalized(presets).items()}


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

    assert "midnight" in canonical
    for palette in canonical.values():
        assert set(palette) == ROLES


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
