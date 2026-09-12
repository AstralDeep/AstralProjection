"""Cross-client component actions preserve host flags and original identity."""
from __future__ import annotations

import copy
import itertools
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from webrender.chrome.component_model import (
    build_component_chrome,
    canonical_components_by_id,
    component_action_descriptors,
    component_versions,
    renderer_component_actions,
    stamp_canvas_component_chrome,
    stamp_component_chrome,
)
from webrender.renderer import render_component_fragment, render_workspace
from rote.rote import ROTE

FIXTURES = Path(__file__).resolve().parents[2] / "contracts/fixtures/workspace_088"
CORPUS = json.loads((FIXTURES / "component_chrome.json").read_text())
LEGACY = json.loads((FIXTURES / "component_chrome_web_legacy.json").read_text())


def profile(device="browser", interactive=True):
    return SimpleNamespace(device_type=SimpleNamespace(value=device),
                           supports_interactivity=interactive)


def component(**changes):
    return {"type": "table", "component_id": "wc_table", "headers": ["a"],
            "rows": [["1"]], **changes}


def kinds(value):
    return [action["kind"] for action in value["actions"]]


@pytest.fixture(autouse=True)
def flags(monkeypatch):
    monkeypatch.setenv("FF_COMPONENT_REFINE", "true")
    monkeypatch.setenv("FF_ARTIFACT_EXPORT", "true")
    monkeypatch.setenv("FF_ARTIFACT_SHARING", "true")


@pytest.mark.parametrize("case", CORPUS["actions"], ids=lambda case: case["name"])
def test_shared_action_corpus(case):
    assert [entry["kind"] for entry in component_action_descriptors(case["metadata"])] == case["expected_kinds"]


@pytest.mark.parametrize("case", CORPUS["versions"], ids=lambda case: case["name"])
def test_shared_version_corpus(case):
    assert component_versions({"versions": case["versions"]}) == case["expected"]


@pytest.mark.parametrize("value", [None, {}, "invalid", [None, {"version_no": float("inf")}],
                                  [{"version_no": float("nan")}], [{"version_no": -1}]])
def test_invalid_version_values_are_omitted(value):
    assert component_versions({"versions": value}) == []


def test_null_version_text_is_missing_equivalent():
    assert component_versions({"versions": [{"version_no": 1, "reason": None,
                                              "created_at": None, "title": None}]}) == [
        {"version_no": 1, "reason": "", "created_at": "", "title": ""}]


def test_descriptor_text_is_nonempty_without_stripping_server_labels():
    descriptor = {"kind": "refine", "label": " ", "icon": " ", "title": " ", "context": "live_canvas"}
    assert component_action_descriptors({"version": 1, "actions": [descriptor]}) == [descriptor]


@pytest.mark.parametrize("refine,export,share", list(itertools.product([False, True], repeat=3)))
def test_one_host_inventory_for_all_flag_combinations(refine, export, share):
    enabled = {"component_refine": refine, "artifact_export": export, "artifact_sharing": share}
    expected = (["refine", "history"] if refine else []) + (["csv"] if export else []) + (["share"] if share else [])
    assert kinds(build_component_chrome(component(), profile(), enabled=enabled.__getitem__)) == expected
    assert kinds(build_component_chrome(component(type="chart"), profile(), enabled=enabled.__getitem__)) == [kind for kind in expected if kind != "csv"]


@pytest.mark.parametrize("changes", [{"component_id": None}, {"component_id": 7},
    {"component_id": ""}, {"component_id": "dg_notice"}, {"component_id": "ly_layout"},
    {"component_id": "wel_hello"}, {"type": "divider"}, {"type": "skeleton"}])
def test_ephemeral_or_unidentified_components_have_no_actions(changes):
    assert kinds(build_component_chrome(component(**changes), profile())) == []


@pytest.mark.parametrize("receiver", [None, profile("watch"), profile("voice"), profile(interactive=False)])
def test_static_and_restricted_receivers_have_no_actions(receiver):
    assert kinds(build_component_chrome(component(), receiver)) == []


def test_flag_failure_is_closed_without_suppressing_other_actions():
    def enabled(name):
        if name == "component_refine":
            raise RuntimeError("unavailable")
        return name == "artifact_export"
    assert kinds(build_component_chrome(component(), profile(), enabled=enabled)) == ["csv"]
    assert kinds(build_component_chrome(component(), profile(), enabled=lambda _: "true")) == []


def test_environment_defaults_and_truthy_values(monkeypatch):
    for name in ("FF_COMPONENT_REFINE", "FF_ARTIFACT_EXPORT", "FF_ARTIFACT_SHARING"):
        monkeypatch.delenv(name)
    assert kinds(build_component_chrome(component(), profile())) == ["refine", "history", "csv"]
    monkeypatch.setenv("FF_COMPONENT_REFINE", "false")
    monkeypatch.setenv("FF_ARTIFACT_EXPORT", "0")
    monkeypatch.setenv("FF_ARTIFACT_SHARING", "YES")
    assert kinds(build_component_chrome(component(), profile())) == ["share"]


