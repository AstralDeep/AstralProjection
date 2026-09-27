"""Protect selectable detail surfaces, exact native action payloads and popup geometry.
The fixtures exercise complete public reference shapes plus malformed fallback and resize paths.
"""

from copy import deepcopy
from math import ceil
import pytest
from PySide6.QtCore import QEvent, Qt, QPoint
from PySide6.QtGui import QFont, QFontMetricsF
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QPushButton, QStyle, QStyleOptionButton, QVBoxLayout, QWidget
from astral_client import theme as T
from astral_client.app import SurfaceDialog
from astral_client.renderer import RenderContext
from astral_client.rest import parse_chrome_menu
from astral_client.surface_widgets import adapt_detail_components, _detail_text
from webrender.chrome.menu_model import menu_model_dict
from test_surface_presentation import MODEL, presentation
from test_console_shell import win as shell_fixture  # noqa: F401
from test_message_routing import win as window_fixture  # noqa: F401

DESCRIPTION = "Rolls dice and reports every roll and the total — the smallest honest end-to-end test of routing, permissions and rendering."
PROMPT = "Roll exactly six six-sided dice and show the normalized results."
DISCLOSURE = "Use for this chat: your selection applies to this chat only. Each task you send carries exactly the agent revision, skill revisions and note revisions listed here; the server rechecks them when the task is accepted and refuses anything changed or forgotten since."


def text(value, variant="body"):
    return dict(type="text", content=value, variant=variant)


def action(label, verb, payload, **extra):
    return dict(type="button", label=label, action=verb, payload=payload, **extra)


def intro():
    examples = []
    for title, prompt in [
        ("Six dice", PROMPT),
        ("Many rolls", "Roll 100 six-sided dice and chart how often each face came up"),
    ]:
        examples.append(
            dict(
                type="card",
                title=title,
                content=[
                    text(prompt),
                    dict(
                        type="container",
                        direction="row",
                        children=[
                            action("Run", "chat_message", dict(message=prompt), variant="primary"),
                            action("Load", "compose_prompt", dict(message=prompt)),
                        ],
                    ),
                ],
            )
        )
    return [
        dict(type="badge", label="Available", variant="success"),
        text(DESCRIPTION),
        text("Try one of these", "h3"),
        *examples,
        text("Tools it can reach (1)", "h3"),
        dict(type="list", items=["roll_dice"], ordered=False),
        action(
            "Permissions for this agent",
            "chrome_open",
            dict(surface="agents", params=dict(agent_id="dice", tab="mine")),
        ),
    ]


def selection():
    return [
        text(DISCLOSURE),
        text("Agent", "h3"),
        text("No active agent revision to select.", "caption"),
        text("Skills", "h3"),
        text("No skills to select.", "caption"),
        text("Private notes", "h3"),
        text("No private notes to select.", "caption"),
        action("Refresh", "chrome_open", dict(surface="guidance", params=dict(view="selection"))),
    ]


@pytest.fixture
def host(qapp):
    old_font, old_style = qapp.font(), qapp.styleSheet()
    loaded = qapp.property("astralOpenSansLoaded")
    qapp.setProperty("astralOpenSansLoaded", False)
    T.configure_fonts(qapp)
    qapp.setStyleSheet(T.APP_STYLESHEET)
    widget = QWidget()
    widget._console_model = MODEL["console"]
    widget.resize(1440, 900)
    widget.show()
    yield widget
    widget.close()
    widget.deleteLater()
    QApplication.sendPostedEvents(widget, QEvent.Type.DeferredDelete)
    qapp.setFont(old_font)
    qapp.setStyleSheet(old_style)
    qapp.setProperty("astralOpenSansLoaded", loaded)


def settle():
    for _ in range(4):
        QApplication.processEvents()
        QTest.qWait(1)


@pytest.mark.parametrize("width", [1440, 1280, 1024, 834, 768, 390, 320])
def test_settings_navigation_retains_reference_line_boxes_and_group_spacing(host, width):
    host.resize(width, 1194 if width == 834 else 900)
    dialog = SurfaceDialog(host, lambda *_: None)
    dialog.begin_load("agents", {}, "Agents & permissions")
    dialog.set_navigation(parse_chrome_menu(MODEL), presentation(width), lambda *_: None)
    dialog.show()
    settle()
    controls = dialog._navigation_inner.findChildren(QPushButton, "surfaceNavigationItem")
    assert controls
    row_height = 34 if width >= 1024 else 35
    assert all(control.height() == row_height for control in controls)
    if width >= 768:
        identity = dialog._navigation_inner.findChild(QWidget, "surfaceIdentity")
        assert identity.height() == 56
        assert controls[0].y() == 111
        assert controls[1].y() - controls[0].y() == row_height + 2
        groups = dialog._navigation_inner.findChildren(QWidget, "surfaceNavigationGroup")
        assert all(group.height() == 31 for group in groups)
    else:
        assert dialog._navigation_inner.findChild(QWidget, "surfaceIdentity") is None
        assert controls[0].y() == 10
    dialog.close()


