"""Verify native workspace action authorization, bounded REST and stale delivery fences.
The controller uses synthetic account tokens and injected transports without a backend.
"""

import base64
import io
import json
import threading
import urllib.error
from email.message import Message

import pytest
from PySide6.QtTest import QTest

from astral_client.protocol import ConversationResumeStore
from astral_client.rest import parse_chrome_menu
from astral_client.workspace_actions import (
    AUTH_REQUIRED,
    EXPORT_FAILED,
    REVISION_CHANGED,
    SHARE_FAILED,
    WorkspaceActions,
    WorkspaceContext,
    WorkspaceFailure,
    WorkspaceRest,
    _NoRedirect,
)


def _token(subject="alice"):
    claims = base64.urlsafe_b64encode(json.dumps({"iss": "https://identity.test", "sub": subject}).encode()).decode().rstrip("=")
    return f"test.{claims}.signature"


def _context():
    return {"owner": ConversationResumeStore.account_key("https://identity.test", "alice"),
            "connection": "connection-one", "chat_id": "chat-one", "render_revision": 7,
            "operations": ["export_canvas", "share_canvas"]}


class Response(io.BytesIO):
    def __init__(self, data=b"<html>Canvas</html>", status=200, *, headers=None):
        super().__init__(data)
        self.status = status
        self.headers = Message()
        for name, value in (headers or {"Content-Type": "text/html", "X-Astral-Render-Revision": "7"}).items():
            self.headers[name] = value


def test_rest_export_revision_header_and_private_credentials():
    seen = []
    def open_request(request, timeout):
        seen.append(request)
        assert timeout == 30
        return Response()

    rest = WorkspaceRest("https://server.test/base", opener=open_request)
    assert rest.export_canvas("private-token", "chat-one", 7) == b"<html>Canvas</html>"
    request = seen[0]
    assert request.full_url == "https://server.test/api/export/canvas/chat-one.html?render_revision=7"
    assert request.headers["Authorization"] == "Bearer private-token"
    assert request.headers["Cache-control"] == "no-store"
    assert "private-token" not in request.full_url and request.data is None


@pytest.mark.parametrize("status,headers,expected", [
    (401, {}, AUTH_REQUIRED), (403, {}, AUTH_REQUIRED), (409, {}, REVISION_CHANGED),
    (200, {"Content-Type": "text/html"}, REVISION_CHANGED),
    (200, {"Content-Type": "text/html", "X-Astral-Render-Revision": "8"}, REVISION_CHANGED),
    (500, {}, EXPORT_FAILED),
    (200, {"Content-Type": "application/json", "X-Astral-Render-Revision": "7"}, EXPORT_FAILED),
])
def test_export_refusals(status, headers, expected):
    rest = WorkspaceRest("https://server.test", opener=lambda *a, **k: Response(status=status, headers=headers))
    with pytest.raises(WorkspaceFailure, match=expected):
        rest.export_canvas("token", "chat-one", 7)


def test_duplicate_revision_headers_are_refused():
    response = Response()
    response.headers["X-Astral-Render-Revision"] = "7"
    rest = WorkspaceRest("https://server.test", opener=lambda *a, **k: response)
    with pytest.raises(WorkspaceFailure, match=REVISION_CHANGED):
        rest.export_canvas("token", "chat-one", 7)


def test_empty_export_is_refused():
    rest = WorkspaceRest("https://server.test", opener=lambda *a, **k: Response(b""))
    with pytest.raises(WorkspaceFailure, match=EXPORT_FAILED):
        rest.export_canvas("token", "chat-one", 7)


@pytest.mark.parametrize("base", ["https://user:pass@server.test", "https://server.test?token=x", "https://server.test#x",
                                   "file:///tmp/x", " https://server.test", "https://server.test\\evil", "https://server.test:bad", None])
def test_invalid_origins_are_refused(base):
    with pytest.raises(WorkspaceFailure, match="address is invalid"):
        WorkspaceRest(base)


@pytest.mark.parametrize("token", [None, "", " ", "a\nb", "x" * 16385])
def test_invalid_credentials_never_send(token):
    def forbidden(*a, **k):
        pytest.fail("Invalid credentials sent")
    rest = WorkspaceRest("https://server.test", opener=forbidden)
    with pytest.raises(WorkspaceFailure, match=AUTH_REQUIRED):
        rest.export_canvas(token, "chat-one", 7)


