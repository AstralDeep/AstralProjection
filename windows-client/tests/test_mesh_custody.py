"""Checks local device identity, exact wire signing and fail-closed mesh responses.
Synthetic protection tests isolate custody behavior; the hosted Windows case checks
real DPAPI without relaxing platform or device ownership gates.
"""

import base64
import hashlib
import json
import sys
from contextlib import contextmanager

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from astral_client.mesh import (
    MeshCustodyError,
    MeshDeviceCustody,
    WindowsProtection,
    parse_link,
    public_key,
)


class Settings:
    def __init__(self):
        self.values = {}
        self.error = 0

    def value(self, name, default, **_):
        return self.values.get(name, default)

    def setValue(self, name, value):
        self.values[name] = value

    def sync(self):
        pass

    def status(self):
        return self.error

    def remove(self, name):
        self.values.pop(name, None)


class Protection:
    def transform(self, raw, *, decrypt=False):
        if decrypt:
            assert raw.startswith(b"protected-")
            return bytes(value ^ 0x37 for value in raw[len(b"protected-") :])
        return b"protected-" + bytes(value ^ 0x37 for value in raw)


def encoded(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


SERVER_NONCE = "0123456789abcdef0123456789abcdef." + encoded(bytes([7]) * 32)


def grant(owner="owner"):
    challenge = bytes(range(32))
    payload = encoded(
        json.dumps(
            {
                "v": 1,
                "o": owner,
                "i": "abc123",
                "t": encoded(bytes([9]) * 32),
                "c": encoded(challenge),
            },
            separators=(",", ":"),
        ).encode()
    )
    return "https://mesh.example/enroll#" + payload, challenge


def custody(settings=None, **kwargs):
    return MeshDeviceCustody(
        "https://mesh.example",
        ("https://iam.example/realm", "owner"),
        settings or Settings(),
        protection=Protection(),
        **kwargs,
    )


def test_key_persists_protected_and_challenge_is_exact():
    settings = Settings()
    device = custody(settings)
    public = device.public_identity()
    assert custody(settings).public_identity() == public
    body, signed_public = device.redemption(grant()[0])
    assert signed_public == public
    Ed25519PublicKey.from_public_bytes(base64.urlsafe_b64decode(public["x"] + "=")).verify(
        base64.urlsafe_b64decode(body["signature"] + "=="), grant()[1]
    )
    assert len(body["signature"]) == 86
    assert set(body) == {"payload", "signature"}
    assert "private" not in json.dumps(settings.values)
    assert "payload" not in json.dumps(settings.values)
    device.purge()
    assert settings.values == {}
    with pytest.raises(MeshCustodyError):
        device.redemption(grant()[0])


@pytest.mark.parametrize("phase", ["initial", "key_write", "member_write"])
def test_cached_values_never_hide_a_durable_settings_failure(phase):
    settings = Settings()
    device = custody(settings)
    if phase == "initial":
        settings.error = 1
    elif phase == "member_write":
        device.public_identity()

    def failed_sync():
        settings.error = 1

    settings.sync = failed_sync
    with pytest.raises(MeshCustodyError):
        if phase == "member_write":
            device.save_member({"owner_id": "owner", "member_id": "member1"})
        else:
            device.public_identity()
    with pytest.raises(MeshCustodyError):
        device.public_identity()


def test_retired_context_never_sends_a_redemption_or_keeps_a_proof_key():
    device = custody()
    device.public_identity()
    body, public = device.redemption(grant()[0])
    requests = []

    def opener(request, timeout):
        requests.append(request)
        raise AssertionError("Retired request crossed the HTTP boundary")

    device.opener = opener
    with pytest.raises(MeshCustodyError):
        device.redeem(body, public, current=lambda: False)
    assert requests == [] and device._proof_key is None


@pytest.mark.parametrize("phase", ["redemption", "nonce"])
def test_response_retirement_refuses_before_nonce_or_member_persistence(phase):
    device = custody()
    device.public_identity()
    body, public = device.redemption(grant()[0])
    current = [True]
    requests = []
    result = {"token_type": "DPoP", "access_token": "ephemeral-synthetic", "member": {
        "owner_id": "owner", "member_id": "member1", "device_key": public, "status": "active",
    }}

    class Reply:
        status = 200

        def __init__(self, request):
            self.request = request

        def geturl(self):
            return self.request.full_url

        def read(self, _):
            if self.request.full_url.endswith("/redeem" if phase == "redemption" else "/nonce"):
                current[0] = False
            return json.dumps({"nonce": SERVER_NONCE} if self.request.full_url.endswith("/nonce") else result).encode()

    @contextmanager
    def opener(request, timeout):
        requests.append(request.full_url)
        yield Reply(request)

    device.opener = opener
    with pytest.raises(MeshCustodyError):
        device.redeem(body, public, current=lambda: current[0])
    expected = ["https://mesh.example/api/mesh/enrollment/redeem"]
    if phase == "nonce":
        expected.append("https://mesh.example/api/mesh/nonce")
    assert requests == expected
    assert device._proof_key is None
    assert device.settings.value(device.scope + "/member", "") == ""


def test_distinct_devices_and_server_account_scopes():
    first = custody()
    second = custody()
    assert first.public_identity() != second.public_identity()
    settings = Settings()
    assert (
        custody(settings).scope
        != MeshDeviceCustody(
            "https://other.example",
            ("https://iam.example/realm", "owner"),
            settings,
            protection=Protection(),
        ).scope
    )
    assert (
        custody(settings).scope
        != MeshDeviceCustody(
            "https://mesh.example",
            ("https://iam.example/realm", "other"),
            settings,
            protection=Protection(),
        ).scope
    )
    with pytest.raises(MeshCustodyError):
        custody().redemption(grant()[0])


@pytest.mark.parametrize(
    "link",
    [
        "https://foreign.example/enroll#abc",
        "https://mesh.example/other#abc",
        "https://mesh.example/enroll?secret=bad#abc",
        "https://mesh.example/enroll#%%%",
        "",
        None,
    ],
)
def test_invalid_links_refused(link):
    with pytest.raises(MeshCustodyError):
        parse_link(link, "https://mesh.example", "owner")


def test_wrong_owner_and_private_identity_refused():
    with pytest.raises(MeshCustodyError):
        custody().redemption(grant("other")[0])
    valid = custody().public_identity()
    assert public_key(valid) == valid
    for raw in [
        {**valid, "d": "private"},
        {**valid, "x": valid["x"] + "="},
        {**valid, "crv": "P-256"},
    ]:
        with pytest.raises(MeshCustodyError):
            public_key(raw)
    assert custody().prepare({"device_key": json.dumps(valid)})["device_key"]


def test_response_requires_exact_owner_and_local_key():
    device = custody()
    public = device.public_identity()
    body, _ = device.redemption(grant()[0])
    result = {
        "token_type": "DPoP",
        "access_token": "ephemeral-synthetic",
        "member": {
            "owner_id": "owner",
            "member_id": "member1",
            "device_key": public,
            "status": "active",
        },
    }

    class Reply:
        status = 200

        def __init__(self, request):
            self.request = request

        def geturl(self):
            return self.request.full_url

        def read(self, _):
            if self.request.full_url.endswith("/nonce"):
                return json.dumps({"nonce": SERVER_NONCE}).encode()
            if self.request.full_url.endswith("/me"):
                return json.dumps({"member": result["member"]}).encode()
            return json.dumps(result).encode()

    @contextmanager
    def opener(request, timeout):
        assert timeout == 15
        assert "Cookie" not in request.headers
        if request.full_url.endswith("/me"):
            assert request.get_method() == "GET"
            assert request.headers["Authorization"] == "DPoP ephemeral-synthetic"
            parts = request.headers["Dpop"].split(".")
            fields = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
            assert fields["htu"] == "https://mesh.example/api/mesh/me" and fields["htm"] == "GET"
            assert fields["nonce"] == request.headers["Dpop-nonce"] == SERVER_NONCE
            assert fields["ath"] == encoded(hashlib.sha256(b"ephemeral-synthetic").digest())
            Ed25519PublicKey.from_public_bytes(base64.urlsafe_b64decode(public["x"] + "=")).verify(
                base64.urlsafe_b64decode(parts[2] + "=="), (parts[0] + "." + parts[1]).encode()
            )
        else:
            assert request.get_method() == "POST"
            assert "Authorization" not in request.headers
        yield Reply(request)

    device.opener = opener
    member = device.redeem(body, public)
    device.save_member(member)
    assert "ephemeral-synthetic" not in json.dumps(device.settings.values)
    for mutate in [
        lambda: result.update(token_type="Bearer"),
        lambda: result["member"].update(owner_id="foreign"),
        lambda: result["member"].update(device_key=custody().public_identity()),
        lambda: result["member"].update(status="revoked"),
    ]:
        mutate()
        with pytest.raises(MeshCustodyError):
            device.redeem(body, public)
        result["token_type"] = "DPoP"
        result["member"] = {
            "owner_id": "owner",
            "member_id": "member1",
            "device_key": public,
            "status": "active",
        }


@pytest.mark.parametrize("nonce", [
    None, 3, "", encoded(bytes([7]) * 32),
    "g" * 32 + SERVER_NONCE[32:], SERVER_NONCE + "=", SERVER_NONCE + "\n",
    SERVER_NONCE[:-1] + "B", "a" * 257, SERVER_NONCE.replace(".", ".."),
])
def test_invalid_server_nonce_never_sends_a_member_proof_or_persists(nonce):
    device = custody()
    public = device.public_identity()
    body, _ = device.redemption(grant()[0])
    requests = []
    result = {"token_type": "DPoP", "access_token": "ephemeral-synthetic", "member": {
        "owner_id": "owner", "member_id": "member1", "device_key": public, "status": "active",
    }}

    class Reply:
        status = 200

        def __init__(self, request):
            self.request = request

        def geturl(self):
            return self.request.full_url

        def read(self, _):
            return json.dumps({"nonce": nonce} if self.request.full_url.endswith("/nonce") else result).encode()

    @contextmanager
    def opener(request, timeout):
        requests.append(request.full_url)
        yield Reply(request)

    device.opener = opener
    with pytest.raises(MeshCustodyError):
        device.redeem(body, public)
    assert requests == ["https://mesh.example/api/mesh/enrollment/redeem", "https://mesh.example/api/mesh/nonce"]
    assert device._proof_key is None and device.settings.value(device.scope + "/member", "") == ""


def test_unsupported_platform_never_persists_plaintext(monkeypatch):
    monkeypatch.setattr(sys, "platform", "darwin")
    with pytest.raises(MeshCustodyError):
        WindowsProtection().transform(b"synthetic-private")
    settings = Settings()
    with pytest.raises(MeshCustodyError):
        MeshDeviceCustody("https://mesh.example", ("issuer", "owner"), settings).public_identity()
    assert settings.values == {}


@pytest.mark.skipif(sys.platform != "win32", reason="DPAPI is exercised on hosted Windows")
def test_real_dpapi_roundtrip_and_tamper_refusal():
    protection = WindowsProtection()
    original = bytes(range(32))
    protected = protection.transform(original)
    assert protected != original
    assert protection.transform(protected, decrypt=True) == original
    with pytest.raises(MeshCustodyError):
        protection.transform(protected[:-1] + bytes([protected[-1] ^ 1]), decrypt=True)


@pytest.mark.parametrize(
    "origin,account",
    [
        ("http://remote.example", ("issuer", "owner")),
        ("https://user:secret@mesh.example", ("issuer", "owner")),
        ("https://mesh.example/path", ("issuer", "owner")),
        ("https://mesh.example:bad", ("issuer", "owner")),
        ("https://mesh.example", None),
        ("https://mesh.example", ("issuer", "")),
    ],
)
def test_invalid_origin_or_account_refused(origin, account):
    with pytest.raises(MeshCustodyError):
        MeshDeviceCustody(origin, account, Settings(), protection=Protection())


@pytest.mark.parametrize(
    "fields", [None, {"device_key": 3}, {"label": "x" * 2049}, {"device_key": "{"}]
)
def test_invalid_local_form_refused(fields):
    with pytest.raises(MeshCustodyError):
        custody().prepare(fields)


def test_storage_failure_and_corrupt_custody_refused():
    class Broken(Settings):
        def setValue(self, name, value):
            pass

    with pytest.raises(MeshCustodyError):
        custody(Broken()).public_identity()
    device = custody()
    device.settings.setValue(device.scope, encoded(b"protected-short"))
    with pytest.raises(MeshCustodyError):
        device.public_identity()
    with pytest.raises(MeshCustodyError):
        MeshDeviceCustody(
            "https://mesh.example", ("issuer", "owner"), Broken(), protection=Protection()
        ).save_member({"member_id": "synthetic"})


def test_network_failure_redirect_and_oversized_response_refused():
    from astral_client.mesh import _NoRedirect

    with pytest.raises(MeshCustodyError):
        _NoRedirect().redirect_request(None, None, 302, "redirect", {}, "https://foreign.example")
    device = custody()
    public = device.public_identity()
    body, _ = device.redemption(grant()[0])

    class Reply:
        status = 200

        def geturl(self):
            return "https://mesh.example/api/mesh/enrollment/redeem"

        def read(self, _):
            return b"x" * 65537

    @contextmanager
    def opener(*args, **kwargs):
        yield Reply()

    device.opener = opener
    with pytest.raises(MeshCustodyError):
        device.redeem(body, public)
    Reply.status = 403
    with pytest.raises(MeshCustodyError):
        device.redeem(body, public)


def test_dpapi_ffi_keeps_user_scope_and_releases_output(monkeypatch):
    import ctypes
    from types import SimpleNamespace

    monkeypatch.setattr(sys, "platform", "win32")
    allocated, freed, flags = [], [], []

    class Operation:
        fails = False

        def __call__(self, incoming, description, entropy, reserved, prompt, flag, outgoing):
            assert description is entropy is reserved is prompt is None
            assert ctypes.string_at(incoming._obj.data, incoming._obj.size) == b"synthetic"
            flags.append(flag)
            if self.fails:
                return 0
            raw = ctypes.create_string_buffer(b"protected-output")
            allocated.append(raw)
            outgoing._obj.size = 16
            outgoing._obj.data = ctypes.cast(raw, ctypes.c_void_p)
            return 1

    operation = Operation()

    class Free:
        def __call__(self, pointer):
            freed.append(pointer)

    library = SimpleNamespace(CryptProtectData=operation, CryptUnprotectData=operation)
    kernel = SimpleNamespace(LocalFree=Free())
    monkeypatch.setattr(
        ctypes, "WinDLL", lambda name, **_: library if name == "crypt32" else kernel, raising=False
    )
    assert WindowsProtection().transform(b"synthetic") == b"protected-output"
    assert WindowsProtection().transform(b"synthetic", decrypt=True) == b"protected-output"
    assert flags == [1, 1]
    assert len(freed) == len(allocated) == 2
    operation.fails = True
    with pytest.raises(MeshCustodyError):
        WindowsProtection().transform(b"synthetic")
    assert len(freed) == 2
