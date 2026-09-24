"""Tests for windows-client voice refusal rendering (astral_client/voice.py):
human-readable refusal text for known codes, a verbatim fallback for unmapped codes,
and wording parity with the web client.
"""

from __future__ import annotations

from astral_client.voice import _REFUSAL_REASON_TEXT, _refusal_line


def test_known_refusal_reasons_render_human_lines() -> None:
    for code, line in _REFUSAL_REASON_TEXT.items():
        rendered = _refusal_line(code)
        assert rendered == line
        assert rendered != code
        assert " " in rendered


def test_fr033_refusal_classes_are_covered() -> None:
    for code in (
        "worker_unavailable",
        "asr_unavailable",
        "tts_unavailable",
        "capacity_exhausted",
    ):
        assert code in _REFUSAL_REASON_TEXT


def test_unmapped_code_falls_back_to_the_verbatim_code() -> None:
    assert _refusal_line("stale_generation") == "stale_generation"
    assert _refusal_line("") == "Voice is temporarily unavailable. You can keep typing."
    assert _refusal_line(None) == "Voice is temporarily unavailable. You can keep typing."


def test_wording_matches_the_web_reference() -> None:
    assert (
        _refusal_line("capacity_exhausted")
        == "Voice is at capacity right now. Try again shortly."
    )
    assert (
        _refusal_line("feature_disabled")
        == "Voice is not enabled on this server. You can keep typing."
    )
