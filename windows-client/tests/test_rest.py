"""Tests for astral_client/rest.py: the audit REST helper's URL building, Bearer auth,
response shaping, and error mapping for logout, the chrome menu model, audit queries,
attachment upload, bounded streaming downloads, and atomic download saves — via injected
openers and deterministic failure injection, no real network.
"""

import os
import urllib.error

import pytest

from astral_client.rest import (
    DOWNLOAD_LIMIT,
    EVENT_CLASSES,
    OUTCOMES,
    RestError,
    audit_url,
    chrome_menu_url,
    fetch_bytes,
    fetch_json,
    keycloak_logout,
    native_logout,
    parse_audit_response,
    parse_chrome_menu,
    upload_attachment,
    write_download,
)


class _FakeLogoutResp:
    def __init__(self, status):
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self, *a):
        return b""


def test_native_logout_posts_bearer_and_body():
    seen = {}

    def opener(req, timeout=None):
        seen["url"] = req.full_url
        seen["method"] = req.get_method()
        seen["auth"] = req.get_header("Authorization")
        seen["body"] = req.data
        return _FakeLogoutResp(200)

    ok = native_logout("http://h:8001", "acc-tok", "rt-1", "astral-desktop", opener=opener)
    assert ok is True
    assert seen["url"] == "http://h:8001/api/auth/logout"
    assert seen["method"] == "POST"
    assert seen["auth"] == "Bearer acc-tok"
    import json as _j
    body = _j.loads(seen["body"])
    assert body == {"refresh_token": "rt-1", "client_id": "astral-desktop"}


def test_native_logout_false_on_error_status():
    def opener(req, timeout=None):
        return _FakeLogoutResp(500)

    assert native_logout("http://h:8001", "t", "rt", "astral-desktop", opener=opener) is False


def test_native_logout_false_on_transport_error():
    def opener(req, timeout=None):
        raise OSError("connection refused")

    assert native_logout("http://h:8001", "t", "rt", "astral-desktop", opener=opener) is False


def test_keycloak_logout_direct_fallback():
    seen = {}

    def opener(req, timeout=None):
        seen["url"] = req.full_url
        seen["body"] = req.data
        return _FakeLogoutResp(204)

    ok = keycloak_logout("https://iam.example/realms/Astral", "astral-desktop", "rt-9", opener=opener)
    assert ok is True
    assert seen["url"] == "https://iam.example/realms/Astral/protocol/openid-connect/logout"
    assert b"refresh_token=rt-9" in seen["body"] and b"client_id=astral-desktop" in seen["body"]


def test_keycloak_logout_noop_without_inputs():
    assert keycloak_logout("", "c", "rt") is False
    assert keycloak_logout("https://iam", "c", "") is False


def test_chrome_menu_url():
    assert chrome_menu_url("http://h:8001/") == "http://h:8001/api/chrome/menu"


def test_parse_chrome_menu_full():
    model = {
        "version": 1,
        "topbar": [
            {"key": "brand", "kind": "brand"},
            {"key": "timeline", "kind": "action", "label": "Workspace timeline",
             "icon": "history", "action": {"surface": "workspace_timeline", "params": {}}},
            {"key": "settings", "kind": "menu", "label": "Settings", "icon": "gear"},
        ],
        "menu": [
            {"key": "account", "label": "Account", "items": [
                {"key": "agents", "label": "Agents & permissions", "surface": "agents", "params": {}},
                {"key": "audit", "label": "Audit log", "surface": "audit", "params": {}},
            ]},
            {"key": "admin", "label": "Admin tools", "admin_only": True, "items": [
                {"key": "tq", "label": "Tool quality", "surface": "admin_tools", "params": {"tab": "quality"}},
            ]},
        ],
        "signout": {"key": "signout", "label": "Sign out", "style": "danger", "action": "logout"},
    }
    parsed = parse_chrome_menu(model)
    assert [s["label"] for s in parsed["sections"]] == ["Account", "Admin tools"]
    assert [i["surface"] for i in parsed["sections"][0]["items"]] == ["agents", "audit"]
    assert parsed["sections"][0]["items"][0]["label"] == "Agents & permissions"
    assert parsed["sections"][1]["items"][0]["params"] == {"tab": "quality"}
    assert [a["surface"] for a in parsed["topbar_actions"]] == ["workspace_timeline"]
    assert parsed["signout"] == {"label": "Sign out", "action": "logout"}