def test_adaptation_cannot_promote_or_lose_canonical_table_export():
    original = component(versions=[{"version_no": 1, "body": "secret archive"}])
    reduced = component(type="text", content="one row", component_chrome={"version": 99})
    original_before, reduced_before = copy.deepcopy(original), copy.deepcopy(reduced)
    stamped = stamp_component_chrome(original, reduced, profile("android"))
    assert kinds(stamped["component_chrome"]) == ["refine", "history", "csv", "share"]
    assert "body" not in stamped["versions"][0]
    assert original == original_before and reduced == reduced_before
    rendered = render_component_fragment(stamped, profile(), canonical=original)
    assert "astral-export-csv" in rendered
    promoted = stamp_component_chrome(component(type="chart"), component(), profile())
    assert "csv" not in kinds(promoted["component_chrome"])
    assert "astral-export-csv" not in render_component_fragment(promoted, profile(), canonical=component(type="chart"))


def test_missing_or_mismatched_identity_removes_spoofed_actions_and_versions():
    spoofed = component(component_chrome={"version": 1, "actions": []}, versions=[{"version_no": 1}])
    for original in (None, {}, {"component_id": "someone_else"}, {"id": "wc_table"}):
        stamped = stamp_component_chrome(original, spoofed, profile())
        assert kinds(stamped["component_chrome"]) == []
        assert "versions" not in stamped
    for receiver in (None, profile("watch"), profile("voice")):
        stamped = stamp_component_chrome(spoofed, spoofed, receiver)
        assert "component_chrome" not in stamped and "versions" not in stamped


def test_canvas_correspondence_uses_unambiguous_ids_not_positions():
    originals = [component(component_id="table"), component(type="chart", component_id="chart"),
                 component(component_id="ambiguous"), component(component_id="ambiguous"), None, {}, {"component_id": []}]
    adapted = [component(component_id="chart"), component(type="text", component_id="table"),
               component(component_id="unknown"), component(component_id="ambiguous"),
               {"type": "table", "component_id": []}, None]
    output = stamp_canvas_component_chrome(originals, adapted, profile())
    assert "csv" not in kinds(output[0]["component_chrome"])
    assert "csv" in kinds(output[1]["component_chrome"])
    assert all(kinds(row["component_chrome"]) == [] for row in output[2:5])
    assert output[5] is None
    assert canonical_components_by_id(originals)["ambiguous"] is None
    html = render_workspace(output, profile(), canonical_components=originals)
    assert html.count('class="astral-export-csv') == 1


def test_renderer_metadata_can_only_restrict_current_host_policy(monkeypatch):
    host = component()
    metadata = build_component_chrome(host, profile())
    proposed = component(component_chrome=metadata)
    monkeypatch.setenv("FF_COMPONENT_REFINE", "false")
    monkeypatch.setenv("FF_ARTIFACT_SHARING", "false")
    assert [a["kind"] for a in renderer_component_actions(proposed, profile())] == ["csv"]
    proposed["component_chrome"] = {"version": 999, "actions": metadata["actions"]}
    assert renderer_component_actions(proposed, profile()) == []
    assert renderer_component_actions(component(), profile(), canonical={"component_id": "other"}) == []


def test_protocol_declares_the_shared_corpus_and_fixed_inventory():
    manifest = json.loads((FIXTURES.parents[1] / "ui_protocol.json").read_text())
    contract = manifest["presentation_contracts"]["component_chrome"]
    built = build_component_chrome(component(), profile())
    assert contract["action_order"] == kinds(built)
    assert contract["contexts"] == {row["kind"]: row["context"] for row in built["actions"]}
    assert contract["fixture"] == "contracts/fixtures/workspace_088/component_chrome.json"


@pytest.mark.parametrize("case", LEGACY["cases"])
def test_existing_web_markup_is_byte_identical(case, monkeypatch):
    for name, value in {**LEGACY["fixed_flags"], **case["flags"]}.items():
        monkeypatch.setenv(name, str(value).lower())
    assert render_component_fragment(case["component"], profile()) == case["html"]
    stamped = stamp_component_chrome(case["component"], case["component"], profile())
    assert render_component_fragment(stamped, profile(), canonical=case["component"]) == case["html"]


def test_rote_cached_originals_are_socket_scoped_detached_and_retired():
    rote = ROTE()
    socket, unrelated = object(), object()
    original = [component(rows=[["private result"]])]
    rote.adapt(socket, original)
    cached = rote.get_cached_components(socket)
    assert cached == original
    cached[0]["rows"][0][0] = "receiver mutation"
    assert rote.get_cached_components(socket) == original
    assert rote.get_cached_components(unrelated) is None
    rote.cleanup(socket)
    assert rote.get_cached_components(socket) is None