@pytest.mark.parametrize("headers,data", [({"Content-Length": "9"}, b"x"), ({"Content-Length": "bad"}, b"x"), ({}, b"123456789")])
def test_bounded_read_fails_instead_of_truncating(headers, data):
    rest = WorkspaceRest("https://server.test", opener=lambda *a, **k: Response(data, headers=headers))
    with pytest.raises(WorkspaceFailure, match="too large"):
        rest._request("/bounded", "token", limit=8)


def test_network_and_body_failures_hide_exception_details():
    def failed_open(*a, **k):
        raise OSError("secret-token")
    rest = WorkspaceRest("https://server.test", opener=failed_open)
    with pytest.raises(WorkspaceFailure) as caught:
        rest.export_canvas("token", "chat-one", 7)
    assert "secret-token" not in str(caught.value)
    assert "connection" in str(caught.value)

    class Broken(Response):
        def read1(self, *args):
            raise OSError("secret-body")
    rest.opener = lambda *a, **k: Broken()
    with pytest.raises(WorkspaceFailure, match="interrupted"):
        rest.export_canvas("token", "chat-one", 7)


def test_http_error_is_handled_and_redirect_is_never_followed():
    def failed_open(*a, **k):
        raise urllib.error.HTTPError("https://server.test", 409, "Conflict", Message(), io.BytesIO(b"{}"))
    rest = WorkspaceRest("https://server.test", opener=failed_open)
    with pytest.raises(WorkspaceFailure, match=REVISION_CHANGED):
        rest.export_canvas("token", "chat-one", 7)
    def redirect(*a, **k):
        return _NoRedirect().redirect_request(None, None, 302, "", {}, "https://attacker.test")
    rest.opener = redirect
    with pytest.raises(WorkspaceFailure, match="redirected"):
        rest.export_canvas("token", "chat-one", 7)


def test_share_posts_only_authoritative_chat_scope_and_validates_url():
    seen = []
    def open_request(request, timeout):
        seen.append(request)
        return Response(json.dumps({"share_url": "/share/" + "a" * 32}).encode(), 201,
                        headers={"Content-Type": "application/json"})
    rest = WorkspaceRest("https://server.test", opener=open_request)
    assert rest.share_canvas("private", "chat-one") == "https://server.test/share/" + "a" * 32
    assert json.loads(seen[0].data) == {"chat_id": "chat-one", "scope": "canvas"}
    assert seen[0].method == "POST" and seen[0].headers["Authorization"] == "Bearer private"


@pytest.mark.parametrize("body,status,expected", [
    (b'{"error":"phi_blocked"}', 403, "PHI gate"), (b'{}', 403, AUTH_REQUIRED),
    (b'{}', 401, AUTH_REQUIRED), (b'{}', 404, SHARE_FAILED),
    (b'[]', 201, SHARE_FAILED), (b'bad', 201, SHARE_FAILED),
    (b'{"share_url":"a","share_url":"b"}', 201, SHARE_FAILED),
    (b'{"share_url":null}', 201, SHARE_FAILED),
])
def test_share_failures_are_actionable(body, status, expected):
    rest = WorkspaceRest("https://server.test", opener=lambda *a, **k: Response(body, status,
                         headers={"Content-Type": "application/json"}))
    with pytest.raises(WorkspaceFailure, match=expected):
        rest.share_canvas("token", "chat-one")


@pytest.mark.parametrize("reference", [
    "https://attacker.test/share/" + "a" * 32, "//attacker.test/share/" + "a" * 32,
    "/share/short", "/share/" + "a" * 32 + "?token=secret", "/share/" + "a" * 32 + "#fragment",
    " /share/" + "a" * 32, "/share/" + "a" * 32 + "\n", "/share/" + "a" * 32 + "\\", 3,
])
def test_share_never_exposes_external_or_credential_urls(reference):
    rest = WorkspaceRest("https://server.test", opener=lambda *a, **k: Response(json.dumps({"share_url": reference}).encode(),
                         201, headers={"Content-Type": "application/json"}))
    with pytest.raises(WorkspaceFailure):
        rest.share_canvas("token", "chat-one")


def test_context_binds_account_and_validates_revision():
    assert WorkspaceContext.from_provider(_context(), _token()).render_revision == 7
    for patch in ({"owner": "another"}, {"chat_id": "../escape"}, {"render_revision": True}, {"render_revision": -1},
                  {"render_revision": 2**63}, {"connection": None}, {"operations": "export_canvas"}, {"operations": [1]}):
        assert WorkspaceContext.from_provider({**_context(), **patch}, _token()) is None
    assert WorkspaceContext.from_provider(None, _token()) is None
    assert WorkspaceContext.from_provider(_context(), "bad") is None


