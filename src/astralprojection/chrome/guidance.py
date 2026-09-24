"""Pure view builders for private notes, skills, declarative agents and the per-chat
selection picker, all over closed host-authorized snapshots; the host re-authorizes
every command before delivery.
"""

from __future__ import annotations

from collections.abc import Mapping
from datetime import datetime, timedelta, timezone
import json
import re
import unicodedata
from uuid import UUID

from astralprojection.models import ChromeViewModel, LayoutView, ThemeView

from ._components import alert, badge, build_view, bullet_list, button, card, container, field, form, text

NOTE_CATEGORY_LABELS = {
    "profession": "Profession", "goal": "Goal", "preference": "Preference",
    "workflow_tag": "Workflow tag", "context": "Context",
}
_NOTICES = {"saved": "Note saved.", "enabled": "Note enabled.",
            "disabled": "Note disabled.", "forgotten": "Note forgotten."}
_NOTE_ERRORS = {
    "sensitive": "This note was not saved because it may contain sensitive information. "
                 "Remove personal or patient details and try again.",
    "privacy_unavailable": "This note was not saved because its privacy check is temporarily unavailable. "
                           "Try again shortly.",
    "changed": "This note changed since you opened it. Reopen the current version before editing.",
    "not_found": "This note is no longer available. Return to your current notes.",
}
_MAX = 2**53 - 1


def _require(condition):
    if not condition:
        raise ValueError("notes_view_unavailable")


def _identity(value):
    _require(type(value) is str)
    parsed = UUID(value)
    _require(parsed.version == 4 and str(parsed) == value)
    return value


def _integer(value, minimum=0, maximum=_MAX):
    _require(type(value) is int and minimum <= value <= maximum)


def _string(value, maximum, *, empty=False):
    _require(type(value) is str and (empty or bool(value)))
    _require(len(value.encode("utf-8")) <= maximum)
    _require(not any(unicodedata.category(char) in {"Cc", "Cs"} and char not in "\n\t"
                     for char in value))


def _note(value):
    _require(isinstance(value, Mapping) and set(value) == {
        "note_id", "revision", "category", "value", "enabled", "expires_at"})
    _identity(value["note_id"])
    _integer(value["revision"], 1, _MAX - 1)
    _require(type(value["category"]) is str and value["category"] in NOTE_CATEGORY_LABELS)
    _require(type(value["enabled"]) is bool)
    _string(value["value"], 4096)
    if value["expires_at"] is not None:
        _integer(value["expires_at"])
    return value


def _date(value):
    if value is None:
        return ""
    try:
        instant = datetime(1970, 1, 1, tzinfo=timezone.utc) + timedelta(milliseconds=value)
        return instant.isoformat(timespec="milliseconds").replace("+00:00", "Z")
    except OverflowError:
        return ""


def _nav(label, mode="list", **params):
    return button(label, "chrome_open", {"surface": "guidance", "params": {"mode": mode, **params}})


def _key(note):
    return {"note_id": note["note_id"], "expected_revision": note["revision"]}


def _summary(note):
    expiry = note["expires_at"]
    label = "No expiry" if expiry is None else ("Expires " + _date(expiry) if _date(expiry) else "Expiry is set")
    return [badge("Enabled" if note["enabled"] else "Disabled"),
            text(note["value"]), text(label, "caption")]


def _list(state):
    notes, search, cursor = state["notes"], state["search"], state["next_cursor"]
    _require(type(notes) in {tuple, list} and len(notes) <= 100)
    _string(search, 256, empty=True)
    if cursor is not None:
        _identity(cursor)
    for note in notes:
        _note(note)
    _require(len({note["note_id"] for note in notes}) == len(notes))
    components = [text("Private notes are guidance you can select for your work."),
                  _nav("Add note", "new"),
                  form([field("search", "Search notes", default=search)],
                       submit_action="chrome_note_search", submit_label="Search")]
    if not notes:
        components.append(text("No matching notes on this page." if search or cursor
                               else "No private notes yet."))
    for note in notes:
        components.append(card(NOTE_CATEGORY_LABELS[note["category"]], [*_summary(note),
            _nav("Edit", "edit", **_key(note)),
            button("Disable" if note["enabled"] else "Enable", "chrome_note_toggle",
                   {**_key(note), "enabled": not note["enabled"]}),
            _nav("Forget", "forget", **_key(note))]))
    if cursor is not None:
        components.append(_nav("Next page", after_id=cursor, search=search))
    components.append(_nav("Refresh", search=search))
    return components


