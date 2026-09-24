"""Minimal second render target (text-only) that proves the multi-target registration
seam in registry.py without depending on the web renderer or changing astralprims.
"""

from __future__ import annotations

import html
from typing import Any, List, Dict

from ..registry import register_target

TARGET_NAME = "stubtext"


def render_stub(components: List[Dict[str, Any]], profile: Any = None) -> str:
    lines = []
    for c in components or []:
        if isinstance(c, dict) and c.get("type") == "text":
            lines.append(html.escape(str(c.get("content", ""))))
    return "\n".join(lines)


def install() -> None:
    register_target(TARGET_NAME, render_stub)
