"""Tests binding the per-client disposition matrix to the code that actually decides
delivery (backend/rote/adapter.py, backend/webrender/chrome/menu_model.py): refuses
any row with an unresolvable surface, action, or capability.
"""

import json
from copy import deepcopy
from pathlib import Path

import pytest

from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile, DeviceType
from webrender.chrome.menu_model import menu_model_dict, project_watch_menu_model

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / "contracts" / "ui_protocol.json").read_text(encoding="utf-8"))
MATRIX = MANIFEST["presentation_contracts"]["disposition_matrix_088"]

CLIENTS = ["web", "windows", "android", "ios", "macos", "watch", "voice"]
NATIVE_CLIENTS = ("android", "ios", "macos", "watch")
DISPOSITIONS = {"supported", "read_only_handoff", "omitted_by_server", "version_required"}
WINDOWS_SURFACES = {"guidance_notes_088", "guidance_selection_088"}
WINDOWS_WORKSPACE_ACTIONS = {"canvas_export": "export_canvas", "canvas_share": "share_canvas"}


def _fixture(relative):
    return json.loads((ROOT / relative).read_text(encoding="utf-8"))


def _resolve(manifest, path):
    node = manifest
    for part in path.split("."):
        if not isinstance(node, dict) or part not in node:
            raise ValueError("unknown contract_path %s" % path)
        node = node[part]
    if not node:
        raise ValueError("empty contract_path %s" % path)
    return node


def validate(matrix, manifest):
    if matrix.get("version") != 1:
        raise ValueError("disposition_matrix_088 must be version 1")
    if matrix.get("clients") != CLIENTS:
        raise ValueError("closed client list required")
    if set(matrix.get("dispositions") or {}) != DISPOSITIONS:
        raise ValueError("closed disposition vocabulary required")
    profiles = matrix.get("client_profiles") or {}
    if set(profiles) != set(CLIENTS):
        raise ValueError("every client needs a profile")
    bases = set(matrix.get("bases") or {})
    if not bases:
        raise ValueError("bases required")
    family = set(matrix.get("capability_family") or ())
    contracts = manifest["presentation_contracts"]
    actions = set(manifest["accept_actions"])
    operations = set(
        _resolve(manifest, "presentation_contracts.chrome_menu.workspace_action.operations")
    )
    rows = matrix.get("rows") or []
    if not rows:
        raise ValueError("rows required")
    seen = set()
    for row in rows:
        destination = row.get("destination")
        if not destination or destination in seen:
            raise ValueError("each destination appears exactly once")
        seen.add(destination)
        contract = contracts.get(row.get("contract"))
        if contract is None or row["contract"] == "disposition_matrix_088":
            raise ValueError("unknown contract for %s" % destination)
        has_action, has_operation = "action" in row, "operation" in row
        if has_action == has_operation:
            raise ValueError("%s needs exactly one of action/operation" % destination)
        if has_action and row["action"] not in actions:
            raise ValueError("unknown action %s" % row["action"])
        if has_operation and row["operation"] not in operations:
            raise ValueError("unknown operation %s" % row["operation"])
        for command in row.get("commands") or ():
            if command not in actions:
                raise ValueError("unknown command %s" % command)
        surface = (row.get("params") or {}).get("surface")
        if surface is not None and contract.get("surface_key") not in (None, surface):
            raise ValueError("%s names a surface its contract does not own" % destination)
        state = row.get("fixture_state")
        if state is not None:
            fixture = contract.get("fixture")
            if not fixture:
                raise ValueError("%s names a state but its contract has no fixture" % destination)
            data = _fixture(fixture)
            if state not in (data.get("frames") or data.get("states") or {}):
                raise ValueError("unknown fixture state %s" % state)
        capability = contract.get("client_capability")
        if capability is not None and capability not in family:
            raise ValueError("capability %s outside the declared family" % capability)
        cells = row.get("clients") or {}
        if set(cells) != set(CLIENTS):
            raise ValueError("%s must name every client" % destination)
        for client, cell in cells.items():
            _validate_cell(manifest, row, client, cell, bases, profiles, capability)
    return matrix