def _editor(state):
    new = state["mode"] == "new"
    note = ({"note_id": _identity(state["note_id"]), "revision": 0, "category": "context",
             "value": "", "enabled": True, "expires_at": None} if new else _note(state["note"]))
    expiry_options = ["No expiry", "Set a date"] if new else ["Keep current expiry", "No expiry", "Set a date"]
    components = [_nav("Back to notes")]
    if not new:
        components.extend([text("Current note", "h3"), *_summary(note)])
    components.append(form([
        field("category", "Category", "select", default=NOTE_CATEGORY_LABELS[note["category"]],
              options=list(NOTE_CATEGORY_LABELS.values())),
        field("value", "Note", "textarea", default=note["value"],
              help_text="Describe your preferences or context. Do not include patient information."),
        field("enabled", "Enabled", "boolean", default=note["enabled"]),
        field("expiry", "Expiry", "select", default=expiry_options[0], options=expiry_options),
        field("expiry_date", "Expiry date (UTC)", default=_date(note["expires_at"]),
              help_text="Use a UTC date and time, for example 2026-12-31T23:59:00Z.",
              visible_when={"expiry": "Set a date"}),
    ], title="Add note" if new else "Edit note", submit_action="chrome_note_save",
        submit_label="Save note", submit_payload=_key(note)))
    return components


def _forget(state):
    note = _note(state["note"])
    return [_nav("Keep note"), card(NOTE_CATEGORY_LABELS[note["category"]], _summary(note)),
            alert("Forget permanently erases this note's current value. This cannot be undone.", "warning"),
            button("Forget note", "chrome_note_forget", _key(note), variant="danger")]


def build_notes_view(state: Mapping[str, object], *, theme: ThemeView | None = None,
                     layout: LayoutView | None = None) -> ChromeViewModel:
    try:
        _require(isinstance(state, Mapping))
        status = state.get("status")
        _require(type(status) is str and status in {"ready", "loading", "unavailable"})
        if status != "ready":
            components = [text("Loading private notes…") if status == "loading" else
                          alert(_NOTE_ERRORS.get(state.get("error"),
                                "Private notes are unavailable. Refresh to try again."), "error")]
            if status == "unavailable":
                components.append(_nav("Back to notes"))
        else:
            mode = state.get("mode")
            _require(type(mode) is str and mode in {"list", "new", "edit", "forget"})
            expected = ({"notes", "search", "next_cursor"} if mode == "list" else
                        {"note_id"} if mode == "new" else {"note"})
            _require(set(state) - {"notice"} == {"mode", "status", *expected})
            notice = state.get("notice")
            _require(notice is None or (type(notice) is str and notice in _NOTICES))
            components = (_list(state) if mode == "list" else
                          _forget(state) if mode == "forget" else _editor(state))
            if notice is not None:
                components.insert(0, alert(_NOTICES[notice], "success"))
    except (ValueError, TypeError, KeyError, AttributeError, UnicodeError):
        components = [alert("Private notes are unavailable. Refresh to try again.", "error")]
    return build_view("guidance", "Private notes", components, theme=theme, layout=layout)


_SKILL_NOTICES = {"saved": "Skill saved.", "enabled": "Skill enabled.",
                  "disabled": "Skill disabled.", "deleted": "Skill deleted."}
_SLUG_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$", re.ASCII)
_COMMAND_RE = re.compile(r"^[a-z][a-z0-9_-]{0,23}$", re.ASCII)
_AGENT_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,64}$", re.ASCII)
_DIGEST_RE = re.compile(r"^[0-9a-f]{64}$", re.ASCII)
MAX_SKILLS = 20
MAX_SKILL_APPLIES_TO = 8
MAX_SELECTED_NOTES = 8
MAX_DECLARATIVE_AGENTS = 50
MAX_DECLARATIVE_REVISIONS = 100
MAX_DEFINITION_BYTES = 64 * 1024
_SKILL_UNAVAILABLE = "Skills are unavailable. Refresh to try again."
_AGENTS_UNAVAILABLE = "Agents are unavailable. Refresh to try again."
_SELECTION_UNAVAILABLE = "Selections are unavailable. Refresh to try again."


def _chars(value, maximum, *, empty=False):
    _string(value, maximum * 4, empty=empty)
    _require(len(value) <= maximum)


