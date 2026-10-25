"""Tests binding the terminal panel presentation contract to its fixture, the shared
sanitizer and the closed ROTE dispositions, including deterministic malicious-sequence,
bound and input vectors.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from rote.terminal import (
    INTERACTIVE_PANEL,
    OMITTED,
    READ_ONLY_MONITOR,
    WATCH_HANDOFF,
    contract_dispositions,
    terminal_disposition,
)
from rote.capabilities import DeviceType
from webrender.terminal import (
    MAX_KEYBOARD_TEXT,
    MAX_OUTPUT_BYTES,
    MAX_OUTPUT_LINES,
    bounded_terminal_output,
    decode_terminal_chunk,
    keyboard_input_text,
    sanitize_terminal_output,
    terminal_number,
    terminal_seconds,
)

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / "contracts" / "ui_protocol.json").read_text(encoding="utf-8"))
CONTRACT = MANIFEST["presentation_contracts"]["terminal_panel"]
FIXTURE = json.loads(
    (ROOT / "contracts" / "fixtures" / "terminal" / "panel_surface.json").read_text(encoding="utf-8")
)

ROTE_DEVICE_DISPOSITIONS = {
    "browser": INTERACTIVE_PANEL,
    "windows": INTERACTIVE_PANEL,
    "android": READ_ONLY_MONITOR,
    "ios": READ_ONLY_MONITOR,
    "macos": READ_ONLY_MONITOR,
    "tablet": READ_ONLY_MONITOR,
    "mobile": READ_ONLY_MONITOR,
    "tv": READ_ONLY_MONITOR,
    "watch": WATCH_HANDOFF,
    "voice": OMITTED,
}


def test_contract_declares_the_closed_terminal_vocabulary():
    assert CONTRACT["version"] == 1
    assert CONTRACT["surface_key"] == "terminal"
    assert CONTRACT["navigation"]["action"] == "chrome_open"
    assert CONTRACT["navigation"]["modes"] == ["list", "panel"]
    assert set(CONTRACT["actions"]) == {
        "chrome_terminal_input", "chrome_terminal_resize",
        "chrome_terminal_interrupt", "chrome_terminal_close",
    }
    assert set(CONTRACT["actions"]) <= set(MANIFEST["accept_actions"])
    assert len(MANIFEST["accept_actions"]) == len(set(MANIFEST["accept_actions"]))
    assert set(CONTRACT["statuses"]) == {
        "ready", "loading", "unavailable", "stale", "wrong_owner", "disconnected",
        "account_changed", "denied", "expired", "error", "timeout",
    }
    assert set(CONTRACT["session"]["states"]) == {
        "running", "exited", "closed", "disconnected", "unavailable",
    }
    assert CONTRACT["input"]["maximum_characters"] == 512
    assert CONTRACT["output"]["display_utf8_bytes"] == MAX_OUTPUT_BYTES
    assert CONTRACT["output"]["display_lines"] == MAX_OUTPUT_LINES


def test_contract_dispositions_match_the_closed_rote_device_table():
    assert set(CONTRACT["dispositions"]) == {
        "browser", "windows", "android", "macos", "ios", "watchos", "voice",
    }
    assert contract_dispositions() == CONTRACT["dispositions"]
    assert CONTRACT["rote_devices"] == ROTE_DEVICE_DISPOSITIONS
    for device, disposition in ROTE_DEVICE_DISPOSITIONS.items():
        assert terminal_disposition(DeviceType(device)) == disposition
    assert terminal_disposition("unknown-device") == OMITTED
    assert terminal_disposition(None) == OMITTED


def test_fixture_frames_are_exact_correlated_server_builds():
    assert FIXTURE["version"] == 1
    assert FIXTURE["surface"] == CONTRACT["surface_key"]
    assert FIXTURE["request"]["action"] == "chrome_open"
    assert FIXTURE["request"]["payload"]["surface"] == "terminal"
    assert FIXTURE["request"]["payload"]["params"]["mode"] == "panel"
    generation = FIXTURE["request"]["request_generation"]
    for group in ("frames", "read_only_frames", "web_frames"):
        assert set(FIXTURE[group]) == set(FIXTURE["states"])
    for name, frame in FIXTURE["frames"].items():
        assert set(frame) == set(CONTRACT["native_response"]["exact_fields"])
        assert frame["type"] == "chrome_surface" and frame["region"] == "modal"
        assert frame["mode"] == "replace" and frame["admin_only"] is False
        assert frame["surface_key"] == "terminal"
        assert frame["request_generation"] == generation
    for name, frame in FIXTURE["web_frames"].items():
        assert set(frame) == set(CONTRACT["web_response"]["exact_fields"])
        assert frame["type"] == "chrome_render" and frame["html"]
        assert frame["request_generation"] == generation
    assert FIXTURE["native_frame"] == FIXTURE["frames"]["panel"]


def test_interactive_operations_appear_only_in_interactive_frames():
    for name in FIXTURE["states"]:
        read_only = FIXTURE["read_only_frames"][name]
        interactive = FIXTURE["frames"][name]
        read_only_actions = {
            node.get("action", node.get("submit_action"))
            for node in _nodes(read_only["components"])
            if node.get("type") in {"button", "param_picker"}
        }
        assert read_only_actions <= {"chrome_open", "chrome_close"}, name
        interactive_actions = {
            node.get("action", node.get("submit_action"))
            for node in _nodes(interactive["components"])
            if node.get("type") in {"button", "param_picker"}
        }
        if name == "panel":
            assert interactive_actions == {
                "chrome_open", "chrome_close",
                "chrome_terminal_input", "chrome_terminal_resize",
                "chrome_terminal_interrupt", "chrome_terminal_close",
            }


def _nodes(components, found=None):
    found = [] if found is None else found
    for node in components:
        found.append(node)
        for key in ("content", "children"):
            if isinstance(node.get(key), list):
                _nodes(node[key], found)
    return found


def test_malicious_fixture_vector_sanitizes_to_the_declared_literal():
    text = sanitize_terminal_output(FIXTURE["source_text"])
    assert text == FIXTURE["expected_sanitized_text"]
    assert "\x1b" not in text and "\x9b" not in text
    assert "evil.example" not in text
    assert "clipboard theft" not in text
    assert "\u202e" not in text and "\u200b" not in text


def test_sanitizer_strips_every_escape_stream_class():
    text = sanitize_terminal_output(
        "a\x1b[31mb\x1b[0m\x1b]0;t\x07\x1b]8;;http://x\x1b\\l\x1b]8;;\x1b\\"
        "\x1bPdata\x1b\\\x1b^pm\x1b\\\x1b_x\x1b\\\x9bK\x9dosc\x90dcs\x9c\x9fapc"
    )
    assert text == "abl"
    assert not any(character in text for character in "\x1b\x07\x9c\x90\x9d\x9e\x9f\x9b")


def test_sanitizer_preserves_newline_and_tab_and_folds_returns():
    assert sanitize_terminal_output("one\rtwo\tthree\nfour") == "one\ntwo\tthree\nfour"


def test_sanitizer_replaces_lone_surrogates_with_replacement_characters():
    assert sanitize_terminal_output("a\ud800b") == "a\ufffdb"


@pytest.mark.parametrize("payload", [b"\xff\xfe valid", "valid"])
def test_sanitizer_accepts_bytes_and_bounded_text(payload):
    assert "valid" in sanitize_terminal_output(payload)


def test_sanitizer_rejects_oversized_input_text():
    from webrender.terminal import MAX_INPUT_TEXT

    with pytest.raises(ValueError, match="too large|bounded"):
        sanitize_terminal_output("x" * (MAX_INPUT_TEXT + 1))


def test_bounded_output_keeps_the_newest_complete_scalars():
    text = "á" * 10 + "\n" + "b" * 4
    bounded, truncated = bounded_terminal_output(text)
    assert bounded == text and truncated is False
    bounded, truncated = bounded_terminal_output("x" * (MAX_OUTPUT_BYTES + 40))
    assert truncated is True and len(bounded.encode("utf-8")) <= MAX_OUTPUT_BYTES
    lines = "\n".join(f"line{index}" for index in range(MAX_OUTPUT_LINES + 5))
    bounded, truncated = bounded_terminal_output(lines)
    assert truncated is True and len(bounded.split("\n")) == MAX_OUTPUT_LINES


def test_decode_terminal_chunk_accepts_only_bounded_canonical_base64():
    assert decode_terminal_chunk("aGVsbG8=") == "hello"
    with pytest.raises(ValueError):
        decode_terminal_chunk("not base64!!")
    with pytest.raises(ValueError):
        decode_terminal_chunk("QUJD" * 40000)
    with pytest.raises(ValueError):
        decode_terminal_chunk(3.5)


def test_keyboard_input_is_bounded_printable_text():
    assert keyboard_input_text("systemctl status astral") == "systemctl status astral"
    with pytest.raises(ValueError):
        keyboard_input_text("bad\x1b[31mcolor")
    with pytest.raises(ValueError):
        keyboard_input_text("bad\nnewline")
    with pytest.raises(ValueError):
        keyboard_input_text("   ")
    with pytest.raises(ValueError):
        keyboard_input_text("x" * (MAX_KEYBOARD_TEXT + 1))
    with pytest.raises(ValueError):
        keyboard_input_text(12)


def test_terminal_numbers_seconds_and_offsets_fail_closed():
    assert terminal_number(7) == 7 and terminal_seconds(2.55) == "2.55"
    for value in (True, -1, 1.5, "7", None, 9007199254740991 + 1):
        with pytest.raises(ValueError):
            terminal_number(value)
    for value in (-0.1, float("nan"), float("inf"), "2", None):
        with pytest.raises(ValueError):
            terminal_seconds(value)


def test_sanitizer_boundary_and_terminator_branches():
    assert sanitize_terminal_output("tail\x1b") == "tail"
    assert sanitize_terminal_output("\x1b]0;title") == ""
    assert sanitize_terminal_output("\x1b]0;t\x1b\\after") == "after"
    assert sanitize_terminal_output("\x1bPdata") == ""
    assert sanitize_terminal_output("\x1bPdata\x1b\\after") == "after"
    assert sanitize_terminal_output("\x1b(Bascii") == "ascii"
    assert sanitize_terminal_output("\x1bZmiddle") == "middle"
    assert sanitize_terminal_output("\x9b31mC1") == "C1"
    assert sanitize_terminal_output("\x9b") == ""
    assert sanitize_terminal_output("\x9dosc\x9ctail") == "tail"
    assert sanitize_terminal_output("\x90dcs\x9ctail") == "tail"
    assert sanitize_terminal_output("\x98\x9ctail") == "tail"
    assert sanitize_terminal_output("\x9e\x9ctail") == "tail"
    assert sanitize_terminal_output("\x9f\x9ctail") == "tail"
    assert decode_terminal_chunk(b"bytes") == "bytes"
    from webrender.terminal import _bound

    with pytest.raises(ValueError, match="bounds"):
        _bound("x", 0, 1)
    with pytest.raises(ValueError, match="bounds"):
        _bound("x", 1, 0)


def test_osc_string_terminator_at_the_exact_end_of_input():
    assert sanitize_terminal_output("\x1b]52;c;abc") == ""
    assert sanitize_terminal_output("\x1b]52;c;abc\x1b") == ""
    assert sanitize_terminal_output("\x1bP1;2|3") == ""


def test_remaining_sanitizer_and_validator_branches():
    assert sanitize_terminal_output("\x1bPdata\x07after") == "after"
    assert sanitize_terminal_output("\x1b^pm\x07after") == "after"
    from rote.terminal import validate_terminal_components

    identity = {"surface": "terminal", "session_id": "term_01JABCDEF"}
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components(
            [{"type": "param_picker",
              "fields": [{"name": "data", "label": "d", "kind": "text",
                          "default": "bad\x1b[31m"}],
              "submit_action": "chrome_terminal_input", "submit_payload": identity}],
            interactive=True)
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components(
            [{"type": "card", "title": "t", "children": 12}], interactive=True)
    wide = [{"type": "text", "content": "y" * 3000, "variant": "body"} for _ in range(400)]
    with pytest.raises(ValueError, match="terminal_surface_unavailable"):
        validate_terminal_components(wide, interactive=True)


def test_fixture_watch_handoff_is_the_exact_content_free_panel_build():
    from astralprojection.chrome.terminal import build_terminal_view

    expected = [
        component.to_dict()
        for component in build_terminal_view(FIXTURE["states"]["panel"], watch=True).components
    ]
    assert FIXTURE["watch_components"] == expected
    assert [node["type"] for node in expected] == ["badge", "alert"]
    serialized = json.dumps(expected, ensure_ascii=False)
    for private in ("term_01JABCDEF", "ops@staging.example", "/srv/astral/work", "hello"):
        assert private not in serialized
    assert "phone or desktop" in serialized
