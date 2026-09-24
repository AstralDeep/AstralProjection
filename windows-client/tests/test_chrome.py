"""Tests for astral_client/chrome.py: a pushed chrome modal frame is acknowledged rather
than silently dropped, while close and topbar region frames are ignored.
"""

from astral_client.chrome import chrome_render_notice


def test_modal_with_html_returns_a_notice():
    notice = chrome_render_notice({"type": "chrome_render", "region": "modal", "html": "<div>settings</div>"})
    assert isinstance(notice, str) and notice


def test_default_region_is_modal():
    assert chrome_render_notice({"type": "chrome_render", "html": "<div/>"})


def test_empty_or_blank_html_is_close_and_ignored():
    assert chrome_render_notice({"type": "chrome_render", "region": "modal", "html": ""}) is None
    assert chrome_render_notice({"type": "chrome_render", "region": "modal", "html": "   "}) is None
    assert chrome_render_notice({"type": "chrome_render", "region": "modal"}) is None


def test_topbar_region_is_ignored():
    assert chrome_render_notice({"type": "chrome_render", "region": "topbar", "html": "<header/>"}) is None
