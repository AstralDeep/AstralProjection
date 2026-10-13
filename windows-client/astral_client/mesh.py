"""Protects a joining device's account-scoped Ed25519 key with Windows DPAPI.
The native shell shares only public identity and redeems current-server links through
an exact challenge signature, retaining member identifiers rather than bearer tokens.
"""

from __future__ import annotations

import base64
import ctypes
import hashlib
import json
import re
import sys
import time
import uuid
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    PrivateFormat,
    NoEncryption,
    PublicFormat,
)


class MeshCustodyError(ValueError):
    pass


def _refuse():
    raise MeshCustodyError(
        "Enrollment refused. Check the original joining device and current owner account."
    )


def _encode(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _decode(value, length=None):
    try:
        if type(value) is not str or not 1 <= len(value) <= 2048:
            _refuse()
        decoded = base64.b64decode(value + "=" * (-len(value) % 4), altchars=b"-_", validate=True)
        if _encode(decoded) != value or length is not None and len(decoded) != length:
            _refuse()
        return decoded
    except (ValueError, UnicodeError):
        _refuse()


def public_key(value):
    if (
        type(value) is not dict
        or set(value) != {"kty", "crv", "x"}
        or value["kty"] != "OKP"
        or value["crv"] != "Ed25519"
    ):
        _refuse()
    _decode(value["x"], 32)
    return {"kty": "OKP", "crv": "Ed25519", "x": value["x"]}


def _origin(value):
    parsed = urlsplit(value)
    if (
        parsed.scheme not in {"https", "http"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
    ):
        _refuse()
    if parsed.scheme == "http" and parsed.hostname not in {"localhost", "127.0.0.1", "::1"}:
        _refuse()
    try:
        parsed.port
    except ValueError:
        _refuse()
    return f"{parsed.scheme}://{parsed.netloc}"


def parse_link(link, origin, owner):
    if type(link) is not str or not 1 <= len(link) <= 4096:
        _refuse()
    parsed = urlsplit(link)
    if (
        f"{parsed.scheme}://{parsed.netloc}" != origin
        or parsed.path != "/enroll"
        or parsed.query
        or parsed.username is not None
        or parsed.password is not None
    ):
        _refuse()
    try:
        payload = json.loads(_decode(parsed.fragment))
    except (ValueError, UnicodeError):
        _refuse()
    if (
        type(payload) is not dict
        or set(payload) != {"v", "o", "i", "t", "c"}
        or type(payload["v"]) is not int
        or payload["v"] != 1
        or payload["o"] != owner
        or type(payload["i"]) is not str
        or not payload["i"].isalnum()
        or not 1 <= len(payload["i"]) <= 128
    ):
        _refuse()
    _decode(payload["t"], 32)
    return parsed.fragment, _decode(payload["c"], 32)


class _Blob(ctypes.Structure):
    _fields_ = [("size", ctypes.c_uint32), ("data", ctypes.c_void_p)]


class WindowsProtection:
    def transform(self, value, *, decrypt=False):
        if sys.platform != "win32" or type(value) is not bytes or not value:
            _refuse()
        source = ctypes.create_string_buffer(value)
        incoming = _Blob(len(value), ctypes.cast(source, ctypes.c_void_p))
        outgoing = _Blob()
        library = ctypes.WinDLL("crypt32", use_last_error=True)
        operation = library.CryptUnprotectData if decrypt else library.CryptProtectData
        operation.argtypes = [
            ctypes.POINTER(_Blob),
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_uint32,
            ctypes.POINTER(_Blob),
        ]
        operation.restype = ctypes.c_int
        if not operation(ctypes.byref(incoming), None, None, None, None, 1, ctypes.byref(outgoing)):
            _refuse()
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.LocalFree.argtypes = [ctypes.c_void_p]
        kernel.LocalFree.restype = ctypes.c_void_p
        try:
            return ctypes.string_at(outgoing.data, outgoing.size)
        finally:
            kernel.LocalFree(outgoing.data)


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        _refuse()


class MeshDeviceCustody:
    def __init__(self, origin, account, settings, *, protection=None, opener=None):
        self.origin = _origin(origin)
        if (
            type(account) is not tuple
            or len(account) != 2
            or any(type(part) is not str or not part for part in account)
        ):
            _refuse()
        self.owner = account[1]
        self.scope = (
            "mesh_device_v1/"
            + hashlib.sha256(
                json.dumps([self.origin, *account], separators=(",", ":")).encode()
            ).hexdigest()
        )
        self.settings = settings
        self.protection = protection or WindowsProtection()
        self.opener = opener or build_opener(_NoRedirect()).open
        self._proof_key = None

    def _sync(self):
        self.settings.sync()
        status = self.settings.status()
        if getattr(status, "value", status) != 0:
            _refuse()

    def _device(self, create=False):
        self._sync()
        saved = self.settings.value(self.scope, "", type=str)
        if not saved:
            if not create:
                _refuse()
            private = Ed25519PrivateKey.generate()
            raw = private.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
            protected = self.protection.transform(raw)
            self.settings.setValue(self.scope, _encode(protected))
            self._sync()
            if self.settings.value(self.scope, "", type=str) != _encode(protected):
                _refuse()
            return private
        try:
            return Ed25519PrivateKey.from_private_bytes(
                self.protection.transform(_decode(saved), decrypt=True)
            )
        except (ValueError, TypeError):
            _refuse()

    def public_identity(self):
        private = self._device(create=True)
        return {
            "kty": "OKP",
            "crv": "Ed25519",
            "x": _encode(private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)),
        }

    def prepare(self, fields):
        if type(fields) is not dict or any(
            type(value) is not str or len(value) > 2048 for value in fields.values()
        ):
            _refuse()
        try:
            key = (
                public_key(json.loads(fields["device_key"]))
                if fields.get("device_key")
                else self.public_identity()
            )
        except (ValueError, TypeError):
            _refuse()
        return {**fields, "device_key": json.dumps(key, separators=(",", ":"))}

    def redemption(self, link):
        payload, challenge = parse_link(link, self.origin, self.owner)
        private = self._device()
        public = {
            "kty": "OKP",
            "crv": "Ed25519",
            "x": _encode(private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)),
        }
        self._proof_key = private
        return {"payload": payload, "signature": _encode(private.sign(challenge))}, public

    def _request_json(self, request, current):
        if not current():
            _refuse()
        with self.opener(request, timeout=15) as response:
            if response.status != 200 or response.geturl() != request.full_url:
                _refuse()
            raw = response.read(65537)
            if len(raw) > 65536 or not current():
                _refuse()
            return json.loads(raw)

    def redeem(self, body, public, *, current=lambda: True):
        request = Request(
            self.origin + "/api/mesh/enrollment/redeem",
            method="POST",
            data=json.dumps(body, separators=(",", ":")).encode(),
            headers={"Content-Type": "application/json", "Cache-Control": "no-store"},
        )
        try:
            result = self._request_json(request, current)
            member = result["member"]
            if (
                result["token_type"] != "DPoP"
                or type(result["access_token"]) is not str
                or not result["access_token"]
                or member["owner_id"] != self.owner
                or public_key(member["device_key"]) != public
                or member["status"] != "active"
                or type(member["member_id"]) is not str
                or not 1 <= len(member["member_id"]) <= 128
                or self._proof_key is None
            ):
                _refuse()
            nonce_body = json.dumps(
                {"owner_id": self.owner, "member_id": member["member_id"]}
            ).encode()
            nonce = self._request_json(
                Request(
                    self.origin + "/api/mesh/nonce",
                    method="POST",
                    data=nonce_body,
                    headers={"Content-Type": "application/json", "Cache-Control": "no-store"},
                ),
                current,
            )["nonce"]
            if type(nonce) is not str or re.fullmatch(r"[a-f0-9]{32}\.[A-Za-z0-9_-]{43}", nonce) is None:
                _refuse()
            _decode(nonce[33:], 32)
            header = {"typ": "dpop+jwt", "alg": "EdDSA", "jwk": public}
            claims = {
                "jti": uuid.uuid4().hex,
                "htm": "GET",
                "htu": self.origin + "/api/mesh/me",
                "iat": int(time.time()),
                "nonce": nonce,
                "ath": _encode(hashlib.sha256(result["access_token"].encode()).digest()),
            }
            signed = (
                _encode(json.dumps(header, sort_keys=True, separators=(",", ":")).encode())
                + "."
                + _encode(json.dumps(claims, sort_keys=True, separators=(",", ":")).encode())
            )
            proof = signed + "." + _encode(self._proof_key.sign(signed.encode()))
            verified = self._request_json(
                Request(
                    self.origin + "/api/mesh/me",
                    headers={
                        "Authorization": "DPoP " + result["access_token"],
                        "DPoP": proof,
                        "DPoP-Nonce": nonce,
                        "Cache-Control": "no-store",
                    },
                ),
                current,
            )["member"]
            if (
                verified["owner_id"] != self.owner
                or verified["member_id"] != member["member_id"]
                or public_key(verified["device_key"]) != public
                or verified["status"] != "active"
            ):
                _refuse()
            return {"owner_id": self.owner, "member_id": member["member_id"], "device_key": public}
        except Exception:
            _refuse()
        finally:
            self._proof_key = None

    def save_member(self, member):
        self._sync()
        self.settings.setValue(self.scope + "/member", json.dumps(member, separators=(",", ":")))
        self._sync()
        if self.settings.value(self.scope + "/member", "", type=str) != json.dumps(
            member, separators=(",", ":")
        ):
            _refuse()

    def purge(self):
        self._proof_key = None
        self.settings.remove(self.scope)
        self.settings.remove(self.scope + "/member")
        self.settings.sync()
