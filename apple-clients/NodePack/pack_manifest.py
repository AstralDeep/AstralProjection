"""Builds, writes and verifies the node pack's file manifest, its deterministic archive and its download descriptor.

assemble_pack.py uses it to seal a staged tree, and the tests use verify_tree to prove the same checks the app performs after it unpacks a download.
"""

import gzip
import hashlib
import io
import json
import os
import stat
import tarfile
from pathlib import Path

MANIFEST_NAME = "manifest.json"
DESCRIPTOR_FORMAT = "astral.nodepack-descriptor/v1"
MANIFEST_FORMAT = "astral.nodepack-manifest/v1"
ARCHIVE_PREFIX = "astral-node-pack"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_table(root: Path) -> list[dict]:
    entries: list[dict] = []
    for current, directories, names in os.walk(root, followlinks=False):
        directories.sort()
        base = Path(current)
        for name in sorted(names):
            path = base / name
            relative = path.relative_to(root).as_posix()
            if relative == MANIFEST_NAME:
                continue
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                entries.append({"path": relative, "link": os.readlink(path)})
            elif stat.S_ISREG(info.st_mode):
                entries.append({
                    "path": relative,
                    "sha256": sha256_file(path),
                    "size": info.st_size,
                    "executable": bool(info.st_mode & stat.S_IXUSR),
                })
            else:
                raise ValueError(f"unsupported file type: {relative}")
        for directory in directories:
            path = base / directory
            if path.is_symlink():
                entries.append({"path": path.relative_to(root).as_posix(), "link": os.readlink(path)})
    entries.sort(key=lambda entry: entry["path"])
    return entries


def link_escapes(root: Path, relative: str, target: str) -> bool:
    if os.path.isabs(target):
        return True
    resolved = os.path.normpath(os.path.join(os.path.dirname(relative), target))
    return resolved == ".." or resolved.startswith("../")


def write_manifest(root: Path, inputs: dict) -> dict:
    files = file_table(root)
    for entry in files:
        if "link" in entry and link_escapes(root, entry["path"], entry["link"]):
            raise ValueError(f"link leaves the pack: {entry['path']}")
    manifest = {
        "format": MANIFEST_FORMAT,
        **inputs,
        "installed_bytes": sum(entry.get("size", 0) for entry in files),
        "files": files,
    }
    (root / MANIFEST_NAME).write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
    return manifest


def verify_tree(root: Path, manifest: dict) -> list[str]:
    problems: list[str] = []
    expected = {entry["path"]: entry for entry in manifest["files"]}
    actual: dict[str, Path] = {}
    for current, directories, names in os.walk(root, followlinks=False):
        base = Path(current)
        for name in names + [d for d in directories if (base / d).is_symlink()]:
            path = base / name
            actual[path.relative_to(root).as_posix()] = path
    actual.pop(MANIFEST_NAME, None)
    for relative in sorted(set(actual) - set(expected)):
        problems.append(f"unexpected file {relative}")
    for relative, entry in sorted(expected.items()):
        path = actual.get(relative)
        if path is None:
            problems.append(f"missing file {relative}")
        elif "link" in entry:
            if not path.is_symlink() or os.readlink(path) != entry["link"]:
                problems.append(f"link changed {relative}")
            elif link_escapes(root, relative, entry["link"]):
                problems.append(f"link leaves the pack {relative}")
        elif path.is_symlink():
            problems.append(f"link where a file belongs {relative}")
        elif path.stat().st_size != entry["size"] or sha256_file(path) != entry["sha256"]:
            problems.append(f"content changed {relative}")
    return problems


def write_archive(root: Path, archive: Path) -> dict:
    names = sorted(
        [MANIFEST_NAME] + [entry["path"] for entry in json.loads((root / MANIFEST_NAME).read_text())["files"]]
    )
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb", compresslevel=9, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as bundle:
            for name in names:
                path = root / name
                info = bundle.gettarinfo(str(path), arcname=name)
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mtime = 0
                if info.isreg():
                    info.mode = 0o755 if info.mode & stat.S_IXUSR else 0o644
                    with path.open("rb") as handle:
                        bundle.addfile(info, handle)
                else:
                    bundle.addfile(info)
    archive.write_bytes(buffer.getvalue())
    return {"file": archive.name, "size": archive.stat().st_size, "sha256": sha256_file(archive)}


def descriptor(manifest: dict, archive: dict, manifest_sha256: str) -> dict:
    return {
        "format": DESCRIPTOR_FORMAT,
        "version": manifest["version"],
        "platform": manifest["platform"],
        "archive": archive,
        "installed_bytes": manifest["installed_bytes"],
        "manifest_sha256": manifest_sha256,
    }
