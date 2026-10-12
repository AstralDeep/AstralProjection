"""Exercises real desktop custody contracts with bounded synthetic HTTP replies.
Tests bind cookie, OAuth identity, expiry, refresh, logout and WebSocket transport.
"""

import base64
from copy import copy
import json
import time

import pytest

from astral_client import auth


SERVER = "https://app.invalid"
ISSUER = "https://iam.invalid/realms/fixture"
COOKIE = "astral_session=synthetic.custody"
SET_COOKIE = COOKIE + "; HttpOnly; Max-Age=3600; Path=/; SameSite=lax; Secure"


def token(**changes):
    claims = {"sub": "synthetic-owner", "iss": ISSUER, "azp": "astral-desktop", "exp": time.time() + 300}
    claims.update(changes)
    part = base64.urlsafe_b64encode(json.dumps(claims).encode()).rstrip(b"=").decode()
    return "header." + part + ".signature"


def body(**changes):
    result = {"authenticated": True, "access_token": token(), "token_type": "Bearer", "expires_in": 300,
              "user_id": "synthetic-owner", "resumed": False}
    result.update(changes)
    return result


def session(**changes):
    return auth.Session.from_custody(body(**changes), [SET_COOKIE], server_base=SERVER,
                                    authority=ISSUER, client_id="astral-desktop")


def test_custody_keeps_distinct_credentials_and_exact_transport_binding():
    value = session()
    assert value.refresh_token is None
    assert value.websocket_headers("wss://app.invalid/ws") == {
        "origin": SERVER, "additional_headers": {"Cookie": COOKIE}}
    assert value.refresh_delay_ms() is not None
    assert value.remaining() > 0
    assert "synthetic.custody" not in repr(value)


@pytest.mark.parametrize("url", ["ws://app.invalid/ws", "wss://foreign.invalid/ws", "wss://app.invalid:444/ws",
                                      "wss://user@app.invalid/ws", "wss://app.invalid/ws?token=secret"])
def test_custody_never_moves_to_another_transport(url):
    with pytest.raises(ValueError):
        session().websocket_headers(url)


@pytest.mark.parametrize("changes", [
    {"authenticated": False}, {"resumed": True}, {"refresh_token": "never-import"},
    {"user_id": "foreign"}, {"token_type": "cookie"}, {"expires_in": 0},
    {"access_token": token(sub="foreign")}, {"access_token": token(iss="https://foreign.invalid")},
    {"access_token": token(azp="astral-mobile")}, {"access_token": token(exp=0)},
    {"access_token": token(exp=True)}, {"access_token": token(act={"sub": "agent"})},
])
def test_invalid_custody_identity_is_not_a_session(changes):
    with pytest.raises(ValueError):
        session(**changes)


@pytest.mark.parametrize("cookies", [
    [], [SET_COOKIE, SET_COOKIE], [SET_COOKIE.replace("HttpOnly; ", "")],
    [SET_COOKIE.replace("; Secure", "")], [SET_COOKIE + "; Domain=foreign.invalid"],
    [SET_COOKIE.replace("Path=/", "Path=/other")], [SET_COOKIE.replace("SameSite=lax", "SameSite=none")],
    [SET_COOKIE.replace("Max-Age=3600", "Max-Age=0")], [SET_COOKIE + "; Secure"],
    [SET_COOKIE.replace("synthetic.custody", "line\nbreak")],
])
def test_cookie_issuance_is_closed(cookies):
    with pytest.raises(ValueError):
        auth.Session.from_custody(body(), cookies, server_base=SERVER, authority=ISSUER, client_id="astral-desktop")


def test_refresh_uses_only_bound_cookie_and_preserves_original_copy(monkeypatch):
    original = session()
    renewed = copy(original)
    requests = []
    fresh = token(exp=time.time() + 600)
    def exchange(url, **kwargs):
        requests.append((url, kwargs))
        return {"authenticated": True, "access_token": fresh, "user_id": "synthetic-owner", "resumed": True}, [], []
    monkeypatch.setattr(auth, "_custody_request", exchange)
    assert renewed.refresh() == fresh
    assert original.access_token != fresh and renewed.refresh_token is None
    assert requests == [(SERVER + "/auth/session", {"headers": {"Cookie": COOKIE}})]


