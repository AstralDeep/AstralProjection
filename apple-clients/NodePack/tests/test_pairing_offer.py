"""Checks the pure helpers, the verdict logic and the request driver of the no-sign-in pairing qualification."""

import hashlib
import json
import tarfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pairing_offer as po
import pytest


def reply(status: int, **body) -> dict:
    return {"status": status, "body": body, "cache": "no-store"}


def good_observation() -> dict:
    refused = reply(401, detail="node.pairing_secret_required")
    return {
        "descriptor": reply(200, format=po.DESCRIPTOR_FORMAT, capabilities=["chat", "mesh-peer"], mesh={"state": "not_enrolled"}),
        "no_auth": reply(401), "forged_bearer": reply(401),
        "no_secret": refused, "wrong_secret": refused, "replay": refused,
        "forwarded": reply(403, detail="node.loopback_required"),
        "offer": reply(200, state="offer", code="123-456-789", payload="payload-1"),
        "secret_rotated": True, "secret_mode_private": True, "secret": "s",
    }


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
    report = po.evaluate(good_observation(), True)
    assert report.exit_code == 0
    assert report.lines()[-1] == f"RESULT {len(report.checks)} passed, 0 failed of {len(report.checks)}"


@pytest.mark.parametrize("mutate", [
    lambda o: o["descriptor"]["body"].update(format="astral.node.descriptor/v1"),
    lambda o: o["descriptor"]["body"].update(capabilities=["chat"]),
    lambda o: o["descriptor"]["body"].update(issuer="https://iam.example"),
    lambda o: o["no_auth"].update(status=200),
    lambda o: o["forged_bearer"].update(status=200),
    lambda o: o.update(no_secret=reply(200, state="offer")),
    lambda o: o.update(wrong_secret=reply(401, detail="other")),
    lambda o: o.update(forwarded=reply(200, state="offer")),
    lambda o: o.update(replay=reply(200, state="offer")),
    lambda o: o["offer"].update(status=500),
    lambda o: o["offer"]["body"].update(payload=""),
    lambda o: o["offer"].update(cache=""),
    lambda o: o.update(secret_rotated=False),
    lambda o: o.update(secret_mode_private=False),
])
def test_any_observation_mismatch_fails(mutate):
    observed = good_observation()
    mutate(observed)
    assert po.evaluate(observed, True).exit_code == 1


def test_a_logged_secret_fails_and_an_empty_report_never_passes():
    assert po.evaluate(good_observation(), False).exit_code == 1
    assert po.Report().exit_code == 1


def test_env_helpers_keep_existing_values_and_find_secrets():
    merged = po.merge_env("A=1\nB=2", {"B": "3", "C": "4"})
    assert merged == "A=1\nB=2\nC=4\n"
    assert po.merge_env("", {"X": "1"}) == "X=1\n"
    values = po.parse_env_text("# note\nWEB_SESSION_ENC_KEY='abcdef123456'\nAGENT_API_KEY=xy\nPLAIN=value-long-enough\nbad line")
    assert values["WEB_SESSION_ENC_KEY"] == "abcdef123456"
    secrets = po.secret_values(values)
    assert secrets == ["abcdef123456"]
    assert po.contains_secret("log abcdef123456", secrets) and not po.contains_secret("log clean", secrets)


def test_installed_pack_is_used_in_place_and_an_archive_folder_is_verified_and_unpacked(tmp_path):
    folder = make_pack_folder(tmp_path)
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    root = po.resolve_pack(folder, scratch)
    assert po.is_installed_pack(root)
    assert po.resolve_pack(root, tmp_path) == root


