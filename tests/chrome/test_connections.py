"""Tests for src/astralprojection/chrome/connections.py: credential row states, the
issue form, and one-time secret disclosure.
"""

from __future__ import annotations

import json
from copy import deepcopy
from pathlib import Path

import pytest

from astralprojection.chrome import render_html
from astralprojection.chrome.connections import (
    ISSUE_ACTION,
    REVOKE_ACTION,
    build_connections_view,
    build_issued_secret_view,
)
from astralprojection.models import LayoutView, ThemeView

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "contracts/fixtures/connections_088/connections_surface.json"
SECRET = "afk_5e6fQ2p7X1mK8sT4vB0nL6rJ9wZ3yH5c"


def row(**values):
    return {
        "credential_id": "6a0f2c5d-4a1e-4c6b-9d3f-1b2c3d4e5f60",
        "revision": 2,
        "name": "Laptop scripts",
        "prefix": "afk_9f3c",
        "scopes": ["operations.read", "operations.submit"],
        "created_at": "2026-09-12T12:00:00+00:00",
        "expires_at": "2026-12-12T12:00:00+00:00",
        "consumed_admissions": 7,
        "max_admissions": 100,
        "revoked": False,
        "expired": False,
        **values,
    }


def fresh(**values):
    return row(
        **{
            "credential_id": "9d3f5f80-7d4f-4f9e-8a6c-4e5f60718293",
            "prefix": "afk_5e6f",
            "revision": 1,
            "consumed_admissions": 0,
            "name": "New key",
            **values,
        }
    )


def form_state(**values):
    return {
        "scope_options": ["operations.control", "operations.read", "operations.submit"],
        "defaults": {
            "name": "",
            "scopes": ["operations.read"],
            "expires_in_seconds": 2592000,
            "max_admissions": 100,
        },
        "error": None,
        **values,
    }


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


def encoded(view):
    return json.dumps(view.to_dict(), ensure_ascii=False)


def actions(view):
    found = set()
    for node in nodes(view.to_dict()):
        for key in ("action", "submit_action"):
            if isinstance(node.get(key), str):
                found.add(node[key])
    return found


def unavailable(view):
    html = render_html(view)
    assert "unavailable" in html.lower() or "not allowed" in html.lower()
    assert actions(view) == set()
    return html


def test_list_renders_every_row_without_any_secret_and_only_server_bound_commands():
    view = build_connections_view([row(), fresh()], form_state())
    html = render_html(view)
    assert SECRET not in encoded(view) and SECRET not in html
    assert "afk_9f3c" in html and "operations.read, operations.submit" in html
    assert "7 of 100" in html
    assert actions(view) == {ISSUE_ACTION, REVOKE_ACTION}
    revokes = [
        node
        for node in nodes(view.to_dict())
        if node.get("action") == REVOKE_ACTION
    ]
    assert [node["payload"] for node in revokes] == [
        {"version": 1, "credential_id": row()["credential_id"], "expected_revision": 2},
        {"version": 1, "credential_id": fresh()["credential_id"], "expected_revision": 1},
    ]


def test_caller_state_is_never_mutated_and_empty_is_distinguished_from_broken():
    rows = [row()]
    before = deepcopy(rows)
    build_connections_view(rows, form_state())
    assert rows == before
    empty = render_html(build_connections_view([], form_state()))
    assert "not issued any keys yet" in empty and "unavailable" not in empty.lower()


@pytest.mark.parametrize(
    "change,label,badge",
    [
        ({}, "Active", "success"),
        ({"revoked": True}, "Revoked", "error"),
        ({"expired": True}, "Expired", "warning"),
        ({"consumed_admissions": 100}, "Allowance used up", "warning"),
    ],
)
def test_revoked_expired_and_exhausted_rows_carry_their_own_badge(change, label, badge):
    view = build_connections_view([row(**change)], None)
    badges = [node for node in nodes(view.to_dict()) if node.get("type") == "badge"]
    assert [(node["label"], node["variant"]) for node in badges] == [(label, badge)]
    assert (REVOKE_ACTION in actions(view)) is (label in {"Active", "Allowance used up"})
    if label in {"Revoked", "Expired"}:
        assert "can no longer be used" in render_html(view)


def test_a_revoked_row_that_is_also_exhausted_is_shown_as_revoked():
    view = build_connections_view([row(revoked=True, consumed_admissions=100)], None)
    assert "Revoked" in render_html(view) and REVOKE_ACTION not in actions(view)


