"""Qualifies an installed node pack with an owner-authenticated tool turn using only loopback fixtures and a temporary home.

It installs a personal-profile home with the pack's own script, starts the packed node, and drives it with a loopback token issuer and a loopback model. The pure checks live in this file so the pack tests cover them, and the fixture and client halves run under the pack's own Python.
"""

import argparse
import asyncio
import base64
import hashlib
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import uuid
from collections import Counter
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TOOL = "generate_dynamic_chart"
CHART_TITLE = "Node pack qualification chart"
FINAL_TEXT = "FAKE-MODEL-OK"
CLIENT_ID = "astral-app"
REALM = "/realms/astral"
CHAT_PROMPT = "Please chart these two values: a is 1 and b is 2."
CHART_ARGUMENTS = {
    "data": [{"name": "a", "value": 1}, {"name": "b", "value": 2}],
    "x_key": "name",
    "y_key": "value",
    "chart_type": "bar",
    "title": CHART_TITLE,
}
SECRET_KEYS = ("KEY", "SECRET", "TOKEN", "PASSWORD")
NOISE_FRAMES = {
    "audit_append", "user_preferences", "system_config", "rote_config", "chrome_render", "chrome_surface",
    "history_list", "chat_history", "llm_usage_report", "conversation_snapshot", "user_message_acked",
}


class PackError(Exception):
    pass


@dataclass
class Check:
    name: str
    ok: bool
    detail: str = ""


@dataclass
class Report:
    checks: list[Check] = field(default_factory=list)

    def add(self, name: str, ok: bool, detail: str = "") -> None:
        self.checks.append(Check(name, bool(ok), detail))

    @property
    def failed(self) -> list[Check]:
        return [check for check in self.checks if not check.ok]

    def lines(self) -> list[str]:
        rows = [f"{'PASS' if c.ok else 'FAIL'} {c.name}" + (f" ({c.detail})" if c.detail else "") for c in self.checks]
        rows.append(f"RESULT {len(self.checks) - len(self.failed)} passed, {len(self.failed)} failed of {len(self.checks)}")
        return rows

    @property
    def exit_code(self) -> int:
        return 1 if self.failed or not self.checks else 0


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def pack_python(root: Path) -> Path:
    return root / "python" / "bin" / "python3.11"


def is_installed_pack(path: Path) -> bool:
    return pack_python(path).is_file() and (path / "launcher" / "astral_node_launch.py").is_file()


def resolve_pack(source: Path, scratch: Path) -> Path:
    if is_installed_pack(source):
        return source
    descriptor_path = source / "node-pack.json"
    if not descriptor_path.is_file():
        raise PackError(f"{source} is neither an installed pack nor a folder with node-pack.json")
    descriptor = json.loads(descriptor_path.read_text())
    archive = source / descriptor["archive"]["file"]
    if not archive.is_file():
        raise PackError(f"archive {archive.name} is missing")
    if archive.stat().st_size != descriptor["archive"]["size"]:
        raise PackError("archive size does not match the descriptor")
    if sha256_file(archive) != descriptor["archive"]["sha256"]:
        raise PackError("archive SHA-256 does not match the descriptor")
    target = scratch / "pack"
    target.mkdir(parents=True)
    with tarfile.open(archive) as bundle:
        bundle.extractall(target, filter="data")
    if not is_installed_pack(target):
        raise PackError("the extracted archive is not a node pack")
    return target