def test_a_tampered_missing_or_foreign_pack_is_refused(tmp_path):
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    with pytest.raises(po.PackError, match="SHA-256"):
        po.resolve_pack(make_pack_folder(tmp_path / "a", tamper=True), scratch)
    sized = make_pack_folder(tmp_path / "b")
    descriptor = json.loads((sized / "node-pack.json").read_text())
    descriptor["archive"]["size"] += 1
    (sized / "node-pack.json").write_text(json.dumps(descriptor))
    with pytest.raises(po.PackError, match="size"):
        po.resolve_pack(sized, scratch)
    (sized / "pack.tar.gz").unlink()
    with pytest.raises(po.PackError, match="missing"):
        po.resolve_pack(sized, scratch)
    with pytest.raises(po.PackError, match="neither"):
        po.resolve_pack(tmp_path / "nothing", scratch)
    empty = tmp_path / "empty"
    empty.mkdir()
    with tarfile.open(empty / "x.tar.gz", "w:gz") as bundle:
        bundle.add(empty, arcname="other")
    digest = hashlib.sha256((empty / "x.tar.gz").read_bytes()).hexdigest()
    size = (empty / "x.tar.gz").stat().st_size
    (empty / "node-pack.json").write_text(json.dumps({"archive": {"file": "x.tar.gz", "size": size, "sha256": digest}}))
    with pytest.raises(po.PackError, match="not a node pack"):
        po.resolve_pack(empty, tmp_path / "scratch2")


def test_the_secret_helpers_read_a_private_file_and_tolerate_none(tmp_path):
    assert po.read_secret(tmp_path) == ""
    (tmp_path / po.SECRET_FILE).write_text("abc\n")
    (tmp_path / po.SECRET_FILE).chmod(0o600)
    tmp_path.chmod(0o700)
    assert po.read_secret(tmp_path) == "abc"
    assert po.private_mode(tmp_path / po.SECRET_FILE, 0o600) and po.private_mode(tmp_path, 0o700)
    (tmp_path / po.SECRET_FILE).chmod(0o644)
    assert not po.private_mode(tmp_path / po.SECRET_FILE, 0o600)
    assert not po.private_mode(tmp_path / "missing", 0o600)


def test_the_driver_sends_no_authorization_with_the_offer_and_reads_the_rotated_secret(tmp_path):
    seen: list[dict] = []
    data = tmp_path / "data"
    data.mkdir(mode=0o700)
    secret = data / po.SECRET_FILE
    secret.write_text("one")
    secret.chmod(0o600)

    class Handler(BaseHTTPRequestHandler):
        def _answer(self, status: int, body: dict) -> None:
            payload = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("cache-control", "no-store")
            self.send_header("content-length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            seen.append({"path": self.path, "auth": self.headers.get("Authorization")})
            if self.path == "/api/node/descriptor":
                self._answer(200, {"format": po.DESCRIPTOR_FORMAT, "capabilities": ["mesh-peer"]})
            else:
                self._answer(401, {"detail": "unauthorized"})

        def do_POST(self):
            given = self.headers.get(po.SECRET_HEADER)
            seen.append({"path": self.path, "secret": given, "auth": self.headers.get("Authorization")})
            if self.headers.get("X-Forwarded-For"):
                self._answer(403, {"detail": "node.loopback_required"})
            elif given != secret.read_text():
                self._answer(401, {"detail": "node.pairing_secret_required"})
            else:
                secret.write_text("two")
                self._answer(200, {"state": "offer", "code": "1", "payload": "p"})

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        observed = po.drive(f"http://127.0.0.1:{server.server_address[1]}", data)
    finally:
        server.shutdown()
    assert po.evaluate(observed, True).exit_code == 0
    posts = [entry for entry in seen if "secret" in entry]
    assert all(entry["auth"] is None for entry in posts)
    assert observed["offer"]["body"]["payload"] == "p" and observed["secret"] == "one"


def test_sha256_file_hashes_in_blocks_and_ports_are_free(tmp_path):
    path = tmp_path / "f"
    path.write_bytes(b"abc" * 1000)
    assert po.sha256_file(path) == hashlib.sha256(b"abc" * 1000).hexdigest()
    assert 0 < po.free_port() < 65536
    assert po.leftover_processes("no-such-process-marker-2f9c1b") == []


def test_main_requires_a_pack_and_fails_cleanly_on_a_bad_one(tmp_path, capsys):
    with pytest.raises(SystemExit):
        po.main([])
    assert po.main(["--pack", str(tmp_path)]) == 1
    assert "FAIL setup" in capsys.readouterr().out
