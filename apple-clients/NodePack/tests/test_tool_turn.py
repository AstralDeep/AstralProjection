"""Checks the pure helpers, the verdict logic and the model fixture of the tool-turn qualification driver."""

import hashlib
import json
import tarfile
import threading
import urllib.request
from pathlib import Path

import pytest
import tool_turn as tt


def good_observation() -> dict:

    def message(role: str, text: str) -> dict:
        return {"role": role, "text": text}

    return {
        "statuses": {"missing": 401, "forged": 401, "owner": 200},
        "registered": True, "provider_saved": True, "final_state": "completed", "chart_frame": "ui_upsert",
        "history": [message("user", "chart"), message("assistant", f"{tt.CHART_TITLE} {tt.FINAL_TEXT}")],
    }


def good_requests() -> list[dict]:
    return [{"roles": ["system", "user"], "tools": ["general-1_" + tt.TOOL, "other"]},
            {"roles": ["system", "user", "assistant", "tool"], "tools": ["general-1_" + tt.TOOL]}]


def make_pack_folder(tmp_path: Path, tamper: bool = False) -> Path:
    tree = tmp_path / "tree"
    (tree / "python/bin").mkdir(parents=True)
    (tree / "launcher").mkdir()
    (tree / "python/bin/python3.11").write_text("")
    (tree / "launcher/astral_node_launch.py").write_text("")
    folder = tmp_path / "pack"
    folder.mkdir()
    archive = folder / "pack.tar.gz"
    with tarfile.open(archive, "w:gz") as bundle:
        bundle.add(tree / "python", arcname="python")
        bundle.add(tree / "launcher", arcname="launcher")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    descriptor = {"archive": {"file": "pack.tar.gz", "size": archive.stat().st_size, "sha256": "0" * 64 if tamper else digest}}
    (folder / "node-pack.json").write_text(json.dumps(descriptor))
    return folder


def test_every_check_passing_gives_exit_zero_and_a_summary():
    report = tt.evaluate(good_observation(), good_requests(), True, True)
    assert report.exit_code == 0
    assert report.lines()[-1] == f"RESULT {len(report.checks)} passed, 0 failed of {len(report.checks)}"


@pytest.mark.parametrize("mutate", [
    lambda o: o["statuses"].update(missing=200),
    lambda o: o["statuses"].update(forged=200),
    lambda o: o["statuses"].update(owner=401),
    lambda o: o.update(registered=False),
    lambda o: o.update(provider_saved=False),
    lambda o: o.update(final_state="failed"),
    lambda o: o.update(chart_frame=None),
    lambda o: o.update(history=[]),
    lambda o: o["history"].pop(),
])
def test_any_observation_mismatch_fails(mutate):
    observed = good_observation()
    mutate(observed)
    report = tt.evaluate(observed, good_requests(), True, True)
    assert report.exit_code == 1 and report.failed


def test_request_disk_and_log_mismatches_fail():
    no_tools = [{"roles": ["user"], "tools": []}]
    assert tt.evaluate(good_observation(), no_tools, True, True).exit_code == 1
    wrong_tool = [{"roles": ["user"], "tools": ["other"]}, {"roles": ["tool"], "tools": []}]
    assert tt.evaluate(good_observation(), wrong_tool, True, True).exit_code == 1
    no_result = [good_requests()[0]]
    assert tt.evaluate(good_observation(), no_result, True, True).exit_code == 1
    assert tt.evaluate(good_observation(), good_requests(), False, True).exit_code == 1
    assert tt.evaluate(good_observation(), good_requests(), True, False).exit_code == 1


def test_an_empty_report_never_passes():
    assert tt.Report().exit_code == 1


def test_tool_offer_uses_the_largest_listing():
    assert tt.tool_offer([]) == (0, False)
    assert tt.tool_offer(good_requests()) == (2, True)


def test_env_helpers_keep_existing_values_and_find_secrets():
    merged = tt.merge_env("A=1\nB=2", {"B": "3", "C": "4"})
    assert merged == "A=1\nB=2\nC=4\n"
    assert tt.merge_env("", {"X": "1"}) == "X=1\n"
    values = tt.parse_env_text("# note\nWEB_SESSION_ENC_KEY='abcdef123456'\nAGENT_API_KEY=xy\nPLAIN=value-long-enough\nbad line")
    assert values["WEB_SESSION_ENC_KEY"] == "abcdef123456"
    secrets = tt.secret_values(values)
    assert secrets == ["abcdef123456"]
    assert tt.contains_secret("log abcdef123456", secrets) and not tt.contains_secret("log clean", secrets)


def test_collect_types_walks_nested_structures():
    assert tt.collect_types({"type": "a", "x": [{"type": "b"}, {"y": {"type": "c"}}], "z": 1}) == {"a", "b", "c"}


def test_installed_pack_is_used_in_place_and_an_archive_folder_is_verified_and_unpacked(tmp_path):
    folder = make_pack_folder(tmp_path)
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    root = tt.resolve_pack(folder, scratch)
    assert tt.is_installed_pack(root)
    assert tt.resolve_pack(root, tmp_path) == root


