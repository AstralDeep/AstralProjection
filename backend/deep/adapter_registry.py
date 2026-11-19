'''backend/deep/adapter_registry.py
Central registry mapping contract identifiers to their handling callables.
Existing adapters are imported and registered here. The new ``TerminalAdapter``
is added to support interactive terminal controls.
''' 

from typing import Callable, Dict

# Existing adapters – placeholders for the real imports in the production code.
from backend.deep.console_adapter import ConsoleAdapter  # noqa: F401
from backend.deep.chat_adapter import ChatAdapter  # noqa: F401
# New terminal adapter import.
from backend.deep.terminal_adapter import TerminalAdapter

# ---------------------------------------------------------------------------
# Registry structure – keys are contract strings, values are callables with the
# signature ``(action: str, payload: dict, context: dict) -> dict``.
# ---------------------------------------------------------------------------
ADAPTERS: Dict[str, Callable[[str, dict, dict], dict]] = {
    "console/v2": ConsoleAdapter.handle,
    "chat/v1": ChatAdapter.handle,
    # Register the terminal adapter under its contract identifier.
    TerminalAdapter.CONTRACT: TerminalAdapter.handle,
}


def get_adapter(contract: str) -> Callable[[str, dict, dict], dict]:
    """Retrieve the handler for a given contract.

    Raises
    ------
    KeyError
        If the contract is not known to the registry.
    """
    return ADAPTERS[contract]
