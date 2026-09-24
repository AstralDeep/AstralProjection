"""The orchestrator's server-side render layer: turns astralprims component dicts,
already ROTE-adapted per device, into a client target's output, web HTML by default;
new targets register via register_target() in webrender.registry.
"""

from .renderer import (  # noqa: F401
    allowed_primitive_types,
    render,
    render_one,
    render_component_fragment,
    render_workspace,
    render_export_document,
    provenance_enabled,
    provenance_of,
    esc,
    safe_url,
)
from .registry import (  # noqa: F401
    render_for_target,
    target_for_profile,
    register_target,
    get_renderer,
    TARGET_RENDERERS,
    PRIMITIVE_RENDERERS,
)

__all__ = [
    "render",
    "render_one",
    "render_component_fragment",
    "render_workspace",
    "render_export_document",
    "render_for_target",
    "target_for_profile",
    "register_target",
    "get_renderer",
    "esc",
    "safe_url",
    "TARGET_RENDERERS",
    "PRIMITIVE_RENDERERS",
]
