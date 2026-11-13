"""Checks secret redaction and size rotation of the node log."""

import os
import time

import node_logging as nl


def test_secret_values_come_only_from_secret_looking_names_and_skip_short_values():
    env = {"WEB_SESSION_ENC_KEY": "abcdef123456", "AGENT_API_KEY": "xy", "KEYCLOAK_CLIENT_ID": "astral", "AUDIT_HMAC_SECRET": "hmac-secret-value"}
    assert nl.secret_values(env) == ["hmac-secret-value", "abcdef123456"]


def test_known_values_bearer_tokens_jwts_and_assignments_are_removed():
    secrets = ["abcdef123456"]
    jwt = "eyJhbGciOiJFZERTQSJ9.eyJzdWIiOiJ1c2VyIn0.c2lnbmF0dXJl"
    line = f"key abcdef123456 Authorization: Bearer {jwt} token={jwt} password: 'hunter2hunter2' api_key=zzz9999 ok=1"
    cleaned = nl.redact(line, secrets)
    for leaked in ("abcdef123456", jwt, "hunter2hunter2", "zzz9999"):
        assert leaked not in cleaned
    assert "ok=1" in cleaned and "Bearer [redacted]" in cleaned


def test_ordinary_lines_pass_through_unchanged():
    line = "INFO:     127.0.0.1:58481 - GET /healthz HTTP/1.1 200 OK"
    assert nl.redact(line, []) == line


def test_the_file_is_private_and_rotates_with_a_bounded_number_of_backups(tmp_path):
    sink = nl.RotatingFile(tmp_path / "logs", "node.log", max_bytes=40, backups=2)
    for index in range(12):
        sink.write(f"line number {index:03d} padding\n")
    names = sorted(path.name for path in (tmp_path / "logs").iterdir())
    assert names == ["node.log", "node.log.1", "node.log.2"]
    assert oct((tmp_path / "logs" / "node.log").stat().st_mode & 0o777) == "0o600"
    assert oct((tmp_path / "logs").stat().st_mode & 0o777) == "0o700"
    assert "line number 011" in (tmp_path / "logs" / "node.log").read_text()


def test_capture_output_redacts_what_the_process_writes_to_its_descriptors(tmp_path):
    pid = os.fork()
    if pid == 0:
        try:
            nl.capture_output(tmp_path / "logs", ["topsecretvalue"])
            os.write(1, b"started with topsecretvalue\n")
            os.write(2, b"warning without secrets\n")
            time.sleep(0.4)
        finally:
            os._exit(0)
    os.waitpid(pid, 0)
    text = (tmp_path / "logs" / "node.log").read_text()
    assert "started with [redacted]" in text and "warning without secrets" in text
    assert "topsecretvalue" not in text
