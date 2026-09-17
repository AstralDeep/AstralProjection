"""Canonical Work fixtures bind additive negotiated presentation contracts.

``work_read_088`` is the read-only surface; feature 088 T043/T044 add
``work_save_088`` (the one closed non-navigation Work action),
``recurring_work_088`` and ``saved_results_088``. Every fixture frame is the
exact output of its shared builder and every new action is manifested once.
"""
import json
from pathlib import Path

import pytest

from astralprojection.chrome import render_html
from astralprojection.chrome.assignments import build_recurring_work_view
from astralprojection.chrome.work import build_work_view
from astralprojection.chrome.workspace import build_saved_results_view
from rote.work import SAVE_ACTION, validate_work_components, validate_work_navigation
from webrender.chrome import render_modal_shell
from webrender.chrome.menu_model import menu_model_dict, project_watch_menu_model

ROOT = Path(__file__).resolve().parents[1]
BUILDERS = {
    "work_save_088": ("work_save_v1", "work", build_work_view),
    "recurring_work_088": ("recurring_work_v1", "personalization", build_recurring_work_view),
    "saved_results_088": ("saved_results_v1", "saved_results", build_saved_results_view),
}
NEW_ACTIONS = {SAVE_ACTION, "chrome_job_stop"}
# 132 (T037 guidance) + chrome_work_result_save + chrome_job_stop.
# 136 = 134 + the two closed feature-088 T048 Connections actions.
ACTION_COUNT = 136


def manifest():
    return json.loads((ROOT / "contracts/ui_protocol.json").read_text(encoding="utf-8"))


def fixture(contract):
    return json.loads((ROOT / contract["fixture"]).read_text(encoding="utf-8"))


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


def test_work_contract_matches_actual_shared_frames_and_navigation():
    document = manifest()
    contract = document["presentation_contracts"]["work_read_088"]
    read_fixture = fixture(contract)
    expected = set(contract["native_response"]["exact_fields"])
    assert contract["client_capability"] == "work_read_v1"
    for frame in read_fixture["frames"].values():
        assert set(frame) == expected
        assert frame["surface_key"] == contract["surface_key"] == "work"
        assert frame["region"] == "modal" and frame["mode"] == "replace"
        assert frame["admin_only"] is False
        assert validate_work_components(frame["components"]) == frame["components"]
        # The read-only golden is untouched by T043: no Save action rides it.
        assert SAVE_ACTION not in json.dumps(frame)
    model = menu_model_dict(work_enabled=True)
    projected = project_watch_menu_model(model)
    assert projected["menu"] == [] and projected["signout"] == {}
    assert projected["topbar"] == [item for item in model["topbar"] if item["key"] == "work"]
    assert len(projected["topbar"]) == 1
    validate_work_navigation({"surface": "work", "params": {"mode": "list"}})


@pytest.mark.parametrize("name", sorted(BUILDERS))
def test_088_fixtures_are_the_exact_builder_output_with_closed_types_and_actions(name):
    document = manifest()
    contract = document["presentation_contracts"][name]
    capability, surface, builder = BUILDERS[name]
    document_fixture = fixture(contract)
    assert contract["client_capability"] == capability and contract["surface_key"] == surface
    assert set(contract["actions"]) <= set(document["accept_actions"])
    assert contract["navigation"]["action"] in document["accept_actions"]
    assert set(contract["content"]["types"]) <= set(document["component_types"])
    assert document_fixture["states"], name
    for mode, state in document_fixture["states"].items():
        view = builder(state)
        frame = document_fixture["frames"][mode]
        assert set(frame) == set(contract["native_response"]["exact_fields"])
        assert frame["components"] == [item.to_dict() for item in view.components]
        assert frame["surface_key"] == surface and frame["mode"] == "replace"
        assert frame["admin_only"] is False and frame["region"] == "modal"
        assert frame["title"] == view.title
        assert "unavailable" not in render_html(view).lower()
        assert document_fixture["web_frames"][mode]["html"] == render_modal_shell(
            view.title, render_html(view), surface)
        used = {item["type"] for item in nodes(frame["components"]) if "type" in item}
        assert used <= set(contract["content"]["types"]), (mode, used)
        actions = {item["action"] for item in nodes(frame["components"]) if "action" in item}
        assert actions <= set(contract["actions"]) | {contract["navigation"]["action"]}, (mode, actions)


