"""Verifies the terminal monitor contract, fixtures, literal output and read-only state handling.
The host owns terminal authority; these tests only exercise presentation and sanitization.
"""

from __future__ import annotations

import base64
import json
from pathlib import Path
from uuid import UUID

import pytest

from astralprojection.chrome import render_html
from astralprojection.chrome.terminal import build_terminal_monitor_view as build_terminal_view
from webrender.chrome import render_modal_shell
from webrender.terminal import bounded_terminal_output, sanitize_terminal_output

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / "contracts/ui_protocol.json").read_text(encoding="utf-8"))
CONTRACT = MANIFEST["presentation_contracts"]["terminal_monitor"]
FIXTURE = json.loads((ROOT / CONTRACT["fixture"]).read_text(encoding="utf-8"))
STATUSES = [
    "loading",
    "unavailable",
    "stale",
    "wrong_owner",
    "disconnected",
    "account_changed",
]


def _walk(nodes):
    for node in nodes:
        yield node
        for key in ("content", "children"):
            children = node.get(key)
            if isinstance(children, list):
                yield from _walk(children)


def _buttons(nodes):
    return [node for node in _walk(nodes) if node.get("type") == "button"]


def _texts(nodes):
    return [node.get("content", "") for node in _walk(nodes) if node.get("type") == "text"]


def _codes(nodes):
    return [node for node in _walk(nodes) if node.get("type") == "code"]


def _components(state, *, watch=False):
    return [item.to_dict() for item in build_terminal_view(state, watch=watch).components]


def test_contract_is_read_only_closed_and_uses_the_existing_vocabulary():
    assert CONTRACT["version"] == FIXTURE["version"] == 1
    assert CONTRACT["surface_key"] == FIXTURE["surface"] == "terminal"
    assert CONTRACT["navigation"]["action"] == FIXTURE["request"]["action"] == "chrome_open"
    assert CONTRACT["navigation"]["modes"] == ["list", "monitor"]
    assert CONTRACT["controls"]["actions"] == ["chrome_open", "chrome_close"]
    assert set(CONTRACT["controls"]["actions"]) <= set(MANIFEST["accept_actions"])
    assert not {name for name in MANIFEST["push_types"] if name["name"].startswith("terminal")}
    assert not {name for name in MANIFEST["client_local_actions"] if "terminal" in name}
    assert len(MANIFEST["push_types"]) == 72
    assert len(MANIFEST["accept_actions"]) == 157
    assert len(MANIFEST["client_local_actions"]) == 5
    used = {node["type"] for frame in FIXTURE["frames"].values() for node in _walk(frame["components"])}
    assert used <= set(MANIFEST["component_types"])
    assert "param_picker" not in used and "input" not in used
    generation = FIXTURE["request"]["request_generation"]
    assert str(UUID(generation)) == generation and UUID(generation).version == 4
    assert CONTRACT["output"]["display_utf8_bytes"] == 32768
    assert CONTRACT["output"]["display_lines"] == 2000
    assert "OSC 52" in CONTRACT["output"]["copy"]
    assert "No create, input, resize, interrupt, session close" in CONTRACT["controls"]["read_only"]


def test_fixture_frames_are_builder_goldens_and_use_exact_correlated_envelopes():
    for name, state in FIXTURE["states"].items():
        view = build_terminal_view(state)
        frame = FIXTURE["frames"][name]
        assert frame["title"] == view.title
        assert frame["components"] == [item.to_dict() for item in view.components]
        assert set(frame) == set(CONTRACT["native_response"]["exact_fields"])
        assert frame["type"] == "chrome_surface" and frame["surface_key"] == "terminal"
        assert frame["region"] == "modal" and frame["mode"] == "replace"
        assert frame["admin_only"] is False
        assert frame["request_generation"] == FIXTURE["request"]["request_generation"]
        web = FIXTURE["web_frames"][name]
        assert set(web) == set(CONTRACT["web_response"]["exact_fields"])
        assert web["type"] == "chrome_render" and web["surface_key"] == "terminal"
        assert web["html"] == render_modal_shell(view.title, render_html(view), "terminal")
    assert FIXTURE["native_frame"] == FIXTURE["frames"]["monitor"]
    assert FIXTURE["web_frame"] == FIXTURE["web_frames"]["monitor"]
    watch = [item.to_dict() for item in build_terminal_view(FIXTURE["states"]["monitor"], watch=True).components]
    assert FIXTURE["watch_components"] == watch


