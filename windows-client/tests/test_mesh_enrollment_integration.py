"""Exercises mesh enrollment through the real window and surface lifecycle.
Synthetic custody isolates OS/network boundaries while current owner and transport
fences decide whether a queued response can persist or display success.
"""

import json
import uuid

import pytest
from PySide6.QtWidgets import QApplication

from astral_client import app as appmod
from astral_client.mesh import MeshCustodyError

pytest_plugins = ["test_auth_refresh_integration"]


class Custody:
    def __init__(self):
        self.public = {"kty": "OKP", "crv": "Ed25519", "x": "synthetic-public"}
        self.member = {"owner_id": "alice", "member_id": "member1", "device_key": self.public}
        self.saved = []
        self.calls = []
        self.failure = None

    def public_identity(self):
        if self.failure == "key":
            raise MeshCustodyError()
        return self.public

    def prepare(self, fields):
        return {**fields, "device_key": json.dumps(self.public)}

    def redemption(self, link):
        self.calls.append(("sign", link))
        return {"payload": "synthetic", "signature": "synthetic"}, self.public

    def redeem(self, body, public, *, current=lambda: True):
        if self.failure == "network" or not current():
            raise MeshCustodyError()
        self.calls.append(("redeem", body, public))
        return self.member

    def save_member(self, member):
        if self.failure == "save":
            raise MeshCustodyError()
        self.saved.append(member)

    def purge(self):
        self.calls.append(("purge",))


@pytest.fixture
def mesh_window(win, native_root, monkeypatch):
    dialog = native_root(appmod.SurfaceDialog, win, win._emit, win._download)
    dialog.begin_load("mesh", {}, "Mesh devices")
    dialog.show()
    win._surface_dialog = dialog
    win._surface_owner = (win.client, win.client.connection_generation, win._resume_store.storage_key)
    device = Custody()
    win._mesh_custody = device
    notices = []
    monkeypatch.setattr(win, "_show_banner", lambda *args: notices.append(args))
    monkeypatch.setattr(appmod.QMessageBox, "information", lambda *_: None)
    return win, device, notices


def test_public_identity_never_transmits_a_grant_or_private_key(mesh_window):
    window, device, notices = mesh_window
    prior = list(window.client.events)
    window._emit("chrome_mesh_identity", {})
    assert json.loads(QApplication.clipboard().text()) == device.public
    assert window.client.events == prior and not device.saved and not notices


def test_create_uses_current_shared_transport_and_preserves_non_key_fields(mesh_window, monkeypatch):
    window, device, _ = mesh_window
    submitted = []
    monkeypatch.setattr(window, "_send_settings", lambda action, body: submitted.append((action, body)))
    window._emit("chrome_mesh_create", {"surface": "mesh", "fields": {"label": "Tablet", "device_key": ""}})
    assert submitted[0][0] == "chrome_mesh_create"
    assert submitted[0][1]["fields"]["label"] == "Tablet"
    assert json.loads(submitted[0][1]["fields"]["device_key"]) == device.public
    assert not device.saved


def test_redeem_is_single_flight_and_persists_only_verified_current_member(mesh_window, workers, monkeypatch):
    window, device, notices = mesh_window
    reopened = []
    monkeypatch.setattr(window, "_console_open_surface", lambda *args: reopened.append(args))
    window._emit("chrome_mesh_redeem", {"fields": {"link": "synthetic-link"}})
    window._emit("chrome_mesh_redeem", {"fields": {"link": "second-link"}})
    assert len(workers) == 1 and not device.saved
    assert device.calls == [("sign", "synthetic-link")]
    workers.pop()()
    assert device.saved == [device.member]
    assert reopened == [("mesh", "Mesh devices", {})]
    assert notices[-1] == ("This device is enrolled.",)


@pytest.mark.parametrize("transition", ["owner", "transport", "surface", "closed", "timeout", "disconnect"])
def test_pending_redemption_cannot_cross_owner_transport_or_surface(mesh_window, workers, transition):
    window, device, notices = mesh_window
    window._emit("chrome_mesh_redeem", {"fields": {"link": "synthetic-link"}})
    pending = workers.pop()
    if transition == "owner":
        window._invalidate_auth()
    elif transition == "transport":
        window._on_status("reconnecting:1")
        window.client.connection_generation = str(uuid.uuid4())
    elif transition == "surface":
        window._console_open_surface("settings", "Settings", {})
    elif transition == "closed":
        window._surface_closed()
    elif transition == "timeout":
        window._surface_timeout()
    else:
        window._on_status("closed")
    pending()
    assert not device.saved
    assert not any(row[0] == "redeem" for row in device.calls)
    assert all(row[0] != "This device is enrolled." for row in notices)


@pytest.mark.parametrize("failure", ["network", "save"])
def test_failures_never_report_enrollment_success(mesh_window, workers, failure):
    window, device, notices = mesh_window
    device.failure = failure
    window._emit("chrome_mesh_redeem", {"fields": {"link": "synthetic-link"}})
    workers.pop()()
    assert not device.saved and window._mesh_pending is None
    assert notices[-1][1] == "error"


def test_closed_or_foreign_surface_cannot_generate_or_submit_identity(mesh_window):
    window, device, notices = mesh_window
    window._surface_owner = None
    window._emit("chrome_mesh_identity", {})
    assert not device.calls and notices[-1][1] == "error"
    window._surface_owner = (window.client, window.client.connection_generation, window._resume_store.storage_key)
    window._surface_dialog.hide()
    window._emit("chrome_mesh_create", {"fields": {}})
    assert not device.calls and notices[-1][1] == "error"


def test_closed_mesh_dialog_clears_one_time_payload_and_widgets(mesh_window):
    window, _, _ = mesh_window
    dialog = window._surface_dialog
    dialog.set_surface("Mesh devices", [{"type": "text", "content": "synthetic-one-time-link"}])
    assert dialog._surface_payload
    assert dialog._lay.count()
    window._surface_closed()
    assert dialog._surface_payload == []
    assert dialog._lay.count() == 1
    assert dialog._lay.itemAt(0).spacerItem() is not None


def test_key_protection_failure_stays_a_static_denial(mesh_window):
    window, device, notices = mesh_window
    device.failure = "key"
    window._emit("chrome_mesh_identity", {})
    assert not device.saved and notices[-1][1] == "error"