def _validate_cell(manifest, row, client, cell, bases, profiles, capability):
    destination = row["destination"]
    where = "%s/%s" % (destination, client)
    disposition, basis = cell.get("disposition"), cell.get("basis")
    if disposition not in DISPOSITIONS:
        raise ValueError("unknown disposition at %s" % where)
    if basis not in bases:
        raise ValueError("unknown basis at %s" % where)
    if (disposition == "read_only_handoff") != bool(cell.get("handoff")):
        raise ValueError("read_only_handoff needs a declared handoff at %s" % where)
    if row.get("effect_review") and disposition == "read_only_handoff":
        raise ValueError("an effect review is never partially delivered at %s" % where)
    if "contract_path" in cell:
        _resolve(manifest, cell["contract_path"])
    elif basis == "contract_declared":
        raise ValueError("contract_declared needs a contract_path at %s" % where)
    advertised = set(profiles[client].get("advertised_088_capabilities") or ())
    if client == "web":
        if disposition != "supported" or basis != "web_render_channel":
            raise ValueError("web is the web-first channel at %s" % where)
    elif client == "windows":
        if row["contract"] == "work_read_088":
            if (disposition != "read_only_handoff" or basis != "owner_exclusion_T059"
                    or capability not in advertised):
                raise ValueError("Windows retains its declared work read handoff at %s" % where)
        elif row["contract"] in WINDOWS_SURFACES:
            if (disposition != "supported" or basis != "advertised_capability"
                    or capability not in advertised):
                raise ValueError("Windows requires its qualified surface capability at %s" % where)
        elif row["contract"] == "chrome_menu" and destination in WINDOWS_WORKSPACE_ACTIONS:
            if (disposition != "supported" or basis != "shared_chrome_menu"
                    or row.get("operation") != WINDOWS_WORKSPACE_ACTIONS[destination]):
                raise ValueError("Windows requires its qualified workspace action at %s" % where)
        elif disposition != "omitted_by_server":
            raise ValueError("Windows cannot gain an unqualified destination at %s" % where)
    elif client == "voice":
        if disposition not in {"read_only_handoff", "omitted_by_server"}:
            raise ValueError("voice cannot complete a command surface at %s" % where)
        if basis != "rote_voice_profile":
            raise ValueError("voice dispositions come from the ROTE profile at %s" % where)
    elif capability is None:
        if disposition == "version_required":
            raise ValueError("%s has no capability to require" % where)
    elif capability in advertised:
        if disposition not in {"supported", "read_only_handoff"}:
            raise ValueError("%s advertises %s already" % (where, capability))
    elif disposition not in {"version_required", "omitted_by_server"}:
        raise ValueError("%s does not advertise %s" % (where, capability))


def rows_for(contract):
    return [row for row in MATRIX["rows"] if row["contract"] == contract]


def profile_for(client):
    return DeviceProfile.from_dict(
        {"device_type": MATRIX["client_profiles"][client]["device_type"]}
    )


def components_for(row):
    contract = MANIFEST["presentation_contracts"][row["contract"]]
    data = _fixture(contract["fixture"])
    state = row["fixture_state"]
    frame = (data.get("frames") or {}).get(state)
    return frame["components"] if frame else data["components"]


def buttons(nodes, found=None):
    found = [] if found is None else found
    for node in nodes:
        if not isinstance(node, dict):
            continue
        if node.get("type") in ("button", "param_picker"):
            found.append(node)
        for key in ("content", "children"):
            if isinstance(node.get(key), list):
                buttons(node[key], found)
    return found


def texts(nodes, found=None):
    found = [] if found is None else found
    for node in nodes:
        if not isinstance(node, dict):
            continue
        for key in ("content", "children"):
            if isinstance(node.get(key), list):
                texts(node[key], found)
        if node.get("type") == "text" and isinstance(node.get("content"), str):
            found.append(node["content"])
    return found


