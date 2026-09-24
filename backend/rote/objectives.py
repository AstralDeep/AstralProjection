"""Declarative multi-objective scoring (width_fit, interaction_cost, glanceability,
speakability) behind FF_ADAPTIVE_OBJECTIVES: score_adaptation weights the four into
one device-fit score for ui_designer.py's best_adaptation ranking.
"""

from __future__ import annotations

import os
from typing import Any, Dict, List, Mapping, Optional

_WIDE_TYPES: frozenset = frozenset(
    {
        "table",
        "grid",
        "plotly_chart",
        "line_chart",
        "bar_chart",
        "chart",
        "dataframe",
        "code",
        "timeline",
    }
)

_NARROW_TYPES: frozenset = frozenset(
    {
        "text",
        "metric",
        "badge",
        "alert",
        "rating",
        "keyvalue",
    }
)

_INTERACTIVE_TYPES: frozenset = frozenset(
    {
        "button",
        "input",
        "param_picker",
        "file_upload",
        "select",
        "form",
        "slider",
    }
)

_HIGH_GLANCE_TYPES: frozenset = frozenset(
    {"metric", "badge", "hero", "rating", "alert"}
)
_LOW_GLANCE_TYPES: frozenset = frozenset(
    {"table", "code", "plotly_chart", "dataframe", "grid"}
)

_HIGH_SPEAK_TYPES: frozenset = frozenset(
    {"text", "alert", "list", "list_", "metric", "keyvalue"}
)
_LOW_SPEAK_TYPES: frozenset = frozenset(
    {
        "chart",
        "line_chart",
        "bar_chart",
        "plotly_chart",
        "table",
        "image",
        "code",
        "grid",
        "dataframe",
    }
)


DEFAULT_WEIGHTS: Dict[str, float] = {
    "width_fit": 0.35,
    "interaction_cost": 0.2,
    "glanceability": 0.25,
    "speakability": 0.2,
}


def objectives_enabled() -> bool:
    return os.getenv("FF_ADAPTIVE_OBJECTIVES", "false").strip().lower() in (
        "1",
        "true",
        "yes",
        "on",
    )


def _device(d: Optional[Mapping[str, Any]]) -> Dict[str, Any]:
    d = d or {}
    try:
        max_cols = int(d.get("max_grid_columns", 12))
    except (TypeError, ValueError):
        max_cols = 12
    return {
        "max_grid_columns": max_cols,
        "is_voice": bool(d.get("is_voice", False)),
        "is_small": bool(d.get("is_small", False)),
    }


def _ctype(component: Mapping[str, Any]) -> str:
    if not isinstance(component, Mapping):
        return ""
    return str(component.get("type", "")).strip().lower()


def _clamp01(x: float) -> float:
    if x < 0.0:
        return 0.0
    if x > 1.0:
        return 1.0
    return float(x)


def width_fit(component: Mapping[str, Any], device: Optional[Mapping[str, Any]]) -> float:
    dev = _device(device)
    ctype = _ctype(component)

    if dev["is_voice"]:
        if ctype in _WIDE_TYPES:
            return 0.1
        if ctype in _NARROW_TYPES:
            return 0.9
        return 0.5

    roominess = _clamp01((dev["max_grid_columns"] - 2) / 10.0)

    if ctype in _WIDE_TYPES:
        score = 0.2 + 0.8 * roominess
        if dev["is_small"]:
            score = min(score, 0.45)
        return _clamp01(score)

    if ctype in _NARROW_TYPES:
        return _clamp01(0.85 + 0.15 * roominess)

    score = 0.55 + 0.35 * roominess
    if dev["is_small"]:
        score = min(score, 0.7)
    return _clamp01(score)


def interaction_cost(
    component: Mapping[str, Any], device: Optional[Mapping[str, Any]]
) -> float:
    dev = _device(device)
    ctype = _ctype(component)

    if ctype in _INTERACTIVE_TYPES:
        if dev["is_voice"]:
            return 0.1
        if dev["is_small"]:
            return 0.5
        return 0.95

    return 1.0


def glanceability(
    component: Mapping[str, Any], device: Optional[Mapping[str, Any]]
) -> float:
    dev = _device(device)
    ctype = _ctype(component)
    constrained = dev["is_small"] or dev["is_voice"]

    if ctype in _HIGH_GLANCE_TYPES:
        base = 0.9
        if constrained:
            base = min(1.0, base + 0.1)
        return _clamp01(base)

    if ctype in _LOW_GLANCE_TYPES:
        base = 0.3
        if constrained:
            base = max(0.0, base - 0.1)
        return _clamp01(base)

    base = 0.6
    if constrained:
        base = min(1.0, base + 0.05)
    return _clamp01(base)


def speakability(
    component: Mapping[str, Any], device: Optional[Mapping[str, Any]]
) -> float:
    dev = _device(device)
    if not dev["is_voice"]:
        return 1.0

    ctype = _ctype(component)
    if ctype in _HIGH_SPEAK_TYPES:
        return 0.95
    if ctype in _LOW_SPEAK_TYPES:
        return 0.1
    return 0.5


_OBJECTIVES = {
    "width_fit": width_fit,
    "interaction_cost": interaction_cost,
    "glanceability": glanceability,
    "speakability": speakability,
}


def score_adaptation(
    component: Mapping[str, Any],
    device: Optional[Mapping[str, Any]],
    weights: Optional[Mapping[str, float]] = None,
) -> float:
    weights = weights or {}
    total_weight = 0.0
    weighted_sum = 0.0
    for name, scorer in _OBJECTIVES.items():
        try:
            w = float(weights.get(name, DEFAULT_WEIGHTS[name]))
        except (TypeError, ValueError):
            w = DEFAULT_WEIGHTS[name]
        if w <= 0.0:
            continue
        weighted_sum += w * scorer(component, device)
        total_weight += w

    if total_weight <= 0.0:
        return 0.0
    return _clamp01(weighted_sum / total_weight)


def best_adaptation(
    candidates: List[Mapping[str, Any]],
    device: Optional[Mapping[str, Any]],
    weights: Optional[Mapping[str, float]] = None,
) -> Dict[str, Any]:
    if not candidates:
        raise ValueError("best_adaptation requires a non-empty candidate list")

    best = candidates[0]
    best_score = score_adaptation(best, device, weights)
    for candidate in candidates[1:]:
        s = score_adaptation(candidate, device, weights)
        if s > best_score:
            best, best_score = candidate, s
    return dict(best)
