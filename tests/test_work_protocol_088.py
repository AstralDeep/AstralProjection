"""Canonical Work fixture binds additive negotiated read-only presentation."""
import json
from pathlib import Path

from rote.work import validate_work_components, validate_work_navigation
from webrender.chrome.menu_model import menu_model_dict, project_watch_menu_model

ROOT = Path(__file__).resolve().parents[1]


def test_work_contract_matches_actual_shared_frames_and_navigation():
    manifest = json.loads((ROOT / 'contracts/ui_protocol.json').read_text())
    contract = manifest['presentation_contracts']['work_read_088']
    fixture = json.loads((ROOT / contract['fixture']).read_text())
    expected = set(contract['native_response']['exact_fields'])
    assert contract['client_capability'] == 'work_read_v1'
    for frame in fixture['frames'].values():
        assert set(frame) == expected
        assert frame['surface_key'] == contract['surface_key'] == 'work'
        assert frame['region'] == 'modal' and frame['mode'] == 'replace'
        assert frame['admin_only'] is False
        assert validate_work_components(frame['components']) == frame['components']
    model = menu_model_dict(work_enabled=True)
    projected = project_watch_menu_model(model)
    assert projected['menu'] == [] and projected['signout'] == {}
    assert projected['topbar'] == [item for item in model['topbar'] if item['key'] == 'work']
    assert len(projected['topbar']) == 1
    validate_work_navigation({'surface': 'work', 'params': {'mode': 'list'}})