def test_the_committed_matrix_is_a_closed_resolvable_web_first_table():
    validate(deepcopy(MATRIX), MANIFEST)
    destinations = [row["destination"] for row in MATRIX["rows"]]
    assert len(destinations) == len(set(destinations))
    covered = {row["contract"] for row in MATRIX["rows"]}
    assert covered == {
        "work_read_088", "work_save_088", "guidance_notes_088", "guidance_skills_088",
        "guidance_agents_088", "guidance_selection_088", "recurring_work_088",
        "saved_results_088", "connections_088", "chrome_menu", "workspace_088",
    }
    gated = {
        name for name, contract in MANIFEST["presentation_contracts"].items()
        if isinstance(contract, dict) and contract.get("client_capability")
    }
    assert gated <= covered, sorted(gated - covered)
    assert set(MATRIX["capability_family"]) == {
        MANIFEST["presentation_contracts"][name]["client_capability"] for name in gated
    }
    assert {row["destination"] for row in rows_for("work_read_088")} == {
        "work_list", "work_detail", "work_result"}
    assert {row["destination"] for row in rows_for("guidance_notes_088")} == {
        "guidance_notes_list", "guidance_notes_new", "guidance_notes_edit",
        "guidance_notes_forget"}
    assert {row["destination"] for row in rows_for("chrome_menu")} == {
        "canvas_export", "canvas_share"}
    assert [row["destination"] for row in MATRIX["rows"] if row["effect_review"]] == [
        "work_save_review", "guidance_notes_forget", "guidance_skills_delete",
        "guidance_agents_activate", "guidance_agents_archive", "guidance_agents_delete",
        "connections_issue", "connections_revoke"]


def _mutate(change):
    matrix = deepcopy(MATRIX)
    change(matrix)
    return matrix


def _first(matrix, destination):
    return next(row for row in matrix["rows"] if row["destination"] == destination)


REFUSALS = {
    "unknown_surface": lambda m: _first(m, "work_list")["params"].update(surface="nowhere"),
    "unknown_action": lambda m: _first(m, "work_list").update(action="chrome_teleport"),
    "unknown_command": lambda m: _first(m, "guidance_notes_new").update(
        commands=["chrome_note_save", "chrome_note_teleport"]),
    "unknown_contract": lambda m: _first(m, "work_list").update(contract="work_dreams_088"),
    "self_referential_contract": lambda m: _first(m, "work_list").update(
        contract="disposition_matrix_088"),
    "unknown_fixture_state": lambda m: _first(m, "work_list").update(fixture_state="phantom"),
    "unknown_operation": lambda m: _first(m, "canvas_export").update(operation="delete_canvas"),
    "action_and_operation": lambda m: _first(m, "canvas_export").update(action="chrome_open"),
    "unknown_disposition": lambda m: _first(m, "work_list")["clients"]["ios"].update(
        disposition="partially_supported"),
    "unknown_basis": lambda m: _first(m, "work_list")["clients"]["ios"].update(basis="vibes"),
    "unknown_client": lambda m: _first(m, "work_list")["clients"].pop("watch"),
    "extra_client": lambda m: _first(m, "work_list")["clients"].update(fridge={}),
    "handoff_without_disposition": lambda m: _first(m, "work_list")["clients"]["ios"].update(
        handoff="just go somewhere else"),
    "handoff_missing": lambda m: _first(m, "work_list")["clients"]["windows"].pop("handoff"),
    "partial_effect_review": lambda m: _first(m, "work_save_review")["clients"]["ios"].update(
        disposition="read_only_handoff", handoff="finish it on web"),
    "unresolvable_contract_path": lambda m: _first(m, "guidance_notes_list")["clients"][
        "windows"].update(contract_path="presentation_contracts.guidance_notes_088.rumour"),
    "contract_declared_without_path": lambda m: _first(m, "workspace_start_welcome")["clients"][
        "windows"].pop("contract_path"),
    "web_not_supported": lambda m: _first(m, "work_list")["clients"]["web"].update(
        disposition="version_required", basis="missing_capability"),
    "windows_redesigned": lambda m: _first(m, "work_list")["clients"]["windows"].update(
        disposition="supported", basis="advertised_capability", handoff=None),
    "windows_work_write": lambda m: _first(m, "work_save_review")["clients"]["windows"].update(
        disposition="supported", basis="advertised_capability"),
    "windows_notes_capability_missing": lambda m: m["client_profiles"]["windows"][
        "advertised_088_capabilities"].remove("guidance_notes_v1"),
    "windows_selection_capability_missing": lambda m: m["client_profiles"]["windows"][
        "advertised_088_capabilities"].remove("guidance_selection_v1"),
    "windows_notes_omitted": lambda m: _first(m, "guidance_notes_list")["clients"][
        "windows"].update(disposition="omitted_by_server"),
    "windows_workspace_operation_mismatch": lambda m: _first(m, "canvas_export").update(
        operation="share_canvas"),
    "windows_workspace_wrong_basis": lambda m: _first(m, "canvas_share")["clients"][
        "windows"].update(basis="owner_exclusion_T059"),
    "voice_supported": lambda m: _first(m, "guidance_notes_new")["clients"]["voice"].update(
        disposition="supported"),
    "capability_already_advertised": lambda m: _first(m, "work_detail")["clients"][
        "android"].update(disposition="version_required", basis="missing_capability"),
    "capability_not_advertised": lambda m: _first(m, "guidance_skills_new")["clients"][
        "android"].update(disposition="supported", basis="advertised_capability"),
    "version_required_without_capability": lambda m: _first(m, "canvas_export")["clients"][
        "android"].update(disposition="version_required", basis="missing_capability"),
    "partial_credential_review": lambda m: _first(m, "connections_revoke")["clients"][
        "android"].update(disposition="read_only_handoff", handoff="revoke it on web"),
    "duplicate_destination": lambda m: m["rows"].append(deepcopy(m["rows"][0])),
    "open_client_list": lambda m: m["clients"].append("fridge"),
    "open_disposition_vocabulary": lambda m: m["dispositions"].update(maybe="sometimes"),
}


