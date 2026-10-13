"""Desktop Keycloak PKCE login through an exact loopback callback, used by app.py.
Configured HTTPS servers retain refresh grants and issue a separate, account-bound
session cookie; direct and legacy modes retain their explicit existing contracts.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import math
import re
import secrets
import threading
import time
import webbrowser
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Optional
from urllib.parse import parse_qs, urlencode, urlparse
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener, urlopen

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


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Invalid session response.")
        result[key] = value
    return result


def _https_base(value):
    if type(value) is not str or value != value.strip() or len(value) > 2048:
        raise ValueError("Invalid session destination.")
    parsed = urlparse(value)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
            or parsed.query or parsed.fragment or parsed.params
            or any(ord(c) <= 32 or ord(c) >= 127 for c in value)):
        raise ValueError("Invalid session destination.")
    parsed.port
    return value.rstrip("/")


def _identity(token, *, allow_expired=False):
    if type(token) is not str or len(token) > 16384 or len(token.split(".")) != 3:
        raise ValueError("Invalid session identity.")
    try:
        encoded = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)),
                            object_pairs_hook=_object)
        identity = tuple(claims[k] for k in ("iss", "sub", "azp"))
        if any(type(v) is not str or not v or len(v) > 2048 for v in identity) or "act" in claims:
            raise ValueError
        exp = claims["exp"]
        if (type(exp) not in (int, float) or not math.isfinite(exp)
                or (not allow_expired and exp <= time.time())):
            raise ValueError
        return identity, exp
    except (KeyError, TypeError, ValueError, UnicodeError):
        raise ValueError("Invalid session identity.") from None


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("Session redirects are refused.")


def _custody_request(url, *, headers=None, fields=None, json_body=None):
    data = None
    selected = dict(headers or {})
    if fields is not None:
        data = urlencode(fields).encode()
        selected["Content-Type"] = "application/x-www-form-urlencoded"
    elif json_body is not None:
        data = json.dumps(json_body).encode()
        selected["Content-Type"] = "application/json"
    request = Request(url, data=data, headers=selected)
    with build_opener(ProxyHandler({}), _NoRedirect()).open(request, timeout=20) as response:
        if (response.status != 200 or response.geturl() != url
                or response.headers.get_content_type() != "application/json"):
            raise ValueError("Invalid session response.")
        raw = response.read(32769)
        if len(raw) > 32768:
            raise ValueError("Invalid session response.")
        body = json.loads(raw.decode("utf-8"), object_pairs_hook=_object)
        if type(body) is not dict:
            raise ValueError("Invalid session response.")
        return body, response.headers.get_all("Set-Cookie", []), response.headers.get_all("X-Astral-Session-Custody", [])


def _issued_cookie(headers):
    if len(headers) != 1 or type(headers[0]) is not str or len(headers[0]) > 4608:
        raise ValueError("Invalid session cookie.")
    parts = [part.strip() for part in headers[0].split(";")]
    cookie = parts[0]
    if re.fullmatch(r"astral_session=[A-Za-z0-9._~=-]{1,4096}", cookie) is None:
        raise ValueError("Invalid session cookie.")
    attrs = {}
    for part in parts[1:]:
        key, _, value = part.partition("=")
        key = key.lower()
        if key in attrs:
            raise ValueError("Invalid session cookie.")
        attrs[key] = value
    if (set(attrs) != {"path", "httponly", "secure", "samesite", "max-age"}
            or attrs["path"] != "/" or attrs["httponly"] or attrs["secure"]
            or attrs["samesite"].lower() != "lax"
            or re.fullmatch(r"[1-9][0-9]{0,7}", attrs["max-age"]) is None
            or int(attrs["max-age"]) > 31_536_000):
        raise ValueError("Invalid session cookie.")
    return cookie, int(attrs["max-age"])


@dataclass(repr=False)
class Session:
    access_token: str
    refresh_token: Optional[str]
    token_url: str
    client_id: str
    expires_at: Optional[float] = None
    monotonic_expires_at: Optional[float] = None
    refresh_margin: float = 60.0
    server_base: Optional[str] = None
    authority: Optional[str] = None
    user_id: Optional[str] = None
    cookie: Optional[str] = None
    cookie_expires_at: Optional[float] = None
    cookie_monotonic_expires_at: Optional[float] = None

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

    @classmethod
    def from_custody(cls, response, cookies, *, server_base, authority, client_id):
        server_base, authority = _https_base(server_base), _https_base(authority)
        if urlparse(server_base).path or client_id != "astral-desktop":
            raise ValueError("Invalid session destination.")
        if (type(response) is not dict
                or set(response) != {"authenticated", "access_token", "token_type", "expires_in", "user_id", "resumed"}
                or response["authenticated"] is not True or response["resumed"] is not False
                or response["token_type"] != "Bearer"):
            raise ValueError("Invalid session response.")
        identity, _ = _identity(response["access_token"])
        if identity != (authority, response["user_id"], client_id):
            raise ValueError("Invalid session identity.")
        cookie, seconds = _issued_cookie(cookies)
        result = cls.from_response(response, token_url=server_base + "/auth/token", client_id=client_id)
        result.server_base, result.authority, result.user_id, result.cookie = server_base, authority, identity[1], cookie
        result.cookie_expires_at = time.time() + seconds
        result.cookie_monotonic_expires_at = time.monotonic() + seconds
        result._eligible()
        return result

    def _eligible(self):
        if (not self.cookie or self.cookie_expires_at is None or self.cookie_monotonic_expires_at is None
                or time.time() >= self.cookie_expires_at or time.monotonic() >= self.cookie_monotonic_expires_at
                or _https_base(self.server_base) != self.server_base
                or _https_base(self.authority) != self.authority
                or re.fullmatch(r"astral_session=[A-Za-z0-9._~=-]{1,4096}", self.cookie) is None
                or _identity(self.access_token, allow_expired=True)[0] != (self.authority, self.user_id, self.client_id)):
            raise ValueError("Session is unavailable.")

    def websocket_headers(self, url):
        self._eligible()
        _identity(self.access_token)
        target = urlparse(url)
        if (target.scheme != "wss" or target.username or target.password or target.query or target.fragment
                or "https://" + target.netloc != self.server_base):
            raise ValueError("Session transport changed.")
        return {"origin": self.server_base, "additional_headers": {"Cookie": self.cookie}}

    def logout(self):
        try:
            self._eligible()
            body, _, _ = _custody_request(self.server_base + "/api/auth/logout",
                headers={"Cookie": self.cookie, "Authorization": "Bearer " + self.access_token,
                         "X-Astral-Session-Custody": "server_v1"}, json_body={"session_custody": "server_v1"})
            return (set(body) == {"outcome", "revoked", "queued"}
                    and ((body["outcome"] == "revoked" and body["revoked"] is True and body["queued"] is False)
                         or (body["outcome"] == "queued" and body["revoked"] is False and body["queued"] is True)))
        except Exception:
            return False

    def remaining(self) -> Optional[float]:
        if self.expires_at is None or self.monotonic_expires_at is None:
            return None
        remaining = min(self.expires_at - time.time(), self.monotonic_expires_at - time.monotonic())
        if self.cookie_expires_at is not None and self.cookie_monotonic_expires_at is not None:
            remaining = min(remaining, self.cookie_expires_at - time.time(),
                            self.cookie_monotonic_expires_at - time.monotonic())
        return remaining

    def refresh_delay_ms(self) -> Optional[int]:
        remaining = self.remaining()
        if (not self.refresh_token and not self.cookie) or remaining is None:
            return None
        return int(min(60_000, max(0.0, (remaining - self.refresh_margin) * 1000)))

    def refresh(self) -> Optional[str]:
        if self.server_base is not None:
            try:
                self._eligible()
                body, cookies, _ = _custody_request(self.server_base + "/auth/session", headers={"Cookie": self.cookie})
                if (cookies or set(body) != {"authenticated", "access_token", "user_id", "resumed"}
                        or body["authenticated"] is not True or type(body["resumed"]) is not bool
                        or body["user_id"] != self.user_id):
                    raise ValueError("Session is unavailable.")
                identity, exp = _identity(body["access_token"])
                if identity != (self.authority, self.user_id, self.client_id):
                    raise ValueError("Session identity changed.")
                renewed = Session.from_response({"access_token": body["access_token"], "expires_in": exp - time.time()},
                    token_url=self.token_url, client_id=self.client_id)
                self._eligible()
                self.access_token, self.expires_at = renewed.access_token, renewed.expires_at
                self.monotonic_expires_at, self.refresh_margin = renewed.monotonic_expires_at, renewed.refresh_margin
                return self.access_token
            except Exception:
                logger.warning("session refresh failed")
                return None
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
               cancel_event: Optional[threading.Event] = None,
               server_base: Optional[str] = None) -> Session:
    if server_base is not None:
        server_base, authority = _https_base(server_base), _https_base(authority)
        if bff_base is not None or urlparse(server_base).path or client_id != "astral-desktop":
            raise ValueError("Invalid session destination.")
        probe, cookies, capability = _custody_request(server_base + "/auth/session")
        if (capability != ["server_v1"] or cookies
                or set(probe) != {"authenticated", "access_token", "resumed", "reason"}
                or probe["authenticated"] is not False or probe["access_token"] != ""
                or probe["resumed"] is not False or type(probe["reason"]) is not str
                or len(probe["reason"]) > 128):
            raise ValueError("Server session custody is unavailable.")
        conf, cookies, _ = _custody_request(authority + "/.well-known/openid-configuration")
        if (cookies or conf.get("authorization_endpoint") != authority + "/protocol/openid-connect/auth"
                or conf.get("token_endpoint") != authority + "/protocol/openid-connect/token"):
            raise ValueError("Identity provider destination changed.")
    else:
        conf = json.load(urlopen(f"{authority.rstrip('/')}/.well-known/openid-configuration", timeout=15))
    auth_ep = conf["authorization_endpoint"]
    token_url = (server_base + "/auth/token" if server_base else f"{bff_base.rstrip('/')}/auth/token" if bff_base
                 else conf["token_endpoint"])

    verifier = _b64u(secrets.token_bytes(32))
    challenge = _b64u(hashlib.sha256(verifier.encode("ascii")).digest())
    state = _b64u(secrets.token_bytes(16))
    captured: dict = {}

    class _Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            target = urlparse(self.path)
            q = parse_qs(target.query, keep_blank_values=True)
            if (target.path != "/callback" or target.fragment or target.scheme or target.netloc
                    or any(len(values) != 1 for values in q.values())
                    or set(q) - {"code", "state", "session_state", "iss"}
                    or q.get("state") != [state] or not q.get("code", [None])[0]
                    or ("iss" in q and q["iss"] != [authority.rstrip("/")])):
                self.send_error(400)
                return
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

    fields = {
        "grant_type": "authorization_code", "code": code, "redirect_uri": redirect_uri,
        "client_id": client_id, "code_verifier": verifier,
    }
    if server_base is not None:
        fields["session_custody"] = "server_v1"
        tok, cookies, _ = _custody_request(token_url, fields=fields,
            headers={"X-Astral-Session-Custody": "server_v1"})
        session = Session.from_custody(tok, cookies, server_base=server_base, authority=authority, client_id=client_id)
        if cancel_event is not None and cancel_event.is_set():
            session.logout()
            raise LoginCancelled("sign-in cancelled by the user")
        return session
    tok = _post_form(token_url, fields)
    return Session.from_response(tok, token_url=token_url, client_id=client_id)
