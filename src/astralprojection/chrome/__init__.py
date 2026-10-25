"""Re-exports _components.py's pure shared-chrome presentation builders as the
astralprojection.chrome package entry point used by
orchestrator/projection_surfaces/*.py and the chrome test suite.
"""

from ._components import code_block, render_html

__all__ = [
    "build_terminal_monitor_view",
    "build_terminal_panel_view",
    "build_terminal_view",
    "code_block",
    "render_html",
    "sanitize_terminal_output",
]


def __getattr__(name):
    if name in {"build_terminal_monitor_view", "build_terminal_panel_view", "build_terminal_view"}:
        from . import terminal

        return getattr(terminal, name)
    if name == "sanitize_terminal_output":
        from webrender.terminal import sanitize_terminal_output

        return sanitize_terminal_output
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