def _skill(value):
    _require(isinstance(value, Mapping) and set(value) == {
        "skill_id", "command_id", "revision", "slug", "name", "command",
        "applies_to", "enabled", "instructions"})
    _identity(value["skill_id"])
    _identity(value["command_id"])
    _require(value["command_id"] != value["skill_id"])
    _integer(value["revision"], 1, _MAX - 1)
    _string(value["slug"], 80)
    _require(_SLUG_RE.fullmatch(value["slug"]) is not None)
    _chars(value["name"], 60)
    _require(type(value["command"]) is str
             and (value["command"] == "" or _COMMAND_RE.fullmatch(value["command"]) is not None))
    applies = value["applies_to"]
    _require(type(applies) in {tuple, list} and len(applies) <= MAX_SKILL_APPLIES_TO)
    for agent_id in applies:
        _require(type(agent_id) is str and _AGENT_ID_RE.fullmatch(agent_id) is not None)
    _require(len(set(applies)) == len(applies))
    _require(type(value["enabled"]) is bool)
    _chars(value["instructions"], 4000, empty=True)
    return value


def _skill_nav(label, mode="list", **params):
    return button(label, "chrome_open",
                  {"surface": "guidance", "params": {"view": "skills", "mode": mode, **params}})


def _skill_key(skill):
    return {"skill_id": skill["skill_id"], "command_id": skill["command_id"],
            "expected_revision": skill["revision"]}


def _skill_route(skill):
    return {"skill_id": skill["skill_id"], "expected_revision": skill["revision"]}


def _skill_summary(skill):
    applies = skill["applies_to"]
    parts = [badge("Enabled" if skill["enabled"] else "Disabled")]
    if skill["command"]:
        parts.append(text("/" + skill["command"], "caption"))
    parts.append(text("Applies to every chat" if not applies
                      else "Applies to agents: " + ", ".join(applies), "caption"))
    return parts


def _skills_list(state):
    skills = state["skills"]
    _require(type(skills) in {tuple, list} and len(skills) <= MAX_SKILLS)
    for skill in skills:
        _skill(skill)
    identities = [skill["skill_id"] for skill in skills] + [skill["command_id"] for skill in skills]
    _require(len(set(identities)) == len(identities))
    _require(len({skill["slug"] for skill in skills}) == len(skills))
    components = [text("Skills are standing instructions you can select for your work; "
                       "a /command makes one a shortcut you can type.")]
    if len(skills) < MAX_SKILLS:
        components.append(_skill_nav("Add skill", "new"))
    else:
        components.append(text(f"You can keep up to {MAX_SKILLS} skills. Delete one to add another.",
                               "caption"))
    if not skills:
        components.append(text("No skills yet."))
    for skill in skills:
        components.append(card(skill["name"], [*_skill_summary(skill),
            _skill_nav("Edit", "edit", **_skill_route(skill)),
            button("Disable" if skill["enabled"] else "Enable", "chrome_user_skill_toggle",
                   {**_skill_key(skill), "enabled": not skill["enabled"]}),
            _skill_nav("Delete", "delete", **_skill_route(skill))]))
    components.append(_skill_nav("Refresh"))
    return components


def _skills_editor(state):
    new = state["mode"] == "new"
    if new:
        skill = {"skill_id": _identity(state["skill_id"]), "command_id": _identity(state["command_id"]),
                 "revision": 0, "slug": "", "name": "", "command": "", "applies_to": [],
                 "enabled": True, "instructions": ""}
        _require(skill["skill_id"] != skill["command_id"])
    else:
        skill = _skill(state["skill"])
    components = [_skill_nav("Back to skills")]
    if not new:
        components.extend([text("Current skill", "h3"), *_skill_summary(skill)])
    components.append(form([
        field("skill_name", "Name", default=skill["name"],
              help_text="2 to 60 characters."),
        field("skill_command", "/command (optional)", default=skill["command"],
              help_text="Lowercase letters, digits, - or _; up to 24 characters."),
        field("skill_applies", "Applies to", default=", ".join(skill["applies_to"]),
              help_text="Leave empty for every chat, or list agent ids separated by commas."),
        field("skill_instructions", "Instructions", "textarea", default=skill["instructions"],
              help_text="Standing guidance in your own words. Do not include patient information."),
    ], title="Add skill" if new else "Edit skill", submit_action="chrome_user_skill_save",
        submit_label="Add skill" if new else "Save skill",
        submit_payload={**_skill_key(skill), "skill_slug": skill["slug"],
                        "skill_enabled": "true" if skill["enabled"] else "false"}))
    return components


def _skills_delete(state):
    skill = _skill(state["skill"])
    return [_skill_nav("Keep skill"), card(skill["name"], _skill_summary(skill)),
            alert("Delete permanently removes this skill and its /command. This cannot be undone.",
                  "warning"),
            button("Delete skill", "chrome_user_skill_delete", _skill_key(skill), variant="danger")]


