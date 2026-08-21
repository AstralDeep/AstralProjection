from __future__ import annotations

import importlib.util
import json
import os
import stat
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

MODULE_PATH = Path(__file__).resolve().parents[2] / "scripts/migration/materialize_extraction.py"
SPEC = importlib.util.spec_from_file_location("materialize_extraction", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
materializer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = materializer
SPEC.loader.exec_module(materializer)


def _git(repo: Path, *arguments: str, input_bytes: bytes | None = None) -> bytes:
    process = subprocess.run(
        ["git", "-C", os.fspath(repo), *arguments],
        input=input_bytes,
        capture_output=True,
        check=False,
    )
    assert process.returncode == 0, process.stderr.decode("utf-8", "replace")
    return process.stdout


def _repo(path: Path, *, branch: str, origin: str) -> None:
    path.mkdir()
    _git(path, "init", "-b", branch)
    _git(path, "config", "user.email", "tests@example.invalid")
    _git(path, "config", "user.name", "Projection Tests")
    _git(path, "remote", "add", "origin", origin)


def _commit_file(repo: Path, relative: str, payload: bytes) -> tuple[str, str, str]:
    destination = repo / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(payload)
    _git(repo, "add", "--", relative)
    _git(repo, "commit", "-m", "fixture")
    commit = _git(repo, "rev-parse", "HEAD").decode().strip()
    tree = _git(repo, "rev-parse", "HEAD^{tree}").decode().strip()
    blob = _git(repo, "rev-parse", f"HEAD:{relative}").decode().strip()
    return commit, tree, blob


def _manifest(
    *,
    source_commit: str,
    source_tree: str,
    destination_commit: str,
    blob: str,
    payload: bytes,
) -> dict[str, object]:
    result: dict[str, object] = {
        "format": materializer.FORMAT,
        "digestAlgorithm": materializer.DIGEST_ALGORITHM,
        "source": {
            "repository": "https://github.com/AstralDeep/AstralDeep.git",
            "commit": source_commit,
            "tree": source_tree,
        },
        "destination": {
            "repository": "https://github.com/AstralDeep/AstralProjection.git",
            "branch": "codex/test",
            "legacyBaseline": {
                "sourceRef": "refs/heads/master",
                "commit": destination_commit,
                "observedAt": "2026-08-13T00:00:00Z",
            },
        },
        "selectionRoots": ["source/item.txt"],
        "entries": [
            {
                "sourcePath": "source/item.txt",
                "destinationPath": "imported/item.txt",
                "mode": "100644",
                "blob": blob,
                "bytes": len(payload),
            }
        ],
    }
    result["manifestSha256"] = materializer.hashlib.sha256(
        materializer._canonical_manifest_bytes(result)
    ).hexdigest()
    return result


def _write_manifest(path: Path, manifest: dict[str, object]) -> None:
    path.write_text(json.dumps(manifest), encoding="utf-8")


def _redigest(manifest: dict[str, object]) -> None:
    manifest["manifestSha256"] = materializer.hashlib.sha256(
        materializer._canonical_manifest_bytes(manifest)
    ).hexdigest()


def _plan_arguments(repositories) -> dict[str, object]:
    source, destination, manifest_path, destination_commit, _ = repositories
    return {
        "manifest_path": manifest_path,
        "source_repo": source,
        "destination_root": destination,
        "expected_branch": "codex/test",
        "expected_head": destination_commit,
        "allowed_symlinks": {},
    }


def _manifest_entry(
    *,
    destination_path: str,
    payload: bytes,
    mode: str = "100644",
    blob: str = "0" * 40,
) -> materializer.ManifestEntry:
    return materializer.ManifestEntry(
        source_path="source/item",
        destination_path=destination_path,
        mode=mode,
        blob=blob,
        size_bytes=len(payload),
        payload=payload,
    )


@pytest.fixture
def repositories(tmp_path: Path):
    source = tmp_path / "source"
    destination = tmp_path / "destination"
    _repo(
        source,
        branch="main",
        origin="https://github.com/AstralDeep/AstralDeep.git",
    )
    source_payload = b"immutable source payload\n"
    source_commit, source_tree, blob = _commit_file(source, "source/item.txt", source_payload)
    _repo(
        destination,
        branch="codex/test",
        origin="https://github.com/AstralDeep/AstralProjection.git",
    )
    destination_commit, _, _ = _commit_file(destination, "legacy.txt", b"legacy\n")
    manifest = _manifest(
        source_commit=source_commit,
        source_tree=source_tree,
        destination_commit=destination_commit,
        blob=blob,
        payload=source_payload,
    )
    manifest_path = tmp_path / "manifest.json"
    _write_manifest(manifest_path, manifest)
    return source, destination, manifest_path, destination_commit, source_payload


def test_build_plan_materializes_only_immutable_git_blob(repositories):
    source, destination, manifest_path, destination_commit, payload = repositories
    (source / "source/item.txt").write_bytes(b"uncommitted working tree bytes\n")

    plan = materializer.build_plan(
        manifest_path=manifest_path,
        source_repo=source,
        destination_root=destination,
        expected_branch="codex/test",
        expected_head=destination_commit,
        allowed_symlinks={},
    )
    result = materializer.materialize(plan)

    assert (destination / "imported/item.txt").read_bytes() == payload
    assert result == {
        "created": 1,
        "resumed": 0,
        "entries": 1,
        "manifestSha256": plan.manifest_sha256,
    }


def test_materialization_is_exactly_resumable(repositories):
    source, destination, manifest_path, destination_commit, payload = repositories
    plan = materializer.build_plan(
        manifest_path=manifest_path,
        source_repo=source,
        destination_root=destination,
        expected_branch="codex/test",
        expected_head=destination_commit,
        allowed_symlinks={},
    )
    (destination / "imported").mkdir()
    (destination / "imported/item.txt").write_bytes(payload)

    result = materializer.materialize(plan)

    assert result["created"] == 0
    assert result["resumed"] == 1


def test_build_plan_rejects_different_existing_leaf(repositories):
    source, destination, manifest_path, destination_commit, _ = repositories
    (destination / "imported").mkdir()
    (destination / "imported/item.txt").write_bytes(b"different")

    with pytest.raises(materializer.MaterializationError, match="leaf differs"):
        materializer.build_plan(
            manifest_path=manifest_path,
            source_repo=source,
            destination_root=destination,
            expected_branch="codex/test",
            expected_head=destination_commit,
            allowed_symlinks={},
        )


def test_build_plan_rejects_manifest_digest_tampering(repositories):
    source, destination, manifest_path, destination_commit, _ = repositories
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["entries"][0]["bytes"] += 1
    _write_manifest(manifest_path, manifest)

    with pytest.raises(materializer.MaterializationError, match="digest mismatch"):
        materializer.build_plan(
            manifest_path=manifest_path,
            source_repo=source,
            destination_root=destination,
            expected_branch="codex/test",
            expected_head=destination_commit,
            allowed_symlinks={},
        )


def test_build_plan_rejects_git_tuple_mismatch_after_valid_redigest(repositories):
    source, destination, manifest_path, destination_commit, _ = repositories
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["entries"][0]["bytes"] += 1
    manifest["manifestSha256"] = materializer.hashlib.sha256(
        materializer._canonical_manifest_bytes(manifest)
    ).hexdigest()
    _write_manifest(manifest_path, manifest)

    with pytest.raises(materializer.MaterializationError, match="Git tuple mismatch"):
        materializer.build_plan(
            manifest_path=manifest_path,
            source_repo=source,
            destination_root=destination,
            expected_branch="codex/test",
            expected_head=destination_commit,
            allowed_symlinks={},
        )


@pytest.mark.parametrize(
    "path",
    [
        "../escape",
        "/absolute",
        "a//b",
        "a\\b",
        "C:/drive",
        "a/NUL",
        "a/trailing.",
        "a/trailing ",
    ],
)
def test_portable_path_validation_fails_closed(path: str):
    with pytest.raises(materializer.MaterializationError):
        materializer._safe_relative_path(path, field="test path")


@pytest.mark.parametrize("path", ["a", "a/b.txt", ".github/workflows/ci.yml"])
def test_portable_path_validation_accepts_canonical_paths(path: str):
    assert materializer._safe_relative_path(path, field="test path") == path


def test_destination_collision_check_rejects_case_and_prefix_collisions():
    with pytest.raises(materializer.MaterializationError, match="case-insensitive"):
        materializer._validate_destination_collisions(["A/file", "a/file"])
    with pytest.raises(materializer.MaterializationError, match="also a parent"):
        materializer._validate_destination_collisions(["a", "a/file"])


def test_declared_symlink_is_confined_and_exact(tmp_path: Path):
    destination = materializer.APPLE_FIXTURE_SYMLINK
    target = "../../../../../backend/tests/fixtures/voice_065"
    payload = target.encode()
    assert (
        materializer._validate_symlink_target(
            destination, payload, allowed_symlinks={destination: target}
        )
        == target
    )
    with pytest.raises(materializer.MaterializationError, match="escapes"):
        materializer._validate_symlink_target(
            destination,
            b"../../../../../../outside",
            allowed_symlinks={destination: "../../../../../../outside"},
        )
    with pytest.raises(materializer.MaterializationError, match="undeclared"):
        materializer._validate_symlink_target(destination, payload, allowed_symlinks={})
    with pytest.raises(materializer.MaterializationError, match="mismatch"):
        materializer._validate_symlink_target(
            destination, payload, allowed_symlinks={destination: "../different"}
        )

    with pytest.raises(materializer.MaterializationError, match="not allowlisted"):
        materializer._validate_symlink_target(
            "some/other/link", b"target", allowed_symlinks={"some/other/link": "target"}
        )


def test_stage_entries_preserves_existing_index_and_enforces_executable(tmp_path: Path):
    destination = tmp_path / "destination"
    _repo(
        destination,
        branch="codex/test",
        origin="https://github.com/AstralDeep/AstralProjection.git",
    )
    commit, tree, _ = _commit_file(destination, "legacy.txt", b"legacy\n")
    payload = b"#!/bin/sh\nexit 0\n"
    blob = _git(destination, "hash-object", "-w", "--stdin", input_bytes=payload).decode().strip()
    entry = materializer.ManifestEntry(
        source_path="script.sh",
        destination_path="scripts/script.sh",
        mode="100755",
        blob=blob,
        size_bytes=len(payload),
        payload=payload,
    )
    plan = materializer.MaterializationPlan(
        source_repo=destination,
        destination_root=destination,
        source_commit=commit,
        source_tree=tree,
        manifest_sha256="0" * 64,
        entries=(entry,),
        allowed_symlinks={},
    )
    materializer.materialize(plan)

    materializer.stage_entries(plan)

    index = _git(destination, "ls-files", "--stage").decode()
    assert f"100755 {blob} 0\tscripts/script.sh" in index
    assert "legacy.txt" in index


def test_cli_reports_duplicate_symlink_declaration(capsys):
    result = materializer.main(
        [
            "--manifest",
            "manifest.json",
            "--source-repo",
            ".",
            "--destination-root",
            ".",
            "--expected-branch",
            "codex/test",
            "--expected-head",
            "0" * 40,
            "--allow-symlink",
            "a=b",
            "--allow-symlink",
            "a=b",
        ]
    )
    assert result == 2
    assert "duplicate allowed symlink" in capsys.readouterr().err


def test_run_git_converts_failures_and_can_return_them(tmp_path: Path):
    with pytest.raises(materializer.MaterializationError, match="Git command failed"):
        materializer._run_git(tmp_path, ["not-a-real-command"])

    result = materializer._run_git(tmp_path, ["not-a-real-command"], check=False)
    assert result.returncode != 0


def test_exact_git_root_rejects_missing_file_and_nested_root(tmp_path: Path):
    with pytest.raises(materializer.MaterializationError, match="does not resolve"):
        materializer._exact_git_root(tmp_path / "missing", field="fixture")

    regular = tmp_path / "regular"
    regular.write_text("not a directory", encoding="utf-8")
    with pytest.raises(materializer.MaterializationError, match="not a directory"):
        materializer._exact_git_root(regular, field="fixture")

    repository = tmp_path / "repo"
    _repo(repository, branch="main", origin=materializer.SOURCE_REPOSITORY)
    nested = repository / "nested"
    nested.mkdir()
    with pytest.raises(materializer.MaterializationError, match="exact Git worktree root"):
        materializer._exact_git_root(nested, field="fixture")


def test_exact_git_root_rejects_alias_unresolvable_git_root_and_reparse(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    repository = tmp_path / "repo"
    _repo(repository, branch="main", origin=materializer.SOURCE_REPOSITORY)

    alias = tmp_path / "alias"
    try:
        alias.symlink_to(repository, target_is_directory=True)
    except OSError as exc:
        pytest.skip(f"symlink creation unavailable: {exc}")
    with pytest.raises(materializer.MaterializationError, match="must not traverse"):
        materializer._exact_git_root(alias, field="fixture")

    completed = subprocess.CompletedProcess(
        args=["git"], returncode=0, stdout=b"Z:/missing-git-root\n", stderr=b""
    )
    monkeypatch.setattr(materializer, "_run_git", lambda *_args, **_kwargs: completed)
    with pytest.raises(materializer.MaterializationError, match="Git root does not resolve"):
        materializer._exact_git_root(repository, field="fixture")

    monkeypatch.setattr(
        materializer,
        "_run_git",
        lambda *_args, **_kwargs: subprocess.CompletedProcess(
            args=["git"],
            returncode=0,
            stdout=(os.fspath(repository.resolve()) + "\n").encode(),
            stderr=b"",
        ),
    )
    monkeypatch.setattr(materializer, "_is_reparse", lambda _path: True)
    with pytest.raises(materializer.MaterializationError, match="reparse point"):
        materializer._exact_git_root(repository, field="fixture")


def test_is_reparse_handles_symlink_attribute_and_inspection_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    target = tmp_path / "target"
    target.write_text("x", encoding="utf-8")

    monkeypatch.setattr(
        Path,
        "lstat",
        lambda _self: SimpleNamespace(st_mode=stat.S_IFLNK, st_file_attributes=0),
    )
    assert materializer._is_reparse(target)

    monkeypatch.setattr(
        Path,
        "lstat",
        lambda _self: SimpleNamespace(
            st_mode=stat.S_IFREG, st_file_attributes=materializer.REPARSE_ATTRIBUTE
        ),
    )
    assert materializer._is_reparse(target)

    def denied(_self):
        raise OSError("denied")

    monkeypatch.setattr(Path, "lstat", denied)
    with pytest.raises(materializer.MaterializationError, match="cannot inspect"):
        materializer._is_reparse(target)


def test_canonical_manifest_bytes_rejects_non_json_values():
    with pytest.raises(materializer.MaterializationError, match="cannot be canonicalized"):
        materializer._canonical_manifest_bytes({"bad": object()})
    with pytest.raises(materializer.MaterializationError, match="cannot be canonicalized"):
        materializer._canonical_manifest_bytes({"bad": float("nan")})


@pytest.mark.parametrize(
    ("payload", "message"),
    [
        (b"{", "cannot load manifest"),
        (b"\xff", "cannot load manifest"),
        (b"[]", "JSON object"),
        (b'{"format":"wrong"}', "manifest format"),
        (
            json.dumps({"format": materializer.FORMAT, "digestAlgorithm": "sha512"}).encode(),
            "digestAlgorithm",
        ),
        (
            json.dumps(
                {
                    "format": materializer.FORMAT,
                    "digestAlgorithm": materializer.DIGEST_ALGORITHM,
                    "manifestSha256": "BAD",
                }
            ).encode(),
            "lowercase SHA-256",
        ),
    ],
)
def test_load_manifest_rejects_malformed_documents(tmp_path: Path, payload: bytes, message: str):
    path = tmp_path / "manifest.json"
    path.write_bytes(payload)
    with pytest.raises(materializer.MaterializationError, match=message):
        materializer._load_manifest(path)


def test_load_manifest_rejects_missing_document(tmp_path: Path):
    with pytest.raises(materializer.MaterializationError, match="cannot load manifest"):
        materializer._load_manifest(tmp_path / "missing.json")


@pytest.mark.parametrize("value", [None, "ABC", "0" * 39, "g" * 40])
def test_object_id_validation_rejects_noncanonical_values(value):
    with pytest.raises(materializer.MaterializationError, match="full Git object ID"):
        materializer._require_object_id(value, field="fixture")


@pytest.mark.parametrize(
    "value",
    [None, "git@github.com:AstralDeep/AstralDeep.git", "https://example.com/repo.git"],
)
def test_repository_validation_rejects_noncanonical_values(value):
    with pytest.raises(materializer.MaterializationError, match="canonical HTTPS"):
        materializer._require_repository(value, field="fixture")


@pytest.mark.parametrize(
    "path",
    ["a/control\x01", "a/delete\x7f", "a/<bad>", "a/question?", "e\u0301.txt", "a" * 4097],
)
def test_portable_path_validation_rejects_controls_unicode_and_forbidden_chars(path: str):
    with pytest.raises(materializer.MaterializationError):
        materializer._safe_relative_path(path, field="fixture")


@pytest.mark.parametrize(
    "payload",
    [
        b"bad-record\0",
        b"100644 blob nothex 1\tpath\0",
        b"100644 tree " + b"0" * 40 + b" 1\tpath\0",
        b"100664 blob " + b"0" * 40 + b" 1\tpath\0",
        b"100644 blob " + b"0" * 40 + b" -1\tpath\0",
        b"100644 blob " + b"0" * 40 + b" 1\t\xff\0",
    ],
)
def test_parse_ls_tree_rejects_malformed_records(payload: bytes):
    with pytest.raises(materializer.MaterializationError):
        materializer._parse_ls_tree(payload)


def test_parse_ls_tree_rejects_duplicate_paths():
    record = b"100644 blob " + b"0" * 40 + b" 1\tpath\0"
    with pytest.raises(materializer.MaterializationError, match="repeats"):
        materializer._parse_ls_tree(record + record)


@pytest.mark.parametrize(
    ("field", "replacement", "message"),
    [
        ("source", [], "source and destination"),
        ("destination", [], "source and destination"),
        ("entries", [], "non-empty array"),
        ("entries", "wrong", "non-empty array"),
    ],
)
def test_build_plan_rejects_wrong_manifest_container_types(
    repositories, field: str, replacement, message: str
):
    manifest_path = repositories[2]
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest[field] = replacement
    _redigest(manifest)
    _write_manifest(manifest_path, manifest)

    with pytest.raises(materializer.MaterializationError, match=message):
        materializer.build_plan(**_plan_arguments(repositories))


@pytest.mark.parametrize("which", ["source", "destination"])
def test_build_plan_rejects_origin_mismatch(repositories, which: str):
    source, destination, *_ = repositories
    repository = source if which == "source" else destination
    _git(repository, "remote", "set-url", "origin", "https://github.com/AstralDeep/Wrong.git")

    with pytest.raises(materializer.MaterializationError, match=f"{which} origin"):
        materializer.build_plan(**_plan_arguments(repositories))


@pytest.mark.parametrize(
    ("which", "repository", "message"),
    [
        ("source", "https://github.com/AstralDeep/AstralPlane.git", "must be AstralDeep"),
        (
            "destination",
            "https://github.com/AstralDeep/AstralPlane.git",
            "must be AstralProjection",
        ),
    ],
)
def test_build_plan_rejects_wrong_canonical_repository_roles(
    repositories, which: str, repository: str, message: str
):
    source, destination, manifest_path, *_ = repositories
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest[which]["repository"] = repository
    _redigest(manifest)
    _write_manifest(manifest_path, manifest)
    _git(source if which == "source" else destination, "remote", "set-url", "origin", repository)

    with pytest.raises(materializer.MaterializationError, match=message):
        materializer.build_plan(**_plan_arguments(repositories))


def test_build_plan_rejects_expected_and_actual_branch_mismatches(repositories):
    arguments = _plan_arguments(repositories)
    arguments["expected_branch"] = "codex/other"
    with pytest.raises(materializer.MaterializationError, match="expected branch"):
        materializer.build_plan(**arguments)

    destination = repositories[1]
    _git(destination, "switch", "-c", "codex/other")
    with pytest.raises(materializer.MaterializationError, match="destination branch mismatch"):
        materializer.build_plan(**_plan_arguments(repositories))


def test_build_plan_rejects_invalid_actual_and_legacy_head(repositories):
    arguments = _plan_arguments(repositories)
    arguments["expected_head"] = "bad"
    with pytest.raises(materializer.MaterializationError, match="full Git object ID"):
        materializer.build_plan(**arguments)

    destination = repositories[1]
    _commit_file(destination, "new.txt", b"new\n")
    with pytest.raises(materializer.MaterializationError, match="destination HEAD mismatch"):
        materializer.build_plan(**_plan_arguments(repositories))


def test_build_plan_rejects_legacy_baseline_mismatch(repositories):
    manifest_path = repositories[2]
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["destination"]["legacyBaseline"]["commit"] = "0" * 40
    _redigest(manifest)
    _write_manifest(manifest_path, manifest)

    with pytest.raises(materializer.MaterializationError, match="legacy baseline"):
        materializer.build_plan(**_plan_arguments(repositories))


def test_build_plan_rejects_invalid_source_commit_and_tree(repositories):
    manifest_path = repositories[2]
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["source"]["commit"] = "bad"
    _redigest(manifest)
    _write_manifest(manifest_path, manifest)
    with pytest.raises(materializer.MaterializationError, match="source commit"):
        materializer.build_plan(**_plan_arguments(repositories))

    manifest = json.loads(repositories[2].read_text(encoding="utf-8"))
    manifest["source"]["commit"] = _git(repositories[0], "rev-parse", "HEAD").decode().strip()
    manifest["source"]["tree"] = "0" * 40
    _redigest(manifest)
    _write_manifest(manifest_path, manifest)
    with pytest.raises(materializer.MaterializationError, match="source tree"):
        materializer.build_plan(**_plan_arguments(repositories))


def test_build_plan_rejects_commit_that_resolves_to_another_object(repositories):
    source, _, manifest_path, *_ = repositories
    _git(source, "tag", "-a", "fixture-tag", "-m", "fixture tag")
    tag_object = _git(source, "rev-parse", "fixture-tag").decode().strip()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["source"]["commit"] = tag_object
    _redigest(manifest)
    _write_manifest(manifest_path, manifest)

    with pytest.raises(materializer.MaterializationError, match="does not resolve to itself"):
        materializer.build_plan(**_plan_arguments(repositories))


@pytest.mark.parametrize(
    ("mutation", "message"),
    [
        (lambda entry: "wrong", "must be an object"),
        (lambda entry: {**entry, "mode": "160000"}, "unsupported mode"),
        (lambda entry: {**entry, "blob": "bad"}, "full Git object ID"),
        (lambda entry: {**entry, "bytes": True}, "invalid byte count"),
        (lambda entry: {**entry, "bytes": -1}, "invalid byte count"),
    ],
)
def test_build_plan_rejects_malformed_entries(repositories, mutation, message: str):
    manifest_path = repositories[2]
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["entries"][0] = mutation(manifest["entries"][0])
    _redigest(manifest)
    _write_manifest(manifest_path, manifest)

    with pytest.raises(materializer.MaterializationError, match=message):
        materializer.build_plan(**_plan_arguments(repositories))


def test_build_plan_rejects_duplicate_source_path(repositories):
    manifest_path = repositories[2]
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    duplicate = dict(manifest["entries"][0])
    duplicate["destinationPath"] = "other/item.txt"
    manifest["entries"].append(duplicate)
    _redigest(manifest)
    _write_manifest(manifest_path, manifest)

    with pytest.raises(materializer.MaterializationError, match="duplicate source path"):
        materializer.build_plan(**_plan_arguments(repositories))


def test_build_plan_rejects_noncanonical_entry_order(repositories):
    source, _, manifest_path, *_ = repositories
    second = source / "source/another.txt"
    second.write_bytes(b"another\n")
    _git(source, "add", "--", "source/another.txt")
    _git(source, "commit", "-m", "second fixture")
    commit = _git(source, "rev-parse", "HEAD").decode().strip()
    tree = _git(source, "rev-parse", "HEAD^{tree}").decode().strip()
    first_blob = _git(source, "rev-parse", "HEAD:source/item.txt").decode().strip()
    second_blob = _git(source, "rev-parse", "HEAD:source/another.txt").decode().strip()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["source"].update(commit=commit, tree=tree)
    original = manifest["entries"][0]
    original["blob"] = first_blob
    another = {
        "sourcePath": "source/another.txt",
        "destinationPath": "imported/another.txt",
        "mode": "100644",
        "blob": second_blob,
        "bytes": len(b"another\n"),
    }
    manifest["entries"] = [original, another]
    _redigest(manifest)
    _write_manifest(manifest_path, manifest)

    with pytest.raises(materializer.MaterializationError, match="canonical order"):
        materializer.build_plan(**_plan_arguments(repositories))


def test_build_plan_rejects_extra_symlink_declaration(repositories):
    arguments = _plan_arguments(repositories)
    arguments["allowed_symlinks"] = {materializer.APPLE_FIXTURE_SYMLINK: "target"}
    with pytest.raises(materializer.MaterializationError, match="declarations"):
        materializer.build_plan(**arguments)


def test_build_plan_rejects_blob_size_and_hash_mismatch(
    repositories, monkeypatch: pytest.MonkeyPatch
):
    original = materializer._run_git

    def shorter(repo, arguments, **kwargs):
        result = original(repo, arguments, **kwargs)
        if arguments[:2] == ["cat-file", "blob"]:
            return subprocess.CompletedProcess(
                args=result.args,
                returncode=0,
                stdout=result.stdout[:-1],
                stderr=b"",
            )
        return result

    monkeypatch.setattr(materializer, "_run_git", shorter)
    with pytest.raises(materializer.MaterializationError, match="blob size mismatch"):
        materializer.build_plan(**_plan_arguments(repositories))

    def different(repo, arguments, **kwargs):
        result = original(repo, arguments, **kwargs)
        if arguments[:2] == ["cat-file", "blob"]:
            return subprocess.CompletedProcess(
                args=result.args,
                returncode=0,
                stdout=b"X" + result.stdout[1:],
                stderr=b"",
            )
        return result

    monkeypatch.setattr(materializer, "_run_git", different)
    with pytest.raises(materializer.MaterializationError, match="blob hash mismatch"):
        materializer.build_plan(**_plan_arguments(repositories))


@pytest.mark.parametrize(
    ("payload", "expected", "message"),
    [
        (b"\xff", "target", "not UTF-8"),
        (b"", "", "unsafe symlink target"),
        (b"a\\b", "a\\b", "unsafe symlink target"),
        (b"C:/drive", "C:/drive", "unsafe symlink target"),
        (b"/absolute", "/absolute", "absolute symlink target"),
    ],
)
def test_symlink_target_validation_rejects_malformed_targets(
    payload: bytes, expected: str, message: str
):
    with pytest.raises(materializer.MaterializationError, match=message):
        materializer._validate_symlink_target(
            materializer.APPLE_FIXTURE_SYMLINK,
            payload,
            allowed_symlinks={materializer.APPLE_FIXTURE_SYMLINK: expected},
        )


def test_existing_prefix_rejects_case_collision_file_and_reparse(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    root = tmp_path / "root"
    root.mkdir()
    imported = root / "imported"
    imported.mkdir()
    (imported / "ITEM.txt").write_text("x", encoding="utf-8")
    with pytest.raises(materializer.MaterializationError, match="case collision"):
        materializer._validate_existing_prefix(root, "imported/item.txt")

    obstacle_root = tmp_path / "obstacle"
    obstacle_root.mkdir()
    (obstacle_root / "parent").write_text("file", encoding="utf-8")
    with pytest.raises(materializer.MaterializationError, match="not a directory"):
        materializer._validate_existing_prefix(obstacle_root, "parent/item.txt")

    reparse_root = tmp_path / "reparse"
    reparse_root.mkdir()
    (reparse_root / "parent").mkdir()
    monkeypatch.setattr(
        materializer,
        "_is_reparse",
        lambda path: path.name == "parent",
    )
    with pytest.raises(materializer.MaterializationError, match="reparse point"):
        materializer._validate_existing_prefix(reparse_root, "parent/item.txt")


def test_same_existing_leaf_rejects_wrong_types_content_and_read_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    directory = tmp_path / "directory"
    directory.mkdir()
    entry = _manifest_entry(destination_path="directory", payload=b"x")
    with pytest.raises(materializer.MaterializationError, match="wrong type"):
        materializer._same_existing_leaf(directory, entry, None)

    different = tmp_path / "different"
    different.write_bytes(b"different")
    entry = _manifest_entry(destination_path="different", payload=b"expected")
    with pytest.raises(materializer.MaterializationError, match="leaf differs"):
        materializer._same_existing_leaf(different, entry, None)

    unreadable = tmp_path / "unreadable"
    unreadable.write_bytes(b"expected")
    original_read_bytes = Path.read_bytes

    def denied(path: Path):
        if path == unreadable:
            raise OSError("denied")
        return original_read_bytes(path)

    monkeypatch.setattr(Path, "read_bytes", denied)
    with pytest.raises(materializer.MaterializationError, match="cannot verify"):
        materializer._same_existing_leaf(unreadable, entry, None)


def test_same_existing_leaf_rejects_reparse_regular_and_wrong_symlink(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    regular = tmp_path / "regular"
    regular.write_bytes(b"expected")
    entry = _manifest_entry(destination_path="regular", payload=b"expected")
    original_lstat = Path.lstat

    def reparse_lstat(path: Path):
        metadata = original_lstat(path)
        if path == regular:
            return SimpleNamespace(
                st_mode=metadata.st_mode,
                st_file_attributes=materializer.REPARSE_ATTRIBUTE,
            )
        return metadata

    monkeypatch.setattr(Path, "lstat", reparse_lstat)
    with pytest.raises(materializer.MaterializationError, match="reparse point"):
        materializer._same_existing_leaf(regular, entry, None)


def _symlink_plan(root: Path, target: str) -> materializer.MaterializationPlan:
    payload = target.encode("utf-8")
    entry = _manifest_entry(
        destination_path=materializer.APPLE_FIXTURE_SYMLINK,
        payload=payload,
        mode="120000",
    )
    return materializer.MaterializationPlan(
        source_repo=root,
        destination_root=root,
        source_commit="0" * 40,
        source_tree="0" * 40,
        manifest_sha256="1" * 64,
        entries=(entry,),
        allowed_symlinks={materializer.APPLE_FIXTURE_SYMLINK: target},
    )


def test_materialize_creates_real_confined_symlink_and_resumes_without_dereferencing(
    tmp_path: Path,
):
    target = "../../../../../backend/tests/fixtures/voice_065"
    plan = _symlink_plan(tmp_path, target)

    try:
        result = materializer.materialize(plan)
    except materializer.MaterializationError as exc:
        if "cannot create real destination symlink" in str(exc):
            pytest.skip(f"symlink creation unavailable: {exc}")
        raise

    link = tmp_path.joinpath(*materializer.PurePosixPath(materializer.APPLE_FIXTURE_SYMLINK).parts)
    assert link.is_symlink()
    assert os.readlink(link) == target
    assert not link.exists()
    assert result["created"] == 1
    assert materializer.materialize(plan)["resumed"] == 1


def test_same_existing_symlink_rejects_wrong_type_and_target(tmp_path: Path):
    target = "../../../../../backend/tests/fixtures/voice_065"
    entry = _symlink_plan(tmp_path, target).entries[0]
    leaf = tmp_path / "leaf"
    leaf.write_bytes(target.encode())
    with pytest.raises(materializer.MaterializationError, match="wrong type"):
        materializer._same_existing_leaf(leaf, entry, target)

    leaf.unlink()
    try:
        leaf.symlink_to("wrong", target_is_directory=True)
    except OSError as exc:
        pytest.skip(f"symlink creation unavailable: {exc}")
    with pytest.raises(materializer.MaterializationError, match="symlink leaf differs"):
        materializer._same_existing_leaf(leaf, entry, target)


def test_ensure_parent_rejects_existing_file_reparse_and_mkdir_errors(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    root = tmp_path / "root"
    root.mkdir()
    (root / "file").write_text("obstacle", encoding="utf-8")
    with pytest.raises(materializer.MaterializationError, match="unsafe destination ancestor"):
        materializer._ensure_parent(root, "file/item.txt")

    reparse_root = tmp_path / "reparse"
    reparse_root.mkdir()
    (reparse_root / "parent").mkdir()
    monkeypatch.setattr(materializer, "_is_reparse", lambda path: path.name == "parent")
    with pytest.raises(materializer.MaterializationError, match="unsafe destination ancestor"):
        materializer._ensure_parent(reparse_root, "parent/item.txt")

    error_root = tmp_path / "error"
    error_root.mkdir()
    original_mkdir = Path.mkdir

    def denied(path: Path, *args, **kwargs):
        if path.name == "new":
            raise OSError("denied")
        return original_mkdir(path, *args, **kwargs)

    monkeypatch.setattr(Path, "mkdir", denied)
    monkeypatch.setattr(materializer, "_is_reparse", lambda _path: False)
    with pytest.raises(materializer.MaterializationError, match="cannot create directory"):
        materializer._ensure_parent(error_root, "new/item.txt")


def test_ensure_parent_handles_creation_races_fail_closed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    root = tmp_path / "root"
    root.mkdir()

    monkeypatch.setattr(Path, "mkdir", lambda _path: (_ for _ in ()).throw(FileExistsError()))
    monkeypatch.setattr(materializer, "_is_reparse", lambda _path: True)
    with pytest.raises(materializer.MaterializationError, match="unsafe destination ancestor"):
        materializer._ensure_parent(root, "raced/item.txt")

    monkeypatch.undo()
    root = tmp_path / "post-create"
    root.mkdir()
    original_is_reparse = materializer._is_reparse

    def appeared(path: Path) -> bool:
        return path.name == "raced" or original_is_reparse(path)

    monkeypatch.setattr(materializer, "_is_reparse", appeared)
    with pytest.raises(materializer.MaterializationError, match="unsafe destination ancestor"):
        materializer._ensure_parent(root, "raced/item.txt")


def test_atomic_regular_write_rejects_racing_different_leaf(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    destination = tmp_path / "item.txt"
    entry = _manifest_entry(destination_path="item.txt", payload=b"expected")

    def raced(_source, target, **_kwargs):
        Path(target).write_bytes(b"different")
        raise FileExistsError()

    monkeypatch.setattr(materializer.os, "link", raced)
    with pytest.raises(materializer.MaterializationError, match="leaf differs"):
        materializer._write_regular_atomically(destination, entry)


def test_atomic_regular_write_accepts_racing_exact_leaf(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    destination = tmp_path / "item.txt"
    entry = _manifest_entry(destination_path="item.txt", payload=b"expected")

    def raced(_source, target, **_kwargs):
        Path(target).write_bytes(entry.payload)
        raise FileExistsError()

    monkeypatch.setattr(materializer.os, "link", raced)
    materializer._write_regular_atomically(destination, entry)
    assert destination.read_bytes() == entry.payload


def test_atomic_regular_write_converts_link_and_cleanup_errors(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    destination = tmp_path / "item.txt"
    entry = _manifest_entry(destination_path="item.txt", payload=b"expected")
    monkeypatch.setattr(
        materializer.os,
        "link",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(OSError("link denied")),
    )
    with pytest.raises(materializer.MaterializationError, match="cannot atomically create"):
        materializer._write_regular_atomically(destination, entry)

    monkeypatch.undo()
    original_unlink = Path.unlink

    def unlink_denied(path: Path, *args, **kwargs):
        if path.name.startswith(".astral-extract-"):
            original_unlink(path, *args, **kwargs)
            raise OSError("cleanup denied")
        return original_unlink(path, *args, **kwargs)

    monkeypatch.setattr(Path, "unlink", unlink_denied)
    destination = tmp_path / "cleanup.txt"
    with pytest.raises(materializer.MaterializationError, match="cannot remove temporary"):
        materializer._write_regular_atomically(destination, entry)


def test_materialize_converts_symlink_creation_errors(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    target = "../../../../../backend/tests/fixtures/voice_065"
    plan = _symlink_plan(tmp_path, target)
    monkeypatch.setattr(
        materializer.os,
        "symlink",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(OSError("denied")),
    )
    with pytest.raises(materializer.MaterializationError, match="cannot create real"):
        materializer.materialize(plan)


def test_materialize_handles_symlink_creation_races(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    target = "../../../../../backend/tests/fixtures/voice_065"
    plan = _symlink_plan(tmp_path, target)
    states = iter([False, True, True])
    monkeypatch.setattr(materializer, "_same_existing_leaf", lambda *_args: next(states))
    monkeypatch.setattr(
        materializer.os,
        "symlink",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(FileExistsError()),
    )
    assert materializer.materialize(plan)["created"] == 1

    states = iter([False, False])
    monkeypatch.setattr(materializer, "_same_existing_leaf", lambda *_args: next(states))
    with pytest.raises(materializer.MaterializationError, match="appeared"):
        materializer.materialize(plan)


def test_materialize_fails_when_post_write_verification_fails(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    entry = _manifest_entry(destination_path="item.txt", payload=b"expected")
    plan = materializer.MaterializationPlan(
        source_repo=tmp_path,
        destination_root=tmp_path,
        source_commit="0" * 40,
        source_tree="0" * 40,
        manifest_sha256="1" * 64,
        entries=(entry,),
        allowed_symlinks={},
    )
    monkeypatch.setattr(materializer, "_same_existing_leaf", lambda *_args: False)
    monkeypatch.setattr(materializer, "_write_regular_atomically", lambda *_args: None)
    with pytest.raises(materializer.MaterializationError, match="verification failed"):
        materializer.materialize(plan)


def test_stage_entries_rejects_index_tuple_mismatch(tmp_path: Path):
    destination = tmp_path / "destination"
    _repo(
        destination,
        branch="codex/test",
        origin=materializer.DESTINATION_REPOSITORY,
    )
    commit, tree, _ = _commit_file(destination, "legacy.txt", b"legacy\n")
    entry = _manifest_entry(
        destination_path="item.txt",
        payload=b"payload",
        blob="0" * 40,
    )
    (destination / "item.txt").write_bytes(entry.payload)
    plan = materializer.MaterializationPlan(
        source_repo=destination,
        destination_root=destination,
        source_commit=commit,
        source_tree=tree,
        manifest_sha256="1" * 64,
        entries=(entry,),
        allowed_symlinks={},
    )
    with pytest.raises(materializer.MaterializationError, match="staged Git tuple mismatch"):
        materializer.stage_entries(plan)


@pytest.mark.parametrize(
    ("value", "message"),
    [
        ("missing-separator", "DESTINATION=TARGET"),
        ("../unsafe=target", "unsafe segment"),
        ("safe/path=", "must not be empty"),
    ],
)
def test_parse_symlink_rejects_bad_cli_values(value: str, message: str):
    with pytest.raises(materializer.argparse.ArgumentTypeError, match=message):
        materializer._parse_symlink(value)


def test_parse_symlink_accepts_canonical_cli_value():
    assert materializer._parse_symlink("safe/path=../target") == (
        "safe/path",
        "../target",
    )


def test_cli_reports_materialization_error(repositories, capsys):
    arguments = _plan_arguments(repositories)
    result = materializer.main(
        [
            "--manifest",
            os.fspath(arguments["manifest_path"]),
            "--source-repo",
            os.fspath(arguments["source_repo"]),
            "--destination-root",
            os.fspath(arguments["destination_root"]),
            "--expected-branch",
            "codex/test",
            "--expected-head",
            "0" * 40,
        ]
    )
    assert result == 1
    assert "materialize_extraction:" in capsys.readouterr().err


def test_cli_materializes_and_stages_exact_entries(repositories, capsys):
    arguments = _plan_arguments(repositories)
    result = materializer.main(
        [
            "--manifest",
            os.fspath(arguments["manifest_path"]),
            "--source-repo",
            os.fspath(arguments["source_repo"]),
            "--destination-root",
            os.fspath(arguments["destination_root"]),
            "--expected-branch",
            "codex/test",
            "--expected-head",
            str(arguments["expected_head"]),
            "--stage",
        ]
    )
    assert result == 0
    output = json.loads(capsys.readouterr().out)
    assert output["created"] == 1
    assert output["staged"] is True