class Transport:
    def __init__(self):
        self.calls = []
        self.error = None

    def export_canvas(self, token, chat, revision):
        self.calls.append(("export", token, chat, revision, threading.get_ident()))
        if self.error:
            raise self.error
        return b"<html>Native test</html>"

    def share_canvas(self, token, chat):
        self.calls.append(("share", token, chat, threading.get_ident()))
        if self.error:
            raise self.error
        return "https://server.test/share/" + "a" * 32


def _controller(**kwargs):
    context, queued, notices, saved, shared = _context(), [], [], [], []
    transport = Transport()
    controller = WorkspaceActions(parent=None, context_provider=lambda: context, token_provider=_token,
                                  http_base="https://server.test", notify=notices.append, transport=transport,
                                  save_export=lambda data, current: saved.append((data, current())),
                                  share_ready=shared.append, start_worker=queued.append, **kwargs)
    return controller, context, queued, notices, saved, shared, transport


def test_controller_runs_each_advertised_action_once_and_delivers_on_gui(qapp):
    controller, context, queued, notices, saved, shared, transport = _controller()
    assert controller.perform("export_canvas")
    assert not controller.perform("export_canvas")
    assert not controller.perform("unknown")
    assert not transport.calls
    queued.pop(0)()
    assert saved == [(b"<html>Native test</html>", True)]
    assert controller.perform("share_canvas")
    queued.pop(0)()
    assert shared == ["https://server.test/share/" + "a" * 32]
    assert not notices and not controller._active


@pytest.mark.parametrize("change", [{"chat_id": "different"}, {"connection": "different"},
                                   {"owner": "different"}, {"render_revision": 8}, {"operations": []}])
def test_stale_exports_never_expose_bytes(qapp, change):
    controller, context, queued, notices, saved, shared, transport = _controller()
    assert controller.perform("export_canvas")
    context.update(change)
    queued.pop(0)()
    assert not saved and not notices
    assert not controller._active


def test_clear_or_invalidation_cancels_before_network(qapp):
    controller, context, queued, notices, saved, shared, transport = _controller()
    controller.perform("export_canvas")
    controller.clear()
    queued.pop(0)()
    assert not transport.calls
    controller.perform("share_canvas")
    context["chat_id"] = "changed"
    controller.invalidate_stale()
    queued.pop(0)()
    assert not transport.calls and not saved and not shared


def test_share_retains_server_snapshot_semantics_when_revision_changes(qapp):
    controller, context, queued, notices, saved, shared, transport = _controller()
    controller.perform("share_canvas")
    context["render_revision"] += 1
    queued.pop(0)()
    assert len(shared) == 1


@pytest.mark.parametrize("failure,expected", [(WorkspaceFailure("PHI denied"), "PHI denied"), (RuntimeError("private-token"), EXPORT_FAILED)])
def test_controller_failures_do_not_leak_credentials(qapp, failure, expected):
    controller, context, queued, notices, saved, shared, transport = _controller()
    transport.error = failure
    controller.perform("export_canvas")
    queued.pop(0)()
    assert notices == [expected] and not saved


def test_worker_start_and_destination_failures_are_visible(qapp):
    controller, context, queued, notices, saved, shared, transport = _controller()
    def fail(*args):
        raise OSError("private")
    controller.start_worker = fail
    assert not controller.perform("export_canvas")
    assert "could not start" in notices[-1]
    controller.start_worker = queued.append
    controller.save_export = fail
    controller.perform("export_canvas")
    queued.pop(0)()
    assert "could not be saved" in notices[-1]


def test_default_worker_is_off_gui_thread(qapp):
    controller, context, queued, notices, saved, shared, transport = _controller()
    controller.start_worker = WorkspaceActions._start_worker
    assert controller.perform("export_canvas")
    for _ in range(100):
        qapp.processEvents()
        if saved:
            break
        QTest.qWait(10)
    assert saved and transport.calls[0][-1] != threading.get_ident()


def test_native_save_is_atomic_and_rechecks_after_dialog(qapp, tmp_path, monkeypatch):
    controller, context, queued, notices, saved, shared, transport = _controller()
    path = tmp_path / "canvas.html"
    monkeypatch.setattr("astral_client.workspace_actions.QFileDialog.getSaveFileName", lambda *a: (str(path), "HTML"))
    controller._save_export(b"<html>safe</html>", lambda: True)
    assert path.read_bytes() == b"<html>safe</html>"
    controller._save_export(b"<html>stale</html>", lambda: False)
    assert path.read_bytes() == b"<html>safe</html>"
    monkeypatch.setattr("astral_client.workspace_actions.QFileDialog.getSaveFileName", lambda *a: ("", ""))
    controller._save_export(b"cancelled", lambda: True)
    assert notices == ["Canvas saved."]