@pytest.mark.parametrize("name", sorted(REFUSALS))
def test_every_drifting_or_unknown_row_is_refused(name):
    with pytest.raises(ValueError):
        validate(_mutate(REFUSALS[name]), MANIFEST)


@pytest.mark.parametrize("client", CLIENTS)
def test_declared_capabilities_are_the_ones_each_client_actually_advertises(client):
    profile = MATRIX["client_profiles"][client]
    source = (ROOT / profile["registration_source"]).read_text(encoding="utf-8")
    family = MATRIX["capability_family"]
    present = sorted(name for name in family if '"%s"' % name in source)
    assert present == sorted(profile["advertised_088_capabilities"]), profile[
        "registration_source"]
    assert DeviceType(profile["device_type"])


def test_the_voice_row_is_the_rote_profile_not_a_registration():
    voice = DeviceProfile.from_dict({"device_type": "voice"})
    assert voice.supports_interactivity is False
    assert MATRIX["client_profiles"]["voice"]["advertised_088_capabilities"] == []


@pytest.mark.parametrize("destination", ["work_list", "work_detail", "work_result"])
def test_work_reads_adapt_exactly_as_each_row_declares(destination):
    row = _first(MATRIX, destination)
    raw = components_for(row)
    assert buttons(raw), destination
    for client, cell in row["clients"].items():
        if client == "web":
            continue
        adapted = ComponentAdapter.adapt_work_surface(raw, profile_for(client))
        if cell["disposition"] == "supported":
            assert adapted == raw, client
        else:
            assert cell["disposition"] == "read_only_handoff"
            if client == "windows":
                assert adapted == raw
                assert "T059" in cell["handoff"]
            else:
                assert client == "voice"
                assert adapted != raw and not buttons(adapted)
                assert texts(adapted) == texts(raw)


@pytest.mark.parametrize("destination", [
    "guidance_notes_list", "guidance_notes_new", "guidance_notes_edit", "guidance_notes_forget"])