def complete_navigation():
    return parse_chrome_menu(menu_model_dict(
        ["admin"], pulse_enabled=True, byo_enabled=True, remote_enabled=True,
        notes_enabled=True, export_enabled=True, share_enabled=True,
    ))


@pytest.mark.parametrize("width,height", [(390, 844), (320, 740)])
@pytest.mark.parametrize("surface", ["agents", "llm"])
def test_phone_navigation_measures_the_font_used_for_active_and_inactive_text(host, width, height, surface):
    host.resize(width, height)
    dialog = SurfaceDialog(host, lambda *_: None)
    dialog.begin_load(surface, {}, "Settings")
    dialog.set_navigation(complete_navigation(), presentation(width), lambda *_: None)
    dialog.show()
    settle()
    controls = dialog._navigation_inner.findChildren(QPushButton, "surfaceNavigationItem")
    assert any(control.isChecked() for control in controls)
    assert any(not control.isChecked() for control in controls)
    for control in controls:
        expected = QFont.Weight.DemiBold if control.isChecked() else QFont.Weight.Normal
        assert control.font().weight() == expected
        option = QStyleOptionButton()
        control.initStyleOption(option)
        contents = control.style().subElementRect(QStyle.SubElement.SE_PushButtonContents, option, control)
        label_width = ceil(QFontMetricsF(control.font()).horizontalAdvance(control.text().replace("&&", "&")))
        assert label_width <= contents.width(), control.text()
    dialog.close()


@pytest.mark.parametrize("width,height", [(1440, 900), (1280, 800), (1024, 768)])
def test_settings_footer_scrolls_with_navigation_and_keyboard_reaches_it(host, width, height):
    host.resize(width, height)
    signed_out = []
    opened = []
    dialog = SurfaceDialog(host, lambda *_: None, on_sign_out=lambda: signed_out.append(True))
    dialog.begin_load("agents", {}, "Agents & permissions")
    menu = complete_navigation()
    dialog.set_navigation(menu, presentation(width), lambda *args: opened.append(args))
    dialog.show()
    settle()
    footer = dialog._nav_signout
    viewport = dialog._navigation.viewport()
    bar = dialog._navigation.verticalScrollBar()
    assert footer.parentWidget() is dialog._navigation_inner
    assert bar.maximum() > 0
    assert bar.value() == 0
    assert footer.mapTo(viewport, QPoint()).y() + footer.height() > viewport.height()
    controls = dialog._navigation_inner.findChildren(QPushButton, "surfaceNavigationItem")
    controls[-1].setFocus()
    QTest.keyClick(controls[-1], Qt.Key.Key_Tab)
    settle()
    assert footer.hasFocus()
    assert bar.value() > 0
    position = footer.mapTo(viewport, QPoint())
    assert 0 <= position.y() <= viewport.height() - footer.height()
    QTest.keyClick(footer, Qt.Key.Key_Space)
    assert signed_out == [True]
    assert opened == []
    dialog.close()


@pytest.mark.parametrize("width,height", [(390, 844), (320, 740)])
def test_phone_navigation_ends_with_reachable_authorized_signout(host, width, height):
    host.resize(width, height)
    signed_out = []
    dialog = SurfaceDialog(host, lambda *_: None, on_sign_out=lambda: signed_out.append(True))
    dialog.begin_load("agents", {}, "Agents & permissions")
    menu = complete_navigation()
    dialog.set_navigation(menu, presentation(width), lambda *_: None)
    dialog.show()
    settle()
    footer = dialog._nav_signout
    viewport = dialog._navigation.viewport()
    controls = dialog._navigation_inner.findChildren(QPushButton, "surfaceNavigationItem")
    assert footer.isVisible()
    assert footer.height() == 35
    assert footer.x() > controls[-1].x()
    controls[-1].setFocus()
    QTest.keyClick(controls[-1], Qt.Key.Key_Tab)
    settle()
    assert footer.hasFocus()
    position = footer.mapTo(viewport, QPoint())
    assert 0 <= position.x() <= viewport.width() - footer.width()
    QTest.keyClick(footer, Qt.Key.Key_Space)
    assert signed_out == [True]
    assert dialog._footer.isHidden()
    dialog.close()


