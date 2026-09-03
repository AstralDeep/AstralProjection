"""Feature 077 — "Agents on this PC" (SC-005).

The person at the PC can see every personal agent hosted here with its derived
status and stop it; the list is read-only otherwise. Pins:

* ``ByoAgentHost.inventory()`` derives online/starting/offline from the live
  children and lists installed-but-stopped bundles from disk with the manifest
  name, never touching a child.
* The dialog renders the inventory, refreshes, enables Stop only for a live
  agent, and Stop goes through the host's own ``stop`` (the same kill the
  server commands).
* The Settings menu carries the client-local entry only when the deployment
  profile hosts personal agents.
"""

import json
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("PySide6")
from PySide6.QtWidgets import QApplication  # noqa: E402

from win_agent import byo_host as bh  # noqa: E402
from astral_client import local_agents  # noqa: E402


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


class _Proc:
    def __init__(self, pid=4242, alive=True):
        self.pid = pid
        self._alive = alive

    def poll(self):
        return None if self._alive else 0


def _host(tmp_path):
    host = bh.ByoAgentHost(send_event=lambda *a: None, notify=lambda *a: None,
                           base_dir=str(tmp_path))
    return host


def _install(tmp_path, agent_id, name):
    d = tmp_path / agent_id
    d.mkdir()
    (d / "agent_main.py").write_text("print('x')")
    (d / "manifest.json").write_text(json.dumps({"name": name}))
    return str(d)


def test_inventory_is_derived_and_read_only(tmp_path):
    host = _host(tmp_path)
    running_dir = _install(tmp_path, "ua-greeter-1", "Greeter")
    stopped_dir = _install(tmp_path, "ua-sorter-2", "Inbox sorter")
    (tmp_path / "ua-broken-3.pending").mkdir()          # staging, never an agent
    child = bh._Child("ua-greeter-1", _Proc(), running_dir)
    child.registered = True
    host._children["ua-greeter-1"] = child
    starting = bh._Child("ua-new-4", _Proc(pid=7), _install(tmp_path, "ua-new-4", "New one"))
    host._children["ua-new-4"] = starting
    rows = host.inventory()
    by_id = {r["agent_id"]: r for r in rows}
    assert set(by_id) == {"ua-greeter-1", "ua-sorter-2", "ua-new-4"}
    assert by_id["ua-greeter-1"] == {"agent_id": "ua-greeter-1", "name": "Greeter", "status": "online",
                                     "pid": 4242, "directory": running_dir, "revision": ""}
    assert by_id["ua-new-4"]["status"] == "starting" and by_id["ua-new-4"]["pid"] == 7
    assert by_id["ua-sorter-2"] == {"agent_id": "ua-sorter-2", "name": "Inbox sorter",
                                    "status": "offline", "pid": None, "directory": stopped_dir,
                                    "revision": ""}
    assert [r["agent_id"] for r in rows][0] == "ua-greeter-1"    # online first
    assert bh._bundle_display_name(str(tmp_path / "nowhere")) == ""


def test_inventory_skips_and_prunes_a_root_whose_revisions_are_gone(tmp_path):
    """Rig finding (2026-09-03): after reconciliation deleted an agent's last
    revision, the empty ``<agent>/revisions`` shell stayed behind and the dialog
    listed it as an installed, offline agent named by its id."""
    host = _host(tmp_path)
    (tmp_path / "ua-ghost-9" / "revisions").mkdir(parents=True)
    kept = tmp_path / "ua-kept-8" / "revisions" / "rev-1"
    kept.mkdir(parents=True)
    (kept / "manifest.json").write_text(json.dumps({"name": "Kept"}))
    legacy = _install(tmp_path, "ua-legacy-7", "Legacy")
    by_id = {r["agent_id"]: r for r in host.inventory()}
    assert set(by_id) == {"ua-kept-8", "ua-legacy-7"}
    assert by_id["ua-kept-8"]["status"] == "offline" and by_id["ua-legacy-7"]["directory"] == legacy
    host._prune_empty_agent_root("ua-ghost-9")
    assert not (tmp_path / "ua-ghost-9").exists()
    host._prune_empty_agent_root("ua-kept-8")          # still holds a revision: untouched
    host._prune_empty_agent_root("ua-legacy-7")        # legacy flat bundle: untouched
    assert kept.is_dir() and os.path.isdir(legacy)
    host._prune_empty_agent_root("ua-absent-0")        # nothing there: no error
    # The host's own inventory pass sweeps ghosts left by earlier deletions —
    # and a root whose only revision it just discarded as partial (the
    # pre-existing corruption rule) becomes one too. Legacy bundles are untouched.
    (tmp_path / "ua-ghost-3" / "revisions").mkdir(parents=True)
    assert host._local_inventory() == []
    assert not (tmp_path / "ua-ghost-3").exists()
    assert not (tmp_path / "ua-kept-8").exists()
    assert os.path.isdir(legacy)


def test_dialog_lists_refreshes_and_stops_through_the_host(qapp, tmp_path):
    host = _host(tmp_path)
    running_dir = _install(tmp_path, "ua-greeter-1", "Greeter")
    proc = _Proc()
    child = bh._Child("ua-greeter-1", proc, running_dir)
    child.registered = True
    host._children["ua-greeter-1"] = child
    stopped = []

    def _stop(agent_id):
        stopped.append(agent_id)
        proc._alive = False
        return True
    host.stop = _stop
    opened = []
    dialog = local_agents.LocalAgentsDialog(host, opener=opened.append)
    assert dialog.table.rowCount() == 1 and dialog.rows()[0]["status"] == "online"
    assert "1 installed · 1 online" in dialog.status.text()
    assert not dialog.stop_btn.isEnabled()                    # nothing selected yet
    dialog.table.selectRow(0)
    assert dialog.stop_btn.isEnabled() and dialog.folder_btn.isEnabled()
    dialog.folder_btn.click()
    assert opened == [running_dir]
    dialog.stop_btn.click()
    assert stopped == ["ua-greeter-1"]
    assert dialog.rows()[0]["status"] == "offline" and "Stopped" in dialog.status.text()
    dialog.table.selectRow(0)
    assert not dialog.stop_btn.isEnabled()                    # already offline
    # a disappearing folder is reported, not raised
    import shutil
    shutil.rmtree(running_dir)
    dialog.folder_btn.click()
    assert "not there" in dialog.status.text()
    assert local_agents.open_folder("") is False


def test_settings_menu_carries_the_local_entry_only_for_a_hosting_profile(qapp):
    from astral_client.app import TopBar
    calls = []
    bar = TopBar("sam", lambda: None, lambda: None, lambda *a: None, lambda: None,
                 local_items=[("Agents on this PC", lambda: calls.append("open"))])
    bar.set_menu_model({"menu": [{"label": "Account", "items": [
        {"label": "My agents & skills", "surface": "agent_authoring"}]}],
        "signout": {"label": "Sign out", "action": "logout"}})
    labels = [a.text() for a in bar._menu.actions() if a.text()]
    assert "Agents on this PC" in labels
    assert labels.index("Agents on this PC") > labels.index("My agents && skills")
    [a for a in bar._menu.actions() if a.text() == "Agents on this PC"][0].trigger()
    assert calls == ["open"]
    plain = TopBar("sam", lambda: None, lambda: None, lambda *a: None, lambda: None)
    plain.set_menu_model({"menu": [], "signout": {"label": "Sign out", "action": "logout"}})
    assert "Agents on this PC" not in [a.text() for a in plain._menu.actions()]
