"""Binds the Mac conversation turn actions and branch snapshot to the capability-gated additive
contract: new intents stay chat-scoped, the optional fields declare their exact carriers, and the
gating keeps every other client on its existing vocabulary.
"""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def _manifest():
    return json.loads((ROOT / "contracts/ui_protocol.json").read_text())


def test_turn_intents_are_manifested_sorted_and_chat_scoped():
    manifest = _manifest()
    actions = manifest["accept_actions"]
    assert actions == sorted(set(actions))
    intents = {"chat_fork", "chat_regenerate", "chat_branch_select"}
    assert intents <= set(actions)
    assert not intents & set(manifest["client_local_actions"])
    assert not intents & {push["name"] for push in manifest["push_types"]}


def test_edit_resend_names_the_revised_turn_and_the_summary_choice():
    manifest = _manifest()
    fields = {entry["field"]: entry for entry in manifest["additive_fields"]}
    revised = fields["revised_turn_id"]
    assert revised["carried_on"] == ["ui_event.chat_message"]
    assert "UUID4" in revised["shape"]
    departed = fields["summarize_departed"]
    assert set(departed["carried_on"]) == {
        "ui_event.chat_message",
        "ui_event.chat_fork",
        "ui_event.chat_regenerate",
        "ui_event.chat_branch_select",
    }
    assert departed["shape"] == "boolean"
    for entry in (revised, departed):
        assert "chat_branches_v1" in entry["contract"]
        assert "refuses" in entry["scope"] or "never" in entry["scope"]


def test_branch_snapshot_is_transcript_scoped_and_bounded():
    manifest = _manifest()
    fields = {entry["field"]: entry for entry in manifest["additive_fields"]}
    branch = fields["branch"]
    assert branch["carried_on"] == ["conversation_snapshot.transcript[]"]
    shape = branch["shape"]
    for required in ["group_id", "index", "count", "siblings", "50"]:
        assert required in shape
    assert "chat_branches_v1" in branch["contract"]
    assert "persists none" in branch["scope"]
