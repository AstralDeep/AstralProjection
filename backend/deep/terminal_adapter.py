'''backend/deep/terminal_adapter.py
Defines the Deep‑side adapter for the `terminal/v1` contract.
It validates the incoming action, checks explicit consent, and forwards the request
to the target peer via the normal dispatch mechanism.
''' 

from __future__ import annotations

from typing import Any, Dict

from backend.dispatch import dispatch_action
from backend.auth import authorize_terminal_control


class TerminalAdapter:
    """Adapter handling interactive terminal control actions.

    The contract version is defined in the UI protocol as ``terminal/v1``. The
    adapter is registered in ``backend/deep/adapter_registry.py``.
    """

    CONTRACT = "terminal/v1"
    SUPPORTED_ACTIONS = {"input", "resize", "interrupt", "close"}

    @staticmethod
    def handle(action: str, payload: Dict[str, Any], context: Dict[str, Any]) -> Dict[str, Any]:
        """Validate and forward a terminal control request.

        Parameters
        ----------
        action: str
            One of ``input``, ``resize``, ``interrupt`` or ``close``.
        payload: dict
            Action‑specific data – e.g. ``{"data": "..."}`` for ``input`` or
            ``{"cols": 80, "rows": 24}`` for ``resize``.
        context: dict
            Request context supplied by the WebSocket layer. Must contain the
            ``peer_id`` of the authorized executing node and the caller's
            authentication information.

        Returns
        -------
        dict
            Minimal acknowledgement that the request has been queued.
        """
        # ---------------------------------------------------------------------
        # 1️⃣  Authorization – only callers with explicit consent may issue a
        #     terminal control command. The helper encapsulates the roster‑list
        #     and mesh‑ticket checks introduced in Spec 106.
        # ---------------------------------------------------------------------
        if not authorize_terminal_control(context):
            raise PermissionError("Caller lacks permission for terminal control")

        # ---------------------------------------------------------------------
        # 2️⃣  Action validation – ensure we only accept the four supported verbs.
        # ---------------------------------------------------------------------
        if action not in TerminalAdapter.SUPPORTED_ACTIONS:
            raise ValueError(f"Unsupported terminal action: {action!r}")

        # ---------------------------------------------------------------------
        # 3️⃣  Target peer resolution – the context must contain the identifier of
        #     the peer that owns the terminal session.
        # ---------------------------------------------------------------------
        target_peer = context.get("peer_id")
        if not target_peer:
            raise ValueError("Missing target peer identifier in request context")

        # ---------------------------------------------------------------------
        # 4️⃣  Forward the request – we reuse the generic ``dispatch_action``
        #     helper which routes the payload through the normal Deep dispatch
        #     pipeline, preserving audit logging and replay safety.
        # ---------------------------------------------------------------------
        dispatch_action(
            target_peer,
            {
                "type": "terminal_control",
                "action": action,
                "payload": payload,
                "origin": context.get("caller_id"),
            },
        )

        # ---------------------------------------------------------------------
        # 5️⃣  Acknowledge receipt to the client.
        # ---------------------------------------------------------------------
        return {"status": "queued", "action": action}