@pytest.mark.parametrize("mode", ["open", "write", "commit", "stale"])
def test_save_failure_cancels_without_success_notice(qapp, monkeypatch, mode):
    controller, context, queued, notices, saved, shared, transport = _controller()
    cancelled = []
    class File:
        def __init__(self, path):
            pass
        def open(self, flags):
            return mode != "open"
        def write(self, data):
            return -1 if mode == "write" else len(data)
        def commit(self):
            return mode != "commit"
        def cancelWriting(self):
            cancelled.append(True)
    monkeypatch.setattr("astral_client.workspace_actions.QSaveFile", File)
    monkeypatch.setattr("astral_client.workspace_actions.QFileDialog.getSaveFileName", lambda *a: ("canvas.html", ""))
    checked = []
    def current():
        checked.append(True)
        return mode != "stale" or len(checked) < 2
    with pytest.raises(WorkspaceFailure):
        controller._save_export(b"data", current)
    assert not notices
    assert bool(cancelled) == (mode in {"write", "stale"})


def test_native_share_copies_only_validated_link(qapp):
    controller, context, queued, notices, saved, shared, transport = _controller()
    controller._share_ready("https://server.test/share/" + "a" * 32)
    assert qapp.clipboard().text() == "https://server.test/share/" + "a" * 32
    qapp.clipboard().clear()
    assert notices == ["Share link copied to clipboard."]


def test_workspace_chrome_descriptors_are_consumed_without_surface_alias():
    model = {"topbar": [
        {"kind": "workspace_action", "context": "live_canvas", "operation": "export_canvas", "label": "Export", "icon": "download"},
        {"kind": "workspace_action", "context": "live_canvas", "operation": "share_canvas", "label": "Share"},
        {"kind": "workspace_action", "context": "owned_chat", "operation": "share_canvas"},
        {"kind": "workspace_action", "context": "live_canvas", "operation": "unknown"},
        {"kind": "workspace_action", "context": "live_canvas", "operation": []},
        {"kind": "workspace_action", "context": "live_canvas", "operation": "export_canvas", "action": {}},
        {"kind": "workspace_action", "context": "live_canvas", "operation": "export_canvas", "action": {"surface": "bad"}},
    ]}
    parsed = parse_chrome_menu(model)
    assert parsed["topbar_actions"] == []
    assert parsed["workspace_actions"] == [
        {"label": "Export", "icon": "download", "operation": "export_canvas"},
        {"label": "Share", "icon": "", "operation": "share_canvas"},
    ]


def test_duplicate_encoding_and_incomplete_transport_are_refused():
    response = Response(headers={"Content-Length": "1"})
    response.headers["Content-Length"] = "1"
    rest = WorkspaceRest("https://server.test", opener=lambda *a, **k: response)
    with pytest.raises(WorkspaceFailure, match="format is unsupported"):
        rest.export_canvas("token", "chat-one", 7)
    rest.opener = lambda *a, **k: Response(headers={"Content-Encoding": "gzip"})
    with pytest.raises(WorkspaceFailure, match="format is unsupported"):
        rest.export_canvas("token", "chat-one", 7)
    rest.opener = lambda *a, **k: Response(b"abc", headers={"Content-Length": "4"})
    with pytest.raises(WorkspaceFailure, match="interrupted"):
        rest.export_canvas("token", "chat-one", 7)


def test_absolute_transport_deadline(qapp, monkeypatch):
    readings = iter([0, 31])
    monkeypatch.setattr("astral_client.workspace_actions.time.monotonic", lambda: next(readings))
    rest = WorkspaceRest("https://server.test", opener=lambda *a, **k: Response())
    with pytest.raises(WorkspaceFailure, match="timed out"):
        rest.export_canvas("token", "chat-one", 7)


def test_invalid_port_and_share_authority():
    with pytest.raises(WorkspaceFailure):
        WorkspaceRest("https://server.test:0")
    rest = WorkspaceRest("https://server.test", opener=lambda *a, **k: Response(b'{"share_url":"https://[invalid"}',
                         201, headers={"Content-Type": "application/json"}))
    with pytest.raises(WorkspaceFailure, match=SHARE_FAILED):
        rest.share_canvas("token", "chat-one")


def test_malformed_operation_never_starts_worker(qapp):
    controller, context, queued, notices, saved, shared, transport = _controller()
    assert not controller.perform([])
    assert not queued
