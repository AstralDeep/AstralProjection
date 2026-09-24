"""Tests for src/astralprojection/chrome/guidance.py's notes view: save/forget/toggle
forms, pagination and fail-closed handling of invalid snapshots.
"""

from copy import deepcopy
import json

import pytest

from astralprojection.chrome import render_html
from astralprojection.chrome.guidance import build_guidance_view, build_notes_view
from astralprojection.models import LayoutView

ID = "180cd30b-cc38-432d-8349-1851b0d3ad7e"
OTHER = "48873d61-2e9b-4f38-bc36-bbfa81d78580"


def note(**values):
    return {"note_id": ID, "revision": 7, "category": "preference",
            "value": '<script>alert("private")</script>\nUse short paragraphs.',
            "enabled": True, "expires_at": 1798761540000, **values}


def state(mode="list", **values):
    base = {"mode": mode, "status": "ready"}
    if mode == "list":
        base.update(notes=[note()], search="", next_cursor=None)
    elif mode == "new":
        base["note_id"] = OTHER
    else:
        base["note"] = note()
    return {**base, **values}


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


def encoded(value):
    return json.dumps(value.to_dict(), ensure_ascii=False)


def forms(view):
    return [item for item in nodes(view.to_dict()) if item.get("type") == "param_picker"]


@pytest.mark.parametrize("mode", ["list", "new", "edit", "forget"])
def test_shared_form_factors_keep_identical_content_and_escape_private_text(mode):
    original = state(mode)
    before = deepcopy(original)
    view = build_notes_view(original)
    for layout in ("standard", "compact", "wide", "watch"):
        other = build_notes_view(original, layout=LayoutView(mode=layout))
        assert other.to_dict()["components"] == view.to_dict()["components"]
    assert original == before
    html = render_html(view)
    assert '<script>' not in html and "javascript:" not in html
    if mode != "new":
        assert "&lt;script&gt;" in html and "Use short paragraphs." in html
    assert "ciphertext" not in encoded(view) and "owner_id" not in encoded(view)


@pytest.mark.parametrize("mode,revision", [("new", 0), ("edit", 7)])
def test_save_form_submits_only_exact_identity_and_reviewed_fields(mode, revision):
    view = build_notes_view(state(mode))
    form, = forms(view)
    assert form["submit_action"] == "chrome_note_save"
    assert form["submit_payload"] == {"note_id": OTHER if mode == "new" else ID,
                                      "expected_revision": revision}
    fields = {item["name"]: item for item in form["fields"]}
    assert set(fields) == {"category", "value", "enabled", "expiry", "expiry_date"}
    assert fields["expiry"]["default"] == ("No expiry" if mode == "new" else "Keep current expiry")
    assert fields["expiry_date"]["visible_when"] == {"expiry": "Set a date"}
    assert "token" not in encoded(view) and "approval" not in form["submit_payload"]


def test_forget_requires_separate_review_and_has_no_value_in_command():
    listing = build_notes_view(state())
    links = [item for item in nodes(listing.to_dict()) if item.get("type") == "button"]
    forget = next(item for item in links if item["label"] == "Forget")
    assert forget["action"] == "chrome_open"
    assert forget["payload"] == {"surface": "guidance", "params": {
        "mode": "forget", "note_id": ID, "expected_revision": 7}}
    review = build_notes_view(state("forget"))
    buttons = [item for item in nodes(review.to_dict()) if item.get("type") == "button"]
    command = next(item for item in buttons if item["action"] == "chrome_note_forget")
    assert command["payload"] == {"note_id": ID, "expected_revision": 7}
    assert "cannot be undone" in render_html(review)


@pytest.mark.parametrize("enabled,label", [(True, "Disable"), (False, "Enable")])
def test_toggle_has_explicit_target_state_and_revision(enabled, label):
    view = build_notes_view(state(notes=[note(enabled=enabled)]))
    toggle = next(item for item in nodes(view.to_dict()) if item.get("action") == "chrome_note_toggle")
    assert toggle["label"] == label
    assert toggle["payload"] == {"note_id": ID, "expected_revision": 7, "enabled": not enabled}


