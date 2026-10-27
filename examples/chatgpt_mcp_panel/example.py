"""Executable installed-wheel example for ChatGPT MCP Extension hosts: a different
developer consumes the published astralprojection distribution (no sibling checkout) and
renders the bounded Astral Work status/artifact panel for every state, denial, recovery
and fallback path; examples/chatgpt_mcp_panel/README.md documents the pins and duties,
and tests/interop runs this file deterministically in a clean environment.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import astralprojection
from astralprims import Alert, Text
from astralprojection import CONTRACT_VERSION, UI_PROTOCOL_SHA256, UI_PROTOCOL_VERSION
from webrender.targets import chatgpt_panel

sys.path.insert(0, str(Path(__file__).resolve().parent))

from envelopes import (  # noqa: E402
    ASTRALPROJECTION_PIN,
    MCP_SDK_PIN,
    MCP_SCHEMA_REVISION,
    TOOL_NAME,
    denied_tool_result,
    document_sha256,
    resources_read_result,
    summarize_envelope,
    tool_descriptor,
    tool_result,
)

_AUDITOR_ALERT = Alert(
    title="Auditor access",
    message="Approve the external auditor access request",
    variant="warning",
).to_dict()
_FAILURE_NOTE = Text(
    content="The storage backend rejected the pack; retry is available.",
    variant="caption",
).to_dict()


def _authorized_works() -> dict[str, dict[str, Any]]:
    return {
        "work-waiting": {
            "kind": chatgpt_panel.PANEL_KIND,
            "state": "waiting",
            "title": "Quarterly compliance review",
            "detail": "Queued behind the evidence upload.",
        },
        "work-running": {
            "kind": chatgpt_panel.PANEL_KIND,
            "state": "running",
            "title": "Quarterly compliance review",
            "status_message": "Collecting control evidence",
            "progress": {"completed": 3, "total": 5},
            "detail": "Two controls remain open.",
        },
        "work-input-required": {
            "kind": chatgpt_panel.PANEL_KIND,
            "state": "input_required",
            "title": "Quarterly compliance review",
            "status_message": _AUDITOR_ALERT["message"],
            "detail": "The review pauses until the owner decides.",
        },
        "work-failed": {
            "kind": chatgpt_panel.PANEL_KIND,
            "state": "failed",
            "title": "Quarterly compliance review",
            "status_message": "Evidence upload failed",
            "detail": _FAILURE_NOTE["content"],
        },
        "work-cancelled": {
            "kind": chatgpt_panel.PANEL_KIND,
            "state": "cancelled",
            "title": "Quarterly compliance review",
            "status_message": "Cancelled by the owner",
        },
        "work-succeeded": {
            "kind": chatgpt_panel.PANEL_KIND,
            "state": "succeeded",
            "title": "Quarterly compliance review",
            "detail": "All controls closed.",
            "artifacts": [
                {
                    "id": "ev-pack",
                    "title": "Evidence pack",
                    "media_type": "application/pdf",
                    "url": "https://files.astral.test/w/quarterly/evidence-pack.pdf",
                    "size_bytes": 48213,
                    "note": "Receipt recorded in the audit log",
                },
                {
                    "id": "hours",
                    "title": "Focus hours export",
                    "media_type": "text/csv",
                    "url": "https://files.astral.test/w/quarterly/hours.csv",
                    "size_bytes": 942,
                },
            ],
        },
    }


AUTHORIZED_WORKS = _authorized_works()

UNAUTHORIZED_HOST_STATE = {
    "kind": chatgpt_panel.PANEL_KIND,
    "state": "succeeded",
    "title": "Injected work",
    "html": "<script>alert(1)</script>",
}

TRANSPORT_RESULT_STATE = {
    "content": [{"type": "text", "text": "the transport says done"}],
    "isError": False,
}

RECOVERY_SEQUENCE = ("work-failed", "work-running", "work-succeeded")


def _state_scenarios() -> list[dict[str, Any]]:
    scenarios = []
    for work_id in sorted(AUTHORIZED_WORKS):
        view = AUTHORIZED_WORKS[work_id]
        panel = chatgpt_panel.render_chatgpt_panel(view)
        scenarios.append(
            {
                "workId": work_id,
                "structuredState": panel["structuredContent"]["state"],
                "title": panel["structuredContent"]["title"],
                "artifactCount": len(panel["structuredContent"].get("artifacts", [])),
                "contentText": panel["content"][0]["text"],
                "contentBytes": len(panel["content"][0]["text"].encode("utf-8")),
                "envelope": summarize_envelope(tool_result(panel)),
            }
        )
    return scenarios


def _denial_scenarios() -> list[dict[str, Any]]:
    scenarios = []
    denied = summarize_envelope(
        denied_tool_result("host policy denied artifact sharing for this work item")
    )
    scenarios.append({"case": "host_policy_denial", **denied, "panelEmitted": False})
    try:
        chatgpt_panel.render_chatgpt_panel(UNAUTHORIZED_HOST_STATE)
        raise AssertionError("unauthorized state must be rejected")
    except chatgpt_panel.InvalidPanelView as error:
        rejected = summarize_envelope(denied_tool_result(str(error)))
        scenarios.append(
            {"case": "unauthorized_view_model_rejected", **rejected, "panelEmitted": False}
        )
    return scenarios


def _recovery_scenarios() -> list[dict[str, Any]]:
    steps = []
    for work_id in RECOVERY_SEQUENCE:
        panel = chatgpt_panel.render_chatgpt_panel(AUTHORIZED_WORKS[work_id])
        steps.append(
            {
                "workId": work_id,
                "structuredState": panel["structuredContent"]["state"],
                "resourceUri": panel["resource"]["uri"],
            }
        )
    return steps


def _fallback_scenario() -> dict[str, Any]:
    panel = chatgpt_panel.render_chatgpt_panel(AUTHORIZED_WORKS["work-succeeded"])
    result = tool_result(panel)
    return {
        "hostHasPanelSupport": False,
        "usableText": "\n".join(block["text"] for block in result["content"]),
        "contentBlocks": len(result["content"]),
    }


def _transport_state_rejection() -> dict[str, Any]:
    try:
        chatgpt_panel.render_chatgpt_panel(TRANSPORT_RESULT_STATE)
        raise AssertionError("transport state must be rejected")
    except chatgpt_panel.InvalidPanelView as error:
        return {"attempted": "mcp CallToolResult-shaped payload", "error": str(error)}


def build_report() -> dict[str, Any]:
    resource = chatgpt_panel.panel_resource()
    contents = resources_read_result()["contents"][0]
    return {
        "pins": {
            "astralprojection": ASTRALPROJECTION_PIN,
            "astralprojectionVersion": astralprojection.__version__,
            "contractVersion": CONTRACT_VERSION,
            "uiProtocolVersion": UI_PROTOCOL_VERSION,
            "uiProtocolSha256": UI_PROTOCOL_SHA256,
            "mcpSdk": MCP_SDK_PIN,
            "mcpSchemaRevision": MCP_SCHEMA_REVISION,
        },
        "authorizedInputs": {
            "inputRequiredMessageSource": _AUDITOR_ALERT["type"],
            "failedDetailSource": _FAILURE_NOTE["type"],
        },
        "toolName": TOOL_NAME,
        "panelResource": {
            "uri": resource["uri"],
            "mimeType": resource["mimeType"],
            "title": resource["title"],
            "bytes": len(resource["text"].encode("utf-8")),
            "sha256": document_sha256(),
        },
        "toolDescriptor": tool_descriptor(),
        "resourcesReadResult": {
            "uri": contents["uri"],
            "mimeType": contents["mimeType"],
            "textSha256": document_sha256(),
        },
        "stateScenarios": _state_scenarios(),
        "denialScenarios": _denial_scenarios(),
        "recoverySequence": _recovery_scenarios(),
        "fallbackScenario": _fallback_scenario(),
        "transportStateRejection": _transport_state_rejection(),
    }


def main() -> None:
    print(json.dumps(build_report(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
