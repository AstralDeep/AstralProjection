"""Link destinations and code must never be rewritten as Markdown emphasis."""
from html.parser import HTMLParser

import pytest

from webrender import render_one
from webrender.sanitize import block_md, inline_md


class _Links(HTMLParser):
    def __init__(self, markup):
        super().__init__()
        self.anchors = []
        self.feed(markup)

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.anchors.append(dict(attrs))


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
