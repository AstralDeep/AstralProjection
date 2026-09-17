"""Feature 089 (T050): every color in the web stylesheet is a theme token.

The 089 layout is scored with colors excluded, because colors come from
``ThemeView``: ``theme_apply`` and the color picker mutate the ``--astral-*``
channel triplets at runtime and the whole interface is expected to follow. A
literal anywhere outside the ``:root`` block is a color that does not follow —
it stays put while everything around it changes, which is exactly the kind of
defect a person only notices after picking a light theme.

So: literals are allowed where the palette is *defined* (``:root`` and its
dark/light variants) and nowhere else.
"""

from __future__ import annotations

import re

import pytest

from astralprojection import resources

# `#abc`, `#aabbcc`, `#aabbccdd`, `rgb(12 34 56)`, `rgba(1, 2, 3, .4)`.
# `rgb(var(--astral-text) / 0.08)` is a token reference, not a literal, and
# does not match because what follows the paren is `var(`, not a digit.
LITERAL = re.compile(r"#[0-9a-fA-F]{3,8}\b|rgba?\(\s*[0-9]")

# Rules that define the palette. Everything else consumes it.
DEFINITION_SELECTORS = (":root", "@media (prefers-color-scheme")


def _stylesheet() -> str:
    return resources.static_path("astral.css").read_text(encoding="utf-8")


def _definition_spans(css: str) -> list[tuple[int, int]]:
    """Character ranges of the palette-defining blocks."""
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
    """A guard on the guard: if :root ever stops carrying literals, the test
    above would pass vacuously and stop protecting anything."""
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
    """The regex has to match the shapes people actually write."""
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
    """The literals were replaced by these; a rename would silently blank the
    interface, since an undefined var() falls back to nothing."""
    assert f"{token}:" in _stylesheet()
