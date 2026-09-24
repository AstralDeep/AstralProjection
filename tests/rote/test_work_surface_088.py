"""Tests for the read-only Work surface (backend/rote/work.py,
backend/webrender/chrome/menu_model.py): navigation descriptors, builder output,
save-command vocabulary, and refusal of malformed or oversized payloads.
"""

from copy import deepcopy
import importlib.util
from pathlib import Path
import json

import pytest

from astralprojection.chrome.work import build_work_view
from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile
from rote.work import validate_work_components, validate_work_navigation
from webrender.chrome.menu_model import (
    build_menu_model,
    menu_model_dict,
    project_watch_menu_model,
)
from webrender.chrome.topbar import render_topbar

spec = importlib.util.spec_from_file_location(
    "work_view_fixtures", Path(__file__).parents[1] / "chrome/test_work.py"
)
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


def components(state):
    return build_work_view(state).to_dict()["components"]


def test_work_navigation_is_one_server_descriptor_with_explicit_watch_projection():
    legacy = menu_model_dict()
    assert not project_watch_menu_model(legacy)["topbar"]
    enabled = menu_model_dict(work_enabled=True, export_enabled=True, share_enabled=True)
    expected = next(c for c in enabled["topbar"] if c["key"] == "work")
    projected = project_watch_menu_model(enabled)
    assert projected["topbar"] == [expected]
    assert projected["menu"] == [] and projected["signout"] == {}
    assert expected["action"] == {"surface": "work", "params": {"mode": "list"}}
    projected["topbar"][0]["label"] = "Changed"
    assert expected["label"] == "Recent work"
    enabled["topbar"].append(expected)
    assert not project_watch_menu_model(enabled)["topbar"]
    assert not project_watch_menu_model(None)["topbar"]
    assert not project_watch_menu_model({"topbar": 3})["topbar"]
    from webrender.chrome.settings_nav import render_settings_nav

    assert "Recent work" not in render_settings_nav(build_menu_model())
    assert "Recent work" not in render_settings_nav(build_menu_model(work_enabled=True))
    assert "Recent work" not in render_topbar(work_enabled=True)


@pytest.mark.parametrize("mode", ["list", "detail", "result"])
@pytest.mark.parametrize("device", ["watch", "ios", "macos", "android", "browser"])
def test_actual_builder_is_preserved_in_each_read_surface(mode, device):
    state = fixtures.state()
    state["mode"] = mode
    state["page"] = {"operations": [fixtures.operation()], "next_cursor": None, "page_full": False}
    raw = components(state)
    before = deepcopy(raw)
    adapted = ComponentAdapter.adapt_work_surface(
        raw, DeviceProfile.from_dict({"device_type": device})
    )
    assert adapted == raw == before
    adapted[0]["variant"] = "changed"
    assert raw == before


