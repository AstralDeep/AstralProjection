"""Re-exports _components.py's pure shared-chrome presentation builders as the
astralprojection.chrome package entry point used by
orchestrator/projection_surfaces/*.py and the chrome test suite.
"""

from ._components import code_block, render_html
from .terminal import build_terminal_monitor_view, build_terminal_view

__all__ = [
    "build_terminal_monitor_view",
    "build_terminal_view",
    "code_block",
    "render_html",
]
