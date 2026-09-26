"""Native desktop OIDC login (Authorization-Code + PKCE via a loopback redirect), used
by app.py's resolve_auth(); the default dedicated public client talks to Keycloak
directly, or proxies through the orchestrator's BFF in legacy mode.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import math
import secrets
import threading
import time
import webbrowser
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Optional
from urllib.parse import parse_qs, urlencode, urlparse
from urllib.request import Request, urlopen

logger = logging.getLogger("astral.auth")


class LoginCancelled(RuntimeError):
    pass

_DEFAULT_SCOPES = "openid profile email offline_access"
_DONE_HTML = (b"<html><body style='font-family:sans-serif;background:#0F1221;color:#F3F4F6;"
              b"text-align:center;padding-top:80px'><h2>AstralDeep</h2>"
              b"<p>Login complete - you can close this window.</p></body></html>")


def _b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _post_form(url: str, fields: dict, timeout: int = 20) -> dict:
    data = urlencode(fields).encode()
    req = Request(url, data=data, headers={"Content-Type": "application/x-www-form-urlencoded"})
    return json.load(urlopen(req, timeout=timeout))


@dataclass
class Session:
    access_token: str
    refresh_token: Optional[str]
    token_url: str
    client_id: str
    expires_at: Optional[float] = None
    monotonic_expires_at: Optional[float] = None
    refresh_margin: float = 60.0

    @classmethod
    def from_response(cls, response: dict, *, token_url: str, client_id: str,
                      refresh_token: Optional[str] = None) -> "Session":
        token = response.get("access_token")
        rotated = response.get("refresh_token", refresh_token)
        if (not isinstance(token, str) or not token.strip()
                or (rotated is not None and (not isinstance(rotated, str) or not rotated.strip()))):
            raise ValueError("The identity provider returned invalid credentials.")
        result = cls(token, rotated, token_url, client_id)
        lifetime = response.get("expires_in")
        if "expires_in" in response:
            if (type(lifetime) not in (int, float) or not 0 < lifetime <= 31_536_000
                    or not math.isfinite(lifetime)):
                raise ValueError("The identity provider returned invalid token expiry.")
            result.expires_at = time.time() + lifetime
            result.monotonic_expires_at = time.monotonic() + lifetime
            if not math.isfinite(result.expires_at) or not math.isfinite(result.monotonic_expires_at):
                raise ValueError("The identity provider returned invalid token expiry.")
            result.refresh_margin = min(60.0, lifetime / 10)
        return result

    def remaining(self) -> Optional[float]:
        if self.expires_at is None or self.monotonic_expires_at is None:
            return None
        return min(self.expires_at - time.time(), self.monotonic_expires_at - time.monotonic())

    def refresh_delay_ms(self) -> Optional[int]:
        remaining = self.remaining()
        if not self.refresh_token or remaining is None:
            return None
        return int(min(60_000, max(0.0, (remaining - self.refresh_margin) * 1000)))

    def refresh(self) -> Optional[str]:
        if not self.refresh_token:
            return None
        try:
            r = _post_form(self.token_url, {"grant_type": "refresh_token",
                                            "refresh_token": self.refresh_token,
                                            "client_id": self.client_id}, timeout=15)
            renewed = Session.from_response(r, token_url=self.token_url,
                                            client_id=self.client_id, refresh_token=self.refresh_token)
            self.access_token = renewed.access_token
            self.refresh_token = renewed.refresh_token
            self.expires_at = renewed.expires_at
            self.monotonic_expires_at = renewed.monotonic_expires_at
            self.refresh_margin = renewed.refresh_margin
            return self.access_token
        except Exception:  # noqa: BLE001
            logger.warning("token refresh failed")
            return None


def oidc_login(authority: str, *, client_id: str = "astral-desktop",
               bff_base: Optional[str] = None, scopes: str = _DEFAULT_SCOPES,
               timeout: int = 300,
               cancel_event: Optional[threading.Event] = None) -> Session:
    conf = json.load(urlopen(f"{authority.rstrip('/')}/.well-known/openid-configuration", timeout=15))
    auth_ep = conf["authorization_endpoint"]
    token_url = (f"{bff_base.rstrip('/')}/auth/token" if bff_base
                 else conf["token_endpoint"])

    verifier = _b64u(secrets.token_bytes(32))
    challenge = _b64u(hashlib.sha256(verifier.encode("ascii")).digest())
    state = _b64u(secrets.token_bytes(16))
    captured: dict = {}

    class _Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            q = parse_qs(urlparse(self.path).query)
            captured["code"] = q.get("code", [None])[0]
            captured["state"] = q.get("state", [None])[0]
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(_DONE_HTML)

        def log_message(self, *a):
            pass

    server = HTTPServer(("127.0.0.1", 0), _Handler)
    port = server.server_address[1]
    redirect_uri = f"http://127.0.0.1:{port}/callback"

    params = urlencode({
        "response_type": "code", "client_id": client_id, "redirect_uri": redirect_uri,
        "scope": scopes, "code_challenge": challenge, "code_challenge_method": "S256",
        "state": state,
    })
    url = f"{auth_ep}?{params}"
    logger.info("opening browser for OIDC login (client=%s)", client_id)
    try:
        print("\n[AstralDeep] Opening your browser to sign in…\n"
              "If it doesn't open automatically, paste this URL into your browser:\n"
              f"  {url}\n", flush=True)
    except Exception:
        pass
    webbrowser.open(url)

    t = threading.Thread(target=server.handle_request, daemon=True)
    t.start()
    deadline = time.monotonic() + timeout
    while t.is_alive() and time.monotonic() < deadline:
        if cancel_event is not None and cancel_event.is_set():
            break
        t.join(0.2)
    server.server_close()

    if (not captured.get("code")
            and cancel_event is not None and cancel_event.is_set()):
        raise LoginCancelled("sign-in cancelled by the user")
    code = captured.get("code")
    if not code:
        raise RuntimeError("OIDC login did not complete (no authorization code).")
    if captured.get("state") != state:
        raise RuntimeError("OIDC state mismatch — aborting.")

    tok = _post_form(token_url, {
        "grant_type": "authorization_code", "code": code, "redirect_uri": redirect_uri,
        "client_id": client_id, "code_verifier": verifier,
    })
    return Session.from_response(tok, token_url=token_url, client_id=client_id)
