"""Browser contract fixtures rendered by the actual shared Projection builder."""
import json
import sys
from pathlib import Path

projection_root = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(projection_root / "src"), str(projection_root)]

from astralprojection.chrome import render_html  # noqa: E402
from astralprojection.chrome.assignments import build_assignments_view  # noqa: E402

IDENTITY = "11111111-1111-4111-8111-111111111111"
SUBMISSION = "22222222-2222-4222-8222-222222222222"
ACTION = "33333333-3333-4333-8333-333333333333"
ACTIONS = [f"chrome_assignment_{suffix}" for suffix in
           ("create", "revise", "pause", "resume", "stop", "revoke", "run_now", "approval_decide")]

row = {
    "assignment_id": IDENTITY, "instruction_revision": 2, "control_epoch": 3,
    "lifecycle": "active", "phase": "waiting_approval", "available_actions": ACTIONS,
    "submission_ids": dict.fromkeys(ACTIONS, SUBMISSION),
    "latest_result": '<img src="x" onerror="window.assignmentInjected=true"> is untrusted external text.',
    "definition": {"name": "Release monitor", "instructions": "Report meaningful new releases.",
                   "source_key": "public_page", "source_url": "https://example.org/releases",
                   "allowed_tools": ["web-research-1:fetch_page"], "conversation_id": "conversation-1"},
    "approvals": [{"action_id": ACTION, "request_digest": "a" * 64, "state": "proposed",
                   "instruction_revision": 2, "control_epoch": 3, "expired": False,
                   "expires_at": "2099-01-01T00:00:00Z", "tool_label": "reviewed:write",
                   "arguments_summary": "Update the release note.", "consequence": "Changes one release note.",
                   "interactive_only": True, "submission_ids": {"approve": SUBMISSION, "decline": SUBMISSION}}],
}
state = {
    "enabled": True, "execution_enabled": True, "mode": sys.argv[1], "assignment": row,
    "assignments": [row], "available_actions": ACTIONS, "submission_ids": dict.fromkeys(ACTIONS, SUBMISSION),
    "source_options": ["public_page"], "tool_options": ["web-research-1:fetch_page", "reader:read"],
    "limit_fields": [{"name": "daily.tool_calls", "label": "Daily tool calls", "value": 20},
                     {"name": "lifetime.tool_calls", "label": "Lifetime tool calls", "value": 200}],
}
if sys.argv[1] == "error":
    state.update(mode="detail", error="The instruction revision changed. Reload the current assignment.")
if sys.argv[1] == "expired":
    state["mode"] = "detail"
    row["approvals"][0]["expired"] = True
print(json.dumps({"html": render_html(build_assignments_view(state)), "assignment_id": IDENTITY,
                  "submission_id": SUBMISSION, "action_id": ACTION}, ensure_ascii=False))