def test_actual_maximum_producer_result_keeps_every_passage_and_source_field():
    state = fixtures.state()
    page = state["result"]["result"]["content"]
    page["source"].update(
        title="🙂" * 128,
        requested_url="https://example.org/段落/" + "a" * 1638,
        final_url="https://example.org/段落/" + "b" * 1638,
    )
    page["passages"] = [{"id": f"p{i:03}", "text": "🙂" + "x" * 511} for i in range(1, 8)]
    page["passages"].append({"id": "p008", "text": "zq"})
    import json

    assert (
        len(json.dumps(page, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode())
        == 8192
    )
    raw = components(state)
    profile = DeviceProfile.from_dict({"device_type": "watch"})
    assert ComponentAdapter.adapt(raw, profile) != raw
    assert ComponentAdapter.adapt_work_surface(raw, profile) == raw
    assert profile.max_text_chars == 120 and not profile.supports_file_io


def test_maximum_list_and_host_action_bounds_preserve_complete_passive_content():
    rows = [
        fixtures.operation(id=f"00000000-0000-4000-8000-{i:012x}", title="x" * 4096)
        for i in range(100)
    ]
    raw = components(
        {
            "mode": "list",
            "status": "ready",
            "page": {"operations": rows, "next_cursor": rows[-1]["id"], "page_full": True},
        }
    )
    profile = DeviceProfile.from_dict({"device_type": "watch"})
    assert ComponentAdapter.adapt_work_surface(raw, profile) == raw
    profile.supports_interactivity = False
    passive = ComponentAdapter.adapt_work_surface(raw, profile)
    assert all(n.get("type") != "button" for n in fixtures.nodes({"components": passive}))
    assert [n["title"] for n in passive if n["type"] == "card"] == [r["title"] for r in rows]
    profile.supports_interactivity = True
    profile.max_actions = 1
    limited = ComponentAdapter.adapt_work_surface(raw, profile)
    assert sum(n.get("type") == "button" for n in fixtures.nodes({"components": limited})) == 1


@pytest.mark.parametrize(
    "payload",
    [
        None,
        {},
        {"surface": "work", "params": {}},
        {"surface": "llm", "params": {"mode": "list"}},
        {"surface": "work", "params": {"mode": "create"}},
        {"surface": "work", "params": {"mode": "result"}},
        {"surface": "work", "params": {"mode": "list", "after_id": "bad"}},
        {"surface": "work", "params": {"mode": "list", "after_id": 12}},
        {
            "surface": "work",
            "params": {"mode": "list", "after_id": "00000000-0000-1000-8000-000000000000"},
        },
        {"surface": "work", "params": {"mode": "list", "fields": {}}},
    ],
)
def test_navigation_refuses_effects_aliases_and_malformed_identifiers(payload):
    with pytest.raises(ValueError, match="^work_surface_unavailable$"):
        validate_work_navigation(payload)


@pytest.mark.parametrize(
    "raw",
    [
        None,
        {},
        [{"type": "file_download", "url": "https://example.org"}],
        [{"type": "text", "content": "secret", "variant": "body", "action": "delete"}],
        [{"type": "text", "content": "\ud800", "variant": "body"}],
        [{"type": "text", "content": "x" * 8193, "variant": "body"}],
        [{"type": "text", "content": float("nan"), "variant": "body"}],
        [{"type": "keyvalue", "items": [{"label": "a", "value": "b", "action": "delete"}]}],
        [{"type": "card", "title": "x", "content": {}, "variant": "default"}],
        [{"type": "text", "content": "x", "variant": "body"}] * 1025,
    ],
)
def test_entire_unknown_or_oversized_surface_refused_without_content(raw):
    with pytest.raises(ValueError, match="^work_surface_unavailable$"):
        validate_work_components(raw)


def test_unsupported_target_and_hidden_button_payloads_refuse():
    raw = components({"mode": "list", "status": "unavailable"})
    with pytest.raises(ValueError):
        validate_work_components(raw, frozenset({"text"}))
    for field, value in [("action", "work_delete"), ("local", True), ("disabled", 1)]:
        broken = deepcopy(raw)
        broken[-1][field] = value
        with pytest.raises(ValueError):
            validate_work_components(broken)


def test_deep_and_cyclic_payloads_have_closed_refusal():
    node = {"type": "text", "variant": "body", "content": "x"}
    for _ in range(10):
        node = {"type": "card", "variant": "default", "title": "", "content": [node]}
    with pytest.raises(ValueError):
        validate_work_components([node])
    node["content"] = [node]
    with pytest.raises(ValueError):
        validate_work_components([node])


def test_shared_swift_golden_is_the_actual_builder_and_rote_output():
    root = Path(__file__).parents[2]
    fixture = json.loads((root / "contracts/fixtures/work_088/read_surface.json").read_text())
    profile = DeviceProfile.from_dict(fixture["device"])
    for name, state in fixture["states"].items():
        view = build_work_view(state).to_dict()
        assert fixture["frames"][name]["title"] == view["title"]
        assert fixture["frames"][name]["components"] == ComponentAdapter.adapt_work_surface(
            view["components"], profile
        )
    assert fixture["menu"] == project_watch_menu_model(menu_model_dict(work_enabled=True))


from rote.work import SAVE_ACTION, validate_work_save_command  # noqa: E402

PROPOSE = {
    "version": 1, "command": "propose", "operation_id": fixtures.ID,
    "submission_id": fixtures.SUBMISSION, "publication_id": fixtures.PUBLICATION,
    "expected_revision": 3, "conversation_id": "chat-1", "expected_workspace_revision": 0,
    "expected_workspace_publication_id": None,
}
SAVE = {
    "version": 1, "command": "save", "operation_id": fixtures.ID, "action_id": fixtures.SUBMISSION,
    "submission_id": fixtures.APPROVAL, "expected_revision": 4, "proposal_digest": "c" * 64,
}


def test_save_command_vocabulary_accepts_exactly_the_two_server_bound_steps():
    validate_work_save_command(PROPOSE)
    validate_work_save_command({**PROPOSE, "expected_workspace_revision": 2,
                                "expected_workspace_publication_id": fixtures.OTHER})
    validate_work_save_command(SAVE)


@pytest.mark.parametrize(
    "payload",
    [
        None, {}, [],
        {**PROPOSE, "version": 2}, {**PROPOSE, "version": True}, {**PROPOSE, "command": "publish"},
        {**PROPOSE, "extra": 1}, {k: v for k, v in PROPOSE.items() if k != "publication_id"},
        {**PROPOSE, "submission_id": fixtures.PUBLICATION}, {**PROPOSE, "expected_revision": 0},
        {**PROPOSE, "expected_revision": True}, {**PROPOSE, "conversation_id": " padded "},
        {**PROPOSE, "conversation_id": ""}, {**PROPOSE, "conversation_id": "x" * 513},
        {**PROPOSE, "expected_workspace_revision": 1},
        {**PROPOSE, "expected_workspace_publication_id": fixtures.OTHER},
        {**PROPOSE, "expected_workspace_revision": -1},
        {**PROPOSE, "operation_id": "00000000-0000-1000-8000-000000000000"},
        {**SAVE, "proposal_digest": "C" * 64}, {**SAVE, "proposal_digest": "c" * 63},
        {**SAVE, "action_id": fixtures.APPROVAL}, {**SAVE, "expected_revision": 0},
        {**SAVE, "publication_id": fixtures.PUBLICATION},
        {k: v for k, v in SAVE.items() if k != "action_id"},
        {**SAVE, "command": "approve"},
    ],
)
def test_save_command_vocabulary_refuses_every_other_shape(payload):
    with pytest.raises(ValueError, match="^work_surface_unavailable$"):
        validate_work_save_command(payload)


def _button(action, payload):
    return {"type": "button", "label": "x", "action": action, "payload": payload,
            "variant": "primary", "disabled": False, "local": False}


def test_only_the_exact_save_action_joins_the_passive_surface():
    assert validate_work_components([_button(SAVE_ACTION, PROPOSE)]) == [_button(SAVE_ACTION, PROPOSE)]
    assert validate_work_components([_button(SAVE_ACTION, SAVE)])
    for action, payload in [
        (SAVE_ACTION, {"surface": "work", "params": {"mode": "list"}}),
        ("chrome_open", PROPOSE),
        ("chrome_work_result_publish", SAVE),
        ("chrome_job_stop", {"job_id": fixtures.ID}),
    ]:
        with pytest.raises(ValueError, match="^work_surface_unavailable$"):
            validate_work_components([_button(action, payload)])
    hidden = _button(SAVE_ACTION, SAVE)
    hidden["local"] = True
    with pytest.raises(ValueError):
        validate_work_components([hidden])


@pytest.mark.parametrize("name", ["result_saveable", "review", "review_expired", "review_undecidable"])
@pytest.mark.parametrize("device", ["watch", "ios", "macos", "android", "browser"])
def test_save_and_review_frames_are_complete_closed_surfaces(name, device):
    root = Path(__file__).parents[2]
    fixture = json.loads(
        (root / "contracts/fixtures/work_088/save_review.json").read_text(encoding="utf-8"))
    raw = components(fixture["states"][name])
    assert raw == fixture["frames"][name]["components"]
    before = deepcopy(raw)
    profile = DeviceProfile.from_dict({"device_type": device})
    assert ComponentAdapter.adapt_work_surface(raw, profile) == raw == before
    profile.supports_interactivity = False
    passive = ComponentAdapter.adapt_work_surface(raw, profile)
    assert all(n.get("type") != "button" for n in fixtures.nodes({"components": passive}))
    assert "Exact retained evidence" in json.dumps(passive, ensure_ascii=False)