@pytest.mark.parametrize(
    "change",
    [
        {"credential_id": "not-a-uuid"},
        {"revision": 0},
        {"revision": True},
        {"name": "  "},
        {"prefix": "af"},
        {"scopes": ["Operations.Read"]},
        {"scopes": ["operations.read", "operations.read"]},
        {"scopes": ["operations.submit", "operations.read"]},
        {"consumed_admissions": 101},
        {"consumed_admissions": -1},
        {"max_admissions": 0},
        {"revoked": "yes"},
        {"expired": None},
    ],
)
def test_unknown_or_malformed_row_fields_are_refused_whole(change):
    unavailable(build_connections_view([row(**change)], form_state()))


def test_extra_and_missing_row_keys_are_refused_rather_than_partially_rendered():
    extra = row()
    extra["owner_id"] = "SECRETOWNER"
    view = build_connections_view([extra], None)
    assert "SECRETOWNER" not in encoded(view)
    unavailable(view)
    missing = row()
    del missing["expired"]
    unavailable(build_connections_view([missing], None))


def test_duplicate_rows_are_refused_so_one_key_is_never_shown_twice():
    unavailable(build_connections_view([row(), row()], None))


def test_issue_form_offers_only_the_hosts_own_scope_vocabulary():
    view = build_connections_view([], form_state())
    picker = next(node for node in nodes(view.to_dict()) if node.get("type") == "param_picker")
    assert picker["submit_action"] == ISSUE_ACTION and picker["submit_payload"] == {"version": 1}
    scopes = next(item for item in picker["fields"] if item["name"] == "scopes")
    assert scopes["options"] == ["operations.control", "operations.read", "operations.submit"]
    assert scopes["default"] == ["operations.read"]
    assert [item["name"] for item in picker["fields"]] == [
        "name",
        "scopes",
        "expires_in_seconds",
        "max_admissions",
    ]


def test_absent_form_state_offers_no_issue_affordance_at_all():
    view = build_connections_view([row()], None)
    assert ISSUE_ACTION not in actions(view)
    assert not [node for node in nodes(view.to_dict()) if node.get("type") == "param_picker"]


def test_form_error_is_shown_without_losing_the_form():
    view = build_connections_view([], form_state(error="That expiry is too long."))
    html = render_html(view)
    assert "That expiry is too long." in html and ISSUE_ACTION in actions(view)


@pytest.mark.parametrize(
    "change",
    [
        {"scope_options": []},
        {"scope_options": ["operations.submit", "operations.read"]},
        {"scope_options": ["Operations.Read"]},
        {"defaults": {"name": "", "scopes": ["operations.unknown"], "expires_in_seconds": 1,
                      "max_admissions": 1}},
        {"defaults": {"name": "", "scopes": [], "expires_in_seconds": 0, "max_admissions": 1}},
        {"defaults": {"name": "", "scopes": [], "expires_in_seconds": 1, "max_admissions": 0}},
        {"defaults": {"name": "", "scopes": []}},
    ],
)
def test_malformed_issue_form_state_refuses_the_view(change):
    unavailable(build_connections_view([row()], form_state(**change)))


def test_denied_and_error_states_carry_no_rows_and_no_actions():
    denied = build_connections_view([row()], form_state(), denied=True)
    assert "not allowed" in render_html(denied) and "afk_9f3c" not in encoded(denied)
    failed = build_connections_view([row()], form_state(), error="Connections are unavailable.")
    assert actions(failed) == set() and "afk_9f3c" not in encoded(failed)


def test_issued_secret_is_rendered_exactly_once_in_its_own_view():
    view = build_issued_secret_view(SECRET, fresh())
    serialized = encoded(view)
    html = render_html(view)
    assert serialized.count(SECRET) == 1 and html.count(SECRET) == 1
    assert "shown once" in html and "cannot be shown again" in html
    assert actions(view) == {"chrome_open"}
    assert ISSUE_ACTION not in serialized and REVOKE_ACTION not in serialized


def test_the_secret_never_reaches_any_action_payload():
    view = build_issued_secret_view(SECRET, fresh())
    for node in nodes(view.to_dict()):
        payload = node.get("payload") or node.get("submit_payload")
        if payload is not None:
            assert SECRET not in json.dumps(payload)


