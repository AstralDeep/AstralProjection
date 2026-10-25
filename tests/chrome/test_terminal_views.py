"""Tests the server-owned terminal panel builder: list and panel golden paths, closed
failure statuses, watch handoff, bounded sessions, and the accessible escaped web rendering.
"""

from __future__ import annotations

import json

import pytest

from astralprojection.chrome import render_html
from astralprojection.chrome.terminal import (
    CONTRACT,
    LIST_TITLE,
    MAX_SESSIONS,
    SURFACE,
    TITLE,
    build_terminal_panel_view,
    build_terminal_view,
)

SESSION = {
    "session_id": "term_01JABCDEF",
    "target": "ops@staging.example",
    "directory": "/srv/astral/work",
    "state": "running",
    "cols": 120,
    "rows": 32,
    "idle_seconds": 2.5,
    "ring_start": 0,
    "ring_end": 57,
}
PANEL = {
    "mode": "panel",
    "status": "ready",
    "session": SESSION,
    "output": {"text": "$ printf 'hello\\n'\nhello\n", "offset": 0,
               "next_offset": 57, "truncated": False, "eof": False},
}


def _nodes(view):
    found = []

    def visit(component):
        node = component.to_dict() if hasattr(component, "to_dict") else component
        found.append(node)
        for key in ("content", "children"):
            child = node.get(key)
            if isinstance(child, list):
                for item in child:
                    visit(item)

    for component in view.components:
        visit(component)
    return found


def _actions(view):
    return {
        node.get("action") or node.get("submit_action")
        for node in _nodes(view)
        if node.get("type") in {"button", "param_picker"}
        and (node.get("action") or node.get("submit_action"))
    }


def test_list_mode_renders_one_bounded_card_per_session():
    view = build_terminal_view({"mode": "list", "status": "ready", "sessions": [SESSION, dict(SESSION, session_id="term_02")]})
    assert view.surface == SURFACE and view.title == LIST_TITLE
    cards = [node for node in _nodes(view) if node.get("type") == "card" and node.get("title") == "ops@staging.example"]
    assert len(cards) == 2
    assert _actions(view) == {"chrome_open", "chrome_close"}
    empty = build_terminal_view({"mode": "list", "status": "ready", "sessions": []})
    assert any(node.get("type") == "text" and "No terminal sessions" in node.get("content", "")
               for node in _nodes(empty))


def test_list_mode_refuses_duplicates_and_oversized_catalogs():
    for sessions in ([SESSION, dict(SESSION)], [SESSION] * (MAX_SESSIONS + 1), "bad"):
        recovered = build_terminal_view({"mode": "list", "status": "ready", "sessions": sessions})
        assert any(node.get("type") == "alert" for node in _nodes(recovered))
        assert _actions(recovered) <= {"chrome_open", "chrome_close"}


def test_panel_mode_shows_target_directory_state_and_literal_output():
    view = build_terminal_view(PANEL)
    assert view.title == "Terminal panel · ops@staging.example"
    serialized = json.dumps([node for node in _nodes(view)], ensure_ascii=False)
    for expected in ("term_01JABCDEF", "ops@staging.example", "/srv/astral/work",
                     "Running", "120 × 32"):
        assert expected in serialized
    code = next(node for node in _nodes(view) if node.get("type") == "code")
    assert code["code"] == "$ printf 'hello\\n'\nhello\n"
    assert _actions(view) == {"chrome_open", "chrome_close"}


def test_interactive_panel_declares_only_the_governed_operations():
    view = build_terminal_view(PANEL, interactive=True)
    assert _actions(view) == {
        "chrome_open", "chrome_close", "chrome_terminal_input",
        "chrome_terminal_resize", "chrome_terminal_interrupt", "chrome_terminal_close",
    }
    forms = [node for node in _nodes(view) if node.get("type") == "param_picker"]
    assert [(form["submit_action"], sorted(form["submit_payload"])) for form in forms] == [
        ("chrome_terminal_input", ["session_id", "surface"]),
        ("chrome_terminal_resize", ["session_id", "surface"]),
    ]
    input_form = next(form for form in forms if form["submit_action"] == "chrome_terminal_input")
    assert [entry["name"] for entry in input_form["fields"]] == ["data"]
    resize_form = next(form for form in forms if form["submit_action"] == "chrome_terminal_resize")
    assert [(entry["name"], entry["default"]) for entry in resize_form["fields"]] == [
        ("cols", 120), ("rows", 32)]


def test_interactive_controls_withdraw_when_the_session_is_not_running():
    exited = dict(PANEL, session=dict(SESSION, state="exited"),
                  output=dict(PANEL["output"], eof=True))
    view = build_terminal_view(exited, interactive=True)
    assert "chrome_terminal_interrupt" not in _actions(view)
    assert "chrome_terminal_close" not in _actions(view)


def test_truncation_and_exit_are_declared_with_visible_warnings():
    view = build_terminal_view(dict(PANEL, output=dict(PANEL["output"], truncated=True, eof=True)))
    messages = [node.get("message", "") for node in _nodes(view) if node.get("type") == "alert"]
    assert any("truncated" in message for message in messages)
    assert any("exited" in message for message in messages)


@pytest.mark.parametrize("status", ["loading", "unavailable", "stale", "wrong_owner",
                                    "disconnected", "account_changed", "denied",
                                    "expired", "error", "timeout"])
def test_every_declared_status_fails_closed_with_recovery_guidance(status):
    view = build_terminal_view({"mode": "panel", "status": status})
    alerts = [node for node in _nodes(view) if node.get("type") == "alert"]
    assert alerts and all(node.get("message") for node in alerts)
    actions = _actions(view)
    assert actions <= {"chrome_open", "chrome_close"}
    if status in {"loading", "account_changed"}:
        assert "chrome_open" not in actions
    else:
        assert "chrome_open" in actions


