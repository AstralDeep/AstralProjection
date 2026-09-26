"""Verify native chrome surfaces use server navigation and responsive dialog geometry.
The cases preserve mandatory controls, correlated loading and keyboard return focus.
"""

import json
from copy import deepcopy
from pathlib import Path

import pytest
from PySide6.QtCore import Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QLabel, QPushButton, QVBoxLayout, QWidget

from astral_client.app import SurfaceDialog
from astral_client.rest import parse_chrome_menu
from astral_client.renderer import RenderContext
from astral_client.surface_widgets import adapt_settings_component


ROOT = Path(__file__).resolve().parents[2]
MODEL = json.loads((ROOT / "contracts/fixtures/console/chrome-console.json").read_text(encoding="utf-8"))
CASES = json.loads((ROOT / "contracts/fixtures/console/rote-console.json").read_text(encoding="utf-8"))["cases"]


@pytest.fixture
def host(qapp):
    parent = QWidget()
    parent._console_model = MODEL["console"]
    layout = QVBoxLayout(parent)
    button = QPushButton("Open settings")
    layout.addWidget(button)
    parent.resize(1440, 900)
    parent.show()
    parent.activateWindow()
    button.setFocus()
    QApplication.processEvents()
    yield parent, button
    parent.close()
    parent.deleteLater()


def presentation(width):
    return next(case["presentation"] for case in CASES if case["viewport"][0] == width)


def test_settings_dialog_centers_and_renders_server_identity_and_navigation(host):
    parent, _ = host
    opened = []
    dialog = SurfaceDialog(parent, emit=lambda *_: None)
    dialog.begin_load("agents", {}, "Agents & permissions")
    dialog.set_navigation(parse_chrome_menu(MODEL), presentation(1440), lambda *args: opened.append(args))
    dialog.show()
    QApplication.processEvents()
    assert dialog.windowFlags() & Qt.WindowType.FramelessWindowHint
    assert dialog.width() == 940
    assert dialog.height() == 774
    assert dialog.pos() == parent.mapToGlobal(parent.rect().center()) - dialog.rect().center()
    labels = [label.text() for label in dialog._navigation_inner.findChildren(QLabel)]
    assert MODEL["console"]["identity"]["name"] in labels
    assert MODEL["menu"][0]["label"].upper() in labels
    controls = dialog._navigation_inner.findChildren(QPushButton)
    controls[-1].click()
    final_item = MODEL["menu"][-1]["items"][-1]
    assert opened == [(final_item["surface"], final_item["label"], final_item["params"])]
    assert dialog._veil.isVisible()
    dialog.close()
    assert dialog._veil.isHidden()


@pytest.mark.parametrize("surface", ["agent_intro", "guidance"])
def test_non_menu_surface_uses_compact_dialog_and_server_subtitle(host, surface):
    parent, _ = host
    dialog = SurfaceDialog(parent, emit=lambda *_: None)
    dialog.begin_load(surface, {"view": "selection"} if surface == "guidance" else {}, "Server title")
    dialog.set_navigation(parse_chrome_menu(MODEL), presentation(1440), lambda *_: None)
    dialog.set_surface("Server title", [
        {"type": "text", "content": "Server subtitle", "console_role": "surface_subtitle"},
        {"type": "text", "content": "Server content"},
    ])
    dialog.show()
    QApplication.processEvents()
    assert dialog.width() == 640
    assert dialog.height() < presentation(1440)["settings_max_height"]
    assert dialog._navigation_panel.isHidden()
    assert dialog._subtitle.text() == "Server subtitle" and not dialog._subtitle.isHidden()
    assert [label.text() for label in dialog._inner.findChildren(QLabel)] == ["Server content"]
    dialog.close()


@pytest.mark.parametrize("width,height", [(390, 844), (320, 740)])
def test_phone_surface_matches_parent_client_without_native_frame(host, width, height):
    parent, _ = host
    parent.resize(width, height)
    dialog = SurfaceDialog(parent, emit=lambda *_: None)
    dialog.begin_load("agents", {}, "Settings")
    dialog.set_navigation(parse_chrome_menu(MODEL), presentation(width), lambda *_: None)
    dialog.show()
    QApplication.processEvents()
    assert dialog.size() == parent.size()
    assert dialog.pos() == parent.mapToGlobal(parent.rect().topLeft())
    assert dialog._navigation_panel.maximumHeight() == 56
    assert dialog._navigation_inner.findChild(QLabel, "surfaceIdentityName") is None
    assert dialog._close_btn.size().width() == 44
    dialog.close()


def test_escape_closes_once_stops_timer_and_returns_focus(host):
    parent, button = host
    closed = []
    dialog = SurfaceDialog(parent, emit=lambda *_: None, on_close=lambda: closed.append(True))
    dialog.begin_load("agents", {}, "Settings")
    dialog.set_navigation(parse_chrome_menu(MODEL), presentation(1440), lambda *_: None)
    dialog.show()
    QApplication.processEvents()
    QTest.keyClick(dialog, Qt.Key.Key_Escape)
    QApplication.processEvents()
    assert dialog.isHidden() and not dialog._timer.isActive()
    assert closed == [True]
    assert QApplication.focusWidget() is button


