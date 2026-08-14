"""Pure remote-machine, feature-flag, workspace, history, and timeline builders."""

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

_CAUSE_LABELS = {
    "turn": "Assistant turn",
    "component_action": "Component action",
    "combine": "Components combined",
    "condense": "Components condensed",
    "remove": "Component removed",
}


def _rows(values: Iterable[Mapping[str, object]]) -> tuple[Mapping[str, object], ...]:
    return tuple(item for item in values if isinstance(item, Mapping))


def _credential_fields() -> list[dict[str, object]]:
    return [
        field(
            "cred_type",
            "Credential type",
            "select",
            default="ssh_key",
            options=("ssh_key", "password"),
        ),
        field(
            "private_key",
            "Private key (paste the full PEM)",
            "textarea",
            help_text="Used only when credential type is ssh_key.",
            visible_when={"field": "cred_type", "equals": "ssh_key", "default": "ssh_key"},
        ),
        field(
            "passphrase",
            "Key passphrase (optional)",
            "password",
            visible_when={"field": "cred_type", "equals": "ssh_key", "default": "ssh_key"},
        ),
        field(
            "password",
            "Password",
            "password",
            help_text="Used only when credential type is password.",
            visible_when={"field": "cred_type", "equals": "password", "default": "ssh_key"},
        ),
    ]