def test_returning_from_the_issued_view_lands_on_a_listing_that_cannot_show_it():
    issued = build_issued_secret_view(SECRET, fresh())
    back = next(node for node in nodes(issued.to_dict()) if node.get("type") == "button")
    assert back["payload"] == {"surface": "connections", "params": {}}
    listing = build_connections_view([fresh()], form_state())
    assert SECRET not in encoded(listing) and SECRET not in render_html(listing)


@pytest.mark.parametrize(
    "secret",
    [
        "afk_9f3cQ2p7X1mK8sT4vB0nL6rJ9wZ3yH5c",
        "afk_5e6f",
        "afk_5e6f Q2p7X1mK8sT4vB0nL6rJ9wZ3yH5c",
        "afk_5e6féQ2p7X1mK8sT4vB0nL6rJ9wZ3yH",
        None,
        b"afk_5e6fQ2p7X1mK8sT4vB0nL6rJ9wZ3yH5c",
    ],
)
def test_a_secret_that_does_not_belong_to_the_record_is_never_displayed(secret):
    view = build_issued_secret_view(secret, fresh())
    html = unavailable(view)
    assert "Q2p7X1mK8sT4v" not in html and "Q2p7X1mK8sT4v" not in encoded(view)


@pytest.mark.parametrize(
    "change",
    [{"revoked": True}, {"expired": True}, {"consumed_admissions": 1}, {"prefix": "afk_9f3c"}],
)
def test_a_secret_is_not_shown_for_a_record_that_is_not_freshly_issued(change):
    unavailable(build_issued_secret_view(SECRET, fresh(**change)))


def test_issued_view_refuses_a_malformed_record_without_leaking_the_secret():
    broken = fresh()
    broken["revision"] = "one"
    view = build_issued_secret_view(SECRET, broken)
    assert SECRET not in encoded(view) and SECRET not in unavailable(view)


def test_theme_and_layout_are_carried_through_both_views():
    theme, layout = ThemeView("midnight"), LayoutView("compact")
    for view in (
        build_connections_view([row()], form_state(), theme=theme, layout=layout),
        build_issued_secret_view(SECRET, fresh(), theme=theme, layout=layout),
    ):
        assert view.theme.name == "midnight" and view.layout.mode == "compact"
        assert view.surface == "connections" and view.title == "Connections"


def test_committed_fixture_is_the_exact_shared_builder_output():
    document = json.loads(FIXTURE.read_text(encoding="utf-8"))
    manifest = json.loads((ROOT / "contracts/ui_protocol.json").read_text(encoding="utf-8"))
    contract = manifest["presentation_contracts"]["connections_088"]
    assert contract["fixture"] == "contracts/fixtures/connections_088/connections_surface.json"
    assert contract["surface_key"] == "connections"
    assert contract["client_capability"] == "connections_v1"
    assert set(contract["actions"]) == {ISSUE_ACTION, REVOKE_ACTION}
    assert set(contract["actions"]) <= set(manifest["accept_actions"])
    assert contract["navigation"]["action"] in manifest["accept_actions"]
    assert set(contract["content"]["types"]) <= set(manifest["component_types"])
    for mode, state in document["states"].items():
        view = (
            build_issued_secret_view(state["secret"], state["view"])
            if mode == "issued"
            else build_connections_view(state["rows"], state["form_state"])
        )
        frame = document["frames"][mode]
        assert set(frame) == set(contract["native_response"]["exact_fields"])
        assert frame["components"] == [item.to_dict() for item in view.components]
        assert frame["surface_key"] == "connections" and frame["mode"] == "replace"
        assert frame["region"] == "modal" and frame["admin_only"] is False
        used = {item["type"] for item in nodes(frame["components"]) if "type" in item}
        assert used <= set(contract["content"]["types"])
        found = {item["action"] for item in nodes(frame["components"]) if "action" in item}
        found |= {
            item["submit_action"] for item in nodes(frame["components"]) if "submit_action" in item
        }
        assert found <= set(contract["actions"]) | {contract["navigation"]["action"]}


def test_only_the_dedicated_issued_fixture_frame_carries_key_material():
    document = json.loads(FIXTURE.read_text(encoding="utf-8"))
    for mode, frame in document["frames"].items():
        occurrences = json.dumps(frame, ensure_ascii=False).count(SECRET)
        assert occurrences == (1 if mode == "issued" else 0), mode
    for mode, frame in document["web_frames"].items():
        assert frame["html"].count(SECRET) == (1 if mode == "issued" else 0), mode