def test_parse_chrome_menu_tolerates_empty_and_malformed():
    assert parse_chrome_menu({}) == {
        "sections": [], "topbar_actions": [], "workspace_actions": [],
        "signout": {"label": "Sign out", "action": "logout"},
    }
    assert parse_chrome_menu(None)["sections"] == []
    m = {"menu": [
        {"label": "Empty", "items": [{"label": "nosurf"}]},
        {"label": "Ok", "items": [{"label": "A", "surface": "agents"}]},
    ]}
    assert [s["label"] for s in parse_chrome_menu(m)["sections"]] == ["Ok"]


def test_audit_url_minimal():
    assert audit_url("http://h:8001") == "http://h:8001/api/audit?limit=50"


def test_audit_url_strips_trailing_slash_and_encodes_filters():
    u = audit_url("http://h:8001/", limit=25, event_class="auth",
                  outcome="failure", q="login x", cursor="c1")
    assert u.startswith("http://h:8001/api/audit?")
    assert "limit=25" in u
    assert "event_class=auth" in u
    assert "outcome=failure" in u
    assert "q=login+x" in u
    assert "cursor=c1" in u


def test_audit_url_omits_empty_filters():
    assert audit_url("http://h:8001", event_class="", outcome="", q="", cursor="") \
        == "http://h:8001/api/audit?limit=50"


def test_parse_audit_response_rows_and_cursor():
    data = {
        "items": [{
            "event_id": "e1",
            "recorded_at": "2026-06-30T12:34:56.789012+00:00",
            "event_class": "auth",
            "action_type": "auth.ws_register",
            "outcome": "success",
            "description": "registered",
        }],
        "next_cursor": "NEXT",
    }
    rows, nxt = parse_audit_response(data)
    assert nxt == "NEXT"
    assert rows[0]["recorded_at"] == "2026-06-30 12:34:56"
    assert rows[0]["event_class"] == "auth"
    assert rows[0]["outcome"] == "success"
    assert rows[0]["action_type"] == "auth.ws_register"


def test_parse_audit_response_empty_and_missing_cursor():
    rows, nxt = parse_audit_response({"items": []})
    assert rows == [] and nxt is None


def test_parse_audit_response_defensive_against_bad_items():
    rows, _ = parse_audit_response({"items": [None, 7, {"event_id": "e"}]})
    assert len(rows) == 1
    assert rows[0]["event_class"] == ""
    assert rows[0]["recorded_at"] == "-"


class _FakeResp:
    def __init__(self, data: bytes):
        self._data = data

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self, n: int = -1) -> bytes:
        return self._data


def test_fetch_json_sends_bearer_and_parses():
    captured = {}

    def opener(req, timeout=None):
        captured["auth"] = req.get_header("Authorization")
        captured["url"] = req.full_url
        return _FakeResp(b'{"items": [], "next_cursor": null}')

    data = fetch_json("http://h/api/audit?limit=50", "TOK", opener=opener)
    assert data == {"items": [], "next_cursor": None}
    assert captured["auth"] == "Bearer TOK"
    assert captured["url"] == "http://h/api/audit?limit=50"


def test_fetch_json_http_error_becomes_resterror():
    def opener(req, timeout=None):
        raise urllib.error.HTTPError(req.full_url, 401, "Unauthorized", {}, None)

    with pytest.raises(RestError) as ei:
        fetch_json("http://h/api/audit", "TOK", opener=opener)
    assert ei.value.status == 401


