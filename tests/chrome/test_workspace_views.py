from __future__ import annotations

from astralprojection.chrome import render_html
from astralprojection.chrome.workspace import (
    build_feature_flags_view,
    build_history_view,
    build_remote_machines_view,
    build_timeline_view,
    build_workspace_view,
)


def _actions(view) -> list[str]:
    found: list[str] = []

    def visit(value) -> None:
        if isinstance(value, dict):
            if isinstance(value.get("action"), str):
                found.append(value["action"])
            if isinstance(value.get("submit_action"), str):
                found.append(value["submit_action"])
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(view.to_dict())
    return found


def test_remote_machine_feature_gate_denial_error_and_empty_state() -> None:
    denied = build_remote_machines_view(denied=True)
    assert "access denied" in render_html(denied)
    assert _actions(denied) == []
    disabled = build_remote_machines_view(enabled=False)
    assert "disabled on this server" in render_html(disabled)
    assert _actions(disabled) == []
    failed = build_remote_machines_view(error="Remote inventory failed")
    assert "Remote inventory failed" in render_html(failed)
    empty = build_remote_machines_view()
    html = render_html(empty)
    assert "No machines yet" in html
    assert "chrome_machine_add" in _actions(empty)
    assert 'type="password"' in html
    assert 'name="private_key"' in html


def test_remote_machine_populated_actions_and_secret_free_state() -> None:
    view = build_remote_machines_view(
        [
            {
                "id": "m1",
                "label": "Cluster <script>",
                "address": "cluster.example",
                "port": 22,
                "os_family": "linux",
                "role": "cluster",
                "last_verdict": "ok",
                "password": "MUST_NOT_APPEAR",
            },
            {
                "machine_id": "m2",
                "label": "Changed host",
                "address": "new.example",
                "port": None,
                "os_family": "macos",
                "role": "plain",
                "last_verdict": "host_key_mismatch",
            },
        ]
    )
    encoded = str(view.to_dict())
    assert "MUST_NOT_APPEAR" not in encoded
    html = render_html(view)
    assert "<script>" not in html
    actions = _actions(view)
    assert actions.count("chrome_machine_probe") == 2
    assert actions.count("chrome_machine_retrust") == 1
    assert actions.count("chrome_machine_credential_set") == 2
    assert actions.count("chrome_machine_credential_delete") == 2
    assert actions.count("chrome_machine_delete") == 2
    assert actions.count("chrome_machine_add") == 1


def test_feature_flags_are_read_only_and_explain_policy() -> None:
    assert "access denied" in render_html(build_feature_flags_view([], denied=True))
    assert "Flag service offline" in render_html(
        build_feature_flags_view([], error="Flag service offline")
    )
    empty = build_feature_flags_view([])
    assert "No feature flags" in render_html(empty)
    flags = build_feature_flags_view(
        [
            {
                "key": "pulse_digest",
                "label": "Pulse",
                "enabled": True,
                "description": "Shows the digest",
                "source": "deployment policy",
            },
            {"key": "remote_compute", "enabled": False},
        ]
    )
    html = render_html(flags)
    assert "enabled" in html and "disabled" in html
    assert "read-only" in html
    assert _actions(flags) == []


def test_workspace_view_accepts_protocol_values_and_never_queries_host() -> None:
    assert "Workspace access denied" in render_html(build_workspace_view({}, denied=True))
    assert "Workspace offline" in render_html(build_workspace_view({}, error="Workspace offline"))
    empty = build_workspace_view({})
    assert "no visible components" in render_html(empty)
    state = build_workspace_view(
        {
            "title": "Clinical <workspace>",
            "chat_id": "chat-1",
            "read_only": True,
            "read_only_reason": "Historical snapshot",
            "components": [
                {"type": "text", "content": "Hello <script>", "variant": "body"},
                {"type": "card", "title": "Result", "content": []},
                "bad",
            ],
        }
    )
    html = render_html(state)
    assert "Clinical &lt;workspace&gt;" in html
    assert "Hello &lt;script&gt;" in html
    assert "Historical snapshot" in html
    assert _actions(state) == ["chrome_open"]


def test_history_empty_error_selected_and_open_actions() -> None:
    assert "History offline" in render_html(build_history_view([], error="History offline"))
    assert "No conversations" in render_html(build_history_view([]))
    history = build_history_view(
        [
            {"id": "chat-1", "title": "Current", "updated_at": "today", "summary": "Now"},
            {"chat_id": "chat-2", "title": "Prior", "updated_at": "yesterday"},
        ],
        selected_chat_id="chat-1",
    )
    html = render_html(history)
    assert "Current" in html
    assert "Prior" in html
    assert _actions(history) == ["load_chat"]