def build_remote_machines_view(
    machines: Iterable[Mapping[str, object]] = (),
    *,
    enabled: bool = True,
    denied: bool = False,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build owner-scoped remote-machine inventory without receiving secrets."""
    if denied:
        return denied_view("remote_machines", "Remote machines", "Remote-machine access denied.")
    if not enabled:
        return build_view(
            "remote_machines",
            "Remote machines",
            [alert("Remote compute is disabled on this server.", "info")],
            theme=theme,
            layout=layout,
        )
    if error:
        return unavailable_view("remote_machines", "Remote machines", error)
    components: list[ComponentView] = [
        text(
            "Register private machines and clusters. Saving performs a real connection "
            "probe and reports the result.",
            "caption",
        )
    ]
    rows = _rows(machines)
    if not rows:
        components.append(alert("No machines yet — add one below.", "info"))
    for machine in rows:
        machine_id = clean_text(machine.get("machine_id") or machine.get("id"))
        verdict = clean_text(machine.get("last_verdict") or "not yet probed")
        actions: list[ComponentView] = [
            button("Probe", "chrome_machine_probe", {"machine_id": machine_id})
        ]
        if verdict == "host_key_mismatch":
            actions.append(button("Re-trust", "chrome_machine_retrust", {"machine_id": machine_id}))
        actions.extend(
            [
                button(
                    "Remove credential",
                    "chrome_machine_credential_delete",
                    {"machine_id": machine_id},
                ),
                button(
                    "Delete",
                    "chrome_machine_delete",
                    {"machine_id": machine_id},
                    variant="danger",
                ),
            ]
        )
        components.append(
            card(
                machine.get("label") or "Unnamed machine",
                [
                    key_value(
                        [
                            (
                                "Address",
                                (
                                    f"{clean_text(machine.get('address'))}:"
                                    f"{clean_text(machine.get('port') or 22)}"
                                ),
                            ),
                            ("OS", machine.get("os_family") or "unknown"),
                            ("Role", machine.get("role") or "plain"),
                            ("Last check", verdict),
                        ]
                    ),
                    container(actions, direction="row"),
                    form(
                        _credential_fields(),
                        title="Replace credential",
                        submit_action="chrome_machine_credential_set",
                        submit_label="Replace & probe",
                        submit_payload={"machine_id": machine_id},
                    ),
                ],
            )
        )
    components.append(
        form(
            [
                field("label", "Label", help_text="A short name, for example my-dgx."),
                field("address", "Address", help_text="Hostname or IP address."),
                field("port", "Port", "number", default=22),
                field("username", "Username"),
                field(
                    "os_family",
                    "Operating system",
                    "select",
                    default="linux",
                    options=("linux", "windows", "macos"),
                ),
                field(
                    "role",
                    "Role",
                    "select",
                    default="cluster",
                    options=("cluster", "plain"),
                ),
                *_credential_fields(),
            ],
            title="Add a machine",
            submit_action="chrome_machine_add",
            submit_label="Add & probe",
        )
    )
    return build_view("remote_machines", "Remote machines", components, theme=theme, layout=layout)


def build_feature_flags_view(
    flags: Iterable[Mapping[str, object]],
    *,
    denied: bool = False,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build a read-only feature-policy explanation; Deep retains mutation."""
    if denied:
        return denied_view("feature_flags", "Feature flags", "Feature-flag access denied.")
    if error:
        return unavailable_view("feature_flags", "Feature flags", error)
    components: list[ComponentView] = [
        alert(
            "Feature policy is read-only here. Changes require the authorized host "
            "configuration path.",
            "info",
        )
    ]
    rows = _rows(flags)
    if not rows:
        components.append(text("No feature flags were supplied.", "caption"))
    for item in rows:
        components.append(
            card(
                item.get("label") or item.get("key") or "Feature",
                [
                    badge(
                        "enabled" if item.get("enabled") else "disabled",
                        "success" if item.get("enabled") else "default",
                    ),
                    text(item.get("description") or "", "caption"),
                    text(item.get("source") or "host policy", "caption"),
                ],
            )
        )
    return build_view("feature_flags", "Feature flags", components, theme=theme, layout=layout)


def build_workspace_view(
    state: Mapping[str, object],
    *,
    denied: bool = False,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build a workspace surface from host-supplied component dictionaries."""
    if denied:
        return denied_view("workspace", "Workspace", "Workspace access denied.")
    if error:
        return unavailable_view("workspace", "Workspace", error)
    components: list[ComponentView] = []
    if state.get("read_only"):
        components.append(
            alert(
                state.get("read_only_reason") or "This workspace view is read-only.",
                "warning",
            )
        )
    raw_components = state.get("components") or ()
    for raw in raw_components:
        if isinstance(raw, Mapping) and raw.get("type"):
            properties = {key: value for key, value in raw.items() if key != "type"}
            components.append(ComponentView(clean_text(raw["type"]).lower(), properties))
    if not components:
        components.append(alert("This workspace has no visible components yet.", "info"))
    if state.get("chat_id"):
        components.append(
            button(
                "Workspace timeline",
                "chrome_open",
                {
                    "surface": "workspace_timeline",
                    "params": {"chat_id": state.get("chat_id"), "page": 0},
                },
            )
        )
    title = clean_text(state.get("title") or "Workspace")
    return build_view("workspace", title, components, theme=theme, layout=layout)


def build_history_view(
    conversations: Iterable[Mapping[str, object]],
    *,
    selected_chat_id: str | None = None,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build conversation history; loading remains an authorized host action."""
    if error:
        return unavailable_view("history", "Conversation history", error)
    components: list[ComponentView] = []
    rows = _rows(conversations)
    if not rows:
        components.append(alert("No conversations yet.", "info"))
    for conversation in rows:
        chat_id = clean_text(conversation.get("chat_id") or conversation.get("id"))
        body: list[ComponentView] = [
            text(conversation.get("updated_at") or "", "caption"),
            text(conversation.get("summary") or "", "caption"),
        ]
        if chat_id == clean_text(selected_chat_id):
            body.append(badge("Current", "success"))
        else:
            body.append(button("Open", "load_chat", {"chat_id": chat_id}))
        components.append(card(conversation.get("title") or "Untitled conversation", body))
    return build_view("history", "Conversation history", components, theme=theme, layout=layout)


def build_timeline_view(
    snapshots: Iterable[Mapping[str, object]] = (),
    *,
    chat_id: str = "",
    page: int = 0,
    total: int = 0,
    selected: Mapping[str, object] | None = None,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build timeline navigation or a read-only historical workspace snapshot."""
    if error:
        return unavailable_view("workspace_timeline", "Workspace timeline", error)
    safe_chat_id = clean_text(chat_id)
    if not safe_chat_id:
        return build_view(
            "workspace_timeline",
            "Workspace timeline",
            [
                alert(
                    "Open a chat first — the timeline shows that chat's workspace history.", "info"
                )
            ],
            theme=theme,
            layout=layout,
        )
    if selected is not None:
        return _build_snapshot_view(selected, safe_chat_id, theme=theme, layout=layout)
    rows = _rows(snapshots)
    if not rows:
        return build_view(
            "workspace_timeline",
            "Workspace timeline",
            [alert("No workspace history yet for this chat.", "info")],
            theme=theme,
            layout=layout,
        )
    safe_page = max(0, int(page))
    safe_total = max(len(rows), int(total))
    components: list[ComponentView] = [
        text("Viewing the past never changes the live workspace.", "caption"),
        button(
            "Back to live",
            "chrome_workspace_timeline_live",
            {"chat_id": safe_chat_id},
            variant="primary",
        ),
    ]
    for index, snapshot in enumerate(rows):
        sequence = safe_total - (safe_page * 50) - index
        cause = clean_text(snapshot.get("cause"))
        label = _CAUSE_LABELS.get(cause, cause or "Workspace change")
        components.append(
            button(
                f"#{sequence} · {label} · {clean_text(snapshot.get('created_at'))}".rstrip(" ·"),
                "chrome_workspace_timeline_view",
                {
                    "chat_id": safe_chat_id,
                    "snapshot_id": snapshot.get("snapshot_id") or snapshot.get("id"),
                },
            )
        )
    navigation: list[ComponentView] = []
    if safe_page > 0:
        navigation.append(
            button(
                "Newer",
                "chrome_open",
                {
                    "surface": "workspace_timeline",
                    "params": {"chat_id": safe_chat_id, "page": safe_page - 1},
                },
            )
        )
    if (safe_page + 1) * 50 < safe_total:
        navigation.append(
            button(
                "Older",
                "chrome_open",
                {
                    "surface": "workspace_timeline",
                    "params": {"chat_id": safe_chat_id, "page": safe_page + 1},
                },
            )
        )
    if navigation:
        components.append(container(navigation, direction="row"))
    return build_view(
        "workspace_timeline", "Workspace timeline", components, theme=theme, layout=layout
    )


def _build_snapshot_view(
    snapshot: Mapping[str, object],
    chat_id: str,
    *,
    theme: ThemeView | None,
    layout: LayoutView | None,
) -> ChromeViewModel:
    if not snapshot:
        return build_view(
            "workspace_timeline",
            "Workspace timeline",
            [alert("That snapshot no longer exists.", "error")],
            theme=theme,
            layout=layout,
        )
    cause = clean_text(snapshot.get("cause"))
    label = _CAUSE_LABELS.get(cause, cause or "Workspace change")
    components: list[ComponentView] = [
        alert(
            f"Viewing workspace history ({label}, {clean_text(snapshot.get('created_at'))}) — read-only.",
            "warning",
        ),
        button(
            "Back to live",
            "chrome_workspace_timeline_live",
            {"chat_id": chat_id},
            variant="primary",
        ),
    ]
    for raw in snapshot.get("components") or ():
        if isinstance(raw, Mapping) and raw.get("type"):
            components.append(
                ComponentView(
                    clean_text(raw["type"]).lower(),
                    {key: value for key, value in raw.items() if key != "type"},
                )
            )
    return build_view(
        "workspace_timeline", "Workspace timeline", components, theme=theme, layout=layout
    )


__all__ = [
    "build_feature_flags_view",
    "build_history_view",
    "build_remote_machines_view",
    "build_timeline_view",
    "build_workspace_view",
]
