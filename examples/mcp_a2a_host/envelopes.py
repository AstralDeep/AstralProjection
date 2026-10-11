"""Dependency-free host-side mapping from AstralProjection output into pinned MCP
CallToolResult and A2A Artifact JSON envelopes; example.py and the repo interop tests
share this module so the protocol mapping and its schema checks cannot drift apart.
"""

from __future__ import annotations

import hashlib
import json
import re
from typing import Any, Dict, List, Optional, Tuple

MCP_SDK_PIN = "mcp==2.3.0"
MCP_SCHEMA_REVISION = "2026-07-28"
A2A_SDK_PIN = "a2a-sdk==1.2.2"
A2A_PROTOCOL_REVISION = "1.0"
ASTRALPROJECTION_PIN = "astralprojection==0.1.0"
CONTRACT_VERSION = "astralprojection.contract/v1"

MCP_RESULT_TYPE_COMPLETE = "complete"

A2A_TASK_STATES = frozenset(
    {
        "TASK_STATE_UNSPECIFIED",
        "TASK_STATE_SUBMITTED",
        "TASK_STATE_WORKING",
        "TASK_STATE_COMPLETED",
        "TASK_STATE_FAILED",
        "TASK_STATE_CANCELED",
        "TASK_STATE_INPUT_REQUIRED",
        "TASK_STATE_REJECTED",
        "TASK_STATE_AUTH_REQUIRED",
    }
)

_SECRET_KEY_RE = re.compile(
    r"(token|secret|password|passwd|api[_-]?key|authorization|cookie|session|credential)",
    re.IGNORECASE,
)
_SECRET_VALUE_RE = re.compile(
    r"(?i)\b(eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}|"
    r"sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|Bearer\s+[A-Za-z0-9._-]{16,})"
)
REDACTED = "[REDACTED]"
DEFAULT_MAX_CHARS = 20000
ERROR_MAX_CHARS = 2000
MAX_STRUCTURE_DEPTH = 12
MAX_LIST_ITEMS = 200


def redact(value: Any, _depth: int = 0) -> Any:
    if _depth > MAX_STRUCTURE_DEPTH:
        return "[TRUNCATED_DEPTH]"
    if isinstance(value, str):
        if _SECRET_VALUE_RE.search(value):
            return _SECRET_VALUE_RE.sub(REDACTED, value)
        return value
    if isinstance(value, dict):
        out: Dict[str, Any] = {}
        for key, item in value.items():
            if isinstance(key, str) and _SECRET_KEY_RE.search(key):
                if isinstance(item, str):
                    out[key] = REDACTED
                elif isinstance(item, (list, tuple)):
                    out[key] = [REDACTED for _ in item[:MAX_LIST_ITEMS]]
                elif isinstance(item, dict):
                    out[key] = {str(k): REDACTED for k in list(item)[:MAX_LIST_ITEMS]}
                else:
                    out[key] = REDACTED
            else:
                out[key] = redact(item, _depth + 1)
        return out
    if isinstance(value, (list, tuple)):
        trimmed = list(value)[:MAX_LIST_ITEMS]
        return [redact(item, _depth + 1) for item in trimmed]
    return value


def bound_text(text: str, max_chars: int = DEFAULT_MAX_CHARS) -> Tuple[str, bool]:
    if len(text) <= max_chars:
        return text, False
    head = text[:max_chars]
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]
    return f"{head}\n[BOUNDED: full output sha256:{digest}, {len(text)} chars]", True


def stable_json(payload: Any) -> str:
    return json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _bounded_text_block(text: str, max_chars: int) -> Dict[str, Any]:
    bounded, _ = bound_text(redact(str(text)), max_chars)
    return {"type": "text", "text": bounded}


def build_mcp_call_tool_result(
    *,
    content_blocks: Optional[List[Dict[str, Any]]] = None,
    html_text: Optional[str] = None,
    error: Optional[BaseException] = None,
    max_chars: int = DEFAULT_MAX_CHARS,
) -> Dict[str, Any]:
    content: List[Dict[str, Any]] = []
    if error is not None:
        content.append(_bounded_text_block(f"render error: {error}", ERROR_MAX_CHARS))
        return {"content": content, "isError": True, "resultType": MCP_RESULT_TYPE_COMPLETE}
    for block in content_blocks or []:
        content.append(_bounded_text_block(block.get("text", ""), max_chars))
    if html_text is not None:
        content.append(_bounded_text_block(html_text, max_chars))
    if not content:
        content.append({"type": "text", "text": "(no renderable content)"})
    return {"content": content, "isError": False, "resultType": MCP_RESULT_TYPE_COMPLETE}


def _bounded_data_part(data: Any, max_chars: int) -> Dict[str, Any]:
    safe = redact(data)
    if isinstance(safe, (str, int, float, bool)) or safe is None:
        return {"data": safe}
    encoded = stable_json(safe)
    if len(encoded) > max_chars:
        digest = hashlib.sha256(encoded.encode("utf-8")).hexdigest()[:16]
        return {"data": {"truncated": True, "sha256Prefix": digest, "chars": len(encoded)}}
    return {"data": safe}


def build_a2a_artifact(
    *,
    artifact_id: str,
    name: str,
    data: Any = None,
    html_text: Optional[str] = None,
    error: Optional[BaseException] = None,
    max_chars: int = DEFAULT_MAX_CHARS,
) -> Dict[str, Any]:
    parts: List[Dict[str, Any]] = []
    if error is not None:
        bounded, _ = bound_text(redact(f"render error: {error}"), ERROR_MAX_CHARS)
        parts.append({"text": bounded})
        return {"artifactId": artifact_id, "name": name, "parts": parts}
    if data is not None:
        parts.append(_bounded_data_part(data, max_chars))
    if html_text is not None:
        bounded, _ = bound_text(redact(html_text), max_chars)
        parts.append({"text": bounded, "mediaType": "text/html"})
    return {"artifactId": artifact_id, "name": name, "parts": parts}


def a2a_task_envelope(*, task_id: str, context_id: str, state: str) -> Dict[str, Any]:
    if state not in A2A_TASK_STATES:
        raise ValueError(f"unknown A2A task state {state!r}")
    return {"id": task_id, "contextId": context_id, "status": {"state": state}}


def map_exception_to_state(exc: BaseException) -> str:
    if isinstance(exc, PermissionError):
        return "TASK_STATE_REJECTED"
    if isinstance(exc, LookupError):
        return "TASK_STATE_INPUT_REQUIRED"
    return "TASK_STATE_FAILED"
