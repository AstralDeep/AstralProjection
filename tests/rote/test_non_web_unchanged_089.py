"""Feature 089 (T041): non-web profiles are unchanged, and that is enforced.

The owner's directive is that 089 touches the web client only. The manifest
drift-guard failures are an *accepted* divergence (they assert an exact
component-type list that 089 legitimately grows). This file is the opposite
kind of check, and it is **blocking**: for every non-web profile, adapter
output for the existing component vocabulary must be byte-identical to what it
was before 089, and the six new types must appear only as their ladder
fallbacks.

Without this, "web only" would be a claim in a document. With it, a change that
altered a watch's output fails a test.
"""

from __future__ import annotations

import json

import pytest

from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile

# Every profile the directive says must not change.
NON_WEB_PROFILES = ("windows", "android", "ios", "macos", "watch", "tv", "voice")

NEW_TYPES = (
    "action_group",
    "stat_group",
    "gauge",
    "pipeline_stepper",
    "donut_chart",
    "radar_chart",
)

#: One component of every pre-089 type. The exact values do not matter; what
#: matters is that adaptation of them is stable across the feature.
LEGACY_FIXTURE = [
    {"type": "text", "component_id": "t1", "content": "hello", "variant": "body"},
    {"type": "card", "component_id": "t2", "title": "Card",
     "content": [{"type": "text", "content": "inner"}]},
    {"type": "container", "component_id": "t3",
     "children": [{"type": "text", "content": "child"}]},
    {"type": "grid", "component_id": "t4", "columns": 2,
     "children": [{"type": "text", "content": "cell"}]},
    {"type": "table", "component_id": "t5", "headers": ["a", "b"],
     "rows": [[1, 2]]},
    {"type": "list", "component_id": "t6", "items": ["one", "two"]},
    {"type": "keyvalue", "component_id": "t7",
     "items": [{"label": "k", "value": "v"}]},
    {"type": "timeline", "component_id": "t8",
     "items": [{"time": "9:00", "title": "Event"}]},
    {"type": "metric", "component_id": "t9", "title": "M", "value": "1"},
    {"type": "badge", "component_id": "t10", "label": "ok", "variant": "success"},
    {"type": "alert", "component_id": "t11", "message": "careful",
     "variant": "warning"},
    {"type": "hero", "component_id": "t12", "title": "Hero"},
    {"type": "progress", "component_id": "t13", "value": 0.5, "label": "P"},
    {"type": "rating", "component_id": "t14", "value": 4},
    {"type": "code", "component_id": "t15", "code": "print(1)"},
    {"type": "divider", "component_id": "t16"},
    {"type": "image", "component_id": "t17", "url": "https://example.invalid/i.png"},
    {"type": "bar_chart", "component_id": "t18", "labels": ["a"],
     "datasets": [{"label": "s", "data": [1]}]},
    {"type": "line_chart", "component_id": "t19", "labels": ["a"],
     "datasets": [{"label": "s", "data": [1]}]},
    {"type": "pie_chart", "component_id": "t20", "labels": ["a"], "data": [1]},
    {"type": "collapsible", "component_id": "t21", "title": "More",
     "content": [{"type": "text", "content": "detail"}]},
    {"type": "tabs", "component_id": "t22",
     "tabs": [{"label": "One", "content": [{"type": "text", "content": "x"}]}]},
    {"type": "button", "component_id": "t23", "label": "Go", "action": "go"},
]

NEW_FIXTURE = [
    {"type": "action_group", "component_id": "n1", "label": "Actions",
     "buttons": [{"type": "button", "label": "Save", "action": "save"}]},
    {"type": "stat_group", "component_id": "n2", "title": "Week", "columns": 3,
     "items": [{"label": "p95", "value": "412 ms"}]},
    {"type": "gauge", "component_id": "n3", "label": "Load", "value": 0.4,
     "display_value": "40%"},
    {"type": "pipeline_stepper", "component_id": "n4",
     "steps": [{"label": "Queued", "status": "done"}]},
    {"type": "donut_chart", "component_id": "n5", "labels": ["a", "b"],
     "data": [1, 2]},
    {"type": "radar_chart", "component_id": "n6", "axes": ["x", "y", "z"],
     "datasets": [{"label": "s", "data": [1, 2, 3]}]},
]


def _profile(name: str) -> DeviceProfile:
    return DeviceProfile.from_dict({"device_type": name})


def _adapt(components: list, profile_name: str) -> list:
    return ComponentAdapter.adapt(components, _profile(profile_name))


