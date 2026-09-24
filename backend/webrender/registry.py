"""Registry mapping client render targets to their renderer callables, letting
webrender/targets/* add a new target without changing astralprims or agent code; used
by render_for_target().
"""

from __future__ import annotations

import logging
from typing import Any, Callable, Dict, List, Optional

from .renderer import PRIMITIVE_RENDERERS, render as render_web
from .voice import render_voice
from .aom import render_aom

logger = logging.getLogger("webrender")

TARGET_RENDERERS: Dict[str, Callable[[List[Dict[str, Any]], Any], Any]] = {
    "web": render_web,
    "voice": render_voice,
    "aom": render_aom,
}

DEFAULT_TARGET = "web"


def register_target(name: str, renderer: Callable[[List[Dict[str, Any]], Any], Any]) -> None:
    TARGET_RENDERERS[name] = renderer


def get_renderer(type_name: str) -> Optional[Callable[[Dict[str, Any]], str]]:
    return PRIMITIVE_RENDERERS.get(type_name)


def render_for_target(target: Optional[str], components: List[Dict[str, Any]], profile: Any = None) -> Any:
    key = (target or DEFAULT_TARGET).lower()
    fn = TARGET_RENDERERS.get(key)
    if fn is None:
        logger.warning("webrender: unknown client target %r — falling back to %r", target, DEFAULT_TARGET)
        fn = TARGET_RENDERERS[DEFAULT_TARGET]
    return fn(components, profile)


def target_for_profile(profile: Any) -> str:
    import os
    if os.getenv("FF_NATIVE_TARGETS", "false").strip().lower() not in ("1", "true", "yes", "on"):
        return DEFAULT_TARGET
    explicit = getattr(profile, "render_target", None)
    if explicit and str(explicit).lower() in TARGET_RENDERERS:
        return str(explicit).lower()
    dt = getattr(profile, "device_type", None)
    dt_val = getattr(dt, "value", dt)
    if dt_val == "voice" and "voice" in TARGET_RENDERERS:
        return "voice"
    return DEFAULT_TARGET
