"""Tests for backend/webrender/sanitize.py: link destinations and code spans survive
markdown formatting literally, unsafe destinations stay blocked, and user text cannot
forge protected fragment tokens.
"""

from html.parser import HTMLParser

import pytest

from webrender import render_one
from webrender import sanitize
from webrender.sanitize import block_md, inline_md, plain_md


class _Links(HTMLParser):
    def __init__(self, markup):
        super().__init__()
        self.anchors = []
        self.feed(markup)

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.anchors.append(dict(attrs))


class _PatternWork:
    def __init__(self, pattern):
        self.pattern = pattern
        self.searched = 0

    def search(self, text, start=0):
        match = self.pattern.search(text, start)
        self.searched += (len(text) if match is None else match.end()) - start
        return match

    def finditer(self, text, start=0):
        cursor = start
        for match in self.pattern.finditer(text, start):
            self.searched += match.end() - cursor
            cursor = match.end()
            yield match
        self.searched += len(text) - cursor


@pytest.mark.parametrize("url", [
    "https://en.wikipedia.org/wiki/Dog_grooming",
    "https://example.test/a_b_c?one=1&two=two_words#some_section",
    "https://example.test/__bold__/*literal*/~~literal~~/`literal`",
    "https://example.test/a%20b?x=%3Cem%3E&y=1",
    "/docs/some_page",
    "mailto:first_last@example.test",
])
@pytest.mark.parametrize("render", [inline_md, block_md])
def test_destinations_survive_formatting_exactly(url, render):
    out = render(f"Source: [{url}]({url}) and _emphasis_.")
    link, = _Links(out).anchors
    assert link["href"] == url
    assert link["target"] == "_blank"
    assert link["rel"] == "noopener noreferrer"
    assert "<em>emphasis</em>" in out


def test_markdown_text_component_preserves_wikipedia_source():
    url = "https://en.wikipedia.org/wiki/Dog_grooming"
    out = render_one({"type": "text", "variant": "markdown",
                      "content": f"Source: [{url}]({url})"})
    assert _Links(out).anchors[0]["href"] == url
    assert "<em>" not in out


def test_link_label_and_surrounding_emphasis_still_render():
    out = inline_md("**See [*the page* and `a_b`](https://example.test/a_b)**")
    assert out.startswith("<strong") and out.endswith("</strong>")
    assert "<em>the page</em>" in out
    assert ">a_b</code>" in out
    assert _Links(out).anchors[0]["href"] == "https://example.test/a_b"


@pytest.mark.parametrize("url", [
    "https://example.test/A_(B)",
    "https://example.test/A_(B_(C))",
    "https://en.wikipedia.org/wiki/Foo_(bar)",
])
def test_balanced_parentheses_survive_in_link_destinations(url):
    out = inline_md(f"**[page]({url})**")
    link, = _Links(out).anchors
    assert link["href"] == url
    assert out.startswith("<strong") and out.endswith("</strong>")


@pytest.mark.parametrize(("source", "expected"), [
    (r"[escaped](https://example.test/A\(B\))", "https://example.test/A(B)"),
    (r"[escaped close](https://example.test/A\)B)", "https://example.test/A)B"),
])
def test_escaped_parentheses_are_literal_destination_characters(source, expected):
    link, = _Links(inline_md(source)).anchors
    assert link["href"] == expected


@pytest.mark.parametrize("source", [
    "[empty]()",
    "[space](https://example.test/a b)",
    "[missing close](https://example.test/A_(B)",
    "[too deep](https://example.test/" + "(" * 9 + "x" + ")" * 9 + ")",
    "[too long](https://example.test/" + "x" * 2049 + ")",
])
def test_malformed_or_unbounded_destinations_are_not_links(source):
    assert not _Links(inline_md(source)).anchors


def test_destination_bounds_are_inclusive_and_parenthesis_nesting_is_limited():
    prefix = "https://example.test/"
    url = prefix + "x" * (2048 - len(prefix))
    link, = _Links(inline_md(f"[maximum]({url})")).anchors
    assert link["href"] == url

    nested = "https://example.test/" + "(" * 8 + "x" + ")" * 8
    link, = _Links(inline_md(f"[nested]({nested})")).anchors
    assert link["href"] == nested


def test_link_destinations_inside_code_remain_literal():
    out = inline_md("`[page](https://example.test/A_(B))`")
    assert not _Links(out).anchors
    assert "[page](https://example.test/A_(B))" in out


def test_plain_text_conversion_removes_a_balanced_parenthesis_destination():
    assert plain_md("[page](https://example.test/A_(B))") == "page"


def test_code_keeps_markup_literal_and_links_inert():
    out = inline_md("`**bold** _em_ ~~strike~~ [link](https://example.test)`")
    assert "<strong" not in out and "<em>" not in out and "<del>" not in out
    assert not _Links(out).anchors
    assert "**bold** _em_ ~~strike~~ [link](https://example.test)" in out


@pytest.mark.parametrize("url", ["javascript:alert", "data:text/html,evil", "vbscript:evil"])
def test_unsafe_destinations_still_blocked(url):
    out = inline_md(f"[**click**]({url})")
    assert _Links(out).anchors[0]["href"] == "#"
    assert url not in out


def test_html_and_attribute_injection_stay_escaped():
    out = inline_md('[<img/src=x/onerror=alert>](https://example.test/"onmouseover="evil)')
    link, = _Links(out).anchors
    assert link["href"] == 'https://example.test/"onmouseover="evil'
    assert "onmouseover" not in link
    assert "<img" not in out and "&lt;img" in out


def test_user_text_cannot_forge_protected_fragment_tokens(monkeypatch):
    markers = iter(["collision", "fresh", "label"])
    monkeypatch.setattr("webrender.sanitize.secrets.token_hex", lambda _: next(markers))
    forged = "\x00mdcollision:0\x00mdcollision:"
    out = inline_md(f"{forged} [source](https://example.test/a_b) `code`")
    assert out.startswith(forged + " ")
    assert len(_Links(out).anchors) == 1
    assert out.count("<code") == 1


@pytest.mark.parametrize("count", [128, 256, 512])
@pytest.mark.parametrize("shape", [
    "code_only", "links_only", "code_before_link", "links_before_code", "mixed", "malformed",
])
def test_token_search_work_is_bounded_by_input_length(monkeypatch, count, shape):
    code = "`code` "
    link = "[page](https://example.test/A_(B)) "
    sources = {
        "code_only": code * count,
        "links_only": link * count,
        "code_before_link": code * count + link,
        "links_before_code": link * count + code,
        "mixed": "`[literal](https://example.test/x)` [label `value`](https://example.test/y) " * count,
        "malformed": "[invalid](has space) `code` " * count,
    }
    source = sources[shape]
    code_work = _PatternWork(sanitize._CODE)
    link_work = _PatternWork(sanitize._LINK_START)
    monkeypatch.setattr(sanitize, "_CODE", code_work)
    monkeypatch.setattr(sanitize, "_LINK_START", link_work)

    out = inline_md(source)

    assert code_work.searched + link_work.searched <= 4 * len(source)
    expected_links = {
        "code_only": 0, "links_only": count, "code_before_link": 1,
        "links_before_code": count, "mixed": count, "malformed": 0,
    }
    assert len(_Links(out).anchors) == expected_links[shape]