@pytest.mark.parametrize("reply,cookies", [
    ({"authenticated": False, "access_token": "", "resumed": False, "reason": "no_session"}, []),
    ({"authenticated": True, "access_token": token(sub="foreign"), "user_id": "foreign", "resumed": True}, []),
    ({"authenticated": True, "access_token": token(), "user_id": "synthetic-owner", "resumed": True}, [SET_COOKIE]),
    ({"authenticated": True, "access_token": token(iss="https://foreign.invalid"), "user_id": "synthetic-owner", "resumed": True}, []),
])
def test_refresh_refuses_retirement_identity_switch_and_cookie_rotation(monkeypatch, reply, cookies):
    value = session()
    before = value.access_token
    monkeypatch.setattr(auth, "_custody_request", lambda *a, **kw: (reply, cookies, []))
    assert value.refresh() is None and value.access_token == before


def test_cookie_expiry_stops_refresh_and_transport_without_network(monkeypatch):
    value = session()
    value.cookie_monotonic_expires_at = time.monotonic() - 1
    monkeypatch.setattr(auth, "_custody_request", lambda *a, **kw: pytest.fail("network after expiry"))
    assert value.refresh() is None
    with pytest.raises(ValueError):
        value.websocket_headers("wss://app.invalid/ws")


def test_logout_uses_both_credentials_without_releasing_refresh_token(monkeypatch):
    value = session()
    seen = []
    def exchange(url, **kwargs):
        seen.append((url, kwargs))
        return {"outcome": "queued", "revoked": False, "queued": True}, [], []
    monkeypatch.setattr(auth, "_custody_request", exchange)
    assert value.logout()
    assert seen[0][0] == SERVER + "/api/auth/logout"
    assert seen[0][1]["headers"] == {"Cookie": COOKIE, "Authorization": "Bearer " + value.access_token,
                                      "X-Astral-Session-Custody": "server_v1"}
    assert seen[0][1]["json_body"] == {"session_custody": "server_v1"}


@pytest.mark.parametrize("reply", [
    {"outcome": "unconfirmed", "revoked": False, "queued": False},
    {"outcome": "queued", "revoked": True, "queued": True},
    {"outcome": "revoked", "revoked": False, "queued": False},
    {"outcome": "unknown", "revoked": False, "queued": False},
])
def test_unconfirmed_logout_does_not_claim_success(monkeypatch, reply):
    monkeypatch.setattr(auth, "_custody_request", lambda *a, **kw: (reply, [], []))
    assert not session().logout()


@pytest.mark.parametrize("value", [None, " https://app.invalid", "http://app.invalid", "https://u@app.invalid", "https://app.invalid?x=1", "https://app.invalid/#x", "https://app.invalid:bad", "https://app.invalid/\n"])
def test_invalid_https_session_destination_is_refused(value):
    with pytest.raises(ValueError):
        auth._https_base(value)


@pytest.mark.parametrize("value", [None, "malformed", "a.!.b", token(sub=""), token(exp=float("inf"))])
def test_malformed_token_identity_is_refused(value):
    with pytest.raises(ValueError):
        auth._identity(value)


def test_custody_logout_failure_is_unconfirmed(monkeypatch):
    def offline(*a, **kw):
        raise OSError("synthetic unavailable")
    monkeypatch.setattr(auth, "_custody_request", offline)
    assert session().logout() is False


@pytest.mark.parametrize("change", [{"server_base": SERVER + "/path"}, {"client_id": "astral-mobile"}])
def test_custody_session_issuance_rejects_unapproved_client_or_server_path(change):
    options = dict(server_base=SERVER, authority=ISSUER, client_id="astral-desktop")
    options.update(change)
    with pytest.raises(ValueError):
        auth.Session.from_custody(body(), [SET_COOKIE], **options)


