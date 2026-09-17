"""Skill, declarative-agent and selection forms carry exact identities and never private text."""

from copy import deepcopy
import json
from uuid import UUID

import pytest

from astralprojection.chrome import render_html
from astralprojection.chrome.agents import build_declarative_agents_view as reexported
from astralprojection.chrome.guidance import (
    GUIDANCE_VIEWS, SELECTION_DISCLOSURE, build_declarative_agents_view, build_guidance_view,
    build_notes_view, build_selection_form, build_skills_view,
)
from astralprojection.models import LayoutView

SKILL = "0d9c2f9a-3e5b-4c7d-8a1f-6b2e4d8c0a13"
CMD = "7a5e1c3b-9d2f-4b6a-8c4e-1f3a5b7d9e21"
OTHER = "48873d61-2e9b-4f38-bc36-bbfa81d78580"
OTHER_CMD = "c2d4e6f8-0a1b-4c3d-8e5f-6a7b8c9d0e43"
AGENT = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c76"
REV1 = "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d98"
REV2 = "3c4d5e6f-7a8b-4c9d-8e1f-2a3b4c5d6e09"
FRESH = "4d5e6f7a-8b9c-4d0e-9f2a-3b4c5d6e7f10"
NOTE = "7a8b9c0d-1e2f-4a3b-8c5d-6e7f8a9b0c43"
PRIVATE = '<script>alert("private")</script> keep this secret'
DIGEST = "a" * 64
LAYOUTS = ("standard", "compact", "wide", "watch")


def skill(**values):
    return {"skill_id": SKILL, "command_id": CMD, "revision": 4, "slug": "standup", "name": "Standup <b>",
            "command": "standup", "applies_to": ["web-research-1"], "enabled": True,
            "instructions": "Three lines. " + PRIVATE, **values}


def skills_state(mode="list", **values):
    base = {"status": "ready", "mode": mode}
    if mode == "list":
        base["skills"] = [skill()]
    elif mode == "new":
        base.update(skill_id=OTHER, command_id=OTHER_CMD)
    else:
        base["skill"] = skill()
    return {**base, **values}


def head(**values):
    return {"agent_id": AGENT, "display_name": "Scout <i>", "status": "active", "state_revision": 6,
            "selected_revision_id": REV2, "updated_at": 1789000000000, **values}


def revision(number=2, revision_id=REV2, parent=REV1):
    return {"revision_id": revision_id, "agent_id": AGENT, "revision_number": number,
            "parent_revision_id": parent, "created_at": 1788000000000,
            "definition_digest": DIGEST, "definition": {"version": 1, "note": PRIVATE}}


def agents_state(mode="list", **values):
    base = {"status": "ready", "mode": mode}
    if mode == "list":
        base["agents"] = [head()]
    elif mode == "history":
        base.update(agent=head(), revisions=[revision(), revision(1, REV1, None)], next_before=None)
    elif mode == "new":
        base.update(agent_id=OTHER, revision_id=FRESH, command_id=CMD)
    elif mode == "revise":
        base.update(agent=head(), revision=revision(), revision_id=FRESH, command_id=CMD)
    elif mode == "clone":
        base.update(agent=head(), revision=revision(), agent_id=OTHER, revision_id=FRESH, command_id=CMD)
    elif mode == "activate":
        base.update(agent=head(), revision=revision(1, REV1, None), command_id=CMD)
    else:
        base.update(agent=head(), command_id=CMD)
    return {**base, **values}


def selection_state(**values):
    return {"status": "ready",
            "agents": [{"agent_id": AGENT, "revision_id": REV2, "display_name": "Scout <i>"}],
            "skills": [{"skill_id": SKILL, "revision": 4, "name": "Standup <b>", "command": "standup",
                        "enabled": True},
                       {"skill_id": OTHER, "revision": 1, "name": "Off", "command": "", "enabled": False}],
            "notes": [{"note_id": NOTE, "revision": 3, "category": "preference", "enabled": True}],
            "selected": {"agent": None, "skills": [], "notes": []}, **values}


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


def encoded(view):
    return json.dumps(view.to_dict(), ensure_ascii=False)