def build_skills_view(state: Mapping[str, object], *, theme: ThemeView | None = None,
                      layout: LayoutView | None = None) -> ChromeViewModel:
    try:
        _require(isinstance(state, Mapping))
        status = state.get("status")
        _require(type(status) is str and status in {"ready", "loading", "unavailable"})
        if status != "ready":
            components = [text("Loading skills…") if status == "loading" else
                          alert(_SKILL_UNAVAILABLE, "error")]
        else:
            mode = state.get("mode")
            _require(type(mode) is str and mode in {"list", "new", "edit", "delete"})
            expected = ({"skills"} if mode == "list" else
                        {"skill_id", "command_id"} if mode == "new" else {"skill"})
            _require(set(state) - {"notice"} == {"mode", "status", *expected})
            notice = state.get("notice")
            _require(notice is None or (type(notice) is str and notice in _SKILL_NOTICES))
            components = (_skills_list(state) if mode == "list" else
                          _skills_delete(state) if mode == "delete" else _skills_editor(state))
            if notice is not None:
                components.insert(0, alert(_SKILL_NOTICES[notice], "success"))
    except (ValueError, TypeError, KeyError, AttributeError, UnicodeError):
        components = [alert(_SKILL_UNAVAILABLE, "error")]
    return build_view("guidance", "My skills", components, theme=theme, layout=layout)


_AGENT_NOTICES = {"created": "Agent created.", "revised": "Revision saved.",
                  "activated": "Revision activated.", "archived": "Agent archived.",
                  "cloned": "Agent cloned.", "deleted": "Agent deleted."}
_AGENT_STATUS_LABELS = {"draft": "Draft", "active": "Active", "archived": "Archived"}


def _agent_head(value):
    _require(isinstance(value, Mapping) and set(value) == {
        "agent_id", "display_name", "status", "state_revision", "selected_revision_id", "updated_at"})
    _identity(value["agent_id"])
    _chars(value["display_name"], 120)
    _require(type(value["status"]) is str and value["status"] in _AGENT_STATUS_LABELS)
    _integer(value["state_revision"], 0, _MAX - 1)
    selected = value["selected_revision_id"]
    _require((value["status"] == "active") == (selected is not None))
    if selected is not None:
        _identity(selected)
    if value["updated_at"] is not None:
        _integer(value["updated_at"])
    return value


def _definition_text(value, depth=0):
    _require(depth <= 32)
    if isinstance(value, Mapping):
        for key, item in value.items():
            _string(key, 256)
            _definition_text(item, depth + 1)
    elif type(value) in {tuple, list}:
        for item in value:
            _definition_text(item, depth + 1)
    elif type(value) is str:
        _string(value, MAX_DEFINITION_BYTES, empty=True)
    else:
        _require(value is None or type(value) in {bool, int, float})


def _definition(value):
    _require(isinstance(value, Mapping) and type(value.get("version")) is int)
    _definition_text(value)
    canonical = json.dumps(value, sort_keys=True, separators=(",", ":"),
                           ensure_ascii=False, allow_nan=False)
    _require(len(canonical.encode("utf-8")) <= MAX_DEFINITION_BYTES)
    return json.dumps(json.loads(canonical), sort_keys=True, indent=2, ensure_ascii=False)


def _agent_revision(value, agent):
    _require(isinstance(value, Mapping) and set(value) == {
        "revision_id", "agent_id", "revision_number", "parent_revision_id", "created_at",
        "definition_digest", "definition"})
    _identity(value["revision_id"])
    _require(value["agent_id"] == agent["agent_id"])
    _integer(value["revision_number"], 1, _MAX - 1)
    if value["parent_revision_id"] is not None:
        _identity(value["parent_revision_id"])
        _require(value["parent_revision_id"] != value["revision_id"])
    _integer(value["created_at"])
    _require(type(value["definition_digest"]) is str
             and _DIGEST_RE.fullmatch(value["definition_digest"]) is not None)
    _definition(value["definition"])
    return value


def _agent_nav(label, mode="list", *, variant="secondary", **params):
    return button(label, "chrome_declarative_view", {"mode": mode, **params}, variant=variant)


def _agent_command(command, command_id, agent_id, **extra):
    return {"version": 1, "command": command, "command_id": command_id, "agent_id": agent_id, **extra}


def _agent_summary(agent):
    parts = [badge(_AGENT_STATUS_LABELS[agent["status"]],
                   "success" if agent["status"] == "active" else "default")]
    if agent["selected_revision_id"] is not None:
        parts.append(text("Active revision " + agent["selected_revision_id"], "caption"))
    if agent["updated_at"] is not None and _date(agent["updated_at"]):
        parts.append(text("Updated " + _date(agent["updated_at"]), "caption"))
    return parts


def _agent_route(agent):
    return {"agent_id": agent["agent_id"], "expected_revision": agent["state_revision"]}