def test_a_tampered_missing_or_foreign_pack_is_refused(tmp_path):
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    with pytest.raises(tt.PackError, match="SHA-256"):
        tt.resolve_pack(make_pack_folder(tmp_path / "a", tamper=True), scratch)
    sized = make_pack_folder(tmp_path / "b")
    descriptor = json.loads((sized / "node-pack.json").read_text())
    descriptor["archive"]["size"] += 1
    (sized / "node-pack.json").write_text(json.dumps(descriptor))
    with pytest.raises(tt.PackError, match="size"):
        tt.resolve_pack(sized, scratch)
    (sized / "pack.tar.gz").unlink()
    with pytest.raises(tt.PackError, match="missing"):
        tt.resolve_pack(sized, scratch)
    with pytest.raises(tt.PackError, match="neither"):
        tt.resolve_pack(tmp_path / "nothing", scratch)
    empty = tmp_path / "empty"
    empty.mkdir()
    with tarfile.open(empty / "x.tar.gz", "w:gz") as bundle:
        bundle.add(empty, arcname="other")
    digest = hashlib.sha256((empty / "x.tar.gz").read_bytes()).hexdigest()
    size = (empty / "x.tar.gz").stat().st_size
    (empty / "node-pack.json").write_text(json.dumps({"archive": {"file": "x.tar.gz", "size": size, "sha256": digest}}))
    with pytest.raises(tt.PackError, match="not a node pack"):
        tt.resolve_pack(empty, tmp_path / "scratch2")


def test_model_replies_call_the_tool_once_then_answer():
    tools = [{"function": {"name": "agent_" + tt.TOOL}}, {"function": {"name": "other"}}]
    first = tt.model_reply({"messages": [{"role": "user"}], "tools": tools})
    assert first["finish"] == "tool_calls"
    assert json.loads(first["tool_calls"][0]["function"]["arguments"])["title"] == tt.CHART_TITLE
    second = tt.model_reply({"messages": [{"role": "user"}, {"role": "tool"}], "tools": tools})
    assert second["finish"] == "stop" and tt.FINAL_TEXT in second["content"]
    assert tt.model_reply({"messages": [], "tools": tools, "tool_choice": "none"})["finish"] == "stop"
    assert tt.model_reply({"messages": [], "tools": []})["content"] == tt.FINAL_TEXT
    assert tt.model_tool_args({"function": {"name": "other"}}) == {}


def test_model_fixture_serves_models_and_journals_each_completion(tmp_path):
    ready, ports = threading.Event(), {}
    threading.Thread(target=tt.run_model, args=(tmp_path, ready, ports), daemon=True).start()
    assert ready.wait(10)
    base = f"http://127.0.0.1:{ports['model']}"
    with urllib.request.urlopen(base + "/v1/models") as response:
        assert json.load(response)["data"][0]["id"] == "fixture-model"
    tools = [{"function": {"name": "a_" + tt.TOOL}}]

    def post(stream: bool) -> bytes:
        body = json.dumps({"messages": [{"role": "user"}], "tools": tools, "stream": stream}).encode()
        request = urllib.request.Request(base + "/v1/chat/completions", body, {"content-type": "application/json"})
        with urllib.request.urlopen(request) as response:
            return response.read()

    assert json.loads(post(False))["choices"][0]["finish_reason"] == "tool_calls"
    assert b"[DONE]" in post(True)
    lines = (tmp_path / "model-requests.jsonl").read_text().splitlines()
    assert json.loads(lines[0]) == {"roles": ["user"], "tools": ["a_" + tt.TOOL]}


def test_minted_tokens_verify_against_their_own_key_only():
    rsa = pytest.importorskip("cryptography.hazmat.primitives.asymmetric.rsa")
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import padding

    key, other = (rsa.generate_private_key(public_exponent=65537, key_size=2048) for _ in range(2))
    head, claims, signature = tt.mint(key, "kid-1", "http://127.0.0.1:1/realms/astral", "owner-1").split(".")
    raw = tt.base64.urlsafe_b64decode(signature + "=" * (-len(signature) % 4))
    key.public_key().verify(raw, f"{head}.{claims}".encode(), padding.PKCS1v15(), hashes.SHA256())
    with pytest.raises(InvalidSignature):
        other.public_key().verify(raw, f"{head}.{claims}".encode(), padding.PKCS1v15(), hashes.SHA256())
    assert json.loads(tt.base64.urlsafe_b64decode(claims + "=" * (-len(claims) % 4)))["sub"] == "owner-1"


def test_sha256_file_hashes_in_blocks_and_ports_are_free(tmp_path):
    path = tmp_path / "f"
    path.write_bytes(b"abc" * 1000)
    assert tt.sha256_file(path) == hashlib.sha256(b"abc" * 1000).hexdigest()
    assert 0 < tt.free_port() < 65536
    assert tt.disk_has_marker(tmp_path, "abc") is False
    (tmp_path / "plane.sqlite3-wal").write_bytes(b"xx marker yy")
    assert tt.disk_has_marker(tmp_path, "marker") is True
    assert tt.leftover_processes("no-such-process-marker-2f9c1b") == []


def test_main_requires_a_pack_and_fails_cleanly_on_a_bad_one(tmp_path, capsys):
    with pytest.raises(SystemExit):
        tt.main([])
    assert tt.main(["--pack", str(tmp_path)]) == 1
    assert "FAIL setup" in capsys.readouterr().out