def forms(view):
    return [item for item in nodes(view.to_dict()) if item.get("type") == "param_picker"]


def buttons(view, action=None):
    return [item for item in nodes(view.to_dict()) if item.get("type") == "button"
            and (action is None or item["action"] == action)]


def commands(view):
    """Every non-navigation command payload in the view."""
    return [item["payload"] for item in buttons(view)
            if item["action"] not in {"chrome_open", "chrome_declarative_view"}] + [
            item["submit_payload"] for item in forms(view)]


def selected_ids(value):
    """Local replica of backend work_submit._selected_ids (closed version-1 shape)."""
    assert type(value) is dict and set(value) == {"version", "agent", "skills", "notes"}
    assert value["version"] == 1
    agent = value["agent"]
    if agent is not None:
        assert set(agent) == {"agent_id", "revision_id"} and 1 <= len(agent["agent_id"]) <= 255
        assert UUID(agent["revision_id"]).version == 4
    for kind, field_name, maximum in (("skills", "skill_id", 20), ("notes", "note_id", 8)):
        entries = value[kind]
        assert type(entries) is list and len(entries) <= maximum
        seen = set()
        for entry in entries:
            assert set(entry) == {field_name, "revision"} and 1 <= entry["revision"] <= 2**53 - 1
            assert str(UUID(entry[field_name])) == entry[field_name] and entry[field_name] not in seen
            seen.add(entry[field_name])
    return agent is None and not value["skills"] and not value["notes"]


# ---------------------------------------------------------------- shared

@pytest.mark.parametrize("builder,state", [
    (build_skills_view, skills_state()), (build_skills_view, skills_state("edit")),
    (build_declarative_agents_view, agents_state()), (build_declarative_agents_view, agents_state("revise")),
    (build_selection_form, selection_state()),
])
def test_form_factors_share_content_escape_text_and_leave_state_untouched(builder, state):
    before = deepcopy(state)
    view = builder(state)
    for layout in LAYOUTS:
        assert builder(state, layout=LayoutView(mode=layout)).to_dict()["components"] == \
            view.to_dict()["components"]
    assert state == before
    html = render_html(view)
    assert "<script>" not in html and "<b>" not in html and "<i>" not in html
    assert "&lt;b&gt;" in html or "&lt;i&gt;" in html
    assert "owner_id" not in encoded(view) and "ciphertext" not in encoded(view)
    assert view.surface == "guidance"


@pytest.mark.parametrize("builder,unavailable", [
    (build_skills_view, "Skills are unavailable"), (build_declarative_agents_view, "Agents are unavailable"),
    (build_selection_form, "Selections are unavailable"),
])
@pytest.mark.parametrize("state", [None, "ready", {"status": "mystery"}, {"status": "ready"},
                                   {"status": "ready", "mode": "list", "extra": "PRIVATE"}])
def test_untyped_or_unknown_state_renders_no_rows_and_no_diagnostics(builder, unavailable, state):
    view = builder(state)
    assert unavailable in render_html(view) and "PRIVATE" not in encoded(view)
    assert not forms(view) and not buttons(view)


@pytest.mark.parametrize("builder", [build_skills_view, build_declarative_agents_view, build_selection_form])
@pytest.mark.parametrize("status", ["loading", "unavailable"])
def test_nonready_states_render_neither_forms_nor_commands(builder, status):
    view = builder({"status": status, "mode": "list", "skills": [skill()]})
    assert not forms(view) and not buttons(view) and PRIVATE not in encoded(view)


# ---------------------------------------------------------------- skills

@pytest.mark.parametrize("mode", ["list", "new", "edit", "delete"])
def test_skill_commands_never_carry_instructions_and_navigation_carries_exact_identity(mode):
    view = build_skills_view(skills_state(mode))
    for payload in commands(view):
        assert "instructions" not in json.dumps(payload) and PRIVATE not in json.dumps(payload)
    for nav in buttons(view, "chrome_open"):
        params = nav["payload"]["params"]
        assert nav["payload"]["surface"] == "guidance" and params["view"] == "skills"
        assert set(params) <= {"view", "mode", "skill_id", "expected_revision"}
        if "skill_id" in params:
            assert params == {"view": "skills", "mode": params["mode"], "skill_id": SKILL,
                              "expected_revision": 4}
    if mode == "list":
        assert PRIVATE not in encoded(view)


