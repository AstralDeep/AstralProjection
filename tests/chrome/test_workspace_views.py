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
