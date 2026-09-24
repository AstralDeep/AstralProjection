"""Converts orchestrator ui_stream_data frames into Canvas ops, rendering only the
structured components (never the web html). Keys nodes by stream_id, or component_id
when bridged to a workspace identity; used by astral_client/app.py.
"""

from __future__ import annotations

from typing import Container, Dict, List, Optional, Tuple

STREAM_NODE_PREFIX = "stream-"


def stream_node_id(stream_id: str) -> str:
    return f"{STREAM_NODE_PREFIX}{stream_id}"


def _node_key(frame: dict) -> Tuple[Optional[str], Optional[str]]:
    sid = frame.get("stream_id")
    if sid:
        cid = frame.get("component_id")
        return (str(cid) if cid else stream_node_id(str(sid))), str(sid)
    tool = frame.get("tool_name")
    if tool:
        return f"{STREAM_NODE_PREFIX}tool-{tool}", f"tool:{tool}"
    return None, None


def _error_component(err: dict) -> dict:
    retryable = bool(err.get("retryable"))
    text = err.get("message") or err.get("code") or "stream error"
    return {
        "type": "alert",
        "variant": "warning" if retryable else "error",
        "title": "Live update interrupted" if retryable else "Live update failed",
        "message": str(text),
    }


def stream_frame_to_ops(
    frame: dict, *, active_chat: Optional[str], seq_state: Dict[str, int]
) -> List[dict]:
    node, key = _node_key(frame)
    if not node:
        return []

    session = frame.get("session_id")
    if session and active_chat and session != active_chat:
        return []

    seq = frame.get("seq")
    if isinstance(seq, int) and key is not None:
        last = seq_state.get(key)
        if last is not None and seq <= last:
            return []
        seq_state[key] = seq

    if frame.get("terminal") and key is not None:
        seq_state.pop(key, None)

    err = frame.get("error")
    if isinstance(err, dict) and err:
        return [{"op": "upsert", "component_id": node, "component": _error_component(err)}]

    comps = [c for c in (frame.get("components") or []) if isinstance(c, dict)]
    if not comps:
        return []
    body = comps[0] if len(comps) == 1 else {"type": "container", "content": comps}
    return [{"op": "upsert", "component_id": node, "component": body}]


def subscribe_ack_ops(frame: dict, *, existing_ids: Container[str] = ()) -> List[dict]:
    node, _ = _node_key(frame)
    if not node or node in existing_ids:
        return []
    tool = frame.get("tool_name") or "tool"
    return [{
        "op": "upsert",
        "component_id": node,
        "component": {"type": "text", "content": f"Streaming {tool}…"},
    }]


def stream_error_ops(frame: dict) -> List[dict]:
    payload = frame.get("payload") or {}
    node, _ = _node_key({
        "stream_id": payload.get("stream_id"),
        "tool_name": payload.get("tool_name") or frame.get("tool_name"),
    })
    if not node:
        return []
    text = payload.get("message") or payload.get("code") or frame.get("error") or "stream error"
    return [{
        "op": "upsert",
        "component_id": node,
        "component": {"type": "alert", "variant": "error", "title": "Stream error", "message": str(text)},
    }]
