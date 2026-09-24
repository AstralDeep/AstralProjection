"""Tests for escape-by-default output safety (AstralPrimitives/src/astralprims,
backend/webrender/sanitize.py): rendered text, table cells, button payloads, and code
blocks stay inert, and the sanitized markdown opt-in strips scripts and handlers.
"""

import astralprims as ap
import webrender
from webrender.sanitize import inline_md, block_md

XSS = '<script>alert(1)</script><img src=x onerror=alert(2)>'


def _no_live_markup(html):
    low = html.lower()
    # escaped onerror= text is safe; check for raw tags
    assert "<script" not in low, f"unescaped <script tag in: {html}"
    assert "<img" not in low, f"unescaped <img tag in: {html}"
    assert "&lt;script&gt;" in html


def test_text_content_escaped():
    html = webrender.render_one(ap.Text(content=XSS).to_dict())
    _no_live_markup(html)


def test_table_cells_escaped():
    html = webrender.render_one(ap.Table(headers=[XSS], rows=[[XSS]]).to_dict())
    _no_live_markup(html)


def test_button_label_and_payload_escaped():
    html = webrender.render_one(ap.Button(label=XSS, action="x", payload={"k": XSS}).to_dict())
    assert "<script" not in html.lower()
    assert "&lt;script&gt;" in html


def test_code_block_escaped():
    html = webrender.render_one(ap.CodeBlock(code=XSS).to_dict())
    _no_live_markup(html)


def test_alert_message_markdown_is_sanitized():
    html = webrender.render_one(ap.Alert(message=XSS + " and **bold**").to_dict())
    assert "<script" not in html.lower() and "<img" not in html.lower()
    assert "&lt;script&gt;" in html
    assert "<strong" in html


def test_inline_md_allows_safe_only():
    out = inline_md("**b** `c` [x](https://ok.co) " + XSS)
    assert "<strong" in out and "<code" in out and 'href="https://ok.co"' in out
    assert "<script" not in out.lower() and "<img" not in out.lower()
    assert "&lt;script&gt;" in out


def test_inline_md_blocks_javascript_url():
    out = inline_md("[click](javascript:alert(1))")
    assert "javascript:" not in out
    assert 'href="#"' in out


def test_block_md_fenced_code_escaped():
    out = block_md("```\n<script>evil()</script>\n```")
    assert "<script" not in out.lower() and "&lt;script&gt;" in out


def test_audio_src_sanitized():
    html = webrender.render_one(ap.Audio(src="javascript:alert(1)").to_dict())
    assert "javascript:alert" not in html
