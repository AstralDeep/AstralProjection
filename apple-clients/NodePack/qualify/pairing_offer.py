"""Qualifies an installed node pack with the no-sign-in pairing path: a loopback offer needs the node's private pairing secret, and a bearer token is refused.

It installs a personal-profile home with the pack's own script, starts the packed node, and drives its public routes over loopback with the standard library only. The pure checks live in this file so the pack tests cover them.
"""

import argparse
import hashlib
import json
import os
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

DESCRIPTOR_FORMAT = "astral.node.descriptor/v2"
SECRET_HEADER = "Astral-Pairing-Secret"
SECRET_FILE = "pairing-secret"
SECRET_KEYS = ("KEY", "SECRET", "TOKEN", "PASSWORD")
FORGED_BEARER = "eyJhbGciOiJSUzI1NiJ9.e30.c2ln"


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


def request(base: str, method: str, path: str, headers: dict[str, str] | None = None) -> dict:
    call = urllib.request.Request(base + path, method=method, headers=headers or {}, data=b"" if method == "POST" else None)
    try:
        with urllib.request.urlopen(call, timeout=20) as response:
            status, raw, reply = response.status, response.read(), response.headers
    except urllib.error.HTTPError as error:
        status, raw, reply = error.code, error.read(), error.headers
    try:
        document = json.loads(raw or b"{}")
    except ValueError:
        document = {}
    return {"status": status, "body": document if isinstance(document, dict) else {}, "cache": reply.get("cache-control", "")}


def read_secret(data: Path) -> str:
    path = data / SECRET_FILE
    return path.read_text().strip() if path.is_file() else ""


def private_mode(path: Path, expected: int) -> bool:
    return path.exists() and stat.S_IMODE(path.stat().st_mode) == expected


def drive(base: str, data: Path) -> dict:
    offer_path = "/api/node/mesh/offer"
    first = read_secret(data)
    observed: dict = {"secret": first}
    observed["descriptor"] = request(base, "GET", "/api/node/descriptor")
    observed["no_auth"] = request(base, "GET", "/api/chats")
    observed["forged_bearer"] = request(base, "GET", "/api/chats", {"Authorization": "Bearer " + FORGED_BEARER})
    observed["no_secret"] = request(base, "POST", offer_path)
    observed["wrong_secret"] = request(base, "POST", offer_path, {SECRET_HEADER: "wrong"})
    observed["forwarded"] = request(base, "POST", offer_path, {SECRET_HEADER: first, "X-Forwarded-For": "192.0.2.7"})
    observed["offer"] = request(base, "POST", offer_path, {SECRET_HEADER: first})
    rotated = read_secret(data)
    observed["secret_rotated"] = bool(first) and bool(rotated) and first != rotated
    observed["secret_mode_private"] = private_mode(data / SECRET_FILE, 0o600) and private_mode(data, 0o700)
    observed["replay"] = request(base, "POST", offer_path, {SECRET_HEADER: first})
    return observed


def detail(result: dict) -> str:
    return str(result.get("body", {}).get("detail", ""))


def evaluate(observed: dict, log_clean: bool) -> Report:
    report = Report()
    descriptor = observed.get("descriptor", {})
    document = descriptor.get("body", {})
    report.add("descriptor is v2 and offers mesh pairing", descriptor.get("status") == 200
               and document.get("format") == DESCRIPTOR_FORMAT and "mesh-peer" in document.get("capabilities", []),
               f"status {descriptor.get('status')}")
    report.add("descriptor names no identity server", "issuer" not in json.dumps(document).lower())
    for name in ("no_auth", "forged_bearer"):
        report.add(f"{name.replace('_', ' ')} is refused", observed.get(name, {}).get("status") == 401,
                   f"got {observed.get(name, {}).get('status')}")
    for name, status, code in (("no_secret", 401, "node.pairing_secret_required"),
                               ("wrong_secret", 401, "node.pairing_secret_required"),
                               ("forwarded", 403, "node.loopback_required"),
                               ("replay", 401, "node.pairing_secret_required")):
        got = observed.get(name, {})
        report.add(f"{name.replace('_', ' ')} offer answers {status} {code}", got.get("status") == status and detail(got) == code,
                   f"got {got.get('status')} {detail(got)}")
    offer = observed.get("offer", {})
    body = offer.get("body", {})
    report.add("the right secret returns the offer", offer.get("status") == 200 and body.get("state") == "offer"
               and bool(body.get("payload")) and bool(body.get("code")), f"status {offer.get('status')}")
    report.add("the offer is not cached", "no-store" in offer.get("cache", ""))
    report.add("the secret is replaced after the offer", bool(observed.get("secret_rotated")))
    report.add("the secret file and data directory are private", bool(observed.get("secret_mode_private")))
    report.add("node log holds no secret value", log_clean)
    return report


def wait_ready(port: int, seconds: float, process: subprocess.Popen) -> None:
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


def run(pack_source: Path, keep: bool, log) -> Report:
    scratch = Path(tempfile.mkdtemp(prefix="nodepack-pairing-"))
    scratch.chmod(0o700)
    home = scratch / "home"
    children: list[subprocess.Popen | None] = []
    try:
        log(f"workdir {scratch.name}")
        pack = resolve_pack(pack_source, scratch)
        python = str(pack_python(pack))
        port = free_port()
        install = subprocess.run(
            ["/bin/bash", str(pack / "app/scripts/node/install-personal-node.sh"), "--home", str(home)],
            env={"PATH": "/usr/bin:/bin", "HOME": str(home)}, capture_output=True, text=True)
        if install.returncode != 0:
            raise PackError("install-personal-node.sh failed: " + install.stdout[-200:] + install.stderr[-200:])
        env_file = home / "node.env"
        env_file.write_text(merge_env(env_file.read_text(), {
            "ASTRAL_ENV": "development", "PUBLIC_BASE_URL": f"http://127.0.0.1:{port}",
            "BACKEND_PUBLIC_URL": f"http://127.0.0.1:{port}", "PYTHON_DOTENV_DISABLED": "1"}))
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
        observed = drive(f"http://127.0.0.1:{port}", home / "data")
        node_log = home / "logs" / "node.log"
        text = node_log.read_text(errors="replace") if node_log.is_file() else ""
        clean = not contains_secret(text, secrets + ([observed["secret"]] if observed.get("secret") else []))
        report = evaluate(observed, clean)
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
    parser.add_argument("--pack", type=Path, required=True,
                        help="an installed pack directory or a folder holding node-pack.json and its archive")
    parser.add_argument("--keep", action="store_true", help="keep the temporary folder for inspection")
    arguments = parser.parse_args(argv)
    started = time.monotonic()
    try:
        report = run(arguments.pack.expanduser().resolve(), arguments.keep, lambda line: print(line, flush=True))
    except (PackError, subprocess.TimeoutExpired, OSError) as error:
        print(f"FAIL setup ({type(error).__name__}: {error})")
        return 1
    for line in report.lines():
        print(line)
    print(f"DURATION {time.monotonic() - started:.1f}s")
    return report.exit_code


if __name__ == "__main__":
    sys.exit(main())