def test_save_fixture_commands_are_the_exact_deep_body_shapes_and_rote_admits_them():
    document = manifest()
    contract = document["presentation_contracts"]["work_save_088"]
    commands = contract["commands"]
    seen = set()
    for mode, frame in fixture(contract)["frames"].items():
        assert validate_work_components(frame["components"]) == frame["components"]
        for item in nodes(frame["components"]):
            if item.get("action") == SAVE_ACTION:
                payload = item["payload"]
                assert set(payload) == set(commands[payload["command"]]) and payload["version"] == 1
                seen.add(payload["command"])
        if mode in ("review_expired", "review_undecidable"):
            assert SAVE_ACTION not in json.dumps(frame)
        assert "Exact retained evidence" in json.dumps(frame, ensure_ascii=False)
    assert seen == {"propose", "save"}
    declared = contract["actions"][SAVE_ACTION]
    optional = {field[:-1] for field in declared if field.endswith("?")}
    required = {field for field in declared if not field.endswith("?")}
    assert required == set(commands["propose"]) & set(commands["save"])
    assert optional == (set(commands["propose"]) | set(commands["save"])) - required


def test_new_088_work_actions_are_manifested_once_and_only_where_declared():
    document = manifest()
    actions = document["accept_actions"]
    assert NEW_ACTIONS <= set(actions) and len(actions) == len(set(actions)) == ACTION_COUNT
    for name, contract in document["presentation_contracts"].items():
        declared = set(contract.get("actions", []))
        if name == "work_save_088":
            assert SAVE_ACTION in declared and "chrome_job_stop" not in declared
        elif name == "recurring_work_088":
            assert "chrome_job_stop" in declared and SAVE_ACTION not in declared
        else:
            assert not (declared & NEW_ACTIONS), name
    assert {"chrome_job_pause", "chrome_job_resume", "chrome_job_stop"} == set(
        document["presentation_contracts"]["recurring_work_088"]["actions"])
    assert set(document["presentation_contracts"]["saved_results_088"]["actions"]) == {"load_chat"}


def test_saved_results_fixture_has_no_save_path_and_no_result_text():
    document = manifest()
    document_fixture = fixture(document["presentation_contracts"]["saved_results_088"])
    for mode, frame in document_fixture["frames"].items():
        encoded = json.dumps(frame, ensure_ascii=False)
        assert SAVE_ACTION not in encoded and "Save result" not in encoded
        assert "Exact retained evidence" not in encoded
        downloads = [n for n in nodes(frame["components"]) if n.get("type") == "file_download"]
        assert bool(downloads) is (mode == "detail")
        for item in downloads:
            assert item["url"].startswith("/api/export/")


def test_recurring_fixture_covers_terminal_stop_unknown_allowance_and_every_outcome():
    document = manifest()
    contract = document["presentation_contracts"]["recurring_work_088"]
    document_fixture = fixture(contract)
    encoded = json.dumps(document_fixture["frames"], ensure_ascii=False)
    for label in ("Stop permanently", "Stopped permanently", "No run limit", "3 of 10 runs admitted"):
        assert label in encoded
    badges = {n["label"] for n in nodes(document_fixture["frames"]) if n.get("type") == "badge"}
    assert {"Initial observation", "Unchanged", "Insufficient evidence"} <= badges
    assert set(contract["outcomes"]) == {"initial", "unchanged", "changed", "insufficient_evidence"}
    for item in nodes(document_fixture["frames"]):
        if item.get("action") in contract["actions"]:
            assert set(item["payload"]) == set(contract["actions"][item["action"]])
    stopped = json.dumps(document_fixture["frames"]["stopped"])
    assert "chrome_job_" not in stopped and "Stopped permanently" in stopped


def test_new_088_surfaces_are_not_yet_menu_destinations():
    # ui.md's "Saved results"/"Recurring work" destinations ride menu_model.py (outside
    # these builders); until that lands no client is offered an unregistered entry.
    model = menu_model_dict(work_enabled=True, export_enabled=True)
    encoded = json.dumps(model)
    assert "saved_results" not in encoded and "recurring" not in encoded