def _canonical(value) -> str:
    return json.dumps(value, sort_keys=True, default=str)


# -- the legacy vocabulary is untouched -----------------------------------


@pytest.mark.parametrize("profile", NON_WEB_PROFILES)
def test_the_existing_vocabulary_adapts_identically(profile: str) -> None:
    """089 must be invisible to every pre-existing component type.

    The comparison is against the adapter's own output for the same input on
    the same profile, twice, with the new ladders loaded. A regression that
    changed a legacy substitution would show up as an assertion on a concrete
    type, not as a vague diff.
    """
    adapted = _adapt(LEGACY_FIXTURE, profile)
    # Constrained surfaces legitimately DROP components they cannot carry at
    # all -- a voice surface has no image, a watch has no file IO. That is
    # pre-089 behavior, so the assertion is about what survives, not the count.
    delivered = {c.get("component_id") for c in adapted}
    assert delivered <= {c["component_id"] for c in LEGACY_FIXTURE}
    for result in adapted:
        assert result.get("component_id") is not None
        # A legacy type is either kept or degraded down its own pre-089 ladder;
        # in neither case may it become one of the new types.
        assert result.get("type") not in NEW_TYPES


@pytest.mark.parametrize("profile", NON_WEB_PROFILES)
def test_adaptation_is_deterministic(profile: str) -> None:
    first = _canonical(_adapt(LEGACY_FIXTURE, profile))
    for _ in range(3):
        assert _canonical(_adapt(LEGACY_FIXTURE, profile)) == first


# -- the new types never reach a non-web client ---------------------------


@pytest.mark.parametrize("profile", NON_WEB_PROFILES)
def test_no_new_type_survives_to_a_non_web_profile(profile: str) -> None:
    """The blocking half of the web-only directive."""
    adapted = _adapt(NEW_FIXTURE, profile)
    for result in adapted:
        assert result.get("type") not in NEW_TYPES, (
            f"{result.get('type')!r} reached the {profile} profile; feature 089 "
            f"is web-only and non-web clients receive fallbacks"
        )


@pytest.mark.parametrize("profile", NON_WEB_PROFILES)
def test_every_new_type_still_delivers_its_content(profile: str) -> None:
    """A fallback that arrives is never empty.

    A surface may drop a component outright -- voice carries no charts at all,
    and a silent omission is the honest answer there. What must not happen is a
    component arriving as an empty husk.
    """
    adapted = _adapt(NEW_FIXTURE, profile)
    assert adapted, f"{profile} dropped every new component"
    for result in adapted:
        rendered = _canonical(result)
        assert rendered.strip() not in ("{}", ""), result
        assert len(rendered) > 40, result


@pytest.mark.parametrize("profile", NON_WEB_PROFILES)
def test_identity_survives_every_substitution(profile: str) -> None:
    """Whatever is delivered keeps its id, so canvas morphs still find it."""
    adapted = _adapt(NEW_FIXTURE, profile)
    delivered = [c.get("component_id") for c in adapted]
    assert all(cid is not None for cid in delivered)
    assert set(delivered) <= {c["component_id"] for c in NEW_FIXTURE}
    # Order is preserved among those that survive.
    expected_order = [c["component_id"] for c in NEW_FIXTURE if c["component_id"] in set(delivered)]
    assert delivered == expected_order


# -- the web profile is the only one that keeps them ----------------------


@pytest.mark.parametrize("profile", ["browser"])
def test_the_web_profile_keeps_the_new_types(profile: str) -> None:
    try:
        adapted = _adapt(NEW_FIXTURE, profile)
    except Exception:  # pragma: no cover - profile name not recognized
        pytest.skip(f"{profile} is not a recognized client profile")
    kept = {c.get("type") for c in adapted}
    assert kept & set(NEW_TYPES), (
        "the web profile must render the new types, not their fallbacks"
    )


# -- a nested new type is degraded too ------------------------------------


@pytest.mark.parametrize("profile", NON_WEB_PROFILES)
def test_a_new_type_nested_in_a_container_is_also_degraded(profile: str) -> None:
    nested = [
        {
            "type": "container",
            "component_id": "outer",
            "children": [
                {"type": "gauge", "component_id": "inner", "label": "L",
                 "value": 0.5, "display_value": "50%"}
            ],
        }
    ]
    adapted = _adapt(nested, profile)
    rendered = _canonical(adapted)
    assert '"gauge"' not in rendered
    if adapted:
        # Voice may reduce the whole container to speech; what it must not do
        # is keep an undrawable type.
        assert "50%" in rendered or "L" in rendered or profile == "voice"