def test_expired_access_token_refreshes_with_live_server_custody(monkeypatch):
    value = session()
    value.access_token = token(exp=time.time() - 10)
    monkeypatch.setattr(auth, "_custody_request", lambda *a, **kw: ({"authenticated": True, "access_token": token(), "user_id": value.user_id, "resumed": False}, [], []))
    assert value.refresh() is not None


@pytest.mark.parametrize("reply,status,destination,mime", [(b'{}', 200, SERVER, "application/json"), (b'{}', 201, SERVER, "application/json"), (b'{}', 200, SERVER + "/other", "application/json"), (b'{}', 200, SERVER, "text/html"), (b'x' * 32769, 200, SERVER, "application/json"), (b'[]', 200, SERVER, "application/json"), (b'{"authenticated":false,"authenticated":true}', 200, SERVER, "application/json")])
def test_session_http_transport_bounds_identity_and_never_redirects(monkeypatch, reply, status, destination, mime):
    from email.message import Message
    from types import SimpleNamespace
    headers = Message()
    headers["Content-Type"] = mime
    class Response:
        def __enter__(self):
            return self
        def __exit__(self, *a):
            return False
        def geturl(self):
            return destination
        def read(self, maximum):
            assert maximum == 32769
            return reply
    response = Response()
    response.headers, response.status = headers, status
    requests = []
    def opened(request, timeout):
        requests.append(request)
        assert timeout == 20
        return response
    monkeypatch.setattr(auth, "build_opener", lambda *a: SimpleNamespace(open=opened))
    if reply == b'{}' and status == 200 and destination == SERVER and mime == "application/json":
        assert auth._custody_request(SERVER, fields={"code": "synthetic"}) == ({}, [], [])
        assert requests[0].data == b"code=synthetic"
        auth._custody_request(SERVER, json_body={"session_custody": "server_v1"})
        assert json.loads(requests[1].data) == {"session_custody": "server_v1"}
    else:
        with pytest.raises(ValueError):
            auth._custody_request(SERVER)


def test_session_redirect_handler_never_forwards_credentials():
    with pytest.raises(ValueError):
        auth._NoRedirect().redirect_request(None, None, 302, None, None, "https://other.invalid")


def custody_login(monkeypatch, *, callback=None, cancel_after_exchange=False, probe_change=None, discovery_change=None, **options):
    import threading
    from urllib.parse import parse_qs, urlparse
    from urllib.request import urlopen
    from urllib.error import HTTPError
    captured = []
    cancel = threading.Event()
    def exchange(url, **kwargs):
        captured.append((url, kwargs))
        if url.endswith("/auth/session"):
            probe = {"authenticated": False, "access_token": "", "resumed": False, "reason": "no_session"}
            probe.update(probe_change or {})
            return probe, [], ["server_v1"]
        if url.endswith("/.well-known/openid-configuration"):
            discovery = {"authorization_endpoint": ISSUER + "/protocol/openid-connect/auth", "token_endpoint": ISSUER + "/protocol/openid-connect/token"}
            discovery.update(discovery_change or {})
            return discovery, [], []
        if url.endswith("/api/auth/logout"):
            return {"outcome": "revoked", "revoked": True, "queued": False}, [], []
        if cancel_after_exchange:
            cancel.set()
        return body(), [SET_COOKIE], ["server_v1"]
    def browser(url):
        q = parse_qs(urlparse(url).query)
        redirect, state = q["redirect_uri"][0], q["state"][0]
        assert q["code_challenge_method"] == ["S256"]
        assert q["client_id"] == ["astral-desktop"]
        def complete():
            target = callback(redirect, state) if callback else redirect + "?code=synthetic&state=" + state + "&iss=" + ISSUER
            try:
                with urlopen(target, timeout=5) as response:
                    response.read()
            except HTTPError as error:
                assert error.code == 400
        threading.Thread(target=complete, daemon=True).start()
    monkeypatch.setattr(auth, "_custody_request", exchange)
    monkeypatch.setattr(auth.webbrowser, "open", browser)
    result = auth.oidc_login(ISSUER, server_base=SERVER, cancel_event=cancel, **options)
    return result, captured


