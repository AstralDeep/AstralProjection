"""Tests for backend/webrender/chrome/menu_model.py: role-filtered inventory and native
serialization contracts.
"""

from webrender.chrome.menu_model import (
    MODEL_VERSION,
    build_menu_model,
    menu_model_dict,
    project_watch_menu_model,
)


def test_default_and_feature_enabled_inventory_is_role_filtered() -> None:
    default = build_menu_model(None)
    assert [control.key for control in default.topbar] == [
        "brand",
        "status",
        "timeline",
        "settings",
    ]
    assert [group.key for group in default.menu] == ["account", "help"]

    enabled = build_menu_model(
        ["user", "admin"],
        pulse_enabled=True,
        byo_enabled=True,
        remote_enabled=True,
    )
    assert [control.key for control in enabled.topbar] == [
        "brand",
        "status",
        "pulse",
        "timeline",
        "settings",
    ]
    assert [group.key for group in enabled.menu] == ["account", "help", "admin"]
    account_keys = [item.key for item in enabled.menu[0].items]
    assert account_keys[-2:] == ["my-agents", "remote-machines"]


def test_native_serialization_omits_web_only_tour_and_admin_group() -> None:
    payload = menu_model_dict(
        ["admin"],
        include_admin=False,
        include_tour=False,
        byo_enabled=True,
        remote_enabled=True,
    )
    assert payload["version"] == MODEL_VERSION == 2
    assert set(payload) == {"version", "topbar", "menu", "signout"}
    assert [group["key"] for group in payload["menu"]] == ["account", "help"]
    assert [item["key"] for item in payload["menu"][1]["items"]] == ["guide"]
    assert payload["signout"] == {
        "key": "signout",
        "label": "Sign out",
        "style": "danger",
        "action": "logout",
    }
    timeline = next(item for item in payload["topbar"] if item["key"] == "timeline")
    assert timeline == {
        "key": "timeline",
        "kind": "action",
        "label": "Workspace timeline",
        "icon": "history",
        "action": {"surface": "workspace_timeline", "params": {}},
    }
    assert payload["topbar"][0] == {"key": "brand", "kind": "brand"}


def test_admin_items_serialize_params_and_authorization_markers() -> None:
    payload = menu_model_dict(["admin"])
    admin = payload["menu"][-1]
    assert admin["admin_only"] is True
    assert admin["items"][0] == {
        "key": "tool-quality",
        "label": "Tool quality",
        "surface": "admin_tools",
        "params": {"tab": "quality"},
        "admin_only": True,
    }


def test_connections_item_is_absent_until_the_host_enables_it() -> None:
    default = build_menu_model(["user"])
    assert "connections" not in [item.key for group in default.menu for item in group.items]

    enabled = build_menu_model(["user"], connections_enabled=True)
    account = enabled.menu[0]
    assert account.key == "account"
    item = next(entry for entry in account.items if entry.key == "connections")
    assert item.to_dict() == {
        "key": "connections",
        "label": "Connections",
        "surface": "connections",
        "params": {},
        "admin_only": False,
    }
    assert [control.key for control in enabled.topbar] == [
        control.key for control in default.topbar
    ]


def test_connections_serializes_for_native_clients_and_never_reaches_the_watch() -> None:
    payload = menu_model_dict(
        ["user"], connections_enabled=True, notes_enabled=True, work_enabled=True,
        include_admin=False, include_tour=False,
    )
    keys = [item["key"] for group in payload["menu"] for item in group["items"]]
    assert keys.count("connections") == 1
    watch = project_watch_menu_model(payload)
    assert [item["key"] for item in watch["topbar"]] == ["work", "guidance"]
    assert watch["menu"] == [] and watch["signout"] == {}


def test_connections_does_not_disturb_the_other_flagged_account_items() -> None:
    both = build_menu_model(
        ["user"], byo_enabled=True, remote_enabled=True, computer_enabled=True,
        connections_enabled=True,
    )
    assert [item.key for item in both.menu[0].items][-4:] == [
        "my-agents", "remote-machines", "my-computers", "connections",
    ]
    without = build_menu_model(["user"], byo_enabled=True, remote_enabled=True,
                               computer_enabled=True)
    assert [item.key for item in without.menu[0].items] == [
        item.key for item in both.menu[0].items if item.key != "connections"
    ]
