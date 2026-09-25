"""Runs server-declared canvas export and share actions for the native shell.
Bearer requests and result delivery stay bound to the current account, connection and conversation.
"""

from __future__ import annotations

import json
import re
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from urllib.parse import quote, urljoin, urlsplit

from PySide6.QtCore import QIODevice, QObject, QSaveFile, Signal
from PySide6.QtWidgets import QApplication, QFileDialog

from .protocol import ConversationResumeStore, decode_token_account


OPERATIONS = frozenset({"export_canvas", "share_canvas"})
MAX_EXPORT_BYTES = 32 * 1024 * 1024
EXPORT_FAILED = "Could not export this canvas. Try again."
SHARE_FAILED = "Could not create the share link. Try again."
REVISION_CHANGED = "The canvas changed. Reopen the result before exporting."
AUTH_REQUIRED = "Sign in again before exporting or sharing."


class WorkspaceFailure(Exception):
    pass


def _origin(value):
    if not isinstance(value, str) or value != value.strip() or any(ord(c) < 32 or c == "\\" for c in value):
        raise WorkspaceFailure("The server address is invalid.")
    try:
        parsed = urlsplit(value)
        if (parsed.scheme not in {"http", "https"} or not parsed.hostname
                or parsed.username is not None or parsed.password is not None
                or parsed.query or parsed.fragment):
            raise ValueError
        port = parsed.port if parsed.port is not None else (443 if parsed.scheme == "https" else 80)
        if not 1 <= port <= 65535:
            raise ValueError
    except ValueError as exc:
        raise WorkspaceFailure("The server address is invalid.") from exc
    return parsed, (parsed.scheme, parsed.hostname, port)


def _json_object(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate JSON key")
            result[key] = value
        return result

    value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique)
    if not isinstance(value, dict):
        raise ValueError("Expected JSON object")
    return value


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise WorkspaceFailure("The server redirected this request. Check the server address and try again.")


class WorkspaceRest:
    def __init__(self, http_base, *, opener=None):
        parsed, self.origin = _origin(http_base)
        self.base = f"{parsed.scheme}://{parsed.netloc}"
        self.opener = opener or urllib.request.build_opener(_NoRedirect()).open

    def _request(self, path, token, *, body=None, limit=MAX_EXPORT_BYTES):
        if (not isinstance(token, str) or not token.strip() or len(token) > 16384
                or any(ord(char) < 32 for char in token)):
            raise WorkspaceFailure(AUTH_REQUIRED)
        headers = {"Authorization": f"Bearer {token}", "Cache-Control": "no-store"}
        if body is not None:
            headers["Content-Type"] = "application/json"
            headers["Accept"] = "application/json"
        request = urllib.request.Request(self.base + path, data=body, headers=headers,
                                         method="POST" if body is not None else "GET")
        deadline = time.monotonic() + 30
        try:
            response = self.opener(request, timeout=30)
        except urllib.error.HTTPError as exc:
            response = exc
        except WorkspaceFailure:
            raise
        except Exception as exc:
            raise WorkspaceFailure("The server could not be reached. Check your connection and try again.") from exc
        try:
            with response:
                status = response.status
                lengths = response.headers.get_all("Content-Length", [])
                content_length = lengths[0] if lengths else None
                if len(lengths) > 1 or response.headers.get("Content-Encoding", "identity") != "identity":
                    raise WorkspaceFailure("The server response format is unsupported. Try again.")
                if content_length and (not content_length.isdigit() or int(content_length) > limit):
                    raise WorkspaceFailure("The server response is too large to export safely.")
                data = bytearray()
                reader = getattr(response, "read1", response.read)
                while True:
                    if time.monotonic() > deadline:
                        raise WorkspaceFailure("The action timed out. Try again.")
                    chunk = reader(min(65536, limit + 1 - len(data)))
                    if not chunk:
                        break
                    data.extend(chunk)
                    if len(data) > limit:
                        raise WorkspaceFailure("The server response is too large to export safely.")
                if content_length is not None and int(content_length) != len(data):
                    raise WorkspaceFailure("The server response was interrupted. Try again.")
                return status, response.headers, bytes(data)
        except WorkspaceFailure:
            raise
        except Exception as exc:
            raise WorkspaceFailure("The server response was interrupted. Try again.") from exc

    def export_canvas(self, token, chat_id, revision):
        path = f"/api/export/canvas/{quote(chat_id, safe='')}.html?render_revision={revision}"
        status, headers, data = self._request(path, token)
        if status in {401, 403}:
            raise WorkspaceFailure(AUTH_REQUIRED)
        if status == 409 or status == 200 and headers.get_all("X-Astral-Render-Revision") != [str(revision)]:
            raise WorkspaceFailure(REVISION_CHANGED)
        if status != 200 or not data or headers.get_content_type() != "text/html":
            raise WorkspaceFailure(EXPORT_FAILED)
        return data

    def share_canvas(self, token, chat_id):
        body = json.dumps({"chat_id": chat_id, "scope": "canvas"}).encode("utf-8")
        status, headers, data = self._request("/api/share", token, body=body, limit=65536)
        try:
            payload = _json_object(data)
        except (ValueError, UnicodeError, RecursionError) as exc:
            raise WorkspaceFailure(SHARE_FAILED) from exc
        if status == 403 and payload.get("error") == "phi_blocked":
            raise WorkspaceFailure("Sharing refused: the content matched the PHI gate.")
        if status in {401, 403}:
            raise WorkspaceFailure(AUTH_REQUIRED)
        if status != 201 or headers.get_content_type() != "application/json":
            raise WorkspaceFailure(SHARE_FAILED)
        reference = payload.get("share_url")
        if (not isinstance(reference, str) or reference != reference.strip()
                or reference.startswith("//") or any(ord(c) < 32 or c == "\\" for c in reference)):
            raise WorkspaceFailure(SHARE_FAILED)
        try:
            raw = urlsplit(reference)
        except ValueError as exc:
            raise WorkspaceFailure(SHARE_FAILED) from exc
        if not re.fullmatch(r"/share/[A-Za-z0-9_-]{32,256}", raw.path):
            raise WorkspaceFailure(SHARE_FAILED)
        resolved = urljoin(self.base, reference)
        _, origin = _origin(resolved)
        if origin != self.origin:
            raise WorkspaceFailure(SHARE_FAILED)
        return resolved