def test_server_login_keeps_normal_keycloak_pkce_and_fresh_cookie_exchange(monkeypatch):
    value, requests = custody_login(monkeypatch)
    assert value.cookie == COOKIE and value.refresh_token is None
    fields = requests[-1][1]["fields"]
    assert fields["redirect_uri"].startswith("http://127.0.0.1:") and fields["redirect_uri"].endswith("/callback")
    assert len(fields["code_verifier"]) >= 43 and fields["session_custody"] == "server_v1"
    assert requests[-1][0] == SERVER + "/auth/token"
    assert requests[-1][1]["headers"] == {"X-Astral-Session-Custody": "server_v1"}


@pytest.mark.parametrize("probe", [{"authenticated": True}, {"reason": 1}, {"reason": "x" * 129}])
def test_custody_login_has_no_fallback_for_unsupported_server(monkeypatch, probe):
    with pytest.raises(ValueError, match="custody is unavailable"):
        custody_login(monkeypatch, probe_change=probe)


@pytest.mark.parametrize("discovery", [{"authorization_endpoint": "https://foreign.invalid/auth"}, {"token_endpoint": "https://foreign.invalid/token"}])
def test_custody_login_binds_keycloak_discovery(monkeypatch, discovery):
    with pytest.raises(ValueError, match="destination changed"):
        custody_login(monkeypatch, discovery_change=discovery)


@pytest.mark.parametrize("callback", [lambda uri, state: uri + "?code=x&state=foreign", lambda uri, state: uri + "?code=x&state=" + state + "&state=" + state, lambda uri, state: uri.replace("/callback", "/other") + "?code=x&state=" + state, lambda uri, state: uri + "?code=x&state=" + state + "&iss=https://foreign.invalid", lambda uri, state: uri + "?code=x&state=" + state + "&unapproved=x"])
def test_loopback_callback_denials_do_not_exchange_a_code(monkeypatch, callback):
    with pytest.raises(RuntimeError, match="no authorization code"):
        custody_login(monkeypatch, callback=callback)


def test_cancel_after_server_issuance_retires_new_custody(monkeypatch):
    with pytest.raises(auth.LoginCancelled):
        custody_login(monkeypatch, cancel_after_exchange=True)


@pytest.mark.parametrize("options", [{"bff_base": SERVER}, {"client_id": "astral-frontend"}])
def test_server_custody_cannot_mix_legacy_bff_or_frontend_client(monkeypatch, options):
    with pytest.raises(ValueError):
        custody_login(monkeypatch, **options)


def test_transport_keeps_cookie_and_bearer_separate_and_refuses_mismatches(qapp):
    from astral_client.protocol import OrchestratorClient, WindowsProtocolError
    value = session()
    transport = OrchestratorClient("wss://app.invalid/ws", value.access_token, session=value)
    assert transport._auth_session is not value
    assert transport._register_frame()["token"] == value.access_token
    transport._worker_running = True
    transport._request_socket_close = lambda *args: None
    assert transport.renew_credentials(value.access_token, session=value)
    assert not transport.renew_credentials("foreign", session=value)
    foreign = copy(value)
    foreign.server_base = "https://foreign.invalid"
    assert not transport.renew_credentials(foreign.access_token, session=foreign)
    transport.stop()
    with pytest.raises(WindowsProtocolError):
        OrchestratorClient("wss://app.invalid/ws", "foreign", session=value)


