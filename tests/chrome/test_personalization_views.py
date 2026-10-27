"""Tests for src/astralprojection/chrome/personalization.py: LLM, profile, memory,
skills, scheduler, dreaming, pulse, theme and shell tab routing states.
"""

from __future__ import annotations

from astralprojection.chrome import render_html
from astralprojection.models import ThemeView
from astralprojection.chrome.personalization import (
    THEME_COLOR_ROLES,
    THEME_PRESETS,
    build_dreaming_view,
    build_llm_view,
    build_memory_view,
    build_personalization_view,
    build_profile_view,
    build_pulse_view,
    build_scheduler_view,
    build_skills_view,
    build_theme_view,
)


def _actions(view) -> list[str]:
    found: list[str] = []

    def visit(value) -> None:
        if isinstance(value, dict):
            if isinstance(value.get("action"), str):
                found.append(value["action"])
            if isinstance(value.get("submit_action"), str):
                found.append(value["submit_action"])
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(view.to_dict())
    return found


def _helps(view) -> list[str]:
    found: list[str] = []

    def visit(value) -> None:
        if isinstance(value, dict):
            if "help" in value:
                found.append(value["help"])
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(view.to_dict())
    return found


def test_llm_user_and_system_views_never_emit_secret_values() -> None:
    denied = build_llm_view({}, system=True, denied=True)
    assert "Admin role required" in render_html(denied)
    assert _actions(denied) == []
    assert "Provider store offline" in render_html(
        build_llm_view({}, error="Provider store offline")
    )
    first_run = build_llm_view(
        {
            "first_run": True,
            "provider": "openai",
            "providers": [
                {"key": "openai", "label": "OpenAI"},
                {"key": "custom", "label": "Custom"},
            ],
            "base_url": "https://example.invalid/v1",
            "model": "gpt-test",
            "models": ["gpt-a", "gpt-test"],
            "has_key": True,
            "configured": True,
            "api_key": "MUST_NOT_APPEAR",
            "notice": "Connection succeeded",
            "notice_variant": "success",
        }
    )
    encoded = str(first_run.to_dict())
    assert "MUST_NOT_APPEAR" not in encoded
    assert first_run.title == "Set up your AI provider"
    actions = set(_actions(first_run))
    assert {
        "chrome_llm_models",
        "chrome_llm_test",
        "chrome_llm_save",
        "chrome_llm_clear",
    } <= actions
    html = render_html(first_run)
    assert "leave blank" not in html
    assert "Stored encrypted" not in html
    assert "never displayed" not in html
    assert "Connection succeeded" in html
    assert _helps(first_run) == []
    system = build_llm_view(
        {"provider": "unknown", "providers": [], "configured": False}, system=True
    )
    assert {"chrome_llm_sys_models", "chrome_llm_sys_test", "chrome_llm_sys_save"} <= set(
        _actions(system)
    )
    assert _helps(system) == []
    assert "deployment-wide" not in render_html(system)
    assert "chrome_llm_sys_clear" not in _actions(system)


def test_profile_and_memory_views_cover_phi_safe_empty_and_mutation_states() -> None:
    assert "Personalization offline" in render_html(
        build_profile_view({}, error="Personalization offline")
    )
    profile = build_profile_view(
        {
            "profession": "Researcher <script>",
            "goals": ["Goal one", "Goal two"],
            "personality_notes": "Concise",
        }
    )
    html = render_html(profile)
    assert "<script>" not in html
    assert "Goal one\nGoal two" in html
    assert "never overrides safety" not in html
    assert "protected health information" not in html
    assert _actions(profile) == ["chrome_profile_save"]
    assert "Memory offline" in render_html(build_memory_view([], error="Memory offline"))
    empty = build_memory_view([])
    assert "No memory items" not in render_html(empty)
    assert "Durable" not in render_html(empty)
    assert empty.to_dict()["components"] == []
    memory = build_memory_view(
        [
            {"id": "m1", "category": "goal", "value": "Finish paper", "created_at": "today"},
            {"memory_id": "m2", "value": "Learn", "created_at": None},
        ]
    )
    assert _actions(memory).count("chrome_memory_update") == 2
    assert _actions(memory).count("chrome_memory_delete") == 2