def _agents_list(state):
    agents = state["agents"]
    _require(type(agents) in {tuple, list} and len(agents) <= MAX_DECLARATIVE_AGENTS)
    for agent in agents:
        _agent_head(agent)
    _require(len({agent["agent_id"] for agent in agents}) == len(agents))
    components = [card("Declarative agents", [
        text("Save a reusable set of instructions and capabilities for your work."),
        text("Create a definition, review its revisions, then activate the version you want to select "
             "for a chat. Your usual permissions and approvals still apply.", "caption"),
        _agent_nav("New agent", "new", variant="primary"),
    ])]
    if not agents:
        components.append(card("No agents yet", [
            text("Create your first agent to keep its instructions and revision history in one place."),
            bullet_list(["Give the agent a name and define its job.",
                         "Save and review the definition before activating it.",
                         "Choose the active agent from your chat's selections."], ordered=True),
        ]))
    for agent in agents:
        actions = [_agent_nav("History", "history", agent_id=agent["agent_id"])]
        if agent["status"] != "archived":
            actions.append(_agent_nav("Revise", "revise", **_agent_route(agent)))
        actions.append(_agent_nav("Clone", "clone", agent_id=agent["agent_id"]))
        if agent["status"] != "archived":
            actions.append(_agent_nav("Archive", "archive", **_agent_route(agent)))
        actions.append(_agent_nav("Delete", "delete", **_agent_route(agent)))
        components.append(card(agent["display_name"], [*_agent_summary(agent),
                                                      container(actions, direction="row")]))
    components.append(_agent_nav("Refresh"))
    return components


def _agents_history(state):
    agent = _agent_head(state["agent"])
    revisions = state["revisions"]
    _require(type(revisions) in {tuple, list} and len(revisions) <= MAX_DECLARATIVE_REVISIONS)
    for revision in revisions:
        _agent_revision(revision, agent)
    numbers = [revision["revision_number"] for revision in revisions]
    _require(numbers == sorted(numbers, reverse=True) and len(set(numbers)) == len(numbers))
    _require(len({revision["revision_id"] for revision in revisions}) == len(revisions))
    before = state["next_before"]
    if before is not None:
        _integer(before, 1, _MAX - 1)
        _require(not numbers or before <= numbers[-1])
    components = [_agent_nav("Back to agents"), card(agent["display_name"], _agent_summary(agent)),
                  text("Revision history", "h3")]
    if not revisions:
        components.append(text("No revisions on this page." if before is not None
                               else "No revisions yet."))
    for revision in revisions:
        body = [text("Definition digest " + revision["definition_digest"], "caption")]
        if _date(revision["created_at"]):
            body.append(text("Created " + _date(revision["created_at"]), "caption"))
        if revision["revision_id"] == agent["selected_revision_id"]:
            body.append(badge("Active", "success"))
        elif agent["status"] != "archived":
            body.append(_agent_nav("Activate", "activate", agent_id=agent["agent_id"],
                                   revision_id=revision["revision_id"],
                                   expected_revision=agent["state_revision"]))
        body.append(_agent_nav("Clone this revision", "clone", agent_id=agent["agent_id"],
                               revision_id=revision["revision_id"]))
        components.append(card(f"Revision {revision['revision_number']}", body))
    if before is not None:
        components.append(_agent_nav("Older revisions", "history", agent_id=agent["agent_id"],
                                     before_revision_number=before))
    return components


def _definition_fields(display_name, definition_text):
    return [field("display_name", "Name", default=display_name, help_text="1 to 120 characters."),
            field("definition", "Definition (JSON)", "textarea", default=definition_text,
                  help_text="A versioned declarative definition. The server validates it "
                            "before storing an immutable revision.")]


def _agents_new(state):
    agent_id, revision_id, command_id = (_identity(state[key])
                                         for key in ("agent_id", "revision_id", "command_id"))
    _require(len({agent_id, revision_id, command_id}) == 3)
    template = {"version": 1, "purpose": "Describe the agent's goal.",
                "instructions": "Describe how the agent should approach its work.",
                "capabilities": [], "memory": {"mode": "none"}, "triggers": [{"kind": "manual"}],
                "limits": {}, "approvals": {"policy": "normal"}}
    return [_agent_nav("Back to agents"),
            form(_definition_fields("", _definition(template)), title="New agent",
                 description="Name this agent and customize the starter definition below. Saving creates "
                             "a draft revision with no tool access; review its capabilities before activation.",
                 submit_action="chrome_declarative_command", submit_label="Create agent",
                 submit_payload=_agent_command("create", command_id, agent_id, revision_id=revision_id))]


