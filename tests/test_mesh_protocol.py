"""Binds shared mesh management and joining actions to explicit client dispositions.
The private joining page loads uncached custody code only after removing its one-time
fragment; host-side authority and durable mutation remain outside Projection.
"""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_mesh_actions_separate_host_writes_from_local_key_custody():
    manifest = json.loads((ROOT / "contracts/ui_protocol.json").read_text())
    contract = manifest["presentation_contracts"]["mesh_enrollment"]
    writes = {
        "chrome_mesh_create", "chrome_mesh_confirm", "chrome_mesh_reject",
        "chrome_mesh_rename", "chrome_mesh_revoke", "chrome_mesh_remove_invitation",
    }
    local = {"chrome_mesh_identity", "chrome_mesh_redeem"}
    assert contract["version"] == 1 and contract["surface_key"] == "mesh"
    assert set(contract["actions"]) == writes <= set(manifest["accept_actions"])
    assert set(contract["local_actions"]) == local <= set(manifest["client_local_actions"])
    assert not local & set(manifest["accept_actions"])
    assert set(contract["clients"]) == {"web", "windows", "android", "ios", "macos", "watch"}
    assert "handoff" in contract["clients"]["watch"]
    assert "no private key or grant forwarded" in contract["clients"]["watch"]


def test_enrollment_fragment_is_scrubbed_before_external_assets_and_never_cached():
    template = (ROOT / "backend/webrender/templates/enrollment.html").read_text()
    assert template.index('history.replaceState(null, "", "/enroll")') < template.index('src="/static/mesh-custody.js')
    assert 'nonce="%%ASTRAL_NONCE%%"' in template
    assert 'autocomplete="off"' in template and 'maxlength="4096"' in template
    assert 'role="status" aria-live="polite"' in template
    from scripts.build_offline_assets import PUBLIC_ASSETS

    assert not any("mesh-custody" in str(path) or "mesh-enrollment" in str(path) for path in PUBLIC_ASSETS)