def test_private_notes_adapt_exactly_as_each_row_declares(destination):
    row = _first(MATRIX, destination)
    contract = MANIFEST["presentation_contracts"]["guidance_notes_088"]
    data = _fixture(contract["fixture"])
    state = data["states"][row["fixture_state"]]
    for client, cell in row["clients"].items():
        if client == "web":
            continue
        if cell["disposition"] == "supported":
            adapted = ComponentAdapter.adapt_guidance_surface(state, profile_for(client))
            assert adapted == data["frames"][row["fixture_state"]]["components"], client
        else:
            assert cell["disposition"] == "omitted_by_server"
            if client == "voice":
                with pytest.raises(ValueError, match="guidance_surface_unavailable"):
                    ComponentAdapter.adapt_guidance_surface(state, profile_for(client))
            else:
                assert client == "windows" and cell["basis"] == "contract_declared"
                assert "Windows" in _resolve(MANIFEST, cell["contract_path"])


@pytest.mark.parametrize("destination", sorted(
    row["destination"] for row in MATRIX["rows"] if "fixture_state" in row))
def test_the_voice_profile_leaves_no_action_on_any_destination(destination):
    row = _first(MATRIX, destination)
    raw = components_for(row)
    adapted = ComponentAdapter.adapt(raw, profile_for("voice"))
    assert not buttons(adapted), destination
    assert row["clients"]["voice"]["disposition"] in {"read_only_handoff", "omitted_by_server"}


def test_the_wrist_projection_pins_every_watch_row():
    model = menu_model_dict(
        work_enabled=True, notes_enabled=True, export_enabled=True, share_enabled=True)
    projected = project_watch_menu_model(model)
    keys = [control["key"] for control in projected["topbar"]]
    assert keys == ["work", "guidance"]
    assert projected["menu"] == [] and projected["signout"] == {}
    assert not project_watch_menu_model(menu_model_dict())["topbar"]

    for row in rows_for("work_read_088") + rows_for("guidance_notes_088"):
        assert row["clients"]["watch"]["disposition"] == "supported", row["destination"]
    for row in rows_for("chrome_menu"):
        cell = row["clients"]["watch"]
        assert cell["disposition"] == "omitted_by_server"
        assert cell["basis"] == "watch_menu_projection"
        assert _resolve(MANIFEST, cell["contract_path"]) == "omitted_by_server"
        assert row["operation"] not in [
            control.get("operation") for control in projected["topbar"]]
    for row in rows_for("work_save_088"):
        cell = row["clients"]["watch"]
        assert cell["disposition"] == "omitted_by_server"
        assert "wrist never advertises it" in _resolve(MANIFEST, cell["contract_path"])


def test_windows_supports_only_qualified_surfaces_and_workspace_actions():
    supported = {
        "guidance_notes_list", "guidance_notes_new", "guidance_notes_edit",
        "guidance_notes_forget", "guidance_selection_form", "canvas_export", "canvas_share",
    }
    handoffs = {"work_list", "work_detail", "work_result"}
    for row in MATRIX["rows"]:
        cell = row["clients"]["windows"]
        if row["destination"] in supported:
            assert cell["disposition"] == "supported"
        elif row["destination"] in handoffs:
            assert cell["disposition"] == "read_only_handoff"
        else:
            assert cell["disposition"] == "omitted_by_server"
    legacy = _resolve(MANIFEST, "presentation_contracts.workspace_088.legacy_layout_targets")
    assert legacy == ["windows"]
    assert _first(MATRIX, "workspace_start_welcome")["clients"]["windows"][
        "contract_path"] == "presentation_contracts.workspace_088.legacy_layout_targets"


def test_the_matrix_adds_no_vocabulary_and_retains_the_old_capabilities():
    encoded = json.dumps(MATRIX)
    for name in MANIFEST["component_types"]:
        assert '"type": "%s"' % name not in encoded
    assert MATRIX["vocabulary"] == (
        "no new push type, component type, accept_action or client_local_action")
    for contract in ("component_chrome", "canvas_export", "chrome_menu", "workspace_088"):
        assert contract in MANIFEST["presentation_contracts"]
    assert len(MANIFEST["accept_actions"]) == len(set(MANIFEST["accept_actions"]))
    referenced = {row.get("action") for row in MATRIX["rows"]} - {None}
    referenced |= {c for row in MATRIX["rows"] for c in row.get("commands") or ()}
    assert referenced <= set(MANIFEST["accept_actions"])