def _agents_revise(state):
    agent = _agent_head(state["agent"])
    _require(agent["status"] != "archived")
    revision = _agent_revision(state["revision"], agent)
    revision_id, command_id = _identity(state["revision_id"]), _identity(state["command_id"])
    _require(len({revision_id, command_id, revision["revision_id"], agent["agent_id"]}) == 4)
    return [_agent_nav("Back to agents"), card(agent["display_name"], _agent_summary(agent)),
            text(f"Revising from revision {revision['revision_number']}", "caption"),
            form(_definition_fields(agent["display_name"], _definition(revision["definition"])),
                 title="Revise agent", submit_action="chrome_declarative_command",
                 submit_label="Save revision",
                 submit_payload=_agent_command("revise", command_id, agent["agent_id"],
                                               expected_revision=agent["state_revision"],
                                               revision_id=revision_id,
                                               parent_revision_id=revision["revision_id"]))]


def _agents_clone(state):
    source = _agent_head(state["agent"])
    revision = _agent_revision(state["revision"], source)
    agent_id, revision_id, command_id = (_identity(state[key])
                                         for key in ("agent_id", "revision_id", "command_id"))
    _require(len({agent_id, revision_id, command_id, source["agent_id"], revision["revision_id"]}) == 5)
    return [_agent_nav("Back to agents"), card(source["display_name"], _agent_summary(source)),
            text(f"Cloning revision {revision['revision_number']} into a new agent", "caption"),
            form([field("display_name", "Name", default=source["display_name"] + " (copy)",
                        help_text="1 to 120 characters.")],
                 title="Clone agent", submit_action="chrome_declarative_command",
                 submit_label="Clone agent",
                 submit_payload=_agent_command("clone", command_id, agent_id, revision_id=revision_id,
                                               source_agent_id=source["agent_id"],
                                               source_revision_id=revision["revision_id"]))]


def _agents_activate(state):
    agent = _agent_head(state["agent"])
    _require(agent["status"] != "archived")
    revision = _agent_revision(state["revision"], agent)
    _require(revision["revision_id"] != agent["selected_revision_id"])
    command_id = _identity(state["command_id"])
    _require(command_id not in {agent["agent_id"], revision["revision_id"]})
    return [_agent_nav("Back to history", "history", agent_id=agent["agent_id"]),
            card(agent["display_name"], [*_agent_summary(agent),
                 text(f"Revision {revision['revision_number']}", "caption"),
                 text("Definition digest " + revision["definition_digest"], "caption")]),
            alert("Activating selects this exact revision for future work. It grants no access "
                  "and starts nothing.", "info"),
            button("Activate this revision", "chrome_declarative_command",
                   _agent_command("activate", command_id, agent["agent_id"],
                                  expected_revision=agent["state_revision"],
                                  revision_id=revision["revision_id"]), variant="primary")]


def _agents_review(state, command):
    agent = _agent_head(state["agent"])
    _require(command == "delete" or agent["status"] != "archived")
    command_id = _identity(state["command_id"])
    _require(command_id != agent["agent_id"])
    message = ("Archive keeps the history but the agent can no longer be selected."
               if command == "archive" else
               "Delete removes this agent and its history from your list. This cannot be undone.")
    return [_agent_nav("Keep agent"), card(agent["display_name"], _agent_summary(agent)),
            alert(message, "warning"),
            button("Archive agent" if command == "archive" else "Delete agent",
                   "chrome_declarative_command",
                   _agent_command(command, command_id, agent["agent_id"],
                                  expected_revision=agent["state_revision"]),
                   variant="danger")]


_AGENT_MODES = {
    "list": ({"agents"}, _agents_list),
    "history": ({"agent", "revisions", "next_before"}, _agents_history),
    "new": ({"agent_id", "revision_id", "command_id"}, _agents_new),
    "revise": ({"agent", "revision", "revision_id", "command_id"}, _agents_revise),
    "clone": ({"agent", "revision", "agent_id", "revision_id", "command_id"}, _agents_clone),
    "activate": ({"agent", "revision", "command_id"}, _agents_activate),
    "archive": ({"agent", "command_id"}, lambda state: _agents_review(state, "archive")),
    "delete": ({"agent", "command_id"}, lambda state: _agents_review(state, "delete")),
}


