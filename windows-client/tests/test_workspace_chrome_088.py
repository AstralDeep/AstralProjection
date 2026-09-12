"""Legacy Windows ignores the new closed workspace topbar kind safely."""
from astral_client.rest import parse_chrome_menu
from webrender.chrome.menu_model import menu_model_dict


def test_workspace_and_unknown_topbar_kinds_do_not_become_surface_actions():
    model = menu_model_dict(export_enabled=True, share_enabled=True, include_admin=False)
    model["topbar"].extend([
        {"kind": "workspace_action", "operation": "unknown", "action": {"surface": "admin_tools"}},
        {"kind": "future", "action": {"surface": "admin_tools"}},
        None,
    ])
    parsed = parse_chrome_menu(model)
    assert parsed["topbar_actions"] == [{
        "label": "Workspace timeline", "surface": "workspace_timeline", "icon": "history"}]
    assert parsed["sections"] and parsed["signout"]["action"] == "logout"