def test_mandatory_surface_refuses_close_and_retains_signout(host):
    parent, _ = host
    signed_out, closed = [], []
    dialog = SurfaceDialog(parent, emit=lambda *_: None,
                           on_sign_out=lambda: signed_out.append(True),
                           on_close=lambda: closed.append(True))
    dialog.set_mandatory(True)
    dialog.begin_load("consent", {}, "Consent")
    dialog.show()
    QTest.keyClick(dialog, Qt.Key.Key_Escape)
    assert not dialog.close() and not dialog.isHidden()
    assert dialog._close_btn.isHidden() and dialog._signout_btn.isVisible()
    dialog._signout_btn.click()
    assert signed_out == [True] and closed == []
    dialog.set_mandatory(False)
    dialog.close()
    assert closed == [True]


def test_ambiguous_subtitle_roles_remain_visible_content(host):
    parent, _ = host
    dialog = SurfaceDialog(parent, emit=lambda *_: None)
    dialog.set_surface("Details", [
        {"type": "text", "content": name, "console_role": "surface_subtitle"}
        for name in ("First", "Second")
    ])
    assert dialog._subtitle.isHidden()
    assert [label.text() for label in dialog._inner.findChildren(QLabel)] == ["First", "Second"]
    dialog.close()


def agent_row():
    return {"type": "card", "title": "Sample agent", "content": [
        {"type": "container", "direction": "row", "children": [
            {"type": "badge", "label": "Owned", "variant": "accent"},
            {"type": "badge", "label": "Ready", "variant": "success"},
        ]},
        {"type": "text", "content": "Description from the server. " * 8},
        {"type": "container", "direction": "row", "children": [
            {"type": "button", "label": "Inspect", "action": "chrome_open", "payload": {"surface": "agents", "params": {"agent_id": "sample", "tab": "mine"}}},
            {"type": "button", "label": "Turn off", "action": "chrome_agent_enabled", "payload": {"agent_id": "sample", "enabled": False, "tab": "mine"}},
        ]},
    ]}


def test_agent_adapter_preserves_exact_actions_and_accessible_full_description(qapp):
    sent = []
    source = agent_row()
    original = deepcopy(source)
    widget = adapt_settings_component("agents", {}, source, RenderContext(lambda *args: sent.append(args)))
    buttons = widget.findChildren(QPushButton)
    opener = next(button for button in buttons if button.objectName() == "settingsAgentOpen")
    assert opener.accessibleName() == "Inspect: Sample agent"
    assert opener.accessibleDescription() == source["content"][1]["content"]
    opener.click()
    next(button for button in buttons if button.objectName() == "settingsAgentToggle").click()
    expected = [(item["action"], item["payload"]) for item in source["content"][2]["children"]]
    assert sent == expected
    sent[0][1]["params"]["agent_id"] = "changed"
    opener.click()
    assert sent[-1][1]["params"]["agent_id"] == "sample"
    assert source == original


@pytest.mark.parametrize("mutation", ["extra", "wrong_owner", "unknown_badge", "extra_child", "missing", "invalid_enabled"])
def test_agent_adapter_leaves_unrecognized_payloads_for_generic_renderer(qapp, mutation):
    source = agent_row()
    if mutation == "extra":
        source["content"][2]["children"].append({"type": "text", "content": "Additional information"})
    elif mutation == "wrong_owner":
        source["content"][2]["children"][1]["payload"]["agent_id"] = "different"
    elif mutation == "unknown_badge":
        source["content"][0]["children"][0]["variant"] = []
    elif mutation == "extra_child":
        source["content"].append({"type": "input", "name": "setting"})
    elif mutation == "missing":
        del source["content"][2]["children"][0]["payload"]
    else:
        source["content"][2]["children"][1]["payload"]["enabled"] = "false"
    assert adapt_settings_component("agents", {}, source, RenderContext(lambda *_: None)) is None


@pytest.mark.parametrize("surface,params,source", [
    ("guidance", {}, agent_row()), ("agents", {"agent_id": "sample"}, agent_row()),
    ("agents", {}, "invalid"), ("agents", {}, {"type": "text", "content": "Keep visible"}),
])
def test_settings_adaptation_is_scoped_to_agent_list_only(qapp, surface, params, source):
    assert adapt_settings_component(surface, params, source, RenderContext(lambda *_: None)) is None


def test_agent_adapter_preserves_disabled_actions_and_non_success_badges(qapp):
    source = agent_row()
    source["content"][0]["children"][1]["variant"] = "warning"
    source["content"][1]["content"] = "Short description"
    for action in source["content"][2]["children"]:
        action["disabled"] = True
    sent = []
    widget = adapt_settings_component("agents", {}, source, RenderContext(lambda *args: sent.append(args)))
    for button in widget.findChildren(QPushButton):
        button.click()
        assert not button.isEnabled()
    assert not sent
    assert "Ready" in [label.text() for label in widget.findChildren(QLabel)]


def test_agent_list_tabs_use_server_labels_actions_and_selected_disablement(qapp):
    sent = []
    source = {"type": "container", "direction": "row", "children": [
        {"type": "button", "label": "Private", "action": "chrome_open", "payload": {"surface": "agents", "params": {"tab": "mine"}}, "disabled": True},
        {"type": "button", "label": "Shared", "action": "chrome_open", "payload": {"surface": "agents", "params": {"tab": "public"}}},
    ]}
    widget = adapt_settings_component("agents", {}, source, RenderContext(lambda *args: sent.append(args)))
    private, shared = widget.findChildren(QPushButton)
    private.click()
    shared.click()
    assert not private.isEnabled() and shared.text() == "Shared"
    assert sent == [("chrome_open", {"surface": "agents", "params": {"tab": "public"}})]