@pytest.mark.parametrize("mode,revision,slug,label", [("new", 0, "", "Add skill"), ("edit", 4, "standup", "Save skill")])
def test_skill_save_form_submits_deep_field_names_and_exact_command_identity(mode, revision, slug, label):
    form, = forms(build_skills_view(skills_state(mode)))
    assert form["submit_action"] == "chrome_user_skill_save" and form["submit_label"] == label
    assert form["submit_payload"] == {"skill_id": OTHER if mode == "new" else SKILL,
                                      "command_id": OTHER_CMD if mode == "new" else CMD,
                                      "expected_revision": revision, "skill_slug": slug,
                                      "skill_enabled": "true"}
    fields = {item["name"]: item for item in form["fields"]}
    assert list(fields) == ["skill_name", "skill_command", "skill_applies", "skill_instructions"]
    assert fields["skill_instructions"]["kind"] == "textarea"
    if mode == "edit":
        assert fields["skill_applies"]["default"] == "web-research-1"
        assert PRIVATE in fields["skill_instructions"]["default"]
    else:
        assert all(fields[name]["default"] == "" for name in fields)


def test_skill_edit_payload_carries_current_enabled_flag_as_rendered():
    form, = forms(build_skills_view(skills_state("edit", skill=skill(enabled=False))))
    assert form["submit_payload"]["skill_enabled"] == "false"


@pytest.mark.parametrize("enabled,label", [(True, "Disable"), (False, "Enable")])
def test_skill_toggle_is_an_explicit_target_state_with_command_id(enabled, label):
    toggle, = buttons(build_skills_view(skills_state(skills=[skill(enabled=enabled)])), "chrome_user_skill_toggle")
    assert toggle["label"] == label
    assert toggle["payload"] == {"skill_id": SKILL, "command_id": CMD, "expected_revision": 4,
                                 "enabled": not enabled}


def test_skill_delete_requires_separate_review_with_identity_only():
    listing = build_skills_view(skills_state())
    delete = next(item for item in buttons(listing, "chrome_open") if item["label"] == "Delete")
    assert delete["payload"]["params"] == {"view": "skills", "mode": "delete", "skill_id": SKILL,
                                           "expected_revision": 4}
    review = build_skills_view(skills_state("delete"))
    command, = buttons(review, "chrome_user_skill_delete")
    assert command["payload"] == {"skill_id": SKILL, "command_id": CMD, "expected_revision": 4}
    assert "cannot be undone" in render_html(review) and PRIVATE not in encoded(review)


def test_skill_list_hides_add_at_the_twenty_skill_bound_and_refuses_twenty_one():
    full = [skill(skill_id=f"{i:08x}-0000-4000-8000-0000000000{i:02x}",
                  command_id=f"{i:08x}-1111-4000-8000-0000000000{i:02x}", slug=f"s{i}") for i in range(20)]
    view = build_skills_view(skills_state(skills=full))
    assert not any(item["label"] == "Add skill" for item in buttons(view))
    assert "up to 20 skills" in render_html(view)
    over = build_skills_view(skills_state(skills=[*full, skill(slug="extra")]))
    assert "unavailable" in render_html(over) and not buttons(over)


@pytest.mark.parametrize("bad", [
    {"skill_id": "bad"}, {"command_id": SKILL}, {"revision": 0}, {"revision": 2**53 - 1}, {"revision": "4"},
    {"slug": "Bad Slug"}, {"slug": ""}, {"name": "x" * 61}, {"name": ""}, {"command": "/standup"},
    {"command": "x" * 25}, {"applies_to": ["a"] * 9}, {"applies_to": ["dup", "dup"]}, {"applies_to": ["bad id"]},
    {"applies_to": "web-research-1"}, {"enabled": 1}, {"instructions": "x" * 4001}, {"instructions": "bad\x00"},
    {"owner_id": "private-owner"},
])
def test_invalid_skill_refuses_entire_snapshot_without_partial_text(bad):
    view = build_skills_view(skills_state(skills=[skill(skill_id=OTHER, command_id=OTHER_CMD, slug="other"),
                                                  skill(**bad)]))
    assert "unavailable" in render_html(view) and "Standup" not in encoded(view) and not buttons(view)


