"""Pure LLM, personalization, dreaming, pulse, scheduler, and theme builders."""

from __future__ import annotations

from collections.abc import Iterable, Mapping
import re

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

THEME_PRESETS: Mapping[str, Mapping[str, str]] = {
    "midnight": {
        "bg": "#0F1221",
        "surface": "#1A1E2E",
        "primary": "#6366F1",
        "secondary": "#8B5CF6",
        "text": "#F3F4F6",
        "muted": "#9CA3AF",
        "accent": "#06B6D4",
    },
    "daylight": {
        "bg": "#F8FAFC",
        "surface": "#FFFFFF",
        "primary": "#4F46E5",
        "secondary": "#7C3AED",
        "text": "#1E293B",
        "muted": "#64748B",
        "accent": "#0891B2",
    },
    "ocean": {
        "bg": "#0C1222",
        "surface": "#132038",
        "primary": "#0EA5E9",
        "secondary": "#06B6D4",
        "text": "#E2E8F0",
        "muted": "#94A3B8",
        "accent": "#2DD4BF",
    },
    "sunset": {
        "bg": "#1C1017",
        "surface": "#2D1B24",
        "primary": "#F97316",
        "secondary": "#EF4444",
        "text": "#FEF2F2",
        "muted": "#A8A29E",
        "accent": "#FBBF24",
    },
    "forest": {
        "bg": "#0F1A14",
        "surface": "#1A2E22",
        "primary": "#22C55E",
        "secondary": "#10B981",
        "text": "#ECFDF5",
        "muted": "#86EFAC",
        "accent": "#A3E635",
    },
}

_PERSONALIZATION_TABS = (
    ("soul", "Soul"),
    ("memory", "Memory"),
    ("skills", "Skills"),
    ("schedule", "Schedule"),
    ("dreaming", "Dreaming"),
)
_HEX_COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")


def _rows(values: Iterable[Mapping[str, object]]) -> tuple[Mapping[str, object], ...]:
    return tuple(item for item in values if isinstance(item, Mapping))