def parse_env_text(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip().strip("'\"")
    return values


def merge_env(text: str, extra: dict[str, str]) -> str:
    present = parse_env_text(text)
    body = text if not text or text.endswith("\n") else text + "\n"
    return body + "".join(f"{key}={value}\n" for key, value in extra.items() if key not in present)


def secret_values(env: dict[str, str]) -> list[str]:
    return [v for k, v in env.items() if any(word in k for word in SECRET_KEYS) and len(v) >= 8]


def contains_secret(text: str, secrets: list[str]) -> bool:
    return any(secret in text for secret in secrets)


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def collect_types(value, found: set[str] | None = None) -> set[str]:
    found = set() if found is None else found
    if isinstance(value, dict):
        if isinstance(value.get("type"), str):
            found.add(value["type"])
        for child in value.values():
            collect_types(child, found)
    elif isinstance(value, list):
        for child in value:
            collect_types(child, found)
    return found


def tool_offer(requests: list[dict]) -> tuple[int, bool]:
    best = max((r for r in requests if r.get("tools")), key=lambda r: len(r["tools"]), default=None)
    if best is None:
        return 0, False
    return len(best["tools"]), any(name.endswith(TOOL) for name in best["tools"])


def tool_result_returned(requests: list[dict]) -> bool:
    return any("tool" in r.get("roles", []) for r in requests)


def evaluate(observed: dict, requests: list[dict], disk_marker: bool, log_clean: bool) -> Report:
    report = Report()
    statuses = observed.get("statuses", {})
    for name, expected in (("missing", 401), ("forged", 401), ("owner", 200)):
        report.add(f"{name} credential answers {expected}", statuses.get(name) == expected, f"got {statuses.get(name)}")
    report.add("websocket registered as the owner", bool(observed.get("registered")))
    report.add("provider saved on the node", bool(observed.get("provider_saved")), observed.get("provider_detail", ""))
    count, offered = tool_offer(requests)
    report.add("tools offered to the model", count > 0 and offered, f"{count} tools, {TOOL} offered={offered}")
    report.add(f"{TOOL} executed and its result returned to the model", tool_result_returned(requests))
    report.add("turn completed", observed.get("final_state") == "completed", f"state {observed.get('final_state')}")
    report.add("chart streamed to the client in the turn", bool(observed.get("chart_frame")), f"in {observed.get('chart_frame')} frames")
    history = observed.get("history", [])
    roles = [m.get("role") for m in history]
    report.add("history holds the user message and the final answer",
               "user" in roles and any(m.get("role") == "assistant" and FINAL_TEXT in m.get("text", "") for m in history),
               f"{len(history)} messages")
    report.add("chart persisted in history", any(CHART_TITLE in m.get("text", "") for m in history))
    report.add("chart persisted in the node database", disk_marker)
    report.add("node log holds no secret value", log_clean)
    return report


def brief_message(message: dict) -> dict:
    return {"role": message.get("role"), "text": json.dumps(message, sort_keys=True)}


def model_tool_args(spec: dict) -> dict:
    if (spec.get("function") or {}).get("name", "").endswith(TOOL):
        return CHART_ARGUMENTS
    return {}


def model_reply(body: dict) -> dict:
    messages = body.get("messages") or []
    tools = body.get("tools") or []
    used = any(m.get("role") == "tool" for m in messages)
    pick = next((t for t in tools if (t.get("function") or {}).get("name", "").endswith(TOOL)), None)
    if pick and not used and body.get("tool_choice") != "none":
        call = {"id": "call_fixture_1", "type": "function",
                "function": {"name": pick["function"]["name"], "arguments": json.dumps(model_tool_args(pick))}}
        return {"content": None, "tool_calls": [call], "finish": "tool_calls"}
    return {"content": f"{FINAL_TEXT}: tool result received" if used else FINAL_TEXT, "tool_calls": None, "finish": "stop"}


def run_model(directory: Path, ready: threading.Event, ports: dict) -> None:
    journal = directory / "model-requests.jsonl"

    class Handler(BaseHTTPRequestHandler):
        def _send(self, payload: bytes, kind: str = "application/json") -> None:
            self.send_response(200)
            self.send_header("content-type", kind)
            self.send_header("content-length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            self._send(json.dumps({"object": "list", "data": [{"id": "fixture-model", "object": "model"}]}).encode())

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("content-length") or 0)) or b"{}")
            names = [(t.get("function") or {}).get("name") for t in body.get("tools") or []]
            record = {"roles": [m.get("role") for m in body.get("messages") or []], "tools": [n for n in names if n]}
            with journal.open("a") as handle:
                handle.write(json.dumps(record) + "\n")
            reply = model_reply(body)
            message = {"role": "assistant", "content": reply["content"]}
            if reply["tool_calls"]:
                message["tool_calls"] = reply["tool_calls"]
            base = {"id": "chatcmpl-fixture", "object": "chat.completion", "created": int(time.time()), "model": "fixture-model"}
            usage = {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
            if not body.get("stream"):
                self._send(json.dumps(base | {"choices": [{"index": 0, "message": message, "finish_reason": reply["finish"]}], "usage": usage}).encode())
                return
            delta = {"role": "assistant"}
            if reply["content"]:
                delta["content"] = reply["content"]
            if reply["tool_calls"]:
                delta["tool_calls"] = [dict(c, index=0) for c in reply["tool_calls"]]
            chunk = base | {"object": "chat.completion.chunk"}
            events = [chunk | {"choices": [{"index": 0, "delta": delta, "finish_reason": None}]},
                      chunk | {"choices": [{"index": 0, "delta": {}, "finish_reason": reply["finish"]}]},
                      chunk | {"choices": [], "usage": usage}]
            self._send(("".join(f"data: {json.dumps(e)}\n\n" for e in events) + "data: [DONE]\n\n").encode(), "text/event-stream")

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    ports["model"] = server.server_address[1]
    ready.set()
    server.serve_forever()


def mint(key, kid: str, issuer: str, subject: str) -> str:
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import padding

    now = int(time.time())
    claims = {"iss": issuer, "sub": subject, "azp": CLIENT_ID, "aud": ["account", CLIENT_ID], "iat": now, "exp": now + 900,
              "preferred_username": "node-owner", "email": "owner@node.test", "realm_access": {"roles": ["user"]}}
    head = {"alg": "RS256", "typ": "JWT", "kid": kid}
    signing = b64url(json.dumps(head).encode()) + "." + b64url(json.dumps(claims).encode())
    return signing + "." + b64url(key.sign(signing.encode(), padding.PKCS1v15(), hashes.SHA256()))


def run_fixtures(directory: Path) -> None:
    from cryptography.hazmat.primitives.asymmetric import rsa

    kid = "fixture-issuer-1"
    trusted = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    rogue = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    numbers = trusted.public_key().public_numbers()

    def size(v: int) -> bytes:
        return v.to_bytes((v.bit_length() + 7) // 8, "big")

    jwks = json.dumps({"keys": [{"kty": "RSA", "use": "sig", "alg": "RS256", "kid": kid, "n": b64url(size(numbers.n)), "e": b64url(size(numbers.e))}]}).encode()

    class Issuer(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.endswith("/protocol/openid-connect/certs"):
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(jwks)))
                self.end_headers()
                self.wfile.write(jwks)
            else:
                self.send_response(404)
                self.end_headers()

        def log_message(self, *args):
            pass

    issuer_server = ThreadingHTTPServer(("127.0.0.1", 0), Issuer)
    ports: dict = {"issuer": issuer_server.server_address[1]}
    issuer = f"http://127.0.0.1:{ports['issuer']}{REALM}"
    for name, key in (("owner", trusted), ("forged", rogue)):
        token_path = directory / f"{name}.token"
        token_path.write_text(mint(key, kid, issuer, "owner-1"))
        token_path.chmod(0o600)
    ready = threading.Event()
    threading.Thread(target=run_model, args=(directory, ready, ports), daemon=True).start()
    ready.wait(10)
    (directory / "fixtures.json").write_text(json.dumps({"issuer": issuer, "model_port": ports["model"]}))
    issuer_server.serve_forever()


def read_token(directory: Path, name: str) -> str:
    return (directory / f"{name}.token").read_text().strip()


def ui_event(action: str, session: str, **payload) -> dict:
    return {"type": "ui_event", "action": action, "session_id": session,
            "payload": {"submission_id": str(uuid.uuid4()), "request_generation": str(uuid.uuid4()), **payload}}


async def run_client(directory: Path, port: int, model_port: int) -> dict:
    import aiohttp

    base = f"http://127.0.0.1:{port}"
    owner = read_token(directory, "owner")
    forged = read_token(directory, "forged")
    observed: dict = {"statuses": {}, "frames": {}}

    async def status(session, headers) -> int:
        async with session.get(base + "/api/chats", headers=headers) as response:
            await response.read()
            return response.status

    async def pump(ws, seconds, stop):
        loop = asyncio.get_event_loop()
        end = loop.time() + seconds
        while loop.time() < end:
            try:
                message = await ws.receive(timeout=end - loop.time())
            except asyncio.TimeoutError:
                return
            if message.type != aiohttp.WSMsgType.TEXT:
                return
            frame = json.loads(message.data)
            yield frame
            if stop(frame):
                return

    async with aiohttp.ClientSession() as session:
        observed["statuses"]["missing"] = await status(session, {})
        observed["statuses"]["forged"] = await status(session, {"Authorization": "Bearer " + forged})
        auth = {"Authorization": "Bearer " + owner}
        observed["statuses"]["owner"] = await status(session, auth)
        async with session.post(base + "/api/chats", headers=auth, json={}) as response:
            chat_id = (await response.json())["chat_id"]
        async with session.ws_connect(base + "/ws") as ws:
            await ws.send_json({"type": "register_ui", "token": owner, "capabilities": [], "device": {"device_type": "browser"}})
            async for frame in pump(ws, 6, lambda f: False):
                observed["registered"] = True
            fields = {"provider": "custom", "base_url": f"http://127.0.0.1:{model_port}/v1", "model": "fixture-model",
                      "api_key": "fixture-key-local-only", "data_sharing_acknowledged": True}
            await ws.send_json(ui_event("chrome_llm_save", chat_id, surface="llm", fields=fields))
            async for frame in pump(ws, 30, lambda f: f.get("type") == "llm_config_ack"):
                if frame.get("type") == "llm_config_ack":
                    observed["provider_saved"] = frame.get("ok", frame.get("status") in ("ok", "saved", "success"))
                    observed["provider_detail"] = json.dumps({k: frame[k] for k in ("ok", "status", "message") if k in frame})
            await asyncio.sleep(3)
            await ws.send_json(ui_event("chat_message", chat_id, message=CHAT_PROMPT, async_mode=False))
            types: Counter = Counter()
            components: set[str] = set()

            def done(f: dict) -> bool:
                return f.get("type") == "operation_status" and f.get("state") in ("completed", "failed")

            async for frame in pump(ws, 120, done):
                kind = frame.get("type")
                if kind in NOISE_FRAMES:
                    continue
                types[kind] += 1
                if CHART_TITLE in json.dumps(frame):
                    observed["chart_frame"] = kind
                    components |= collect_types(frame)
                if done(frame):
                    observed["final_state"] = frame.get("state")
            observed["frames"] = dict(types)
            observed["component_types"] = sorted(components)
        async with session.get(f"{base}/api/chats/{chat_id}", headers=auth) as response:
            detail = await response.json()
        observed["history"] = [brief_message(m) for m in (detail.get("chat") or {}).get("messages", [])]
    return observed


def wait_for(path: Path, seconds: float) -> None:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if path.is_file() and path.stat().st_size:
            return
        time.sleep(0.1)
    raise PackError(f"{path.name} did not appear")


def wait_ready(port: int, seconds: float, process: subprocess.Popen) -> None:
    import urllib.request

    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if process.poll() is not None:
            raise PackError(f"the node exited with {process.returncode}")
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/readyz", timeout=3) as response:
                if response.status == 200:
                    return
        except OSError:
            time.sleep(0.5)
    raise PackError("the node did not become ready")


def stop_group(process: subprocess.Popen | None) -> None:
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=10)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def leftover_processes(marker: str) -> list[str]:
    found = subprocess.run(["pgrep", "-f", marker], capture_output=True, text=True)
    return [pid for pid in found.stdout.split() if pid != str(os.getpid())]


