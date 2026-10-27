"""Synthetic ChatGPT-style MCP host for local panel qualification: serves the pinned
panel document and tool envelopes over loopback HTTP under the declared CSP and sandbox
posture, and exercises them like the external host would; deterministic and offline.
"""

from __future__ import annotations

import hashlib
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse
from urllib.request import urlopen

sys.path.insert(0, str(Path(__file__).resolve().parent))

import webrender.targets.chatgpt_panel as chatgpt_panel

from envelopes import (  # noqa: E402
    TOOL_NAME,
    denied_tool_result,
    document_sha256,
    resources_read_result,
    tool_descriptor,
    tool_result,
)

PANEL_CSP = (
    "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
    "img-src 'none'; font-src 'none'; media-src 'none'; connect-src 'none'; "
    "form-action 'none'; base-uri 'none'"
)
SANDBOX_ATTRIBUTE = 'sandbox="allow-scripts"'
_IFRAME_PAGE = (
    "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
    "<title>Astral Work panel host</title></head><body>"
    f"<iframe src=\"/panel\" title=\"Astral Work status\" width=\"600\" height=\"420\" "
    f"{SANDBOX_ATTRIBUTE}></iframe></body></html>"
)


def _json_bytes(payload: dict[str, Any]) -> bytes:
    return json.dumps(payload, sort_keys=True, ensure_ascii=False).encode("utf-8")


def _document_bytes() -> bytes:
    return chatgpt_panel.panel_document().encode("utf-8")


def build_handler(works: dict[str, dict[str, Any]]) -> type[BaseHTTPRequestHandler]:
    class HostHandler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            pass

        def _send(self, body: bytes, content_type: str, headers: dict[str, str]) -> None:
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            for name, value in headers.items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(body)

        def _send_json(self, payload: dict[str, Any]) -> None:
            self._send(_json_bytes(payload), "application/json; charset=utf-8", {})

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            query = parse_qs(parsed.query)
            if parsed.path == "/panel":
                self._send(
                    _document_bytes(),
                    "text/html; charset=utf-8",
                    {"Content-Security-Policy": PANEL_CSP},
                )
            elif parsed.path == "/embed":
                self._send(_IFRAME_PAGE.encode("utf-8"), "text/html; charset=utf-8", {})
            elif parsed.path == "/tools/list":
                self._send_json({"tools": [tool_descriptor()]})
            elif parsed.path == "/resources/read":
                uri = (query.get("uri") or [""])[0]
                if uri == chatgpt_panel.PANEL_RESOURCE_URI:
                    self._send_json(resources_read_result())
                else:
                    self._send_json(
                        {"error": {"code": -32002, "message": f"unknown resource {uri!r}"}}
                    )
            elif parsed.path in (f"/tool/{TOOL_NAME}", f"/fallback/{TOOL_NAME}"):
                work_id = (query.get("work_id") or [""])[0]
                view = works.get(work_id)
                if view is None:
                    self._send_json(
                        denied_tool_result(f"host policy denied work item {work_id!r}")
                    )
                    return
                panel = chatgpt_panel.render_chatgpt_panel(view)
                if parsed.path.startswith("/fallback/"):
                    self._send_json({"content": panel["content"]})
                else:
                    self._send_json(tool_result(panel))
            else:
                self._send_json({"error": {"code": -32601, "message": "not found"}})

    return HostHandler


def build_server(works: dict[str, dict[str, Any]]) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(("127.0.0.1", 0), build_handler(works))
    server.daemon_threads = True
    return server


def _fetch(base_url: str, path: str) -> tuple[bytes, dict[str, str]]:
    with urlopen(f"{base_url}{path}", timeout=10) as response:
        return response.read(), dict(response.headers)


def exercise(base_url: str, work_id: str) -> dict[str, Any]:
    descriptor_body, _ = _fetch(base_url, "/tools/list")
    descriptor = json.loads(descriptor_body)["tools"][0]
    template = descriptor["_meta"]["openai/outputTemplate"]

    resource_body, _ = _fetch(
        base_url, f"/resources/read?uri={chatgpt_panel.PANEL_RESOURCE_URI}"
    )
    resource = json.loads(resource_body)["contents"][0]
    missing_resource = json.loads(
        _fetch(base_url, "/resources/read?uri=ui://elsewhere/none")[0]
    )

    panel_body, panel_headers = _fetch(base_url, "/panel")
    embed_body, _ = _fetch(base_url, "/embed")

    result_body, _ = _fetch(base_url, f"/tool/{TOOL_NAME}?work_id={work_id}")
    result = json.loads(result_body)
    fallback_body, _ = _fetch(base_url, f"/fallback/{TOOL_NAME}?work_id={work_id}")
    fallback = json.loads(fallback_body)
    denial_body, _ = _fetch(base_url, f"/tool/{TOOL_NAME}?work_id=unauthorized-work")
    denial = json.loads(denial_body)
    unknown_body, _ = _fetch(base_url, "/unknown/path")
    unknown = json.loads(unknown_body)

    return {
        "toolName": descriptor["name"],
        "outputTemplateUri": template["uri"],
        "outputTemplateMime": template["mimeType"],
        "resourceUri": resource["uri"],
        "resourceMatchesPanelDocument": (
            hashlib.sha256(resource["text"].encode("utf-8")).hexdigest()
            == document_sha256()
            and hashlib.sha256(panel_body).hexdigest() == document_sha256()
        ),
        "panelCsp": panel_headers.get("Content-Security-Policy"),
        "embedSandboxed": SANDBOX_ATTRIBUTE in embed_body.decode("utf-8")
        and "allow-same-origin" not in embed_body.decode("utf-8"),
        "toolIsError": result["isError"],
        "toolStructuredState": result["structuredContent"]["state"],
        "toolContentBlocks": len(result["content"]),
        "fallbackHasNoStructuredContent": "structuredContent" not in fallback,
        "fallbackContentMatchesToolContent": fallback["content"] == result["content"],
        "fallbackTextStartsWith": fallback["content"][0]["text"].splitlines()[0],
        "denialIsError": denial["isError"],
        "denialHasNoPanel": "structuredContent" not in denial,
        "missingResourceErrorCode": missing_resource["error"]["code"],
        "unknownPathErrorCode": unknown["error"]["code"],
    }


__all__ = ["PANEL_CSP", "build_server", "exercise"]