def test_monitor_shows_target_directory_state_output_and_only_read_controls():
    frame = FIXTURE["frames"]["monitor"]
    labels = {}
    for node in _walk(frame["components"]):
        if node.get("type") == "keyvalue":
            labels.update({item["label"]: item["value"] for item in node.get("items", [])})
    assert labels["Session"] == "term_01JABCDEF"
    assert labels["Target"] == "ops@staging.example"
    assert labels["Directory"] == "/srv/astral/work"
    assert labels["State"] == "Running"
    assert labels["Read from byte"] == "0"
    assert "hello" in _codes(frame["components"])[0]["code"]
    actions = [button["action"] for button in _buttons(frame["components"])]
    assert actions == ["chrome_open", "chrome_open", "chrome_close"]
    assert [button["label"] for button in _buttons(frame["components"])] == [
        "Refresh output",
        "Back to terminals",
        "Close monitor",
    ]
    assert all(button["local"] is False and button["disabled"] is False
               for button in _buttons(frame["components"]))
    assert _buttons(frame["components"])[-1]["payload"] == {"surface": "terminal"}
    assert _texts(frame["components"]) == []


def test_list_and_empty_states_offer_existing_sessions_without_output():
    listed = FIXTURE["frames"]["list"]["components"]
    cards = [node for node in listed if node.get("type") == "card"]
    assert [card["title"] for card in cards] == [
        "ops@staging.example",
        "runner@staging.example",
    ]
    opens = [button for button in _buttons(listed) if button["label"] == "Open monitor"]
    assert [button["payload"]["params"]["session_id"] for button in opens] == [
        "term_01JABCDEF",
        "term_02JABCDEF",
    ]
    assert not _codes(listed)
    empty = FIXTURE["frames"]["empty"]["components"]
    assert _texts(empty) == []
    assert [button["action"] for button in _buttons(empty)] == ["chrome_open", "chrome_close"]


def test_malicious_ansi_osc_hyperlink_and_clipboard_sequences_are_removed():
    source = FIXTURE["source_text"]
    expected = FIXTURE["expected_sanitized_text"]
    assert sanitize_terminal_output(source) == expected
    assert "\x1b" not in expected
    assert "\x00" not in expected
    assert "\u202e" not in expected
    assert "evil.example" not in expected
    assert "clipboard theft" not in expected
    assert "owned title" not in expected
    frame = FIXTURE["frames"]["malicious"]
    codes = _codes(frame["components"])
    assert [item["code"] for item in codes] == [expected]
    html = FIXTURE["web_frames"]["malicious"]["html"]
    for forbidden in ("\x1b", "\x00", "\u202e", "evil.example", "clipboard theft", "owned title"):
        assert forbidden not in html
    assert "href=" not in html and "<script" not in html
    assert "&lt;" not in html


@pytest.mark.parametrize("source", [
    "\x1b]52;c;c2VjcmV0",
    "\x1b]8;;https://evil.example",
    "\x1b[31",
    "\x1bP1;2",
    "\x9b31",
    "\x9d52;c;secret",
])
def test_incomplete_escape_streams_never_leave_their_payload(source):
    result = sanitize_terminal_output(source + "kept")
    assert "kept" not in result and "secret" not in result
    assert "evil.example" not in result


def test_utf8_truncation_keeps_complete_scalars_and_is_explicit():
    source = "head\n" + "🙂" * 12000
    text, truncated = bounded_terminal_output(source)
    assert truncated is True
    assert len(text.encode("utf-8")) <= 32768
    assert "\ufffd" not in text
    assert text == text.encode("utf-8").decode("utf-8")
    state = {
        **FIXTURE["states"]["monitor"],
        "output": {"text": source, "offset": 0, "next_offset": 1, "truncated": False, "eof": False},
    }
    components = _components(state)
    assert any(item["message"].startswith("The retained output window is truncated")
               for item in _walk(components) if item.get("type") == "alert")


def test_host_truncation_and_eof_are_visible_without_inventing_output():
    components = FIXTURE["frames"]["truncated"]["components"]
    alerts = [item["message"] for item in _walk(components) if item.get("type") == "alert"]
    assert any("truncated" in message for message in alerts)
    assert any("terminal has exited" in message for message in alerts)
    assert _codes(components)[0]["code"] == "tail bytes\n"


@pytest.mark.parametrize("status", STATUSES)
def test_failure_states_are_deterministic_and_drop_private_snapshot_data(status):
    state = FIXTURE["states"][status]
    components = _components(state)
    assert not _codes(components)
    assert "private" not in json.dumps(components)
    actions = [(button["action"], button["payload"]) for button in _buttons(components)]
    recoverable = status not in {"loading", "account_changed"}
    assert actions == (
        [("chrome_open", {"surface": "terminal", "params": {"mode": "list"}}),
         ("chrome_close", {"surface": "terminal"})]
        if recoverable else [("chrome_close", {"surface": "terminal"})]
    )
    first = _walk(components).__next__()
    assert first["type"] == "alert"