@dataclass(frozen=True)
class WorkspaceContext:
    owner: str
    connection: str
    chat_id: str
    render_revision: int
    operations: frozenset[str]

    @classmethod
    def from_provider(cls, value, token):
        if not isinstance(value, dict):
            return None
        identity = decode_token_account(token)
        if identity is None:
            return None
        owner = ConversationResumeStore.account_key(*identity)
        chat, revision = value.get("chat_id"), value.get("render_revision")
        operations = value.get("operations")
        connection = value.get("connection")
        if (value.get("owner") != owner or not isinstance(chat, str)
                or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", chat)
                or type(revision) is not int or not 0 <= revision <= 2**63 - 1
                or not isinstance(connection, str) or not connection
                or not isinstance(operations, (list, tuple, set, frozenset))
                or not all(isinstance(item, str) for item in operations)):
            return None
        return cls(owner, connection, chat, revision, frozenset(operations) & OPERATIONS)


@dataclass(eq=False, repr=False)
class _Ticket:
    operation: str
    context: WorkspaceContext
    cancelled: threading.Event = field(default_factory=threading.Event)


class WorkspaceActions(QObject):
    _completed = Signal(object, object, object)

    def __init__(self, *, parent, context_provider, token_provider, http_base, notify,
                 transport=None, save_export=None, share_ready=None, start_worker=None):
        super().__init__(parent)
        self.context_provider, self.token_provider = context_provider, token_provider
        self.notify = notify
        self.transport = transport or WorkspaceRest(http_base)
        self.save_export = save_export or self._save_export
        self.share_ready = share_ready or self._share_ready
        self.start_worker = start_worker or self._start_worker
        self._active = {}
        self._completed.connect(self._finish)

    def _current(self):
        return WorkspaceContext.from_provider(self.context_provider(), self.token_provider())

    def _is_current(self, ticket):
        current = self._current()
        return (not ticket.cancelled.is_set() and self._active.get(ticket.operation) is ticket
                and current is not None and ticket.operation in current.operations
                and current.owner == ticket.context.owner and current.connection == ticket.context.connection
                and current.chat_id == ticket.context.chat_id
                and (ticket.operation != "export_canvas" or current.render_revision == ticket.context.render_revision))

    def perform(self, operation):
        if not isinstance(operation, str):
            return False
        self.invalidate_stale()
        context = self._current()
        if (context is None or operation not in context.operations or operation in self._active):
            return False
        ticket = _Ticket(operation, context)
        token = self.token_provider()
        self._active[operation] = ticket

        def execute():
            result, error = None, None
            try:
                if ticket.cancelled.is_set():
                    return
                if operation == "share_canvas":
                    result = self.transport.share_canvas(token, context.chat_id)
                else:
                    result = self.transport.export_canvas(token, context.chat_id, context.render_revision)
            except WorkspaceFailure as exc:
                error = str(exc)
            except Exception:
                error = SHARE_FAILED if operation == "share_canvas" else EXPORT_FAILED
            if not ticket.cancelled.is_set():
                self._completed.emit(ticket, result, error)

        try:
            self.start_worker(execute)
        except Exception:
            self._active.pop(operation, None)
            self.notify("The action could not start. Try again.")
            return False
        return True

    @staticmethod
    def _start_worker(callback):
        threading.Thread(target=callback, daemon=True).start()

    def _finish(self, ticket, result, error):
        try:
            if not self._is_current(ticket):
                return
            if error:
                self.notify(error)
            elif ticket.operation == "share_canvas":
                self.share_ready(result)
            else:
                self.save_export(result, lambda: self._is_current(ticket))
        except Exception:
            if self._is_current(ticket):
                self.notify("The result could not be saved. Try again.")
        finally:
            if self._active.get(ticket.operation) is ticket:
                self._active.pop(ticket.operation, None)

    def invalidate_stale(self):
        for ticket in list(self._active.values()):
            if not self._is_current(ticket):
                ticket.cancelled.set()
                self._active.pop(ticket.operation, None)

    def clear(self):
        for ticket in self._active.values():
            ticket.cancelled.set()
        self._active.clear()

    def _save_export(self, data, is_current):
        path, _ = QFileDialog.getSaveFileName(self.parent(), "Save canvas", "canvas.html", "HTML (*.html)")
        if not path or not is_current():
            return
        destination = QSaveFile(path)
        if not destination.open(QIODevice.OpenModeFlag.WriteOnly):
            raise WorkspaceFailure(EXPORT_FAILED)
        if destination.write(data) != len(data) or not is_current():
            destination.cancelWriting()
            raise WorkspaceFailure(EXPORT_FAILED)
        if not destination.commit():
            raise WorkspaceFailure(EXPORT_FAILED)
        self.notify("Canvas saved.")

    def _share_ready(self, url):
        QApplication.clipboard().setText(url)
        self.notify("Share link copied to clipboard.")