@pytest.mark.parametrize("bad", [
    {"skills": [skill(), skill()]}, {"skills": [skill(), skill(command_id=OTHER_CMD)]},
    {"skills": [skill(), skill(skill_id=OTHER, command_id=OTHER_CMD)]}, {"skills": "private"},
    {"mode": "execute"}, {"notice": "PRIVATE"}, {"status": "mystery"},
])
def test_invalid_skill_listing_never_forwards_untrusted_diagnostics(bad):
    view = build_skills_view(skills_state(**bad))
    assert "unavailable" in render_html(view) and "PRIVATE" not in encoded(view)


def test_new_skill_refuses_shared_or_invalid_identities():
    assert not forms(build_skills_view(skills_state("new", command_id=OTHER)))
    assert not forms(build_skills_view(skills_state("new", skill_id="bad")))


@pytest.mark.parametrize("notice", ["saved", "enabled", "disabled", "deleted"])
def test_skill_notices_are_closed_server_owned_text(notice):
    view = build_skills_view(skills_state(notice=notice))
    assert any(item.get("variant") == "success" for item in nodes(view.to_dict()))


# ---------------------------------------------------------------- declarative agents

def test_declarative_builder_is_reexported_from_agents_module():
    assert reexported is build_declarative_agents_view


@pytest.mark.parametrize("mode", ["list", "history", "new", "revise", "clone", "activate", "archive", "delete"])
def test_declarative_commands_are_closed_request_shapes_with_exact_ids(mode):
    view = build_declarative_agents_view(agents_state(mode))
    shapes = {
        "create": {"version", "command", "command_id", "agent_id", "revision_id"},
        "revise": {"version", "command", "command_id", "agent_id", "expected_revision", "revision_id",
                   "parent_revision_id"},
        "clone": {"version", "command", "command_id", "agent_id", "revision_id", "source_agent_id",
                  "source_revision_id"},
        "activate": {"version", "command", "command_id", "agent_id", "expected_revision", "revision_id"},
        "archive": {"version", "command", "command_id", "agent_id", "expected_revision"},
        "delete": {"version", "command", "command_id", "agent_id", "expected_revision"},
    }
    for payload in commands(view):
        assert payload["version"] == 1 and set(payload) == shapes[payload["command"]]
        assert payload["command_id"] == CMD
        for key in ("revision_id", "parent_revision_id", "source_revision_id", "agent_id", "source_agent_id"):
            if key in payload:
                assert str(UUID(payload[key])) == payload[key]
        assert "definition" not in payload and "display_name" not in payload
    for nav in buttons(view, "chrome_declarative_view"):
        assert set(nav["payload"]) <= {"mode", "agent_id", "revision_id", "expected_revision",
                                       "before_revision_number"}
        assert nav["payload"]["mode"] in {"list", "history", "new", "revise", "clone", "activate",
                                          "archive", "delete"}
    assert not buttons(view, "chrome_open")


def test_history_activate_is_a_separate_review_and_the_active_revision_has_no_activate():
    history = build_declarative_agents_view(agents_state("history"))
    activates = [item for item in buttons(history, "chrome_declarative_view") if item["label"] == "Activate"]
    assert [item["payload"] for item in activates] == [
        {"mode": "activate", "agent_id": AGENT, "revision_id": REV1, "expected_revision": 6}]
    assert "Active" in render_html(history) and PRIVATE not in encoded(history)
    review = build_declarative_agents_view(agents_state("activate"))
    command, = buttons(review, "chrome_declarative_command")
    assert command["payload"] == {"version": 1, "command": "activate", "command_id": CMD, "agent_id": AGENT,
                                  "expected_revision": 6, "revision_id": REV1}
    assert not forms(build_declarative_agents_view(agents_state("activate", revision=revision())))


