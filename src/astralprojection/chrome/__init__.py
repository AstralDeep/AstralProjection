"""Re-exports _components.py's pure shared-chrome presentation builders as the
astralprojection.chrome package entry point used by
orchestrator/projection_surfaces/*.py and the chrome test suite.
"""

from ._components import render_html

__all__ = ["render_html"]