def test_fetch_json_transport_error_becomes_resterror():
    def opener(req, timeout=None):
        raise OSError("connection refused")

    with pytest.raises(RestError) as ei:
        fetch_json("http://h/api/audit", "TOK", opener=opener)
    assert ei.value.status == 0


def test_event_classes_and_outcomes_exported():
    assert "auth" in EVENT_CLASSES and "agent_lifecycle" in EVENT_CLASSES
    assert OUTCOMES == ("in_progress", "success", "failure", "interrupted")


def test_upload_attachment_multipart_bearer_and_parse():
    seen = {}

    def opener(req, timeout=None):
        seen["url"] = req.full_url
        seen["method"] = req.get_method()
        seen["auth"] = req.get_header("Authorization")
        seen["ctype"] = req.get_header("Content-type")
        seen["body"] = req.data
        return _FakeResp(
            b'{"attachment_id":"att-1","filename":"a.csv",'
            b'"category":"data","parser_status":"covered"}'
        )

    out = upload_attachment("http://h:8001", "TOK", "a.csv", "text/csv",
                            b"col\n1\n", opener=opener)
    assert out == {"attachment_id": "att-1", "filename": "a.csv",
                   "category": "data", "parser_status": "covered"}
    assert seen["url"] == "http://h:8001/api/upload"
    assert seen["method"] == "POST"
    assert seen["auth"] == "Bearer TOK"
    assert seen["ctype"].startswith("multipart/form-data; boundary=")
    assert b'name="file"; filename="a.csv"' in seen["body"]
    assert b"col\n1\n" in seen["body"]


def test_upload_attachment_http_error_becomes_resterror():
    def opener(req, timeout=None):
        raise urllib.error.HTTPError(req.full_url, 413, "Payload Too Large", {}, None)

    with pytest.raises(RestError) as ei:
        upload_attachment("http://h", "T", "f", "text/plain", b"x", opener=opener)
    assert ei.value.status == 413


def test_upload_attachment_transport_error_becomes_resterror():
    def opener(req, timeout=None):
        raise OSError("connection refused")

    with pytest.raises(RestError) as ei:
        upload_attachment("http://h", "T", "f", "text/plain", b"x", opener=opener)
    assert ei.value.status == 0


class _StreamResp:
    def __init__(self, chunks, headers=None):
        self._buffer = bytearray(b"".join(chunks))
        self.headers = {} if headers is None else headers
        self.reads = []
        self.auth = None
        self.url = None

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self, n: int = -1) -> bytes:
        self.reads.append(n)
        if n is None or n < 0:
            data = bytes(self._buffer)
            self._buffer.clear()
            return data
        data = bytes(self._buffer[:n])
        del self._buffer[:n]
        return data


class _BreakingResp(_StreamResp):
    def __init__(self, chunks, fail_after=1, headers=None):
        super().__init__(chunks, headers)
        self._fail_after = fail_after

    def read(self, n: int = -1) -> bytes:
        if len(self.reads) >= self._fail_after:
            raise OSError("connection reset by peer")
        return super().read(n)


def test_fetch_bytes_streams_bounded_chunks_with_bearer():
    resp = _StreamResp([b"x" * 300, b"y" * 300], headers={"Content-Length": "600"})

    def opener(req, timeout=None):
        resp.auth = req.get_header("Authorization")
        resp.url = req.full_url
        return resp

    data = fetch_bytes("http://h/api/result", "TOK", opener=opener, limit=1024)
    assert data == b"x" * 300 + b"y" * 300
    assert resp.auth == "Bearer TOK"
    assert resp.url == "http://h/api/result"
    assert resp.reads[0] == 1025
    assert all(n <= 1025 for n in resp.reads)


def test_fetch_bytes_uses_production_chunk_bound():
    body = bytes(range(256)) * 1024
    resp = _StreamResp([body])

    def opener(req, timeout=None):
        return resp

    data = fetch_bytes("http://h/api/result", "TOK", opener=opener)
    assert data == body
    assert resp.reads == [256 * 1024, 256 * 1024]


