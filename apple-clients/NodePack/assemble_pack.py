"""Assembles the relocatable macOS arm64 node pack from pinned inputs and seals it with a manifest, a deterministic archive and a download descriptor.

It reads pins.json and the hashed requirement locks beside it, takes the kernel wheel and mailbox that build_kernel.sh produced, and writes into one output directory that the app's node installer downloads from.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.parse
import urllib.request
from pathlib import Path

import pack_manifest
import pins

HERE = Path(__file__).resolve().parent
PYTHON_HOST_PREFIX = "https://github.com/astral-sh/python-build-standalone/releases/download/"
COMPONENT_BUILD_ORDER = ("astral-primitives", "astral-kernel", "astral-projection", "astral-plane", "lets")
PRUNED_SITE_PACKAGES = ("pip", "setuptools", "wheel", "pkg_resources", "_distutils_hack", "distutils-precedence.pth")


class PackError(Exception):
    pass


def run(command: list, **kwargs) -> None:
    subprocess.run([str(part) for part in command], check=True, **kwargs)


def download_python(pin: dict, cache: Path) -> Path:
    if not pin["url"].startswith(PYTHON_HOST_PREFIX):
        raise PackError("the Python runtime must come from the python-build-standalone GitHub releases")
    target = cache / urllib.parse.unquote(pin["url"].rsplit("/", 1)[1])
    if not target.is_file():
        cache.mkdir(parents=True, exist_ok=True)
        partial = target.with_suffix(".part")
        with urllib.request.urlopen(pin["url"], timeout=120) as response, partial.open("wb") as handle:
            shutil.copyfileobj(response, handle)
        partial.replace(target)
    if pack_manifest.sha256_file(target) != pin["sha256"]:
        target.unlink()
        raise PackError("the Python runtime archive does not match its pinned SHA-256")
    return target


def mirror(name: str, repository: str, work: Path) -> Path:
    override = os.environ.get(f"NODEPACK_REPO_{name.upper().replace('-', '_')}")
    source = override or repository
    bare = work / "sources" / f"{name}.git"
    if not bare.is_dir():
        bare.parent.mkdir(parents=True, exist_ok=True)
        run(["git", "clone", "--quiet", "--bare", source, bare])
    return bare


def export_commit(name: str, repository: str, commit: str, destination: Path, work: Path) -> str:
    bare = mirror(name, repository, work)
    resolved = subprocess.run(
        ["git", "-C", bare, "rev-parse", "--verify", f"{commit}^{{commit}}"],
        capture_output=True, text=True,
    )
    if resolved.returncode != 0:
        run(["git", "-C", bare, "fetch", "--quiet", "origin", commit])
        resolved = subprocess.run(
            ["git", "-C", bare, "rev-parse", "--verify", f"{commit}^{{commit}}"],
            capture_output=True, text=True, check=True,
        )
    full = resolved.stdout.strip()
    if not full.startswith(commit):
        raise PackError(f"{name} resolved {full}, expected {commit}")
    destination.mkdir(parents=True, exist_ok=True)
    archive = subprocess.Popen(["git", "-C", str(bare), "archive", full], stdout=subprocess.PIPE)
    with tarfile.open(fileobj=archive.stdout, mode="r|") as bundle:
        bundle.extractall(destination, filter="data")
    if archive.wait() != 0:
        raise PackError(f"git archive failed for {name}")
    return full


def prune_backend(backend: Path, exclusions: list[dict]) -> None:
    for entry in exclusions:
        target = backend / entry["path"]
        if target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()
    for tests in sorted(backend.rglob("tests"), reverse=True):
        if tests.is_dir():
            shutil.rmtree(tests)
    for cache in sorted(backend.rglob("__pycache__"), reverse=True):
        shutil.rmtree(cache)


def prune_python(python_root: Path) -> None:
    site = python_root / "lib" / "python3.11" / "site-packages"
    for name in PRUNED_SITE_PACKAGES:
        for match in site.glob(f"{name}*"):
            shutil.rmtree(match) if match.is_dir() else match.unlink()
    bin_dir = python_root / "bin"
    for entry in bin_dir.iterdir():
        if not entry.name.startswith("python"):
            entry.unlink()
    for unused in ("test", "idlelib", "turtledemo", "tkinter", "ensurepip"):
        shutil.rmtree(python_root / "lib" / "python3.11" / unused, ignore_errors=True)
    for unused in (
        sorted(python_root.glob("lib/libtcl*")) + sorted(python_root.glob("lib/libtk*"))
        + sorted(python_root.glob("lib/thread*")) + sorted(python_root.glob("lib/tcl*"))
        + sorted(python_root.glob("lib/tk*")) + sorted(python_root.glob("lib/itcl*"))
        + sorted(python_root.glob("lib/python3.11/lib-dynload/_tkinter*"))
    ):
        shutil.rmtree(unused, ignore_errors=True) if unused.is_dir() else unused.unlink()
    shutil.rmtree(python_root / "share", ignore_errors=True)
    shutil.rmtree(python_root / "include", ignore_errors=True)
    for cache in sorted(python_root.rglob("__pycache__"), reverse=True):
        shutil.rmtree(cache)


def installed_distributions(python: Path) -> list[dict]:
    code = (
        "import importlib.metadata as m, json;"
        "print(json.dumps(sorted([d.metadata['Name'], d.version] for d in m.distributions())))"
    )
    output = subprocess.run([str(python), "-I", "-c", code], capture_output=True, text=True, check=True)
    return [{"name": name, "version": version} for name, version in json.loads(output.stdout)]


def verify_exclusions(distributions: list[dict], excluded: list[dict]) -> None:
    names = {entry["name"].lower().replace("_", "-") for entry in distributions}
    present = [entry["name"] for entry in excluded if entry["name"].lower().replace("_", "-") in names]
    if present:
        raise PackError(f"excluded packages are present: {', '.join(present)}")


def assemble(output: Path, kernel_dir: Path, work: Path) -> Path:
    settings = pins.load()
    kernel_commit = (kernel_dir / "kernel-commit.txt").read_text().strip()
    if kernel_commit != settings["kernel"]["commit"]:
        raise PackError(f"kernel artifacts come from {kernel_commit}, pins.json names {settings['kernel']['commit']}")
    wheels = sorted(kernel_dir.glob("astral_kernel-*-macosx_*_arm64.whl"))
    mailbox = kernel_dir / "astral-mailbox-macos-aarch64"
    if len(wheels) != 1 or not mailbox.is_file():
        raise PackError(f"{kernel_dir} needs one kernel wheel and the mailbox; run build_kernel.sh first")

    stage = work / "stage"
    shutil.rmtree(stage, ignore_errors=True)
    app = stage / "app"
    components_root = work / "components-root"
    shutil.rmtree(components_root, ignore_errors=True)

    python_archive = download_python(settings["python"], work / "downloads")
    with tarfile.open(python_archive) as bundle:
        bundle.extractall(stage, filter="data")
    python_root = stage / "python"
    python = python_root / "bin" / "python3.11"

    deep_commit = export_commit("AstralDeep", settings["deep"]["repository"], settings["deep"]["commit"], components_root, work)
    composition = json.loads((components_root / "config" / "astral-composition.json").read_text())
    component_inputs = {}
    for name, component in composition["components"].items():
        full = export_commit(
            Path(component["path"]).name, component["repository"], component["commit"],
            components_root / component["path"], work,
        )
        component_inputs[name] = {"repository": component["repository"], "commit": full}

    tooling = work / "build-venv"
    shutil.rmtree(tooling, ignore_errors=True)
    run([python, "-m", "venv", tooling])
    tool_python = tooling / "bin" / "python"
    run([tool_python, "-m", "pip", "install", "--quiet", "--require-hashes", "--no-deps",
         "-r", HERE / "build-requirements.lock"])
    wheelhouse = work / "wheelhouse"
    shutil.rmtree(wheelhouse, ignore_errors=True)
    run([tool_python, "-m", "pip", "wheel", "--quiet", "--require-hashes", "--no-build-isolation", "--no-deps",
         "-r", HERE / "node-requirements.lock", "-w", wheelhouse])
    component_wheels = work / "component-wheels"
    shutil.rmtree(component_wheels, ignore_errors=True)
    lock = component_wheels / "astral-component-wheels.lock.json"
    run([tool_python, components_root / "scripts" / "install_local_components.py", "build",
         "--root", components_root, "--wheel-dir", component_wheels, "--lock", lock])

    run([python, "-m", "ensurepip", "--default-pip"], stdout=subprocess.DEVNULL)
    run([python, "-m", "pip", "install", "--quiet", "--no-index", "--no-deps", "--no-compile",
         *sorted(wheelhouse.glob("*.whl")), wheels[0]])
    run([python, components_root / "scripts" / "install_local_components.py", "install",
         "--root", components_root, "--lock", lock])
    run([python, components_root / "scripts" / "install_local_components.py", "verify",
         "--root", components_root, "--lock", lock])
    distributions = installed_distributions(python)
    verify_exclusions(distributions, settings["excluded_packages"])
    prune_python(python_root)

    for relative in ("backend", "config", "scripts/node", "pyproject.toml", ".gitmodules"):
        source = components_root / relative
        if source.is_dir():
            shutil.copytree(source, app / relative)
        elif source.is_file():
            (app / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, app / relative)
    prune_backend(app / "backend", settings["backend_exclusions"])

    (stage / "bin").mkdir()
    shutil.copy2(mailbox, stage / "bin" / "astral-mailbox")
    (stage / "launcher").mkdir()
    shutil.copy2(HERE / "launcher" / "astral_node_launch.py", stage / "launcher" / "astral_node_launch.py")

    run([python, "-I", "-m", "compileall", "-q", "-j", "0", "--invalidation-mode", "unchecked-hash",
         python_root / "lib" / "python3.11", app / "backend", app / "scripts"])

    deep_short = deep_commit[:8]
    version = f"{settings['python']['version']}-{deep_short}-{kernel_commit[:7]}"
    inputs = {
        "version": version,
        "platform": "macos-arm64",
        "pack_format": settings["pack_format"],
        "python": {**settings["python"], "archive_sha256": settings["python"]["sha256"]},
        "deep": {"repository": settings["deep"]["repository"], "commit": deep_commit},
        "components": component_inputs,
        "component_wheels": json.loads(lock.read_text()),
        "kernel": {
            "repository": settings["kernel"]["repository"],
            "commit": kernel_commit,
            "wheel": {"file": wheels[0].name, "sha256": pack_manifest.sha256_file(wheels[0])},
            "mailbox": {"file": mailbox.name, "sha256": pack_manifest.sha256_file(mailbox)},
        },
        "requirements": {
            "node_lock_sha256": pack_manifest.sha256_file(HERE / "node-requirements.lock"),
            "build_lock_sha256": pack_manifest.sha256_file(HERE / "build-requirements.lock"),
            "wheels": sorted(
                ({"file": wheel.name, "sha256": pack_manifest.sha256_file(wheel)} for wheel in wheelhouse.glob("*.whl")),
                key=lambda entry: entry["file"],
            ),
        },
        "installed_distributions": distributions,
        "excluded_packages": settings["excluded_packages"],
        "kept_server_parts": settings["kept_server_parts"],
        "excluded_backend_paths": settings["backend_exclusions"],
    }
    manifest = pack_manifest.write_manifest(stage, inputs)

    output.mkdir(parents=True, exist_ok=True)
    archive_name = f"{pack_manifest.ARCHIVE_PREFIX}-{version}-macos-arm64.tar.gz"
    archive = pack_manifest.write_archive(stage, output / archive_name)
    manifest_sha = pack_manifest.sha256_file(stage / pack_manifest.MANIFEST_NAME)
    descriptor = pack_manifest.descriptor(manifest, archive, manifest_sha)
    (output / "node-pack.json").write_text(json.dumps(descriptor, indent=1, sort_keys=True) + "\n")
    shutil.copy2(stage / pack_manifest.MANIFEST_NAME, output / "node-pack-manifest.json")
    return output / "node-pack.json"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kernel-dir", type=Path, default=HERE / "build" / "kernel")
    parser.add_argument("--out", type=Path, default=HERE / "build" / "pack")
    parser.add_argument("--work", type=Path, default=Path(os.environ.get(
        "NODEPACK_WORK", Path.home() / "Library" / "Caches" / "AstralNodePack")))
    arguments = parser.parse_args()
    try:
        descriptor = assemble(arguments.out, arguments.kernel_dir, arguments.work)
    except (PackError, subprocess.CalledProcessError) as error:
        sys.exit(f"node pack: {error}")
    summary = json.loads(descriptor.read_text())
    print(f"{descriptor}: archive {summary['archive']['size']} bytes, installed {summary['installed_bytes']} bytes")


if __name__ == "__main__":
    main()