def build_llm_view(
    state: Mapping[str, object],
    *,
    system: bool = False,
    denied: bool = False,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build a user or deployment-wide LLM configuration form without secrets."""
    surface = "llm_system" if system else "llm"
    title = (
        "System LLM"
        if system
        else ("Set up your AI provider" if state.get("first_run") else "LLM settings")
    )
    if denied:
        return denied_view(surface, title, "Admin role required for system LLM settings.")
    if error:
        return unavailable_view(surface, title, error)
    prefix = "chrome_llm_sys" if system else "chrome_llm"
    provider = clean_text(state.get("provider") or "openai").lower()
    raw_providers = state.get("providers") or ()
    providers = _rows(raw_providers)  # type: ignore[arg-type]
    provider_keys = [clean_text(item.get("key")) for item in providers if item.get("key")]
    if provider not in provider_keys:
        provider_keys.insert(0, provider)
    models = [clean_text(item) for item in state.get("models") or ()]
    fields = [
        field("provider", "Provider", "select", default=provider, options=provider_keys),
        field(
            "base_url",
            "Endpoint (Base URL)",
            default=state.get("base_url") or "",
            help_text="Auto-set for hosted providers; required for Custom.",
        ),
        field(
            "api_key",
            "API key",
            "password",
            help_text=(
                "A key is saved; leave blank to keep the encrypted value."
                if state.get("has_key")
                else "Stored encrypted for this account."
            ),
        ),
        field(
            "model",
            "Model",
            "select" if models else "text",
            default=state.get("model") or "",
            options=models if models else None,
        ),
    ]
    actions: list[dict[str, object]] = [
        {"label": "Load models", "action": f"{prefix}_models"},
        {"label": "Test connection", "action": f"{prefix}_test"},
        {"label": "Save", "action": f"{prefix}_save", "variant": "primary"},
    ]
    components: list[ComponentView] = [
        text(
            "The provider configuration is account-scoped and its API key is never displayed."
            if not system
            else "This credential is used only for reviewed deployment-wide background work.",
            "caption",
        ),
        badge(
            "configured" if state.get("configured") else "not configured",
            "success" if state.get("configured") else "default",
        ),
        form(fields, actions=actions, title="AI provider"),
    ]
    if state.get("configured"):
        components.append(button("Clear configuration", f"{prefix}_clear"))
    if state.get("notice"):
        components.insert(
            0, alert(state["notice"], clean_text(state.get("notice_variant") or "info"))
        )
    return build_view(surface, title, components, theme=theme, layout=layout)


def build_profile_view(
    profile: Mapping[str, object],
    *,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    if error:
        return unavailable_view("personalization", "Personalization", error)
    goals = profile.get("goals") or ()
    goals_text = "\n".join(clean_text(goal) for goal in goals)
    components = [
        form(
            [
                field("profession", "Profession", default=profile.get("profession") or ""),
                field("goals", "Goals (one per line)", "textarea", default=goals_text),
                field(
                    "personality_notes",
                    "Personality notes",
                    "textarea",
                    default=profile.get("personality_notes") or "",
                ),
            ],
            submit_action="chrome_profile_save",
            submit_label="Save profile",
        ),
        text(
            "Personality guides tone only; it never overrides safety, privacy, or "
            "compliance rules. Free text is screened for protected health information.",
            "caption",
        ),
    ]
    return build_view("personalization", "Personalization", components, theme=theme, layout=layout)


def build_memory_view(
    memories: Iterable[Mapping[str, object]],
    *,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    if error:
        return unavailable_view("personalization", "Personalization", error)
    components: list[ComponentView] = [
        text(
            "Durable, non-PHI personalization facts remembered across sessions. Edits "
            "are screened by the same PHI gate as new values.",
            "caption",
        )
    ]
    rows = _rows(memories)
    if not rows:
        components.append(alert("No memory items yet.", "info"))
    for memory in rows:
        memory_id = clean_text(memory.get("memory_id") or memory.get("id"))
        components.append(
            form(
                [
                    field(
                        "value",
                        f"{clean_text(memory.get('category') or 'general')} memory",
                        default=memory.get("value") or "",
                    )
                ],
                title=f"Added {clean_text(memory.get('created_at') or '-')}",
                actions=[
                    {
                        "label": "Save",
                        "action": "chrome_memory_update",
                        "payload": {"id": memory_id},
                    },
                    {
                        "label": "Delete",
                        "action": "chrome_memory_delete",
                        "variant": "danger",
                        "payload": {"id": memory_id},
                    },
                ],
            )
        )
    return build_view("personalization", "Personalization", components, theme=theme, layout=layout)


def build_skills_view(
    skills: Iterable[Mapping[str, object]],
    *,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    if error:
        return unavailable_view("personalization", "Personalization", error)
    components: list[ComponentView] = []
    rows = _rows(skills)
    if not rows:
        components.append(alert("No skills are available yet.", "info"))
    for skill in rows:
        body: list[ComponentView] = [
            key_value(
                [
                    ("Agent", skill.get("agent_id") or "-"),
                    ("Scope", skill.get("scope") or "-"),
                ]
            )
        ]
        if skill.get("authorized"):
            enabled = bool(skill.get("enabled"))
            body.append(
                button(
                    "Disable" if enabled else "Enable",
                    "chrome_skill_toggle",
                    {
                        "agent_id": skill.get("agent_id"),
                        "tool_name": skill.get("tool_name"),
                        "enabled": not enabled,
                    },
                )
            )
        else:
            body.append(
                alert(
                    f"Unavailable — requires the '{clean_text(skill.get('scope'))}' permission.",
                    "warning",
                )
            )
        components.append(card(skill.get("tool_name") or "Unnamed skill", body))
    return build_view("personalization", "Personalization", components, theme=theme, layout=layout)


def build_scheduler_view(
    jobs: Iterable[Mapping[str, object]],
    *,
    execution_enabled: bool,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build scheduled-job controls; run-now requires a host-supplied idempotency id."""
    if error:
        return unavailable_view("personalization", "Personalization", error)
    components: list[ComponentView] = [
        text(
            "New jobs are created in chat after confirmation. Manage existing jobs here.",
            "caption",
        )
    ]
    if not execution_enabled:
        components.append(
            alert(
                "Unattended execution is unavailable pending an administrator security review. "
                "Jobs can still be managed.",
                "warning",
            )
        )
    rows = _rows(jobs)
    if not rows:
        components.append(alert("No scheduled jobs yet.", "info"))
    for job in rows:
        job_id = clean_text(job.get("job_id") or job.get("id"))
        status = clean_text(job.get("status") or "unknown")
        actions: list[ComponentView] = []
        if status == "active":
            actions.append(button("Pause", "chrome_job_pause", {"job_id": job_id}))
            submission_id = clean_text(job.get("run_submission_id"))
            if execution_enabled and submission_id:
                actions.append(
                    button(
                        "Run now",
                        "chrome_job_run_now",
                        {"job_id": job_id, "submission_id": submission_id},
                    )
                )
        elif status == "paused":
            actions.append(button("Resume", "chrome_job_resume", {"job_id": job_id}))
        actions.append(button("Delete", "chrome_job_delete", {"job_id": job_id}, variant="danger"))
        recent_runs = _rows(job.get("recent_runs") or ())  # type: ignore[arg-type]
        run_components = [
            text(
                f"{clean_text(run.get('started_at') or '-')} — "
                f"{clean_text(run.get('outcome') or 'unknown')}"
                + (f": {clean_text(run.get('summary'))}" if run.get("summary") else ""),
                "caption",
            )
            for run in recent_runs[:5]
        ] or [text("No runs yet.", "caption")]
        components.append(
            card(
                job.get("name") or "Scheduled job",
                [
                    badge(status),
                    key_value(
                        [
                            ("Schedule", job.get("schedule") or "-"),
                            ("Next run", job.get("next_run_at") or "-"),
                            ("Last run", job.get("last_run_at") or "-"),
                        ]
                    ),
                    card("Recent runs", run_components),
                    container(actions, direction="row"),
                ],
            )
        )
    return build_view("personalization", "Personalization", components, theme=theme, layout=layout)


def build_dreaming_view(
    *,
    enabled: bool,
    sweeps: Iterable[Mapping[str, object]] = (),
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    if error:
        return unavailable_view("personalization", "Personalization", error)
    components: list[ComponentView] = [
        card(
            "Background consolidation",
            [
                badge("on" if enabled else "off", "success" if enabled else "default"),
                text(
                    "Dreaming reviews recurring signals and promotes only non-PHI items into "
                    "long-term memory."
                ),
                container(
                    [
                        button(
                            "Turn off" if enabled else "Turn on",
                            "chrome_dreaming_toggle",
                            {"enabled": not enabled},
                        ),
                        button("Run a sweep now", "chrome_dreaming_trigger", {}),
                    ],
                    direction="row",
                ),
            ],
        )
    ]
    rows = _rows(sweeps)
    if not rows:
        components.append(alert("No sweeps yet.", "info"))
    for sweep in rows:
        components.append(
            card(
                f"{clean_text(sweep.get('ran_at') or '-')} — "
                f"{clean_text(sweep.get('trigger') or 'scheduled')}",
                [
                    key_value(
                        [
                            ("Considered", sweep.get("candidates_considered") or 0),
                            ("Promoted", sweep.get("promoted_count") or 0),
                        ]
                    ),
                    text(sweep.get("summary") or "", "caption"),
                ],
            )
        )
    return build_view("personalization", "Personalization", components, theme=theme, layout=layout)


def build_pulse_view(
    digest: Iterable[Mapping[str, object]] = (),
    *,
    enabled: bool = True,
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    if not enabled:
        return build_view(
            "pulse",
            "Pulse — your digest",
            [alert("The Pulse digest is currently turned off.", "info")],
            theme=theme,
            layout=layout,
        )
    if error:
        return unavailable_view("pulse", "Pulse — your digest", error)
    components: list[ComponentView] = [
        text(
            "A read-only summary of recurring topics, goals, and preferences from recent activity."
        )
    ]
    rows = _rows(digest)
    if not rows:
        components.append(alert("Nothing to show yet — the digest fills in as you chat.", "info"))
    for item in rows:
        components.append(
            card(
                item.get("title") or item.get("value") or "Digest item",
                [
                    badge(item.get("category") or "general"),
                    text(item.get("summary") or ""),
                ],
            )
        )
    components.append(
        card(
            "Want this on a schedule?",
            [
                text(
                    'Ask in chat, for example "remind me every morning". You will be asked '
                    "to confirm before anything is scheduled."
                )
            ],
        )
    )
    return build_view("pulse", "Pulse — your digest", components, theme=theme, layout=layout)


def build_theme_view(
    current: Mapping[str, object],
    *,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build theme presets and color controls from a resolved host snapshot."""
    active = clean_text(current.get("preset"))
    supplied_colors = current.get("colors") if isinstance(current.get("colors"), Mapping) else {}
    colors = dict(THEME_PRESETS[active] if active in THEME_PRESETS else THEME_PRESETS["midnight"])
    for key, value in supplied_colors.items():  # type: ignore[union-attr]
        value_text = clean_text(value)
        if key in colors and _HEX_COLOR_RE.fullmatch(value_text):
            colors[str(key)] = value_text.upper()
    summary = (
        f"Current theme: {active.capitalize()} preset (saved)."
        if active in THEME_PRESETS
        else "Current theme: custom colors (defaults shown where unset)."
        if supplied_colors
        else "Current theme: default (Midnight)."
    )
    components: list[ComponentView] = []
    if current:
        apply_properties: dict[str, object] = {
            "message": "Theme applied",
            "colors": colors,
        }
        if active in THEME_PRESETS:
            apply_properties["preset"] = active
        components.append(ComponentView("theme_apply", apply_properties))
    components.extend([text(summary, "caption"), text("Presets", "h3")])
    for name, preset_colors in THEME_PRESETS.items():
        components.append(
            card(
                name.capitalize() + (" — Active" if name == active else ""),
                [
                    key_value((key.capitalize(), value) for key, value in preset_colors.items()),
                    button(
                        "Applied" if name == active else f"Apply {name.capitalize()}",
                        "chrome_theme_preset",
                        {"preset": name},
                        disabled=name == active,
                    ),
                ],
            )
        )
    components.append(text("Fine-tune colors", "h3"))
    for key, value in colors.items():
        components.append(
            ComponentView(
                "color_picker",
                {"color_key": key, "value": value, "label": key.capitalize()},
            )
        )
    return build_view("theme", "Theme", components, theme=theme, layout=layout)


def build_personalization_view(
    tab: str,
    *,
    profile: Mapping[str, object] | None = None,
    memories: Iterable[Mapping[str, object]] = (),
    skills: Iterable[Mapping[str, object]] = (),
    jobs: Iterable[Mapping[str, object]] = (),
    execution_enabled: bool = False,
    dreaming_enabled: bool = True,
    sweeps: Iterable[Mapping[str, object]] = (),
    error: str | None = None,
    theme: ThemeView | None = None,
    layout: LayoutView | None = None,
) -> ChromeViewModel:
    """Build the shared tab shell around one personalization subview."""
    valid_tabs = {key for key, _label in _PERSONALIZATION_TABS}
    active = tab if tab in valid_tabs else "soul"
    tabs = container(
        [
            button(
                label,
                "chrome_open",
                {"surface": "personalization", "params": {"tab": key}},
                disabled=key == active,
            )
            for key, label in _PERSONALIZATION_TABS
        ],
        direction="row",
    )
    if active == "soul":
        inner = build_profile_view(profile or {}, error=error, theme=theme, layout=layout)
    elif active == "memory":
        inner = build_memory_view(memories, error=error, theme=theme, layout=layout)
    elif active == "skills":
        inner = build_skills_view(skills, error=error, theme=theme, layout=layout)
    elif active == "schedule":
        inner = build_scheduler_view(
            jobs,
            execution_enabled=execution_enabled,
            error=error,
            theme=theme,
            layout=layout,
        )
    else:
        inner = build_dreaming_view(
            enabled=dreaming_enabled,
            sweeps=sweeps,
            error=error,
            theme=theme,
            layout=layout,
        )
    return build_view(
        "personalization",
        "Personalization",
        [tabs, *inner.components],
        theme=theme,
        layout=layout,
    )


__all__ = [
    "THEME_PRESETS",
    "build_dreaming_view",
    "build_llm_view",
    "build_memory_view",
    "build_personalization_view",
    "build_profile_view",
    "build_pulse_view",
    "build_scheduler_view",
    "build_skills_view",
    "build_theme_view",
]