def test_navigation_without_logout_action_never_offers_signout(host):
    menu = complete_navigation()
    menu["signout"] = {}
    dialog = SurfaceDialog(host, lambda *_: None)
    dialog.begin_load("agents", {}, "Agents & permissions")
    for width, height in [(1440, 900), (390, 844)]:
        host.resize(width, height)
        dialog.set_navigation(menu, presentation(width), lambda *_: None)
        dialog.show()
        settle()
        assert dialog._nav_signout.isHidden()
        assert dialog._navigation_inner.findChild(QWidget, "surfaceNavigationRule") is None
    dialog.close()


@pytest.mark.parametrize(
    "surface,builder,expected", [("agent_intro", intro, 508), ("guidance", selection, 467)]
)
def test_detail_dialog_natural_height_reflows_after_population_and_phone_resize(
    host, surface, builder, expected
):
    dialog = SurfaceDialog(host, lambda *_: None)
    params = {"view": "selection"} if surface == "guidance" else {"agent_id": "dice"}
    dialog.begin_load(surface, params, "Details")
    dialog.set_navigation(parse_chrome_menu(MODEL), presentation(1440), lambda *_: None)
    dialog.show()
    dialog.set_surface("Details", builder())
    settle()
    assert dialog.size().toTuple() == (640, expected)
    assert dialog._scroll.verticalScrollBar().maximum() == 0
    for width, height in [(390, 844), (320, 740), (1440, 900)]:
        host.resize(width, height)
        dialog.set_navigation(parse_chrome_menu(MODEL), presentation(width), lambda *_: None)
        settle()
        assert dialog.size().toTuple() == ((640, expected) if width == 1440 else (width, height))
        if surface == "agent_intro":
            cards = dialog._inner.findChildren(QWidget, "agentIntroExample")
            assert cards[0].height() == (68 if width == 1440 else 128)
    dialog.close()


@pytest.mark.parametrize(
    "surface,builder,params",
    [("agent_intro", intro, {}), ("guidance", selection, {"view": "selection"})],
)
def test_detail_actions_preserve_disabled_state_and_exact_deep_copied_payload(
    host, surface, builder, params
):
    source = builder()
    original = deepcopy(source)
    sent = []
    body = adapt_detail_components(
        surface, params, source, RenderContext(lambda *args: sent.append(args)), True
    )
    body.setParent(host)
    body.resize(358, 700)
    body.show()
    settle()
    buttons = body.findChildren(QPushButton)
    buttons[0].click()
    expected = (
        original[3]["content"][1]["children"][0] if surface == "agent_intro" else original[-1]
    )
    assert sent[-1] == (expected["action"], expected["payload"])
    sent[-1][1].clear()
    buttons[0].click()
    assert sent[-1][1] == expected["payload"]
    assert source == original
    for button in buttons:
        button.setEnabled(False)
        before = len(sent)
        button.click()
        assert len(sent) == before


@pytest.mark.parametrize("which", ["card", "button", "off"])
def test_intro_server_disabled_states_and_unavailable_badge(host, which):
    source = intro()
    source[0]["variant"] = "default"
    source[0]["label"] = "Turned off for this account"
    if which == "card":
        source[3]["disabled"] = True
    if which == "button":
        source[3]["content"][1]["children"][0]["disabled"] = True
    sent = []
    body = adapt_detail_components(
        "agent_intro", {}, source, RenderContext(lambda *a: sent.append(a)), True
    )
    buttons = body.findChildren(QPushButton)
    buttons[0].click()
    assert bool(sent) == (which == "off")