def test_fetch_bytes_accepts_zero_bytes():
    def opener(req, timeout=None):
        return _StreamResp([], headers={"Content-Length": "0"})

    assert fetch_bytes("http://h/api/result", "TOK", opener=opener) == b""


def test_fetch_bytes_accepts_exact_limit():
    def opener(req, timeout=None):
        return _StreamResp([b"12345", b"678"], headers={"Content-Length": "8"})

    assert fetch_bytes("http://h/api/result", "TOK", opener=opener, limit=8) == b"12345678"


def test_fetch_bytes_rejects_declared_over_limit_without_reading():
    resp = _StreamResp([b"123456789"], headers={"Content-Length": "9"})

    def opener(req, timeout=None):
        return resp

    with pytest.raises(RestError) as ei:
        fetch_bytes("http://h/api/result", "TOK", opener=opener, limit=8)
    assert ei.value.status == 0
    assert "declared 9 bytes" in ei.value.message
    assert "8 byte download limit" in ei.value.message
    assert resp.reads == []


def test_fetch_bytes_rejects_chunked_over_limit():
    def opener(req, timeout=None):
        return _StreamResp([b"12345", b"6789"])

    with pytest.raises(RestError) as ei:
        fetch_bytes("http://h/api/result", "TOK", opener=opener, limit=8)
    assert "the body exceeded the 8 byte download limit" in ei.value.message


def test_fetch_bytes_rejects_body_over_incorrect_declared_length():
    def opener(req, timeout=None):
        return _StreamResp([b"123456789"], headers={"Content-Length": "5"})

    with pytest.raises(RestError) as ei:
        fetch_bytes("http://h/api/result", "TOK", opener=opener, limit=8)
    assert "the body exceeded the 8 byte download limit" in ei.value.message


def test_fetch_bytes_rejects_transport_truncation():
    def opener(req, timeout=None):
        return _StreamResp([b"123456"], headers={"Content-Length": "10"})

    with pytest.raises(RestError) as ei:
        fetch_bytes("http://h/api/result", "TOK", opener=opener, limit=64)
    assert ei.value.status == 0
    assert "received 6 of 10 declared bytes" in ei.value.message


def test_fetch_bytes_tolerates_absent_content_length():
    def opener(req, timeout=None):
        return _StreamResp([b"abc", b"def"])

    assert fetch_bytes("http://h/api/result", "TOK", opener=opener, limit=16) == b"abcdef"


def test_fetch_bytes_treats_malformed_content_length_as_absent():
    for bad in ("abc", "", "-4", None):
        def opener(req, timeout=None, bad=bad):
            return _StreamResp([b"abc"], headers={"Content-Length": bad})

        assert fetch_bytes("http://h/api/result", "TOK", opener=opener, limit=16) == b"abc"


def test_fetch_bytes_maps_interrupted_read_to_resterror():
    def opener(req, timeout=None):
        return _BreakingResp([b"123456"], fail_after=1)

    with pytest.raises(RestError) as ei:
        fetch_bytes("http://h/api/result", "TOK", opener=opener)
    assert ei.value.status == 0
    assert "connection reset by peer" in ei.value.message


def test_fetch_bytes_rejects_limit_plus_one_at_production_limit():
    def opener(req, timeout=None):
        return _StreamResp([bytes(DOWNLOAD_LIMIT + 1)])

    with pytest.raises(RestError) as ei:
        fetch_bytes("http://h/api/result", "TOK", opener=opener)
    assert f"the body exceeded the {DOWNLOAD_LIMIT} byte download limit" in ei.value.message


def test_fetch_bytes_accepts_exact_production_limit():
    body = bytes(DOWNLOAD_LIMIT)

    def opener(req, timeout=None):
        return _StreamResp([body], headers={"Content-Length": str(DOWNLOAD_LIMIT)})

    assert fetch_bytes("http://h/api/result", "TOK", opener=opener) == body


