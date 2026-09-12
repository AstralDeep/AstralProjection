"""Actual watch descriptor/ROTE outputs also consumed by SwiftCore CLI tests."""
import copy
import json
from pathlib import Path

import pytest

from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = json.loads((ROOT / "contracts/fixtures/workspace_088/watch_history.json").read_text())


@pytest.mark.parametrize("state", ["loading", "populated", "empty"])
def test_actual_rote_matches_watch_decoded_frames(state):
    source = FIXTURE["source_components"][state]
    before = copy.deepcopy(source)
    frame = FIXTURE["frames"][state]
    adapted = ComponentAdapter.adapt(source, DeviceProfile.from_dict(FIXTURE["device"]))
    assert frame == {"type": "ui_render", "target": "history", "components": adapted}
    assert source == before
    assert all(key not in frame for key in ("chat_id", "request_generation", "frame_sequence"))


def test_history_enrichment_survives_real_watch_bounds():
    component, = FIXTURE["frames"]["populated"]["components"]
    assert component["type"] == "chat_history"
    assert component["title"] == "Recent chats"
    assert len(component["items"]) == 4
    assert [item["chat_id"] for item in component["items"]] == [f"watch-fixture-{i}" for i in range(4)]
    assert component["items"][0]["saved"] is True
    assert component["items"][0]["time"] == "just now"
    assert component["items"][0]["icon"] == "🌤️"
    assert all("preview" not in item for item in component["items"])
    loading = FIXTURE["frames"]["loading"]["components"]
    assert loading[1]["type"] == "skeleton" and loading[1]["count"] == 3
    assert FIXTURE["frames"]["empty"]["components"][0]["items"] == []


@pytest.mark.parametrize("state,required", [("loading", "skeleton"), ("populated", "chat_history")])
def test_old_advertisement_reproduces_loss_of_canonical_surface(state, required):
    descriptor = {**FIXTURE["device"], "supported_types": [
        kind for kind in FIXTURE["device"]["supported_types"] if kind not in {"chat_history", "skeleton"}]}
    adapted = ComponentAdapter.adapt(FIXTURE["source_components"][state], DeviceProfile.from_dict(descriptor))
    assert all(component["type"] != required for component in adapted)
    assert any(component["type"] == "text" for component in adapted)


def test_watch_passive_details_survive_adaptation_without_invented_actions():
    components = [
        {"type": "keyvalue", "items": [{"label": "Status", "value": "Ready", "hint": "After review"}]},
        {"type": "list", "variant": "detailed", "items": [
            {"title": "Evidence", "subtitle": "Today", "description": "Both details remain visible"}]},
    ]
    adapted = ComponentAdapter.adapt(components, DeviceProfile.from_dict(FIXTURE["device"]))
    assert adapted == components
