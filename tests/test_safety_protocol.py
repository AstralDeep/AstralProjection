"""Verifies the shared safety vocabulary and primary watch controls.
The host owns authority while generic renderers preserve offered actions.
"""

import json
from pathlib import Path

import pytest

from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / "contracts/ui_protocol.json").read_text(encoding="utf-8"))
CONTRACT = MANIFEST["presentation_contracts"]["owner_safety"]
FIXTURE = json.loads((ROOT / CONTRACT["fixture"]).read_text(encoding="utf-8"))


def test_safety_contract_has_closed_actions_and_all_client_dispositions():
    actions = {button["action"] for button in FIXTURE["buttons"]}
    assert actions == set(CONTRACT["actions"])
    assert actions <= set(MANIFEST["accept_actions"])
    assert set(CONTRACT["dispositions"]) == {"browser", "windows", "android", "macos", "ios", "watchos"}
    assert FIXTURE["states"] == ["running", "stopped", "partial", "unreachable", "unknown"]
    for button in FIXTURE["buttons"]:
        assert set(button["payload"]) == set(CONTRACT["actions"][button["action"]])
        assert button["payload"]["surface"] == "safety"
        assert not button["disabled"] and not button["local"]


@pytest.mark.parametrize("state", ["running", "engaged"])
def test_watch_retains_both_explicit_controls(state):
    profile = DeviceProfile.from_dict({"device_type": "watch"})
    controls = FIXTURE[state]
    assert len(controls) == 2
    adapted = ComponentAdapter.adapt(controls, profile)
    assert [row["action"] for row in adapted] == [row["action"] for row in controls]
    assert all(row["payload"] == original["payload"] for row, original in zip(adapted, controls))
