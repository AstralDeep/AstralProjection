"""Pure audit, feedback, onboarding, and administrative view builders."""

from __future__ import annotations

import json
from collections.abc import Iterable, Mapping

from astralprojection.models import ChromeViewModel, ComponentView, LayoutView, ThemeView

from ._components import (
    alert,
    badge,
    build_view,
    button,
    card,
    clean_text,
    container,
    denied_view,
    field,
    form,
    key_value,
    text,
    unavailable_view,
)

_AUDIT_OUTCOMES = ("success", "failure", "in_progress", "interrupted")


def _rows(values: Iterable[Mapping[str, object]]) -> tuple[Mapping[str, object], ...]:
    return tuple(item for item in values if isinstance(item, Mapping))


def _percent(value: object) -> str:
    try:
        return f"{float(value) * 100:.1f}%"
    except (TypeError, ValueError):
        return "n/a"


def _pretty(value: object) -> str:
    try:
        return json.dumps(value or {}, indent=2, sort_keys=True, default=str)
    except (TypeError, ValueError):
        return "{}"


def build_audit_view(
    entries: Iterable[Mapping[str, object]] = (),
    *,
    selected: Mapping[str, object] | None = None,
    filters: Mapping[str, object] | None = None,
    event_classes: Iterable[str] = (),
    next_cursor: str | None = None,
    denied: bool = False,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build the owner-filtered audit surface from already-authorized state."""
    if denied:
        return denied_view("audit", "Audit log", "You are not allowed to view this audit log.")
    if error:
        return unavailable_view("audit", "Audit log", error)
    if selected is not None:
        return _build_audit_detail(selected, theme=theme, layout=layout)

    active = dict(filters or {})
    fields = [
        field(
            "event_class",
            "Event class",
            "select",
            default=active.get("event_class") or "",
            options=("", *tuple(event_classes)),
        ),
        field(
            "outcome",
            "Outcome",
            "select",
            default=active.get("outcome") or "",
            options=("", *_AUDIT_OUTCOMES),
        ),
        field("q", "Search", default=active.get("q") or ""),
    ]
    components: list[ComponentView] = [
        form(
            fields,
            submit_action="chrome_audit_page",
            submit_label="Apply",
            title="Filter audit entries",
        )
    ]
    rows = _rows(entries)
    if not rows:
        components.append(alert("No audit entries match the current filters.", "info"))
    else:
        components.append(text(f"Showing {len(rows)} entries", "caption"))
        for entry in rows:
            outcome = clean_text(entry.get("outcome") or "unknown")
            description = " ".join(clean_text(entry.get("description")).split())
            if len(description) > 120:
                description = description[:117].rstrip() + "..."
            components.append(
                card(
                    entry.get("action_type") or "Audit event",
                    [
                        container(
                            [
                                badge(outcome, _outcome_variant(outcome)),
                                text(entry.get("event_class") or "unknown", "caption"),
                                text(entry.get("recorded_at") or "-", "caption"),
                            ],
                            direction="row",
                        ),
                        text(description or "No description supplied."),
                        button(
                            "View details",
                            "chrome_open",
                            {
                                "surface": "audit",
                                "params": {"event_id": clean_text(entry.get("event_id"))},
                            },
                        ),
                    ],
                )
            )
    if next_cursor:
        payload = {"fields": {**active, "cursor": clean_text(next_cursor)}}
        components.append(button("Next", "chrome_audit_page", payload))
    return build_view("audit", "Audit log", components, theme=theme, layout=layout)


def _outcome_variant(outcome: str) -> str:
    return {
        "success": "success",
        "failure": "error",
        "in_progress": "info",
        "interrupted": "warning",
    }.get(outcome, "default")


def _build_audit_detail(
    entry: Mapping[str, object],
    *,
    theme: ThemeView | None,
    layout: LayoutView | None,
) -> ChromeViewModel:
    if not entry:
        components = [
            button("Back to audit log", "chrome_open", {"surface": "audit", "params": {}}),
            alert("Audit event not found.", "error"),
        ]
        return build_view("audit", "Audit log", components, theme=theme, layout=layout)
    rows = [
        ("Recorded at", entry.get("recorded_at") or "-"),
        ("Event class", entry.get("event_class") or "-"),
        ("Action type", entry.get("action_type") or "-"),
        ("Outcome", entry.get("outcome") or "-"),
        ("Description", entry.get("description") or "-"),
        ("Event id", entry.get("event_id") or "-"),
        ("Correlation id", entry.get("correlation_id") or "-"),
        ("Agent", entry.get("agent_id") or "-"),
        ("Conversation", entry.get("conversation_id") or "-"),
        ("Started at", entry.get("started_at") or "-"),
        ("Completed at", entry.get("completed_at") or "-"),
    ]
    if entry.get("outcome_detail"):
        rows.append(("Outcome detail", entry["outcome_detail"]))
    components: list[ComponentView] = [
        button("Back to audit log", "chrome_open", {"surface": "audit", "params": {}}),
        key_value(rows, title="Event details"),
        card("Inputs metadata", [text(_pretty(entry.get("inputs_meta")))]),
        card("Outputs metadata", [text(_pretty(entry.get("outputs_meta")))]),
    ]
    artifacts = entry.get("artifacts") or ()
    if isinstance(artifacts, (list, tuple)) and artifacts:
        artifact_components: list[ComponentView] = []
        for artifact in artifacts:
            if isinstance(artifact, Mapping):
                availability = "available" if artifact.get("available") else "no longer available"
                artifact_components.append(
                    text(
                        f"{clean_text(artifact.get('store'))} / "
                        f"{clean_text(artifact.get('artifact_id'))} — {availability}",
                        "caption",
                    )
                )
        if artifact_components:
            components.append(card("Artifacts", artifact_components))
    return build_view("audit", "Audit log", components, theme=theme, layout=layout)


def build_feedback_view(
    flagged_tools: Iterable[Mapping[str, object]] = (),
    proposals: Iterable[Mapping[str, object]] = (),
    *,
    denied: bool = False,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build the admin tool-quality surface from supplied feedback summaries."""
    if denied:
        return denied_view("admin_tools", "Tool quality", "Admin role required for this action.")
    if error:
        return unavailable_view("admin_tools", "Tool quality", error)
    components: list[ComponentView] = [text("Underperforming tools", "h3")]
    flagged = _rows(flagged_tools)
    if not flagged:
        components.append(alert("No underperforming tools right now.", "info"))
    for item in flagged:
        components.append(
            card(
                item.get("tool_name") or "Unknown tool",
                [
                    key_value(
                        [
                            ("Agent", item.get("agent_id") or "-"),
                            ("Failure rate", _percent(item.get("failure_rate"))),
                            (
                                "Negative feedback",
                                _percent(item.get("negative_feedback_rate")),
                            ),
                            ("Dispatches", item.get("dispatch_count") or 0),
                        ]
                    ),
                    badge("proposal pending", "info")
                    if item.get("pending_proposal_id")
                    else text("No proposal pending.", "caption"),
                ],
            )
        )
    components.append(text("Pending knowledge-update proposals", "h3"))
    pending = _rows(proposals)
    if not pending:
        components.append(alert("No pending knowledge-update proposals.", "info"))
    for proposal in pending:
        proposal_id = clean_text(proposal.get("proposal_id") or proposal.get("id"))
        components.append(
            card(
                proposal.get("tool_name") or "Knowledge update",
                [
                    text(proposal.get("agent_id") or "", "caption"),
                    text(proposal.get("artifact_path") or "", "caption"),
                    text(proposal.get("diff_payload") or "No diff supplied."),
                    form(
                        [field("rationale", "Rationale", help_text="Required to reject")],
                        title="Review proposal",
                        actions=[
                            {
                                "label": "Approve & apply",
                                "action": "chrome_admin_proposal_decide",
                                "variant": "primary",
                                "payload": {"proposal_id": proposal_id, "decision": "accept"},
                            },
                            {
                                "label": "Reject",
                                "action": "chrome_admin_proposal_decide",
                                "variant": "danger",
                                "payload": {"proposal_id": proposal_id, "decision": "reject"},
                            },
                        ],
                    ),
                ],
            )
        )
    return build_view("admin_tools", "Tool quality", components, theme=theme, layout=layout)


def build_onboarding_view(
    steps: Iterable[Mapping[str, object]] = (),
    *,
    admin: bool = False,
    edit_step: Mapping[str, object] | None = None,
    offline: bool = False,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build either the guided tour or the authorized tutorial-admin surface."""
    rows = _rows(steps)
    if not admin:
        intro = text(
            "The guided tour walks through AstralDeep's main controls step by step. "
            "You can skip or dismiss it at any time."
        )
        if offline:
            return build_view(
                "tour",
                "Take the tour",
                [intro, alert("The onboarding subsystem is unavailable right now.", "error")],
                theme=theme,
                layout=layout,
            )
        if not rows:
            return build_view(
                "tour",
                "Take the tour",
                [intro, alert("No tour steps are available yet.", "info")],
                theme=theme,
                layout=layout,
            )
        step_cards = [
            card(
                step.get("title") or "Tour step",
                [text(step.get("body") or ""), text(step.get("target_kind") or "", "caption")],
            )
            for step in rows
        ]
        step_ids = [step.get("id") for step in rows]
        return build_view(
            "tour",
            "Take the tour",
            [
                intro,
                *step_cards,
                button("Start tour", "chrome_tour_event", {"event": "started", "steps": step_ids}),
            ],
            theme=theme,
            layout=layout,
        )

    components: list[ComponentView] = [
        button(
            "New step",
            "chrome_open",
            {"surface": "admin_tools", "params": {"tab": "tutorial", "step_id": "new"}},
            variant="primary",
        )
    ]
    if not rows:
        components.append(alert("No tutorial steps yet.", "info"))
    for step in rows:
        archived = bool(step.get("archived"))
        step_id = step.get("id")
        components.append(
            card(
                step.get("title") or "Untitled step",
                [
                    text(step.get("slug") or "", "caption"),
                    key_value(
                        [
                            ("Audience", step.get("audience") or "user"),
                            ("Target", step.get("target_kind") or "none"),
                            ("Order", step.get("display_order") or 0),
                        ]
                    ),
                    container(
                        [
                            button(
                                "Edit",
                                "chrome_open",
                                {
                                    "surface": "admin_tools",
                                    "params": {"tab": "tutorial", "step_id": step_id},
                                },
                            ),
                            button(
                                "Restore" if archived else "Archive",
                                "chrome_admin_step_restore"
                                if archived
                                else "chrome_admin_step_archive",
                                {"step_id": step_id},
                                variant="secondary" if archived else "danger",
                            ),
                        ],
                        direction="row",
                    ),
                ],
            )
        )
    if edit_step is not None:
        components.append(_step_form(edit_step))
    return build_view("admin_tools", "Tutorial admin", components, theme=theme, layout=layout)


def _step_form(step: Mapping[str, object]) -> ComponentView:
    step_id = step.get("id")
    creating = step_id in {None, "", "new"}
    fields = []
    if creating:
        fields.append(field("slug", "Slug", default=step.get("slug") or ""))
    fields.extend(
        [
            field(
                "audience",
                "Audience",
                "select",
                default=step.get("audience") or "user",
                options=("user", "admin"),
            ),
            field(
                "display_order", "Display order", "number", default=step.get("display_order") or 1
            ),
            field(
                "target_kind",
                "Target kind",
                "select",
                default=step.get("target_kind") or "none",
                options=("none", "selector", "surface"),
            ),
            field("target_key", "Target key", default=step.get("target_key") or ""),
            field("title", "Title", default=step.get("title") or ""),
            field("body", "Body", "textarea", default=step.get("body") or ""),
        ]
    )
    payload = {} if creating else {"step_id": step_id}
    return form(
        fields,
        title="New tutorial step" if creating else "Edit tutorial step",
        submit_action="chrome_admin_step_save",
        submit_payload=payload,
    )


def build_admin_view(
    tab: str,
    *,
    is_admin: bool,
    flagged_tools: Iterable[Mapping[str, object]] = (),
    proposals: Iterable[Mapping[str, object]] = (),
    steps: Iterable[Mapping[str, object]] = (),
    edit_step: Mapping[str, object] | None = None,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build the role-gated admin shell and its active supplied-state tab."""
    if not is_admin:
        return denied_view(
            "admin_tools", "Admin tools", "Admin role required to view this surface."
        )
    active = "tutorial" if tab == "tutorial" else "quality"
    tabs = container(
        [
            button(
                "Tool quality",
                "chrome_open",
                {"surface": "admin_tools", "params": {"tab": "quality"}},
                disabled=active == "quality",
            ),
            button(
                "Tutorial admin",
                "chrome_open",
                {"surface": "admin_tools", "params": {"tab": "tutorial"}},
                disabled=active == "tutorial",
            ),
        ],
        direction="row",
    )
    if active == "quality":
        inner = build_feedback_view(
            flagged_tools,
            proposals,
            error=error,
            theme=theme,
            layout=layout,
        )
    else:
        inner = build_onboarding_view(
            steps,
            admin=True,
            edit_step=edit_step,
            theme=theme,
            layout=layout,
        )
    return build_view(
        "admin_tools",
        "Admin tools",
        [tabs, *inner.components],
        theme=theme,
        layout=layout,
    )


__all__ = [
    "build_admin_view",
    "build_audit_view",
    "build_feedback_view",
    "build_onboarding_view",
]