@pytest.mark.parametrize(
    "mutation",
    [
        "badge_list",
        "badge_dict",
        "text_extra",
        "unknown_child",
        "wrong_prompt",
        "wrong_action",
        "tools_type",
        "tools_ordered",
        "tools_item",
        "card_title",
        "container",
        "description",
        "permission",
        "short",
    ],
)
def test_intro_unrecognized_shapes_fall_back_without_losing_information(qapp, mutation):
    source = intro()
    if mutation == "badge_list":
        source[0]["variant"] = []
    elif mutation == "badge_dict":
        source[0]["variant"] = {}
    elif mutation == "text_extra":
        source.insert(1, text("Additional disclosure"))
    elif mutation == "unknown_child":
        source[3]["content"].append(text("extra"))
    elif mutation == "wrong_prompt":
        source[3]["content"][1]["children"][0]["payload"]["message"] = "different"
    elif mutation == "wrong_action":
        source[3]["content"][1]["children"][0]["action"] = "admin_delete"
    elif mutation == "tools_type":
        source[-2]["items"] = "roll_dice"
    elif mutation == "tools_ordered":
        source[-2]["ordered"] = True
    elif mutation == "tools_item":
        source[-2]["items"] = [{}]
    elif mutation == "card_title":
        source[3]["title"] = []
    elif mutation == "container":
        source[3]["content"][1]["direction"] = "column"
    elif mutation == "description":
        source[1]["content"] = []
    elif mutation == "permission":
        source[-1]["payload"]["surface"] = "other"
    elif mutation == "short":
        source = []
    assert (
        adapt_detail_components("agent_intro", {}, source, RenderContext(lambda *_: None)) is None
    )


@pytest.mark.parametrize(
    "surface,params,source",
    [
        ("other", {}, []),
        ("guidance", None, []),
        ("guidance", {}, None),
        ("guidance", {}, [None]),
        ("guidance", {"view": "selection"}, [{}]),
        ("guidance", {"view": "other"}, []),
    ],
)
def test_detail_unknown_envelopes_fall_back(qapp, surface, params, source):
    assert adapt_detail_components(surface, params, source, RenderContext(lambda *_: None)) is None


@pytest.mark.parametrize("mutation", ["heading", "caption", "action", "payload"])
def test_selection_unrecognized_shapes_fall_back(qapp, mutation):
    source = selection()
    if mutation == "heading":
        source[1]["variant"] = "body"
    elif mutation == "caption":
        source[2]["content"] = {}
    elif mutation == "action":
        source[-1]["action"] = "delete"
    elif mutation == "payload":
        source[-1]["payload"]["extra"] = "keep"
    assert (
        adapt_detail_components(
            "guidance", {"view": "selection"}, source, RenderContext(lambda *_: None)
        )
        is None
    )


def test_detail_text_is_escaped_selectable_and_copies_literal_wrapped_newlines(host, qapp):
    content = (
        "  First <b>literal  & text</b>\n\tSecond line with enough words to wrap on a narrow surface."
    )
    label = _detail_text(content)
    layout = QVBoxLayout(host)
    layout.addWidget(label)
    host.resize(200, 250)
    settle()
    assert label.accessibleName() == content
    assert "&lt;b&gt;" in label.text()
    assert "<br>" in label.text()
    assert label.textInteractionFlags() & Qt.TextInteractionFlag.TextSelectableByMouse
    assert label.textInteractionFlags() & Qt.TextInteractionFlag.TextSelectableByKeyboard
    label.setFocus()
    QTest.keyClick(label, Qt.Key.Key_A, Qt.KeyboardModifier.ControlModifier)
    QTest.keyClick(label, Qt.Key.Key_C, Qt.KeyboardModifier.ControlModifier)
    assert qapp.clipboard().text().replace("\u2028", "\n").replace("\u2029", "\n") == content
    label.setSelection(0, 0)
    QTest.mousePress(label, Qt.MouseButton.LeftButton, pos=QPoint(1, 10))
    QTest.mouseMove(label, QPoint(label.width() - 2, 55))
    QTest.mouseRelease(label, Qt.MouseButton.LeftButton, pos=QPoint(label.width() - 2, 55))
    assert label.hasSelectedText()


def test_composer_popup_keeps_its_full_geometry_and_keyboard_actions(request):
    win = request.getfixturevalue("shell_fixture")
    shell = win._console_shell
    win.resize(390, 844)
    shell.apply_presentation(presentation(390))
    settle()
    shell._show_more()
    settle()
    popup = shell.more_menu
    assert popup.width() == 220
    assert popup.height() == 232
    assert [popup.actionGeometry(action).height() for action in popup.actions()] == [44] * 5
    assert all(not action.icon().isNull() for action in popup.actions())
    assert popup.activeAction() is popup.actions()[0]
    QTest.keyClick(popup, Qt.Key.Key_Down)
    assert popup.activeAction() is popup.actions()[1]
    shell._show_more()
    assert not popup.isVisible()
