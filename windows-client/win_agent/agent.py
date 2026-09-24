"""Self-contained A2A server for the Windows tools: serves the agent card and /agent
WebSocket the orchestrator's discover_agent expects, dispatching MCPRequest via
win_agent/tools.py behind a shared AGENT_API_KEY gate.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import inspect
import json
import logging
import os
import sys
import threading
import time
from collections import OrderedDict
from typing import TYPE_CHECKING, Any, Dict, Optional

from aiohttp import web

from astral_client import __version__
from astral_client.audit_log import AuditLogger
from .lets_executor import (
    ProtectedExecutorConfigurationError,
    ProtectedExecutorError,
    ProtectedExecutorRuntime,
    extract_permit,
    load_protected_executor,
)
from .tools import TOOL_REGISTRY, set_context

if TYPE_CHECKING:
    from astral_client.deployment import EffectiveDeploymentProfile

logger = logging.getLogger("win_agent")

AGENT_ID = "windows-tools-1"
AGENT_NAME = "Windows Tools (code & system)"
AGENT_DESC = ("Windows tools that run on the user's PC: read/write/edit files and "
              "run commands inside an approved workspace, plus system info, clipboard, "
              "notifications, and open. Every action is permission-gated, PHI-gated "
              "(fail-closed), and audited.")

_protected_executor: ProtectedExecutorRuntime | None = None
_protected_executor_lock = threading.Lock()


def _get_protected_executor() -> ProtectedExecutorRuntime:
    global _protected_executor
    with _protected_executor_lock:
        if _protected_executor is None:
            _protected_executor = load_protected_executor(agent_id=AGENT_ID)
        return _protected_executor


def _reset_protected_executor_for_tests() -> None:
    global _protected_executor
    with _protected_executor_lock:
        if _protected_executor is not None:
            _protected_executor.close()
        _protected_executor = None


def _bypass_enabled() -> bool:
    return os.getenv("ASTRAL_DANGEROUS_BYPASS", "0") in ("1", "true", "yes", "on")


def _advertised_tools() -> Dict[str, dict]:
    if _bypass_enabled():
        return TOOL_REGISTRY
    return {k: v for k, v in TOOL_REGISTRY.items() if k != "run_shell"}


def build_card(
    deployment_profile: Optional["EffectiveDeploymentProfile"] = None,
) -> Dict[str, Any]:
    metadata: Dict[str, Any] = {
        "host": "windows-client",
        "platform": "windows",
        "dangerous_bypass": _bypass_enabled(),
        "protected_executor": _get_protected_executor().card_metadata(),
    }
    if deployment_profile is not None:
        metadata.update(
            {
                "deployment_profile_sha256": deployment_profile.digest,
                "deployment_release_id": deployment_profile.profile.release_id,
                "deployment_endpoint_sha256": hashlib.sha256(
                    deployment_profile.profile.websocket_endpoint.encode("utf-8")
                ).hexdigest(),
            }
        )
    return {
        "name": AGENT_NAME,
        "description": AGENT_DESC,
        "agent_id": AGENT_ID,
        "version": __version__,
        "skills": [{
            "id": name, "name": name, "description": info["description"],
            "input_schema": info.get("input_schema", {"type": "object", "properties": {}}),
            "output_schema": None, "tags": ["windows", "desktop"],
            "scope": info.get("scope", "tools:system"), "metadata": {},
        } for name, info in _advertised_tools().items()],
        "metadata": metadata,
    }


AGENT_KEY_HEADER = "X-Astral-Agent-Key"

# Mirrors backend/orchestrator/session_store.py's key gate
MIN_KEY_LENGTH = 16

_PLACEHOLDER_KEYS = frozenset(
    {"change-me", "changeme", "dev-audit-hmac-secret-change-me-in-prod"}
)

_REFUSAL_LOG_INTERVAL_S = 10.0

_REFUSAL_LOG_MAX_PEERS = 512
_last_refusal_log: "OrderedDict[str, float]" = OrderedDict()

BIND_TIMEOUT_S = 5.0


def configured_key(
    deployment_profile: Optional["EffectiveDeploymentProfile"] = None,
) -> Optional[str]:
    key = (
        deployment_profile.managed_agent_api_key
        if deployment_profile is not None
        else (os.getenv("AGENT_API_KEY") or None)
    )
    if not isinstance(key, str):
        return None
    key = key.strip()
    return key or None


def key_rejection_reason(key: Optional[str]) -> Optional[str]:
    if not key:
        return "AGENT_API_KEY is not configured"
    if not key.isascii():
        return "AGENT_API_KEY must be ASCII"
    if key.lower() in _PLACEHOLDER_KEYS:
        return "AGENT_API_KEY is a shipped placeholder"
    if len(key) < MIN_KEY_LENGTH:
        return f"AGENT_API_KEY is shorter than {MIN_KEY_LENGTH} characters"
    return None


def _authorized(request) -> bool:
    expected = request.app.get("inbound_key")
    if not expected:
        return False
    values = request.headers.getall(AGENT_KEY_HEADER, [])
    if len(values) != 1:
        return False
    presented = values[0]
    if not presented or not presented.isascii():
        return False
    return hmac.compare_digest(presented.encode("ascii"), expected.encode("ascii"))


def _log_refusal(request, route: str) -> None:
    peer = str(getattr(request, "remote", "") or "unknown")
    now = time.monotonic()
    last = _last_refusal_log.get(peer)
    if last is not None and (now - last) < _REFUSAL_LOG_INTERVAL_S:
        return
    _last_refusal_log[peer] = now
    _last_refusal_log.move_to_end(peer)
    while len(_last_refusal_log) > _REFUSAL_LOG_MAX_PEERS:
        _last_refusal_log.popitem(last=False)
    logger.warning("refused unauthenticated %s request from %s", route, peer)


def _print_console(text: str) -> None:
    stream = getattr(sys, "stderr", None)
    if stream is None:
        return
    try:
        print(text, file=stream)
    except (AttributeError, ValueError, OSError):
        pass


def _log_bind(host: str, port: int) -> None:
    if host in ("127.0.0.1", "::1", "localhost"):
        logger.info("Windows tools agent listening on %s:%d", host, port)
        return
    logger.warning(
        "Windows tools agent listening on %s:%d — reachable from the local "
        "network; every request requires the %s header",
        host, port, AGENT_KEY_HEADER,
    )


def _unauthorized() -> web.HTTPUnauthorized:
    return web.HTTPUnauthorized(
        text=json.dumps({"error": "agent_auth_required"}),
        content_type="application/json",
        headers={"WWW-Authenticate": 'AstralAgentKey realm="win-agent"'},
    )


def _register_message(
    deployment_profile: Optional["EffectiveDeploymentProfile"] = None,
) -> str:
    return json.dumps({
        "type": "register_agent",
        "agent_card": build_card(deployment_profile),
        "api_key": configured_key(deployment_profile),
    })


def _actor_from_req(req: Dict[str, Any]) -> str:
    meta = req.get("meta") or {}
    return (meta.get("user_id") or meta.get("sub")
            or os.getenv("USERNAME") or "unknown")


_AUDIT = AuditLogger(actor=os.getenv("USERNAME") or "unknown")


def dispatch(req: Dict[str, Any]) -> Dict[str, Any]:
    rid = req.get("request_id", "")
    method = req.get("method", "")
    set_context(actor=_actor_from_req(req), correlation_id=str(rid), audit=_AUDIT)
    tools = _advertised_tools()

    if method == "tools/list":
        return {"type": "mcp_response", "request_id": rid,
                "result_type": "complete",
                "responder_info": {"name": AGENT_ID, "version": "1.0.0"},
                "result": {"tools": [
            {"name": n, "description": i["description"],
             "input_schema": i.get("input_schema", {"type": "object", "properties": {}})}
            for n, i in tools.items()]}}

    if method == "tools/call":
        params = req.get("params") or {}
        name = params.get("name", "")
        args = params.get("arguments", {}) or {}
        info = tools.get(name)
        if not info:
            if name == "run_shell":
                _AUDIT.record(tool="run_shell", args=args, outcome="refused",
                              correlation_id=str(rid), event_class="dangerous_bypass",
                              detail="bypass flag not set (call rejected)")
            return {"type": "mcp_response", "request_id": rid,
                    "result_type": "complete",
                    "responder_info": {"name": AGENT_ID, "version": "1.0.0"},
                    "error": {"code": -32601, "message": f"Unknown tool: {name}", "retryable": False}}
        try:
            fn = info["function"]
            sig = inspect.signature(fn)
            if not any(p.kind == p.VAR_KEYWORD for p in sig.parameters.values()):
                args = {k: v for k, v in args.items() if k in sig.parameters}
            executor = _get_protected_executor()
            permit = extract_permit(req.get("caller_capabilities"))
            if executor.requires_permit:
                if permit is None:
                    raise ProtectedExecutorError("missing_protected_permit")
                executor.verify_and_claim(
                    metadata=permit,
                    final_arguments=args,
                    tool_id=name,
                    tool_scope=info.get("scope", ""),
                )
            result = fn(**args)
            comps = result.get("_ui_components") if isinstance(result, dict) else None
            data = result.get("_data") if isinstance(result, dict) else result
            return {"type": "mcp_response", "request_id": rid,
                    "result_type": "complete",
                    "responder_info": {"name": AGENT_ID, "version": "1.0.0"},
                    "result": data, "ui_components": comps}
        except ProtectedExecutorError as exc:
            logger.warning("protected tool %s refused: %s", name, exc.code)
            return {"type": "mcp_response", "request_id": rid,
                    "result_type": "complete",
                    "responder_info": {"name": AGENT_ID, "version": "1.0.0"},
                    "error": {"code": -32073, "message": exc.code,
                              "retryable": exc.retryable}}
        except Exception as exc:  # noqa: BLE001
            logger.exception("tool %s failed", name)
            return {"type": "mcp_response", "request_id": rid,
                    "result_type": "complete",
                    "responder_info": {"name": AGENT_ID, "version": "1.0.0"},
                    "error": {"code": -32603, "message": str(exc), "retryable": True}}

    return {"type": "mcp_response", "request_id": rid,
            "result_type": "complete",
            "responder_info": {"name": AGENT_ID, "version": "1.0.0"},
            "error": {"code": -32601, "message": f"Unknown method: {method}", "retryable": False}}


async def _card(request):
    if not _authorized(request):
        _log_refusal(request, "card")
        raise _unauthorized()
    return web.json_response(build_card(request.app.get("deployment_profile")))


async def _health(request):
    return web.Response(text="ok")


async def _agent_ws(request):
    # Must precede ws.prepare(): the frame right after carries the key
    if not _authorized(request):
        _log_refusal(request, "agent")
        raise _unauthorized()
    ws = web.WebSocketResponse(max_msg_size=50 * 1024 * 1024)
    await ws.prepare(request)
    await ws.send_str(_register_message(request.app.get("deployment_profile")))
    logger.info("orchestrator connected; registered %d Windows tools", len(TOOL_REGISTRY))
    async for msg in ws:
        if msg.type == web.WSMsgType.TEXT:
            try:
                req = json.loads(msg.data)
            except (ValueError, TypeError):
                continue
            if isinstance(req, dict) and req.get("type") == "mcp_request":
                await ws.send_str(json.dumps(dispatch(req)))
    return ws


class AgentKeyUnavailable(RuntimeError):
    pass


def make_app(
    deployment_profile: Optional["EffectiveDeploymentProfile"] = None,
) -> web.Application:
    key = configured_key(deployment_profile)
    reason = key_rejection_reason(key)
    if reason:
        raise AgentKeyUnavailable(
            f"{reason} — refusing to serve the Windows tools agent"
        )
    try:
        _get_protected_executor()
    except ProtectedExecutorConfigurationError as exc:
        raise AgentKeyUnavailable(
            f"protected executor is not ready ({exc.code}) — refusing to serve"
        ) from None
    app = web.Application()
    app["deployment_profile"] = deployment_profile
    app["inbound_key"] = key
    app.add_routes([
        web.get("/.well-known/agent-card.json", _card),
        web.get("/health", _health),
        web.get("/agent", _agent_ws),
    ])
    return app


def start_agent_thread(
    host: str = "0.0.0.0",
    port: int = 8771,
    *,
    deployment_profile: Optional["EffectiveDeploymentProfile"] = None,
):
    import asyncio
    import threading

    try:
        app = make_app(deployment_profile)
    except AgentKeyUnavailable as exc:
        logger.error("Windows tools agent not started: %s", exc)
        return None

    bound = threading.Event()
    outcome = {}

    def _run():
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        outcome["loop"] = loop
        runner = web.AppRunner(app)
        try:
            loop.run_until_complete(runner.setup())
            loop.run_until_complete(web.TCPSite(runner, host, port).start())
        except Exception as exc:  # noqa: BLE001
            outcome["error"] = exc
            bound.set()
            return
        _log_bind(host, port)
        bound.set()
        try:
            loop.run_forever()
        finally:
            try:
                loop.run_until_complete(runner.cleanup())
            except Exception:  # noqa: BLE001
                pass
            loop.close()

    try:
        t = threading.Thread(target=_run, name="win-agent", daemon=True)
        t.start()
    except Exception:  # noqa: BLE001
        logger.exception("could not start the Windows tools agent")
        return None
    if not bound.wait(BIND_TIMEOUT_S):
        logger.error("Windows tools agent did not bind %s:%d within %.0fs",
                     host, port, BIND_TIMEOUT_S)
        return None
    if "error" in outcome:
        logger.error("Windows tools agent could not bind %s:%d: %s",
                     host, port, outcome["error"])
        return None
    t._astral_loop = outcome.get("loop")
    return t


def main() -> int:
    ap = argparse.ArgumentParser(description="AstralDeep Windows tools agent")
    ap.add_argument("--host", default=os.getenv("ASTRAL_AGENT_BIND", "0.0.0.0"))
    ap.add_argument("--port", type=int, default=int(os.getenv("WIN_AGENT_PORT", "8771")))
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    try:
        app = make_app()
    except AgentKeyUnavailable as exc:
        logger.error("%s", exc)
        _print_console(f"AstralDeep Windows tools agent: {exc}")
        return 78
    logger.info("Windows tools agent on %s:%d (tools: %s)",
                args.host, args.port, ", ".join(TOOL_REGISTRY))
    _log_bind(args.host, args.port)
    web.run_app(app, host=args.host, port=args.port, print=None)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
