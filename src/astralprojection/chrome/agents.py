"""Pure agent, authoring, draft, and attachment presentation builders."""

from __future__ import annotations

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


def _rows(values: Iterable[Mapping[str, object]]) -> tuple[Mapping[str, object], ...]:
    return tuple(item for item in values if isinstance(item, Mapping))


def _human_size(value: object) -> str:
    try:
        size = max(0, int(value))
    except (TypeError, ValueError):
        return ""
    if size >= 1024 * 1024:
        return f"{size / (1024 * 1024):.1f} MB"
    if size >= 1024:
        return f"{size / 1024:.0f} KB"
    return f"{size} B"


def _agent_badges(agent: Mapping[str, object]) -> list[ComponentView]:
    badges: list[ComponentView] = []
    if agent.get("owned"):
        badges.append(badge("Yours", "accent"))
    if agent.get("is_public"):
        badges.append(badge("Public"))
    if agent.get("disabled"):
        badges.append(badge("Disabled by you", "warning"))
    status = clean_text(agent.get("status") or "connected")
    badges.append(badge(status.title(), "success" if status == "connected" else "default"))
    return badges


def build_agents_view(
    agents: Iterable[Mapping[str, object]] = (),
    *,
    tab: str = "mine",
    selected: Mapping[str, object] | None = None,
    can_manage: bool = False,
    permissions: Iterable[Mapping[str, object]] = (),
    credentials: Iterable[Mapping[str, object]] = (),
    denied: bool = False,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build an agent list/detail using only state authorized by the host."""
    if denied:
        return denied_view("agents", "Agents & permissions", "Agent access was denied.")
    if error:
        return unavailable_view("agents", "Agents & permissions", error)
    active = "public" if tab == "public" else "mine"
    if selected is not None:
        return _build_agent_detail(
            selected,
            tab=active,
            can_manage=can_manage,
            permissions=permissions,
            credentials=credentials,
            theme=theme,
            layout=layout,
        )
    tabs = container(
        [
            button(
                "My agents",
                "chrome_open",
                {"surface": "agents", "params": {"tab": "mine"}},
                disabled=active == "mine",
            ),
            button(
                "Public",
                "chrome_open",
                {"surface": "agents", "params": {"tab": "public"}},
                disabled=active == "public",
            ),
            button("Drafts", "chrome_open", {"surface": "drafts", "params": {}}),
        ],
        direction="row",
    )
    components: list[ComponentView] = [tabs]
    rows = _rows(agents)
    if not rows:
        message = (
            "No public agents are available."
            if active == "public"
            else "You don't own any agents yet. Create one from Drafts or chat."
        )
        components.append(alert(message, "info"))
    for agent in rows:
        agent_id = clean_text(agent.get("agent_id") or agent.get("id"))
        enabled = not bool(agent.get("disabled"))
        components.append(
            card(
                agent.get("name") or "Unnamed agent",
                [
                    container(_agent_badges(agent), direction="row"),
                    text(agent.get("description") or "No description supplied."),
                    container(
                        [
                            button(
                                "Open",
                                "chrome_open",
                                {
                                    "surface": "agents",
                                    "params": {"agent_id": agent_id, "tab": active},
                                },
                            ),
                            button(
                                "Disable" if enabled else "Enable",
                                "chrome_agent_enabled",
                                {"agent_id": agent_id, "enabled": not enabled, "tab": active},
                            ),
                        ],
                        direction="row",
                    ),
                ],
            )
        )
    return build_view("agents", "Agents & permissions", components, theme=theme, layout=layout)


def _build_agent_detail(
    agent: Mapping[str, object],
    *,
    tab: str,
    can_manage: bool,
    permissions: Iterable[Mapping[str, object]],
    credentials: Iterable[Mapping[str, object]],
    theme: ThemeView | None,
    layout: LayoutView | None,
) -> ChromeViewModel:
    back = button("Back to agents", "chrome_open", {"surface": "agents", "params": {"tab": tab}})
    if not agent:
        return build_view(
            "agents",
            "Agents & permissions",
            [back, alert("Agent not found.", "error")],
            theme=theme,
            layout=layout,
        )
    agent_id = clean_text(agent.get("agent_id") or agent.get("id"))
    components: list[ComponentView] = [
        back,
        card(
            agent.get("name") or "Unnamed agent",
            [
                container(_agent_badges(agent), direction="row"),
                text(agent.get("description") or "No description supplied."),
                key_value(
                    [
                        ("Agent id", agent_id),
                        ("Owner", agent.get("owner_email") or "-"),
                    ]
                ),
                button(
                    "Disable" if not agent.get("disabled") else "Enable",
                    "chrome_agent_enabled",
                    {
                        "agent_id": agent_id,
                        "enabled": bool(agent.get("disabled")),
                        "tab": tab,
                    },
                ),
            ],
        ),
    ]
    if not can_manage:
        components.append(
            alert(
                "Only the owner or an authorized administrator can change this agent's "
                "permissions, visibility, trust, or credentials.",
                "info",
            )
        )
        return build_view("agents", "Agents & permissions", components, theme=theme, layout=layout)
    components.extend(
        [
            _permissions_form(agent_id, permissions, tab),
            card(
                "Visibility",
                [
                    text(
                        "This agent is currently public."
                        if agent.get("is_public")
                        else "This agent is currently private."
                    ),
                    button(
                        "Make private" if agent.get("is_public") else "Make public",
                        "chrome_visibility_set",
                        {
                            "agent_id": agent_id,
                            "is_public": not bool(agent.get("is_public")),
                            "tab": tab,
                        },
                    ),
                ],
            ),
            card(
                "Trust",
                [
                    text(
                        "This agent is owner-approved safe."
                        if agent.get("is_safe")
                        else "This agent is not marked safe."
                    ),
                    button(
                        "Unmark safe" if agent.get("is_safe") else "Mark safe",
                        "chrome_safe_set",
                        {
                            "agent_id": agent_id,
                            "is_safe": not bool(agent.get("is_safe")),
                            "tab": tab,
                        },
                    ),
                ],
            ),
            _credentials_form(agent_id, credentials, tab),
        ]
    )
    return build_view("agents", "Agents & permissions", components, theme=theme, layout=layout)


def _permissions_form(
    agent_id: str,
    permissions: Iterable[Mapping[str, object]],
    tab: str,
) -> ComponentView:
    rows = _rows(permissions)
    if not rows:
        return card("Tool permissions", [alert("This agent exposes no tools.", "info")])
    fields = []
    for permission in rows:
        field_name = clean_text(permission.get("field_name"))
        tool_name = clean_text(permission.get("tool_name") or "Tool")
        scope = clean_text(permission.get("scope") or "unknown")
        description = clean_text(permission.get("description"))
        if not field_name:
            continue
        destructive = clean_text(permission.get("destructive"))
        suffix = f" — {destructive}" if destructive and destructive != "never" else ""
        fields.append(
            field(
                field_name,
                f"{tool_name} ({scope}){suffix}",
                "boolean",
                default=bool(permission.get("enabled")),
                help_text=description or None,
            )
        )
    if not fields:
        return card(
            "Tool permissions",
            [alert("The supplied tool permissions are not configurable on this client.", "info")],
        )
    return form(
        fields,
        title="Tool permissions",
        description="Runtime security gates remain authoritative after a permission is enabled.",
        submit_action="chrome_perms_save",
        submit_label="Save permissions",
        submit_payload={"agent_id": agent_id, "tab": tab},
    )


def _credentials_form(
    agent_id: str,
    credentials: Iterable[Mapping[str, object]],
    tab: str,
) -> ComponentView:
    rows = _rows(credentials)
    if not rows:
        return card("Credentials", [text("This agent requires no user credentials.", "caption")])
    fields = []
    for credential in rows:
        key = clean_text(credential.get("key"))
        if not key:
            continue
        label = credential.get("label") or key
        requirement = "Optional" if credential.get("optional") else "Required"
        stored = "stored" if credential.get("stored") else "not stored"
        fields.append(
            field(
                key,
                f"{label} ({requirement}, {stored})",
                "password",
                help_text="Leave blank to keep the current encrypted value.",
            )
        )
    actions: list[dict[str, object]] = [
        {
            "label": "Save credentials",
            "action": "chrome_credentials_save",
            "variant": "primary",
            "payload": {"agent_id": agent_id, "tab": tab},
        }
    ]
    for credential in rows:
        key = clean_text(credential.get("key"))
        if key and credential.get("stored"):
            actions.append(
                {
                    "label": f"Delete {key}",
                    "action": "chrome_credential_delete",
                    "variant": "danger",
                    "payload": {"agent_id": agent_id, "key": key, "tab": tab},
                }
            )
    return form(fields, title="Credentials", actions=actions)


def build_authoring_view(
    agents: Iterable[Mapping[str, object]] = (),
    sessions: Iterable[Mapping[str, object]] = (),
    *,
    selected: Mapping[str, object] | None = None,
    enabled: bool = True,
    host_online: bool = True,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build the personal-agent authoring flow from a controller snapshot."""
    if not enabled:
        return unavailable_view(
            "agent_authoring", "My agents", "Personal agents are not enabled on this deployment."
        )
    if selected is not None:
        return _build_authoring_session(selected, theme=theme, layout=layout)
    host_note = (
        "Your agents run on your desktop host, not on the server."
        if host_online
        else "Your desktop host is offline. Agents remain unavailable until it reconnects."
    )
    components: list[ComponentView] = [alert(host_note, "info")]
    rows = _rows(agents)
    if not rows:
        components.append(alert("No agents yet — create one below.", "info"))
    for agent in rows:
        agent_id = clean_text(agent.get("agent_id") or agent.get("id"))
        body: list[ComponentView] = [
            badge(agent.get("status") or "unknown"),
            button("Revise", "chrome_author_revise", {"agent_id": agent_id}),
            button("Delete", "chrome_author_delete", {"agent_id": agent_id}, variant="danger"),
        ]
        if agent.get("revalidation_required"):
            body.insert(
                0,
                alert(
                    "The agent rules changed; revise and re-run Analyze before it can run.",
                    "warning",
                ),
            )
        components.append(card(agent.get("name") or "Unnamed agent", body))
    for session in _rows(sessions):
        components.append(
            button(
                f"{clean_text(session.get('agent_name'))} — "
                f"{clean_text(session.get('phase') or 'specify')}",
                "chrome_open",
                {
                    "surface": "agent_authoring",
                    "params": {"draft_id": session.get("draft_id") or session.get("id")},
                },
            )
        )
    components.append(
        form(
            [
                field("agent_name", "Agent name"),
                field(
                    "description",
                    "What should it do for you?",
                    "textarea",
                    help_text="At least 10 characters.",
                ),
            ],
            title="Create a personal agent",
            submit_action="chrome_author_start",
            submit_label="Start",
        )
    )
    return build_view("agent_authoring", "My agents", components, theme=theme, layout=layout)


def _build_authoring_session(
    session: Mapping[str, object],
    *,
    theme: ThemeView | None,
    layout: LayoutView | None,
) -> ChromeViewModel:
    if not session:
        return build_view(
            "agent_authoring",
            "My agents",
            [alert("That authoring session is not available.", "error")],
            theme=theme,
            layout=layout,
        )
    phase = clean_text(session.get("phase") or "specify")
    draft_id = clean_text(session.get("draft_id") or session.get("id"))
    revision = int(session.get("state_revision") or 0)
    payload = {"draft_id": draft_id, "state_revision": revision}
    components: list[ComponentView] = [
        text(f"{phase.title()} — {clean_text(session.get('agent_name'))}", "h3"),
        text(session.get("phase_help") or "Complete this phase to continue.", "caption"),
    ]
    if phase == "analyze":
        violations = _rows(session.get("violations") or ())  # type: ignore[arg-type]
        if session.get("analyze_passed"):
            components.append(alert("Analyze passed — you can generate this agent.", "success"))
        elif violations:
            for violation in violations:
                components.append(
                    alert(
                        f"{clean_text(violation.get('message') or violation.get('plain_language'))} "
                        f"(rule {clean_text(violation.get('principle'))})",
                        "error",
                    )
                )
        else:
            components.append(text("Not checked yet.", "caption"))
        components.append(
            button("Run Analyze", "chrome_author_analyze", payload, variant="primary")
        )
    elif phase == "generate":
        components.extend(
            [
                alert("Analyze passed against the agent rules.", "success"),
                button(
                    "Generate & send to my desktop",
                    "chrome_author_generate",
                    payload,
                    variant="primary",
                ),
                button("Re-run Analyze", "chrome_author_analyze", payload),
            ]
        )
    else:
        supplied_fields = session.get("fields") or ()
        normalized_fields = [dict(item) for item in supplied_fields if isinstance(item, Mapping)]
        if normalized_fields:
            advance = "chrome_author_clarify" if phase == "clarify" else "chrome_author_advance"
            components.append(
                form(
                    normalized_fields,
                    title=f"{phase.title()} details",
                    actions=[
                        {
                            "label": "Save",
                            "action": "chrome_author_edit",
                            "payload": payload,
                        },
                        {
                            "label": "Save & continue",
                            "action": advance,
                            "variant": "primary",
                            "payload": payload,
                        },
                    ],
                )
            )
        else:
            components.append(text("Nothing drafted yet — ask the assistant.", "caption"))
        components.append(
            button("Ask the assistant", "chrome_author_draft", {"draft_id": draft_id})
        )
    components.append(button("My agents", "chrome_author_list"))
    return build_view("agent_authoring", "My agents", components, theme=theme, layout=layout)


def build_drafts_view(
    drafts: Iterable[Mapping[str, object]] = (),
    *,
    selected: Mapping[str, object] | None = None,
    show_refine: bool = False,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build the owner-scoped draft list or detail surface."""
    if error:
        return unavailable_view("drafts", "Drafts & creation", error)
    if selected is not None:
        return _build_draft_detail(selected, show_refine=show_refine, theme=theme, layout=layout)
    components: list[ComponentView] = []
    rows = _rows(drafts)
    if not rows:
        components.append(
            alert(
                "No drafts yet — create one below or ask for a missing capability in chat.",
                "info",
            )
        )
    for draft in rows:
        draft_id = clean_text(draft.get("draft_id") or draft.get("id"))
        components.append(
            card(
                draft.get("agent_name") or "Unnamed draft",
                [
                    container(
                        [
                            badge(draft.get("origin") or "manual"),
                            badge(draft.get("status") or "unknown"),
                        ],
                        direction="row",
                    ),
                    text(_self_test_summary(draft), "caption"),
                    button(
                        "Open",
                        "chrome_open",
                        {"surface": "drafts", "params": {"draft_id": draft_id}},
                    ),
                ],
            )
        )
    components.append(
        form(
            [
                field("agent_name", "Agent name"),
                field("description", "What should it do?", "textarea"),
                field("tools", "Tools (optional)", "textarea"),
            ],
            title="Create a new agent",
            description="Generation and self-test may take a few minutes.",
            submit_action="chrome_draft_create",
            submit_label="Generate & self-test",
        )
    )
    return build_view("drafts", "Drafts & creation", components, theme=theme, layout=layout)


def _self_test_summary(draft: Mapping[str, object]) -> str:
    status = clean_text(draft.get("self_test_status"))
    if not status:
        return "not self-tested yet"
    summary = clean_text(draft.get("self_test_summary"))
    return f"self-test {status}" + (f" — {summary}" if summary else "")


def _build_draft_detail(
    draft: Mapping[str, object],
    *,
    show_refine: bool,
    theme: ThemeView | None,
    layout: LayoutView | None,
) -> ChromeViewModel:
    back = button("All drafts", "chrome_open", {"surface": "drafts", "params": {}})
    if not draft:
        return build_view(
            "drafts",
            "Drafts & creation",
            [back, alert("Draft not found; it may have been discarded.", "error")],
            theme=theme,
            layout=layout,
        )
    draft_id = clean_text(draft.get("draft_id") or draft.get("id"))
    status = clean_text(draft.get("status") or "unknown")
    body: list[ComponentView] = [
        container([badge(draft.get("origin") or "manual"), badge(status)], direction="row"),
        text(draft.get("description") or "No description supplied."),
        text(_self_test_summary(draft), "caption"),
    ]
    if draft.get("error_message"):
        body.append(alert(draft["error_message"], "error"))
    if status == "live":
        body.append(alert("This draft is live; manage it under Agents & permissions.", "success"))
    else:
        approve_action = "revision_apply" if draft.get("revises_agent_id") else "draft_approve"
        discard_action = "revision_discard" if draft.get("revises_agent_id") else "draft_discard"
        body.append(
            container(
                [
                    button("Approve", approve_action, {"draft_id": draft_id}, variant="primary"),
                    button(
                        "Refine",
                        "chrome_open",
                        {
                            "surface": "drafts",
                            "params": {"draft_id": draft_id, "refine": True},
                        },
                    ),
                    button("Discard", discard_action, {"draft_id": draft_id}, variant="danger"),
                ],
                direction="row",
            )
        )
    components: list[ComponentView] = [back, card(draft.get("agent_name") or "Draft", body)]
    if show_refine and status != "live":
        components.append(
            form(
                [field("message", "Describe what to change", "textarea")],
                title="Refine this draft",
                submit_action="draft_refine",
                submit_payload={"draft_id": draft_id},
            )
        )
    return build_view("drafts", "Drafts & creation", components, theme=theme, layout=layout)


def build_attachments_view(
    attachments: Iterable[Mapping[str, object]] = (),
    *,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build the reusable attachment library without storage access."""
    if error:
        return unavailable_view("attachments", "Attachments", error)
    rows = _rows(attachments)
    if not rows:
        return build_view(
            "attachments",
            "Attachments",
            [
                alert(
                    "No uploads yet. Use the paperclip in chat to attach a file; it will "
                    "appear here for reuse.",
                    "info",
                )
            ],
            theme=theme,
            layout=layout,
        )
    components: list[ComponentView] = [
        text(
            "Attach a previously uploaded file to the next message without uploading it again.",
            "caption",
        )
    ]
    for attachment in rows:
        attachment_id = clean_text(attachment.get("attachment_id") or attachment.get("id"))
        filename = clean_text(attachment.get("filename") or "Unnamed attachment")
        category = clean_text(attachment.get("category") or "file")
        components.append(
            card(
                filename,
                [
                    text(f"{category} · {_human_size(attachment.get('size_bytes'))}", "caption"),
                    container(
                        [
                            button(
                                "Attach",
                                "attach_existing",
                                {
                                    "attachment_id": attachment_id,
                                    "filename": filename,
                                    "category": category,
                                },
                                variant="primary",
                                local=True,
                            ),
                            button(
                                "Delete",
                                "chrome_attachment_delete",
                                {"attachment_id": attachment_id},
                                variant="danger",
                            ),
                        ],
                        direction="row",
                    ),
                ],
            )
        )
    return build_view("attachments", "Attachments", components, theme=theme, layout=layout)


__all__ = [
    "build_agents_view",
    "build_attachments_view",
    "build_authoring_view",
    "build_drafts_view",
]
