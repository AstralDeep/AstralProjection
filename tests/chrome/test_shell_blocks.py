from __future__ import annotations

from html.parser import HTMLParser

from astralprojection.resources import template_path
from webrender.chrome import chrome_error_block, notice_block, render_modal_shell


def test_composer_has_an_accessible_name_and_retains_existing_controls() -> None:
    class ShellParser(HTMLParser):
        elements: list[tuple[str, dict[str, str | None]]]

        def __init__(self) -> None:
            super().__init__()
            self.elements = []

        def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
            self.elements.append((tag, dict(attrs)))

    parser = ShellParser()
    parser.feed(template_path("shell.html").read_text(encoding="utf-8"))
    by_id = {attrs["id"]: (tag, attrs) for tag, attrs in parser.elements if "id" in attrs}
    tag, composer = by_id["astral-input"]
    assert tag == "textarea" and composer["rows"] == "2"
    assert composer.get("aria-label") == "Message"
    assert composer["autocomplete"] == "off"
    assert by_id["astral-form"][0] == "form"
    assert len([attrs for tag, attrs in parser.elements
                if tag == "button" and attrs.get("type") == "submit"]) == 1
    for control in ("astral-attach-btn", "astral-bg-btn", "astral-chat-toggle"):
        assert by_id[control][1].get("aria-label")
    assert by_id["astral-attach-input"][1]["accept"] == "%%ASTRAL_ACCEPT%%"
    assert by_id["astral-voice-controls"][1]["role"] == "group"
    # Reading and keyboard order follow the centered start composition; the
    # server-rendered examples land after the same, permanently mounted form.
    ids = [attrs["id"] for _, attrs in parser.elements if "id" in attrs]
    assert ids.index("astral-start-intro") < ids.index("astral-form")
    assert ids.index("astral-input") < ids.index("astral-attach-btn")
    assert ids.index("astral-form") < ids.index("astral-start-examples")
    assert ids.index("astral-start-examples") < ids.index("astral-start-more")
    for status in ("astral-conn-text", "astral-turn-status", "astral-voice-status"):
        assert by_id[status][1]["role"] == "status"
    assert {"astral-history", "astral-chat", "astral-canvas", "astral-modal"} <= by_id.keys()


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