def build_declarative_agents_view(state: Mapping[str, object], *, theme: ThemeView | None = None,
                                  layout: LayoutView | None = None) -> ChromeViewModel:
    try:
        _require(isinstance(state, Mapping))
        status = state.get("status")
        _require(type(status) is str and status in {"ready", "loading", "unavailable"})
        if status != "ready":
            components = [text("Loading agents…") if status == "loading" else
                          alert(_AGENTS_UNAVAILABLE, "error")]
        else:
            mode = state.get("mode")
            _require(type(mode) is str and mode in _AGENT_MODES)
            expected, builder = _AGENT_MODES[mode]
            _require(set(state) - {"notice"} == {"mode", "status", *expected})
            notice = state.get("notice")
            _require(notice is None or (type(notice) is str and notice in _AGENT_NOTICES))
            components = builder(state)
            if notice is not None:
                components.insert(0, alert(_AGENT_NOTICES[notice], "success"))
    except (ValueError, TypeError, KeyError, AttributeError, UnicodeError, RecursionError):
        components = [alert(_AGENTS_UNAVAILABLE, "error")]
    return build_view("guidance", "My agents", components, theme=theme, layout=layout)


SELECTION_DISCLOSURE = (
    "Use for this chat: your selection applies to this chat only. Each task you send carries "
    "exactly the agent revision, skill revisions and note revisions listed here; the server "
    "rechecks them when the task is accepted and refuses anything changed or forgotten since.")
_SELECTION_NOTICES = {"saved": "Selection saved.", "cleared": "Selection cleared."}


def _selection_agent(value):
    _require(isinstance(value, Mapping) and set(value) == {"agent_id", "revision_id", "display_name"})
    _identity(value["agent_id"])
    _identity(value["revision_id"])
    _require(value["agent_id"] != value["revision_id"])
    _chars(value["display_name"], 120)
    return value


def _selection_skill(value):
    _require(isinstance(value, Mapping) and set(value) == {"skill_id", "revision", "name", "command", "enabled"})
    _identity(value["skill_id"])
    _integer(value["revision"], 1, _MAX - 1)
    _chars(value["name"], 60)
    _require(type(value["command"]) is str
             and (value["command"] == "" or _COMMAND_RE.fullmatch(value["command"]) is not None))
    _require(type(value["enabled"]) is bool)
    return value


def _selection_note(value):
    _require(isinstance(value, Mapping) and set(value) == {"note_id", "revision", "category", "enabled"})
    _identity(value["note_id"])
    _integer(value["revision"], 1, _MAX - 1)
    _require(type(value["category"]) is str and value["category"] in NOTE_CATEGORY_LABELS)
    _require(type(value["enabled"]) is bool)
    return value


def _offered(state, key, validator, maximum, identity):
    entries = state[key]
    _require(type(entries) in {tuple, list} and len(entries) <= maximum)
    for entry in entries:
        validator(entry)
    _require(len({entry[identity] for entry in entries}) == len(entries))
    return {entry[identity]: entry for entry in entries}


def _selected(state, agents, skills, notes):
    selected = state["selected"]
    _require(isinstance(selected, Mapping) and set(selected) == {"agent", "skills", "notes"})
    agent = selected["agent"]
    if agent is not None:
        _require(isinstance(agent, Mapping) and set(agent) == {"agent_id", "revision_id"})
        offered = agents.get(agent["agent_id"])
        _require(offered is not None and offered["revision_id"] == agent["revision_id"])
        agent = {"agent_id": agent["agent_id"], "revision_id": agent["revision_id"]}
    chosen = {"agent": agent, "skills": [], "notes": []}
    for kind, offered, identity in (("skills", skills, "skill_id"), ("notes", notes, "note_id")):
        entries = selected[kind]
        _require(type(entries) in {tuple, list} and len(entries) <= len(offered))
        for entry in entries:
            _require(isinstance(entry, Mapping) and set(entry) == {identity, "revision"})
            current = offered.get(entry[identity])
            _require(current is not None and current["revision"] == entry["revision"]
                     and entry[identity] not in {item[identity] for item in chosen[kind]})
            chosen[kind].append({identity: entry[identity], "revision": entry["revision"]})
    return chosen


# All-empty here means explicit clear, not leave-unchanged
def _selection_payload(chosen):
    return {"version": 1, "agent": None if chosen["agent"] is None else dict(chosen["agent"]),
            "skills": [dict(item) for item in chosen["skills"]],
            "notes": [dict(item) for item in chosen["notes"]]}


def _selection_button(label, chosen, **change):
    return button(label, "chrome_turn_selection_set", _selection_payload({**chosen, **change}),
                  variant="primary" if label.startswith(("Use", "Add")) else "secondary")


