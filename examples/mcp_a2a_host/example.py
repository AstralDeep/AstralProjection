"""Executable installed-wheel example for MCP/A2A hosts: a different developer consumes
the published astralprojection distribution (no sibling checkout), adapts owner-authorized
astralprims primitives with ROTE, and maps the portable output into pinned MCP and A2A
envelopes; examples/mcp_a2a_host/README.md documents the pins and duties, and
tests/interop runs this file deterministically in a clean environment.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import astralprims
from astralprims import Alert, BarChart, MetricCard, Table, Text
from astralprojection import (
    CONTRACT_VERSION,
    UI_PROTOCOL_SHA256,
    UI_PROTOCOL_VERSION,
    __version__,
    notice_path,
    resource_sha256,
    static_path,
)
from rote.adapter import ComponentAdapter
from rote.capabilities import DeviceProfile
from webrender import render
from webrender.registry import render_for_target
from webrender.targets import mcp_renderer

sys.path.insert(0, str(Path(__file__).resolve().parent))

from envelopes import (  # noqa: E402
    A2A_PROTOCOL_REVISION,
    A2A_SDK_PIN,
    ASTRALPROJECTION_PIN,
    MCP_SCHEMA_REVISION,
    MCP_SDK_PIN,
    a2a_task_envelope,
    build_a2a_artifact,
    build_mcp_call_tool_result,
    map_exception_to_state,
)

AUTHORIZED_STATE = {
    "owner": "owner-114",
    "task_title": "Quarterly compliance review",
    "summary": "Three controls closed; one evidence request is open.",
    "metrics": {"closed": "12", "open": "1"},
    "weekly_hours": {"labels": ["Mon", "Tue", "Wed"], "values": [3.5, 2.0, 4.5]},
    "evidence": {
        "headers": ["Control", "Status"],
        "rows": [["CC6.1", "closed"], ["CC7.4", "open"]],
    },
    "reviewer_note": (
        "Evidence pack uploaded by reviewer session "
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMTQifQ.c2lnbmF0dXJlX3Rva2Vu"
    ),
    "audit_log": "event-0001 ok; " * 1400,
}

WATCH_DEVICE = {
    "device_type": "watch",
    "viewport_width": 198,
    "viewport_height": 242,
    "has_touch": True,
    "connection_type": "cellular",
}

FUTURE_WIDGET = {"type": "timeline_widget", "title": "Approved upstream", "items": ["a", "b"]}

BULK_TEXT = "audit event line; " * 1200


def _components(state: dict) -> list:
    return [
        Alert(title="Owner review", message=state["summary"], variant="info").to_dict(),
        MetricCard(title="Controls closed", value=state["metrics"]["closed"]).to_dict(),
        BarChart(
            title="Focus hours",
            labels=state["weekly_hours"]["labels"],
            datasets=[{"label": "hours", "data": state["weekly_hours"]["values"]}],
        ).to_dict(),
        Table(headers=state["evidence"]["headers"], rows=state["evidence"]["rows"]).to_dict(),
        Text(content=state["reviewer_note"], variant="caption").to_dict(),
        Text(content=state["audit_log"]).to_dict(),
        dict(FUTURE_WIDGET),
    ]


def _adapted_types(components: list, profile: DeviceProfile) -> list:
    return [str(component.get("type", "")) for component in ComponentAdapter.adapt(components, profile)]


def _bounding_scenario() -> dict:
    mcp = build_mcp_call_tool_result(content_blocks=[{"type": "text", "text": BULK_TEXT}])
    artifact = build_a2a_artifact(
        artifact_id="ap-08-artifact-2", name="projection-bulk", data=[{"type": "text", "content": BULK_TEXT}]
    )
    mcp_text = str(mcp["content"][0]["text"])
    return {
        "originalChars": len(BULK_TEXT),
        "mcpBounded": "[BOUNDED:" in mcp_text,
        "mcpTail": mcp_text[-72:],
        "a2aDataPartKeys": sorted(str(key) for key in artifact["parts"][0]),
        "a2aDataSummary": artifact["parts"][0]["data"],
    }


def _mapped_error(label: str, exc: BaseException) -> dict:
    return {
        "case": label,
        "projectionError": type(exc).__name__,
        "mcpCallToolResult": build_mcp_call_tool_result(error=exc),
        "a2aTaskState": map_exception_to_state(exc),
    }


def _error_mapping() -> list:
    cases = []
    try:
        static_path("../escape")
    except Exception as exc:
        cases.append(_mapped_error("invalid_resource_path", exc))
    try:
        raise KeyError("weekly_schedule")
    except KeyError as exc:
        cases.append(_mapped_error("missing_state_input", exc))
    cases.append(_mapped_error("host_denial", PermissionError("host policy denied this surface")))
    return cases


def build_report() -> dict:
    profile = DeviceProfile.from_dict(WATCH_DEVICE)
    components = _components(AUTHORIZED_STATE)
    adapted = ComponentAdapter.adapt(components, profile)
    mcp_renderer.install()
    blocks = render_for_target("mcp", adapted)
    html = render(adapted)
    return {
        "pins": {
            "astralprojection": ASTRALPROJECTION_PIN,
            "astralprojectionVersion": __version__,
            "astralprimsVersion": astralprims.__version__,
            "contractVersion": CONTRACT_VERSION,
            "uiProtocolVersion": UI_PROTOCOL_VERSION,
            "uiProtocolSha256": UI_PROTOCOL_SHA256,
            "mcpSdk": MCP_SDK_PIN,
            "mcpSchemaRevision": MCP_SCHEMA_REVISION,
            "a2aSdk": A2A_SDK_PIN,
            "a2aProtocolRevision": A2A_PROTOCOL_REVISION,
        },
        "notice": {"resource": "NOTICE", "sha256": resource_sha256(notice_path())},
        "adaptation": {
            "deviceType": profile.device_type.value,
            "inputTypes": [str(component["type"]) for component in components],
            "adaptedTypes": _adapted_types(components, profile),
        },
        "mcpCallToolResult": build_mcp_call_tool_result(content_blocks=blocks),
        "a2aArtifact": build_a2a_artifact(
            artifact_id="ap-08-artifact-1",
            name="projection-render",
            data=adapted,
            html_text=html,
        ),
        "a2aTask": a2a_task_envelope(
            task_id="ap-08-task-1",
            context_id="ap-08-context-1",
            state="TASK_STATE_COMPLETED",
        ),
        "hostBounding": _bounding_scenario(),
        "errorMapping": _error_mapping(),
    }


def main() -> None:
    print(json.dumps(build_report(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
