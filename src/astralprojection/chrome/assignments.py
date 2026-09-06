"""Pure persistent-assignment views over an explicitly authorized host snapshot.

``build_assignments_view`` accepts ``mode`` (list/create/revise/detail), ``enabled``,
``execution_enabled``, optional safe ``error``/``notice``, ``assignments`` or one
``assignment``. Rows carry assignment_id, instruction_revision, control_epoch,
lifecycle, phase, next_wake_at/wake_reason, last_check_at/latest_result,
grant_summary/grant_expires_at, limit_summary/usage_summary [{label,value}],
currency_cap_label/monetary_cost_label, and safe tasks/activity/approvals.

Definition is a display/form projection, not a Plane record: name, instructions,
source_key, source_url, optional source_arguments JSON / linked_document_urls text,
allowed_tools (portable tool identities), conversation_id,
completion_condition, currency_cap_enabled and currency. Create/revise state also
supplies source_options/tool_options, registered_reader_enabled,
limit_fields [{name,label,value,help}], and
optional activation_error. Limit fields use the host's canonical names, for example
daily.tool_calls and lifetime.tokens, emitted as limits.daily.tool_calls etc.

Both state and each row carry available_actions and submission_ids keyed by exact
action name. Approvals use action_id, request_digest, state, instruction_revision,
control_epoch, expires_at, expired, safe tool_label/target_label/arguments_summary/
consequence/preconditions_summary, interactive_only, and submission_ids keyed by
approve/decline. Raw arguments, tokens, grant IDs, claims, and arbitrary row fields
are never forwarded. The host validates every command; this module only renders.

LayoutView(mode="watch") selects bounded status/chat guidance and a full-client
handoff without forms or buttons. Optional next_cursor/activity_cursor are opaque
host pagination tokens. No IDs, permissions, quotes or clocks are generated here.
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from uuid import UUID

from astralprojection.models import ChromeViewModel, ComponentView, LayoutView, ThemeView

from ._components import alert, badge, build_view, button, card, container, field, form, key_value, text

_SURFACE = "personalization"
_TITLE = "Ongoing agents"
_PHASES = {
    "waiting": "Waiting", "checking": "Checking", "investigating": "Investigating",
    "delegating": "Delegating", "waiting_approval": "Waiting for approval",
    "waiting_authorization": "Authorization required", "budget_exhausted": "Budget exhausted",
    "reconciliation": "Reconciliation required", "failed": "Failed",
}
_LIFECYCLES = {"paused": "Paused", "stopped": "Stopped", "completed": "Completed"}
_CONTROLS = (
    ("pause", "Pause", "secondary"), ("resume", "Resume", "primary"),
    ("run_now", "Check now", "secondary"), ("revoke", "Revoke authorization", "secondary"),
    ("stop", "Stop", "danger"),
)
_LIMIT_NAME = re.compile(r"^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)?$")
_DIGEST = re.compile(r"^[a-f0-9]{64}$")


def _mapping(value: object) -> Mapping:
    return value if isinstance(value, Mapping) else {}


def _display(value: object, default: str = "") -> str:
    # Only a deliberate scalar projection is displayable, never repr(raw records).
    return str(value) if isinstance(value, (str, int, float)) and not isinstance(value, bool) else default


def _rows(value: object, limit: int) -> list[Mapping]:
    if not isinstance(value, (list, tuple)):
        return []
    return [item for item in value[:limit] if isinstance(item, Mapping)]


def _strings(value: object, limit: int = 100) -> list[str]:
    if not isinstance(value, (list, tuple)):
        return []
    return [item for item in value[:limit] if isinstance(item, str)]


def _uuid(value: object) -> str:
    try:
        candidate = UUID(str(value))
        return str(candidate) if candidate.version == 4 else ""
    except (ValueError, TypeError, AttributeError):
        return ""


def _version(value: object) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None


def _allowed(row: Mapping, action: str) -> bool:
    return action in _strings(row.get("available_actions"))


def _payload(row: Mapping, action: str, *, create: bool = False) -> dict | None:
    submission = _uuid(_mapping(row.get("submission_ids")).get(action))
    if not submission or not _allowed(row, action):
        return None
    result = {"submission_id": submission}
    if not create:
        identity = _uuid(row.get("assignment_id"))
        revision, epoch = _version(row.get("instruction_revision")), _version(row.get("control_epoch"))
        if not identity or revision is None or epoch is None:
            return None
        result.update(assignment_id=identity, expected_instruction_revision=revision, expected_control_epoch=epoch)
    return result


def _open(label: str, **params: object) -> ComponentView:
    return button(label, "chrome_open", {"surface": _SURFACE, "params": {"tab": "schedule", **params}})


def _status(row: Mapping) -> str:
    lifecycle = _display(row.get("lifecycle"))
    if lifecycle in _LIFECYCLES:
        return _LIFECYCLES[lifecycle]
    return _PHASES.get(_display(row.get("phase")), "Unknown state") if lifecycle == "active" else "Unknown state"


def _definition(row: Mapping) -> Mapping:
    return _mapping(row.get("definition"))


def _pairs(value: object) -> list[tuple[str, str]]:
    return [(_display(item.get("label")), _display(item.get("value"), "Unknown")) for item in _rows(value, 32)]


def _controls(row: Mapping, execution_enabled: bool) -> list[ComponentView]:
    lifecycle = row.get("lifecycle")
    if lifecycle not in {"active", "paused"}:
        return []
    result = []
    for suffix, label, variant in _CONTROLS:
        if suffix == "resume" and (lifecycle != "paused" or not execution_enabled):
            continue
        if suffix in {"pause", "run_now"} and lifecycle != "active":
            continue
        if suffix == "run_now" and not execution_enabled:
            continue
        action = f"chrome_assignment_{suffix}"
        payload = _payload(row, action)
        if payload:
            result.append(button(label, action, payload, variant=variant))
    if _allowed(row, "chrome_assignment_revise") and _uuid(row.get("assignment_id")):
        result.append(_open("Revise instructions", assignment_id=row["assignment_id"], assignment_mode="revise"))
    return result


def _summary(row: Mapping, *, wrist: bool = False) -> list[ComponentView]:
    definition = _definition(row)

    def display(value: object, default: str = "") -> str:
        rendered = _display(value, default)
        return rendered[:600] + "…" if wrist and len(rendered) > 600 else rendered

    result = [badge(_status(row)), text(display(row.get("latest_result"), "No findings yet."))]
    result.append(key_value([
        ("Source", display(definition.get("source_url")) or display(definition.get("source_key"), "Unavailable")),
        ("Next check", display(row.get("next_wake_at"), "No check scheduled")),
        ("Waiting for", display(row.get("wake_reason"), "No wake reason available")),
    ]))
    if not wrist:
        result.append(key_value([
            ("Instruction revision", _display(row.get("instruction_revision"), "Unknown")),
            ("Control version", _display(row.get("control_epoch"), "Unknown")),
            ("Last checked", _display(row.get("last_check_at"), "Not checked yet")),
            ("Currency cap", _display(row.get("currency_cap_label"), "No currency cap")),
            ("Monetary cost", _display(row.get("monetary_cost_label"), "Unpriced/unknown")),
            *_pairs(row.get("limit_summary")), *_pairs(row.get("usage_summary")),
        ]))
    for key, variant in (("safe_error", "warning"), ("in_flight_summary", "info")):
        if _display(row.get(key)):
            result.append(alert(display(row[key]), variant))
    return result


def _approval(row: Mapping, proposal: Mapping) -> ComponentView:
    status = _display(proposal.get("state"), "unknown")
    children = [badge(status), key_value([
        ("Operation", _display(proposal.get("tool_label"))),
        ("Target", _display(proposal.get("target_label"))),
        ("Parameters", _display(proposal.get("arguments_summary"))),
        ("Consequences", _display(proposal.get("consequence"))),
        ("Preconditions", _display(proposal.get("preconditions_summary"))),
        ("Expires", _display(proposal.get("expires_at"), "Unknown")),
        ("Instruction revision", _display(proposal.get("instruction_revision"))),
    ])]
    if proposal.get("interactive_only"):
        children.append(text("This operation runs through an attended session. The normal security checks may require additional review. Approval is not completion.", "caption"))
    action = "chrome_assignment_approval_decide"
    action_id = _uuid(proposal.get("action_id"))
    digest = _display(proposal.get("request_digest"))
    current = (
        row.get("lifecycle") == "active" and status == "proposed" and not proposal.get("expired")
        and proposal.get("instruction_revision") == row.get("instruction_revision")
        and proposal.get("control_epoch") == row.get("control_epoch")
        and action_id and _DIGEST.fullmatch(digest)
    )
    decisions = []
    if current:
        for decision, label in (("approve", "Approve exact action"), ("decline", "Decline")):
            proposal_ids = _mapping(proposal.get("submission_ids"))
            payload = _payload({**row, "submission_ids": {action: proposal_ids.get(decision)}}, action)
            if payload:
                payload.update(action_id=action_id, request_digest=digest, decision=decision)
                decisions.append(button(label, action, payload, variant="primary" if decision == "approve" else "secondary"))
    children.append(container(decisions, direction="row") if decisions else text("This proposal is not available for a decision. Reload the current assignment.", "caption"))
    return card("Action review", children)


def _detail(row: Mapping, execution_enabled: bool) -> list[ComponentView]:
    definition = _definition(row)
    result = [card(_display(definition.get("name"), "Ongoing agent"), _summary(row)),
              card("Standing instructions", [text(_display(definition.get("instructions"))), text(_display(definition.get("completion_condition")), "caption")]),
              key_value([("Permitted tools", ", ".join(_strings(definition.get("allowed_tools")))),
                         ("Authorization", _display(row.get("grant_summary"), "Authorization required")),
                         ("Grant expires", _display(row.get("grant_expires_at"), "Unknown")),
                         ("Conversation", _display(definition.get("conversation_id")))]),
              container(_controls(row, execution_enabled), direction="row")]
    result.extend(_approval(row, proposal) for proposal in _rows(row.get("approvals"), 100))
    for task in _rows(row.get("tasks"), 32):
        result.append(card(_display(task.get("title"), "Task"), [
            badge(_display(task.get("state"), "unknown")), text(_display(task.get("result"))),
            text(_display(task.get("provenance_summary")), "caption"),
            text("Incorporated" if task.get("incorporated") else "Not yet incorporated", "caption"),
            text(_display(task.get("dependency_summary")), "caption"),
        ]))
    activity = _rows(row.get("activity"), 50)
    result.append(text("Activity", "h3"))
    for item in activity:
        result.append(card(_display(item.get("title"), "Activity"), [
            text(_display(item.get("summary"))), text(_display(item.get("created_at")), "caption"),
        ]))
    if not activity:
        result.append(text("No activity yet. Unchanged checks update Last checked quietly.", "caption"))
    cursor = _display(row.get("activity_cursor"))
    if cursor:
        result.append(_open("More activity", assignment_id=row["assignment_id"], activity_cursor=cursor))
    result.append(_open("Back to Schedule"))
    return result


def _form(state: Mapping, row: Mapping, mode: str) -> list[ComponentView]:
    definition = _definition(row)
    action = f"chrome_assignment_{mode}"
    subject = state if mode == "create" else row
    payload = _payload(subject, action, create=mode == "create")
    sources, tools = _strings(state.get("source_options")), _strings(state.get("tool_options"))
    limits = _rows(state.get("limit_fields"), 32)
    error = _display(state.get("activation_error"))
    raw_limits = state.get("limit_fields")
    complete_limits = isinstance(raw_limits, (list, tuple)) and len(raw_limits) == len(limits)
    terminal = mode == "revise" and row.get("lifecycle") not in {"active", "paused"}
    if error or not payload or not sources or not tools or not limits or not complete_limits or terminal:
        return [alert(error or "The complete authorized source, limits and review controls are not available. Reload before approving.", "warning"), _open("Back to Schedule")]
    limit_fields = []
    seen = set()
    for item in limits:
        name = _display(item.get("name"))
        value = item.get("value")
        if name in seen or not _LIMIT_NAME.fullmatch(name) or (value is not None and (isinstance(value, bool) or not isinstance(value, int) or value < 0)):
            return [alert("Resource limit fields are invalid. Reload before approving.", "warning")]
        seen.add(name)
        limit_fields.append(field(f"limits.{name}", _display(item.get("label"), name), "number", default=value, help_text=_display(item.get("help"))))
    fields = [
        field("name", "Name", default=_display(definition.get("name"))),
        field("instructions", "Standing instructions", "textarea", default=_display(definition.get("instructions"))),
        field("completion_condition", "Completion condition (optional)", default=_display(definition.get("completion_condition"))),
        field("source_key", "Source reader", "select", options=sources, default=_display(definition.get("source_key")) or sources[0]),
        field("source_url", "Source URL", default=_display(definition.get("source_url"))),
        *([field("source_arguments", "Connected reader selection (JSON)", "textarea",
                 default=_display(definition.get("source_arguments")),
                 help_text="For a connected reader; the public page uses Source URL.")]
          if state.get("registered_reader_enabled") else []),
        field("linked_document_urls", "Reviewed linked document URLs (optional, one per line)", "textarea",
              default=_display(definition.get("linked_document_urls")),
              help_text="Only these additional public URLs may be read; no automatic permission to follow other links."),
        field("allowed_tools", "Permitted tools", "checklist", options=tools, default=_strings(definition.get("allowed_tools"))),
        field("conversation_id", "Result conversation", default=_display(definition.get("conversation_id"))),
        *limit_fields,
        field("currency_cap_enabled", "Use a currency spending cap (optional)", "boolean", default=definition.get("currency_cap_enabled") is True),
        field("currency", "Currency when a cap is selected", default=_display(definition.get("currency"))),
        field("consent", "I approve these instructions, source, tools, limits and revocable unattended authorization", "boolean", default=False),
    ]
    return [
        card("Review unattended authorization", [
            text("This ongoing agent may act while you are signed out under a revocable grant. Review all fields before approving. Pause, stop or revoke authorization at any time in Schedule."),
            text(_display(row.get("grant_summary"), "The server must obtain a current owner grant before activation.")),
            text(f"Grant expiry: {_display(row.get('grant_expires_at'), 'Set by the reviewed owner grant')}"),
            text("Without a currency cap, monetary cost is Unpriced/unknown. Finite usage limits still apply. A selected currency cap needs a trusted finite quote; unknown cost is not free.", "caption"),
        ]),
        form(fields, title="Create ongoing agent" if mode == "create" else "Review instruction revision",
             submit_action=action, submit_label="Approve & create ongoing agent" if mode == "create" else "Approve revision",
             submit_payload=payload),
        _open("Cancel"),
    ]


def build_assignments_view(
    state: Mapping[str, object], *, theme: ThemeView | None = None, layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Render a bounded host-authorized assignment snapshot for all client targets.

    Mutation controls require the host's action allowlist and UUID4 submission
    identities. These are presentation eligibility, never execution authority.
    Use ``layout.mode == 'watch'`` for the declared wrist disposition.
    """
    state = _mapping(state)
    layout = layout or LayoutView()
    mode = _display(state.get("mode"), "list")
    row = _mapping(state.get("assignment"))
    error = _display(state.get("error"))
    if state.get("enabled") is not True:
        components = [alert("Ongoing agents are currently turned off.", "info")]
    elif error:
        components = [alert(error, "error")]
    elif mode not in {"list", "detail", "create", "revise"}:
        components = [alert("This assignment view is unavailable.", "warning")]
    elif mode in {"detail", "revise"} and not _uuid(row.get("assignment_id")):
        components = [alert("This ongoing agent is not available.", "warning")]
    elif layout.mode == "watch":
        rows = _rows(state.get("assignments"), 3) if mode == "list" else [row]
        components = []
        for item in rows:
            name = _display(_definition(item).get("name"), "Ongoing agent")[:120]
            components.append(card(name, _summary(item, wrist=True)))
            guidance = (f'Use chat: "Status of {name}".' if item.get("lifecycle") in {"stopped", "completed"}
                        else f'Use chat: "Status of {name}", "Pause {name}", "Resume {name}", or "Stop {name}".')
            components.append(text(guidance, "caption"))
        components.append(alert("For detailed instructions, creation or sensitive review, continue in AstralDeep on your phone or computer in the same conversation.", "info"))
    elif mode in {"create", "revise"}:
        components = _form(state, row, mode)
    elif mode == "detail":
        components = _detail(row, state.get("execution_enabled") is True)
    else:
        components = [text("Standing instructions continue between sessions. Unchanged checks stay quiet.", "caption")]
        if _allowed(state, "chrome_assignment_create"):
            components.append(_open("Create ongoing agent", assignment_mode="create"))
        rows = _rows(state.get("assignments"), 50)
        for item in rows:
            body = _summary(item)
            if _uuid(item.get("assignment_id")):
                body.append(_open("View assignment", assignment_id=item["assignment_id"]))
            body.extend(_controls(item, state.get("execution_enabled") is True))
            components.append(card(_display(_definition(item).get("name"), "Ongoing agent"), body))
        if not rows:
            components.append(alert("No ongoing agents yet.", "info"))
        cursor = _display(state.get("next_cursor"))
        if cursor:
            components.append(_open("More ongoing agents", assignment_cursor=cursor))
    if state.get("enabled") is True and state.get("execution_enabled") is not True:
        components.insert(0, alert("Unattended execution is unavailable. Existing work will not run until its prerequisites are restored.", "warning"))
    if _display(state.get("notice")):
        components.insert(0, alert(_display(state["notice"]), "info"))
    return build_view(_SURFACE, _TITLE, components, theme=theme, layout=layout)


__all__ = ["build_assignments_view"]