def test_timeline_no_chat_empty_error_and_pagination() -> None:
    assert "Timeline offline" in render_html(build_timeline_view(error="Timeline offline"))
    assert "Open a chat first" in render_html(build_timeline_view())
    assert "No workspace history" in render_html(build_timeline_view(chat_id="chat-1"))
    snapshots = [
        {"id": 5, "cause": "turn", "created_at": "today"},
        {"snapshot_id": 4, "cause": "custom", "created_at": "yesterday"},
    ]
    first = build_timeline_view(snapshots, chat_id="chat-1", page=0, total=120)
    first_actions = _actions(first)
    assert first_actions.count("chrome_workspace_timeline_view") == 2
    assert "chrome_workspace_timeline_live" in first_actions
    assert "Older" in render_html(first)
    assert "Newer" not in render_html(first)
    middle = build_timeline_view(snapshots, chat_id="chat-1", page=1, total=120)
    middle_html = render_html(middle)
    assert "Newer" in middle_html and "Older" in middle_html
    last = build_timeline_view(snapshots, chat_id="chat-1", page=2, total=102)
    assert "Newer" in render_html(last)
    assert "Older" not in render_html(last)


def test_timeline_snapshot_missing_and_read_only_component_render() -> None:
    missing = build_timeline_view(chat_id="chat-1", selected={})
    assert "no longer exists" in render_html(missing)
    selected = build_timeline_view(
        chat_id="chat-1",
        selected={
            "cause": "component_action",
            "created_at": "today",
            "components": [
                {"type": "text", "content": "Past value"},
                {"type": "unknown_widget", "value": "x"},
                "bad",
            ],
        },
    )
    html = render_html(selected)
    assert "read-only" in html
    assert "Past value" in html
    assert "unknown_widget component is not available" in html
    assert _actions(selected) == ["chrome_workspace_timeline_live"]


# ── Feature 088 T044: saved results (result-publication receipts) ──────────────

import json  # noqa: E402
from pathlib import Path  # noqa: E402

import pytest  # noqa: E402

from astralprojection.chrome.workspace import build_saved_results_view  # noqa: E402

PUBLICATION = "7c3d5a9e-1f2b-4c6d-8e7f-0a1b2c3d4e5f"
OPERATION = "180cd30b-cc38-432d-8349-1851b0d3ad7e"
ACTION = "48873d61-2e9b-4f38-bc36-bbfa81d78580"
EXPORT_URL = "/api/export/canvas/chat-1.html?render_revision=1"


def receipt(**overrides):
    return {
        "publication_id": PUBLICATION, "action_id": ACTION, "operation_id": OPERATION,
        "operation_title": "Public page research", "conversation_id": "chat-1",
        "conversation_title": "Reviewed result destination",
        "component_id": "au_work_result_" + OPERATION, "committed_render_revision": 1,
        "committed_at": "2026-09-12T12:05:00+00:00",
        "provenance": {"source_title": "Original source", "requested_url": "https://example.org/start",
                       "final_url": "https://example.org/page",
                       "retrieved_at": "2026-09-12T12:00:00+00:00",
                       "result_digest": "a" * 64, "content_digest": "d" * 64, "stage_digest": "e" * 64},
        **overrides,
    }


def _nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from _nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from _nodes(child)


def _payloads(view, action):
    return [n["payload"] for n in _nodes(view.to_dict()) if n.get("action") == action]


def test_saved_results_denied_error_empty_and_unknown_modes() -> None:
    assert "access denied" in render_html(build_saved_results_view({}, denied=True))
    assert "Receipts offline" in render_html(build_saved_results_view({}, error="Receipts offline"))
    empty = build_saved_results_view({"mode": "list", "receipts": []})
    assert "No saved results yet" in render_html(empty) and _actions(empty) == []
    assert "never saves" in render_html(empty)
    assert "unavailable" in render_html(build_saved_results_view({"mode": "save"})).lower()
    assert "No saved results yet" in render_html(build_saved_results_view(None))
    assert "No saved results yet" in render_html(build_saved_results_view({"receipts": "bad"}))


def test_saved_results_list_and_detail_bind_only_existing_destinations() -> None:
    listed = build_saved_results_view({"mode": "list", "receipts": [receipt()], "next_cursor": "older"})
    html = render_html(listed)
    assert "Public page research" in html and "Reviewed result destination" in html
    assert _payloads(listed, "load_chat") == [{"chat_id": "chat-1"}]
    opened = _payloads(listed, "chrome_open")
    assert {"surface": "saved_results", "params": {"mode": "detail", "publication_id": PUBLICATION}} in opened
    assert {"surface": "saved_results", "params": {"mode": "list", "after": "older"}} in opened
    assert "Provenance" not in html and "file_download" not in json.dumps(listed.to_dict())
    detail = build_saved_results_view({"mode": "detail", "receipt": receipt(
        export={"url": EXPORT_URL, "filename": "result.html"})})
    html = render_html(detail)
    for expected in ("Provenance", "a" * 64, "d" * 64, "e" * 64, "https://example.org/page",
                     "Original source", "au_work_result_" + OPERATION, PUBLICATION, OPERATION,
                     "<dd>1</dd>", "Back to saved results"):
        assert expected in html
    assert _payloads(detail, "load_chat") == [{"chat_id": "chat-1"}]
    assert {"surface": "workspace_timeline", "params": {"chat_id": "chat-1", "page": 0}} in _payloads(detail, "chrome_open")
    downloads = [n for n in _nodes(detail.to_dict()) if n.get("type") == "file_download"]
    assert downloads == [{"type": "file_download", "label": "Export saved page (HTML)",
                          "url": EXPORT_URL, "filename": "result.html"}]
    for view in (listed, detail):
        encoded = json.dumps(view.to_dict())
        assert "chrome_work_result_save" not in encoded and "Save result" not in encoded
        assert "never saves" in render_html(view)