@pytest.mark.parametrize("status,expected", [
    ("denied", "not available to the current account"),
    ("expired", "stale"),
    ("error", "unavailable"),
    ("timeout", "unavailable"),
])
def test_failure_aliases_use_the_same_closed_safe_messages(status, expected):
    components = _components({"mode": "monitor", "status": status,
                              "output": {"text": "private alias"}})
    first = next(_walk(components))
    assert first["type"] == "alert" and expected in first["message"]
    assert "private alias" not in json.dumps(components)


def test_watch_and_voice_receive_no_output_identifiers_or_controls():
    watch = FIXTURE["watch_components"]
    serialized = json.dumps(watch, ensure_ascii=False)
    for private in ("term_01JABCDEF", "ops@staging.example", "/srv/astral/work", "hello", "done"):
        assert private not in serialized
    assert {item["type"] for item in watch} == {"badge", "alert"}
    assert any("phone or desktop" in item.get("message", "") for item in watch)
    assert not _buttons(watch) and not _codes(watch)
    assert CONTRACT["dispositions"]["watchos"] == "phone_desktop_handoff"
    assert CONTRACT["dispositions"]["voice"] == "omitted_by_server"


def test_data_b64_output_is_decoded_once_and_invalid_base64_fails_closed():
    payload = "line one\nline two\n"
    state = {
        **FIXTURE["states"]["monitor"],
        "output": {
            "data_b64": base64.b64encode(payload.encode("utf-8")).decode("ascii"),
            "offset": 0,
            "next_offset": len(payload.encode("utf-8")),
            "truncated": False,
            "eof": False,
        },
    }
    assert _codes(_components(state))[0]["code"] == payload
    invalid = {
        **FIXTURE["states"]["monitor"],
        "output": {"data_b64": "not base64!", "offset": 0, "next_offset": 1},
    }
    components = _components(invalid)
    assert not _codes(components)
    assert "not base64" not in json.dumps(components)


@pytest.mark.parametrize("state", [
    None, {}, {"mode": "monitor", "status": "ready"},
    {"mode": "monitor", "status": "ready", "session": {"session_id": "bad id", "state": "running"}},
    {"mode": "monitor", "status": "ready", "session": {"session_id": "term_ok", "state": "running"},
     "output": {"text": "x", "offset": 2, "next_offset": 1}},
    {"mode": "list", "status": "ready", "sessions": [{"session_id": "term_a", "state": "running"},
                                                       {"session_id": "term_a", "state": "running"}]},
    {"mode": "list", "status": "ready", "sessions": [{"session_id": f"term_{i}", "state": "running"}
                                                       for i in range(17)]},
])
def test_malformed_or_unbounded_states_fail_closed_without_echoing_values(state):
    components = _components(state)
    assert not _codes(components)
    assert any(item.get("type") == "alert" for item in components)
    for private in ("bad id", "term_ok", "term_a", "term_16"):
        assert private not in json.dumps(components)


def test_public_code_renderer_escapes_literal_terminal_text_and_never_links():
    state = {
        **FIXTURE["states"]["monitor"],
        "output": {
            "text": '<script>alert("x")</script> & https://example.org/inert\n\u202eRTL',
            "offset": 0,
            "next_offset": 1,
            "truncated": False,
            "eof": False,
        },
    }
    view = build_terminal_view(state)
    html = render_html(view)
    assert "<script>" not in html
    assert "&lt;script&gt;" in html
    assert "https://example.org/inert" in html
    assert "<a " not in html and "href=" not in html
    assert "<pre><code>" in html
    assert "RTL" in html


def test_close_monitor_is_navigation_not_terminal_session_close():
    buttons = _buttons(FIXTURE["frames"]["monitor"]["components"])
    close = next(button for button in buttons if button["label"] == "Close monitor")
    assert close["action"] == "chrome_close"
    assert close["payload"] == {"surface": "terminal"}
    refresh = next(button for button in buttons if button["label"] == "Refresh output")
    assert refresh["payload"]["params"]["mode"] == "monitor"
    assert refresh["payload"]["params"]["offset"] == FIXTURE["states"]["monitor"]["output"]["next_offset"]
    assert all(button["action"] in CONTRACT["controls"]["actions"] for button in buttons)