@pytest.mark.parametrize("mode,command,expected", [
    ("new", "create", {"agent_id": OTHER, "revision_id": FRESH}),
    ("revise", "revise", {"agent_id": AGENT, "expected_revision": 6, "revision_id": FRESH,
                          "parent_revision_id": REV2}),
    ("clone", "clone", {"agent_id": OTHER, "revision_id": FRESH, "source_agent_id": AGENT,
                        "source_revision_id": REV2}),
])
def test_definition_forms_submit_exact_identities_and_literal_json(mode, command, expected):
    form, = forms(build_declarative_agents_view(agents_state(mode)))
    assert form["submit_action"] == "chrome_declarative_command"
    assert form["submit_payload"] == {"version": 1, "command": command, "command_id": CMD, **expected}
    fields = {item["name"]: item for item in form["fields"]}
    assert list(fields) == (["display_name"] if mode == "clone" else ["display_name", "definition"])
    if mode == "revise":
        assert json.loads(fields["definition"]["default"]) == {"version": 1, "note": PRIVATE}
        assert fields["display_name"]["default"] == "Scout <i>"
    if mode == "clone":
        assert fields["display_name"]["default"] == "Scout <i> (copy)"


def test_archived_head_offers_history_clone_delete_only_and_refuses_revise_or_archive_reviews():
    archived = head(status="archived", selected_revision_id=None)
    view = build_declarative_agents_view(agents_state(agents=[archived]))
    assert [item["label"] for item in buttons(view)] == ["New agent", "History", "Clone", "Delete", "Refresh"]
    for mode in ("revise", "archive"):
        refused = build_declarative_agents_view(agents_state(mode, agent=archived))
        assert "unavailable" in render_html(refused) and not buttons(refused)
    assert buttons(build_declarative_agents_view(agents_state("delete", agent=archived)),
                   "chrome_declarative_command")


def test_history_paging_keeps_exact_cursor_and_refuses_out_of_order_revisions():
    view = build_declarative_agents_view(agents_state("history", next_before=1))
    older, = [item for item in buttons(view) if item["label"] == "Older revisions"]
    assert older["payload"] == {"mode": "history", "agent_id": AGENT, "before_revision_number": 1}
    disordered = agents_state("history", revisions=[revision(1, REV1, None), revision()])
    assert not buttons(build_declarative_agents_view(disordered))
    assert not buttons(build_declarative_agents_view(agents_state("history", next_before=3)))


@pytest.mark.parametrize("bad", [
    {"agent_id": "bad"}, {"display_name": ""}, {"display_name": "x" * 121}, {"status": "live"},
    {"status": "draft"}, {"selected_revision_id": None}, {"state_revision": -1}, {"state_revision": "6"},
    {"updated_at": -1}, {"owner_id": "private-owner"},
])
def test_invalid_head_refuses_the_entire_listing(bad):
    view = build_declarative_agents_view(agents_state(agents=[head(agent_id=OTHER), head(**bad)]))
    assert "unavailable" in render_html(view) and "Scout" not in encoded(view)


@pytest.mark.parametrize("bad", [
    {"revision_id": "bad"}, {"agent_id": OTHER}, {"revision_number": 0}, {"parent_revision_id": REV2},
    {"definition_digest": "A" * 64}, {"definition_digest": "a" * 63}, {"definition": {"note": "no version"}},
    {"definition": {"version": 1, "big": "x" * (64 * 1024)}}, {"definition": {"version": 1, "bad": "\x00"}},
    {"created_at": None},
])
def test_invalid_revision_refuses_history_and_revise(bad):
    for mode in ("history", "revise"):
        state = agents_state(mode)
        target = state["revisions"][0] if mode == "history" else state["revision"]
        target.update(bad)
        view = build_declarative_agents_view(state)
        assert "unavailable" in render_html(view) and PRIVATE not in encoded(view)


def test_fresh_identities_must_be_distinct_from_each_other_and_from_the_head():
    assert not forms(build_declarative_agents_view(agents_state("new", revision_id=OTHER)))
    assert not forms(build_declarative_agents_view(agents_state("revise", revision_id=REV2)))
    assert not forms(build_declarative_agents_view(agents_state("clone", agent_id=AGENT)))
    assert not buttons(build_declarative_agents_view(agents_state("archive", command_id=AGENT)))


