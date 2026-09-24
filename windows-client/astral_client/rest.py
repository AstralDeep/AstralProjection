"""Dependency-free REST client for the Windows desktop's chrome surfaces that don't ride
the WebSocket (audit log, attachments, sign-out revocation); Bearer-authed against
the orchestrator, consumed by app.py's dialogs.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
import uuid
from typing import List, Optional, Tuple
from urllib.parse import quote, urlencode

OUTCOMES = ("in_progress", "success", "failure", "interrupted")

EVENT_CLASSES = (
    "auth", "conversation", "file", "settings", "agent_tool_call",
    "agent_ui_render", "agent_external_call", "audit_view",
    "component_feedback", "tool_quality", "proposal_review", "quarantine",
    "onboarding_started", "onboarding_completed", "onboarding_skipped",
    "onboarding_replayed", "tutorial_step_edited",
    "llm_config_change", "llm_unconfigured", "llm_call",
    "personalization", "memory", "skill", "schedule", "dreaming",
    "agent_lifecycle",
)


class RestError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(f"{status or 'network'}: {message}")
        self.status = status
        self.message = message


def audit_url(
    http_base: str,
    *,
    limit: int = 50,
    event_class: str = "",
    outcome: str = "",
    q: str = "",
    cursor: str = "",
) -> str:
    params: List[Tuple[str, str]] = [("limit", str(limit))]
    if event_class:
        params.append(("event_class", event_class))
    if outcome:
        params.append(("outcome", outcome))
    if q:
        params.append(("q", q))
    if cursor:
        params.append(("cursor", cursor))
    return f"{http_base.rstrip('/')}/api/audit?{urlencode(params)}"


def chrome_menu_url(http_base: str) -> str:
    return f"{http_base.rstrip('/')}/api/chrome/menu"


def parse_chrome_menu(model: dict) -> dict:
    model = model or {}
    sections: List[dict] = []
    for g in (model.get("menu") or []):
        items = [
            {"label": str(i.get("label") or ""), "surface": str(i.get("surface") or ""),
             "params": i.get("params") or {}}
            for i in (g.get("items") or [])
            if isinstance(i, dict) and i.get("surface")
        ]
        if items:
            sections.append({"label": str(g.get("label") or ""), "items": items})
    topbar_actions: List[dict] = []
    for c in (model.get("topbar") or []):
        if not isinstance(c, dict) or c.get("kind") != "action":
            continue
        surface = str((c.get("action") or {}).get("surface") or "")
        if surface:
            topbar_actions.append(
                {"label": str(c.get("label") or ""), "surface": surface, "icon": str(c.get("icon") or "")}
            )
    so = model.get("signout") or {}
    signout = {"label": str(so.get("label") or "Sign out"), "action": str(so.get("action") or "logout")}
    return {"sections": sections, "topbar_actions": topbar_actions, "signout": signout}


def export_component_csv_url(http_base: str, component_id: str, chat_id: str) -> str:
    return (f"{http_base.rstrip('/')}/api/export/component/"
            f"{quote(str(component_id), safe='')}.csv?"
            f"{urlencode({'chat_id': chat_id})}")


def export_canvas_html_url(http_base: str, chat_id: str) -> str:
    return (f"{http_base.rstrip('/')}/api/export/canvas/"
            f"{quote(str(chat_id), safe='')}.html")


def _fmt_ts(value) -> str:
    if not value:
        return "-"
    s = str(value).replace("T", " ")
    return s[:19] if len(s) >= 19 else s


def parse_audit_response(data: dict) -> Tuple[List[dict], Optional[str]]:
    rows: List[dict] = []
    for it in (data.get("items") or []):
        if not isinstance(it, dict):
            continue
        rows.append({
            "event_id": str(it.get("event_id") or ""),
            "recorded_at": _fmt_ts(it.get("recorded_at")),
            "event_class": str(it.get("event_class") or ""),
            "action_type": str(it.get("action_type") or ""),
            "outcome": str(it.get("outcome") or ""),
            "description": str(it.get("description") or ""),
        })
    return rows, (data.get("next_cursor") or None)


def fetch_json(url: str, token: str, *, timeout: int = 20, opener=urllib.request.urlopen) -> dict:
    req = urllib.request.Request(url, headers={
        "Accept": "application/json",
        "Authorization": f"Bearer {token}",
    })
    try:
        with opener(req, timeout=timeout) as r:
            raw = r.read(4 * 1024 * 1024)
    except urllib.error.HTTPError as exc:
        raise RestError(exc.code, exc.reason or "HTTP error")
    except Exception as exc:  # noqa: BLE001
        raise RestError(0, str(exc))
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except (ValueError, TypeError) as exc:
        raise RestError(0, f"bad JSON: {exc}")


def fetch_bytes(url: str, token: str, *, timeout: int = 60, opener=urllib.request.urlopen) -> bytes:
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with opener(req, timeout=timeout) as r:
            return r.read(64 * 1024 * 1024)
    except urllib.error.HTTPError as exc:
        raise RestError(exc.code, exc.reason or "HTTP error")
    except Exception as exc:  # noqa: BLE001
        raise RestError(0, str(exc))


def upload_attachment(http_base: str, token: str, filename: str, mime: str,
                      data: bytes, *, timeout: int = 60,
                      opener=urllib.request.urlopen) -> dict:
    boundary = "----AstralBoundary" + uuid.uuid4().hex
    crlf = b"\r\n"
    safe_name = (filename or "upload").replace("\r", "").replace("\n", "").replace('"', "")
    content_type = (mime or "application/octet-stream")
    body = b"".join([
        b"--", boundary.encode("ascii"), crlf,
        b'Content-Disposition: form-data; name="file"; filename="',
        safe_name.encode("utf-8"), b'"', crlf,
        b"Content-Type: ", content_type.encode("ascii", "replace"), crlf, crlf,
        data or b"", crlf,
        b"--", boundary.encode("ascii"), b"--", crlf,
    ])
    req = urllib.request.Request(
        http_base.rstrip("/") + "/api/upload",
        data=body,
        method="POST",
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "Content-Length": str(len(body)),
        },
    )
    try:
        with opener(req, timeout=timeout) as r:
            raw = r.read(4 * 1024 * 1024)
    except urllib.error.HTTPError as exc:
        raise RestError(exc.code, exc.reason or "HTTP error")
    except Exception as exc:  # noqa: BLE001
        raise RestError(0, str(exc))
    try:
        payload = json.loads(raw.decode("utf-8", "replace"))
    except (ValueError, TypeError) as exc:
        raise RestError(0, f"bad JSON: {exc}")
    if not isinstance(payload, dict) or not payload.get("attachment_id"):
        raise RestError(0, "upload response missing attachment_id")
    return {
        "attachment_id": payload.get("attachment_id"),
        "filename": payload.get("filename") or filename,
        "category": payload.get("category") or "file",
        "parser_status": payload.get("parser_status"),
    }


def native_logout(http_base: str, token: str, refresh_token: str, client_id: str,
                  *, timeout: int = 10, opener=urllib.request.urlopen) -> bool:
    body = json.dumps({"refresh_token": refresh_token, "client_id": client_id}).encode("utf-8")
    req = urllib.request.Request(
        http_base.rstrip("/") + "/api/auth/logout",
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
        },
    )
    try:
        with opener(req, timeout=timeout) as r:
            return 200 <= getattr(r, "status", getattr(r, "code", 0)) < 300
    except Exception:  # noqa: BLE001
        return False


def keycloak_logout(authority: str, client_id: str, refresh_token: str,
                    *, timeout: int = 10, opener=urllib.request.urlopen) -> bool:
    if not authority or not refresh_token:
        return False
    body = urlencode(
        {"client_id": client_id, "refresh_token": refresh_token}).encode("utf-8")
    req = urllib.request.Request(
        authority.rstrip("/") + "/protocol/openid-connect/logout",
        data=body,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with opener(req, timeout=timeout) as r:
            return 200 <= getattr(r, "status", getattr(r, "code", 0)) < 300
    except Exception:  # noqa: BLE001
        return False