@pytest.mark.parametrize("renew_before_admission", [False, True])
def test_socket_admission_is_bound_to_current_custody_revision(qapp, monkeypatch, renew_before_admission):
    import asyncio
    from astral_client import protocol
    value = session()
    transport = protocol.OrchestratorClient("wss://app.invalid/ws", value.access_token, session=value)
    transport._worker_running = True
    transport._request_socket_close = lambda *args: None
    sent = []
    class Socket:
        async def __aenter__(self):
            if renew_before_admission:
                replacement = session(access_token=token(exp=time.time() + 600))
                assert transport.renew_credentials(replacement.access_token, session=replacement)
            return self
        async def __aexit__(self, *a):
            return False
        async def send(self, message):
            sent.append(json.loads(message))
        def __aiter__(self):
            async def frames():
                if False:
                    yield None
            return frames()
    def opened(url, **kwargs):
        assert kwargs["origin"] == SERVER and kwargs["additional_headers"] == {"Cookie": COOKIE}
        return Socket()
    async def finish(ws):
        pass
    monkeypatch.setattr(protocol.websockets, "connect", opened)
    monkeypatch.setattr(transport, "_finish_open", finish)
    asyncio.run(transport._main())
    assert len(sent) == (0 if renew_before_admission else 1)
    transport.stop()


@pytest.fixture
def custody_window(request):
    return request.getfixturevalue("window_fixture")


from test_message_routing import win as window_fixture  # noqa: E402, F401


def test_normal_wss_startup_selects_server_custody(monkeypatch):
    from types import SimpleNamespace
    from astral_client.app import resolve_auth
    value = session()
    seen = []
    def login(*args, **kwargs):
        seen.append((args, kwargs))
        return value
    monkeypatch.setattr(auth, "oidc_login", login)
    args = SimpleNamespace(token="", authority=ISSUER, url="wss://app.invalid/ws", client_id="astral-desktop", bff=False)
    assert resolve_auth(args) == (value.access_token, value)
    assert seen[0][1]["server_base"] == SERVER


@pytest.mark.parametrize("revoked", [False, True])
def test_window_signout_retires_server_custody_and_local_mesh(custody_window, monkeypatch, revoked):
    from types import SimpleNamespace
    from astral_client import app as appmod
    window = custody_window
    value = session()
    window._auth_session = value
    calls, pending = [], []
    window._mesh_custody = SimpleNamespace(purge=lambda: calls.append("local-purge"))
    monkeypatch.setattr(auth.Session, "logout", lambda self: calls.append("server-logout") or revoked)
    monkeypatch.setattr(appmod.QMessageBox, "question", lambda *a: appmod.QMessageBox.StandardButton.Yes)
    monkeypatch.setattr(appmod.threading, "Thread", lambda *, target, **kw: SimpleNamespace(start=lambda: pending.append(target)))
    monkeypatch.setattr(appmod.QTimer, "singleShot", lambda *a: None)
    window._signed_out.disconnect()
    window._sign_out()
    pending.pop()()
    assert calls == ["local-purge", "server-logout"]
    assert window._mesh_custody is None and window._mesh_pending is None


def test_account_replacement_purges_prior_mesh_key(custody_window, monkeypatch):
    from types import SimpleNamespace
    window = custody_window
    window._token = token()
    calls = []
    window._mesh_custody = SimpleNamespace(purge=lambda: calls.append("purged"))
    monkeypatch.setattr(window, "_reconnect", lambda access: calls.append(access))
    replacement = token(sub="another-owner")
    window._apply_login(replacement)
    assert calls == ["purged", replacement] and window._mesh_custody is None


def test_interactive_reauth_keeps_server_custody(custody_window, monkeypatch):
    from types import SimpleNamespace
    from astral_client import app as appmod
    window = custody_window
    window._url = "wss://app.invalid/ws"
    window._login_params = {"authority": ISSUER, "client_id": "astral-desktop", "bff": False}
    pending, calls = [], []
    monkeypatch.setattr(appmod.QMessageBox, "question", lambda *a: appmod.QMessageBox.StandardButton.Yes)
    monkeypatch.setattr(appmod.threading, "Thread", lambda *, target, **kw: SimpleNamespace(start=lambda: pending.append(target)))
    monkeypatch.setattr(auth, "oidc_login", lambda *a, **kw: calls.append(kw) or session())
    window._reauth_done.disconnect()
    window._prompt_reauth()
    pending.pop()()
    assert calls[0]["server_base"] == SERVER
