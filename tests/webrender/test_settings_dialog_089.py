"""The settings dialog's shape: a rail beside a pane, and what each omits.

Feature 089 turned the gear's dropdown into the dialog's left rail, which moved
three decisions into the renderer that nothing was reading back: whether a
dialog has a rail at all, where a surface's own tab strip sits when it does,
and what the rail says about who is signed in. Each of them has a case that
produces nothing -- no rail, no tabs, no account block -- and those are the
cases a person hits when a deployment offers less than the full menu.
"""
from webrender.chrome import render_modal_shell, render_settings_nav
from webrender.chrome.menu_model import build_menu_model
from webrender.chrome.topbar import settings_entry_surface
from webrender.renderer import render_chat_history


# ---------------------------------------------------------------------------
# The dialog shell
# ---------------------------------------------------------------------------

def test_a_dialog_without_a_rail_is_the_dialog_it_always_was():
    html = render_modal_shell("Plain", "<p>body</p>", "plain")
    assert "astral-modal-split" not in html
    assert "astral-modal-pane" not in html
    assert "has-nav" not in html
    assert '<div class="astral-modal-body"><p>body</p></div>' in html


def test_a_rail_puts_the_body_in_a_pane_beside_it():
    html = render_modal_shell("Settings", "<p>body</p>", "agents",
                              nav_html='<nav class="astral-settings-nav"></nav>')
    assert "astral-modal-card has-nav" in html
    # The rail comes first, then the pane, and the body is inside the pane.
    split = html.index("astral-modal-split")
    nav = html.index("astral-settings-nav")
    pane = html.index("astral-modal-pane")
    body = html.index("astral-modal-body")
    assert split < nav < pane < body


def test_a_surfaces_tabs_sit_inside_the_pane_not_across_the_dialog():
    """Run full width a tab strip sits over the rail, where it reads as
    navigation for the rail as well as for the pane it actually switches."""
    sections = (("one", "One"), ("two", "Two"))
    without = render_modal_shell("Plain", "<p>b</p>", "plain", sections=sections)
    with_rail = render_modal_shell("Settings", "<p>b</p>", "llm", sections=sections,
                                   nav_html='<nav class="astral-settings-nav"></nav>')
    # No rail: the strip is a sibling of the body, above it and full width.
    assert without.index("astral-modal-tabs") < without.index("astral-modal-body")
    assert "astral-modal-pane" not in without
    # With a rail: the strip is inside the pane, after the rail.
    assert with_rail.index("astral-settings-nav") < with_rail.index("astral-modal-tabs")
    assert with_rail.index("astral-modal-pane") < with_rail.index("astral-modal-tabs")
    assert with_rail.index("astral-modal-tabs") < with_rail.index("astral-modal-body")


def test_a_footer_stays_below_the_split():
    html = render_modal_shell("Settings", "<p>b</p>", "agents",
                              nav_html='<nav class="astral-settings-nav"></nav>',
                              footer_html='<button type="button">Save</button>')
    assert html.index("astral-modal-split") < html.index("astral-modal-footer")


# ---------------------------------------------------------------------------
# The rail
# ---------------------------------------------------------------------------

def test_the_rail_marks_where_you_are_and_offers_sign_out():
    model = build_menu_model(["user"])
    html = render_settings_nav(model, settings_entry_surface(model))
    assert 'class="astral-settings-nav"' in html
    assert html.count('aria-current="true"') == 1
    assert 'href="/auth/logout"' in html


def test_a_model_with_nothing_to_navigate_to_renders_no_rail():
    """A rail with no entries would be a column of nothing, so there is none --
    and the dialog then renders as an ordinary one."""

    class Empty:
        menu = ()
        topbar = ()
        signout = None

    assert render_settings_nav(Empty(), "agents") == ""


def test_the_account_block_needs_a_name_and_says_nothing_more():
    model = build_menu_model(["user"])
    named = render_settings_nav(model, "agents",
                                identity={"name": "A Person", "role": "Member",
                                          "initials": "AP"})
    assert "astral-settings-who" in named
    assert "A Person" in named and "Member" in named and ">AP<" in named

    for identity in (None, {}, {"name": "   ", "role": "Member", "initials": "X"}):
        assert "astral-settings-who" not in render_settings_nav(model, "agents",
                                                                identity=identity)


def test_the_account_block_escapes_what_it_is_given():
    model = build_menu_model(["user"])
    html = render_settings_nav(model, "agents", identity={
        "name": "<script>x</script>", "role": "<b>r</b>", "initials": "<i>"})
    assert "<script>" not in html and "<b>r</b>" not in html
    assert "&lt;script&gt;" in html


# ---------------------------------------------------------------------------
# Where the gear lands
# ---------------------------------------------------------------------------

def test_the_gear_opens_the_rails_first_entry():
    model = build_menu_model(["user"])
    first = model.menu[0].items[0].surface
    assert settings_entry_surface(model) == first


def test_a_model_offering_no_menu_still_opens_something():
    """A gear that opens nothing would be worse than one that opens the
    surface every deployment has."""

    class Empty:
        menu = ()

    assert settings_entry_surface(Empty()) == "agents"


# ---------------------------------------------------------------------------
# The list the rail's History section shows
# ---------------------------------------------------------------------------

def test_an_empty_history_says_so_without_a_heading_or_a_count():
    html = render_chat_history({"type": "chat_history", "items": []})
    assert "No conversations yet." in html
    assert "astral-history-head" not in html
    assert "astral-history-count" not in html
    assert "astral-history-item" not in html


def test_a_row_is_a_button_that_opens_its_chat_and_carries_no_picture():
    html = render_chat_history({"type": "chat_history", "items": [
        {"chat_id": "c1", "title": "Trip to Rome", "preview": "Where to stay",
         "time": "2h", "saved": True},
        {"chat_id": "c2", "title": ""},
    ]})
    assert html.count('data-action="load_chat"') == 2
    assert "Trip to Rome" in html and "Where to stay" in html and ">2h<" in html
    assert "Untitled chat" in html            # a blank title still opens
    assert "astral-history-saved" in html     # the saved-components marker
    # No heading, no count, no per-row avatar (owner directive 2026-09-19).
    assert "astral-history-head" not in html
    assert "astral-history-count" not in html
    assert "astral-history-avatar" not in html


def test_rows_with_no_openable_chat_are_the_empty_state():
    """An item with no chat id cannot be opened, so it is not a row."""
    html = render_chat_history({"type": "chat_history",
                                "items": [{"title": "no id"}, "not a dict"]})
    assert "No conversations yet." in html