def test_skills_authorization_is_visible_and_fail_closed() -> None:
    assert "Permissions offline" in render_html(build_skills_view([], error="Permissions offline"))
    assert build_skills_view([]).to_dict()["components"] == []
    view = build_skills_view(
        [
            {
                "agent_id": "research",
                "tool_name": "search_web",
                "scope": "tools:search",
                "authorized": True,
                "enabled": True,
            },
            {
                "agent_id": "files",
                "tool_name": "write_file",
                "scope": "tools:files",
                "authorized": False,
            },
        ]
    )
    assert _actions(view) == ["chrome_skill_toggle"]
    html = render_html(view)
    assert "Unavailable" in html
    assert "Disable" in html


def test_scheduler_requires_host_supplied_idempotency_for_run_now() -> None:
    assert "Scheduler offline" in render_html(
        build_scheduler_view([], execution_enabled=True, error="Scheduler offline")
    )
    disabled = build_scheduler_view([], execution_enabled=False)
    assert "Unattended execution is unavailable" in render_html(disabled)
    assert "No scheduled jobs" not in render_html(disabled)
    assert "created in chat" not in render_html(disabled)
    jobs = build_scheduler_view(
        [
            {
                "id": "j1",
                "name": "Daily digest",
                "status": "active",
                "schedule": "daily at 09:00 UTC",
                "next_run_at": "tomorrow",
                "last_run_at": "today",
                "run_submission_id": "00000000-0000-4000-8000-000000000001",
                "recent_runs": [
                    {"started_at": "today", "outcome": "success", "summary": "Sent"},
                    {"started_at": "yesterday", "outcome": "failure"},
                ],
            },
            {"id": "j2", "name": "Paused", "status": "paused", "recent_runs": []},
            {"id": "j3", "name": "No id", "status": "active"},
            {"id": "j4", "name": "Done", "status": "completed"},
        ],
        execution_enabled=True,
    )
    actions = _actions(jobs)
    assert actions.count("chrome_job_run_now") == 1
    assert actions.count("chrome_job_pause") == 2
    assert actions.count("chrome_job_resume") == 1
    assert actions.count("chrome_job_delete") == 4
    assert "No runs yet" not in render_html(jobs)
    assert "Sent" in render_html(jobs)
    run_cards = [
        part["title"]
        for job in jobs.to_dict()["components"]
        for part in job["content"]
        if part["type"] == "card"
    ]
    assert run_cards == ["Recent runs"]
    no_run = build_scheduler_view(
        [{"id": "j", "status": "active", "run_submission_id": "id"}],
        execution_enabled=False,
    )
    assert "chrome_job_run_now" not in _actions(no_run)


def test_dreaming_and_pulse_states() -> None:
    assert "Dreaming offline" in render_html(
        build_dreaming_view(enabled=True, error="Dreaming offline")
    )
    empty = build_dreaming_view(enabled=False)
    assert "No sweeps" not in render_html(empty)
    assert "Dreaming reviews" not in render_html(empty)
    assert {"chrome_dreaming_toggle", "chrome_dreaming_trigger"} <= set(_actions(empty))
    sweeps = build_dreaming_view(
        enabled=True,
        sweeps=[
            {
                "ran_at": "today",
                "trigger": "manual",
                "candidates_considered": 5,
                "promoted_count": 2,
                "summary": "Promoted goals",
            }
        ],
    )
    assert "Promoted goals" in render_html(sweeps)
    assert "turned off" in render_html(build_pulse_view(enabled=False))
    assert "Pulse offline" in render_html(build_pulse_view(error="Pulse offline"))
    quiet = render_html(build_pulse_view())
    assert "Nothing to show yet" not in quiet
    assert "read-only summary" not in quiet
    assert "Want this on a schedule" not in quiet
    pulse = build_pulse_view(
        [
            {"title": "Clinical AI", "category": "topic", "summary": "Recurring interest"},
            {"value": "Publish", "category": "goal"},
        ]
    )
    html = render_html(pulse)
    assert "Clinical AI" in html and "Publish" in html
    assert "Want this on a schedule" not in html


