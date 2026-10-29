"""Host-side MCP envelope assembly for the ChatGPT panel example: pins the MCP revision,
builds the panel tool descriptor and resources/read result, and wraps panel output and
host denials into CallToolResult-shaped envelopes; the host owns transport and policy.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any

import webrender.targets.chatgpt_panel as chatgpt_panel

MCP_APPS_SDK_PIN = "@modelcontextprotocol/ext-apps==2.0.4"
MCP_APPS_SPEC_COMMIT = "7af9a75da720b8a81be0f9aff47b25f75e9530ad"
MCP_APPS_PROTOCOL_REVISION = "2026-01-26"
MCP_SCHEMA_REVISION = "2025-11-25"
ASTRALPROJECTION_PIN = "astralprojection==0.1.0"
TOOL_NAME = "astral_work_status"


def tool_descriptor() -> dict[str, Any]:
    return {
        "name": TOOL_NAME,
        "description": "Show the owner-authorized Astral Work status and artifact panel",
        "inputSchema": {
            "type": "object",
            "properties": {"work_id": {"type": "string"}},
            "required": ["work_id"],
        },
        "_meta": chatgpt_panel.panel_tool_metadata(),
    }


def resources_read_result() -> dict[str, Any]:
    resource = chatgpt_panel.panel_resource()
    contents = {key: resource[key] for key in ("uri", "mimeType", "title", "text", "_meta")}
    return {"contents": [contents]}


def tool_result(panel: dict[str, Any]) -> dict[str, Any]:
    return {
        "content": panel["content"],
        "structuredContent": panel["structuredContent"],
        "isError": False,
    }


def denied_tool_result(reason: str) -> dict[str, Any]:
    return {
        "content": [{"type": "text", "text": reason}],
        "isError": True,
    }


def document_sha256() -> str:
    return hashlib.sha256(chatgpt_panel.panel_document().encode("utf-8")).hexdigest()


def summarize_envelope(envelope: dict[str, Any]) -> dict[str, Any]:
    text = "\n".join(
        block.get("text", "") for block in envelope.get("content", [])
    )
    return {
        "isError": envelope["isError"],
        "contentText": text,
        "structuredState": (envelope.get("structuredContent") or {}).get("state"),
        "sha256": hashlib.sha256(
            json.dumps(envelope, sort_keys=True, ensure_ascii=False).encode("utf-8")
        ).hexdigest(),
    }


__all__ = [
    "ASTRALPROJECTION_PIN",
    "MCP_APPS_SDK_PIN",
    "MCP_APPS_SPEC_COMMIT",
    "MCP_APPS_PROTOCOL_REVISION",
    "MCP_SCHEMA_REVISION",
    "TOOL_NAME",
    "denied_tool_result",
    "document_sha256",
    "resources_read_result",
    "summarize_envelope",
    "tool_descriptor",
    "tool_result",
]
