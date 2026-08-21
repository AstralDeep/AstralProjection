from __future__ import annotations

from webrender.chrome import chrome_error_block, notice_block, render_modal_shell


def test_modal_shell_escapes_authority_fields_and_preserves_trusted_body() -> None:
    html = render_modal_shell(
        '<Title "unsafe">',
        "<p>trusted body</p>",
        'settings" data-evil="1',
    )
    assert "<p>trusted body</p>" in html
    assert "&lt;Title &quot;unsafe&quot;&gt;" in html
    assert 'data-surface="settings&quot; data-evil=&quot;1"' in html
    assert "astral-modal-close" in html
    assert "data-mandatory" not in html


def test_mandatory_modal_removes_close_and_keeps_signout_escape_hatch() -> None:
    html = render_modal_shell("Setup", "body", mandatory=True)
    assert 'data-mandatory="1"' in html
    assert 'href="/auth/logout"' in html
    assert "astral-modal-close" not in html


def test_error_and_notice_blocks_escape_text_and_bound_variants() -> None:
    plain = chrome_error_block("<failed>")
    retry = chrome_error_block("again", 'guide" bad="1')
    assert "&lt;failed&gt;" in plain and "chrome_open" not in plain
    assert "chrome_open" in retry and "guide&quot; bad=&quot;1" in retry

    assert "text-green-400" in notice_block("success", "saved")
    assert "text-red-400" in notice_block("error", "failed")
    fallback = notice_block("unknown", "<info>")
    assert "text-astral-primary" in fallback and "&lt;info&gt;" in fallback