@pytest.mark.parametrize("export", [
    None, "string", {}, {"url": "https://evil.example/api/export/x"}, {"url": "//api/export/x"},
    {"url": "/api/other/x"}, {"url": "/api/export/canvas/chat 1.html"}, {"url": "/api/export/\x00"},
    {"url": "/api/export/" + "x" * 2048}, {"url": 12},
])
def test_export_requires_a_host_issued_root_relative_export_path(export) -> None:
    view = build_saved_results_view({"mode": "detail", "receipt": receipt(export=export)})
    encoded = json.dumps(view.to_dict())
    assert "file_download" not in encoded and "evil" not in encoded
    assert "Export is not available" in render_html(view)


def test_export_filename_is_optional_and_control_free() -> None:
    bad = build_saved_results_view({"mode": "detail", "receipt": receipt(
        export={"url": "/api/export/canvas/chat-1.html", "filename": "bad\x00name"})})
    [download] = [n for n in _nodes(bad.to_dict()) if n.get("type") == "file_download"]
    assert "filename" not in download and download["url"] == "/api/export/canvas/chat-1.html"


def test_saved_results_bounds_unknown_values_and_malformed_rows() -> None:
    rows = [receipt()] * 60 + ["bad", 3]
    view = build_saved_results_view({"mode": "list", "receipts": rows})
    assert render_html(view).count("<h3>Public page research</h3>") == 50
    unnamed = build_saved_results_view(
        {"mode": "list", "receipts": [receipt(publication_id="bad", operation_title=None)]})
    html = render_html(unnamed)
    assert "View saved result" not in html and "<h3>Saved result</h3>" in html
    missing = build_saved_results_view({"mode": "detail", "receipt": receipt(publication_id="bad")})
    assert "not available" in render_html(missing) and _actions(missing) == ["chrome_open"]
    assert "not available" in render_html(build_saved_results_view({"mode": "detail", "receipt": "bad"}))
    zero = build_saved_results_view({"mode": "detail", "receipt": receipt(
        committed_render_revision=0, committed_at=None, provenance={"result_digest": "short"},
        conversation_id="", conversation_title="")})
    html = render_html(zero)
    assert "<dt>Saved revision</dt><dd>0</dd>" in html and "<dt>Saved at</dt><dd>Unknown</dd>" in html
    assert "<dt>Result digest</dt><dd>Unavailable</dd>" in html and "Unknown conversation" in html
    assert _actions(zero) == ["chrome_open"] and "load_chat" not in json.dumps(zero.to_dict())
    assert "<dt>Saved revision</dt><dd>Unknown</dd>" in render_html(build_saved_results_view(
        {"mode": "detail", "receipt": receipt(committed_render_revision=True)}))


def test_saved_results_forward_no_result_text_secrets_or_html() -> None:
    row = receipt(payload={"text": "SECRET_RESULT"}, instructions="SECRET_INSTRUCTION",
                  access_token="SECRET_TOKEN", operation_title="<script>x()</script>",
                  provenance={"source_title": "<b>Source</b>", "result_digest": {"raw": "SECRET_RAW"}})
    for mode, key in (("list", "receipts"), ("detail", "receipt")):
        view = build_saved_results_view({"mode": mode, key: [row] if mode == "list" else row})
        encoded = json.dumps(view.to_dict())
        for value in ("SECRET_RESULT", "SECRET_INSTRUCTION", "SECRET_TOKEN", "SECRET_RAW"):
            assert value not in encoded
        html = render_html(view)
        assert "<script>" not in html and "&lt;script&gt;" in html and "<b>" not in html


def test_saved_results_actions_are_manifested_without_new_primitives() -> None:
    manifest = json.loads(
        (Path(__file__).resolve().parents[2] / "contracts/ui_protocol.json").read_text(encoding="utf-8"))
    known = set(manifest["component_types"])
    for state in ({"mode": "list", "receipts": [receipt()]},
                  {"mode": "detail", "receipt": receipt(export={"url": "/api/export/canvas/c.html"})}):
        view = build_saved_results_view(state)
        assert {n["type"] for n in _nodes(view.to_dict()) if "type" in n} <= known
        assert set(_actions(view)) <= set(manifest["accept_actions"])