def test_sanitizer_covers_escape_terminators_scalars_and_decoder_bounds():
    from webrender import terminal

    assert sanitize_terminal_output("\x1b(Bok") == "ok"
    assert sanitize_terminal_output("\x1bZok") == "ok"
    assert sanitize_terminal_output("\x1bPpayload\x07ok") == "ok"
    assert sanitize_terminal_output("\x1bPpayload\x1b\\ok") == "ok"
    assert sanitize_terminal_output("\x90payload\x9cok") == "ok"
    assert sanitize_terminal_output("\x9d52;c;secret\x9cok") == "ok"
    assert sanitize_terminal_output("a\x1b") == "a"
    assert sanitize_terminal_output(b"ok\xff") == "ok\ufffd"
    assert sanitize_terminal_output("\ud800") == "\ufffd"
    assert sanitize_terminal_output("\t\n\r\x07") == "\t\n\n"
    assert sanitize_terminal_output("x\U000e0001y") == "xy"
    assert terminal.decode_terminal_chunk(b"bytes") == "bytes"
    assert terminal.decode_terminal_chunk(base64.b64encode(b"chunk").decode()) == "chunk"
    for invalid in (None, 1, [], {}):
        with pytest.raises(ValueError, match="text or base64"):
            terminal.decode_terminal_chunk(invalid)
    with pytest.raises(ValueError, match="too large"):
        terminal.decode_terminal_chunk("A" * (terminal.MAX_INPUT_BASE64 + 1))
    with pytest.raises(ValueError, match="too large"):
        sanitize_terminal_output("x" * (terminal.MAX_INPUT_TEXT + 1))
    with pytest.raises(ValueError, match="must be text"):
        sanitize_terminal_output(1)
    with pytest.raises(ValueError, match="too large"):
        bounded_terminal_output("x" * (terminal.MAX_INPUT_TEXT + 1))
    with pytest.raises(ValueError, match="must be text"):
        bounded_terminal_output(1)
    with pytest.raises(ValueError, match="bounds"):
        terminal._bound("x", 0, 1)
    with pytest.raises(ValueError, match="bounds"):
        terminal._bound("x", 1, 0)
    line_text, line_truncated = terminal._bound("\n".join(["x"] * 2001), 10000, 2000)
    assert line_truncated is True and line_text.count("\n") == 1999
    assert terminal.terminal_number(7) == 7
    for invalid in (True, -1, "7", 1.5, 9007199254740992):
        with pytest.raises(ValueError, match="number"):
            terminal.terminal_number(invalid)
    assert terminal.terminal_seconds(1.25) == "1.25"
    assert terminal.terminal_seconds(0) == "0"
    for invalid in (True, -1, float("inf"), float("nan"), "1"):
        with pytest.raises(ValueError, match="duration"):
            terminal.terminal_seconds(invalid)


def test_bounded_bytes_and_target_object_aliases_are_supported():
    assert bounded_terminal_output(b"bytes\n") == ("bytes\n", False)
    state = {
        **FIXTURE["states"]["monitor"],
        "session": {
            **FIXTURE["states"]["monitor"]["session"],
            "target": {"label": "Label target", "machine_id": "ignored"},
        },
    }
    components = _components(state)
    values = [
        item["value"]
        for node in _walk(components)
        if node.get("type") == "keyvalue"
        for item in node.get("items", [])
    ]
    assert "Label target" in values
    assert "ignored" not in values


def test_real_host_read_shape_with_top_level_session_and_eof_is_supported():
    payload = FIXTURE["states"]["monitor"]["output"]["text"]
    state = {
        "session_id": "term_01JABCDEF",
        "target": "ops@staging.example",
        "directory": "/srv/astral/work",
        "cols": 80,
        "rows": 24,
        "state": "running",
        "data_b64": base64.b64encode(payload.encode()).decode(),
        "offset": 0,
        "next_offset": len(payload.encode()),
        "bytes": len(payload.encode()),
        "truncated": False,
        "eof": True,
        "session": None,
    }
    components = _components(state)
    assert _codes(components)[0]["code"] == sanitize_terminal_output(payload)
    labels = {}
    for node in _walk(components):
        if node.get("type") == "keyvalue":
            labels.update({item["label"]: item["value"] for item in node.get("items", [])})
    assert labels["Session"] == "term_01JABCDEF"
    assert labels["Target"] == "ops@staging.example"
    assert labels["Directory"] == "/srv/astral/work"
    assert labels["State"] == "Exited"
    assert any(item.get("message", "").startswith("The terminal has exited")
               for item in _walk(components) if item.get("type") == "alert")


def test_chrome_package_lazily_exposes_terminal_helpers_without_eager_webrender_import():
    import astralprojection.chrome as chrome

    assert chrome.build_terminal_view({"mode": "list", "status": "ready", "sessions": []}).surface == "terminal"
    assert chrome.build_terminal_monitor_view({"mode": "list", "status": "ready", "sessions": []}).surface == "terminal"
    assert chrome.sanitize_terminal_output("\x1b[31mred\x1b[0m") == "red"
    with pytest.raises(AttributeError, match="has no attribute"):
        _ = chrome.not_a_terminal_export