def test_write_download_replaces_destination_atomically(tmp_path, monkeypatch):
    destination = tmp_path / "result.bin"
    destination.write_bytes(b"old bytes")
    seen = {}

    real_replace = os.replace

    def replace(src, dst):
        seen["src"] = src
        seen["dst"] = dst
        return real_replace(src, dst)

    monkeypatch.setattr(os, "replace", replace)

    write_download(str(destination), b"new bytes")

    assert destination.read_bytes() == b"new bytes"
    assert os.path.dirname(seen["src"]) == str(tmp_path)
    assert seen["src"].endswith(".part")
    assert seen["dst"] == str(destination)
    assert list(tmp_path.glob("*.part")) == []


def test_write_download_creates_missing_destination(tmp_path):
    destination = tmp_path / "fresh.bin"

    write_download(str(destination), b"payload")

    assert destination.read_bytes() == b"payload"
    assert list(tmp_path.glob("*.part")) == []


def test_write_download_writes_empty_payload(tmp_path):
    destination = tmp_path / "empty.bin"

    write_download(str(destination), b"")

    assert destination.read_bytes() == b""


def test_write_download_preserves_destination_when_replace_fails(tmp_path, monkeypatch):
    destination = tmp_path / "keep.bin"
    destination.write_bytes(b"original")

    def fail_replace(src, dst):
        raise OSError("replace denied")

    monkeypatch.setattr(os, "replace", fail_replace)

    with pytest.raises(OSError):
        write_download(str(destination), b"replacement")

    assert destination.read_bytes() == b"original"
    assert list(tmp_path.glob("*.part")) == []


def test_write_download_preserves_destination_when_write_fails(tmp_path, monkeypatch):
    destination = tmp_path / "keep.bin"
    destination.write_bytes(b"original")

    def fail_fsync(fd):
        raise OSError("disk full")

    monkeypatch.setattr(os, "fsync", fail_fsync)

    with pytest.raises(OSError):
        write_download(str(destination), b"replacement")

    assert destination.read_bytes() == b"original"
    assert list(tmp_path.glob("*.part")) == []


def test_write_download_cleans_temp_sibling_when_open_fails(tmp_path, monkeypatch):
    destination = tmp_path / "keep.bin"
    destination.write_bytes(b"original")

    def fail_fdopen(fd, *args):
        raise OSError("fdopen refused")

    monkeypatch.setattr(os, "fdopen", fail_fdopen)

    with pytest.raises(OSError):
        write_download(str(destination), b"replacement")

    assert destination.read_bytes() == b"original"
    assert list(tmp_path.glob("*.part")) == []


def test_fetch_bytes_http_error_becomes_resterror():
    def opener(req, timeout=None):
        raise urllib.error.HTTPError(req.full_url, 404, "Not Found", {}, None)

    with pytest.raises(RestError) as ei:
        fetch_bytes("http://h/api/result", "TOK", opener=opener)
    assert ei.value.status == 404
    assert ei.value.message == "Not Found"


def test_fetch_bytes_tolerates_hostile_headers_object():
    class _HostileHeaders:
        def get(self, name):
            raise RuntimeError("header store corrupted")

    def opener(req, timeout=None):
        return _StreamResp([b"abc"], headers=_HostileHeaders())

    assert fetch_bytes("http://h/api/result", "TOK", opener=opener, limit=16) == b"abc"


def test_write_download_survives_temp_cleanup_failure(tmp_path, monkeypatch):
    destination = tmp_path / "keep.bin"
    destination.write_bytes(b"original")

    def fail_replace(src, dst):
        raise OSError("replace denied")

    def fail_unlink(path):
        raise OSError("temp already gone")

    monkeypatch.setattr(os, "replace", fail_replace)
    monkeypatch.setattr(os, "unlink", fail_unlink)

    with pytest.raises(OSError) as ei:
        write_download(str(destination), b"replacement")

    assert "replace denied" in str(ei.value)
    assert destination.read_bytes() == b"original"
    assert len(list(tmp_path.glob("*.part"))) == 1