def test_output_windows_expose_bounded_offsets():
    view = build_terminal_view(PANEL, interactive=True)
    pairs = [node for node in _nodes(view) if node.get("type") == "keyvalue"
             and node.get("title") == "Output window"]
    assert pairs and pairs[0]["items"] == [
        {"label": "Read from byte", "value": "0"},
        {"label": "Next byte", "value": "57"},
    ]


def test_watch_handoff_is_content_free():
    view = build_terminal_view(PANEL, watch=True)
    serialized = json.dumps(_nodes(view), ensure_ascii=False)
    for private in ("term_01JABCDEF", "ops@staging.example", "/srv/astral/work", "hello"):
        assert private not in serialized
    assert "phone or desktop" in serialized
    assert _actions(view) == set()


def test_malformed_states_degrade_to_the_declared_unavailable_failure():
    for state in (
        {"mode": "panel", "status": "ready", "session": {"session_id": "bad id"}},
        {"mode": "panel", "status": "ready", "output": {"text": 12}},
        {"mode": "panel", "status": "ready", "session": dict(SESSION, ring_start=99, ring_end=10)},
        {"mode": "panel", "status": "ready", "session": dict(SESSION, cols=1)},
        {"mode": "panel", "status": "ready", "output": {"text": "a", "offset": 5, "next_offset": 2}},
        {"mode": "panel", "status": "ready", "session": None, "data_b64": "!!"},
    ):
        view = build_terminal_view(state)
        assert any(node.get("type") == "alert" for node in _nodes(view))
        assert view.title == LIST_TITLE


def test_base64_output_reads_are_decoded_and_sanitized():
    import base64

    encoded = base64.b64encode("$ ls\x1b[31m\n".encode()).decode()
    view = build_terminal_view({"mode": "panel", "status": "ready",
                                "session": SESSION,
                                "output": {"data_b64": encoded, "offset": 0, "next_offset": 8}})
    code = next(node for node in _nodes(view) if node.get("type") == "code")
    assert code["code"] == "$ ls\n"


def test_web_rendering_is_accessible_escaped_and_surface_scoped():
    html = render_html(build_terminal_view(PANEL, interactive=True))
    assert f'data-chrome-surface="{SURFACE}"' in html
    assert 'aria-labelledby="chrome-terminal-title"' in html
    assert "<pre><code>" in html and "$ printf" in html
    assert 'data-ui-action="chrome_terminal_interrupt"' in html
    assert 'data-ui-action="chrome_terminal_input"' in html or 'data-ui-form="true"' in html
    malicious = render_html(build_terminal_view(
        dict(PANEL, output=dict(PANEL["output"], text='<script>alert(1)</script>\x1b[31m')),
        interactive=True))
    assert "<script>" not in malicious and "&lt;script&gt;" in malicious
    assert "\x1b" not in malicious
    assert "code" in malicious


def test_contract_metadata_matches_the_builder():
    assert CONTRACT == "terminal_panel/v1"
    assert (TITLE, LIST_TITLE, SURFACE) == ("Terminal panel", "Terminal sessions", "terminal")
    assert build_terminal_panel_view is build_terminal_view


def test_target_mapping_created_at_and_retained_reload_paths():
    labeled = build_terminal_view({
        "mode": "list", "status": "ready",
        "sessions": [{
            "session_id": "term_01JABCDEF",
            "target": {"label": "ops@staging.example"},
            "directory": "/srv/astral/work",
            "state": "running", "cols": 80, "rows": 24,
            "created_at": "2026-10-18T09:30:00Z",
            "ring_start": 0, "ring_end": 5,
        }],
    })
    serialized = json.dumps([node for node in _nodes(labeled)], ensure_ascii=False)
    assert "ops@staging.example" in serialized and "2026-10-18T09:30:00Z" in serialized
    target_fallbacks = build_terminal_view({
        "mode": "list", "status": "ready",
        "sessions": [{"session_id": "term_02", "target": {"host": "runner"},
                      "state": "running"},
                     {"session_id": "term_03", "target": "", "machine": "",
                      "state": "running"}],
    })
    titles = [node.get("title") for node in _nodes(target_fallbacks)
              if node.get("type") == "card" and node.get("title")]
    assert titles == ["runner", "Target not reported"]
    reloaded = build_terminal_view(dict(PANEL, output=dict(PANEL["output"], offset=12)))
    labels = [node.get("label") for node in _nodes(reloaded) if node.get("type") == "button"]
    assert "Reload retained output" in labels


def test_flat_panel_state_falls_back_to_top_level_fields():
    flat = {
        "mode": "panel", "status": "ready",
        "session_id": "term_01JABCDEF", "target": "ops@staging.example",
        "directory": "/srv/astral/work", "state": "running",
        "cols": 100, "rows": 30, "offset": 4, "next_offset": 9,
        "ring_start": 0, "ring_end": 9,
        "text": "streamed\n",
    }
    view = build_terminal_view(flat)
    serialized = json.dumps([node for node in _nodes(view)], ensure_ascii=False)
    for expected in ("term_01JABCDEF", "ops@staging.example", "streamed", "100 × 30"):
        assert expected in serialized
    window = next(node for node in _nodes(view) if node.get("type") == "keyvalue"
                  and node.get("title") == "Output window")
    assert window["items"] == [{"label": "Read from byte", "value": "4"},
                              {"label": "Next byte", "value": "9"}]
