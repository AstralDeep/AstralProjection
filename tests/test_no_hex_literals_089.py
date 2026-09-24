"""Tests confirming every color in the web stylesheet
(src/astralprojection/resources.py) is a theme token: literals may appear only inside
the :root/media-query blocks that define the palette, never where it is consumed.
"""

from __future__ import annotations

import re

import pytest

from astralprojection import resources

LITERAL = re.compile(r"#[0-9a-fA-F]{3,8}\b|rgba?\(\s*[0-9]")

DEFINITION_SELECTORS = (":root", "@media (prefers-color-scheme")


def _stylesheet() -> str:
    return resources.static_path("astral.css").read_text(encoding="utf-8")


def _definition_spans(css: str) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    for match in re.finditer(r"^[^\n{]*\{", css, re.MULTILINE):
        selector = match.group(0)[:-1].strip()
        if not selector.startswith(DEFINITION_SELECTORS):
            continue
        depth, index = 1, match.end()
        while index < len(css) and depth:
            if css[index] == "{":
                depth += 1
            elif css[index] == "}":
                depth -= 1
            index += 1
        spans.append((match.start(), index))
    return spans


def _offenders(css: str) -> list[tuple[int, str]]:
    spans = _definition_spans(css)
    offenders: list[tuple[int, str]] = []
    offset = 0
    for number, line in enumerate(css.split("\n"), start=1):
        start = offset
        offset += len(line) + 1
        if not LITERAL.search(line):
            continue
        if any(begin <= start < end for begin, end in spans):
            continue
        offenders.append((number, line.strip()))
    return offenders


def test_the_palette_is_defined_somewhere() -> None:
    css = _stylesheet()
    spans = _definition_spans(css)
    assert spans, "no palette-defining block found in astral.css"
    defined = "".join(css[begin:end] for begin, end in spans)
    assert LITERAL.search(defined), "the palette block carries no color literal"
    assert "--astral-bg:" in defined


def test_no_color_literal_outside_the_palette_block() -> None:
    offenders = _offenders(_stylesheet())
    assert not offenders, "color literals outside the palette block:\n" + "\n".join(
        f"  astral.css:{number}: {line}" for number, line in offenders
    )


def test_the_check_would_catch_a_reintroduced_literal() -> None:
    for snippet in (
        ".x { color: #fff; }",
        ".x { color: #E6E6E6; }",
        ".x { background: rgb(20 22 30); }",
        ".x { background: rgba(255, 255, 255, 0.06); }",
        ".x { border-color: rgba(255,255,255,0.12); }",
    ):
        assert LITERAL.search(snippet), snippet
    for snippet in (
        ".x { color: rgb(var(--astral-text) / 0.08); }",
        ".x { color: var(--text-primary); }",
        ".x { color: color-mix(in srgb, rgb(var(--astral-primary)) 55%, rgb(var(--astral-text))); }",
        ".x { padding: 12px 16px; }",
        ".x { grid-template-columns: repeat(3, minmax(0, 1fr)); }",
    ):
        assert not LITERAL.search(snippet), snippet


@pytest.mark.parametrize("token", [
    "--astral-bg", "--astral-surface", "--astral-primary", "--astral-secondary",
    "--astral-text", "--astral-muted", "--astral-accent",
])
def test_every_theme_channel_is_still_defined(token: str) -> None:
    assert f"{token}:" in _stylesheet()