def _selection_form(state):
    agents = _offered(state, "agents", _selection_agent, MAX_SKILLS, "agent_id")
    skills = _offered(state, "skills", _selection_skill, MAX_SKILLS, "skill_id")
    notes = _offered(state, "notes", _selection_note, MAX_SELECTED_NOTES, "note_id")
    chosen = _selected(state, agents, skills, notes)
    picked = {"skills": {item["skill_id"] for item in chosen["skills"]},
              "notes": {item["note_id"] for item in chosen["notes"]}}
    components = [text(SELECTION_DISCLOSURE), text("Agent", "h3")]
    if not agents:
        components.append(text("No active agent revision to select.", "caption"))
    for agent in agents.values():
        reference = {"agent_id": agent["agent_id"], "revision_id": agent["revision_id"]}
        current = chosen["agent"] == reference
        components.append(card(agent["display_name"], [
            badge("Selected", "success") if current else badge("Available"),
            text("Revision " + agent["revision_id"], "caption"),
            _selection_button("Stop using this agent" if current else "Use this agent", chosen,
                              agent=None if current else reference)]))
    components.append(text("Skills", "h3"))
    if not skills:
        components.append(text("No skills to select.", "caption"))
    for skill in skills.values():
        current = skill["skill_id"] in picked["skills"]
        reference = {"skill_id": skill["skill_id"], "revision": skill["revision"]}
        body = [badge("Selected", "success") if current else
                badge("Enabled" if skill["enabled"] else "Disabled")]
        if skill["command"]:
            body.append(text("/" + skill["command"], "caption"))
        body.append(text(f"Revision {skill['revision']}", "caption"))
        if current:
            body.append(_selection_button("Remove skill", chosen, skills=[
                item for item in chosen["skills"] if item["skill_id"] != skill["skill_id"]]))
        elif skill["enabled"]:
            body.append(_selection_button("Add skill", chosen, skills=[*chosen["skills"], reference]))
        components.append(card(skill["name"], body))
    components.append(text("Private notes", "h3"))
    if not notes:
        components.append(text("No private notes to select.", "caption"))
    for note in notes.values():
        current = note["note_id"] in picked["notes"]
        reference = {"note_id": note["note_id"], "revision": note["revision"]}
        body = [badge("Selected", "success") if current else
                badge("Enabled" if note["enabled"] else "Disabled"),
                text(f"Revision {note['revision']}", "caption")]
        if current:
            body.append(_selection_button("Remove note", chosen, notes=[
                item for item in chosen["notes"] if item["note_id"] != note["note_id"]]))
        elif note["enabled"] and len(chosen["notes"]) < MAX_SELECTED_NOTES:
            body.append(_selection_button("Add note", chosen, notes=[*chosen["notes"], reference]))
        components.append(card(NOTE_CATEGORY_LABELS[note["category"]], body))
    if chosen["agent"] is not None or chosen["skills"] or chosen["notes"]:
        components.append(button("Clear selection", "chrome_turn_selection_set",
                                 _selection_payload({"agent": None, "skills": [], "notes": []}),
                                 variant="danger"))
    components.append(button("Refresh", "chrome_open",
                             {"surface": "guidance", "params": {"view": "selection"}}))
    return components


def build_selection_form(state: Mapping[str, object], *, theme: ThemeView | None = None,
                         layout: LayoutView | None = None) -> ChromeViewModel:
    try:
        _require(isinstance(state, Mapping))
        status = state.get("status")
        _require(type(status) is str and status in {"ready", "loading", "unavailable"})
        if status != "ready":
            components = [text("Loading your selection…") if status == "loading" else
                          alert(_SELECTION_UNAVAILABLE, "error")]
        else:
            _require(set(state) - {"notice"} == {"status", "agents", "skills", "notes", "selected"})
            notice = state.get("notice")
            _require(notice is None or (type(notice) is str and notice in _SELECTION_NOTICES))
            components = _selection_form(state)
            if notice is not None:
                components.insert(0, alert(_SELECTION_NOTICES[notice], "success"))
    except (ValueError, TypeError, KeyError, AttributeError, UnicodeError):
        components = [alert(_SELECTION_UNAVAILABLE, "error")]
    return build_view("guidance", "Use for this chat", components, theme=theme, layout=layout)


GUIDANCE_VIEWS = {"skills": build_skills_view, "agents": build_declarative_agents_view,
                  "selection": build_selection_form}


def build_guidance_view(state: Mapping[str, object], *, theme: ThemeView | None = None,
                        layout: LayoutView | None = None) -> ChromeViewModel:
    if isinstance(state, Mapping) and state.get("view") in GUIDANCE_VIEWS:
        builder = GUIDANCE_VIEWS[state["view"]]
        return builder({key: value for key, value in state.items() if key != "view"},
                       theme=theme, layout=layout)
    return build_notes_view(state, theme=theme, layout=layout)


__all__ = [
    "GUIDANCE_VIEWS", "NOTE_CATEGORY_LABELS", "SELECTION_DISCLOSURE",
    "build_declarative_agents_view", "build_guidance_view", "build_notes_view",
    "build_selection_form", "build_skills_view",
]
