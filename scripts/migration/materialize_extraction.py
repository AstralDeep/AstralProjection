#!/usr/bin/env python3
"""Materialize an extraction manifest from immutable Git blobs.

The command never reads source bytes from a working tree.  It validates the
entire manifest, immutable source tree, destination identity, every Git tuple,
and every destination before it creates the first leaf.  Interrupted runs are
safe to resume only when an existing leaf is byte-for-byte identical.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import unicodedata
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any

FORMAT = "astral.extraction-provenance/v1"
DIGEST_ALGORITHM = "sha256"
ALLOWED_MODES = frozenset({"100644", "100755", "120000"})
FULL_OBJECT_ID = re.compile(r"^[0-9a-f]{40}$")
CANONICAL_REPOSITORY = re.compile(r"^https://github\.com/AstralDeep/[A-Za-z0-9._-]+\.git$")
WINDOWS_DEVICE = re.compile(r"^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$", re.IGNORECASE)
REPARSE_ATTRIBUTE = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
SOURCE_REPOSITORY = "https://github.com/AstralDeep/AstralDeep.git"
DESTINATION_REPOSITORY = "https://github.com/AstralDeep/AstralProjection.git"
APPLE_FIXTURE_SYMLINK = "apple-clients/AstralCore/Tests/AstralCoreTests/Fixtures/voice_065"


class MaterializationError(RuntimeError):
    """Raised when extraction cannot be proven safe."""


@dataclass(frozen=True, slots=True)
class ManifestEntry:
    source_path: str
    destination_path: str
    mode: str
    blob: str
    size_bytes: int
    payload: bytes


@dataclass(frozen=True, slots=True)
class MaterializationPlan:
    source_repo: Path
    destination_root: Path
    source_commit: str
    source_tree: str
    manifest_sha256: str
    entries: tuple[ManifestEntry, ...]
    allowed_symlinks: Mapping[str, str]


def _run_git(
    repo: Path,
    arguments: Sequence[str],
    *,
    input_bytes: bytes | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    environment = os.environ.copy()
    environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    process = subprocess.run(
        ["git", "-C", os.fspath(repo), *arguments],
        input=input_bytes,
        capture_output=True,
        env=environment,
        check=False,
    )
    if check and process.returncode != 0:
        detail = process.stderr.decode("utf-8", "replace").strip()
        raise MaterializationError(
            f"Git command failed ({' '.join(arguments)}): {detail or 'no detail'}"
        )
    return process


def _exact_git_root(path: str | Path, *, field: str) -> Path:
    candidate = Path(path)
    try:
        lexical = Path(os.path.abspath(candidate))
        resolved = candidate.resolve(strict=True)
    except OSError as exc:
        raise MaterializationError(f"{field} does not resolve: {exc}") from exc
    if lexical != resolved:
        raise MaterializationError(f"{field} must not traverse a symlink or reparse point")
    if not resolved.is_dir():
        raise MaterializationError(f"{field} is not a directory")
    top_level = _run_git(resolved, ["rev-parse", "--show-toplevel"])
    try:
        git_root = Path(top_level.stdout.decode("utf-8").strip()).resolve(strict=True)
    except OSError as exc:
        raise MaterializationError(f"{field} Git root does not resolve: {exc}") from exc
    if git_root != resolved:
        raise MaterializationError(f"{field} must be an exact Git worktree root")
    if _is_reparse(resolved):
        raise MaterializationError(f"{field} must not be a reparse point")
    return resolved


def _is_reparse(path: Path) -> bool:
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise MaterializationError(f"cannot inspect path metadata for {path}: {exc}") from exc
    return stat.S_ISLNK(metadata.st_mode) or bool(
        getattr(metadata, "st_file_attributes", 0) & REPARSE_ATTRIBUTE
    )


def _canonical_manifest_bytes(manifest: Mapping[str, Any]) -> bytes:
    projected = dict(manifest)
    projected.pop("manifestSha256", None)
    try:
        return json.dumps(
            projected,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise MaterializationError(f"manifest cannot be canonicalized: {exc}") from exc


def _load_manifest(path: str | Path) -> dict[str, Any]:
    manifest_path = Path(path)
    try:
        raw = manifest_path.read_bytes()
        parsed = json.loads(raw)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise MaterializationError(f"cannot load manifest: {exc}") from exc
    if not isinstance(parsed, dict):
        raise MaterializationError("manifest must be a JSON object")
    if parsed.get("format") != FORMAT:
        raise MaterializationError(f"manifest format must be {FORMAT}")
    if parsed.get("digestAlgorithm") != DIGEST_ALGORITHM:
        raise MaterializationError("manifest digestAlgorithm must be sha256")
    digest = parsed.get("manifestSha256")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise MaterializationError("manifestSha256 must be lowercase SHA-256")
    computed = hashlib.sha256(_canonical_manifest_bytes(parsed)).hexdigest()
    if computed != digest:
        raise MaterializationError(
            f"manifest digest mismatch: recorded {digest}, computed {computed}"
        )
    return parsed


def _require_object_id(value: Any, *, field: str) -> str:
    if not isinstance(value, str) or FULL_OBJECT_ID.fullmatch(value) is None:
        raise MaterializationError(f"{field} must be a lowercase full Git object ID")
    return value


def _require_repository(value: Any, *, field: str) -> str:
    if not isinstance(value, str) or CANONICAL_REPOSITORY.fullmatch(value) is None:
        raise MaterializationError(f"{field} must be an exact canonical HTTPS Git URL")
    return value


def _safe_relative_path(value: Any, *, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise MaterializationError(f"{field} must be a non-empty path")
    if len(value) > 4096 or value != unicodedata.normalize("NFC", value):
        raise MaterializationError(f"{field} is not a canonical portable path: {value!r}")
    if "\\" in value or "\0" in value or ":" in value:
        raise MaterializationError(f"{field} is not a canonical portable path: {value!r}")
    pure = PurePosixPath(value)
    parts = pure.parts
    if pure.is_absolute() or pure.as_posix() != value:
        raise MaterializationError(f"{field} is not a canonical relative path: {value!r}")
    if any(part in {"", ".", ".."} for part in parts):
        raise MaterializationError(f"{field} contains an unsafe segment: {value!r}")
    for part in parts:
        if part[-1:] in {" ", "."} or WINDOWS_DEVICE.fullmatch(part):
            raise MaterializationError(f"{field} contains a non-portable segment: {part!r}")
        if any(ord(character) < 32 or ord(character) == 127 for character in part):
            raise MaterializationError(f"{field} contains a control character: {value!r}")
        if any(character in '<>"|?*' for character in part):
            raise MaterializationError(f"{field} contains a non-portable character: {value!r}")
    return value


def _parse_ls_tree(payload: bytes) -> dict[str, tuple[str, str, int]]:
    inventory: dict[str, tuple[str, str, int]] = {}
    for record in payload.split(b"\0"):
        if not record:
            continue
        try:
            header, raw_path = record.split(b"\t", 1)
            mode, object_type, object_id, raw_size = header.split(b" ", 3)
            path = raw_path.decode("utf-8")
            decoded_mode = mode.decode("ascii")
            decoded_object_id = object_id.decode("ascii")
            size = int(raw_size)
        except (ValueError, UnicodeDecodeError) as exc:
            raise MaterializationError("source Git tree contains an unparsable entry") from exc
        if object_type != b"blob":
            raise MaterializationError(f"source entry is not a blob: {path}")
        if decoded_mode not in ALLOWED_MODES:
            raise MaterializationError(f"source entry has an unsupported mode: {path}")
        if FULL_OBJECT_ID.fullmatch(decoded_object_id) is None or size < 0:
            raise MaterializationError(f"source entry has invalid identity or size: {path}")
        if path in inventory:
            raise MaterializationError(f"source Git tree repeats a path: {path}")
        inventory[path] = (decoded_mode, decoded_object_id, size)
    return inventory


def _validate_symlink_target(
    destination_path: str,
    payload: bytes,
    *,
    allowed_symlinks: Mapping[str, str],
) -> str:
    if destination_path != APPLE_FIXTURE_SYMLINK:
        raise MaterializationError(f"symlink destination is not allowlisted: {destination_path}")
    expected = allowed_symlinks.get(destination_path)
    if expected is None:
        raise MaterializationError(f"undeclared symlink: {destination_path}")
    try:
        target = payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise MaterializationError(f"symlink target is not UTF-8: {destination_path}") from exc
    if target != expected:
        raise MaterializationError(f"symlink target mismatch for {destination_path}: {target!r}")
    if not target or "\\" in target or "\0" in target or ":" in target:
        raise MaterializationError(f"unsafe symlink target for {destination_path}")
    target_path = PurePosixPath(target)
    if target_path.is_absolute():
        raise MaterializationError(f"absolute symlink target for {destination_path}")
    stack = list(PurePosixPath(destination_path).parent.parts)
    for part in target_path.parts:
        if part in {"", "."}:
            continue
        if part == "..":
            if not stack:
                raise MaterializationError(
                    f"symlink target escapes destination root: {destination_path}"
                )
            stack.pop()
        else:
            stack.append(part)
    return target


def _validate_destination_collisions(paths: Iterable[str]) -> None:
    seen: dict[str, str] = {}
    leaves: set[str] = set()
    for path in sorted(paths, key=lambda item: (item.casefold(), item)):
        folded = path.casefold()
        prior = seen.get(folded)
        if prior is not None:
            raise MaterializationError(f"case-insensitive destination collision: {prior}, {path}")
        parts = path.split("/")
        prefix = ""
        for part in parts[:-1]:
            prefix = f"{prefix}/{part}" if prefix else part
            if prefix.casefold() in leaves:
                raise MaterializationError(f"destination leaf is also a parent: {prefix}")
        seen[folded] = path
        leaves.add(folded)


def _validate_existing_prefix(root: Path, relative: str) -> None:
    current = root
    parts = PurePosixPath(relative).parts
    for index, part in enumerate(parts):
        if not current.exists():
            return
        names = {child.name.casefold(): child.name for child in current.iterdir()}
        existing_name = names.get(part.casefold())
        if existing_name is not None and existing_name != part:
            raise MaterializationError(
                f"case collision beneath destination root: {existing_name!r} vs {part!r}"
            )
        current = current / part
        if index == len(parts) - 1:
            return
        if os.path.lexists(current):
            if _is_reparse(current):
                raise MaterializationError(f"destination ancestor is a reparse point: {current}")
            if not current.is_dir():
                raise MaterializationError(f"destination ancestor is not a directory: {current}")


def _same_existing_leaf(path: Path, entry: ManifestEntry, symlink_target: str | None) -> bool:
    if not os.path.lexists(path):
        return False
    metadata = path.lstat()
    if entry.mode == "120000":
        if not stat.S_ISLNK(metadata.st_mode):
            raise MaterializationError(f"destination symlink leaf has wrong type: {path}")
        actual = os.readlink(path)
        if actual != symlink_target:
            raise MaterializationError(f"destination symlink leaf differs: {path}")
        return True
    if stat.S_ISLNK(metadata.st_mode) or bool(
        getattr(metadata, "st_file_attributes", 0) & REPARSE_ATTRIBUTE
    ):
        raise MaterializationError(f"destination regular leaf is a reparse point: {path}")
    if not stat.S_ISREG(metadata.st_mode):
        raise MaterializationError(f"destination regular leaf has wrong type: {path}")
    try:
        existing = path.read_bytes()
    except OSError as exc:
        raise MaterializationError(
            f"cannot verify existing destination leaf {path}: {exc}"
        ) from exc
    if existing != entry.payload:
        raise MaterializationError(f"destination regular leaf differs: {path}")
    return True


def build_plan(
    *,
    manifest_path: str | Path,
    source_repo: str | Path,
    destination_root: str | Path,
    expected_branch: str,
    expected_head: str,
    allowed_symlinks: Mapping[str, str],
) -> MaterializationPlan:
    """Validate every source and destination and return an immutable plan."""

    manifest = _load_manifest(manifest_path)
    source = manifest.get("source")
    destination = manifest.get("destination")
    raw_entries = manifest.get("entries")
    if not isinstance(source, dict) or not isinstance(destination, dict):
        raise MaterializationError("manifest source and destination must be objects")
    if not isinstance(raw_entries, list) or not raw_entries:
        raise MaterializationError("manifest entries must be a non-empty array")

    source_root = _exact_git_root(source_repo, field="source repository root")
    destination_path = _exact_git_root(destination_root, field="destination root")
    source_identity = _require_repository(source.get("repository"), field="source repository")
    destination_identity = _require_repository(
        destination.get("repository"), field="destination repository"
    )
    if source_identity != SOURCE_REPOSITORY:
        raise MaterializationError("manifest source repository must be AstralDeep")
    if destination_identity != DESTINATION_REPOSITORY:
        raise MaterializationError("manifest destination repository must be AstralProjection")
    source_origin = _run_git(source_root, ["remote", "get-url", "origin"]).stdout.decode().strip()
    destination_origin = (
        _run_git(destination_path, ["remote", "get-url", "origin"]).stdout.decode().strip()
    )
    if source_origin != source_identity:
        raise MaterializationError("source origin does not match manifest repository")
    if destination_origin != destination_identity:
        raise MaterializationError("destination origin does not match manifest repository")

    manifest_branch = destination.get("branch")
    if manifest_branch != expected_branch:
        raise MaterializationError("expected branch does not match manifest branch")
    actual_branch = (
        _run_git(destination_path, ["symbolic-ref", "--quiet", "--short", "HEAD"])
        .stdout.decode()
        .strip()
    )
    if actual_branch != expected_branch:
        raise MaterializationError(
            f"destination branch mismatch: expected {expected_branch}, found {actual_branch}"
        )
    expected_head = _require_object_id(expected_head, field="expected destination HEAD")
    actual_head = _run_git(destination_path, ["rev-parse", "HEAD"]).stdout.decode().strip()
    if actual_head != expected_head:
        raise MaterializationError(
            f"destination HEAD mismatch: expected {expected_head}, found {actual_head}"
        )
    legacy = destination.get("legacyBaseline")
    if not isinstance(legacy, dict) or legacy.get("commit") != expected_head:
        raise MaterializationError("destination legacy baseline does not match expected HEAD")

    source_commit = _require_object_id(source.get("commit"), field="source commit")
    source_tree = _require_object_id(source.get("tree"), field="source tree")
    resolved_commit = _run_git(source_root, ["rev-parse", f"{source_commit}^{{commit}}"])
    if resolved_commit.stdout.decode().strip() != source_commit:
        raise MaterializationError("source commit does not resolve to itself")
    actual_tree = _run_git(source_root, ["rev-parse", f"{source_commit}^{{tree}}"])
    if actual_tree.stdout.decode().strip() != source_tree:
        raise MaterializationError("source tree does not match manifest")
    tree_output = _run_git(
        source_root, ["ls-tree", "-r", "-z", "--full-tree", "--long", source_commit]
    )
    inventory = _parse_ls_tree(tree_output.stdout)

    parsed_entries: list[ManifestEntry] = []
    destination_paths: list[str] = []
    source_paths: set[str] = set()
    for index, raw_entry in enumerate(raw_entries):
        if not isinstance(raw_entry, dict):
            raise MaterializationError(f"manifest entry {index} must be an object")
        source_path_value = _safe_relative_path(
            raw_entry.get("sourcePath"), field=f"entries[{index}].sourcePath"
        )
        destination_path_value = _safe_relative_path(
            raw_entry.get("destinationPath"), field=f"entries[{index}].destinationPath"
        )
        if source_path_value in source_paths:
            raise MaterializationError(f"duplicate source path: {source_path_value}")
        source_paths.add(source_path_value)
        mode = raw_entry.get("mode")
        if mode not in ALLOWED_MODES:
            raise MaterializationError(f"unsupported mode for {source_path_value}: {mode!r}")
        blob = _require_object_id(raw_entry.get("blob"), field=f"blob for {source_path_value}")
        size_value = raw_entry.get("bytes")
        if type(size_value) is not int or size_value < 0:
            raise MaterializationError(f"invalid byte count for {source_path_value}")
        tree_tuple = inventory.get(source_path_value)
        if tree_tuple != (mode, blob, size_value):
            raise MaterializationError(f"source Git tuple mismatch: {source_path_value}")
        payload = _run_git(source_root, ["cat-file", "blob", blob]).stdout
        if len(payload) != size_value:
            raise MaterializationError(f"source blob size mismatch: {source_path_value}")
        git_hash = hashlib.sha1(
            f"blob {len(payload)}\0".encode("ascii") + payload,
            usedforsecurity=False,
        ).hexdigest()
        if git_hash != blob:
            raise MaterializationError(f"source blob hash mismatch: {source_path_value}")
        if mode == "120000":
            _validate_symlink_target(
                destination_path_value, payload, allowed_symlinks=allowed_symlinks
            )
        parsed_entries.append(
            ManifestEntry(
                source_path=source_path_value,
                destination_path=destination_path_value,
                mode=mode,
                blob=blob,
                size_bytes=size_value,
                payload=payload,
            )
        )
        destination_paths.append(destination_path_value)

    expected_order = sorted(
        parsed_entries, key=lambda entry: (entry.source_path, entry.destination_path)
    )
    if parsed_entries != expected_order:
        raise MaterializationError("manifest entries are not in canonical order")
    _validate_destination_collisions(destination_paths)
    declared_links = {entry.destination_path for entry in parsed_entries if entry.mode == "120000"}
    if set(allowed_symlinks) != declared_links:
        raise MaterializationError("allowed symlink declarations do not match manifest symlinks")

    for entry in parsed_entries:
        _validate_existing_prefix(destination_path, entry.destination_path)
        target = None
        if entry.mode == "120000":
            target = _validate_symlink_target(
                entry.destination_path, entry.payload, allowed_symlinks=allowed_symlinks
            )
        _same_existing_leaf(destination_path / PurePosixPath(entry.destination_path), entry, target)

    return MaterializationPlan(
        source_repo=source_root,
        destination_root=destination_path,
        source_commit=source_commit,
        source_tree=source_tree,
        manifest_sha256=str(manifest["manifestSha256"]),
        entries=tuple(parsed_entries),
        allowed_symlinks=dict(allowed_symlinks),
    )


def _ensure_parent(root: Path, relative: str) -> Path:
    parent = root
    for part in PurePosixPath(relative).parts[:-1]:
        candidate = parent / part
        if os.path.lexists(candidate):
            if _is_reparse(candidate) or not candidate.is_dir():
                raise MaterializationError(f"unsafe destination ancestor appeared: {candidate}")
        else:
            try:
                candidate.mkdir()
            except FileExistsError:
                if _is_reparse(candidate) or not candidate.is_dir():
                    raise MaterializationError(f"unsafe destination ancestor appeared: {candidate}")
            except OSError as exc:
                raise MaterializationError(f"cannot create directory {candidate}: {exc}") from exc
            if _is_reparse(candidate) or not candidate.is_dir():
                raise MaterializationError(f"unsafe destination ancestor appeared: {candidate}")
        parent = candidate
    return parent


def _write_regular_atomically(path: Path, entry: ManifestEntry) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=".astral-extract-", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(entry.payload)
            handle.flush()
            os.fsync(handle.fileno())
        if entry.mode == "100755" and os.name != "nt":
            temporary.chmod(0o755)
        try:
            os.link(temporary, path, follow_symlinks=False)
        except FileExistsError:
            if not _same_existing_leaf(path, entry, None):
                raise MaterializationError(f"destination appeared during write: {path}")
        except OSError as exc:
            raise MaterializationError(f"cannot atomically create {path}: {exc}") from exc
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError as exc:
            raise MaterializationError(f"cannot remove temporary file {temporary}: {exc}") from exc


def materialize(plan: MaterializationPlan) -> dict[str, int | str]:
    """Materialize a fully validated plan and verify every resulting leaf."""

    created = 0
    resumed = 0
    for entry in plan.entries:
        _ensure_parent(plan.destination_root, entry.destination_path)
        destination = plan.destination_root / PurePosixPath(entry.destination_path)
        target: str | None = None
        if entry.mode == "120000":
            target = _validate_symlink_target(
                entry.destination_path,
                entry.payload,
                allowed_symlinks=plan.allowed_symlinks,
            )
        if _same_existing_leaf(destination, entry, target):
            resumed += 1
            continue
        if entry.mode == "120000":
            try:
                os.symlink(target, destination, target_is_directory=True)
            except FileExistsError:
                if not _same_existing_leaf(destination, entry, target):
                    raise MaterializationError(
                        f"destination appeared during symlink creation: {destination}"
                    )
            except OSError as exc:
                raise MaterializationError(
                    f"cannot create real destination symlink {destination}: {exc}"
                ) from exc
        else:
            _write_regular_atomically(destination, entry)
        if not _same_existing_leaf(destination, entry, target):
            raise MaterializationError(f"destination verification failed: {destination}")
        created += 1
    return {
        "created": created,
        "resumed": resumed,
        "entries": len(plan.entries),
        "manifestSha256": plan.manifest_sha256,
    }


def stage_entries(plan: MaterializationPlan) -> None:
    """Stage only manifest destinations and enforce their Git index modes."""

    pathspec = b"\0".join(entry.destination_path.encode("utf-8") for entry in plan.entries) + b"\0"
    _run_git(
        plan.destination_root,
        ["add", "--pathspec-from-file=-", "--pathspec-file-nul"],
        input_bytes=pathspec,
    )
    executables = [entry.destination_path for entry in plan.entries if entry.mode == "100755"]
    for executable in executables:
        _run_git(plan.destination_root, ["update-index", "--chmod=+x", "--", executable])
    staged = _run_git(plan.destination_root, ["ls-files", "--stage", "-z"]).stdout
    index: dict[str, tuple[str, str]] = {}
    for record in staged.split(b"\0"):
        if not record:
            continue
        header, raw_path = record.split(b"\t", 1)
        mode, blob, _stage = header.decode("ascii").split(" ")
        index[raw_path.decode("utf-8")] = (mode, blob)
    for entry in plan.entries:
        expected_mode = entry.mode
        actual = index.get(entry.destination_path)
        if actual != (expected_mode, entry.blob):
            raise MaterializationError(
                f"staged Git tuple mismatch for {entry.destination_path}: {actual!r}"
            )


def _parse_symlink(value: str) -> tuple[str, str]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("allowed symlink must be DESTINATION=TARGET")
    destination, target = value.split("=", 1)
    try:
        destination = _safe_relative_path(destination, field="allowed symlink destination")
    except MaterializationError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc
    if not target:
        raise argparse.ArgumentTypeError("allowed symlink target must not be empty")
    return destination, target


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--source-repo", required=True)
    parser.add_argument("--destination-root", required=True)
    parser.add_argument("--expected-branch", required=True)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument(
        "--allow-symlink",
        action="append",
        default=[],
        type=_parse_symlink,
        metavar="DESTINATION=TARGET",
    )
    parser.add_argument("--stage", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    allowed_symlinks = dict(arguments.allow_symlink)
    if len(allowed_symlinks) != len(arguments.allow_symlink):
        print("materialize_extraction: duplicate allowed symlink", file=sys.stderr)
        return 2
    try:
        plan = build_plan(
            manifest_path=arguments.manifest,
            source_repo=arguments.source_repo,
            destination_root=arguments.destination_root,
            expected_branch=arguments.expected_branch,
            expected_head=arguments.expected_head,
            allowed_symlinks=allowed_symlinks,
        )
        result = materialize(plan)
        if arguments.stage:
            stage_entries(plan)
    except MaterializationError as exc:
        print(f"materialize_extraction: {exc}", file=sys.stderr)
        return 1
    result["staged"] = bool(arguments.stage)
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