def test_bounded_search_page_does_not_claim_empty_library_and_keeps_cursor():
    view = build_notes_view(state(notes=[], search="needle", next_cursor=ID))
    assert "No matching notes on this page" in render_html(view)
    assert "No private notes yet" not in render_html(view)
    more = next(item for item in nodes(view.to_dict()) if item.get("label") == "Next page")
    assert more["payload"]["params"] == {"mode": "list", "after_id": ID, "search": "needle"}
    assert forms(view)[0]["submit_action"] == "chrome_note_search"
    assert forms(view)[0]["fields"][0]["default"] == "needle"
    assert "No private notes yet" in render_html(build_notes_view(state(notes=[])))


@pytest.mark.parametrize("expiry", [None, 2**53 - 1])
def test_unrepresentable_dates_preserve_current_expiry_without_loss(expiry):
    view = build_notes_view(state("edit", note=note(expires_at=expiry)))
    fields = {item["name"]: item for item in forms(view)[0]["fields"]}
    assert fields["expiry"]["default"] == "Keep current expiry"
    assert fields["expiry_date"]["default"] == ""


@pytest.mark.parametrize("bad", [
    {"owner_id": "private-owner"}, {"ciphertext": "PRIVATE"}, {"revision": True},
    {"revision": 0}, {"revision": 2**53 - 1}, {"note_id": "not-an-id"},
    {"enabled": 1}, {"expires_at": -1}, {"expires_at": True},
    {"category": "authority"}, {"value": ""}, {"value": "x" * 4097},
    {"value": "bad\x00text"}, {"value": "\ud800"},
])
def test_invalid_note_refuses_entire_snapshot_without_partial_private_text(bad):
    view = build_notes_view(state(notes=[note(note_id=OTHER), note(**bad)]))
    assert "unavailable" in render_html(view)
    assert "Use short paragraphs" not in encoded(view)
    assert not forms(view)


@pytest.mark.parametrize("bad", [
    {"notes": [note()] * 101}, {"notes": [note(), note()]}, {"notes": "private"},
    {"search": "x" * 257}, {"next_cursor": "not-an-id"}, {"mode": "execute"},
    {"extra": "PRIVATE"}, {"notice": "PRIVATE"}, {"status": "mystery"},
])
def test_invalid_top_level_state_never_forwards_untrusted_diagnostics(bad):
    view = build_notes_view(state(**bad))
    assert "unavailable" in render_html(view) and "PRIVATE" not in encoded(view)


@pytest.mark.parametrize("status", ["loading", "unavailable"])
def test_nonready_states_do_not_render_stale_private_content(status):
    view = build_notes_view(state(status=status))
    assert "Use short paragraphs" not in encoded(view) and not forms(view)


@pytest.mark.parametrize("notice", ["saved", "enabled", "disabled", "forgotten"])
def test_notices_are_closed_server_owned_text(notice):
    view = build_notes_view(state(notice=notice))
    assert any(item.get("variant") == "success" for item in nodes(view.to_dict()))


def test_invalid_new_identity_refuses_form_and_untyped_state_is_safe():
    assert not forms(build_notes_view(state("new", note_id="bad")))
    assert "unavailable" in render_html(build_notes_view(None))


@pytest.mark.parametrize("mode", ["list", "new", "edit", "forget"])
def test_notes_contract_is_byte_identical_under_the_guidance_dispatcher(mode):
    original = state(mode)
    assert build_guidance_view(original).to_dict() == build_notes_view(original).to_dict()
    tagged = build_notes_view({"view": "skills", **original})
    assert "unavailable" in render_html(tagged) and not forms(tagged)
    assert "Use short paragraphs" not in encoded(tagged)
