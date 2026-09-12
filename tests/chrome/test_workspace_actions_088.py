"""Workspace topbar controls share one flag-resolved inventory across clients."""
import json
from html.parser import HTMLParser

import pytest

from astralprojection.resources import protocol_manifest_path
from webrender.chrome.menu_model import SurfaceRef, TopBarControl, build_menu_model
from webrender.chrome.topbar import render_topbar


class Buttons(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.buttons = []
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        if tag == "button":
            self.buttons.append(dict(attrs))


@pytest.mark.parametrize("export,share", [(False, False), (True, False), (False, True), (True, True)])
@pytest.mark.parametrize("roles", [None, ["user"], ["user", "admin"]])
def test_flag_resolved_inventory_and_web_hooks_have_identical_order(export, share, roles):
    options = {"export_enabled": export, "share_enabled": share, "pulse_enabled": True}
    model = build_menu_model(roles, **options).to_dict()
    actions = [item for item in model["topbar"] if item["kind"] == "workspace_action"]
    assert [item["key"] for item in model["topbar"]] == [
        "brand", "status", *(["export"] if export else []), *(["share"] if share else []),
        "pulse", "timeline", "settings",
    ]
    expected = [
        {"key": key, "kind": "workspace_action", "label": label, "icon": icon,
         "operation": operation, "context": "live_canvas"}
        for enabled, key, label, icon, operation in [
            (export, "export", "Export page", "download", "export_canvas"),
            (share, "share", "Share page", "share", "share_canvas"),
        ] if enabled
    ]
    assert model["version"] == 2 and actions == expected
    buttons = Buttons(render_topbar(roles, **options)).buttons
    by_id = {button["id"]: button for button in buttons if "id" in button}
    ids = list(by_id)
    for enabled, key, hook in [(export, "export", "astral-export-canvas"),
                               (share, "share", "astral-share-btn")]:
        identity = f"astral-{key}-page-btn"
        assert (identity in by_id) is enabled
        if enabled:
            button = by_id[identity]
            assert "hidden" in button and button["type"] == "button"
            assert hook in button["class"].split()
            assert "astral-page-action" in button["class"].split()
            assert button["aria-label"] == f"{key.title()} page"
            assert "data-ui-action" not in button
            assert ids.index("astral-chats-btn") < ids.index(identity) < ids.index("astral-pulse-btn")
    if export and share:
        assert ids.index("astral-export-page-btn") < ids.index("astral-share-page-btn")
    if share:
        assert by_id["astral-share-page-btn"]["data-share-scope"] == "canvas"


def test_host_flags_are_required_and_do_not_read_environment(monkeypatch):
    monkeypatch.setenv("FF_ARTIFACT_EXPORT", "true")
    monkeypatch.setenv("FF_ARTIFACT_SHARING", "true")
    assert not any(item.kind == "workspace_action" for item in build_menu_model().topbar)
    html = render_topbar()
    assert "astral-export-page-btn" not in html and "astral-share-page-btn" not in html


@pytest.mark.parametrize("changes", [
    {"operation": "delete_canvas"}, {"operation": None}, {"operation": {}},
    {"context": "any_canvas"}, {"context": None},
    {"action": SurfaceRef("workspace_timeline")},
    {"kind": "action"}, {"kind": "menu"},
    {"key": ""}, {"label": None}, {"label": 1}, {"label": "  "}, {"icon": None},
])
def test_workspace_descriptor_refuses_unknown_or_ambiguous_operation(changes):
    fields = {"key": "export", "label": "Export page", "icon": "download",
              "kind": "workspace_action", "operation": "export_canvas",
              "context": "live_canvas", **changes}
    with pytest.raises(ValueError, match="workspace"):
        TopBarControl(**fields)


def test_protocol_declares_the_same_closed_descriptor_vocabulary():
    contract = json.loads(protocol_manifest_path().read_text())["presentation_contracts"]["chrome_menu"]
    assert contract["version"] == 2
    assert contract["workspace_action"]["operations"] == ["export_canvas", "share_canvas"]
    assert contract["workspace_action"]["contexts"] == ["live_canvas"]
    descriptor = next(item for item in build_menu_model(export_enabled=True).to_dict()["topbar"]
                      if item["kind"] == "workspace_action")
    assert set(descriptor) == set(contract["workspace_action"]["exact_fields"])
    assert contract["unknown_kind"] == contract["invalid_workspace_action"] == "ignore_control"