def test_agent_listing_bound_is_fifty_heads():
    heads = [head(agent_id=f"{i:08x}-2222-4000-8000-0000000000{i:02x}") for i in range(50)]
    assert len(buttons(build_declarative_agents_view(agents_state(agents=heads)))) == 2 + 50 * 5
    over = build_declarative_agents_view(agents_state(agents=[*heads, head(agent_id=OTHER)]))
    assert not buttons(over)


# ---------------------------------------------------------------- selection picker

def test_every_selection_command_is_the_complete_version_one_shape():
    view = build_selection_form(selection_state())
    assert SELECTION_DISCLOSURE in render_html(view) and "Use for this chat" in render_html(view)
    payloads = [item["payload"] for item in buttons(view, "chrome_turn_selection_set")]
    assert len(payloads) == 3 and not forms(view)
    assert not any(selected_ids(payload) for payload in payloads)
    assert payloads[0] == {"version": 1, "agent": {"agent_id": AGENT, "revision_id": REV2}, "skills": [], "notes": []}
    assert payloads[1] == {"version": 1, "agent": None, "skills": [{"skill_id": SKILL, "revision": 4}], "notes": []}
    assert payloads[2] == {"version": 1, "agent": None, "skills": [], "notes": [{"note_id": NOTE, "revision": 3}]}
    assert not [item for item in buttons(view) if item["label"] == "Clear selection"]


def test_current_selection_yields_remove_buttons_and_an_empty_clear_shape():
    state = selection_state(selected={"agent": {"agent_id": AGENT, "revision_id": REV2},
                                      "skills": [{"skill_id": SKILL, "revision": 4}],
                                      "notes": [{"note_id": NOTE, "revision": 3}]})
    view = build_selection_form(state)
    labelled = {item["label"]: item["payload"] for item in buttons(view, "chrome_turn_selection_set")}
    assert set(labelled) == {"Stop using this agent", "Remove skill", "Remove note", "Clear selection"}
    assert labelled["Stop using this agent"]["agent"] is None and labelled["Stop using this agent"]["skills"]
    assert labelled["Remove skill"] == {"version": 1, "agent": {"agent_id": AGENT, "revision_id": REV2},
                                        "skills": [], "notes": [{"note_id": NOTE, "revision": 3}]}
    assert selected_ids(labelled["Clear selection"])
    assert all(selected_ids(payload) is False for label, payload in labelled.items() if label != "Clear selection")
    assert "Selected" in render_html(view)


def test_disabled_offers_are_visible_but_not_selectable_and_note_values_never_appear():
    view = build_selection_form(selection_state())
    assert "Off" in render_html(view) and "Disabled" in render_html(view)
    assert all(OTHER not in json.dumps(item["payload"]) for item in buttons(view, "chrome_turn_selection_set"))
    assert "value" not in encoded(view) and "instructions" not in encoded(view)
    assert "Preference" in render_html(view)


def test_stale_or_foreign_selection_renders_no_picker():
    for selected in ({"agent": {"agent_id": AGENT, "revision_id": REV1}, "skills": [], "notes": []},
                     {"agent": None, "skills": [{"skill_id": SKILL, "revision": 5}], "notes": []},
                     {"agent": None, "skills": [], "notes": [{"note_id": OTHER, "revision": 3}]},
                     {"agent": None, "skills": [{"skill_id": SKILL, "revision": 4}] * 2, "notes": []},
                     {"agent": None, "skills": []}):
        view = build_selection_form(selection_state(selected=selected))
        assert "unavailable" in render_html(view) and not buttons(view)


def test_selection_bounds_are_twenty_agents_twenty_skills_eight_notes():
    def many(kind, count, entry):
        return [entry(f"{i:08x}-3333-4000-8000-0000000000{i:02x}") for i in range(count)]
    agents = many("agents", 21, lambda i: {"agent_id": i, "revision_id": REV2, "display_name": "A"})
    skills = many("skills", 21, lambda i: {"skill_id": i, "revision": 1, "name": "S", "command": "", "enabled": True})
    notes = many("notes", 9, lambda i: {"note_id": i, "revision": 1, "category": "goal", "enabled": True})
    within = build_selection_form(selection_state(agents=agents[:20], skills=skills[:20], notes=notes[:8]))
    assert len(buttons(within, "chrome_turn_selection_set")) == 48
    for bad in ({"agents": agents}, {"skills": skills}, {"notes": notes}):
        assert not buttons(build_selection_form(selection_state(**bad)))