def test_theme_view_preserves_presets_custom_colors_and_shared_types() -> None:
    default = build_theme_view({})
    assert "default (Graphite)" in render_html(default)
    assert len(THEME_PRESETS) == 6
    assert next(iter(THEME_PRESETS)) == "graphite"
    assert _actions(default).count("chrome_theme_preset") == 6
    cards = [item for item in default.to_dict()["components"] if item.get("type") == "card"]
    assert [item["title"] for item in cards][:2] == ["Graphite", "Midnight"]
    types = [item["type"] for item in default.to_dict()["components"]]
    assert types.count("color_picker") == 7
    pickers = [item["color_key"] for item in default.to_dict()["components"] if item.get("type") == "color_picker"]
    assert pickers == list(THEME_COLOR_ROLES)
    assert "theme_apply" not in types
    ocean = build_theme_view({"preset": "ocean"})
    ocean_html = render_html(ocean)
    assert "Ocean preset" in ocean_html
    assert _actions(ocean).count("chrome_theme_preset") == 6
    assert ocean.to_dict()["components"][0]["type"] == "theme_apply"
    assert ocean.to_dict()["components"][0]["preset"] == "ocean"
    assert ocean.to_dict()["components"][0]["colors"] == dict(THEME_PRESETS["ocean"])
    applied = [
        item
        for item in ocean.to_dict()["components"]
        if item.get("type") == "button" and item.get("label") == "Applied"
    ]
    assert applied == []
    assert 'aria-disabled="true"' in ocean_html
    custom = build_theme_view(
        {"colors": {"primary": "#112233", "unknown": "#000000", "accent": "invalid"}}
    )
    payload = custom.to_dict()["components"][0]
    assert payload["type"] == "theme_apply"
    assert "preset" not in payload
    assert payload["colors"]["primary"] == "#112233"
    assert payload["colors"]["accent"] == THEME_PRESETS["graphite"]["accent"]
    assert "custom colors" in render_html(custom)


def test_personalization_shell_routes_tabs_and_defaults_invalid_tab() -> None:
    soul = build_personalization_view("invalid", profile={"profession": "Engineer"})
    assert "chrome_profile_save" in _actions(soul)
    assert _actions(soul).count("chrome_open") == 5
    memory = build_personalization_view("memory", memories=[])
    assert "No memory" not in render_html(memory)
    assert "chrome_open" in _actions(memory)
    skills = build_personalization_view("skills", skills=[])
    assert "No skills" not in render_html(skills)
    schedule = build_personalization_view("schedule", jobs=[], execution_enabled=False)
    assert "No scheduled jobs" not in render_html(schedule)
    dreaming = build_personalization_view("dreaming", dreaming_enabled=False)
    assert "Background consolidation" in render_html(dreaming)
    failed = build_personalization_view("soul", error="Profile failed")
    assert "Profile failed" in render_html(failed)


def test_graphite_is_the_first_preset_and_the_default_theme_name() -> None:
    assert list(THEME_PRESETS)[0] == "graphite"
    assert dict(THEME_PRESETS["graphite"]) == {
        "bg": "#121214",
        "surface": "#1B1B1F",
        "primary": "#7C3AED",
        "secondary": "#6E6E78",
        "text": "#ECECEF",
        "muted": "#93939B",
        "accent": "#A78BFA",
        "success": "#5EC28F",
        "warning": "#D4A94A",
        "error": "#E17272",
        "info": "#9A8CF2",
        "on_error": "#121214",
        "field_border": "#6E6E75",
    }
    assert dict(THEME_PRESETS["midnight"])["bg"] == "#0F1221"
    assert ThemeView().name == "graphite"
    assert build_theme_view({}).theme.name == "graphite"
    saved = build_theme_view({"preset": "midnight"})
    assert "Midnight preset" in render_html(saved)
    assert saved.to_dict()["components"][0]["preset"] == "midnight"
    assert saved.to_dict()["components"][0]["colors"]["bg"] == "#0F1221"