def disk_has_marker(data: Path, marker: str) -> bool:
    needle = marker.encode()
    for candidate in data.glob("plane.sqlite3*"):
        if candidate.is_file() and needle in candidate.read_bytes():
            return True
    return False


def run(pack_source: Path, keep: bool, log) -> Report:
    scratch = Path(tempfile.mkdtemp(prefix="nodepack-toolturn-"))
    scratch.chmod(0o700)
    home = scratch / "home"
    children: list[subprocess.Popen | None] = []
    try:
        log(f"workdir {scratch.name}")
        pack = resolve_pack(pack_source, scratch)
        python = str(pack_python(pack))
        fixtures_dir = scratch / "fixtures"
        fixtures_dir.mkdir()
        me = str(Path(__file__).resolve())
        fixtures = subprocess.Popen([python, "-I", me, "fixtures", str(fixtures_dir)], start_new_session=True,
                                    stdout=subprocess.DEVNULL, stderr=(scratch / "fixtures.log").open("w"))
        children.append(fixtures)
        wait_for(fixtures_dir / "fixtures.json", 30)
        fixed = json.loads((fixtures_dir / "fixtures.json").read_text())
        port = free_port()
        install = subprocess.run(
            ["/bin/bash", str(pack / "app/scripts/node/install-personal-node.sh"), "--issuer", fixed["issuer"],
             "--client-id", CLIENT_ID, "--home", str(home)],
            env={"PATH": "/usr/bin:/bin", "HOME": str(home)}, capture_output=True, text=True)
        if install.returncode != 0:
            raise PackError("install-personal-node.sh failed: " + install.stdout[-200:] + install.stderr[-200:])
        env_file = home / "node.env"
        env_file.write_text(merge_env(env_file.read_text(), {
            "ASTRAL_ENV": "development", "PUBLIC_BASE_URL": f"http://127.0.0.1:{port}",
            "BACKEND_PUBLIC_URL": f"http://127.0.0.1:{port}", "EXTERNAL_AGENT_ALLOWED_PRIVATE_HOSTS": "127.0.0.1",
            "PYTHON_DOTENV_DISABLED": "1"}))
        env_file.chmod(0o600)
        secrets = secret_values(parse_env_text(env_file.read_text()))
        (home / "tmp").mkdir(exist_ok=True)
        node = subprocess.Popen(
            [python, "-I", str(pack / "launcher/astral_node_launch.py"), "--env-file", str(env_file), "--port", str(port),
             "--log-dir", str(home / "logs")],
            cwd=pack, start_new_session=True, stdout=subprocess.DEVNULL, stderr=(scratch / "node-stderr.log").open("w"),
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home), "TMPDIR": str(home / "tmp") + "/", "LANG": "en_US.UTF-8"})
        children.append(node)
        wait_ready(port, 240, node)
        log("node ready")
        client = subprocess.run([python, "-I", me, "client", str(fixtures_dir), str(port), str(fixed["model_port"])],
                                capture_output=True, text=True, timeout=300)
        if client.returncode != 0:
            raise PackError("client failed: " + client.stderr[-400:])
        observed = json.loads(client.stdout.strip().splitlines()[-1])
        journal = fixtures_dir / "model-requests.jsonl"
        requests = [json.loads(line) for line in journal.read_text().splitlines()] if journal.is_file() else []
        node_log = home / "logs" / "node.log"
        text = node_log.read_text(errors="replace") if node_log.is_file() else ""
        report = evaluate(observed, requests, disk_has_marker(home / "data", CHART_TITLE), not contains_secret(text, secrets))
        count, _ = tool_offer(requests)
        log(f"model requests {len(requests)}, tools offered {count}, frames {json.dumps(observed.get('frames', {}), sort_keys=True)}")
    finally:
        for child in reversed(children):
            stop_group(child)
        time.sleep(0.5)
        left = leftover_processes(scratch.name)
        if not keep:
            shutil.rmtree(scratch, ignore_errors=True)
    report.add("every process this run started has exited", not left, f"{len(left)} left")
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode")
    sub.add_parser("fixtures").add_argument("directory", type=Path)
    client = sub.add_parser("client")
    client.add_argument("directory", type=Path)
    client.add_argument("port", type=int)
    client.add_argument("model_port", type=int)
    parser.add_argument("--pack", type=Path, help="an installed pack directory or a folder holding node-pack.json and its archive")
    parser.add_argument("--keep", action="store_true", help="keep the temporary folder for inspection")
    arguments = parser.parse_args(argv)
    if arguments.mode == "fixtures":
        run_fixtures(arguments.directory)
        return 0
    if arguments.mode == "client":
        print(json.dumps(asyncio.run(run_client(arguments.directory, arguments.port, arguments.model_port))))
        return 0
    if arguments.pack is None:
        parser.error("--pack is required")
    started = time.monotonic()
    try:
        report = run(arguments.pack.expanduser().resolve(), arguments.keep, lambda line: print(line, flush=True))
    except (PackError, subprocess.TimeoutExpired, json.JSONDecodeError, OSError) as error:
        print(f"FAIL setup ({type(error).__name__}: {error})")
        return 1
    for line in report.lines():
        print(line)
    print(f"DURATION {time.monotonic() - started:.1f}s")
    return report.exit_code


if __name__ == "__main__":
    sys.exit(main())