def test_selection_with_eight_notes_chosen_offers_no_further_add():
    notes = [{"note_id": f"{i:08x}-4444-4000-8000-0000000000{i:02x}", "revision": 1, "category": "goal",
              "enabled": True} for i in range(8)]
    chosen = [{"note_id": note["note_id"], "revision": 1} for note in notes]
    view = build_selection_form(selection_state(notes=notes, selected={"agent": None, "skills": [], "notes": chosen}))
    labels = [item["label"] for item in buttons(view, "chrome_turn_selection_set")]
    assert labels.count("Remove note") == 8 and "Add note" not in labels


def test_empty_offers_render_captions_and_only_a_refresh():
    view = build_selection_form(selection_state(agents=[], skills=[], notes=[]))
    assert [item["action"] for item in buttons(view)] == ["chrome_open"]
    assert buttons(view)[0]["payload"] == {"surface": "guidance", "params": {"view": "selection"}}
    assert "No skills to select" in render_html(view)


@pytest.mark.parametrize("bad", [
    {"agents": [{"agent_id": AGENT, "revision_id": AGENT, "display_name": "A"}]},
    {"skills": [{"skill_id": SKILL, "revision": 0, "name": "S", "command": "", "enabled": True}]},
    {"skills": [{"skill_id": SKILL, "revision": 1, "name": "S", "command": "Bad", "enabled": True}]},
    {"notes": [{"note_id": NOTE, "revision": 1, "category": "preference", "enabled": True, "value": "PRIVATE"}]},
    {"notes": [{"note_id": NOTE, "revision": 1, "category": "authority", "enabled": True}]},
    {"selected": "PRIVATE"}, {"notice": "PRIVATE"},
])
def test_invalid_selection_offers_refuse_the_form_without_diagnostics(bad):
    view = build_selection_form(selection_state(**bad))
    assert "unavailable" in render_html(view) and "PRIVATE" not in encoded(view)


def test_empty_listings_and_pages_say_so_without_claiming_more():
    assert "No skills yet" in render_html(build_skills_view(skills_state(skills=[])))
    assert "No agents yet" in render_html(build_declarative_agents_view(agents_state(agents=[])))
    paged = build_declarative_agents_view(agents_state("history", revisions=[], next_before=1))
    assert "No revisions on this page" in render_html(paged) and "No revisions yet" not in render_html(paged)
    first = build_declarative_agents_view(agents_state("history", revisions=[]))
    assert "No revisions yet" in render_html(first)


@pytest.mark.parametrize("builder,state,notices", [
    (build_declarative_agents_view, agents_state(), ["created", "revised", "activated", "archived", "cloned", "deleted"]),
    (build_selection_form, selection_state(), ["saved", "cleared"]),
])
def test_agent_and_selection_notices_are_closed_server_owned_text(builder, state, notices):
    for notice in notices:
        view = builder({**state, "notice": notice})
        assert [item for item in nodes(view.to_dict()) if item.get("variant") == "success"]
    assert "PRIVATE" not in encoded(builder({**state, "notice": "PRIVATE"}))


# ---------------------------------------------------------------- dispatcher

def test_guidance_dispatcher_routes_on_the_closed_view_key_and_defaults_to_notes():
    assert set(GUIDANCE_VIEWS) == {"skills", "agents", "selection"}
    assert build_guidance_view({"view": "skills", **skills_state()}).title == "My skills"
    assert build_guidance_view({"view": "agents", **agents_state()}).title == "My agents"
    assert build_guidance_view({"view": "selection", **selection_state()}).title == "Use for this chat"
    notes = {"status": "ready", "mode": "list", "notes": [], "search": "", "next_cursor": None}
    assert build_guidance_view(notes).title == "Private notes"
    assert build_guidance_view(notes).to_dict() == build_notes_view(notes).to_dict()
    for view in ("notes", "work", None):
        assert "unavailable" in render_html(build_guidance_view({"view": view, **notes}))
    assert "unavailable" in render_html(build_guidance_view(None))
